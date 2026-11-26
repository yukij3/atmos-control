// EngineController — the @MainActor state model over SpatialEngine. Owns the power on/off
// orchestration (default-output routing), device hot-swap and format-change recovery, and a
// poll timer that publishes live engine telemetry (peaks, 3116, ring fill).
//
// UI-agnostic: the Rune UI reads it through the C ABI in AtmosCoreABI.swift (one snapshot
// struct, see Sources/AtmosCoreABI/include/atmos_core.h). @Observable is kept only as a
// change signal: CoreHost tracks every property the snapshot reads and notifies the UI once
// per main-queue turn when any of them changes.

import AppKit
import CoreAudio
import Observation
import SpatialEngine

/// How the engine captures system audio.
enum CaptureMode {
    case processTap      // muting process tap; AirPods stay default → personalized HRTF + no black-hole
    case loopbackDriver  // hijack the default to the atmos-control loopback; generic HRTF only
}

@MainActor
@Observable
final class EngineController {
    var isOn = false
    var isStarting = false
    /// A power-off teardown is in flight (isStarting is also true then). Lets the status
    /// strip say "Stopping…" instead of claiming the engine is starting.
    var isStopping = false
    @ObservationIgnored private var isTerminating = false
    /// A config edit arrived while a lifecycle operation was in flight; re-applied once it
    /// lands so the engine never drifts from what the controls show.
    @ObservationIgnored private var pendingConfigApply = false
    /// The device `config.outputType` was last resolved for. The output type follows the
    /// output device (headphones vs speakers) unless the user picks one for that device.
    @ObservationIgnored private var outputTypeDeviceID: AudioDeviceID?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var pendingDeviceChange = false
    @ObservationIgnored private var pendingFormatChange = false
    @ObservationIgnored private var formatRetryWorkItem: DispatchWorkItem?
    @ObservationIgnored private let audioQueue = DispatchQueue(label: "dev.atmoscontrol.audio-control", qos: .userInitiated)
    /// `ATMOS_CORE_LOG` (any value): log each lifecycle operation's outcome and duration to
    /// stderr, and flag one still running after 3 s. `ATMOS_CORE_LOG=verbose` also routes
    /// SpatialEngine's setup trace (every property set during start) there.
    @ObservationIgnored private let diagnostics = ProcessInfo.processInfo.environment["ATMOS_CORE_LOG"]
    @ObservationIgnored private var operationSerial: UInt64 = 0
    var config = SpatialConfig()
    var lastError: String?
    var atmosPresent = false
    var outputName = "—"

    /// True when the tap start failed on (likely) audio-capture consent. We surface an
    /// explicit permission state and do NOT auto-fall-back to loopback (which would mutate
    /// the system default output). Cleared on a successful start / mode switch / retry.
    var permissionNeeded = false

    /// The installed loopback exposes the full 12-channel 7.1.4 surface (enables Surround).
    var surroundDriverInstalled = false

    /// Per-capture-channel peaks (Atmos_7_1_4 order) for the settings Levels surround meter;
    /// [L,R] in stereo modes. Read only by SettingsView when surround is active.
    var channelPeaks: [Float] = []

    // Live engine telemetry — individual tracked properties (was one EngineState struct)
    // so per-property observation pays off: PanelView reads only personalizedHRTFEngaged,
    // while ringFill/totals (SettingsView-only) no longer invalidate the panel each tick.
    var personalizedHRTFEngaged = false   // AUSpatialMixer property 3116
    var ringFill: UInt64 = 0
    var totalCaptured: UInt64 = 0
    var totalPlayed: UInt64 = 0

    // Output routing (settings window): the discovered real sinks + the user's choice.
    var outputs: [AudioOutputDevice] = []
    var selectedOutputID: AudioDeviceID?   // nil = follow current system default
    var captureMode: CaptureMode = .processTap   // default: personalized, no black-hole

    // Smoothed peak-hold for the meters (linear 0…1).
    var meterL: Float = 0
    var meterR: Float = 0
    var peakHoldL: Float = 0
    var peakHoldR: Float = 0

    // Live head pose (radians yaw) for the radar; mirrors AirPods head tracking.
    var headYaw: Double = 0
    var headPoseLive = false

    @ObservationIgnored private let engine = SpatialEngine()
    @ObservationIgnored private let deviceMonitor = DeviceMonitor()
    @ObservationIgnored private let motion = HeadphoneMotion()
    @ObservationIgnored private let tap = ProcessTap()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var savedDefault: AudioDeviceID?
    @ObservationIgnored private var activeSinkID: AudioDeviceID?   // real device the graph renders to
    @ObservationIgnored private var activeCaptureID: AudioDeviceID?  // tap aggregate (tap mode) or nil
    @ObservationIgnored private var handlingChange = false
    @ObservationIgnored fileprivate var musicSettingCache: (value: Int?, at: Date)?

    // Surface visibility, reported by the UI (atmos_core_set_visible): the panel and the
    // settings window are open independently. Gates meter polling and head motion.
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var settingsOnScreen = false

    /// The engine can run for the CURRENT capture choice. Personalized (tap) needs no driver;
    /// the virtual-device options need the HAL device (Surround needs the 12-channel variant).
    /// A capability only: while a lifecycle operation is in flight (`isStarting`) the UI also
    /// disables the power control, but this stays true so the "can't run" notice never flashes.
    var canRun: Bool {
        switch captureChoice {
        case .personalized:  return true
        case .virtualStereo: return atmosPresent
        case .surround:      return surroundDriverInstalled
        }
    }

    /// The user-facing capture choice derived from the engine's capture mode + source mode.
    var captureChoice: CaptureChoice {
        if captureMode == .processTap { return .personalized }
        return (config.sourceMode == .surround714 || config.sourceMode == .surroundBed714) ? .surround : .virtualStereo
    }

    /// Switch the user-facing capture choice (maps onto CaptureMode + SourceRenderMode).
    /// Restarts the engine atomically on the audio control queue if it was running.
    func setCaptureChoice(_ choice: CaptureChoice) {
        guard !isStarting, choice != captureChoice else { return }
        cancelFormatRetry()
        permissionNeeded = false
        lastError = nil
        let wasOn = isOn
        let prevMode = captureMode
        switch choice {
        case .personalized:
            captureMode = .processTap
            if config.sourceMode.isSurroundMode { config.sourceMode = .dualPointStereo }
        case .virtualStereo:
            captureMode = .loopbackDriver
            if config.sourceMode.isSurroundMode { config.sourceMode = .dualPointStereo }
        case .surround:
            captureMode = .loopbackDriver
            config.sourceMode = .surround714
        }
        guard wasOn else { syncIdleOutput(outputs); return }
        if prevMode == captureMode && captureMode == .loopbackDriver {
            applyConfig()
            return
        }
        if captureMode == .processTap {
            startTapMode(restoreLoopbackDefault: savedDefault)
        } else {
            startLoopbackMode()
        }
    }

    init() {
        if diagnostics == "verbose" {
            // Runs on the audio control queue (SpatialEngine.start): no actor isolation.
            engine.logger = { @Sendable line in EngineController.diag("engine: \(line)") }
        }
        atmosPresent = engine.atmosControlPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        outputs = engine.outputDevices()
        outputName = SpatialEngine.currentDefaultOutput().name
        syncIdleOutput(outputs)

        motion.onYaw = { [weak self] y in
            guard let self else { return }
            if abs(y - self.headYaw) > 0.008 { self.headYaw = y }   // ~0.5°: limit redraw churn
            if !self.headPoseLive { self.headPoseLive = true }
        }
        deviceMonitor.onChange = { [weak self] in self?.handleDeviceChange() }
        deviceMonitor.start()

        // The capture or output device changed sample rate or stream layout (e.g. AirPods
        // A2DP ↔ HFP call profile). Route the rebuild through performAudioChange so one owner
        // serializes all engine lifecycle operations.
        engine.onFormatChange = { [weak self] in
            MainActor.assumeIsolated { self?.handleFormatChange() }
        }
    }

    /// Reads every observed property the C ABI snapshot exposes, inside
    /// withObservationTracking (CoreHost), so a change to any of them notifies the UI.
    /// Add new published properties here too.
    func touchObservedState() {
        _ = (isOn, isStarting, isStopping, config, lastError, atmosPresent, outputName)
        _ = (permissionNeeded, surroundDriverInstalled, channelPeaks, personalizedHRTFEngaged)
        _ = (ringFill, totalCaptured, totalPlayed, outputs, selectedOutputID, captureMode)
        _ = (meterL, meterR, peakHoldL, peakHoldR, headYaw, headPoseLive)
    }

    // MARK: Output devices

    /// Re-enumerate the available real sinks; drop a selection that has vanished.
    func refreshDevices() {
        atmosPresent = engine.atmosControlPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        outputs = engine.outputDevices()
        if let sel = selectedOutputID, !outputs.contains(where: { $0.id == sel }) {
            selectedOutputID = nil
        }
    }

    /// Sensible output-type default for a sink (used on power-on and device switch).
    private nonisolated static func defaultOutputType(for dev: AudioOutputDevice) -> OutputType {
        if dev.isAirPods { return .headphones }
        return dev.name.localizedCaseInsensitiveContains("headphone") ? .headphones : .builtInSpeakers
    }

    /// Adopt the device-appropriate output type when the output device changes; keep the
    /// user's pick for as long as audio stays on the same device.
    private func syncOutputType(to dev: AudioOutputDevice) {
        guard dev.id != outputTypeDeviceID else { return }
        outputTypeDeviceID = dev.id
        config.outputType = Self.defaultOutputType(for: dev)
    }

    /// While the engine is off, show (and pre-resolve the output type for) the device the
    /// next start will render to: the picked sink in the loopback modes, else the macOS
    /// default output (never the atmos-control loopback itself).
    private func syncIdleOutput(_ devices: [AudioOutputDevice]) {
        guard !isOn else { return }
        let dev: AudioOutputDevice?
        if captureMode == .loopbackDriver, let sel = selectedOutputID,
           let picked = devices.first(where: { $0.id == sel }) {
            dev = picked
        } else {
            let cur = SpatialEngine.currentDefaultOutput()
            dev = devices.first(where: { $0.id == cur.id })
        }
        guard let dev else { return }
        outputName = dev.name
        syncOutputType(to: dev)
    }

    /// Pick which real sink to route through (loopback modes only; nil = follow the system default).
    /// Personalized tap mode always follows the system default output so apps are not silenced.
    func selectOutput(_ dev: AudioOutputDevice?) {
        guard captureMode == .loopbackDriver else { return }
        selectedOutputID = dev?.id
        if let d = dev { outputName = d.name; syncOutputType(to: d) } else { syncIdleOutput(outputs) }
        guard isOn, !isStarting else { return }
        let engine = self.engine, snapshot = config, targetID = dev?.id
        performAudioChange({
            engine.stop()
            engine.config = snapshot
            try engine.start(outputDeviceID: targetID, captureDeviceID: nil)
            return targetID
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sinkID):
                self.activeSinkID = sinkID
                self.lastError = nil
                self.updateActivity()
            case .failure(let error):
                self.lastError = "\(error)"
                self.powerOff()
            }
        }
    }

    // MARK: Device hot-swap & format changes

    /// CoreAudio device list or default-output changed. Keep the picker fresh and,
    /// if running, rebuild on default-output changes (Personalized) or fail over when
    /// our real sink has vanished (Loopback).
    private func handleDeviceChange() {
        if isStarting { pendingDeviceChange = true; return }
        guard !handlingChange else { return }
        handlingChange = true
        defer { handlingChange = false }

        atmosPresent = engine.atmosControlPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        let devices = engine.outputDevices()
        outputs = devices
        if let sel = selectedOutputID, !devices.contains(where: { $0.id == sel }) { selectedOutputID = nil }

        guard isOn else { syncIdleOutput(devices); return }
        if captureMode == .processTap {
            let cur = SpatialEngine.currentDefaultOutput()
            guard let next = devices.first(where: { $0.id == cur.id }) else {
                lastError = "Output device disconnected — engine stopped."
                powerOff()
                return
            }
            if next.id != activeSinkID {
                cancelFormatRetry()
                headPoseLive = false   // the new device may not report head motion
                startTapMode()
            }
            return
        }
        if let sink = activeSinkID, !devices.contains(where: { $0.id == sink }) {
            recoverFromLostSink(devices)
        }
    }

    /// Our render sink disappeared mid-session in loopback mode — fail over to another real
    /// device if one exists (atmos-control stays the capture default), else power down safely.
    private func recoverFromLostSink(_ devices: [AudioOutputDevice]) {
        selectedOutputID = nil
        guard let fallback = devices.first(where: { $0.isAirPods }) ?? devices.first(where: { !$0.isAirPods }) ?? devices.first else {
            lastError = "Output device disconnected — engine stopped."
            powerOff()
            return
        }
        syncOutputType(to: fallback)
        headPoseLive = false
        let engine = self.engine, snapshot = config
        performAudioChange({
            engine.stop()
            engine.config = snapshot
            try engine.start(outputDeviceID: fallback.id, captureDeviceID: nil)
            return fallback
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let dev):
                // The Output status shows the new device; this is not an error.
                self.activeSinkID = dev.id
                self.outputName = dev.name
                self.lastError = nil
                self.updateActivity()
            case .failure(let error):
                self.lastError = "Output device lost — \(error)"
                self.powerOff()
            }
        }
    }

    private func handleFormatChange() {
        guard isOn else { return }
        if isStarting { pendingFormatChange = true; return }
        cancelFormatRetry()
        rebuildForFormatChange(retriesLeft: 1)
    }

    private func cancelFormatRetry() {
        formatRetryWorkItem?.cancel()
        formatRetryWorkItem = nil
    }

    /// Rebuild the graph at the new device sample rate / stream layout through performAudioChange.
    /// On failure, retry once after 0.3s (Bluetooth profile transitions are often mid-reconfigure
    /// on the first notification); if the retry also fails, power off cleanly so apps are never
    /// stranded in tap-muted silence.
    private func rebuildForFormatChange(retriesLeft: Int) {
        guard isOn else { return }
        if isStarting { pendingFormatChange = true; return }
        if captureMode == .processTap {
            if config.sourceMode.isSurroundMode { config.sourceMode = .dualPointStereo }
            let engine = self.engine, tap = self.tap, baseConfig = config, typeDevice = outputTypeDeviceID
            performAudioChange({
                try Self.startTapSession(engine: engine, tap: tap, baseConfig: baseConfig,
                                         outputTypeDeviceID: typeDevice)
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let (aggregate, dev, resolvedOutputType, devices)):
                    self.outputs = devices
                    // Same device: keep config.outputType as is (a pick made while the rebuild
                    // ran is re-applied by drainPendingEvents via pendingConfigApply).
                    if dev.id != typeDevice { self.config.outputType = resolvedOutputType }
                    self.outputTypeDeviceID = dev.id
                    self.activeCaptureID = aggregate
                    self.activeSinkID = dev.id
                    self.outputName = dev.name
                    self.lastError = nil
                    self.updateActivity()
                case .failure:
                    self.handleFormatRebuildFailure(retriesLeft: retriesLeft)
                }
            }
        } else {
            let engine = self.engine, snapshot = config, sink = activeSinkID
            performAudioChange({
                engine.stop()
                engine.config = snapshot
                try engine.start(outputDeviceID: sink, captureDeviceID: nil)
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.lastError = nil
                    self.updateActivity()
                case .failure:
                    self.handleFormatRebuildFailure(retriesLeft: retriesLeft)
                }
            }
        }
    }

    private func handleFormatRebuildFailure(retriesLeft: Int) {
        if retriesLeft > 0, isOn, !stopRequested {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.formatRetryWorkItem = nil
                self.rebuildForFormatChange(retriesLeft: retriesLeft - 1)
            }
            formatRetryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        } else {
            lastError = "Audio format changed and the engine could not restart — stopped."
            powerOff()
        }
    }

    // MARK: Surface visibility

    /// Poll meters + run head-motion only while a window is actually on screen — the
    /// engine keeps spatializing when closed, but nobody's looking at the live readouts.
    /// The UI reports both surfaces (they can be open independently), including occlusion:
    /// a covered or minimised window counts as not visible.
    func setSurfaces(panel: Bool, settings: Bool) {
        guard panel != panelOnScreen || settings != settingsOnScreen else { return }
        panelOnScreen = panel
        settingsOnScreen = settings
        updateActivity()
    }

    private var anySurfaceVisible: Bool { panelOnScreen || settingsOnScreen }

    private func updateActivity() {
        if isOn && anySurfaceVisible { startPolling() } else { stopPolling() }
        syncMotion()
    }

    // MARK: Head-pose motion

    /// Run head-pose updates only while on, head-tracking enabled, AND a surface visible.
    /// (Real audio head-tracking is AUSpatialMixer property 3111 — independent of this.)
    private func syncMotion() {
        if isOn && config.headTracking && anySurfaceVisible && motion.isAvailable {
            motion.start()
        } else {
            motion.stop()
            // Only forget the pose when tracking really stopped — not when the panel merely
            // closed — so reopening it doesn't flash "Unavailable" before the first sample.
            if !isOn || !config.headTracking {
                headPoseLive = false
                headYaw = 0
            }
        }
    }

    // MARK: Power

    func toggle() { isOn ? powerOff() : powerOn() }

    func powerOn() {
        guard !isStarting, !isOn else { return }
        atmosPresent = engine.atmosControlPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        permissionNeeded = false
        lastError = nil
        if captureMode == .processTap { startTapMode(); return }
        startLoopbackMode()   // explicit virtual-device (loopback) mode — never an auto-fallback
    }

    /// Deep-link into System Settings ▸ Privacy & Security ▸ the audio-capture list, where the
    /// process-tap consent lives (not Microphone — the tap never opens an input device).
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explicit, user-initiated retry after a permission failure (does NOT change routing).
    func retryCapture() { permissionNeeded = false; powerOn() }

    /// Shared audioQueue helper for starting or rebuilding a device-scoped process-tap session.
    private nonisolated static func startTapSession(
        engine: SpatialEngine,
        tap: ProcessTap,
        baseConfig: SpatialConfig,
        outputTypeDeviceID: AudioDeviceID?,
        restoreLoopbackDefault: AudioDeviceID? = nil
    ) throws -> (AudioDeviceID, AudioOutputDevice, OutputType, [AudioOutputDevice]) {
        engine.stop()
        if tap.isActive { tap.stop() }
        if let prevDefault = restoreLoopbackDefault {
            restoreSafeDefault(savedDefault: prevDefault, engine: engine)
        }
        let devices = engine.outputDevices()
        let current = SpatialEngine.currentDefaultOutput()
        guard let real = devices.first(where: { $0.id == current.id }) else {
            throw SpatialEngineError.noOutputDevice
        }
        var snapshot = baseConfig
        // Keep the user's output type if audio is still on the device it was chosen for.
        if real.id != outputTypeDeviceID { snapshot.outputType = defaultOutputType(for: real) }
        do {
            let aggregate = try tap.start(muted: true, outputDeviceID: real.id)
            engine.config = snapshot
            try engine.start(outputDeviceID: real.id, captureDeviceID: aggregate)
            return (aggregate, real, snapshot.outputType, devices)
        } catch {
            engine.stop()
            if tap.isActive { tap.stop() }
            throw error
        }
    }

    /// Personalized capture via a muting process tap. Always follows the system default
    /// output so apps play into the tapped sink and property 3116 stays engaged.
    private func startTapMode(restoreLoopbackDefault: AudioDeviceID? = nil) {
        if config.sourceMode.isSurroundMode { config.sourceMode = .dualPointStereo }
        let engine = self.engine, tap = self.tap, baseConfig = config, typeDevice = outputTypeDeviceID
        performAudioChange({
            try Self.startTapSession(
                engine: engine, tap: tap, baseConfig: baseConfig, outputTypeDeviceID: typeDevice,
                restoreLoopbackDefault: restoreLoopbackDefault)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (aggregate, real, resolvedOutputType, devices)):
                self.outputs = devices
                if real.id != typeDevice { self.config.outputType = resolvedOutputType }
                self.outputTypeDeviceID = real.id
                self.outputName = real.name
                self.activeCaptureID = aggregate
                self.activeSinkID = real.id
                self.savedDefault = nil
                self.isOn = true
                self.lastError = nil
                self.permissionNeeded = false
                self.updateActivity()
            case .failure(let error):
                self.savedDefault = nil
                self.isOn = false
                self.resetLiveTelemetry()
                self.syncIdleOutput(self.outputs)
                if let e = error as? ProcessTapError, case .createTapFailed = e {
                    self.permissionNeeded = true
                    self.lastError = nil
                } else {
                    self.permissionNeeded = false
                    self.lastError = "Personalized capture unavailable: \(error)."
                }
            }
        }
    }

    // Serialize all engine/tap lifecycle mutations off the UI thread.
    // isStarting excludes overlapping UI requests; device/format changes queue cleanly.
    private func performAudioChange<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T,
        completion: @escaping @MainActor @Sendable (Result<T, Error>) -> Void
    ) {
        guard !isStarting else { return }
        isStarting = true
        stopRequested = false
        stopPolling()
        operationSerial &+= 1
        let traced = diagnostics != nil, serial = operationSerial, began = Date()
        if traced { reportIfSlow(serial) }
        audioQueue.async { [weak self] in
            let result = Result(catching: operation)
            if traced {
                let outcome: String
                switch result {
                case .success: outcome = "ok"
                case .failure(let error): outcome = "failed: \(error)"
                }
                Self.diag(String(format: "engine operation %llu finished in %.3f s: %@",
                                 serial, Date().timeIntervalSince(began), outcome))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStarting = false
                completion(result)
                self.drainPendingEvents()
            }
        }
    }

    /// Diagnostics only: say so when lifecycle operation `serial` is still in flight after 3 s.
    /// The first tap start for a code identity blocks inside the HAL (AudioDeviceStart) while
    /// macOS shows the audio-capture consent prompt; the HAL gives up after about 30 s.
    private func reportIfSlow(_ serial: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isStarting, self.operationSerial == serial else { return }
                Self.diag("engine operation \(serial) still running after 3 s (an audio-capture "
                          + "consent prompt blocks the first start until answered, ~30 s at most)")
            }
        }
    }

    nonisolated static func diag(_ line: String) {
        FileHandle.standardError.write(Data("atmos-core: \(line)\n".utf8))
    }

    private func drainPendingEvents() {
        guard !isStarting, !isTerminating else { return }
        if stopRequested {
            stopRequested = false
            pendingDeviceChange = false
            pendingFormatChange = false
            powerOff()
        } else if pendingDeviceChange {
            pendingDeviceChange = false
            pendingFormatChange = false
            handleDeviceChange()
        } else if pendingFormatChange {
            pendingFormatChange = false
            handleFormatChange()
        }
        if pendingConfigApply && !isStarting {
            pendingConfigApply = false
            applyConfig()
        }
    }

    /// Loopback capture: hijack the system default to the atmos-control HAL device.
    /// Generic HRTF only (personalization blocked by the virtual default); restores on off.
    private func startLoopbackMode() {
        guard let atmos = SpatialEngine.atmosControlDeviceID() else {
            lastError = "atmos-control device not found — install the HAL driver, or use Personalized (tap) mode."
            if isOn || tap.isActive { powerOff() }
            return
        }
        let current = SpatialEngine.currentDefaultOutput()
        let prevDefault = savedDefault ?? current.id
        // Record savedDefault before dispatching so shutdownForTermination can restore it
        // even if termination arrives while startLoopbackMode is still in flight.
        savedDefault = prevDefault
        let devices = engine.outputDevices()
        outputs = devices
        let real: AudioOutputDevice?
        if let sel = selectedOutputID, let d = devices.first(where: { $0.id == sel }) {
            real = d
        } else if current.id == atmos {
            real = devices.first(where: { $0.isAirPods }) ?? devices.first
        } else {
            real = devices.first(where: { $0.id == current.id })
        }
        if let r = real { syncOutputType(to: r); outputName = r.name }
        let engine = self.engine, tap = self.tap, snapshot = config
        let sinkID = real?.id ?? (current.id != atmos ? current.id : nil)

        performAudioChange({
            engine.stop()
            if tap.isActive { tap.stop() }
            SpatialEngine.setDefaultOutput(atmos)
            engine.config = snapshot
            do {
                try engine.start(outputDeviceID: real?.id, captureDeviceID: nil)
                return sinkID
            } catch {
                engine.stop()
                Self.restoreSafeDefault(savedDefault: prevDefault, engine: engine)
                throw error
            }
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let activeSink):
                self.savedDefault = prevDefault
                self.activeCaptureID = nil
                self.activeSinkID = activeSink
                self.isOn = true
                self.lastError = nil
                self.updateActivity()
            case .failure(let error):
                self.savedDefault = nil
                self.isOn = false
                self.resetLiveTelemetry()
                self.lastError = "\(error)"
            }
        }
    }

    private func resetLiveTelemetry() {
        activeSinkID = nil
        activeCaptureID = nil
        personalizedHRTFEngaged = false
        ringFill = 0; totalCaptured = 0; totalPlayed = 0
        meterL = 0; meterR = 0; peakHoldL = 0; peakHoldR = 0
        if !channelPeaks.isEmpty { channelPeaks = [] }
        updateActivity()
    }

    func powerOff() {
        cancelFormatRetry()
        if isStarting {
            // Queued behind the in-flight operation (drainPendingEvents runs it); say so now.
            stopRequested = true
            pendingDeviceChange = false
            pendingFormatChange = false
            isStopping = true
            return
        }
        let restoreDefault = savedDefault
        let needsTeardown = isOn || tap.isActive || restoreDefault != nil
        isOn = false
        savedDefault = nil
        resetLiveTelemetry()
        guard needsTeardown else { isStopping = false; syncIdleOutput(outputs); return }
        isStopping = true
        let engine = self.engine, tap = self.tap
        performAudioChange({
            engine.stop()
            if tap.isActive { tap.stop() }
            if let restoreDefault {
                Self.restoreSafeDefault(savedDefault: restoreDefault, engine: engine)
            }
        }) { [weak self] _ in
            guard let self else { return }
            self.isStopping = false
            self.syncIdleOutput(self.engine.outputDevices())
        }
    }

    /// Synchronous teardown for app termination so the process never exits before
    /// destroying the tap/aggregate or restoring the loopback default. Pumps the main run loop
    /// briefly if an audioQueue transition is in flight so HAL registration cannot deadlock.
    func shutdownForTermination() {
        isTerminating = true
        cancelFormatRetry()
        if isStarting {
            stopRequested = true
            let deadline = Date(timeIntervalSinceNow: 2.0)
            while isStarting && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        }
        let restoreDefault = savedDefault
        let engine = self.engine, tap = self.tap
        if !isStarting {
            audioQueue.sync {
                engine.stop()
                if tap.isActive { tap.stop() }
                if let restoreDefault {
                    Self.restoreSafeDefault(savedDefault: restoreDefault, engine: engine)
                }
            }
        } else if let restoreDefault {
            Self.restoreSafeDefault(savedDefault: restoreDefault, engine: engine)
        }
        isOn = false
        isStopping = false
        savedDefault = nil
        resetLiveTelemetry()
    }

    /// Restore the system default to a present, real (non-virtual) device. Prefers the
    /// saved pre-power-on default; falls back to built-in speakers / any real sink so we
    /// never strand the default on the atmos-control loopback (which black-holes audio).
    private nonisolated static func restoreSafeDefault(savedDefault: AudioDeviceID?, engine: SpatialEngine) {
        let atmos = SpatialEngine.atmosControlDeviceID()
        let present = engine.outputDevices()
        if let s = savedDefault, s != atmos, present.contains(where: { $0.id == s }) {
            SpatialEngine.setDefaultOutput(s)
        } else if let speakers = present.first(where: { $0.name.localizedCaseInsensitiveContains("speaker") })
                    ?? present.first(where: { !$0.isAirPods }) ?? present.first {
            SpatialEngine.setDefaultOutput(speakers.id)
        }
    }

    // MARK: Config changes

    /// Apply a rebuild-class config change (output type, HRTF, algorithm, source mode,
    /// head tracking). Brief audio gap while running.
    func applyConfig() {
        if captureMode == .processTap && config.sourceMode.isSurroundMode {
            config.sourceMode = .dualPointStereo
        }
        // The engine clamps the source to Max distance; mirror it so the readout never lies.
        config.distance = min(max(config.distance, Self.minDistance), config.distanceMax)
        if isStarting { pendingConfigApply = true; return }
        guard isOn else { return }
        let engine = self.engine, snapshot = config
        performAudioChange({ try engine.reconfigure(snapshot) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.updateActivity()
            case .failure(let error): self.lastError = "\(error)"; self.powerOff()
            }
        }
    }

    /// Live source position/gain/width (no rebuild).
    func setSource(azimuth: Float? = nil, elevation: Float? = nil, distance: Float? = nil,
                   gain: Float? = nil, width: Float? = nil) {
        if let a = azimuth { config.azimuth = a }
        if let e = elevation { config.elevation = e }
        // Mirror the engine's clamp (SpatialEngine.updateSource) so the readout never lies.
        let dist = distance.map { min(max($0, Self.minDistance), config.distanceMax) }
        if let d = dist { config.distance = d }
        if let g = gain { config.gain = g }
        if let w = width { config.stereoWidth = w }
        if isStarting { pendingConfigApply = true; return }
        guard isOn, formatRetryWorkItem == nil else { return }
        engine.updateSource(azimuth: azimuth, elevation: elevation, distance: dist, gain: gain, width: width)
    }

    /// Live reverb wet/dry blend (no rebuild; no-op in the engine unless the reverb path is
    /// active, i.e. HRTF / HRTF-HQ).
    func setReverbBlend(_ v: Float) {
        config.reverbBlend = v
        if isStarting { pendingConfigApply = true; return }
        guard isOn, formatRetryWorkItem == nil else { return }
        engine.updateReverb(blend: v)
    }

    /// The engine's defaults: the single source of truth for both Reset actions and for the
    /// defaults the UI shows (atmos_core_default_config).
    static let defaults = SpatialConfig()
    /// SpatialEngine clamps the source distance to at least this (applySourceParams).
    static let minDistance: Float = 0.35

    /// Reset the soundstage (position, gain, stereo width) to front-and-centre.
    func resetSoundstage() {
        let d = Self.defaults
        setSource(azimuth: d.azimuth, elevation: d.elevation, distance: d.distance,
                  gain: d.gain, width: d.stereoWidth)
    }

    /// Nothing to reset — lets both Reset buttons show a truthful disabled state.
    var soundstageIsDefault: Bool {
        let c = config, d = Self.defaults
        return c.azimuth == d.azimuth && c.elevation == d.elevation && c.distance == d.distance
            && c.gain == d.gain && c.stereoWidth == d.stereoWidth
    }

    /// Reset the rendering block (algorithm, reverb, distance model) to its defaults.
    func resetRendering() {
        let d = Self.defaults
        config.algorithm = d.algorithm
        config.interauralDelay = d.interauralDelay
        config.distanceAttenuation = d.distanceAttenuation
        config.attenuationCurve = d.attenuationCurve
        config.distanceRef = d.distanceRef
        config.distanceMax = d.distanceMax
        config.distanceMaxAtten = d.distanceMaxAtten
        config.reverbEnabled = d.reverbEnabled
        config.reverbRoomType = d.reverbRoomType
        config.reverbBlend = d.reverbBlend
        config.globalReverbGain = d.globalReverbGain
        applyConfig()
    }

    var renderingIsDefault: Bool {
        let c = config, d = Self.defaults
        return c.algorithm == d.algorithm && c.interauralDelay == d.interauralDelay
            && c.distanceAttenuation == d.distanceAttenuation && c.attenuationCurve == d.attenuationCurve
            && c.distanceRef == d.distanceRef && c.distanceMax == d.distanceMax
            && c.distanceMaxAtten == d.distanceMaxAtten && c.reverbEnabled == d.reverbEnabled
            && c.reverbRoomType == d.reverbRoomType && c.reverbBlend == d.reverbBlend
            && c.globalReverbGain == d.globalReverbGain
    }

    // MARK: Polling

    private func startPolling() {
        guard timer == nil else { return }   // idempotent: don't restart on every activity change
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 1.0 / 30.0   // let the OS coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard !isStarting, isOn, formatRetryWorkItem == nil else { return }
        let s = engine.pollState()
        // Fan the poll struct out into individual tracked properties, each guarded against
        // no-op writes. ringFill/totalCaptured/totalPlayed change every tick during playback
        // but are read ONLY by SettingsView, so they invalidate the panel only when it's open.
        if personalizedHRTFEngaged != s.personalizedHRTFEngaged { personalizedHRTFEngaged = s.personalizedHRTFEngaged }
        // Surround Levels meter (settings only): publish the full per-channel peak vector when
        // in a 12-channel mode, else keep it empty so stereo modes never carry the extra array.
        if s.peaks.count > 2 {
            if channelPeaks != s.peaks { channelPeaks = s.peaks }
        } else if !channelPeaks.isEmpty {
            channelPeaks = []
        }
        if ringFill != s.ringFill { ringFill = s.ringFill }
        if totalCaptured != s.totalCaptured { totalCaptured = s.totalCaptured }
        if totalPlayed != s.totalPlayed { totalPlayed = s.totalPlayed }
        let nm = s.outputDeviceName
        if !nm.isEmpty && nm != outputName { outputName = nm }   // guard: avoid no-op publishes
        // Meter: fast attack to the new peak, gentle release; hold the peak marker.
        // Snap sub-perceptual levels to exactly 0 and skip unchanged writes so the UI
        // QUIESCES in silence. Otherwise *0.82 / *0.985 only underflow to 0 after tens of
        // seconds, and every @Published write in between redraws the whole observing tree.
        let nL = settle(max(s.peakL, meterL * 0.82))
        let nR = settle(max(s.peakR, meterR * 0.82))
        let hL = settle(max(peakHoldL * 0.985, s.peakL))
        let hR = settle(max(peakHoldR * 0.985, s.peakR))
        if nL != meterL { meterL = nL }
        if nR != meterR { meterR = nR }
        if hL != peakHoldL { peakHoldL = hL }
        if hR != peakHoldR { peakHoldR = hR }
    }

    /// Snap a meter level below the −60 dBFS visual floor to exactly 0 so the decay
    /// reaches a fixed point in one tick instead of asymptotically republishing forever.
    @inline(__always) private func settle(_ x: Float) -> Float { x < 1e-3 ? 0 : x }

    // MARK: Derived UI state (computed here so every UI agrees; raw values are the C ABI's)

    enum EngineStatus: UInt32 { case off = 0, starting = 1, on = 2, stopping = 3 }

    /// Engine state — the text pair for the power switch (never position alone). `isStarting`
    /// is also true for rebuilds while on (config, device swap); those read as On.
    var engineStatus: EngineStatus {
        if isStopping { return .stopping }
        if isStarting && !isOn { return .starting }
        return isOn ? .on : .off
    }

    var engineStatusText: String {
        switch engineStatus {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .on: return "On"
        case .stopping: return "Stopping…"
        }
    }

    enum HRTFState: UInt32 { case inactive = 0, personalized = 1, generic = 2 }

    /// Truthful HRTF status (property 3116): a one-word state for the panel, a sentence for
    /// the reason, and whether the accent "engaged" treatment applies.
    struct HRTFStatus { let state: HRTFState; let short: String; let detail: String; let engaged: Bool }

    var hrtfStatus: HRTFStatus {
        if !isOn { return HRTFStatus(state: .inactive, short: "Inactive", detail: "The engine is off.", engaged: false) }
        if personalizedHRTFEngaged {
            return HRTFStatus(state: .personalized, short: "Personalized",
                              detail: "Your Apple personalized profile is active.", engaged: true)
        }
        if let reason = personalizationDisabledReason {
            return HRTFStatus(state: .generic, short: "Generic", detail: reason, engaged: false)
        }
        if config.hrtfMode == .off {
            return HRTFStatus(state: .generic, short: "Generic", detail: "Personalized HRTF is turned off.", engaged: false)
        }
        return HRTFStatus(state: .generic, short: "Generic",
                          detail: "Needs AirPods with a personalized Spatial Audio profile as the system output.",
                          engaged: false)
    }

    enum HeadTrackState: UInt32 { case off = 0, inactive = 1, tracking = 2, unavailable = 3 }

    /// Head tracking (F14): Off (disabled) · Inactive (engine off) · Tracking (live pose) ·
    /// Unavailable (running, but no head-motion data). Never claims "Tracking" without pose.
    var headTrackState: HeadTrackState {
        guard config.headTracking else { return .off }
        guard isOn else { return .inactive }
        return headPoseLive ? .tracking : .unavailable
    }

    var headTrackStatus: String {
        switch headTrackState {
        case .off: return "Off"
        case .inactive: return "Inactive"
        case .tracking: return "Tracking"
        case .unavailable: return "Unavailable"
        }
    }
    var headTrackActive: Bool { headTrackState == .tracking }

    /// True when personalized HRTF (property 3116) can never engage in the current config, so
    /// the HRTF-mode picker is disabled with this reason (F4).
    var personalizationDisabledReason: String? {
        if captureMode == .loopbackDriver { return "Unavailable with the virtual device." }
        if config.outputType != .headphones { return "Applies to headphones only." }
        if config.algorithm != .useOutputType { return "Needs the Automatic algorithm." }
        return nil
    }

    /// Advisory about Apple Music's Dolby Atmos setting (r4/t4). Only while running; never
    /// written back. In personalized/stereo the ideal is Off; in surround it is Automatic.
    var musicAtmosAdvisory: String? {
        guard isOn, let setting = musicDolbyAtmosSetting() else { return nil }
        if captureChoice == .surround {
            return setting == 10 ? nil : "For true multichannel, set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Automatic."
        }
        if captureMode == .processTap {
            return setting == 30 ? nil : "For best results set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Off."
        }
        return nil
    }
}

extension EngineController {
    /// Apple Music's "Dolby Atmos" playback setting (10 Automatic, 20 Always On, 30 Off), or nil
    /// when Music never wrote it. Re-read at most every 2 s: the snapshot that reports the
    /// advisory is built at meter rate while a window is visible.
    fileprivate func musicDolbyAtmosSetting() -> Int? {
        let now = Date()
        if let cached = musicSettingCache, now.timeIntervalSince(cached.at) < 2 { return cached.value }
        let raw = CFPreferencesCopyAppValue("preferredDolbyAtmosPlaySetting" as CFString,
                                            "com.apple.Music" as CFString)
        let value = raw.map { ($0 as? NSNumber)?.intValue ?? -1 }
        musicSettingCache = (value, now)
        return value
    }
}
