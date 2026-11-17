// TapSpike — Phase 4 premium-tier proof. Captures the system mix via a MUTING
// process tap (SpatialEngine.ProcessTap) and re-spatializes it through our
// AUSpatialMixer, WITHOUT making any virtual device the system default. AirPods
// stay the default output, so Apple's personalized HRTF (property 3116) keeps
// engaging — the thing the virtual-default loopback architecture blocks.
//
// PRE-REQ: AirPods (with a scanned Personalized Spatial Audio profile) selected as
// the system output. No virtual driver / daemon needed.
//
// Env:
//   RUN_SECONDS=N        run length (default 15)
//   MUTE=0|1             1 = silence the original apps (default); 0 = capture only
//   OUTPUT_DEVICE=<sub>  output device substring (default: AirPods, else default)
//   HRTF_MODE=on|auto    PersonalizedHRTFMode (default on)

import Foundation
import CoreAudio
import AudioToolbox
import SpatialEngine

func runTapSpike() {
    setvbuf(stdout, nil, _IONBF, 0)
    func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
    let runSeconds = Int(env("RUN_SECONDS") ?? "") ?? 15
    let muted = (env("MUTE") ?? "1") != "0"

    print("=== TapSpike — personalized HRTF (3116) via muting process tap ===")

    // --- 1. Muting process tap → private aggregate (the capture device) ---
    let tap = ProcessTap()
    let aggID: AudioDeviceID
    do {
        aggID = try tap.start(muted: muted)
    } catch {
        print("  ERR \(error)"); exit(1)
    }
    print("tap aggregate device = \(aggID)  (muted=\(muted))")

    // --- 2. Resolve the real output (AirPods); confirm the default is UNCHANGED ---
    let engine = SpatialEngine()
    engine.logger = { print($0) }
    let outs = engine.outputDevices()
    let wanted = env("OUTPUT_DEVICE")
    let out: AudioOutputDevice? = {
        if let w = wanted, !w.isEmpty { return outs.first { $0.name.localizedCaseInsensitiveContains(w) } }
        return outs.first { $0.isAirPods } ?? outs.first { $0.id == SpatialEngine.currentDefaultOutput().id }
    }()
    let defBefore = SpatialEngine.currentDefaultOutput()
    print("default output = [\(defBefore.id)] \(defBefore.name)  (must be AirPods for 3116=YES)")
    if out?.isAirPods != true { print("  WARN no AirPods output found — 3116 will read NO (plumbing-only run)") }

    // --- 3. Spatialize the tapped mix → AirPods, personalization forced on ---
    var cfg = SpatialConfig()
    cfg.spatialize = true
    cfg.outputType = .headphones
    cfg.algorithm = .useOutputType
    cfg.hrtfMode = (env("HRTF_MODE")?.lowercased() == "auto") ? .auto : .on
    cfg.headTracking = true
    engine.config = cfg

    do {
        try engine.start(outputDeviceID: out?.id, captureDeviceID: aggID)
    } catch {
        print("  ERR engine.start \(error)"); tap.stop(); exit(1)
    }
    print("engine started: capture=aggregate[\(aggID)] output=[\(out?.id ?? 0)] \(out?.name ?? "?")")
    print("--- play audio in any app now ---")

    var everEngaged = false
    let firstCaptured = engine.pollState().totalCaptured
    var lastCaptured = firstCaptured
    for t in 1...max(1, runSeconds) {
        Thread.sleep(forTimeInterval: 1)
        let s = engine.pollState()
        let on = engine.readPersonalizedHRTFEngaged()
        if on { everEngaged = true }
        lastCaptured = s.totalCaptured
        print(String(format: "t=%2ds  captured=%llu  played=%llu  ringFill=%llu  peak=%.4f  3116=%@",
                     t, s.totalCaptured, s.totalPlayed, s.ringFill, s.peakL, on ? "YES" : "NO"))
    }

    engine.stop()
    tap.stop()

    let defAfter = SpatialEngine.currentDefaultOutput()
    print("---")
    print("default output after = [\(defAfter.id)] \(defAfter.name)  (\(defAfter.id == defBefore.id ? "UNCHANGED ✅" : "CHANGED ❌"))")
    print("captured rose (audio flowed through the tap): \(lastCaptured > firstCaptured ? "YES ✅" : "NO — was anything playing?")")
    print("3116 personalized HRTF engaged at any point: \(everEngaged ? "YES ✅ — premium unlock CONFIRMED" : "NO ❌")")

}
DispatchQueue.global(qos: .userInitiated).async { runTapSpike(); exit(0) }
dispatchMain()
