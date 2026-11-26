// EngineBench --live: brief on-device measurement of the real Personalized (process tap)
// path. Costs the offline bench cannot see: HAL aggregate/tap work on the IO thread, the
// IO wake-up rate actually negotiated, OS head-tracking work inside AUSpatialMixer.

@_spi(Bench) import SpatialEngine
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

// MARK: - Output-only IO proxy (no tap, no capture consent needed)
//
// Runs an IOProc directly on the default output device. Each cycle renders the real
// engine (OfflineRenderer, Personalized-path graph) on synthetic programme into scratch
// and writes SILENCE to the device — so it is inaudible. Measures what the offline bench
// cannot: HAL IO-thread overhead + wake-ups at the negotiated buffer size. It does NOT
// include the process tap / aggregate work (that needs audio-capture consent).

final class ProxyState {
    let renderer: OfflineRenderer?
    let input: UnsafeMutablePointer<Float>
    let scratch: UnsafeMutablePointer<Float>
    let frames: Int
    var pos = 0
    var callbacks = 0
    init(renderer: OfflineRenderer?, input: UnsafeMutablePointer<Float>, frames: Int, maxIO: Int) {
        self.renderer = renderer; self.input = input; self.frames = frames
        scratch = .allocate(capacity: maxIO * 2); scratch.initialize(repeating: 0, count: maxIO * 2)
    }
}

nonisolated(unsafe) let proxyIOProc: AudioDeviceIOProc = { _, _, _, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let st = Unmanaged<ProxyState>.fromOpaque(clientData).takeUnretainedValue()
    let outs = UnsafeMutableAudioBufferListPointer(outputData)
    guard outs.count > 0 else { return noErr }
    let ch = max(Int(outs[0].mNumberChannels), 1)
    let n = Int(outs[0].mDataByteSize) / (4 * ch)
    if let r = st.renderer, n > 0 {
        if st.pos + n > st.frames { st.pos = 0 }
        r.render(input: st.input + st.pos * 2, output: st.scratch, frames: UInt32(n))
        st.pos += n
    }
    var b = 0
    while b < outs.count { if let p = outs[b].mData { memset(p, 0, Int(outs[b].mDataByteSize)) }; b += 1 }
    st.callbacks += 1
    return noErr
}

func runLiveOutputProxy(seconds: Double, io: UInt32?, render: Bool, config: SpatialConfig,
                        input: (Int, Double) -> UnsafeMutablePointer<Float>) {
    let out = SpatialEngine.currentDefaultOutput()
    if let io {
        var v = io
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        print("set buffer \(io): status \(AudioObjectSetPropertyData(out.id, &a, 0, nil, 4, &v))")
    }
    let rate = rateProp(out.id)
    let buf = u32Prop(out.id, kAudioDevicePropertyBufferFrameSize) ?? 512
    print("PROXY: [\(out.id)] \(out.name) @ \(Int(rate)) Hz, IO buffer \(buf), render=\(render)")
    let engine = SpatialEngine()
    engine.config = config
    applyBenchSwitches(engine)
    let renderer = render ? try? OfflineRenderer(engine: engine, path: .unifiedTap, sampleRate: rate, ioFrames: buf) : nil
    let frames = Int(rate) * 4
    let state = ProxyState(renderer: renderer, input: input(frames, rate), frames: frames, maxIO: 8192)
    var proc: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcID(out.id, proxyIOProc, Unmanaged.passUnretained(state).toOpaque(), &proc) == noErr,
          let proc, AudioDeviceStart(out.id, proc) == noErr else { print("proxy IOProc failed"); return }
    Thread.sleep(forTimeInterval: 1.0)
    var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
    let th0 = Dictionary(threadSamples().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let cb0 = state.callbacks
    let k0 = procCounters()
    let w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    Thread.sleep(forTimeInterval: seconds)
    let w1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let k1 = procCounters()
    let cb1 = state.callbacks
    var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
    let th1 = threadSamples()
    AudioDeviceStop(out.id, proc)
    AudioDeviceDestroyIOProcID(out.id, proc)
    let wall = Double(w1 - w0)
    func ns(_ t: timeval) -> Double { Double(t.tv_sec) * 1e9 + Double(t.tv_usec) * 1e3 }
    let procCPU = (ns(ru1.ru_utime) + ns(ru1.ru_stime)) - (ns(ru0.ru_utime) + ns(ru0.ru_stime))
    let secs = wall / 1e9
    print(String(format: "callbacks/s %.1f  process CPU %.3f%%  Minstr/s %.2f  kinstr/cb %.1f  energy %.3f mW  pkgIdleWake/s %.0f  intrWake/s %.0f",
                 Double(cb1 - cb0) / secs, procCPU / wall * 100,
                 Double(k1.instructions - k0.instructions) / secs / 1e6,
                 Double(k1.instructions - k0.instructions) / Double(max(cb1 - cb0, 1)) / 1000,
                 Double(k1.energyNJ - k0.energyNJ) / secs / 1e6,
                 Double(k1.idleWakeups - k0.idleWakeups) / secs, Double(k1.intrWakeups - k0.intrWakeups) / secs))
    for t in th1 {
        let d = Double(t.cpuNS - (th0[t.id]?.cpuNS ?? 0))
        if d / wall * 100 >= 0.005 { print(String(format: "  %7.3f%%  %@", d / wall * 100, t.name)) }
    }
    withExtendedLifetime(state) {}
    withExtendedLifetime(renderer) {}
}
