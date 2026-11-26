// EngineBench — offline CPU benchmark + null-test regression harness for SpatialEngine.
//
// Drives the real render path (same AUSpatialMixer graph + the same RT callbacks the
// IOProc / AUHAL threads run, via the `@_spi(Bench)` OfflineRenderer) with deterministic
// synthetic input. No device IO, nothing is played or captured.
//
//   swift run -c release EngineBench                    # full matrix, CPU table
//   swift run -c release EngineBench --filter hq        # only cases whose name contains "hq"
//   swift run -c release EngineBench --record /tmp/ref  # write reference renders (one .f32 per case)
//   swift run -c release EngineBench --compare /tmp/ref # null-test current renders vs reference
//   swift run -c release EngineBench --profile default --seconds 30   # long single-case loop (xctrace)
//   options: --seconds S (audio seconds per rep, default 8) --reps R (default 5) --paced (real-time pacing)
//
//   swift run -c release EngineBench --live 6 [--live-io 1024] [--live-poll 15]
//     LIVE (captures + mutes real system audio for N seconds through the Personalized tap
//     path into the default output): reports the negotiated IO buffer, callbacks/s and
//     per-thread CPU of this process. Run it on the target Mac (AirPods connected) to see
//     costs the offline bench cannot (HAL/tap work on the IO thread, head tracking).
//     NOTE: needs audio-capture consent; without it AudioDeviceStart blocks on the prompt.
//   swift run -c release EngineBench --proxy 6 [--live-io 1024] [--proxy-silent]
//     Output-only proxy (no tap, no consent prompt, inaudible): an IOProc on the default
//     output renders the engine into scratch and writes silence; measures HAL IO-thread
//     overhead + wake-ups at the negotiated buffer size.
//
// CPU is thread CPU time (CLOCK_THREAD_CPUTIME_ID) of the render loop divided by the audio
// time rendered = % of one core the engine needs at real time. Param/meter/head-pose updates
// are issued from the same loop at the stated rates (in the app they run on the main thread).

@_spi(Bench) import SpatialEngine
import Foundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Options

nonisolated(unsafe) var optSeconds = 8.0
nonisolated(unsafe) var optReps = 5
nonisolated(unsafe) var optFilter: [String] = []
nonisolated(unsafe) var optRecord: String? = nil
nonisolated(unsafe) var optCompare: String? = nil
nonisolated(unsafe) var optProfile: String? = nil
nonisolated(unsafe) var optPaced = false
nonisolated(unsafe) var optList = false
nonisolated(unsafe) var optLive: Double? = nil
nonisolated(unsafe) var optLiveIO: UInt32? = nil
nonisolated(unsafe) var optLivePollHz = 1.0
nonisolated(unsafe) var optProxy: Double? = nil
nonisolated(unsafe) var optProxyRender = true
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--seconds": optSeconds = Double(it.next() ?? "") ?? optSeconds
        case "--reps": optReps = Int(it.next() ?? "") ?? optReps
        case "--filter": optFilter = (it.next() ?? "").split(separator: ",").map(String.init)
        case "--record": optRecord = it.next()
        case "--compare": optCompare = it.next()
        case "--profile": optProfile = it.next()
        case "--paced": optPaced = true
        case "--list": optList = true
        case "--live": optLive = Double(it.next() ?? "") ?? 5
        case "--live-io": optLiveIO = UInt32(it.next() ?? "")
        case "--live-poll": optLivePollHz = Double(it.next() ?? "") ?? 1
        case "--proxy": optProxy = Double(it.next() ?? "") ?? 5
        case "--proxy-silent": optProxyRender = false
        default: print("unknown option \(a)"); exit(2)
        }
    }
}

// MARK: - Cases

enum Signal: String { case music, silence, intermittent }

struct Case {
    var name: String
    var path: OfflinePath = .unifiedTap
    var rate: Double = 48_000
    var io: UInt32 = 512
    var signal: Signal = .music
    var sourceHz: Double = 0      // updateSource(azimuth:) drag rate
    var headPoseHz: Double = 0    // emulated head-tracker rotation rate (mixer head yaw/pitch/roll)
    var pollHz: Double = 15       // pollState() (meters) rate; the app polls at 15 Hz while visible
    var tweak: (inout SpatialConfig) -> Void = { _ in }
}

func c(_ name: String, _ build: (inout Case) -> Void = { _ in }) -> Case {
    var k = Case(name: name); build(&k); return k
}

let allCases: [Case] = [
    // Default app configuration: Personalized (unified tap) path, Stereo Points, Use Output Type.
    c("default"),
    c("default-silence") { $0.signal = .silence },
    c("default-intermittent") { $0.signal = .intermittent },
    c("default-nopoll") { $0.pollHz = 0 },
    c("default-poll30") { $0.pollHz = 30 },
    c("default-headpose50") { $0.headPoseHz = 50 },
    c("default-headpose100") { $0.headPoseHz = 100 },
    c("default-drag60") { $0.sourceHz = 60 },
    c("default-ht-off") { $0.tweak = { $0.headTracking = false } },
    c("default-hrtf-on") { $0.tweak = { $0.hrtfMode = .on } },
    c("default-hrtf-off") { $0.tweak = { $0.hrtfMode = .off } },
    c("default-io128") { $0.io = 128 },
    c("default-io256") { $0.io = 256 },
    c("default-io1024") { $0.io = 1024 },
    c("default-io2048") { $0.io = 2048 },
    c("default-44k") { $0.rate = 44_100 },
    c("default-24k") { $0.rate = 24_000 },
    c("default-16k") { $0.rate = 16_000 },
    c("bed") { $0.tweak = { $0.sourceMode = .ambienceBedStereo } },
    c("mono") { $0.tweak = { $0.sourceMode = .pointSourceMono } },
    c("speakers-builtin") { $0.tweak = { $0.outputType = .builtInSpeakers } },
    c("hrtf") { $0.tweak = { $0.algorithm = .hrtf; $0.reverbEnabled = false } },
    c("hrtf-reverb") { $0.tweak = { $0.algorithm = .hrtf; $0.reverbEnabled = true } },
    c("hrtfhq") { $0.tweak = { $0.algorithm = .hrtfHQ; $0.reverbEnabled = false } },
    c("hrtfhq-reverb") { $0.tweak = { $0.algorithm = .hrtfHQ; $0.reverbEnabled = true } },
    c("hrtfhq-reverb-silence") { $0.signal = .silence; $0.tweak = { $0.algorithm = .hrtfHQ; $0.reverbEnabled = true } },
    c("hrtfhq-reverb-intermittent") { $0.signal = .intermittent; $0.tweak = { $0.algorithm = .hrtfHQ; $0.reverbEnabled = true } },
    c("passthrough") { $0.tweak = { $0.spatialize = false } },
    // Virtual-device (loopback HAL driver) path.
    c("loop-dual") { $0.path = .loopback },
    c("loop-dual-silence") { $0.path = .loopback; $0.signal = .silence },
    c("loop-surround") { $0.path = .loopback; $0.tweak = { $0.sourceMode = .surround714 } },
    c("loop-surround-silence") { $0.path = .loopback; $0.signal = .silence; $0.tweak = { $0.sourceMode = .surround714 } },
    c("loop-surround-intermittent") { $0.path = .loopback; $0.signal = .intermittent; $0.tweak = { $0.sourceMode = .surround714 } },
    c("loop-surround-hrtfhq-reverb") { $0.path = .loopback; $0.tweak = { $0.sourceMode = .surround714; $0.algorithm = .hrtfHQ; $0.reverbEnabled = true } },
    c("loop-surroundbed") { $0.path = .loopback; $0.tweak = { $0.sourceMode = .surroundBed714 } },
    c("loop-passthrough") { $0.path = .loopback; $0.tweak = { $0.spatialize = false } },
]

func selected(_ k: Case) -> Bool {
    if let p = optProfile { return k.name == p }
    return optFilter.isEmpty || optFilter.contains { k.name.contains($0) }
}

// MARK: - Deterministic synthetic programme material

struct XorShift { var s: UInt64; mutating func next() -> Float {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17
    return Float(Int64(bitPattern: s) >> 11) / Float(1 << 52)   // ~[-1, 1)
} }

/// "Music": pink-ish noise (Paul Kellet filter) + three slowly AM'd partials, partially
/// decorrelated L/R, around −14 dBFS RMS. Surround gets 12 distinct channels.
func makeSignal(_ sig: Signal, channels ch: Int, frames: Int, rate: Double) -> UnsafeMutablePointer<Float> {
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames * ch)
    buf.initialize(repeating: 0, count: frames * ch)
    if sig == .silence { return buf }
    var rng = XorShift(s: 0x9E37_79B9_7F4A_7C15)
    var b = [[Float]](repeating: [Float](repeating: 0, count: 7), count: ch)
    let partials: [Double] = [110, 440, 1760]
    for i in 0..<frames {
        let t = Double(i) / rate
        if sig == .intermittent && Int(t / 2.0) % 2 == 1 { continue }   // 2 s on / 2 s off
        let common = rng.next()
        for c in 0..<ch {
            let white = 0.6 * rng.next() + 0.4 * common
            b[c][0] = 0.99886 * b[c][0] + white * 0.0555179
            b[c][1] = 0.99332 * b[c][1] + white * 0.0750759
            b[c][2] = 0.96900 * b[c][2] + white * 0.1538520
            b[c][3] = 0.86650 * b[c][3] + white * 0.3104856
            b[c][4] = 0.55000 * b[c][4] + white * 0.5329522
            b[c][5] = -0.7616 * b[c][5] - white * 0.0168980
            let pink = b[c][0] + b[c][1] + b[c][2] + b[c][3] + b[c][4] + b[c][5] + b[c][6] + white * 0.5362
            b[c][6] = white * 0.115926
            var tone = 0.0
            for (k, f) in partials.enumerated() {
                let am = 0.5 + 0.5 * sin(2 * .pi * (0.3 + 0.2 * Double(k)) * t + Double(c))
                tone += am * sin(2 * .pi * f * (1 + 0.001 * Double(c)) * t)
            }
            buf[i * ch + c] = 0.05 * pink + Float(0.06 * tone)
        }
    }
    return buf
}

// MARK: - Runner

func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
func wallNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
/// Whole-process CPU (all threads): catches work an AU might push to helper threads.
func processCPU() -> UInt64 {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    func ns(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1000 }
    return ns(ru.ru_utime) + ns(ru.ru_stime)
}

/// Frequency-independent work + CLPC energy estimate for this process (no root needed).
struct ProcCounters { var instructions: UInt64 = 0; var cycles: UInt64 = 0; var energyNJ: UInt64 = 0
                      var idleWakeups: UInt64 = 0; var intrWakeups: UInt64 = 0 }
func procCounters() -> ProcCounters {
    var ri = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    guard ok == 0 else { return ProcCounters() }
    return ProcCounters(instructions: ri.ri_instructions, cycles: ri.ri_cycles, energyNJ: ri.ri_energy_nj,
                        idleWakeups: ri.ri_pkg_idle_wkups, intrWakeups: ri.ri_interrupt_wkups)
}

struct RunResult { var cpuPct: Double; var procPct: Double; var kInstrPerCallback: Double; var milliwatts: Double; var usPerCallback: Double }

final class Session {
    let k: Case
    let engine = SpatialEngine()
    let r: OfflineRenderer
    let input: UnsafeMutablePointer<Float>
    let output: UnsafeMutablePointer<Float>
    let frames: Int
    let ch: Int
    var block = 0

    init(_ k: Case, seconds: Double) throws {
        self.k = k
        var cfg = SpatialConfig()
        k.tweak(&cfg)
        engine.config = cfg
        r = try OfflineRenderer(engine: engine, path: k.path, sampleRate: k.rate, ioFrames: k.io)
        ch = r.inputChannels
        let blocks = Int((seconds * k.rate) / Double(k.io)) + 1
        frames = blocks * Int(k.io)
        input = makeSignal(k.signal, channels: ch, frames: frames, rate: k.rate)
        output = .allocate(capacity: frames * 2)
        output.initialize(repeating: 0, count: frames * 2)
    }
    deinit { input.deallocate(); output.deallocate() }

    /// Render `blocks` IO cycles starting at the session's running block index (wrapping
    /// over the generated programme), issuing the case's param/meter/head-pose events.
    func run(blocks: Int, writeOut: Bool, paced: Bool = false) {
        let io = Int(k.io)
        let perBlock = Double(k.io) / k.rate
        let blocksInBuf = frames / io
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let blockTicks = UInt64(perBlock * 1e9) * UInt64(tb.denom) / UInt64(tb.numer)
        var deadline = mach_absolute_time()
        for _ in 0..<blocks {
            let t0 = Double(block) * perBlock, t1 = t0 + perBlock
            func crosses(_ hz: Double) -> Bool { hz > 0 && floor(t1 * hz) != floor(t0 * hz) }
            if crosses(k.pollHz) { _ = engine.pollState() }
            if crosses(k.sourceHz) { engine.updateSource(azimuth: Float(40 * sin(2 * .pi * 0.25 * t0))) }
            if crosses(k.headPoseHz) {
                engine.benchSetHeadPose(yaw: Float(60 * sin(2 * .pi * 0.2 * t0)),
                                        pitch: Float(10 * sin(2 * .pi * 0.13 * t0)),
                                        roll: Float(5 * sin(2 * .pi * 0.07 * t0)))
            }
            let off = (block % blocksInBuf) * io
            let out = writeOut ? output + off * 2 : output
            r.render(input: input + off * ch, output: out, frames: k.io)
            block += 1
            if paced { deadline &+= blockTicks; mach_wait_until(deadline) }
        }
    }
}

func measure(_ k: Case) throws -> (median: RunResult, min: RunResult) {
    let s = try Session(k, seconds: optSeconds)
    s.run(blocks: Int(1.0 * k.rate) / Int(k.io), writeOut: false)          // warm-up 1 s
    let blocks = Int(optSeconds * k.rate) / Int(k.io)
    let audioNS = Double(blocks) * Double(k.io) / k.rate * 1e9
    var results: [RunResult] = []
    for _ in 0..<optReps {
        let c0 = threadCPU(), p0 = processCPU(), k0 = procCounters()
        s.run(blocks: blocks, writeOut: false, paced: optPaced)
        let c1 = threadCPU(), p1 = processCPU(), k1 = procCounters()
        let cpu = Double(c1 - c0)
        results.append(RunResult(cpuPct: cpu / audioNS * 100,
                                 procPct: Double(p1 - p0) / audioNS * 100,
                                 kInstrPerCallback: Double(k1.instructions - k0.instructions) / Double(blocks) / 1000,
                                 milliwatts: Double(k1.energyNJ - k0.energyNJ) / audioNS * 1000,
                                 usPerCallback: cpu / Double(blocks) / 1000))
    }
    let sorted = results.sorted { $0.cpuPct < $1.cpuPct }
    return (sorted[sorted.count / 2], sorted[0])
}

// MARK: - Null test (record / compare)

let refSeconds = 6.0   // covers two on/off periods of the intermittent signal

func renderReference(_ k: Case) throws -> [Float] {
    let s = try Session(k, seconds: refSeconds)
    let blocks = s.frames / Int(k.io)
    s.run(blocks: blocks, writeOut: true)
    return Array(UnsafeBufferPointer(start: s.output, count: s.frames * 2))
}

func write(_ v: [Float], to path: String) throws {
    try v.withUnsafeBufferPointer { try Data(buffer: $0).write(to: URL(fileURLWithPath: path)) }
}
func read(_ path: String) -> [Float]? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func db(_ x: Double) -> String { x > 0 ? String(format: "%.1f", 20 * log10(x)) : "-inf" }

// MARK: - Main

pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
if let secs = optLive { runLive(seconds: secs, io: optLiveIO, pollHz: optLivePollHz); exit(0) }
if let secs = optProxy {
    // --filter selects the bench case whose config + signal the proxy renders (default "default").
    let k = allCases.first { $0.name == (optFilter.first ?? "default") } ?? allCases[0]
    var cfg = SpatialConfig(); k.tweak(&cfg)
    print("proxy case: \(k.name)")
    runLiveOutputProxy(seconds: secs, io: optLiveIO, render: optProxyRender, config: cfg) { frames, rate in
        makeSignal(k.signal, channels: 2, frames: frames, rate: rate)
    }
    exit(0)
}
let cases = allCases.filter(selected)
if optList { for k in allCases { print(k.name) }; exit(0) }
if cases.isEmpty { print("no case matches"); exit(2) }

if let name = optProfile, let k = cases.first {
    print("profiling \(name) for \(optSeconds) s of audio (paced=\(optPaced))")
    let s = try Session(k, seconds: min(optSeconds, 10))
    let blocks = Int(optSeconds * k.rate) / Int(k.io)
    let c0 = threadCPU()
    s.run(blocks: blocks, writeOut: false, paced: optPaced)
    print(String(format: "cpu %.2f%% of one core", Double(threadCPU() - c0) / (optSeconds * 1e9) * 100))
    exit(0)
}

if let dir = optRecord {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for k in cases {
        let v = try renderReference(k)
        try write(v, to: "\(dir)/\(k.name).f32")
        let peak = v.reduce(Float(0)) { max($0, abs($1)) }
        print("recorded \(k.name)  frames=\(v.count / 2)  peak=\(db(Double(peak))) dBFS")
    }
    exit(0)
}

if let dir = optCompare {
    var worst = -Double.infinity
    print("case                              maxAbsDiff(dBFS)  diffRMS/refRMS(dB)  refPeak(dBFS)")
    var failed = false
    for k in cases {
        guard let ref = read("\(dir)/\(k.name).f32") else { print("\(k.name): no reference"); continue }
        let cur = try renderReference(k)
        guard ref.count == cur.count else { print("\(k.name): length mismatch \(ref.count) vs \(cur.count)"); failed = true; continue }
        var maxDiff: Double = 0, sumD: Double = 0, sumR: Double = 0, peak: Double = 0
        for i in 0..<ref.count {
            let d = Double(cur[i]) - Double(ref[i])
            maxDiff = max(maxDiff, abs(d)); sumD += d * d; sumR += Double(ref[i]) * Double(ref[i])
            peak = max(peak, abs(Double(ref[i])))
        }
        let rel = sumR > 0 ? (sumD > 0 ? 10 * log10(sumD / sumR) : -Double.infinity) : (sumD > 0 ? Double.infinity : -Double.infinity)
        worst = max(worst, maxDiff > 0 ? 20 * log10(maxDiff) : -Double.infinity)
        print(k.name.padding(toLength: 34, withPad: " ", startingAt: 0)
              + db(maxDiff).padding(toLength: 18, withPad: " ", startingAt: 0)
              + (rel.isFinite ? String(format: "%.1f", rel) : (rel > 0 ? "+inf" : "-inf")).padding(toLength: 20, withPad: " ", startingAt: 0)
              + db(peak))
    }
    print(String(format: "worst maxAbsDiff: %@ dBFS", worst.isFinite ? String(format: "%.1f", worst) : "-inf"))
    exit(failed ? 1 : 0)
}

print("EngineBench  seconds/rep=\(optSeconds)  reps=\(optReps)  paced=\(optPaced)  (CPU = % of one core at real time, median of reps)")
print("case                              path        rate   io     cpu%    min%    proc%   us/cb   kinstr/cb  mW(proc)  x-realtime")
for k in cases {
    do {
        let (m, lo) = try measure(k)
        print(k.name.padding(toLength: 34, withPad: " ", startingAt: 0)
              + k.path.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
              + String(format: "%-7.0f%-7u%-8.3f%-8.3f%-8.3f%-8.2f%-11.1f%-10.3f%.0f", k.rate, k.io, m.cpuPct, lo.cpuPct,
                       m.procPct, m.usPerCallback, m.kInstrPerCallback, m.milliwatts, 100 / max(m.cpuPct, 1e-9)))
    } catch {
        print("\(k.name): FAILED \(error)")
    }
}
