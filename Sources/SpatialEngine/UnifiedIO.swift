import CoreAudio
import AudioToolbox
import Darwin

// Device-scoped tap input and physical output share one IO cycle and one clock.
// No independent capture/output clients or drift correction in the tap path.
nonisolated(unsafe) let unifiedTapCallback: AudioDeviceIOProc = {
    _, _, inputData, inputTime, outputData, outputTime, clientData in
    guard let clientData else { return noErr }
    let ctx = Unmanaged<Ctx>.fromOpaque(clientData).takeUnretainedValue()
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outs = UnsafeMutableAudioBufferListPointer(outputData)
    for b in outs { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
    guard outs.count > 0, let input = ctx.captureABL, let rendered = ctx.unifiedOutputABL else { return noErr }
    let outChannels = max(outs[0].mNumberChannels, 1)
    let n = outs[0].mDataByteSize / 4 / outChannels
    guard n > 0, n <= ctx.captureBufSize, ins.count > 0,
          let left = input[0].mData?.assumingMemoryBound(to: Float.self),
          let right = input[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let count = Int(n)
    // The tap's buffers trail any physical subdevice inputs. AirPods' output
    // device contributes no microphone input; duplex devices retain this layout.
    let last = ins[ins.count - 1]
    if last.mNumberChannels == 2, let raw = last.mData {
        guard last.mDataByteSize >= n * 8 else { return noErr }
        let source = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<count { left[i] = source[2*i]; right[i] = source[2*i+1] }
    } else if ins.count >= 2,
              let l = ins[ins.count - 2].mData, let r = last.mData {
        guard ins[ins.count - 2].mDataByteSize >= n * 4, last.mDataByteSize >= n * 4 else { return noErr }
        memcpy(left, l, count * 4); memcpy(right, r, count * 4)
    } else {
        left.update(repeating: 0, count: count); right.update(repeating: 0, count: count)
    }
    for c in 0..<2 { input[c].mDataByteSize = n * 4; rendered[c].mDataByteSize = n * 4 }
    ctx.totalCaptured &+= UInt64(ctx.ring.writeAll(from: input, frameCount: n))
    for c in 0..<2 {
        let source = c == 0 ? left : right
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, fabsf(source[i])) }
        ctx.capturePeaks[c] = max(ctx.capturePeaks[c], peak)
    }
    var flags = AudioUnitRenderActionFlags()
    let status = playbackRenderCallback(clientData, &flags, outputTime, 0, n, rendered.unsafeMutablePointer)
    guard status == noErr,
          let l = rendered[0].mData?.assumingMemoryBound(to: Float.self),
          let r = rendered[1].mData?.assumingMemoryBound(to: Float.self) else { return status }
    if outs[0].mNumberChannels == 2, let raw = outs[0].mData {
        let target = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<count { target[2*i] = l[i]; target[2*i+1] = r[i] }
    } else if outs.count >= 2, let lo = outs[0].mData, let ro = outs[1].mData {
        memcpy(lo, l, count * 4); memcpy(ro, r, count * 4)
    }
    return noErr
}
