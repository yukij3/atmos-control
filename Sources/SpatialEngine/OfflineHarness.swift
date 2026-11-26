// SpatialEngine/OfflineHarness.swift — benchmark/regression-only SPI.
//
// Builds the SAME Ctx + AUSpatialMixer graph `SpatialEngine.start()` builds (shared
// `installSpatialMixer`) and drives the SAME RT callbacks (`unifiedTapCallback`, or
// `processCapturedBlock` + `playbackRenderCallback` for the loopback path) with caller
// supplied buffers — no device IO, no HAL threads. Not part of the public API: import with
// `@_spi(Bench) import SpatialEngine`.

import CoreAudio
import AudioToolbox
import Darwin

@_spi(Bench) public enum OfflinePath: String, Sendable, CaseIterable {
    /// Personalized path: one output-clocked IOProc (tap input → mixer → device output).
    case unifiedTap
    /// Virtual-device path: capture AUHAL → ring → playback AUHAL pulling the mixer at 48 kHz.
    case loopback
}

@_spi(Bench) public final class OfflineRenderer {
    public let engine: SpatialEngine
    public let path: OfflinePath
    public let sampleRate: Double
    /// Interleaved channel count `render(input:)` expects (2, or 12 for loopback surround).
    public let inputChannels: Int
    private let inABL: UnsafeMutableAudioBufferListPointer
    private let outABL: UnsafeMutableAudioBufferListPointer
    private let outPlanes: [UnsafeMutablePointer<Float>]
    private let maxFrames: UInt32
    private var sampleTime: Float64 = 0

    /// `ioFrames` is the device IO buffer size the real path would negotiate (sizes staging
    /// exactly like `start()` does from `kAudioDevicePropertyBufferFrameSize`).
    public init(engine: SpatialEngine, path: OfflinePath, sampleRate: Double, ioFrames: UInt32) throws {
        self.engine = engine
        self.path = path
        self.sampleRate = sampleRate
        try engine.startOffline(path: path, sampleRate: sampleRate, ioFrames: ioFrames)
        guard let ctx = engine.ctx else { throw SpatialEngineError.setupFailed("offline ctx") }
        inputChannels = ctx.channels
        maxFrames = max(ioFrames * 2, 4096)
        if path == .unifiedTap {
            inABL = AudioBufferList.allocate(maximumBuffers: 1)
            outABL = AudioBufferList.allocate(maximumBuffers: 1)
            outPlanes = []
        } else {
            inABL = AudioBufferList.allocate(maximumBuffers: 1)   // unused
            outABL = AudioBufferList.allocate(maximumBuffers: 2)
            var planes: [UnsafeMutablePointer<Float>] = []
            for c in 0..<2 {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
                p.initialize(repeating: 0, count: Int(maxFrames))
                planes.append(p)
                outABL[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: p)
            }
            outPlanes = planes
        }
    }

    deinit {
        engine.stop()
        free(inABL.unsafeMutablePointer)
        free(outABL.unsafeMutablePointer)
        for p in outPlanes { p.deallocate() }
    }

    /// Render one IO cycle: `input` = `frames` × `inputChannels` interleaved Float32,
    /// `output` = `frames` × 2 interleaved Float32 (binaural L/R).
    @discardableResult
    public func render(input: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>,
                       frames n: UInt32) -> OSStatus {
        guard let ctx = engine.ctx else { return -1 }
        let ctxPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        sampleTime += Float64(n)
        if path == .unifiedTap {
            inABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: n * 8, mData: input)
            outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: n * 8, mData: output)
            return withUnsafePointer(to: &ts) { t in
                unifiedTapCallback(0, t, inABL.unsafeMutablePointer, t, outABL.unsafeMutablePointer, t, ctxPtr)
            }
        }
        // Loopback: the capture AUHAL would deliver planar capture-rate frames into
        // ctx.captureABL; emulate that de-interleave, then run the shared capture post-
        // processing and the playback pull exactly as the two HAL threads would.
        guard let cap = ctx.captureABL, n <= ctx.captureBufSize else { return -1 }
        let ch = ctx.channels
        let count = Int(n)
        for c in 0..<ch {
            let dst = cap[c].mData!.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < count { dst[i] = input[i * ch + c]; i += 1 }
            cap[c].mDataByteSize = n * 4
        }
        processCapturedBlock(ctx, abl: cap, frames: n)
        outABL[0].mDataByteSize = n * 4
        outABL[1].mDataByteSize = n * 4
        var flags = AudioUnitRenderActionFlags()
        let st = withUnsafePointer(to: &ts) { t in
            playbackRenderCallback(ctxPtr, &flags, t, 0, n, outABL.unsafeMutablePointer)
        }
        let l = outPlanes[0], r = outPlanes[1]
        var i = 0
        while i < count { output[2 * i] = l[i]; output[2 * i + 1] = r[i]; i += 1 }
        return st
    }
}

extension SpatialEngine {
    /// Offline twin of `start()`: same Ctx sizing, same mixer factory, no devices.
    func startOffline(path: OfflinePath, sampleRate: Double, ioFrames: UInt32) throws {
        guard !isRunning else { return }
        seLog = logger
        let unifiedTap = (path == .unifiedTap)
        let effectiveMode = Self.effectiveSourceMode(config.sourceMode, unifiedTap: unifiedTap)
        activeSourceMode = effectiveMode
        let captureChannels = (config.spatialize && !unifiedTap) ? effectiveMode.captureChannels : 2
        let ctx = Ctx(channels: captureChannels)
        self.ctx = ctx
        let ctxPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())
        var playMax: UInt32 = 4096
        if unifiedTap {
            let maxF = max(ioFrames * 2, ioFrames * 2, 4096)
            playMax = maxF
            ctx.captureBufSize = maxF
            ctx.unifiedLayout = .defaultStereoInterleaved
            ctx.captureABL = makeCaptureABL(maxFrames: maxF, channels: 2)
            ctx.unifiedOutputABL = makeCaptureABL(maxFrames: maxF, channels: 2)
        } else {
            // AUHAL's MaximumFramesPerSlice default.
            let maxF = max(ioFrames * 2, 4096)
            ctx.captureABL = makeCaptureABL(maxFrames: maxF, channels: captureChannels)
            ctx.captureBufSize = maxF
            playMax = maxF
        }
        if config.spatialize {
            guard installSpatialMixer(ctx: ctx, ctxPtr: ctxPtr, mode: effectiveMode,
                                      captureChannels: captureChannels, captureRate: sampleRate,
                                      outputRate: unifiedTap ? sampleRate : 48_000, playMax: playMax) else {
                teardown(); throw SpatialEngineError.setupFailed("spatial mixer")
            }
        }
        if !unifiedTap {
            ctx.ring.prefill(frames: UInt64(2 * ioFrames))
            ctx.ring.driftLow  = UInt64(ioFrames)
            ctx.ring.driftHigh = UInt64(3 * ioFrames)
            ctx.ring.driftEnabled = true
        }
        isRunning = true
    }

    /// Bench-only: emulate AirPods head-tracking load by driving the mixer's global head
    /// orientation params (the OS-fed tracker applies the same kind of rotation, 3111).
    @_spi(Bench) public func benchSetHeadPose(yaw: Float, pitch: Float, roll: Float) {
        guard let mixer = ctx?.spatialMixer else { return }
        AudioUnitSetParameter(mixer, 19, kAudioUnitScope_Global, 0, yaw, 0)
        AudioUnitSetParameter(mixer, 20, kAudioUnitScope_Global, 0, pitch, 0)
        AudioUnitSetParameter(mixer, 21, kAudioUnitScope_Global, 0, roll, 0)
    }
}
