// SpatialEngine/Audio.swift — internal CoreAudio machinery for the spatializer.
// Moved out of the Phase-1/2 AtmosDaemon CLI so both the daemon and the SwiftUI
// app can drive the same proven engine. CoreAudio HAL only (no AVAudioEngine).
//
// CRITICAL: @convention(c) callbacks must touch ONLY raw pointers and the Ctx
// object passed via inRefCon. No Swift Array closures, no main-actor globals.

import CoreAudio
import AudioToolbox
import Darwin          // memset, memcpy, free
import Accelerate      // vDSP (peaks, silence detection, downmix)
import Synchronization // Atomic<UInt64> — release/acquire ordering on the SPSC indices

// ---------------------------------------------------------------------------
// MARK: - Optional setup logger (RT callbacks never log)
// ---------------------------------------------------------------------------
// Set once by SpatialEngine.start() on the main thread before any audio runs.
// The daemon CLI routes this to print(); the app leaves it nil (silent).
nonisolated(unsafe) var seLog: ((String) -> Void)? = nil

@inline(__always) func selog(_ s: String) { seLog?(s) }

@discardableResult
func check(_ status: OSStatus, _ label: String) -> Bool {
    if status == noErr {
        selog("  OK  \(label)")
        return true
    } else {
        selog("  ERR \(label): \(status) (0x\(String(status, radix: 16)))")
        return false
    }
}

// ---------------------------------------------------------------------------
// MARK: - AUSpatialMixer property IDs + enum values (numeric; CLT-safe)
// ---------------------------------------------------------------------------

let kPropRenderingFlags:                AudioUnitPropertyID = 3003  // Input, UInt32 bitmask
let kPropSourceMode:                    AudioUnitPropertyID = 3005
let kPropDistanceParams:                AudioUnitPropertyID = 3010  // Input, MixerDistanceParams
let kPropAttenuationCurve:              AudioUnitPropertyID = 3013  // Input, UInt32 enum
let kPropOutputType:                    AudioUnitPropertyID = 3100
let kPropPointSourceInHeadMode:         AudioUnitPropertyID = 3103  // Input, UInt32 (0 Mono / 1 Bypass)
let kPropEnableHeadTracking:            AudioUnitPropertyID = 3111
let kPropPersonalizedHRTFMode:          AudioUnitPropertyID = 3113
let kPropAnyInputUsingPersonalizedHRTF: AudioUnitPropertyID = 3116
let kPropReverbRoomType:                AudioUnitPropertyID = 10    // Global, UInt32 enum
let kPropUsesInternalReverb:            AudioUnitPropertyID = 1005  // Global, UInt32 (0/1)

let kSrcModeBypass:      UInt32 = 1
let kSrcModePointSource: UInt32 = 2
let kSrcModeAmbienceBed: UInt32 = 3

// Atmos 7.1.4 canonical speaker directions (degrees), in Atmos_7_1_4 channel/bus order:
//   L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr.
// LFE (index 3) is rendered with SourceMode=Bypass (unspatialized). Read only on the
// setup thread by the mixer factory + applySourceParams (never on an RT callback).
let kAtmos714Azimuth:   [Float] = [-30, 30, 0, 0, -110, 110, -145, 145, -45, 45, -135, 135]
let kAtmos714Elevation: [Float] = [  0,  0, 0, 0,    0,   0,    0,   0,  45, 45,   45,  45]
let kAtmos714Channels          = 12
let kAtmos714LFEChannel        = 3

// Rendering flags (gate distance attenuation + inter-aural time delay).
let kRenderFlagInterAuralDelay: UInt32 = 1 << 0   // 0x1
let kRenderFlagDistanceAtten:   UInt32 = 1 << 2   // 0x4
let kAttenuationCurveInverse:   UInt32 = 2        // natural 1/r falloff
let kInHeadModeBypass:          UInt32 = 1        // sources move OUTSIDE the head

/// Distance attenuation envelope (matches AudioToolbox `MixerDistanceParams`, 3×Float32).
struct DistanceParams { var referenceDistance: Float32; var maxDistance: Float32; var maxAttenuation: Float32 }

/// Half-width (degrees) of the two virtual speakers in the dual-point-source topology.
let kStereoSpreadDegrees: Float = 30

let kParamAzimuth:   AudioUnitParameterID = 0   // ±180°
let kParamElevation: AudioUnitParameterID = 1   // ±90°
let kParamDistance:  AudioUnitParameterID = 2   // metres
let kParamGain:      AudioUnitParameterID = 3   // dB
let kParamReverbBlend:      AudioUnitParameterID = 8   // Input scope, 0…100 percent
let kParamGlobalReverbGain: AudioUnitParameterID = 9   // Global, dB

// ---------------------------------------------------------------------------
// MARK: - Lock-free SPSC ring buffer (atomic release/acquire indices)
// ---------------------------------------------------------------------------

let kRingFrames: UInt64 = 32768       // power-of-two
let kRingMask:   UInt64 = kRingFrames - 1

/// Lock-free SPSC ring of N independent channel planes (fixed at init; never
/// reallocated on the RT threads). Stereo capture uses N=2; surround 7.1.4 uses N=12.
final class RingBuffer {
    let channels: Int
    // C array of `channels` plane pointers, each kRingFrames floats.
    let planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    // arm64 is weakly ordered: producer release-stores writeIdx after the buffer
    // writes; consumer acquire-loads it, so a bumped index implies visible samples.
    let writeIdx = Atomic<UInt64>(0)
    let readIdx  = Atomic<UInt64>(0)
    // Consumer-side fill-target controller (loopback mode only — host clock vs sink
    // clock drift). Set once on the setup thread before audio runs; the RT read()
    // nudges the read index ±1 frame/block to hold the fill inside [driftLow, driftHigh].
    var driftEnabled = false
    var driftLow:  UInt64 = 0
    var driftHigh: UInt64 = 0

    init(channels: Int) {
        self.channels = channels
        planes = .allocate(capacity: channels)
        var c = 0
        while c < channels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Int(kRingFrames))
            p.initialize(repeating: 0, count: Int(kRingFrames))
            planes[c] = p
            c &+= 1
        }
    }
    deinit {
        var c = 0
        while c < channels { planes[c].deallocate(); c &+= 1 }
        planes.deallocate()
    }

    @inline(__always)
    func fill() -> UInt64 {
        writeIdx.load(ordering: .acquiring) &- readIdx.load(ordering: .acquiring)
    }

    /// Reset indices to empty. Call only when no RT thread is touching the ring.
    func reset() {
        writeIdx.store(0, ordering: .relaxed)
        readIdx.store(0, ordering: .relaxed)
    }

    /// Prime the ring with `frames` of silence before the RT threads start, so the
    /// first playback callbacks read primed samples instead of racing an empty ring.
    /// Setup-thread only (no concurrent RT access).
    func prefill(frames: UInt64) {
        let n = frames < (kRingFrames - 1) ? frames : (kRingFrames - 1)
        var c = 0
        while c < channels {
            let plane = planes[c]
            var i: UInt64 = 0
            while i < n { plane[Int(i)] = 0; i &+= 1 }
            c &+= 1
        }
        readIdx.store(0, ordering: .relaxed)
        writeIdx.store(n, ordering: .releasing)
    }

    // Fill-target controller (loopback only): remaining = fill after this block.
    // Above the high water mark → discard 1 extra frame; below the low mark →
    // re-read 1 frame next block. Single-frame nudge, raw pointer math, no alloc.
    @inline(__always)
    func advanceFor(available: UInt64, toRead: UInt64) -> UInt64 {
        if driftEnabled {
            let remaining = available &- toRead
            if remaining > driftHigh { return toRead &+ 1 }
            if toRead > 0 && remaining < driftLow { return toRead &- 1 }
        }
        return toRead
    }

    // Contiguous ring <-> linear copies: at most two memcpy segments per plane (the ring
    // wraps at most once per block) instead of a masked per-sample loop. Pure copies, so
    // bit-identical to the previous element-wise loops.
    @inline(__always)
    private static func copyOut(_ plane: UnsafeMutablePointer<Float>, from start: UInt64, count: Int,
                                to dst: UnsafeMutablePointer<Float>) {
        let s = Int(start & kRingMask)
        let tail = Int(kRingFrames) - s
        let first = count < tail ? count : tail
        memcpy(dst, plane + s, first * 4)
        if first < count { memcpy(dst + first, plane, (count - first) * 4) }
    }

    @inline(__always)
    private static func copyIn(_ plane: UnsafeMutablePointer<Float>, at start: UInt64, count: Int,
                               from src: UnsafePointer<Float>) {
        let s = Int(start & kRingMask)
        let tail = Int(kRingFrames) - s
        let first = count < tail ? count : tail
        memcpy(plane + s, src, first * 4)
        if first < count { memcpy(plane, src + first, (count - first) * 4) }
    }

    /// Producer: copy `frameCount` frames from the N non-interleaved buffers of `abl`
    /// (abl[c].mData) into the N ring planes. Capture RT thread only.
    @inline(__always) @discardableResult
    func writeAll(from abl: RawABL, frameCount: UInt32) -> UInt32 {
        let wi = writeIdx.load(ordering: .relaxed)
        let ri = readIdx.load(ordering: .acquiring)
        let available = kRingFrames &- (wi &- ri)
        let want = UInt64(frameCount)
        let toWrite = want < available ? want : available
        if toWrite == 0 { return 0 }
        var c = 0
        while c < channels {
            if let raw = abl[c].mData {
                RingBuffer.copyIn(planes[c], at: wi, count: Int(toWrite), from: raw.assumingMemoryBound(to: Float.self))
            }
            c &+= 1
        }
        writeIdx.store(wi &+ toWrite, ordering: .releasing)
        return UInt32(toWrite)
    }

    @inline(__always) @discardableResult
    func read(ch0 dst0: UnsafeMutablePointer<Float>, ch1 dst1: UnsafeMutablePointer<Float>,
              frameCount: UInt32) -> UInt32 {
        let ri = readIdx.load(ordering: .relaxed)
        let wi = writeIdx.load(ordering: .acquiring)
        let available = wi &- ri
        let want = UInt64(frameCount)
        let toRead = want < available ? want : available
        if toRead == 0 {
            memset(dst0, 0, Int(frameCount) * 4)
            memset(dst1, 0, Int(frameCount) * 4)
            return 0
        }
        RingBuffer.copyOut(planes[0], from: ri, count: Int(toRead), to: dst0)
        RingBuffer.copyOut(planes[1], from: ri, count: Int(toRead), to: dst1)
        if toRead < want {
            let rem = Int(frameCount) - Int(toRead)
            memset(dst0 + Int(toRead), 0, rem * 4)
            memset(dst1 + Int(toRead), 0, rem * 4)
        }
        readIdx.store(ri &+ advanceFor(available: available, toRead: toRead), ordering: .releasing)
        return UInt32(toRead)
    }

    /// Consumer: stage `frameCount` frames of ALL N channels into caller-provided
    /// plane pointers `dst[0..<channels]` (surround staging). Playback RT thread only.
    @inline(__always) @discardableResult
    func readAll(into dst: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frameCount: UInt32) -> UInt32 {
        let ri = readIdx.load(ordering: .relaxed)
        let wi = writeIdx.load(ordering: .acquiring)
        let available = wi &- ri
        let want = UInt64(frameCount)
        let toRead = want < available ? want : available
        if toRead == 0 {
            var c = 0
            while c < channels { memset(dst[c], 0, Int(frameCount) * 4); c &+= 1 }
            return 0
        }
        var c = 0
        while c < channels {
            let out = dst[c]
            RingBuffer.copyOut(planes[c], from: ri, count: Int(toRead), to: out)
            if toRead < want {
                let rem = Int(frameCount) - Int(toRead)
                memset(out + Int(toRead), 0, rem * 4)
            }
            c &+= 1
        }
        readIdx.store(ri &+ advanceFor(available: available, toRead: toRead), ordering: .releasing)
        return UInt32(toRead)
    }

    /// Consumer-side look-ahead for the idle bypass: are the next `frameCount` frames (or
    /// fewer, if less is buffered) digital silence on every plane? Returns the frame count
    /// it inspected plus the fill it saw, so `discard` consumes exactly what was checked.
    @inline(__always)
    func peekSilent(frameCount: UInt32) -> (silent: Bool, toRead: UInt64, available: UInt64) {
        let ri = readIdx.load(ordering: .relaxed)
        let wi = writeIdx.load(ordering: .acquiring)
        let available = wi &- ri
        let want = UInt64(frameCount)
        let toRead = want < available ? want : available
        if toRead == 0 { return (true, 0, available) }
        let s = Int(ri & kRingMask)
        let tail = Int(kRingFrames) - s
        let count = Int(toRead)
        let first = count < tail ? count : tail
        var c = 0
        while c < channels {
            let plane = planes[c]
            if !isDigitalSilence(plane + s, first) { return (false, toRead, available) }
            if first < count && !isDigitalSilence(plane, count - first) { return (false, toRead, available) }
            c &+= 1
        }
        return (true, toRead, available)
    }

    /// Consume frames inspected by `peekSilent` without copying them (idle bypass). Mirrors
    /// `read`/`readAll` index + drift-controller semantics exactly.
    @inline(__always)
    func discard(toRead: UInt64, available: UInt64) {
        if toRead == 0 { return }
        let ri = readIdx.load(ordering: .relaxed)
        readIdx.store(ri &+ advanceFor(available: available, toRead: toRead), ordering: .releasing)
    }
}

// ---------------------------------------------------------------------------
// MARK: - RawABL: inlinable AudioBufferList view for the RT callbacks
// ---------------------------------------------------------------------------

/// Byte offset of `AudioBufferList.mBuffers` (UInt32 count + 4 bytes padding before the
/// 8-byte-aligned AudioBuffer array). Asserted against MemoryLayout in the tests.
let kAudioBufferListBuffersOffset = 8

/// A plain-pointer view of an AudioBufferList. The SDK's UnsafeMutableAudioBufferListPointer
/// is a resilient CoreAudio-overlay type: every `count`/subscript is a cross-module accessor
/// call, Optionals of it go through value witnesses, and each call site resolves its type
/// metadata on first use — all on the IO thread. This compiles to direct loads/stores.
struct RawABL {
    let list: UnsafeMutablePointer<AudioBufferList>
    @inline(__always) init(_ p: UnsafeMutablePointer<AudioBufferList>) { list = p }
    @inline(__always) init(_ p: UnsafePointer<AudioBufferList>) { list = UnsafeMutablePointer(mutating: p) }
    @inline(__always) var count: Int { Int(list.pointee.mNumberBuffers) }
    @inline(__always) var buffers: UnsafeMutablePointer<AudioBuffer> {
        (UnsafeMutableRawPointer(list) + kAudioBufferListBuffersOffset).assumingMemoryBound(to: AudioBuffer.self)
    }
    @inline(__always) subscript(i: Int) -> AudioBuffer {
        get { buffers[i] }
        nonmutating set { buffers[i] = newValue }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Vector helpers (Accelerate; RT-safe: no allocation, no locks)
// ---------------------------------------------------------------------------

/// max |x| over `n` samples (vDSP_maxmgv) — the meter peak. Same value as the previous
/// scalar fabsf loop (no arithmetic, only magnitude compare).
@inline(__always)
func peakMagnitude(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
    if n <= 0 { return 0 }
    var m: Float = 0
    vDSP_maxmgv(p, 1, &m, vDSP_Length(n))
    return m
}

/// True only when every sample is ±0. NaN/Inf count as signal.
@inline(__always)
func isDigitalSilence(_ p: UnsafePointer<Float>, _ n: Int) -> Bool {
    peakMagnitude(p, n) == 0
}

@inline(__always)
func zeroBuffers(_ abl: RawABL) {
    var b = 0
    while b < abl.count { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
}

// ---------------------------------------------------------------------------
// MARK: - Shared RT context (passed as inRefCon to the callbacks)
// ---------------------------------------------------------------------------

final class Ctx: @unchecked Sendable {
    let channels: Int
    let ring: RingBuffer
    var unifiedDeviceID: AudioDeviceID = 0
    var unifiedIOProc: AudioDeviceIOProcID? = nil
    var unifiedOutputList: UnsafeMutablePointer<AudioBufferList>? = nil   // RT reads this
    var unifiedLayout: UnifiedBufferLayout = .defaultStereoInterleaved
    var captureUnit:  AudioUnit? = nil
    var playbackUnit: AudioUnit? = nil
    var totalCaptured: UInt64 = 0
    var totalPlayed:   UInt64 = 0
    var captureList: UnsafeMutablePointer<AudioBufferList>? = nil         // RT reads this
    var captureBufSize: UInt32 = 0
    // Per-channel peak (max |sample|) since last poll, one Float per capture channel.
    // Written on the capture RT thread, read+reset on the main thread — aligned Float
    // access is atomic on arm64.
    let capturePeaks: UnsafeMutablePointer<Float>

    var spatialMixer:    AudioUnit? = nil
    var spatialize:      Bool = false
    var spatialBed:      Bool = false            // stereo AmbienceBed (2ch, reads L/R)
    var spatialDualPoint: Bool = false           // two mono point-source input buses (L/R)
    var spatialSurround:  Bool = false           // surround714: 12 mono buses staged per cycle
    var spatialSurroundBed: Bool = false         // surroundBed714: single 12ch AmbienceBed bus
    var dmL:             UnsafeMutablePointer<Float>? = nil
    var dmR:             UnsafeMutablePointer<Float>? = nil
    // Surround staging: `channels` planes filled once per render cycle from the ring.
    var stage: UnsafeMutablePointer<UnsafeMutablePointer<Float>>? = nil
    var stageChannels: Int = 0
    var spatialMaxFrames: UInt32 = 0
    var lastStagedSampleTime: Float64 = -1        // stage the ring once per render cycle

    // --- Idle bypass (RT-thread owned except where noted) ---
    // When the mixer has seen exact-zero input AND produced exact-zero output for
    // `idleHoldFrames`, its render is skipped (output = exact zeros, which is what it
    // would have produced). Any live param/property change bumps `paramEpoch` (control
    // thread) and re-arms rendering so ramps run exactly as before. On the first non-silent
    // block a discarded zero-input `idleCatchUpFrames` render lets internal state that may
    // have moved while skipped (OS head pose) converge before the audible block.
    var idleBypassEnabled = true                  // set on the setup thread before audio runs
    var idleHoldFrames: UInt64 = 12_000
    var idleCatchUpFrames: UInt32 = 0
    var idleQuietFrames: UInt64 = 0
    var idleBypassing = false
    var feedSilence = false                       // input callback feeds zeros (catch-up render)
    let paramEpoch = Atomic<UInt32>(0)            // bumped by the control thread
    var seenParamEpoch: UInt32 = 0
    var scratchList: UnsafeMutablePointer<AudioBufferList>? = nil  // catch-up render target
    var idleSkippedBlocks: UInt64 = 0             // telemetry (bench)

    // Setup-thread / test conveniences over the raw lists (never used on the RT threads).
    var captureABL: UnsafeMutableAudioBufferListPointer? {
        get { captureList.map { UnsafeMutableAudioBufferListPointer($0) } }
        set { captureList = newValue?.unsafeMutablePointer }
    }
    var unifiedOutputABL: UnsafeMutableAudioBufferListPointer? {
        get { unifiedOutputList.map { UnsafeMutableAudioBufferListPointer($0) } }
        set { unifiedOutputList = newValue?.unsafeMutablePointer }
    }
    var scratchABL: UnsafeMutableAudioBufferListPointer? {
        get { scratchList.map { UnsafeMutableAudioBufferListPointer($0) } }
        set { scratchList = newValue?.unsafeMutablePointer }
    }

    init(channels: Int) {
        self.channels = channels
        ring = RingBuffer(channels: channels)
        capturePeaks = .allocate(capacity: channels)
        capturePeaks.initialize(repeating: 0, count: channels)
    }
    deinit { capturePeaks.deallocate() }
}

// ---------------------------------------------------------------------------
// MARK: - Format helpers
// ---------------------------------------------------------------------------

func stereoFloat32Format(sampleRate: Float64 = 48000) -> AudioStreamBasicDescription {
    var fmt = AudioStreamBasicDescription()
    fmt.mSampleRate       = sampleRate
    fmt.mFormatID         = kAudioFormatLinearPCM
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
    fmt.mBitsPerChannel   = 32
    fmt.mChannelsPerFrame = 2
    fmt.mFramesPerPacket  = 1
    fmt.mBytesPerFrame    = 4
    fmt.mBytesPerPacket   = 4
    return fmt
}

func makeFloatASBD(channels: UInt32, sampleRate: Double = 48_000) -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate       = sampleRate
    asbd.mFormatID         = kAudioFormatLinearPCM
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
    asbd.mFramesPerPacket  = 1
    asbd.mBytesPerFrame    = 4
    asbd.mBytesPerPacket   = 4
    asbd.mBitsPerChannel   = 32
    asbd.mChannelsPerFrame = channels
    return asbd
}

func makeCaptureABL(maxFrames: UInt32, channels: Int) -> UnsafeMutableAudioBufferListPointer {
    let abl = AudioBufferList.allocate(maximumBuffers: channels)
    for ch in 0..<channels {
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maxFrames) * MemoryLayout<Float>.size,
            alignment: MemoryLayout<Float>.alignment)
        data.initializeMemory(as: Float.self, repeating: 0, count: Int(maxFrames))
        abl[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: data)
    }
    return abl
}

// ---------------------------------------------------------------------------
// MARK: - RT callbacks (raw pointers only; env-free — read ctx fields)
// ---------------------------------------------------------------------------

nonisolated(unsafe) let captureInputCallback: AURenderCallback = { (
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _
) -> OSStatus in
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = ctx.captureUnit, let list = ctx.captureList else { return noErr }
    let abl = RawABL(list)
    let n = inNumberFrames
    // The ABL blocks were allocated once for captureBufSize (MaximumFramesPerSlice at
    // setup). If the HAL delivers a larger slice mid-session (device IO buffer grown in
    // Audio MIDI Setup / aggregate reconfig), rendering it would overflow the heap blocks.
    if n > ctx.captureBufSize { return noErr }
    let ch = ctx.channels
    var b = 0
    while b < ch { abl[b].mDataByteSize = n * 4; b &+= 1 }
    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, n, list)
    if status != noErr { return status }
    processCapturedBlock(ctx, abl: abl, frames: n)
    return noErr
}

/// Capture-side post-processing shared by the loopback capture callback and the offline
/// bench harness: push the rendered capture planes into the ring + update the meters.
@inline(__always)
func processCapturedBlock(_ ctx: Ctx, abl: RawABL, frames n: UInt32) {
    let written = ctx.ring.writeAll(from: abl, frameCount: n)
    ctx.totalCaptured &+= UInt64(written)
    // Per-channel peak (vDSP_maxmgv — no Swift runtime calls on the RT thread).
    let ch = ctx.channels
    let cnt = Int(n)
    var c = 0
    while c < ch {
        if let raw = abl[c].mData {
            let pk = peakMagnitude(raw.assumingMemoryBound(to: Float.self), cnt)
            if pk > ctx.capturePeaks[c] { ctx.capturePeaks[c] = pk }
        }
        c &+= 1
    }
}

/// Render the spatial mixer, or skip it while idle (see Ctx idle-bypass fields).
/// `inputSilent` = the frames the mixer would pull this cycle are all exact zeros.
/// `ringPeek` (loopback only) = what `peekSilent` inspected, consumed when skipping so
/// the ring advances exactly as the mixer's input callback would have advanced it.
/// Returns the render status; when skipping, writes exact zeros into `abl`.
@inline(__always)
func renderMixerGated(_ ctx: Ctx, _ mixer: AudioUnit,
                      _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                      _ ts: UnsafePointer<AudioTimeStamp>, _ n: UInt32,
                      _ abl: UnsafeMutablePointer<AudioBufferList>, inputSilent: Bool,
                      ringPeek: (toRead: UInt64, available: UInt64)?) -> OSStatus {
    let epoch = ctx.paramEpoch.load(ordering: .acquiring)
    if epoch != ctx.seenParamEpoch {
        // A live param change must ramp inside the mixer exactly as before: render again
        // (zeros in → zeros out) until the hold re-qualifies.
        ctx.seenParamEpoch = epoch
        ctx.idleQuietFrames = 0
        ctx.idleBypassing = false
    }
    if ctx.idleBypassing {
        if inputSilent {
            if let p = ringPeek { ctx.ring.discard(toRead: p.toRead, available: p.available) }
            zeroBuffers(RawABL(abl))
            ctx.idleSkippedBlocks &+= 1
            return noErr
        }
        ctx.idleBypassing = false
        idleCatchUp(ctx, mixer, ts)
    }
    let st = AudioUnitRender(mixer, flags, ts, 0, n, abl)
    if inputSilent && st == noErr && ctx.idleBypassEnabled && renderedSilence(abl, n) {
        ctx.idleQuietFrames &+= UInt64(n)
        if ctx.idleQuietFrames >= ctx.idleHoldFrames { ctx.idleBypassing = true }
    } else {
        ctx.idleQuietFrames = 0
    }
    return st
}

@inline(__always)
private func renderedSilence(_ abl: UnsafeMutablePointer<AudioBufferList>, _ n: UInt32) -> Bool {
    let bufs = RawABL(abl)
    var b = 0
    while b < bufs.count {
        guard let p = bufs[b].mData else { return false }
        if !isDigitalSilence(p.assumingMemoryBound(to: Float.self), Int(bufs[b].mDataByteSize) / 4) { return false }
        b &+= 1
    }
    return true
}

/// Resume from idle: one discarded render of silence (input callback feeds zeros, the
/// ring/tap data is untouched) so state that may have changed while skipped — chiefly the
/// OS-fed head pose — settles before the audible block. Cold path: once per resume.
@inline(never)
func idleCatchUp(_ ctx: Ctx, _ mixer: AudioUnit, _ ts: UnsafePointer<AudioTimeStamp>) {
    guard let list = ctx.scratchList, ctx.idleCatchUpFrames > 0 else { return }
    let scratch = RawABL(list)
    let frames = ctx.idleCatchUpFrames
    var t = ts.pointee
    t.mSampleTime -= Float64(frames)
    var b = 0
    while b < scratch.count { scratch[b].mDataByteSize = frames * 4; b &+= 1 }
    ctx.feedSilence = true
    var f = AudioUnitRenderActionFlags()
    _ = AudioUnitRender(mixer, &f, &t, 0, frames, list)
    ctx.feedSilence = false
}

// Sole ring consumer in spatialize mode (runs inside AudioUnitRender on the
// playback HAL thread). dualPoint = stereo split across two mono buses;
// bed = stereo copy; mono point = mono downmix.
nonisolated(unsafe) let spatialInputCallback: AURenderCallback = { (
    inRefCon, _, inTimeStamp, inBusNumber, inNumberFrames, ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let abl = RawABL(ioData)
    let n = inNumberFrames
    let nbuf = abl.count
    guard n <= ctx.spatialMaxFrames else {
        var b = 0; while b < nbuf { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
        return noErr
    }
    if ctx.feedSilence {
        // Idle catch-up render: zeros, leave the ring / tap data untouched.
        var b = 0
        while b < nbuf {
            if let p = abl[b].mData { memset(p, 0, Int(n) * 4 * Int(abl[b].mNumberChannels)); abl[b].mDataByteSize = n * 4 * abl[b].mNumberChannels }
            b &+= 1
        }
        return noErr
    }
    if ctx.unifiedOutputList != nil, let capList = ctx.captureList,
       case let cap = RawABL(capList),
       let lRaw = cap[0].mData, let rRaw = cap[1].mData {
        // Unified tap path: tap input and device output share one clock and one IO cycle,
        // so the IOProc's de-interleaved capture planes feed the buses directly (no ring
        // round trip, no staging). Same samples the ring used to hand over.
        let l = lRaw.assumingMemoryBound(to: Float.self)
        let r = rRaw.assumingMemoryBound(to: Float.self)
        if ctx.spatialDualPoint {
            if let p = abl[0].mData { memcpy(p, inBusNumber == 0 ? l : r, Int(n) * 4); abl[0].mDataByteSize = n * 4 }
        } else if ctx.spatialBed {
            if nbuf >= 2, let p0 = abl[0].mData, let p1 = abl[1].mData {
                memcpy(p0, l, Int(n) * 4); memcpy(p1, r, Int(n) * 4)
                abl[0].mDataByteSize = n * 4; abl[1].mDataByteSize = n * 4
            }
        } else {
            var half: Float = 0.5
            var b = 0
            while b < nbuf {
                if let p = abl[b].mData {
                    vDSP_vasm(l, 1, r, 1, &half, p.assumingMemoryBound(to: Float.self), 1, vDSP_Length(n))
                    abl[b].mDataByteSize = n * 4
                }
                b &+= 1
            }
        }
        return noErr
    }
    if ctx.spatialDualPoint {
        guard let dmL = ctx.dmL, let dmR = ctx.dmR else {
            var b = 0; while b < nbuf { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
            return noErr
        }
        // The mixer pulls bus 0 then bus 1 within one render cycle (same timestamp).
        // Read the stereo ring ONCE per cycle into the staging buffers, then hand the
        // matching channel to whichever bus is being pulled (bus 0 = L, bus 1 = R).
        let st = inTimeStamp.pointee.mSampleTime
        if st != ctx.lastStagedSampleTime {
            ctx.ring.read(ch0: dmL, ch1: dmR, frameCount: n)
            ctx.lastStagedSampleTime = st
        }
        let src = (inBusNumber == 0) ? dmL : dmR    // mono bus → 1 buffer
        if let p = abl[0].mData {
            memcpy(p, src, Int(n) * 4)
            abl[0].mDataByteSize = n * 4
        }
        return noErr
    }
    if ctx.spatialSurround {
        // surround714: 12 mono buses pulled per cycle (same timestamp). Stage all 12
        // ring channels ONCE, then hand bus b its matching channel (bus == chan index).
        guard let stage = ctx.stage else {
            if let p = abl[0].mData { memset(p, 0, Int(abl[0].mDataByteSize)) }
            return noErr
        }
        let st = inTimeStamp.pointee.mSampleTime
        if st != ctx.lastStagedSampleTime {
            ctx.ring.readAll(into: stage, frameCount: n)
            ctx.lastStagedSampleTime = st
        }
        let b = Int(inBusNumber)
        if b < ctx.stageChannels, let p = abl[0].mData {
            memcpy(p, stage[b], Int(n) * 4)
            abl[0].mDataByteSize = n * 4
        }
        return noErr
    }
    if ctx.spatialSurroundBed {
        // surroundBed714: single 12ch AmbienceBed bus. Stage all channels then copy
        // each into its non-interleaved output buffer.
        guard let stage = ctx.stage else {
            var b = 0; while b < nbuf { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
            return noErr
        }
        ctx.ring.readAll(into: stage, frameCount: n)
        var c = 0
        while c < nbuf && c < ctx.stageChannels {
            if let p = abl[c].mData { memcpy(p, stage[c], Int(n) * 4); abl[c].mDataByteSize = n * 4 }
            c &+= 1
        }
        return noErr
    }
    if ctx.spatialBed {
        if nbuf >= 2, let p0 = abl[0].mData, let p1 = abl[1].mData {
            ctx.ring.read(ch0: p0.assumingMemoryBound(to: Float.self),
                          ch1: p1.assumingMemoryBound(to: Float.self), frameCount: n)
            abl[0].mDataByteSize = n * 4
            abl[1].mDataByteSize = n * 4
        }
        return noErr
    }
    guard let dmL = ctx.dmL, let dmR = ctx.dmR else {
        var b = 0; while b < nbuf { if let p = abl[b].mData { memset(p, 0, Int(abl[b].mDataByteSize)) }; b &+= 1 }
        return noErr
    }
    ctx.ring.read(ch0: dmL, ch1: dmR, frameCount: n)
    // Mono downmix (L+R)·0.5 — vDSP_vasm computes the identical IEEE result.
    var half: Float = 0.5
    var b = 0
    while b < nbuf {
        if let raw = abl[b].mData {
            vDSP_vasm(dmL, 1, dmR, 1, &half, raw.assumingMemoryBound(to: Float.self), 1, vDSP_Length(n))
            abl[b].mDataByteSize = n * 4
        }
        b &+= 1
    }
    return noErr
}

/// Loopback playback pull (AUHAL render callback). The unified tap path renders the mixer
/// directly from its IOProc (see unifiedTapCallback) and does not go through here.
nonisolated(unsafe) let playbackRenderCallback: AURenderCallback = { (
    inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, ioData
) -> OSStatus in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(inRefCon).takeUnretainedValue()
    let n = inNumberFrames
    if ctx.spatialize, let mixer = ctx.spatialMixer {
        // The mixer will pull the next n ring frames (dual/surround stage once per cycle;
        // bed/mono read n) — look at exactly those to decide whether it can idle.
        let peek = ctx.ring.peekSilent(frameCount: n)
        let st = renderMixerGated(ctx, mixer, ioActionFlags, inTimeStamp, n, ioData,
                                  inputSilent: peek.silent, ringPeek: (peek.toRead, peek.available))
        ctx.totalPlayed &+= UInt64(n)
        return st
    }
    let ablp = RawABL(ioData)
    if ablp.count >= 2 {
        let dst0 = ablp[0].mData!.assumingMemoryBound(to: Float.self)
        let dst1 = ablp[1].mData!.assumingMemoryBound(to: Float.self)
        ctx.ring.read(ch0: dst0, ch1: dst1, frameCount: n)
        ablp[0].mDataByteSize = n * 4
        ablp[1].mDataByteSize = n * 4
    } else if ablp.count == 1, let p = ablp[0].mData {
        memset(p, 0, Int(ablp[0].mDataByteSize))   // dead path (format is always stereo)
    }
    ctx.totalPlayed &+= UInt64(n)
    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - HAL unit + spatial mixer factories
// ---------------------------------------------------------------------------

func makeHALOutputUnit() -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { selog("  ERR AudioComponentFindNext nil"); return nil }
    var unit: AudioUnit? = nil
    check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
    return unit
}

func setEnableIO(_ unit: AudioUnit, enable: UInt32, scope: AudioUnitScope, element: AudioUnitElement, label: String) {
    var val = enable
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, scope, element,
                               &val, UInt32(MemoryLayout<UInt32>.size)),
          "\(label) EnableIO scope=\(scope) elem=\(element) val=\(enable)")
}

func setCurrentDevice(_ unit: AudioUnit, deviceID: AudioDeviceID, label: String) {
    var id = deviceID
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                               &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
          "\(label) SetCurrentDevice \(deviceID)")
}

@discardableResult
func setStreamFormat(_ unit: AudioUnit, fmt: inout AudioStreamBasicDescription,
                     scope: AudioUnitScope, element: AudioUnitElement, label: String) -> Bool {
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element,
                               &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
          "\(label) StreamFormat scope=\(scope) elem=\(element)")
}

@discardableResult
func setU32(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, scope: AudioUnitScope,
            element: AudioUnitElement, value: UInt32, label: String) -> Bool {
    var v = value
    let ok = check(AudioUnitSetProperty(unit, prop, scope, element, &v, UInt32(MemoryLayout<UInt32>.size)), label)
    var rv: UInt32 = 0xDEAD_BEEF; var rsz = UInt32(MemoryLayout<UInt32>.size)
    if AudioUnitGetProperty(unit, prop, scope, element, &rv, &rsz) == noErr { selog("    readback \(label) -> \(rv)") }
    return ok
}

/// Instantiate + fully configure an AUSpatialMixer per the supplied config values.
/// Returns an INITIALIZED unit. Output/0 = stereo48k binaural.
///
/// Topology by mode:
///  - dualPointStereo: TWO mono PointSource buses (L/R virtual speakers at ±spread) —
///    externalizes a stereo feed and makes az/el/distance audible (the default).
///  - ambienceBedStereo: one stereo far-field AmbienceBed (az/el rotate; distance inert).
///  - pointSourceMono: one mono PointSource (downmix; distance works, image collapses).
func makeSpatialMixer(ctxPtr: UnsafeMutableRawPointer, maxFrames: UInt32, mode: SourceRenderMode,
                      algo: UInt32, algoName: String, outputType: UInt32, outputTypeName: String,
                      hrtfMode: UInt32, hrtfModeName: String, headTrack: UInt32,
                      inputSampleRate: Double, outputSampleRate: Double = 48_000,
                      renderFlags: UInt32, distanceParams: DistanceParams,
                      attenCurve: UInt32, reverbEnabled: Bool, reverbRoomType: UInt32) -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_SpatialMixer,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { selog("  ERR AUSpatialMixer not found"); return nil }
    var unitOpt: AudioUnit? = nil
    guard check(AudioComponentInstanceNew(comp, &unitOpt), "spatial AudioComponentInstanceNew"),
          let unit = unitOpt else { return nil }

    let bed       = mode.isBed
    let surround  = mode.isSurround
    let busCount  = mode.inputBusCount
    let chPerBus  = mode.channelsPerBus
    let asbdSize  = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let srcMode:  UInt32 = bed ? kSrcModeAmbienceBed : kSrcModePointSource

    // Output is stereo binaural at outputSampleRate (48 kHz in loopback; native device rate in unified tap).
    var stereoFmt = makeFloatASBD(channels: 2, sampleRate: outputSampleRate)
    guard check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &stereoFmt, asbdSize),
                "spatial StreamFormat Output/0 = stereo@\(Int(outputSampleRate))") else {
        AudioComponentInstanceDispose(unit); return nil
    }

    // Grow the input element count BEFORE configuring the extra bus.
    if busCount > 1 {
        var count = busCount
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0,
                                   &count, UInt32(MemoryLayout<UInt32>.size)), "spatial ElementCount Input=\(busCount)")
    }

    var maxF = maxFrames
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                               &maxF, UInt32(MemoryLayout<UInt32>.size)), "spatial MaximumFramesPerSlice=\(maxFrames)")

    for bus in 0..<busCount {
        // surround714: the LFE channel (index 3) is rendered unspatialized (Bypass).
        let isLFE = surround && Int(bus) == kAtmos714LFEChannel
        let busSrcMode: UInt32 = isLFE ? kSrcModeBypass : srcMode
        let spatializedPoint = !bed && !isLFE

        var inFmt = makeFloatASBD(channels: chPerBus, sampleRate: inputSampleRate)
        guard check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, &inFmt, asbdSize),
                    "spatial StreamFormat Input/\(bus) = \(chPerBus)ch@\(Int(inputSampleRate))") else {
            AudioComponentInstanceDispose(unit); return nil
        }

        if bed {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = mode.isSurroundBed ? kAudioChannelLayoutTag_Atmos_7_1_4
                                                          : kAudioChannelLayoutTag_Stereo
            layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
            layout.mNumberChannelDescriptions = 0
            check(AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, bus,
                                       &layout, UInt32(MemoryLayout<AudioChannelLayout>.size)),
                  "spatial AudioChannelLayout Input/\(bus) = \(mode.isSurroundBed ? "Atmos_7_1_4" : "Stereo")")
        }

        var inputCB = AURenderCallbackStruct(inputProc: spatialInputCallback, inputProcRefCon: ctxPtr)
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, bus,
                                   &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
              "spatial SetRenderCallback Input/\(bus)")

        setU32(unit, kAudioUnitProperty_SpatializationAlgorithm, scope: kAudioUnitScope_Input, element: bus,
               value: algo, label: "SpatializationAlgorithm=\(algoName)(\(algo)) [Input/\(bus)]")
        setU32(unit, kPropSourceMode, scope: kAudioUnitScope_Input, element: bus,
               value: busSrcMode, label: "SourceMode=\(busSrcMode) [3005/Input/\(bus)]")

        // Distance attenuation + externalization only matter for spatialized point sources
        // (no-op for a far-field bed or the bypassed LFE).
        if spatializedPoint {
            setU32(unit, kPropRenderingFlags, scope: kAudioUnitScope_Input, element: bus,
                   value: renderFlags,
                   label: "RenderingFlags=0x\(String(renderFlags, radix: 16)) [3003/Input/\(bus)]")
            var dp = distanceParams
            check(AudioUnitSetProperty(unit, kPropDistanceParams, kAudioUnitScope_Input, bus,
                                       &dp, UInt32(MemoryLayout<DistanceParams>.size)),
                  "DistanceParams ref=\(dp.referenceDistance) max=\(dp.maxDistance) atten=\(dp.maxAttenuation)dB [3010/Input/\(bus)]")
            setU32(unit, kPropAttenuationCurve, scope: kAudioUnitScope_Input, element: bus,
                   value: attenCurve, label: "AttenuationCurve=\(attenCurve) [3013/Input/\(bus)]")
            setU32(unit, kPropPointSourceInHeadMode, scope: kAudioUnitScope_Input, element: bus,
                   value: kInHeadModeBypass, label: "PointSourceInHeadMode=Bypass [3103/Input/\(bus)]")
        }
    }

    var outType = outputType
    let sGlobal = AudioUnitSetProperty(unit, kPropOutputType, kAudioUnitScope_Global, 0,
                                       &outType, UInt32(MemoryLayout<UInt32>.size))
    if sGlobal == noErr {
        check(sGlobal, "OutputType=\(outputTypeName)(\(outputType)) [3100/Global]")
    } else {
        check(AudioUnitSetProperty(unit, kPropOutputType, kAudioUnitScope_Input, 0,
                                   &outType, UInt32(MemoryLayout<UInt32>.size)),
              "OutputType=\(outputTypeName)(\(outputType)) [3100/Input/0]")
    }

    setU32(unit, kPropEnableHeadTracking, scope: kAudioUnitScope_Global, element: 0,
           value: headTrack, label: "EnableHeadTracking=\(headTrack) [3111/Global]")
    setU32(unit, kPropPersonalizedHRTFMode, scope: kAudioUnitScope_Global, element: 0,
           value: hrtfMode, label: "PersonalizedHRTFMode=\(hrtfModeName)(\(hrtfMode)) [3113/Global]")

    // Internal reverb wet path is inert under kSpatializationAlgorithm_UseOutputType
    // (and would only attenuate the dry path), so the engine gates this OFF there.
    // ReverbBlend / GlobalReverbGain are pushed AFTER initialize (see applyReverbParams).
    if reverbEnabled {
        setU32(unit, kPropUsesInternalReverb, scope: kAudioUnitScope_Global, element: 0,
               value: 1, label: "UsesInternalReverb=1 [1005/Global]")
        setU32(unit, kPropReverbRoomType, scope: kAudioUnitScope_Global, element: 0,
               value: reverbRoomType, label: "ReverbRoomType=\(reverbRoomType) [10/Global]")
    }

    guard check(AudioUnitInitialize(unit), "spatial AudioUnitInitialize") else {
        AudioComponentInstanceDispose(unit); return nil
    }
    return unit
}
