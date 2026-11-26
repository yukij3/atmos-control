// SpatialEngine — public API. Drives the proven capture → AUSpatialMixer →
// output graph; consumed by both the AtmosDaemon CLI and the SwiftUI app.
//
// Threading: callers must serialize lifecycle calls (start/stop/reconfigure) and live
// parameter/telemetry calls (pollState/updateSource/updateReverb) so they never overlap.
// The real-time HAL threads touch only the internal Ctx.

import CoreAudio
import AudioToolbox
import Dispatch
import Synchronization

// MARK: - Public config types

public enum OutputType: UInt32, CaseIterable, Sendable, Identifiable {
    case headphones = 1, builtInSpeakers = 2, externalSpeakers = 3
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .headphones: return "Headphones"
        case .builtInSpeakers: return "Built-in Speakers"
        case .externalSpeakers: return "External Speakers"
        }
    }
    /// Compact form for the menu-bar panel's segmented control, where the full
    /// labels overflow the fixed 332pt width and clip past the popover edges.
    public var shortLabel: String {
        switch self {
        case .headphones: return "Headphones"
        case .builtInSpeakers: return "Built-in"
        case .externalSpeakers: return "External"
        }
    }
}

public enum HRTFMode: UInt32, CaseIterable, Sendable, Identifiable {
    case off = 0, on = 1, auto = 2
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self { case .off: return "Off"; case .on: return "On"; case .auto: return "Auto" }
    }
}

public enum SpatAlgorithm: UInt32, CaseIterable, Sendable, Identifiable {
    case hrtf = 2, hrtfHQ = 6, useOutputType = 7
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self { case .hrtf: return "HRTF"; case .hrtfHQ: return "HRTF HQ"; case .useOutputType: return "Use Output Type" }
    }
}

public enum AttenuationCurve: UInt32, CaseIterable, Sendable, Identifiable {
    case power = 0, exponential = 1, inverse = 2, linear = 3
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .power: return "Power"; case .exponential: return "Exponential"
        case .inverse: return "Inverse"; case .linear: return "Linear"
        }
    }
}

public enum ReverbRoomType: UInt32, CaseIterable, Sendable, Identifiable {
    // rawValue maps directly to kReverbRoomType_SmallRoom / MediumRoom / LargeRoom.
    case small = 0, medium = 1, large = 2
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self { case .small: return "Small"; case .medium: return "Medium"; case .large: return "Large" }
    }
}

public enum SourceRenderMode: String, CaseIterable, Sendable, Identifiable {
    case dualPointStereo, ambienceBedStereo, pointSourceMono, surround714, surroundBed714
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .dualPointStereo:   return "Stereo Points"
        case .ambienceBedStereo: return "Stereo Bed"
        case .pointSourceMono:   return "Mono Point"
        case .surround714:       return "Surround 7.1.4"
        case .surroundBed714:    return "Surround Bed 7.1.4"
        }
    }
    var isBed: Bool { self == .ambienceBedStereo || self == .surroundBed714 }
    var isSurroundBed: Bool { self == .surroundBed714 }
    var isSurround: Bool { self == .surround714 }        // 12 mono buses (11 point + LFE bypass)
    var isDualPoint: Bool { self == .dualPointStereo }
    /// True for 12-channel 7.1.4 modes (supported only by the 12-channel loopback driver).
    public var isSurroundMode: Bool { self == .surround714 || self == .surroundBed714 }
    /// Stereo and mono modes supported by 2-channel capture paths (including Personalized tap).
    public static let stereoModes: [SourceRenderMode] = [.dualPointStereo, .ambienceBedStereo, .pointSourceMono]
    /// Ring / capture channel count required for this mode.
    var captureChannels: Int { (self == .surround714 || self == .surroundBed714) ? kAtmos714Channels : 2 }
    var inputBusCount: UInt32 {
        switch self {
        case .dualPointStereo: return 2
        case .surround714:     return UInt32(kAtmos714Channels)
        default:               return 1
        }
    }
    var channelsPerBus: UInt32 {
        switch self {
        case .ambienceBedStereo: return 2
        case .surroundBed714:    return UInt32(kAtmos714Channels)
        default:                 return 1                // dualPoint, mono point, surround714 (per-bus mono)
        }
    }
}

public struct SpatialConfig: Sendable, Equatable {
    public var spatialize: Bool = true                 // false = direct passthrough (debug)
    public var sourceMode: SourceRenderMode = .dualPointStereo
    public var outputType: OutputType = .headphones
    public var hrtfMode: HRTFMode = .auto
    public var algorithm: SpatAlgorithm = .useOutputType
    public var headTracking: Bool = true
    public var azimuth: Float = 0      // ±180°
    public var elevation: Float = 0    // ±90°
    public var distance: Float = 1.0   // metres
    public var gain: Float = 0         // dB
    public var stereoWidth: Float = 30 // ± spread (°) of the two dualPoint virtual speakers
    // Distance rendering (r2): loudness is distance-invariant by default (ITD only).
    public var interauralDelay: Bool = true
    public var distanceAttenuation: Bool = false
    public var attenuationCurve: AttenuationCurve = .inverse
    public var distanceRef: Float = 1.0
    public var distanceMax: Float = 6.0
    public var distanceMaxAtten: Float = 40.0   // dB, only when distanceAttenuation is on
    // Internal reverb (r1): only audible under HRTF/HRTF-HQ; inert under Use Output Type.
    public var reverbEnabled: Bool = true
    public var reverbRoomType: ReverbRoomType = .medium
    public var reverbBlend: Float = 20          // percent 0…100 (per input bus)
    public var globalReverbGain: Float = -3     // dB
    public init() {}
}

public struct AudioOutputDevice: Identifiable, Sendable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let isAirPods: Bool
}

public struct EngineState: Sendable, Equatable {
    public var running = false
    public var outputDeviceName = ""
    public var personalizedHRTFEngaged = false   // property 3116
    public var peakL: Float = 0                   // linear 0…1, peak since last poll
    public var peakR: Float = 0
    /// Per-capture-channel peaks (linear 0…1) since last poll. 2 entries in stereo
    /// modes, 12 in surround 7.1.4 (Atmos_7_1_4 channel order). peakL/peakR mirror [0]/[1].
    public var peaks: [Float] = []
    public var ringFill: UInt64 = 0
    public var totalCaptured: UInt64 = 0          // rising ⇒ audio is flowing in
    public var totalPlayed: UInt64 = 0
    public init() {}
}

public enum SpatialEngineError: Error, CustomStringConvertible {
    case atmosDeviceNotFound, noOutputDevice, setupFailed(String)
    public var description: String {
        switch self {
        case .atmosDeviceNotFound: return "atmos-control loopback device not found (is the HAL driver installed?)"
        case .noOutputDevice: return "no real output device available"
        case .setupFailed(let s): return "audio setup failed: \(s)"
        }
    }
}

// MARK: - Engine

public final class SpatialEngine: @unchecked Sendable {
    public internal(set) var isRunning = false
    public var config = SpatialConfig()
    /// Optional setup logger (verbose property-set trace). nil = silent.
    public var logger: ((String) -> Void)? = nil
    /// Fired on the main queue when the active capture or output device changes its nominal
    /// sample rate or stream channel layout while running. The engine never rebuilds itself
    /// on a private queue; the owner serializes any rebuild or teardown on its own queue.
    public var onFormatChange: (() -> Void)? = nil
    /// Skip AUSpatialMixer renders while the input is digital silence and the mixer output
    /// has decayed to exact zero (bit-identical output; see Ctx). Benchmark/diagnostic switch,
    /// read at start(). Not public API.
    @_spi(Bench) public var idleBypassEnabled = true

    var ctx: Ctx?                              // internal: shared with the offline bench harness
    private var outputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var startedCaptureID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)  // capture device resolved at start()
    var activeSourceMode: SourceRenderMode = .dualPointStereo
    private let activeUnifiedDeviceID = Atomic<UInt32>(UInt32(kAudioObjectUnknown))
    private let sessionToken = Atomic<UInt64>(0)
    private var formatListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cachedOutputName = ""        // device name only changes on start / sink-swap
    private var pollTick = 0                  // downsample the 3116 HAL read
    private var cached3116 = false

    public init() {}

    /// Effective render mode for the active capture path. The unified process-tap path always
    /// captures stereo/mono (2 staging channels), so 12-channel surround modes clamp to stereo.
    static func effectiveSourceMode(_ mode: SourceRenderMode, unifiedTap: Bool) -> SourceRenderMode {
        (unifiedTap && mode.isSurroundMode) ? .dualPointStereo : mode
    }

    // MARK: Device discovery

    /// True when the atmos-control virtual HAL device is present.
    public func atmosControlPresent() -> Bool { findAtmosControlDevice() != nil }

    /// Channel count reported by the atmos-control loopback (0 = not installed). The 12-channel
    /// surround driver reports 12; the legacy stereo driver reports 2. Lets the UI offer (or
    /// disable) the Surround 7.1.4 capture option honestly.
    public func atmosControlChannelCount() -> Int {
        guard let atmos = findAtmosControlDevice() else { return 0 }
        return max(deviceChannelCount(atmos, scope: kAudioObjectPropertyScopeOutput),
                   deviceChannelCount(atmos, scope: kAudioObjectPropertyScopeInput))
    }

    /// True when the installed loopback exposes the full 7.1.4 (≥12) channel surface.
    public func surroundDriverInstalled() -> Bool { atmosControlChannelCount() >= kAtmos714Channels }

    /// Output-capable devices, excluding the loopback driver and any active tap aggregate.
    public func outputDevices() -> [AudioOutputDevice] {
        let atmos = findAtmosControlDevice()
        let activeUnified = AudioDeviceID(activeUnifiedDeviceID.load(ordering: .acquiring))
        var out: [AudioOutputDevice] = []
        for id in allDeviceIDs() where id != atmos && id != activeUnified
            && deviceName(id) != "atmos-control-tap"
            && deviceHasChannels(id, scope: kAudioObjectPropertyScopeOutput) {
            let name = deviceName(id)
            out.append(AudioOutputDevice(id: id, name: name, isAirPods: name.localizedCaseInsensitiveContains("airpods")))
        }
        return out
    }

    // MARK: Default-output routing (no entitlement)

    public static func currentDefaultOutput() -> (id: AudioDeviceID, name: String) {
        let id = defaultOutputDeviceID()
        return (id, deviceName(id))
    }

    @discardableResult
    public static func setDefaultOutput(_ id: AudioDeviceID, includeSystem: Bool = true) -> Bool {
        let a = setDefaultOutputDeviceID(id, system: false)
        let b = includeSystem ? setDefaultOutputDeviceID(id, system: true) : noErr
        return a == noErr && b == noErr
    }

    public static func atmosControlDeviceID() -> AudioDeviceID? { findAtmosControlDevice() }

    // MARK: Lifecycle

    /// Build + start the graph. `outputDeviceID` is the *real* sink (e.g. AirPods);
    /// nil resolves the current default output (when it isn't atmos-control).
    /// Build + start the graph. `outputDeviceID` is the real sink (nil = current default).
    /// `captureDeviceID` overrides the capture source (nil = the atmos-control loopback);
    /// the process-tap path passes a tap aggregate here to keep AirPods the default.
    public func start(outputDeviceID requested: AudioDeviceID? = nil, captureDeviceID: AudioDeviceID? = nil) throws {
        guard !isRunning else { return }
        seLog = logger

        let captureID: AudioDeviceID
        if let c = captureDeviceID, c != AudioDeviceID(kAudioObjectUnknown) {
            captureID = c
        } else {
            guard let atmosID = findAtmosControlDevice() else { throw SpatialEngineError.atmosDeviceNotFound }
            captureID = atmosID
        }
        startedCaptureID = captureID   // remember so reconfigure()'s rebuild keeps the same capture source
        let isLoopbackCapture = (captureID == findAtmosControlDevice())
        let unifiedTap = !isLoopbackCapture && deviceHasChannels(captureID, scope: kAudioObjectPropertyScopeOutput)
        let outID: AudioDeviceID
        if unifiedTap {
            outID = try resolveUnifiedOutput(requested: requested, aggregateID: captureID)
        } else {
            outID = try resolveOutput(requested: requested, atmosID: captureID)
        }
        outputDeviceID = outID
        cachedOutputName = deviceName(outID)
        pollTick = 0; cached3116 = false
        guard let captureRate = deviceNominalSampleRate(captureID) else {
            throw SpatialEngineError.setupFailed("capture nominal sample rate unreadable")
        }
        selog("Capture device : [\(captureID)] \(deviceName(captureID)) @ \(Int(captureRate)) Hz")
        selog("Playback device: [\(outID)] \(deviceName(outID))")

        // Surround modes capture 12ch from the 7.1.4 loopback; unified tap always stages stereo.
        let effectiveMode = Self.effectiveSourceMode(config.sourceMode, unifiedTap: unifiedTap)
        activeSourceMode = effectiveMode
        let captureChannels = (config.spatialize && !unifiedTap) ? effectiveMode.captureChannels : 2
        let ctx = Ctx(channels: captureChannels)
        self.ctx = ctx
        let ctxPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())

        var playMax: UInt32 = 4096
        if unifiedTap {
            let inputChannels = deviceStreamChannelCounts(captureID, scope: kAudioObjectPropertyScopeInput)
            let physicalInputCount = deviceStreamChannelCounts(outID, scope: kAudioObjectPropertyScopeInput).count
            let outputChannels = deviceStreamChannelCounts(captureID, scope: kAudioObjectPropertyScopeOutput)
            guard let inputFormats = deviceStreamVirtualFormats(captureID, scope: kAudioObjectPropertyScopeInput),
                  let outputFormats = deviceStreamVirtualFormats(captureID, scope: kAudioObjectPropertyScopeOutput) else {
                teardown()
                throw SpatialEngineError.setupFailed("unable to read aggregate stream virtual formats")
            }
            let layout: UnifiedBufferLayout
            do {
                layout = try UnifiedBufferLayout.resolve(
                    inputChannels: inputChannels,
                    physicalInputCount: physicalInputCount,
                    outputChannels: outputChannels,
                    inputFormats: inputFormats,
                    outputFormats: outputFormats
                )
            } catch {
                teardown()
                throw error
            }
            let maxF = max(deviceBufferFrameSize(outID) * 2, deviceBufferFrameSize(captureID) * 2, 4096)
            playMax = maxF
            ctx.captureBufSize = maxF
            ctx.unifiedLayout = layout
            ctx.captureABL = makeCaptureABL(maxFrames: maxF, channels: 2)
            ctx.unifiedOutputABL = makeCaptureABL(maxFrames: maxF, channels: 2)
        } else {
            // --- Capture unit (atmos-control → ring) ---
            guard let captureUnit = makeHALOutputUnit() else { throw SpatialEngineError.setupFailed("capture unit") }
            ctx.captureUnit = captureUnit
            setEnableIO(captureUnit, enable: 0, scope: kAudioUnitScope_Output, element: 0, label: "capture")
            setEnableIO(captureUnit, enable: 1, scope: kAudioUnitScope_Input, element: 1, label: "capture")
            setCurrentDevice(captureUnit, deviceID: captureID, label: "capture")
            var capFmt = captureChannels == 2 ? stereoFloat32Format(sampleRate: captureRate)
                                              : makeFloatASBD(channels: UInt32(captureChannels), sampleRate: captureRate)
            guard setStreamFormat(captureUnit, fmt: &capFmt, scope: kAudioUnitScope_Output, element: 1, label: "capture") else {
                teardown(); throw SpatialEngineError.setupFailed("capture stream format")
            }
            var maxFrames: UInt32 = 4096; var mfSize = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(captureUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &mfSize)
            ctx.captureABL = makeCaptureABL(maxFrames: maxFrames, channels: captureChannels)
            ctx.captureBufSize = maxFrames
            var inputCB = AURenderCallbackStruct(inputProc: captureInputCallback, inputProcRefCon: ctxPtr)
            check(AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "capture SetInputCallback")
            guard check(AudioUnitInitialize(captureUnit), "capture AudioUnitInitialize") else {
                teardown(); throw SpatialEngineError.setupFailed("capture init")
            }

            // --- Playback unit (ring/mixer → real output) ---
            guard let playbackUnit = makeHALOutputUnit() else { teardown(); throw SpatialEngineError.setupFailed("playback unit") }
            ctx.playbackUnit = playbackUnit
            setEnableIO(playbackUnit, enable: 1, scope: kAudioUnitScope_Output, element: 0, label: "playback")
            setEnableIO(playbackUnit, enable: 0, scope: kAudioUnitScope_Input, element: 1, label: "playback")
            setCurrentDevice(playbackUnit, deviceID: outID, label: "playback")
            // Spatialize: mixer output is 48 kHz. Passthrough: the ring holds capture-rate
            // frames, so the playback input runs at captureRate and the AUHAL output-side
            // converter resamples to the sink.
            var playFmt = stereoFloat32Format(sampleRate: config.spatialize ? 48_000 : captureRate)
            guard setStreamFormat(playbackUnit, fmt: &playFmt, scope: kAudioUnitScope_Input, element: 0, label: "playback") else {
                teardown(); throw SpatialEngineError.setupFailed("playback stream format")
            }
            var pmSize = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(playbackUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &playMax, &pmSize)
        }

        // --- Spatial mixer ---
        if config.spatialize {
            guard installSpatialMixer(ctx: ctx, ctxPtr: ctxPtr, mode: effectiveMode,
                                      captureChannels: captureChannels, captureRate: captureRate,
                                      outputRate: unifiedTap ? captureRate : 48_000, playMax: playMax) else {
                teardown(); throw SpatialEngineError.setupFailed("spatial mixer")
            }
        }

        if unifiedTap {
            ctx.unifiedDeviceID = captureID
            activeUnifiedDeviceID.store(UInt32(captureID), ordering: .releasing)
            var proc: AudioDeviceIOProcID?
            guard check(AudioDeviceCreateIOProcID(captureID, unifiedTapCallback, ctxPtr, &proc), "unified CreateIOProc"),
                  let proc else { teardown(); throw SpatialEngineError.setupFailed("unified IOProc") }
            ctx.unifiedIOProc = proc
            if ctx.unifiedLayout.totalInputStreams > 0 {
                // Fatal: if this fails the physical mic stream stays enabled, which flips
                // AirPods into the call (HFP) profile for the whole session.
                guard check(setIOProcStreamUsage(
                    captureID,
                    proc: proc,
                    scope: kAudioObjectPropertyScopeInput,
                    enabledStreams: Set(ctx.unifiedLayout.enabledInputStreams),
                    totalStreams: ctx.unifiedLayout.totalInputStreams
                ), "unified Input IOProcStreamUsage") else {
                    teardown(); throw SpatialEngineError.setupFailed("unified input stream usage")
                }
            }
            guard check(AudioDeviceStart(captureID, proc), "unified Start") else {
                teardown(); throw SpatialEngineError.setupFailed("unified start")
            }
            let token = sessionToken.wrappingAdd(1, ordering: .releasing).newValue
            installFormatListeners(captureID: captureID, outputID: outID, rate: captureRate, token: token,
                                   maxFrames: ctx.captureBufSize)
            isRunning = true
            return
        }
        guard let captureUnit = ctx.captureUnit, let playbackUnit = ctx.playbackUnit else {
            teardown(); throw SpatialEngineError.setupFailed("missing legacy units")
        }

        var renderCB = AURenderCallbackStruct(inputProc: playbackRenderCallback, inputProcRefCon: ctxPtr)
        check(AudioUnitSetProperty(playbackUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &renderCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "playback SetRenderCallback")
        guard check(AudioUnitInitialize(playbackUnit), "playback AudioUnitInitialize") else {
            teardown(); throw SpatialEngineError.setupFailed("playback init")
        }

        // Prime the ring + arm the fill-target controller before the RT threads start.
        let bufFrames = deviceBufferFrameSize(outID)
        ctx.ring.prefill(frames: UInt64(2 * bufFrames))
        if isLoopbackCapture {
            // Legacy loopback: virtual-driver host clock vs sink clock drift → hold the fill
            // inside ~1…3 device buffers. The unified process tap returned above.
            ctx.ring.driftLow  = UInt64(bufFrames)
            ctx.ring.driftHigh = UInt64(3 * bufFrames)
            ctx.ring.driftEnabled = true
        }

        guard check(AudioOutputUnitStart(captureUnit), "captureUnit Start"),
              check(AudioOutputUnitStart(playbackUnit), "playbackUnit Start") else {
            teardown(); throw SpatialEngineError.setupFailed("unit start")
        }
        let token = sessionToken.wrappingAdd(1, ordering: .releasing).newValue
        installFormatListeners(captureID: captureID, outputID: outID, rate: captureRate, token: token)
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
    }

    /// Build + publish the AUSpatialMixer and its staging buffers into `ctx`. Shared by
    /// `start()` and the offline bench harness so both render through the same graph.
    func installSpatialMixer(ctx: Ctx, ctxPtr: UnsafeMutableRawPointer, mode: SourceRenderMode,
                             captureChannels: Int, captureRate: Double, outputRate: Double,
                             playMax: UInt32) -> Bool {
        let spatialMax = max(playMax, ctx.captureBufSize, 4096)
        ctx.spatialBed = (mode == .ambienceBedStereo)
        ctx.spatialDualPoint = mode.isDualPoint
        ctx.spatialSurround = mode.isSurround
        ctx.spatialSurroundBed = mode.isSurroundBed
        var renderFlags: UInt32 = 0
        if config.interauralDelay { renderFlags |= kRenderFlagInterAuralDelay }
        if config.distanceAttenuation { renderFlags |= kRenderFlagDistanceAtten }
        let dp = DistanceParams(referenceDistance: config.distanceRef,
                                maxDistance: config.distanceMax,
                                maxAttenuation: config.distanceMaxAtten)
        guard let mixer = makeSpatialMixer(
            ctxPtr: ctxPtr, maxFrames: spatialMax, mode: mode,
            algo: config.algorithm.rawValue, algoName: config.algorithm.label,
            outputType: config.outputType.rawValue, outputTypeName: config.outputType.label,
            hrtfMode: config.hrtfMode.rawValue, hrtfModeName: config.hrtfMode.label,
            headTrack: config.headTracking ? 1 : 0,
            inputSampleRate: captureRate,
            outputSampleRate: outputRate,
            renderFlags: renderFlags, distanceParams: dp,
            attenCurve: config.attenuationCurve.rawValue,
            reverbEnabled: reverbActive, reverbRoomType: config.reverbRoomType.rawValue) else {
            return false
        }
        let dmL = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
        let dmR = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
        dmL.initialize(repeating: 0, count: Int(spatialMax))
        dmR.initialize(repeating: 0, count: Int(spatialMax))
        ctx.dmL = dmL; ctx.dmR = dmR
        // Surround staging: one plane per capture channel, filled once per render cycle.
        if mode.isSurround || mode.isSurroundBed {
            let stage = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: captureChannels)
            var c = 0
            while c < captureChannels {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: Int(spatialMax))
                p.initialize(repeating: 0, count: Int(spatialMax))
                stage[c] = p
                c += 1
            }
            ctx.stage = stage
            ctx.stageChannels = captureChannels
        }
        ctx.spatialMaxFrames = spatialMax
        // Idle bypass: skip the mixer after 250 ms of exact-zero in AND out (longer than the
        // HRTF FIR; the reverb tail must reach exact zero first). Resume primes ~85-100 ms.
        ctx.idleBypassEnabled = idleBypassEnabled
        ctx.idleHoldFrames = UInt64(outputRate * 0.25)
        ctx.idleCatchUpFrames = min(spatialMax, UInt32(outputRate * 0.1))
        ctx.scratchABL = makeCaptureABL(maxFrames: spatialMax, channels: 2)
        ctx.spatialMixer = mixer
        applySourceParams(mixer: mixer, mode: mode)
        applyReverbParams(mixer: mixer, mode: mode)
        ctx.seenParamEpoch = ctx.paramEpoch.load(ordering: .relaxed)
        ctx.spatialize = true   // publish last
        return true
    }

    private func resolveUnifiedOutput(requested: AudioDeviceID?, aggregateID: AudioDeviceID) throws -> AudioDeviceID {
        let mainID = aggregateMainSubDeviceUID(aggregateID).flatMap { deviceID(forUID: $0) }
        if let r = requested, r != AudioDeviceID(kAudioObjectUnknown) {
            if let mainID, r != mainID {
                throw SpatialEngineError.setupFailed("requested outputDeviceID (\(r)) does not match tap aggregate main subdevice (\(mainID))")
            }
            guard r != aggregateID, deviceHasChannels(r, scope: kAudioObjectPropertyScopeOutput) else {
                throw SpatialEngineError.noOutputDevice
            }
            return r
        }
        if let mainID, mainID != aggregateID, deviceHasChannels(mainID, scope: kAudioObjectPropertyScopeOutput) {
            return mainID
        }
        return try resolveOutput(requested: nil, atmosID: aggregateID)
    }

    private func resolveOutput(requested: AudioDeviceID?, atmosID: AudioDeviceID) throws -> AudioDeviceID {
        if let r = requested, r != atmosID, deviceHasChannels(r, scope: kAudioObjectPropertyScopeOutput) { return r }
        let def = defaultOutputDeviceID()
        if def != AudioDeviceID(kAudioObjectUnknown), def != atmosID,
           deviceHasChannels(def, scope: kAudioObjectPropertyScopeOutput) { return def }
        if let first = outputDevices().first { return first.id }
        throw SpatialEngineError.noOutputDevice
    }

    func teardown() {
        _ = sessionToken.wrappingAdd(1, ordering: .releasing)
        removeFormatListeners()
        activeUnifiedDeviceID.store(UInt32(kAudioObjectUnknown), ordering: .releasing)
        guard let ctx else { return }
        if let proc = ctx.unifiedIOProc { AudioDeviceStop(ctx.unifiedDeviceID, proc) }
        if let c = ctx.captureUnit { AudioOutputUnitStop(c) }
        if let p = ctx.playbackUnit { AudioOutputUnitStop(p) }
        if let proc = ctx.unifiedIOProc { AudioDeviceDestroyIOProcID(ctx.unifiedDeviceID, proc); ctx.unifiedIOProc = nil }
        if let m = ctx.spatialMixer { AudioUnitUninitialize(m); AudioComponentInstanceDispose(m); ctx.spatialMixer = nil }
        if let c = ctx.captureUnit { AudioUnitUninitialize(c); AudioComponentInstanceDispose(c); ctx.captureUnit = nil }
        if let p = ctx.playbackUnit { AudioUnitUninitialize(p); AudioComponentInstanceDispose(p); ctx.playbackUnit = nil }
        ctx.dmL?.deallocate(); ctx.dmL = nil
        ctx.dmR?.deallocate(); ctx.dmR = nil
        if let stage = ctx.stage {
            var c = 0
            while c < ctx.stageChannels { stage[c].deallocate(); c += 1 }
            stage.deallocate()
            ctx.stage = nil; ctx.stageChannels = 0
        }
        if let abl = ctx.captureABL {
            for ch in 0..<abl.count { abl[ch].mData?.deallocate() }
            free(abl.unsafeMutablePointer)
            ctx.captureABL = nil
        }
        if let abl = ctx.unifiedOutputABL {
            for ch in 0..<abl.count { abl[ch].mData?.deallocate() }
            free(abl.unsafeMutablePointer)
            ctx.unifiedOutputABL = nil
        }
        if let abl = ctx.scratchABL {
            for ch in 0..<abl.count { abl[ch].mData?.deallocate() }
            free(abl.unsafeMutablePointer)
            ctx.scratchABL = nil
        }
        self.ctx = nil
    }

    // MARK: Format-change listeners

    /// `maxFrames` (unified path only) is the staging capacity the IOProc was sized for: if the
    /// device IO buffer grows past it the callback can only emit silence, so that counts as a
    /// format change and triggers a rebuild with larger buffers.
    private func installFormatListeners(captureID: AudioDeviceID, outputID: AudioDeviceID, rate captureRate: Double,
                                        token: UInt64, maxFrames: UInt32? = nil) {
        let initialOutRate = deviceNominalSampleRate(outputID)
        let initialCapIn = deviceStreamChannelCounts(captureID, scope: kAudioObjectPropertyScopeInput)
        let initialCapOut = deviceStreamChannelCounts(captureID, scope: kAudioObjectPropertyScopeOutput)
        let initialOut = deviceStreamChannelCounts(outputID, scope: kAudioObjectPropertyScopeOutput)

        let notifyIfChanged: @Sendable () -> Void = { [weak self] in
            guard let self, self.sessionToken.load(ordering: .acquiring) == token else { return }
            let capRate = deviceNominalSampleRate(captureID)
            let outRate = deviceNominalSampleRate(outputID)
            let capRateChanged = (capRate != nil && abs(capRate! - captureRate) >= 0.5)
            let outRateChanged = (initialOutRate != nil && outRate != nil && abs(outRate! - initialOutRate!) >= 0.5)
            let layoutChanged = deviceStreamChannelCounts(captureID, scope: kAudioObjectPropertyScopeInput) != initialCapIn
                || deviceStreamChannelCounts(captureID, scope: kAudioObjectPropertyScopeOutput) != initialCapOut
                || deviceStreamChannelCounts(outputID, scope: kAudioObjectPropertyScopeOutput) != initialOut
            let bufferOutgrown = maxFrames.map {
                max(deviceBufferFrameSize(captureID), deviceBufferFrameSize(outputID)) > $0
            } ?? false
            guard capRateChanged || outRateChanged || layoutChanged || bufferOutgrown else { return }
            self.onFormatChange?()
        }

        let block: AudioObjectPropertyListenerBlock = { _, _ in notifyIfChanged() }

        func add(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) {
            guard device != AudioDeviceID(kAudioObjectUnknown) else { return }
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, block) == noErr {
                formatListeners.append((device, addr, block))
            }
        }

        for dev in Set([captureID, outputID]) {
            add(dev, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
            add(dev, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
            if maxFrames != nil {
                add(dev, selector: kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal)
            }
        }
        add(captureID, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    }

    private func removeFormatListeners() {
        for (device, addr, block) in formatListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, DispatchQueue.main, block)
        }
        formatListeners.removeAll()
    }

    // MARK: Live state + params

    /// Read+reset the peak meters and poll the live engine state. Call ~30 Hz.
    public func pollState() -> EngineState {
        var s = EngineState()
        s.running = isRunning
        guard isRunning, let ctx else { return s }
        s.outputDeviceName = cachedOutputName            // cached: no per-tick CFString HAL fetch
        // Read+reset per-channel peaks off the RT thread (main-thread array build is fine).
        var pk = [Float](repeating: 0, count: ctx.channels)
        var c = 0
        while c < ctx.channels { pk[c] = ctx.capturePeaks[c]; ctx.capturePeaks[c] = 0; c += 1 }
        s.peaks = pk
        s.peakL = pk.count > 0 ? pk[0] : 0
        s.peakR = pk.count > 1 ? pk[1] : 0
        s.ringFill = ctx.ring.fill()
        s.totalCaptured = ctx.totalCaptured
        s.totalPlayed = ctx.totalPlayed
        // 3116 only changes on reconfigure/device-change — read it ~1 Hz, not every tick.
        if let mixer = ctx.spatialMixer {
            if pollTick % 15 == 0 {
                var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
                if AudioUnitGetProperty(mixer, kPropAnyInputUsingPersonalizedHRTF, kAudioUnitScope_Global, 0, &v, &sz) == noErr {
                    cached3116 = (v != 0)
                }
            }
            s.personalizedHRTFEngaged = cached3116
        }
        pollTick &+= 1
        return s
    }

    /// Read property 3116 fresh (un-downsampled) — for the process-tap spike's 1 Hz loop.
    public func readPersonalizedHRTFEngaged() -> Bool {
        guard isRunning, let mixer = ctx?.spatialMixer else { return false }
        var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(mixer, kPropAnyInputUsingPersonalizedHRTF, kAudioUnitScope_Global, 0, &v, &sz) == noErr {
            return v != 0
        }
        return false
    }

    /// Live-update the source position/gain (safe while running; AudioUnitSetParameter).
    public func updateSource(azimuth: Float? = nil, elevation: Float? = nil, distance: Float? = nil,
                             gain: Float? = nil, width: Float? = nil) {
        if let a = azimuth { config.azimuth = a }
        if let e = elevation { config.elevation = e }
        if let d = distance { config.distance = min(max(d, 0.35), config.distanceMax) }
        if let g = gain { config.gain = g }
        if let w = width { config.stereoWidth = w }
        if let mixer = ctx?.spatialMixer { applySourceParams(mixer: mixer, mode: activeSourceMode) }
    }

    /// Live-update the internal reverb wet/dry blend + gain (no-op unless the reverb
    /// path is active — see reverbActive). Safe while running.
    public func updateReverb(blend: Float? = nil, gain: Float? = nil) {
        if let b = blend { config.reverbBlend = b }
        if let g = gain { config.globalReverbGain = g }
        if let mixer = ctx?.spatialMixer { applyReverbParams(mixer: mixer, mode: activeSourceMode) }
    }

    /// Tell the RT thread a live mixer param changed so an idle-bypassed mixer renders
    /// again and the change ramps exactly as it would have (see Ctx idle-bypass fields).
    /// Bump AFTER the AudioUnitSetParameter calls.
    func noteMixerParamsChanged() {
        ctx?.paramEpoch.wrappingAdd(1, ordering: .releasing)
    }

    /// The internal reverb wet path only renders under HRTF/HRTF-HQ; under
    /// Use Output Type it is inert and ReverbBlend would only attenuate the dry path.
    var reverbActive: Bool { config.reverbEnabled && config.algorithm != .useOutputType }

    private func applySourceParams(mixer: AudioUnit, mode: SourceRenderMode) {
        defer { noteMixerParamsChanged() }
        // Below ~0.2 m the UseOutputType renderer collapses the stereo image back into
        // the head; clamp at the engine boundary so no caller can drive it there.
        let dist = min(max(config.distance, 0.35), config.distanceMax)
        if mode.isDualPoint {
            // Two virtual speakers: bus 0 = L (az − spread), bus 1 = R (az + spread);
            // config.azimuth rotates the whole stage. el/distance/gain shared.
            let spread = config.stereoWidth
            AudioUnitSetParameter(mixer, kParamAzimuth, kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.azimuth - spread), 0)
            AudioUnitSetParameter(mixer, kParamAzimuth, kAudioUnitScope_Input, 1, AudioUnitParameterValue(config.azimuth + spread), 0)
            for e: AudioUnitElement in [0, 1] {
                AudioUnitSetParameter(mixer, kParamElevation, kAudioUnitScope_Input, e, AudioUnitParameterValue(config.elevation), 0)
                AudioUnitSetParameter(mixer, kParamDistance,  kAudioUnitScope_Input, e, AudioUnitParameterValue(dist), 0)
                AudioUnitSetParameter(mixer, kParamGain,      kAudioUnitScope_Input, e, AudioUnitParameterValue(config.gain), 0)
            }
        } else if mode.isSurround {
            // 11 virtual speakers at canonical 7.1.4 angles + 1 bypassed LFE (bus 3).
            // config.azimuth/elevation rotate the whole stage; distance/gain shared.
            var b = 0
            while b < kAtmos714Channels {
                let e = AudioUnitElement(b)
                AudioUnitSetParameter(mixer, kParamGain, kAudioUnitScope_Input, e, AudioUnitParameterValue(config.gain), 0)
                if b != kAtmos714LFEChannel {
                    AudioUnitSetParameter(mixer, kParamAzimuth,   kAudioUnitScope_Input, e, AudioUnitParameterValue(kAtmos714Azimuth[b] + config.azimuth), 0)
                    AudioUnitSetParameter(mixer, kParamElevation, kAudioUnitScope_Input, e, AudioUnitParameterValue(kAtmos714Elevation[b] + config.elevation), 0)
                    AudioUnitSetParameter(mixer, kParamDistance,  kAudioUnitScope_Input, e, AudioUnitParameterValue(dist), 0)
                }
                b += 1
            }
        } else {
            AudioUnitSetParameter(mixer, kParamAzimuth,   kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.azimuth), 0)
            AudioUnitSetParameter(mixer, kParamElevation, kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.elevation), 0)
            AudioUnitSetParameter(mixer, kParamDistance,  kAudioUnitScope_Input, 0, AudioUnitParameterValue(dist), 0)
            AudioUnitSetParameter(mixer, kParamGain,      kAudioUnitScope_Input, 0, AudioUnitParameterValue(config.gain), 0)
        }
    }

    private func applyReverbParams(mixer: AudioUnit, mode: SourceRenderMode) {
        guard reverbActive else { return }
        defer { noteMixerParamsChanged() }
        let buses: [AudioUnitElement]
        if mode.isDualPoint {
            buses = [0, 1]
        } else if mode.isSurround {
            buses = (0..<kAtmos714Channels).filter { $0 != kAtmos714LFEChannel }.map { AudioUnitElement($0) }
        } else {
            buses = [0]
        }
        for e in buses {
            AudioUnitSetParameter(mixer, kParamReverbBlend, kAudioUnitScope_Input, e, AudioUnitParameterValue(config.reverbBlend), 0)
        }
        AudioUnitSetParameter(mixer, kParamGlobalReverbGain, kAudioUnitScope_Global, 0, AudioUnitParameterValue(config.globalReverbGain), 0)
    }

    /// Apply a new config. Properties that require a graph rebuild (output type,
    /// HRTF mode, algorithm, source mode, head tracking) trigger a stop/start when
    /// running; live params (az/el/distance/gain) apply immediately.
    public func reconfigure(_ newConfig: SpatialConfig) throws {
        let needsRebuild = isRunning && (
            newConfig.spatialize != config.spatialize ||
            newConfig.sourceMode != config.sourceMode ||
            newConfig.outputType != config.outputType ||
            newConfig.hrtfMode != config.hrtfMode ||
            newConfig.algorithm != config.algorithm ||
            newConfig.headTracking != config.headTracking ||
            newConfig.interauralDelay != config.interauralDelay ||
            newConfig.distanceAttenuation != config.distanceAttenuation ||
            newConfig.attenuationCurve != config.attenuationCurve ||
            newConfig.distanceRef != config.distanceRef ||
            newConfig.distanceMax != config.distanceMax ||
            newConfig.distanceMaxAtten != config.distanceMaxAtten ||
            newConfig.reverbEnabled != config.reverbEnabled ||
            newConfig.reverbRoomType != config.reverbRoomType)
        if needsRebuild {
            let out = outputDeviceID
            let cap = startedCaptureID   // preserve the capture source (tap aggregate vs loopback)
            stop()
            config = newConfig
            try start(outputDeviceID: out, captureDeviceID: cap)
        } else {
            config = newConfig
            if let mixer = ctx?.spatialMixer {
                applySourceParams(mixer: mixer, mode: activeSourceMode)
                applyReverbParams(mixer: mixer, mode: activeSourceMode)
            }
        }
    }
}
