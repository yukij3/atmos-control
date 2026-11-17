import AudioToolbox
import CoreAudio
import Darwin
import XCTest
@testable import SpatialEngine

final class UnifiedIOTests: XCTestCase {
    func testStereoSamplesAndFrameCountsSurviveAllBufferLayouts() {
        for planarInput in [false, true] {
            for planarOutput in [false, true] {
                let frames = 512
                let context = makeContext(capacity: frames)
                let input = makeBuffers(planar: planarInput, frames: frames)
                let output = makeBuffers(planar: planarOutput, frames: frames)
                defer {
                    release(input); release(output)
                    release(context.captureABL!); release(context.unifiedOutputABL!)
                }
                for i in 0..<frames {
                    set(input, planar: planarInput, channel: 0, frame: i, value: Float(i) / 1024)
                    set(input, planar: planarInput, channel: 1, frame: i, value: -Float(i) / 2048)
                }

                XCTAssertEqual(render(context, input: input, output: output), noErr)
                XCTAssertEqual(context.totalCaptured, UInt64(frames))
                XCTAssertEqual(context.totalPlayed, UInt64(frames))
                XCTAssertEqual(context.ring.fill(), 0)
                for i in 0..<frames {
                    XCTAssertEqual(sample(output, planar: planarOutput, channel: 0, frame: i), Float(i) / 1024)
                    XCTAssertEqual(sample(output, planar: planarOutput, channel: 1, frame: i), -Float(i) / 2048)
                }
            }
        }
    }

    func testOversizedCallbackProducesSilenceWithoutConsumingFrames() {
        let context = makeContext(capacity: 512)
        let input = makeBuffers(planar: false, frames: 513)
        let output = makeBuffers(planar: false, frames: 513)
        defer {
            release(input); release(output)
            release(context.captureABL!); release(context.unifiedOutputABL!)
        }
        XCTAssertEqual(render(context, input: input, output: output), noErr)
        XCTAssertEqual(context.totalCaptured, 0)
        XCTAssertEqual(context.totalPlayed, 0)
        for i in 0..<513 {
            XCTAssertEqual(sample(output, planar: false, channel: 0, frame: i), 0)
            XCTAssertEqual(sample(output, planar: false, channel: 1, frame: i), 0)
        }
    }

    private func makeContext(capacity: Int) -> Ctx {
        let context = Ctx(channels: 2)
        context.captureBufSize = UInt32(capacity)
        context.captureABL = makeCaptureABL(maxFrames: UInt32(capacity), channels: 2)
        context.unifiedOutputABL = makeCaptureABL(maxFrames: UInt32(capacity), channels: 2)
        return context
    }

    private func makeBuffers(planar: Bool, frames: Int) -> UnsafeMutableAudioBufferListPointer {
        let buffers = AudioBufferList.allocate(maximumBuffers: planar ? 2 : 1)
        for i in 0..<buffers.count {
            let bytes = frames * 4 * (planar ? 1 : 2)
            let data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4)
            data.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
            buffers[i] = AudioBuffer(mNumberChannels: planar ? 1 : 2,
                                     mDataByteSize: UInt32(bytes), mData: data)
        }
        return buffers
    }

    private func release(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers { buffer.mData?.deallocate() }
        free(buffers.unsafeMutablePointer)
    }

    private func sample(_ buffers: UnsafeMutableAudioBufferListPointer, planar: Bool,
                        channel: Int, frame: Int) -> Float {
        buffers[planar ? channel : 0].mData!.assumingMemoryBound(to: Float.self)[planar ? frame : 2 * frame + channel]
    }

    private func set(_ buffers: UnsafeMutableAudioBufferListPointer, planar: Bool,
                     channel: Int, frame: Int, value: Float) {
        buffers[planar ? channel : 0].mData!.assumingMemoryBound(to: Float.self)[planar ? frame : 2 * frame + channel] = value
    }

    private func render(_ context: Ctx, input: UnsafeMutableAudioBufferListPointer,
                        output: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid
        return withUnsafePointer(to: &timestamp) { time in
            unifiedTapCallback(0, time, input.unsafeMutablePointer, time,
                               output.unsafeMutablePointer, time,
                               Unmanaged.passUnretained(context).toOpaque())
        }
    }
}
