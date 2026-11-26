import AudioToolbox
import CoreAudio
import Darwin
import XCTest
@testable import SpatialEngine

final class UnifiedIOTests: XCTestCase {
    func testStereoSamplesAndFrameCountsSurviveAllBufferLayouts() throws {
        for planarInput in [false, true] {
            for planarOutput in [false, true] {
                let frames = 512
                let layout = try UnifiedBufferLayout.resolve(
                    inputChannels: planarInput ? [1, 1] : [2],
                    physicalInputCount: 0,
                    outputChannels: planarOutput ? [1, 1] : [2]
                )
                let context = makeContext(capacity: frames, layout: layout)
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

    func testMonoCallBuffersDuplicateInputAndDownmixOutput() throws {
        let frames = 256
        let layout = try UnifiedBufferLayout.resolve(
            inputChannels: [1],
            physicalInputCount: 0,
            outputChannels: [1]
        )
        XCTAssertEqual(layout.input, .mono(bufferIndex: 0))
        XCTAssertEqual(layout.output, .mono(bufferIndex: 0))

        let context = makeContext(capacity: frames, layout: layout)
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inData = UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 4)
        let outData = UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 4)
        input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: inData)
        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outData)
        defer {
            release(input); release(output)
            release(context.captureABL!); release(context.unifiedOutputABL!)
        }
        let inFloats = inData.assumingMemoryBound(to: Float.self)
        let outFloats = outData.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { inFloats[i] = Float(i + 1) / 512.0; outFloats[i] = -1 }

        XCTAssertEqual(render(context, input: input, output: output), noErr)
        XCTAssertEqual(context.totalCaptured, UInt64(frames))
        XCTAssertEqual(context.totalPlayed, UInt64(frames))
        for i in 0..<frames {
            XCTAssertEqual(outFloats[i], Float(i + 1) / 512.0, accuracy: 1e-6)
        }
    }

    func testDuplexLayoutSelectsTapIndexAndIgnoresDisabledPhysicalMicBuffer() throws {
        let frames = 128
        let layout = try UnifiedBufferLayout.resolve(
            inputChannels: [1, 2],
            physicalInputCount: 1,
            outputChannels: [2]
        )
        XCTAssertEqual(layout.input, .interleavedStereo(bufferIndex: 1))
        XCTAssertEqual(layout.enabledInputStreams, [1])
        XCTAssertEqual(layout.totalInputStreams, 2)

        // Planar stereo tap trailing multiple physical input streams should enable only the tap streams.
        let planarDuplex = try UnifiedBufferLayout.resolve(
            inputChannels: [1, 2, 1, 1],
            physicalInputCount: 2,
            outputChannels: [1, 1]
        )
        XCTAssertEqual(planarDuplex.input, .planarStereo(leftIndex: 2, rightIndex: 3))
        XCTAssertEqual(planarDuplex.output, .planarStereo(leftIndex: 0, rightIndex: 1))
        XCTAssertEqual(planarDuplex.enabledInputStreams, [2, 3])
        XCTAssertEqual(planarDuplex.totalInputStreams, 4)

        // Single non-interleaved stereo stream expands to two 1-channel buffers owned by one stream.
        let nonInterleavedStereo = makeFloatASBD(channels: 2, sampleRate: 48_000)
        let planarSingleStream = try UnifiedBufferLayout.resolve(
            inputChannels: [1, 1, 1, 1],
            physicalInputCount: 2,
            outputChannels: [1, 1],
            inputFormats: [nonInterleavedStereo, nonInterleavedStereo],
            outputFormats: [nonInterleavedStereo]
        )
        XCTAssertEqual(planarSingleStream.input, .planarStereo(leftIndex: 2, rightIndex: 3))
        XCTAssertEqual(planarSingleStream.output, .planarStereo(leftIndex: 0, rightIndex: 1))
        XCTAssertEqual(planarSingleStream.enabledInputStreams, [1])
        XCTAssertEqual(planarSingleStream.totalInputStreams, 2)

        let context = makeContext(capacity: frames, layout: layout)
        let input = AudioBufferList.allocate(maximumBuffers: 2)
        let tapData = UnsafeMutableRawPointer.allocate(byteCount: frames * 8, alignment: 4)
        // Disabled physical microphone stream delivers a nil mData pointer under IOProcStreamUsage.
        input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        input[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: tapData)
        let output = makeBuffers(planar: false, frames: frames)
        defer {
            release(input); release(output)
            release(context.captureABL!); release(context.unifiedOutputABL!)
        }
        let tapFloats = tapData.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            tapFloats[2 * i] = Float(i) / 256.0
            tapFloats[2 * i + 1] = -Float(i) / 512.0
        }

        XCTAssertEqual(render(context, input: input, output: output), noErr)
        XCTAssertEqual(context.totalCaptured, UInt64(frames))
        XCTAssertEqual(context.totalPlayed, UInt64(frames))
        for i in 0..<frames {
            XCTAssertEqual(sample(output, planar: false, channel: 0, frame: i), Float(i) / 256.0)
            XCTAssertEqual(sample(output, planar: false, channel: 1, frame: i), -Float(i) / 512.0)
        }
    }

    func testLayoutResolutionRejectsUnsupportedMultichannelAndNonFloatFormats() {
        // Multichannel output interface (e.g. 8ch interface or multiple stereo streams)
        XCTAssertThrowsError(try UnifiedBufferLayout.resolve(inputChannels: [2], physicalInputCount: 0, outputChannels: [8]))
        XCTAssertThrowsError(try UnifiedBufferLayout.resolve(inputChannels: [2], physicalInputCount: 0, outputChannels: [2, 2]))
        XCTAssertThrowsError(try UnifiedBufferLayout.resolve(inputChannels: [1], physicalInputCount: 1, outputChannels: [2]))
        // Non-Float32 stream format (16-bit signed integer)
        var int16Fmt = makeFloatASBD(channels: 2, sampleRate: 48_000)
        int16Fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        int16Fmt.mBitsPerChannel = 16
        var interleavedFloat = makeFloatASBD(channels: 2, sampleRate: 48_000)
        interleavedFloat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        interleavedFloat.mBytesPerFrame = 8
        interleavedFloat.mBytesPerPacket = 8
        XCTAssertThrowsError(try UnifiedBufferLayout.resolve(
            inputChannels: [2], physicalInputCount: 0, outputChannels: [2],
            inputFormats: [interleavedFloat], outputFormats: [int16Fmt]
        ))
        // Empty virtual formats array must fail rather than silently bypass validation.
        XCTAssertThrowsError(try UnifiedBufferLayout.resolve(
            inputChannels: [2], physicalInputCount: 0, outputChannels: [2],
            inputFormats: [], outputFormats: [interleavedFloat]
        ))
    }

    func testRawABLMatchesAudioBufferListLayout() {
        XCTAssertEqual(MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers), kAudioBufferListBuffersOffset)
        let abl = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(abl.unsafeMutablePointer) }
        for i in 0..<3 { abl[i] = AudioBuffer(mNumberChannels: UInt32(i + 1), mDataByteSize: UInt32(100 * i), mData: nil) }
        let raw = RawABL(abl.unsafeMutablePointer)
        XCTAssertEqual(raw.count, 3)
        for i in 0..<3 {
            XCTAssertEqual(raw[i].mNumberChannels, UInt32(i + 1))
            XCTAssertEqual(raw[i].mDataByteSize, UInt32(100 * i))
        }
        raw[2].mDataByteSize = 7
        XCTAssertEqual(abl[2].mDataByteSize, 7)
    }

    func testUnifiedModeClampsSurroundModesToStereo() {
        XCTAssertEqual(SpatialEngine.effectiveSourceMode(.surround714, unifiedTap: true), .dualPointStereo)
        XCTAssertEqual(SpatialEngine.effectiveSourceMode(.surroundBed714, unifiedTap: true), .dualPointStereo)
        XCTAssertEqual(SpatialEngine.effectiveSourceMode(.ambienceBedStereo, unifiedTap: true), .ambienceBedStereo)
        XCTAssertEqual(SpatialEngine.effectiveSourceMode(.pointSourceMono, unifiedTap: true), .pointSourceMono)
        // Loopback mode preserves 12-channel surround modes.
        XCTAssertEqual(SpatialEngine.effectiveSourceMode(.surround714, unifiedTap: false), .surround714)
        XCTAssertEqual(SpatialEngine.effectiveSourceMode(.surroundBed714, unifiedTap: false), .surroundBed714)
    }

    func testSpatialMixerSupportsDeviceNativeRates() {
        for rate in [16_000.0, 24_000.0, 44_100.0, 48_000.0, 96_000.0] {
            let frames = 512
            let context = makeContext(capacity: frames)
            context.spatialDualPoint = true
            context.dmL = .allocate(capacity: frames); context.dmL!.initialize(repeating: 0, count: frames)
            context.dmR = .allocate(capacity: frames); context.dmR!.initialize(repeating: 0, count: frames)
            context.spatialMaxFrames = UInt32(frames)
            let dp = DistanceParams(referenceDistance: 1.0, maxDistance: 6.0, maxAttenuation: 40.0)
            let rawCtx = UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
            let mixer = makeSpatialMixer(
                ctxPtr: rawCtx, maxFrames: UInt32(frames), mode: .dualPointStereo,
                algo: SpatAlgorithm.useOutputType.rawValue, algoName: "Use Output Type",
                outputType: OutputType.headphones.rawValue, outputTypeName: "Headphones",
                hrtfMode: HRTFMode.auto.rawValue, hrtfModeName: "Auto", headTrack: 1,
                inputSampleRate: rate, outputSampleRate: rate,
                renderFlags: kRenderFlagInterAuralDelay, distanceParams: dp,
                attenCurve: AttenuationCurve.inverse.rawValue, reverbEnabled: false, reverbRoomType: 1)
            XCTAssertNotNil(mixer, "Expected AUSpatialMixer to initialize at \(Int(rate)) Hz")
            if let mixer {
                context.spatialMixer = mixer
                context.spatialize = true
                let input = makeBuffers(planar: false, frames: frames)
                let output = makeBuffers(planar: false, frames: frames)
                for i in 0..<frames {
                    let v = Float(sin(2.0 * .pi * 997.0 * Double(i) / rate)) * 0.25
                    set(input, planar: false, channel: 0, frame: i, value: v)
                    set(input, planar: false, channel: 1, frame: i, value: v)
                }
                XCTAssertEqual(render(context, input: input, output: output), noErr)
                release(input); release(output)
                AudioUnitUninitialize(mixer)
                AudioComponentInstanceDispose(mixer)
            }
            context.dmL?.deallocate(); context.dmR?.deallocate()
            release(context.captureABL!); release(context.unifiedOutputABL!)
        }
    }

    private func makeContext(capacity: Int, layout: UnifiedBufferLayout = .defaultStereoInterleaved) -> Ctx {
        let context = Ctx(channels: 2)
        context.unifiedLayout = layout
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
