// AtmosCoreABI — the C ABI of libAtmosCore (Sources/AtmosCoreABI/include/atmos_core.h).
//
// One CoreHost per process owns the EngineController. Every exported function runs on the
// main thread (MainActor.assumeIsolated traps otherwise); the Rust UI calls them from Rune's
// UI thread, which is the main thread running the NSApplication run loop.
//
// Change notification: CoreHost watches every property the snapshot reads with Observation's
// withObservationTracking. The first change in a main-queue turn bumps `generation` and
// schedules one DispatchQueue.main.async block that re-arms the tracking and calls the UI's
// change callback; so the callback never runs re-entrantly inside a command, and it only
// runs at all if the main queue is serviced by the run loop the UI drives.

import AtmosCoreABI
import CoreAudio
import Dispatch
import Foundation
import Observation
import SpatialEngine

// MARK: - Host

@MainActor
final class CoreHost {
    static var instance: CoreHost?

    let controller = EngineController()
    private(set) var generation: UInt64 = 1
    private var changeCallback: AtmosCallback?
    private var changeContext: UnsafeMutableRawPointer?
    private var notifyScheduled = false
    private var terminateCallback: AtmosCallback?
    private var terminateContext: UnsafeMutableRawPointer?
    private var signalSources: [DispatchSourceSignal] = []
    private(set) var isShutDown = false
    private let log = ProcessInfo.processInfo.environment["ATMOS_CORE_LOG"] != nil
    private var deliveredOnce = false

    init() {
        armTracking()
        if log {
            FileHandle.standardError.write(Data("atmos-core: created (abi \(ATMOS_CORE_ABI_VERSION))\n".utf8))
            // The engine finishes every start/stop with `Task { @MainActor }` from its audio
            // queue: confirm the host's run loop drains main-actor jobs too.
            DispatchQueue.global().async {
                Task { @MainActor in
                    FileHandle.standardError.write(Data("atmos-core: MainActor task from a background queue ran (main thread: \(pthread_main_np() != 0))\n".utf8))
                }
            }
        }
    }

    // MARK: Change tracking

    private func armTracking() {
        withObservationTracking {
            controller.touchObservedState()
        } onChange: { [weak self] in
            // willSet of an observed property, on the mutating thread: the controller is
            // @MainActor, so this is the main thread.
            MainActor.assumeIsolated { self?.stateWillChange() }
        }
    }

    private func stateWillChange() {
        generation &+= 1
        scheduleNotify()
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyScheduled = false
                // Re-arm after this turn's mutations landed (onChange fires once, on willSet).
                self.armTracking()
                if self.log && !self.deliveredOnce {
                    self.deliveredOnce = true
                    FileHandle.standardError.write(Data("atmos-core: change notification delivered on the main queue\n".utf8))
                }
                if let cb = self.changeCallback { cb(self.changeContext) }
            }
        }
    }

    func setChangeCallback(_ cb: AtmosCallback?, _ ctx: UnsafeMutableRawPointer?) {
        changeCallback = cb
        changeContext = ctx
    }

    // MARK: Termination signals

    func setTerminateCallback(_ cb: AtmosCallback?, _ ctx: UnsafeMutableRawPointer?) {
        for s in signalSources { s.cancel() }
        signalSources = []
        terminateCallback = cb
        terminateContext = ctx
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        guard cb != nil else {
            for sig in signals { signal(sig, SIG_DFL) }
            return
        }
        for sig in signals {
            signal(sig, SIG_IGN)   // the dispatch source sees it; the default action must not run
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let cb = self.terminateCallback else { return }
                    if self.log { FileHandle.standardError.write(Data("atmos-core: signal \(sig), quitting\n".utf8)) }
                    cb(self.terminateContext)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Shutdown

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        controller.shutdownForTermination()
        if log { FileHandle.standardError.write(Data("atmos-core: shut down\n".utf8)) }
    }

    // MARK: Snapshot

    func fill(_ out: inout AtmosSnapshot) {
        let c = controller
        var s = AtmosSnapshot()
        s.struct_size = UInt32(MemoryLayout<AtmosSnapshot>.size)
        s.abi_version = ATMOS_CORE_ABI_VERSION
        s.generation = generation

        s.is_on = c.isOn
        s.busy = c.isStarting
        s.can_run = c.canRun
        s.permission_needed = c.permissionNeeded
        s.engine_status = c.engineStatus.rawValue

        s.capture_choice = c.captureChoice.rawValue
        s.capture_mode = c.captureMode == .processTap ? 0 : 1
        s.atmos_present = c.atmosPresent
        s.surround_driver_installed = c.surroundDriverInstalled
        s.has_selected_output = c.selectedOutputID != nil
        s.selected_output_id = c.selectedOutputID ?? 0
        let maxOutputs = Int(ATMOS_MAX_OUTPUTS)
        s.output_count = UInt32(min(c.outputs.count, maxOutputs))
        s.outputs_truncated = c.outputs.count > maxOutputs
        withUnsafeMutableBytes(of: &s.outputs) { raw in
            let devs = raw.baseAddress!.assumingMemoryBound(to: AtmosOutputDevice.self)
            for (i, d) in c.outputs.prefix(maxOutputs).enumerated() {
                devs[i].id = d.id
                devs[i].is_airpods = d.isAirPods
                writeCString(d.name, &devs[i].name)
            }
        }
        s.config = atmosConfig(c.config)

        s.personalized_hrtf_engaged = c.personalizedHRTFEngaged
        s.head_pose_live = c.headPoseLive
        s.meter_l = c.meterL
        s.meter_r = c.meterR
        s.peak_hold_l = c.peakHoldL
        s.peak_hold_r = c.peakHoldR
        let peaks = c.channelPeaks.prefix(Int(ATMOS_MAX_CHANNELS))
        s.channel_peak_count = UInt32(peaks.count)
        withUnsafeMutableBytes(of: &s.channel_peaks) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            for (i, v) in peaks.enumerated() { p[i] = v }
        }
        s.head_yaw = c.headYaw
        s.ring_fill = c.ringFill
        s.total_captured = c.totalCaptured
        s.total_played = c.totalPlayed

        let hrtf = c.hrtfStatus
        s.hrtf_status = hrtf.state.rawValue
        s.hrtf_engaged = hrtf.engaged
        s.head_track_status = c.headTrackState.rawValue
        s.head_track_active = c.headTrackActive
        s.soundstage_is_default = c.soundstageIsDefault
        s.rendering_is_default = c.renderingIsDefault

        writeCString(c.engineStatusText, &s.engine_status_text)
        writeCString(c.outputName, &s.output_name)
        writeCString(hrtf.short, &s.hrtf_short)
        writeCString(hrtf.detail, &s.hrtf_detail)
        writeCString(c.headTrackStatus, &s.head_track_status_text)
        writeCString(c.personalizationDisabledReason ?? "", &s.personalization_disabled_reason)
        writeCString(c.musicAtmosAdvisory ?? "", &s.music_atmos_advisory)
        writeCString(c.lastError ?? "", &s.last_error)
        out = s
    }
}

// MARK: - Conversions

/// Copy `string` into a fixed C char array as NUL-terminated UTF-8, cut at a character
/// boundary if it does not fit.
private func writeCString<T>(_ string: String, _ field: inout T) {
    withUnsafeMutableBytes(of: &field) { buf in
        guard buf.count > 0 else { return }
        let bytes = Array(string.utf8)
        var n = min(bytes.count, buf.count - 1)
        if n < bytes.count {
            // Don't split a multi-byte sequence: back up to the lead byte of the cut character.
            while n > 0 && (bytes[n] & 0xC0) == 0x80 { n -= 1 }
        }
        for i in 0..<n { buf[i] = bytes[i] }
        buf[n] = 0
    }
}

private func sourceModeIndex(_ m: SourceRenderMode) -> UInt32 {
    switch m {
    case .dualPointStereo: return 0
    case .ambienceBedStereo: return 1
    case .pointSourceMono: return 2
    case .surround714: return 3
    case .surroundBed714: return 4
    }
}

private func sourceMode(index: UInt32) -> SourceRenderMode? {
    switch index {
    case 0: return .dualPointStereo
    case 1: return .ambienceBedStereo
    case 2: return .pointSourceMono
    case 3: return .surround714
    case 4: return .surroundBed714
    default: return nil
    }
}

private func atmosConfig(_ c: SpatialConfig) -> AtmosConfig {
    var a = AtmosConfig()
    a.output_type = c.outputType.rawValue
    a.hrtf_mode = c.hrtfMode.rawValue
    a.algorithm = c.algorithm.rawValue
    a.source_mode = sourceModeIndex(c.sourceMode)
    a.attenuation_curve = c.attenuationCurve.rawValue
    a.reverb_room_type = c.reverbRoomType.rawValue
    a.head_tracking = c.headTracking
    a.interaural_delay = c.interauralDelay
    a.distance_attenuation = c.distanceAttenuation
    a.reverb_enabled = c.reverbEnabled
    a.azimuth = c.azimuth
    a.elevation = c.elevation
    a.distance = c.distance
    a.gain = c.gain
    a.stereo_width = c.stereoWidth
    a.distance_ref = c.distanceRef
    a.distance_max = c.distanceMax
    a.distance_max_atten = c.distanceMaxAtten
    a.reverb_blend = c.reverbBlend
    a.global_reverb_gain = c.globalReverbGain
    return a
}

/// Apply one rebuild-class field to `config`. Unknown fields and out-of-domain enum values
/// are ignored. Returns whether anything was recognised.
@discardableResult
private func setField(_ field: UInt32, _ value: Double, in config: inout SpatialConfig) -> Bool {
    let raw = UInt32(exactly: value.rounded()) ?? UInt32.max
    let on = value != 0
    let f = Float(value)
    guard value.isFinite else { return false }
    switch field {
    case 0: guard let v = OutputType(rawValue: raw) else { return false }; config.outputType = v
    case 1: guard let v = HRTFMode(rawValue: raw) else { return false }; config.hrtfMode = v
    case 2: guard let v = SpatAlgorithm(rawValue: raw) else { return false }; config.algorithm = v
    case 3: guard let v = sourceMode(index: raw) else { return false }; config.sourceMode = v
    case 4: config.headTracking = on
    case 5: config.interauralDelay = on
    case 6: config.distanceAttenuation = on
    case 7: guard let v = AttenuationCurve(rawValue: raw) else { return false }; config.attenuationCurve = v
    case 8: config.distanceRef = f
    case 9: config.distanceMax = f
    case 10: config.distanceMaxAtten = f
    case 11: config.reverbEnabled = on
    case 12: guard let v = ReverbRoomType(rawValue: raw) else { return false }; config.reverbRoomType = v
    case 13: config.globalReverbGain = f
    default: return false
    }
    return true
}

// MARK: - Exported functions

// Pointers are not Sendable, so they cross into MainActor.assumeIsolated as address bits
// (`UInt`) or as `nonisolated(unsafe)` locals. All of this runs synchronously on the main
// thread; nothing is actually sent anywhere.

@inline(__always)
private func host(_ address: UInt) -> CoreHost? {
    guard let raw = UnsafeRawPointer(bitPattern: address) else { return nil }
    return Unmanaged<CoreHost>.fromOpaque(raw).takeUnretainedValue()
}

/// Run a command on the live (not shut down) host. Traps off the main thread.
@inline(__always)
private func command(_ core: OpaquePointer?, _ body: @MainActor (EngineController) -> Void) {
    let address = UInt(bitPattern: core)
    MainActor.assumeIsolated {
        guard let h = host(address), !h.isShutDown else { return }
        body(h.controller)
    }
}

@_cdecl("atmos_core_abi_version")
public func atmos_core_abi_version() -> UInt32 { ATMOS_CORE_ABI_VERSION }

@_cdecl("atmos_core_default_config")
public func atmos_core_default_config(_ out: UnsafeMutablePointer<AtmosConfig>?) {
    out?.pointee = atmosConfig(SpatialConfig())
}

@_cdecl("atmos_core_create")
public func atmos_core_create() -> OpaquePointer? {
    let address: UInt = MainActor.assumeIsolated {
        let h = CoreHost.instance ?? CoreHost()
        CoreHost.instance = h
        // The host lives for the process (one per process); the handle is never released.
        return UInt(bitPattern: Unmanaged.passUnretained(h).toOpaque())
    }
    return OpaquePointer(bitPattern: address)
}

@_cdecl("atmos_core_shutdown")
public func atmos_core_shutdown(_ core: OpaquePointer?) {
    let address = UInt(bitPattern: core)
    MainActor.assumeIsolated { host(address)?.shutdown() }
}

@_cdecl("atmos_core_set_change_callback")
public func atmos_core_set_change_callback(_ core: OpaquePointer?, _ cb: AtmosCallback?,
                                           _ ctx: UnsafeMutableRawPointer?) {
    let address = UInt(bitPattern: core)
    nonisolated(unsafe) let ctx = ctx
    MainActor.assumeIsolated { host(address)?.setChangeCallback(cb, ctx) }
}

@_cdecl("atmos_core_set_terminate_callback")
public func atmos_core_set_terminate_callback(_ core: OpaquePointer?, _ cb: AtmosCallback?,
                                              _ ctx: UnsafeMutableRawPointer?) {
    let address = UInt(bitPattern: core)
    nonisolated(unsafe) let ctx = ctx
    MainActor.assumeIsolated { host(address)?.setTerminateCallback(cb, ctx) }
}

@_cdecl("atmos_core_generation")
public func atmos_core_generation(_ core: OpaquePointer?) -> UInt64 {
    let address = UInt(bitPattern: core)
    return MainActor.assumeIsolated { host(address)?.generation ?? 0 }
}

@_cdecl("atmos_core_snapshot")
public func atmos_core_snapshot(_ core: OpaquePointer?, _ out: UnsafeMutablePointer<AtmosSnapshot>?) -> Bool {
    let address = UInt(bitPattern: core)
    nonisolated(unsafe) let out = out
    return MainActor.assumeIsolated {
        guard let h = host(address), let out,
              out.pointee.struct_size == UInt32(MemoryLayout<AtmosSnapshot>.size) else { return false }
        h.fill(&out.pointee)
        return true
    }
}

@_cdecl("atmos_core_set_visible")
public func atmos_core_set_visible(_ core: OpaquePointer?, _ panel: Bool, _ settings: Bool) {
    command(core) { $0.setSurfaces(panel: panel, settings: settings) }
}

@_cdecl("atmos_core_power_on")
public func atmos_core_power_on(_ core: OpaquePointer?) { command(core) { $0.powerOn() } }

@_cdecl("atmos_core_power_off")
public func atmos_core_power_off(_ core: OpaquePointer?) { command(core) { $0.powerOff() } }

@_cdecl("atmos_core_toggle")
public func atmos_core_toggle(_ core: OpaquePointer?) { command(core) { $0.toggle() } }

@_cdecl("atmos_core_retry_capture")
public func atmos_core_retry_capture(_ core: OpaquePointer?) { command(core) { $0.retryCapture() } }

@_cdecl("atmos_core_open_privacy_settings")
public func atmos_core_open_privacy_settings(_ core: OpaquePointer?) {
    command(core) { $0.openPrivacySettings() }
}

@_cdecl("atmos_core_set_capture_choice")
public func atmos_core_set_capture_choice(_ core: OpaquePointer?, _ choice: UInt32) {
    command(core) { c in
        if let ch = CaptureChoice(rawValue: choice) { c.setCaptureChoice(ch) }
    }
}

@_cdecl("atmos_core_select_output")
public func atmos_core_select_output(_ core: OpaquePointer?, _ followDefault: Bool, _ deviceID: UInt32) {
    command(core) { c in
        if followDefault {
            c.selectOutput(nil)
        } else if let dev = c.outputs.first(where: { $0.id == deviceID }) {
            c.selectOutput(dev)
        }
    }
}

@_cdecl("atmos_core_refresh_devices")
public func atmos_core_refresh_devices(_ core: OpaquePointer?) { command(core) { $0.refreshDevices() } }

@_cdecl("atmos_core_set_field")
public func atmos_core_set_field(_ core: OpaquePointer?, _ field: UInt32, _ value: Double) {
    command(core) { c in
        var cfg = c.config
        if setField(field, value, in: &cfg), cfg != c.config { c.config = cfg }
    }
}

@_cdecl("atmos_core_apply_config")
public func atmos_core_apply_config(_ core: OpaquePointer?) { command(core) { $0.applyConfig() } }

@_cdecl("atmos_core_set_source")
public func atmos_core_set_source(_ core: OpaquePointer?, _ mask: UInt32, _ azimuth: Float, _ elevation: Float,
                                  _ distance: Float, _ gain: Float, _ width: Float) {
    command(core) { c in
        func pick(_ bit: UInt32, _ v: Float) -> Float? { (mask & bit) != 0 && v.isFinite ? v : nil }
        c.setSource(azimuth: pick(1 << 0, azimuth), elevation: pick(1 << 1, elevation),
                    distance: pick(1 << 2, distance), gain: pick(1 << 3, gain), width: pick(1 << 4, width))
    }
}

@_cdecl("atmos_core_set_reverb_blend")
public func atmos_core_set_reverb_blend(_ core: OpaquePointer?, _ percent: Float) {
    command(core) { c in if percent.isFinite { c.setReverbBlend(percent) } }
}

@_cdecl("atmos_core_reset_soundstage")
public func atmos_core_reset_soundstage(_ core: OpaquePointer?) { command(core) { $0.resetSoundstage() } }

@_cdecl("atmos_core_reset_rendering")
public func atmos_core_reset_rendering(_ core: OpaquePointer?) { command(core) { $0.resetRendering() } }
