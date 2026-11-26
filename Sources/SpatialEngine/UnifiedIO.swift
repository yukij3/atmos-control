import CoreAudio
import AudioToolbox
import Darwin
import Accelerate

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
// No independent capture/output clients or drift correction in the tap path, and no ring:
// the de-interleaved tap planes (ctx.captureABL) feed the mixer buses directly (see the
// unified branch of spatialInputCallback). Pure copies are done with vDSP/memcpy, so the
// rendered output is bit-identical to the former ring round-trip.
nonisolated(unsafe) let unifiedTapCallback: AudioDeviceIOProc = {
    _, _, inputData, _, outputData, outputTime, clientData in
    guard let clientData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(clientData).takeUnretainedValue()
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outs = UnsafeMutableAudioBufferListPointer(outputData)
    guard let input = ctx.captureABL, let rendered = ctx.unifiedOutputABL,
          let left = input[0].mData?.assumingMemoryBound(to: Float.self),
          let right = input[1].mData?.assumingMemoryBound(to: Float.self),
          let l = rendered[0].mData?.assumingMemoryBound(to: Float.self),
          let r = rendered[1].mData?.assumingMemoryBound(to: Float.self) else { zeroBuffers(outs); return noErr }

    // Read the two POD enums directly: copying the whole layout struct would retain/release
    // its stream-index array on the IO thread.
    let inLayout = ctx.unifiedLayout.input
    let outLayout = ctx.unifiedLayout.output
    let n: UInt32
    switch outLayout {
    case .interleavedStereo(let idx):
        guard idx < outs.count, outs[idx].mNumberChannels == 2 else { zeroBuffers(outs); return noErr }
        n = outs[idx].mDataByteSize / 8
    case .planarStereo(let lIdx, let rIdx):
        guard lIdx < outs.count, rIdx < outs.count,
              outs[lIdx].mNumberChannels == 1, outs[rIdx].mNumberChannels == 1,
              outs[lIdx].mDataByteSize == outs[rIdx].mDataByteSize else { zeroBuffers(outs); return noErr }
        n = outs[lIdx].mDataByteSize / 4
    case .mono(let idx):
        guard idx < outs.count, outs[idx].mNumberChannels == 1 else { zeroBuffers(outs); return noErr }
        n = outs[idx].mDataByteSize / 4
    }
    guard n > 0, n <= ctx.captureBufSize else { zeroBuffers(outs); return noErr }
    let count = Int(n)

    switch inLayout {
    case .interleavedStereo(let idx):
        guard idx < ins.count, ins[idx].mNumberChannels == 2,
              ins[idx].mDataByteSize >= n * 8, let raw = ins[idx].mData else { zeroBuffers(outs); return noErr }
        var split = DSPSplitComplex(realp: left, imagp: right)
        vDSP_ctoz(raw.assumingMemoryBound(to: DSPComplex.self), 2, &split, 1, vDSP_Length(count))
    case .planarStereo(let lIdx, let rIdx):
        guard lIdx < ins.count, rIdx < ins.count,
              ins[lIdx].mNumberChannels == 1, ins[rIdx].mNumberChannels == 1,
              ins[lIdx].mDataByteSize >= n * 4, ins[rIdx].mDataByteSize >= n * 4,
              let li = ins[lIdx].mData, let ri = ins[rIdx].mData else { zeroBuffers(outs); return noErr }
        memcpy(left, li, count * 4)
        memcpy(right, ri, count * 4)
    case .mono(let idx):
        guard idx < ins.count, ins[idx].mNumberChannels == 1,
              ins[idx].mDataByteSize >= n * 4, let raw = ins[idx].mData else { zeroBuffers(outs); return noErr }
        memcpy(left, raw, count * 4)
        memcpy(right, raw, count * 4)
    }

    input[0].mDataByteSize = n * 4
    input[1].mDataByteSize = n * 4
    rendered[0].mDataByteSize = n * 4
    rendered[1].mDataByteSize = n * 4
    ctx.totalCaptured &+= UInt64(n)
    let peakL = peakMagnitude(left, count)
    let peakR = peakMagnitude(right, count)
    if peakL > ctx.capturePeaks[0] { ctx.capturePeaks[0] = peakL }
    if peakR > ctx.capturePeaks[1] { ctx.capturePeaks[1] = peakR }

    if ctx.spatialize, let mixer = ctx.spatialMixer {
        var flags = AudioUnitRenderActionFlags()
        let status = renderMixerGated(ctx, mixer, &flags, outputTime, n, rendered.unsafeMutablePointer,
                                      inputSilent: peakL == 0 && peakR == 0, ringPeek: nil)
        ctx.totalPlayed &+= UInt64(n)
        guard status == noErr else { zeroBuffers(outs); return status }
    } else {
        // Passthrough (debug): the tap planes go straight out.
        memcpy(l, left, count * 4)
        memcpy(r, right, count * 4)
        ctx.totalPlayed &+= UInt64(n)
    }

    switch outLayout {
    case .interleavedStereo(let idx):
        guard let raw = outs[idx].mData else { return noErr }
        var split = DSPSplitComplex(realp: l, imagp: r)
        vDSP_ztoc(&split, 1, raw.assumingMemoryBound(to: DSPComplex.self), 2, vDSP_Length(count))
        if outs.count > 1 { zeroBuffers(outs, except: idx, idx) }
    case .planarStereo(let lIdx, let rIdx):
        guard let lo = outs[lIdx].mData, let ro = outs[rIdx].mData else { return noErr }
        memcpy(lo, l, count * 4)
        memcpy(ro, r, count * 4)
        if outs.count > 2 { zeroBuffers(outs, except: lIdx, rIdx) }
    case .mono(let idx):
        guard let raw = outs[idx].mData else { return noErr }
        // (L+R)·0.5 — vDSP_vasm computes the identical IEEE result.
        var half: Float = 0.5
        vDSP_vasm(l, 1, r, 1, &half, raw.assumingMemoryBound(to: Float.self), 1, vDSP_Length(count))
        if outs.count > 1 { zeroBuffers(outs, except: idx, idx) }
    }
    return noErr
}

/// Zero every output buffer except the (up to two) the layout writes — device streams the
/// layout does not drive must still be silenced each cycle.
@inline(__always)
private func zeroBuffers(_ abl: UnsafeMutableAudioBufferListPointer, except a: Int, _ b: Int) {
    var i = 0
    while i < abl.count {
        if i != a && i != b, let p = abl[i].mData { memset(p, 0, Int(abl[i].mDataByteSize)) }
        i &+= 1
    }
}
