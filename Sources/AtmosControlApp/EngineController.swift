// EngineController — @MainActor view-model bridging SwiftUI ↔ SpatialEngine.
// Owns the power on/off orchestration (default-output routing) and a poll timer
// that publishes live engine telemetry (peaks, 3116, ring fill) to the UI.
//
// Uses the Observation framework (@Observable) rather than ObservableObject so SwiftUI
// tracks per-property reads: a meter-rate write no longer invalidates the whole tree,
// only the views that actually read the changed property.

import SwiftUI
import AppKit
import CoreAudio
import Observation
import SpatialEngine

/// How the engine captures system audio.
enum CaptureMode: String, CaseIterable, Identifiable {
    case processTap      // muting process tap; AirPods stay default → personalized HRTF + no black-hole
    case loopbackDriver  // hijack the default to the atmos-control loopback; generic HRTF only
    var id: String { rawValue }
    var label: String { self == .processTap ? "Personalized (tap)" : "Loopback driver" }
}

@MainActor
@Observable
final class EngineController {
    var isOn = false
    var isStarting = false
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var pendingDeviceChange = false
    @ObservationIgnored private var pendingFormatChange = false
    @ObservationIgnored private var formatRetryWorkItem: DispatchWorkItem?
    @ObservationIgnored private let audioQueue = DispatchQueue(label: "dev.atmoscontrol.audio-control", qos: .userInitiated)
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

    // Surface visibility. The MenuBarExtra(.window) popover's visibility is taken from its
    // NSWindow (bindPanelWindow) because SwiftUI .onDisappear is not reliably delivered when
    // that popover dismisses; the Settings Window's onAppear/onDisappear ARE reliable.
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var settingsOnScreen = false
    @ObservationIgnored private weak var panelWindow: NSWindow?   // weak: don't pin the hidden popover window
    @ObservationIgnored private var panelOcclusionObserver: NSObjectProtocol?

    /// The engine can run for the CURRENT capture choice. Personalized (tap) needs no driver;
    /// the virtual-device options need the HAL device (Surround needs the 12-channel variant).
    /// The panel never collapses on this — a false value only disables the power toggle and
    /// shows an inline notice (F11).
    var canRun: Bool {
        if isStarting { return false }
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
        let wasOn = isOn
        let prevMode = captureMode
        switch choice {
        case .personalized:
            captureMode = .processTap
            if config.sourceMode.isSurroundMode { config.sourceMode = .dualPointStereo }
            if !wasOn {
                let cur = SpatialEngine.currentDefaultOutput()
                if cur.id != SpatialEngine.atmosControlDeviceID() { outputName = cur.name }
            }
        case .virtualStereo:
            captureMode = .loopbackDriver
            if config.sourceMode.isSurroundMode { config.sourceMode = .dualPointStereo }
        case .surround:
            captureMode = .loopbackDriver
            config.sourceMode = .surround714
        }
        guard wasOn else { return }
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

    /// The live controller. Production creates exactly one (the App's @State model); the
    /// app delegate uses this to run cleanup on quit / logout / shutdown without building a
    /// second engine. (Preview mode's throwaway controller may overwrite it — harmless,
    /// since preview never powers on.)
    static weak var shared: EngineController?

    init() {
        EngineController.shared = self
        atmosPresent = engine.atmosControlPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        let cur = SpatialEngine.currentDefaultOutput()
        outputName = cur.name
        outputs = engine.outputDevices()

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

    private func outputType(for dev: AudioOutputDevice) -> OutputType {
        Self.defaultOutputType(for: dev)
    }

    /// Pick which real sink to route through (loopback modes only; nil = follow the system default).
    /// Personalized tap mode always follows the system default output so apps are not silenced.
    func selectOutput(_ dev: AudioOutputDevice?) {
        guard captureMode == .loopbackDriver else { return }
        selectedOutputID = dev?.id
        if let d = dev { outputName = d.name; config.outputType = outputType(for: d) }
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

        guard isOn else {
            let cur = SpatialEngine.currentDefaultOutput()
            if cur.id != SpatialEngine.atmosControlDeviceID() { outputName = cur.name }
            return
        }
        if captureMode == .processTap {
            let cur = SpatialEngine.currentDefaultOutput()
            guard let next = devices.first(where: { $0.id == cur.id }) else {
                lastError = "Output device disconnected — engine stopped."
                powerOff()
                return
            }
            if next.id != activeSinkID {
                cancelFormatRetry()
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
        config.outputType = outputType(for: fallback)
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
                self.activeSinkID = dev.id
                self.outputName = dev.name
                self.lastError = "Output changed — now routing to \(dev.name)."
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
            let engine = self.engine, tap = self.tap, baseConfig = config
            performAudioChange({
                try Self.startTapSession(engine: engine, tap: tap, baseConfig: baseConfig)
            }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let (aggregate, dev, resolvedOutputType, devices)):
                    self.outputs = devices
                    self.config.outputType = resolvedOutputType
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
    /// (Counted because the panel and settings window can be open independently.)
    /// Panel (MenuBarExtra popover) visibility — the authoritative signal is the popover
    /// NSWindow (see bindPanelWindow). onAppear/onDisappear are kept only as a fallback.
    func panelAppeared()    { panelOnScreen = true;  updateActivity() }
    func panelDisappeared() { panelOnScreen = false; updateActivity() }
    /// Settings is a normal Window scene whose onAppear/onDisappear are reliable.
    func settingsAppeared()    { settingsOnScreen = true;  updateActivity() }
    func settingsDisappeared() { settingsOnScreen = false; updateActivity() }

    private var anySurfaceVisible: Bool { panelOnScreen || settingsOnScreen }

    /// Bind the panel popover's hosting NSWindow (handed over by WindowAccessor when the
    /// view moves in/out of a window). Drives visibility from the window leaving the
    /// hierarchy AND from occlusion — so polling/motion stop the instant the popover is
    /// dismissed, even though SwiftUI does not reliably deliver .onDisappear for it.
    func bindPanelWindow(_ window: NSWindow?) {
        guard window !== panelWindow else { return }
        if let obs = panelOcclusionObserver {
            NotificationCenter.default.removeObserver(obs)
            panelOcclusionObserver = nil
        }
        panelWindow = window
        guard let window else { panelOnScreen = false; updateActivity(); return }
        // OR so a transient not-yet-on-screen occlusion read at bind time can't clobber a
        // `true` just set by onAppear; the observer below corrects it within a frame anyway.
        panelOnScreen = panelOnScreen || window.occlusionState.contains(.visible)
        panelOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Registered for this window only; read it back on the main actor (avoids
                // sending the non-Sendable Notification across the isolation boundary).
                let visible = self.panelWindow?.occlusionState.contains(.visible) ?? false
                if self.panelOnScreen != visible { self.panelOnScreen = visible; self.updateActivity() }
            }
        }
        updateActivity()
    }

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
            headPoseLive = false
            headYaw = 0
        }
    }

    // MARK: Power

    func toggle() { isOn ? powerOff() : powerOn() }

    func powerOn() {
        guard !isStarting, !isOn else { return }
        atmosPresent = engine.atmosControlPresent()
        surroundDriverInstalled = engine.surroundDriverInstalled()
        permissionNeeded = false
        if captureMode == .processTap { startTapMode(); return }
        startLoopbackMode()   // explicit virtual-device (loopback) mode — never an auto-fallback
    }

    /// Deep-link into System Settings ▸ Privacy so the user can grant audio-capture consent.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explicit, user-initiated retry after a permission failure (does NOT change routing).
    func retryCapture() { permissionNeeded = false; powerOn() }

    /// Explicit, user-initiated switch to the virtual-device path (this one DOES change the
    /// default output — so it only happens on a deliberate tap, never as a silent fallback).
    func switchToVirtualDevice() {
        permissionNeeded = false
        setCaptureChoice(.virtualStereo)
        if !isOn { powerOn() }
    }

    /// Shared audioQueue helper for starting or rebuilding a device-scoped process-tap session.
    private nonisolated static func startTapSession(
        engine: SpatialEngine,
        tap: ProcessTap,
        baseConfig: SpatialConfig,
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
        snapshot.outputType = defaultOutputType(for: real)
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
        let engine = self.engine, tap = self.tap, baseConfig = config
        performAudioChange({
            try Self.startTapSession(
                engine: engine, tap: tap, baseConfig: baseConfig,
                restoreLoopbackDefault: restoreLoopbackDefault)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (aggregate, real, resolvedOutputType, devices)):
                self.outputs = devices
                self.config.outputType = resolvedOutputType
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
        audioQueue.async { [weak self] in
            let result = Result(catching: operation)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStarting = false
                completion(result)
                self.drainPendingEvents()
            }
        }
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
        if let r = real { config.outputType = outputType(for: r); outputName = r.name }
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
            stopRequested = true
            pendingDeviceChange = false
            pendingFormatChange = false
            return
        }
        let restoreDefault = savedDefault
        let needsTeardown = isOn || tap.isActive || restoreDefault != nil
        isOn = false
        savedDefault = nil
        resetLiveTelemetry()
        guard needsTeardown else { return }
        let engine = self.engine, tap = self.tap
        performAudioChange({
            engine.stop()
            if tap.isActive { tap.stop() }
            if let restoreDefault {
                Self.restoreSafeDefault(savedDefault: restoreDefault, engine: engine)
            }
        }) { _ in }
    }

    /// Synchronous teardown for applicationWillTerminate so the process never exits before
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
        savedDefault = nil
        resetLiveTelemetry()
    }

    /// Switch the capture path (restarts atomically if running).
    func setCaptureMode(_ m: CaptureMode) {
        guard !isStarting, captureMode != m else { return }
        setCaptureChoice(m == .processTap ? .personalized : (config.sourceMode.isSurroundMode ? .surround : .virtualStereo))
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
        guard !isStarting, isOn else { return }
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
        if let d = distance { config.distance = d }
        if let g = gain { config.gain = g }
        if let w = width { config.stereoWidth = w }
        guard !isStarting, isOn, formatRetryWorkItem == nil else { return }
        engine.updateSource(azimuth: azimuth, elevation: elevation, distance: distance, gain: gain, width: width)
    }

    /// Live reverb wet/dry blend (no rebuild; no-op in the engine unless the reverb path is
    /// active, i.e. HRTF / HRTF-HQ).
    func setReverbBlend(_ v: Float) {
        config.reverbBlend = v
        guard !isStarting, isOn, formatRetryWorkItem == nil else { return }
        engine.updateReverb(blend: v)
    }

    /// Reset the soundstage to the front-and-centre default (F13 / amendment B).
    func resetSoundstage() {
        setSource(azimuth: 0, elevation: 0, distance: Float(Param.distance.def),
                  gain: 0, width: Float(Param.width.def))
    }

    /// Reset the advanced rendering block to its defaults (amendment B).
    func resetRendering() {
        config.interauralDelay = true
        config.distanceAttenuation = false
        config.attenuationCurve = .inverse
        config.distanceRef = Float(Param.distanceRef.def)
        config.distanceMax = Float(Param.distanceMax.def)
        config.distanceMaxAtten = Float(Param.distanceAtten.def)
        config.reverbEnabled = true
        config.reverbRoomType = .medium
        config.reverbBlend = Float(Param.reverbBlend.def)
        config.globalReverbGain = Float(Param.reverbGain.def)
        config.algorithm = .useOutputType
        applyConfig()
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

    // MARK: Derived UI state

    /// Single truthful personalization status (spec §1): a chip short-form, a settings long-form
    /// with a plain-language reason, and whether the accent "engaged" treatment applies.
    struct HRTFStatus { let short: String; let long: String; let engaged: Bool }

    var hrtfStatus: HRTFStatus {
        if !isOn { return HRTFStatus(short: "—", long: "Inactive — engine off", engaged: false) }
        if personalizedHRTFEngaged {
            return HRTFStatus(short: "Personalized", long: "Personalized — Apple profile active", engaged: true)
        }
        if captureMode == .loopbackDriver {
            return HRTFStatus(short: "Generic", long: "Generic — virtual-device output can’t carry a personalized profile", engaged: false)
        }
        if config.outputType != .headphones {
            return HRTFStatus(short: "Generic", long: "Generic — personalized applies to headphones only", engaged: false)
        }
        if config.algorithm != .useOutputType {
            return HRTFStatus(short: "Generic", long: "Generic — personalized needs the Automatic algorithm", engaged: false)
        }
        return HRTFStatus(short: "Generic", long: "Generic — set AirPods with an Apple personalized profile as the system output", engaged: false)
    }

    /// Head-tracking status (F14): Off (disabled) · Idle (enabled, not tracking) · Tracking
    /// (enabled, engine running AND live pose). Never claim "Tracking" without live pose.
    var headTrackStatus: String {
        guard config.headTracking else { return "Off" }
        return (isOn && headPoseLive) ? "Tracking" : "Idle"
    }
    var headTrackActive: Bool { config.headTracking && isOn && headPoseLive }

    /// True when personalized HRTF (property 3116) can never engage in the current config, so
    /// the HRTF-mode picker should be disabled with a reason (F4).
    var personalizationDisabledReason: String? {
        if captureMode == .loopbackDriver { return "Unavailable with the virtual device." }
        if config.outputType != .headphones { return "Personalized applies to headphones only." }
        if config.algorithm != .useOutputType { return "Needs the Automatic algorithm." }
        return nil
    }

    /// Advisory about Apple Music's Dolby Atmos setting (r4/t4). Only while running; never
    /// written back. In personalized/stereo the ideal is Off; in surround it is Automatic.
    var musicAtmosAdvisory: String? {
        guard isOn else { return nil }
        guard let raw = CFPreferencesCopyAppValue("preferredDolbyAtmosPlaySetting" as CFString,
                                                  "com.apple.Music" as CFString) else { return nil }
        let setting = (raw as? NSNumber)?.intValue ?? -1   // 10=Automatic 20=Always On 30=Off
        if captureChoice == .surround {
            return setting == 10 ? nil : "For true multichannel, set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Automatic."
        }
        if captureMode == .processTap {
            return setting == 30 ? nil : "For best results set Music ▸ Settings ▸ Playback ▸ Dolby Atmos to Off."
        }
        return nil
    }
}

// dBFS helpers shared by the meters/readouts.
func linearToDb(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
