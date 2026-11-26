// EngineBench --live: brief on-device measurement of the real Personalized (process tap)
// path. Costs the offline bench cannot see: HAL aggregate/tap work on the IO thread, the
// IO wake-up rate actually negotiated, OS head-tracking work inside AUSpatialMixer.

import SpatialEngine
import CoreAudio
import Foundation
import Darwin

private func u32Prop(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var sz = UInt32(4)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr ? v : nil
}

private func rateProp(_ id: AudioObjectID) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Double = 0; var sz = UInt32(8)
    _ = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v)
    return v
}

private struct ThreadSample { let id: UInt64; let name: String; let cpuNS: UInt64 }

/// Per-thread CPU of this process (user + system), keyed by thread id.
private func threadSamples() -> [ThreadSample] {
    var list: thread_act_array_t? = nil
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
    defer {
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    }
    var out: [ThreadSample] = []
    for i in 0..<Int(count) {
        var info = thread_extended_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &n) }
        }
        var idInfo = thread_identifier_info_data_t()
        var n2 = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &idInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n2)) { thread_info(list[i], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &n2) }
        }
        guard kr == KERN_SUCCESS, kr2 == KERN_SUCCESS else { continue }
        let name = withUnsafeBytes(of: info.pth_name) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        out.append(ThreadSample(id: idInfo.thread_id, name: name.isEmpty ? "(unnamed)" : name,
                                cpuNS: info.pth_user_time + info.pth_system_time))
    }
    return out
}

func runLive(seconds: Double, io: UInt32?, pollHz: Double) {
    let outID = SpatialEngine.currentDefaultOutput()
    print("LIVE: default output [\(outID.id)] \(outID.name) @ \(Int(rateProp(outID.id))) Hz, device buffer \(u32Prop(outID.id, kAudioDevicePropertyBufferFrameSize) ?? 0)")
    let tap = ProcessTap()
    let agg: AudioDeviceID
    do { agg = try tap.start(muted: true, outputDeviceID: outID.id) } catch { print("tap failed: \(error)"); return }
    if let io {
        var v = io
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectSetPropertyData(agg, &a, 0, nil, 4, &v)
        print("set aggregate buffer \(io): status \(st)")
    }
    let engine = SpatialEngine()
    engine.config = SpatialConfig()
    do { try engine.start(outputDeviceID: outID.id, captureDeviceID: agg) } catch {
        print("engine start failed: \(error)"); tap.stop(); return
    }
    let aggBuf = u32Prop(agg, kAudioDevicePropertyBufferFrameSize) ?? 0
    print("aggregate [\(agg)] @ \(Int(rateProp(agg))) Hz, IO buffer \(aggBuf) frames (this process' view)")

    Thread.sleep(forTimeInterval: 1.0)          // settle
    var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
    let th0 = Dictionary(threadSamples().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let s0 = engine.pollState()
    let w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var engaged = false
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1.0 / pollHz)
        let s = engine.pollState()
        if s.personalizedHRTFEngaged { engaged = true }
    }
    let w1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let s1 = engine.pollState()
    var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
    let th1 = threadSamples()
    engine.stop()
    tap.stop()

    let wall = Double(w1 - w0)
    func ns(_ t: timeval) -> Double { Double(t.tv_sec) * 1e9 + Double(t.tv_usec) * 1e3 }
    let procCPU = (ns(ru1.ru_utime) + ns(ru1.ru_stime)) - (ns(ru0.ru_utime) + ns(ru0.ru_stime))
    let played = Double(s1.totalPlayed - s0.totalPlayed)
    let rate = rateProp(outID.id)
    print(String(format: "frames played %.0f (%.0f/s, device rate %.0f)  callbacks/s ≈ %.1f  captured Δ %llu",
                 played, played / (wall / 1e9), rate, aggBuf > 0 ? played / Double(aggBuf) / (wall / 1e9) : 0,
                 s1.totalCaptured - s0.totalCaptured))
    print(String(format: "process CPU %.3f%% of one core  vol.csw/s %.0f  invol.csw/s %.0f  3116=%@",
                 procCPU / wall * 100,
                 Double(ru1.ru_nvcsw - ru0.ru_nvcsw) / (wall / 1e9),
                 Double(ru1.ru_nivcsw - ru0.ru_nivcsw) / (wall / 1e9), engaged ? "YES" : "NO"))
    print("per-thread CPU (% of one core):")
    for t in th1 {
        let d = Double(t.cpuNS - (th0[t.id]?.cpuNS ?? 0))
        if d / wall * 100 >= 0.01 {
            print(String(format: "  %7.3f%%  %@", d / wall * 100, t.name))
        }
    }
}
