import CoreAudio
import AudioToolbox
import Darwin

/// Pre-validated stream indices and buffer formats for the single-IOProc unified path.
/// Resolved once during `SpatialEngine.start()` from Core Audio's stream configuration so
/// the RT callback never guesses buffer indices and unsupported devices fail cleanly at setup.
struct UnifiedBufferLayout: Equatable, Sendable {
    enum ChannelLayout: Equatable, Sendable {
        case interleavedStereo(bufferIndex: Int)
        case planarStereo(leftIndex: Int, rightIndex: Int)
        case mono(bufferIndex: Int)

        var bufferIndices: [Int] {
            switch self {
            case .interleavedStereo(let i), .mono(let i): return [i]
            case .planarStereo(let l, let r): return [l, r]
            }
        }
    }

    let input: ChannelLayout
    let output: ChannelLayout
    /// Tap input stream indices (in `kAudioDevicePropertyStreams` order) to enable via
    /// `kAudioDevicePropertyIOProcStreamUsage`. Any leading physical subdevice mic/line
    /// inputs stay disabled.
    let enabledInputStreams: [Int]
    let totalInputStreams: Int

    static let defaultStereoInterleaved = UnifiedBufferLayout(
        input: .interleavedStereo(bufferIndex: 0),
        output: .interleavedStereo(bufferIndex: 0),
        enabledInputStreams: [0],
        totalInputStreams: 1
    )

    static func resolve(
        inputChannels: [UInt32],
        physicalInputCount: Int,
        outputChannels: [UInt32],
        inputFormats: [AudioStreamBasicDescription]? = nil,
        outputFormats: [AudioStreamBasicDescription]? = nil
    ) throws -> UnifiedBufferLayout {
        guard physicalInputCount >= 0, physicalInputCount <= inputChannels.count else {
            throw SpatialEngineError.setupFailed("invalid aggregate input stream layout (physical=\(physicalInputCount), total=\(inputChannels.count))")
        }

        let tapSlice = Array(inputChannels[physicalInputCount...])
        let inputLayout: ChannelLayout
        switch tapSlice {
        case [2]:
            inputLayout = .interleavedStereo(bufferIndex: physicalInputCount)
        case [1, 1]:
            inputLayout = .planarStereo(leftIndex: physicalInputCount, rightIndex: physicalInputCount + 1)
        case [1]:
            inputLayout = .mono(bufferIndex: physicalInputCount)
        default:
            throw SpatialEngineError.setupFailed("unsupported tap input buffer layout \(tapSlice)")
        }

        let outputLayout: ChannelLayout
        switch outputChannels {
        case [2]:
            outputLayout = .interleavedStereo(bufferIndex: 0)
        case [1, 1]:
            outputLayout = .planarStereo(leftIndex: 0, rightIndex: 1)
        case [1]:
            outputLayout = .mono(bufferIndex: 0)
        default:
            throw SpatialEngineError.setupFailed("unsupported output buffer layout \(outputChannels)")
        }

        let enabledInputStreams: [Int]
        let totalInputStreams: Int
        if let inputFormats {
            let mapping = try mapBuffersToStreams(bufferChannels: inputChannels, streamFormats: inputFormats)
            var streamSet: Set<Int> = []
            for bufIdx in inputLayout.bufferIndices {
                let entry = mapping[bufIdx]
                guard isFloat32PCM(entry.format) else {
                    throw SpatialEngineError.setupFailed("unsupported tap input stream format at buffer \(bufIdx)")
                }
                streamSet.insert(entry.streamIndex)
            }
            enabledInputStreams = streamSet.sorted()
            totalInputStreams = inputFormats.count
        } else {
            enabledInputStreams = inputLayout.bufferIndices
            totalInputStreams = inputChannels.count
        }

        if let outputFormats {
            let mapping = try mapBuffersToStreams(bufferChannels: outputChannels, streamFormats: outputFormats)
            for bufIdx in outputLayout.bufferIndices {
                guard isFloat32PCM(mapping[bufIdx].format) else {
                    throw SpatialEngineError.setupFailed("unsupported output stream format at buffer \(bufIdx)")
                }
            }
        }

        return UnifiedBufferLayout(
            input: inputLayout,
            output: outputLayout,
            enabledInputStreams: enabledInputStreams,
            totalInputStreams: totalInputStreams
        )
    }

    /// Maps each buffer index in `kAudioDevicePropertyStreamConfiguration` to its owning
    /// stream index in `kAudioDevicePropertyStreams` (handling both interleaved 1-buffer
    /// streams and non-interleaved N-buffer streams).
    private static func mapBuffersToStreams(
        bufferChannels: [UInt32],
        streamFormats: [AudioStreamBasicDescription]
    ) throws -> [(streamIndex: Int, format: AudioStreamBasicDescription)] {
        var mapping: [(Int, AudioStreamBasicDescription)] = []
        mapping.reserveCapacity(bufferChannels.count)
        for (streamIdx, asbd) in streamFormats.enumerated() {
            let ch = Int(asbd.mChannelsPerFrame)
            guard ch > 0 else {
                throw SpatialEngineError.setupFailed("stream \(streamIdx) reported 0 channels")
            }
            let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            if nonInterleaved {
                for _ in 0..<ch { mapping.append((streamIdx, asbd)) }
            } else {
                mapping.append((streamIdx, asbd))
            }
        }
        guard mapping.count == bufferChannels.count else {
            throw SpatialEngineError.setupFailed(
                "stream virtual formats map to \(mapping.count) buffer(s), expected \(bufferChannels.count)")
        }
        for (bufIdx, expectedCh) in bufferChannels.enumerated() {
            let asbd = mapping[bufIdx].1
            let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let formatCh: UInt32 = nonInterleaved ? 1 : asbd.mChannelsPerFrame
            guard formatCh == expectedCh else {
                throw SpatialEngineError.setupFailed(
                    "buffer \(bufIdx) channel count (\(expectedCh)) mismatches stream virtual format (\(formatCh))")
            }
        }
        return mapping
    }

    private static func isFloat32PCM(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && asbd.mBitsPerChannel == 32
    }
}

// Device-scoped tap input and physical output share one IO cycle and one clock.
// No independent capture/output clients or drift correction in the tap path.
nonisolated(unsafe) let unifiedTapCallback: AudioDeviceIOProc = {
    _, _, inputData, _, outputData, outputTime, clientData in
    guard let clientData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(clientData).takeUnretainedValue()
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outs = UnsafeMutableAudioBufferListPointer(outputData)
    for b in outs { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
    guard let input = ctx.captureABL, let rendered = ctx.unifiedOutputABL,
          let left = input[0].mData?.assumingMemoryBound(to: Float.self),
          let right = input[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

    let layout = ctx.unifiedLayout
    let n: UInt32
    switch layout.output {
    case .interleavedStereo(let idx):
        guard idx < outs.count, outs[idx].mNumberChannels == 2 else { return noErr }
        n = outs[idx].mDataByteSize / 8
    case .planarStereo(let lIdx, let rIdx):
        guard lIdx < outs.count, rIdx < outs.count,
              outs[lIdx].mNumberChannels == 1, outs[rIdx].mNumberChannels == 1,
              outs[lIdx].mDataByteSize == outs[rIdx].mDataByteSize else { return noErr }
        n = outs[lIdx].mDataByteSize / 4
    case .mono(let idx):
        guard idx < outs.count, outs[idx].mNumberChannels == 1 else { return noErr }
        n = outs[idx].mDataByteSize / 4
    }
    guard n > 0, n <= ctx.captureBufSize else { return noErr }
    let count = Int(n)

    switch layout.input {
    case .interleavedStereo(let idx):
        guard idx < ins.count, ins[idx].mNumberChannels == 2,
              ins[idx].mDataByteSize >= n * 8, let raw = ins[idx].mData else { return noErr }
        let source = raw.assumingMemoryBound(to: Float.self)
        var i = 0
        while i < count { left[i] = source[2 * i]; right[i] = source[2 * i + 1]; i &+= 1 }
    case .planarStereo(let lIdx, let rIdx):
        guard lIdx < ins.count, rIdx < ins.count,
              ins[lIdx].mNumberChannels == 1, ins[rIdx].mNumberChannels == 1,
              ins[lIdx].mDataByteSize >= n * 4, ins[rIdx].mDataByteSize >= n * 4,
              let l = ins[lIdx].mData, let r = ins[rIdx].mData else { return noErr }
        memcpy(left, l, count * 4)
        memcpy(right, r, count * 4)
    case .mono(let idx):
        guard idx < ins.count, ins[idx].mNumberChannels == 1,
              ins[idx].mDataByteSize >= n * 4, let raw = ins[idx].mData else { return noErr }
        memcpy(left, raw, count * 4)
        memcpy(right, raw, count * 4)
    }

    input[0].mDataByteSize = n * 4
    input[1].mDataByteSize = n * 4
    rendered[0].mDataByteSize = n * 4
    rendered[1].mDataByteSize = n * 4
    ctx.totalCaptured &+= UInt64(ctx.ring.writeAll(from: input, frameCount: n))
    for c in 0..<2 {
        let source = c == 0 ? left : right
        var peak: Float = 0
        var i = 0
        while i < count { let a = fabsf(source[i]); if a > peak { peak = a }; i &+= 1 }
        if peak > ctx.capturePeaks[c] { ctx.capturePeaks[c] = peak }
    }

    var flags = AudioUnitRenderActionFlags()
    let status = playbackRenderCallback(clientData, &flags, outputTime, 0, n, rendered.unsafeMutablePointer)
    guard status == noErr,
          let l = rendered[0].mData?.assumingMemoryBound(to: Float.self),
          let r = rendered[1].mData?.assumingMemoryBound(to: Float.self) else { return status }

    switch layout.output {
    case .interleavedStereo(let idx):
        guard let raw = outs[idx].mData else { return noErr }
        let target = raw.assumingMemoryBound(to: Float.self)
        var i = 0
        while i < count { target[2 * i] = l[i]; target[2 * i + 1] = r[i]; i &+= 1 }
    case .planarStereo(let lIdx, let rIdx):
        guard let lo = outs[lIdx].mData, let ro = outs[rIdx].mData else { return noErr }
        memcpy(lo, l, count * 4)
        memcpy(ro, r, count * 4)
    case .mono(let idx):
        guard let raw = outs[idx].mData else { return noErr }
        let target = raw.assumingMemoryBound(to: Float.self)
        var i = 0
        while i < count { target[i] = 0.5 * (l[i] + r[i]); i &+= 1 }
    }
    return noErr
}
