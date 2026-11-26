import AudioToolbox
import XCTest
@testable @_spi(Bench) import SpatialEngine

/// The idle bypass must be invisible: skipping AUSpatialMixer renders while the input is
/// digital silence (and the mixer output has decayed to exact zero) has to produce the
/// same samples as rendering every cycle — including across a live param change and a
/// head-pose move made while the mixer is being skipped.
final class IdleBypassTests: XCTestCase {
    private let rate = 48_000.0
    private let io: UInt32 = 512

    private func render(bypass: Bool, path: OfflinePath, mode: SourceRenderMode = .dualPointStereo,
                        algorithm: SpatAlgorithm = .useOutputType) throws -> (out: [Float], skipped: UInt64) {
        let engine = SpatialEngine()
        var cfg = SpatialConfig()
        cfg.sourceMode = mode
        cfg.algorithm = algorithm
        cfg.reverbEnabled = algorithm != .useOutputType
        engine.config = cfg
        engine.idleBypassEnabled = bypass
        let r = try OfflineRenderer(engine: engine, path: path, sampleRate: rate, ioFrames: io)
        let ch = r.inputChannels
        let blocks = Int(4.0 * rate) / Int(io)
        var rng: UInt64 = 0x1234_5678_9ABC_DEF1
        var input = [Float](repeating: 0, count: Int(io) * ch)
        var out = [Float](repeating: 0, count: blocks * Int(io) * 2)
        for b in 0..<blocks {
            let t = Double(b * Int(io)) / rate
            let audible = t < 1.0 || t >= 3.0                  // 1 s noise, 2 s silence, 1 s noise
            for i in 0..<input.count {
                if audible {
                    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                    input[i] = Float(Int64(bitPattern: rng) >> 40) / Float(1 << 23) * 0.2
                } else {
                    input[i] = 0
                }
            }
            if b == Int(2.0 * rate) / Int(io) { engine.updateSource(azimuth: 25) }        // mid-silence param change
            if b == Int(2.5 * rate) / Int(io) { engine.benchSetHeadPose(yaw: 40, pitch: 5, roll: 0) }  // OS-style pose move
            input.withUnsafeMutableBufferPointer { inp in
                out.withUnsafeMutableBufferPointer { o in
                    _ = r.render(input: inp.baseAddress!, output: o.baseAddress! + b * Int(io) * 2, frames: io)
                }
            }
        }
        return (out, r.idleSkippedBlocks)
    }

    private func assertBypassInvisible(path: OfflinePath, mode: SourceRenderMode = .dualPointStereo,
                                       algorithm: SpatAlgorithm = .useOutputType,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let ref = try render(bypass: false, path: path, mode: mode, algorithm: algorithm)
        let opt = try render(bypass: true, path: path, mode: mode, algorithm: algorithm)
        XCTAssertEqual(ref.skipped, 0, file: file, line: line)
        XCTAssertGreaterThan(opt.skipped, 0, "bypass never engaged", file: file, line: line)
        XCTAssertGreaterThan(ref.out.reduce(0) { max($0, abs($1)) }, 0.01, "reference is silent", file: file, line: line)
        var firstDiff: Int? = nil
        for i in 0..<ref.out.count where ref.out[i].bitPattern != opt.out[i].bitPattern { firstDiff = i; break }
        XCTAssertNil(firstDiff, "bypass changed the output (first diff at sample \(firstDiff ?? -1))", file: file, line: line)
    }

    /// A UI that re-sends unchanged values every tick must not keep the mixer awake;
    /// a real change must re-arm it.
    func testNoOpUpdatesKeepBypassEngaged() throws {
        let engine = SpatialEngine()
        let r = try OfflineRenderer(engine: engine, path: .unifiedTap, sampleRate: rate, ioFrames: io)
        var zeros = [Float](repeating: 0, count: Int(io) * 2)
        var out = [Float](repeating: 0, count: Int(io) * 2)
        func run(_ blocks: Int, each: () -> Void = {}) {
            for _ in 0..<blocks {
                each()
                zeros.withUnsafeMutableBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
                    _ = r.render(input: i.baseAddress!, output: o.baseAddress!, frames: io) } }
            }
        }
        run(50)                                                       // > 250 ms of silence
        let engaged = r.idleSkippedBlocks
        XCTAssertGreaterThan(engaged, 0)
        run(50) {
            engine.updateSource(azimuth: engine.config.azimuth, gain: engine.config.gain)
            engine.updateReverb(blend: engine.config.reverbBlend)
            try? engine.reconfigure(engine.config)
        }
        XCTAssertEqual(r.idleSkippedBlocks, engaged + 50, "no-op updates re-armed the mixer")
        run(1) { engine.updateSource(azimuth: 10) }
        XCTAssertEqual(r.idleSkippedBlocks, engaged + 50, "a real change must render")
    }

    func testUnifiedDualPointIsBitExact() throws { try assertBypassInvisible(path: .unifiedTap) }
    func testUnifiedMonoIsBitExact() throws { try assertBypassInvisible(path: .unifiedTap, mode: .pointSourceMono) }
    func testUnifiedHRTFHQReverbIsBitExact() throws { try assertBypassInvisible(path: .unifiedTap, algorithm: .hrtfHQ) }
    func testLoopbackSurroundIsBitExact() throws { try assertBypassInvisible(path: .loopback, mode: .surround714) }
}
