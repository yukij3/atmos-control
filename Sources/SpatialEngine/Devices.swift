// SpatialEngine/Devices.swift — CoreAudio device enumeration + default-output
// routing (no entitlement required).

import CoreAudio

let kAtmosControlUID = "atmos-control:loopback:0"

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
          dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr
        else { return [] }
    return ids
}

func deviceUID(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, &cfStr) == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, &cfStr) == noErr, let s = cfStr else { return "" }
    return s.takeRetainedValue() as String
}

func deviceHasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    deviceChannelCount(id, scope: scope) > 0
}

/// Per-buffer channel counts from `kAudioDevicePropertyStreamConfiguration` on `scope`.
/// Each entry maps 1-to-1 with the AudioBufferList passed to an AudioDeviceIOProc.
func deviceStreamChannelCounts(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> [UInt32] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    var sz = dataSize
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, raw) == noErr else { return [] }
    let abl = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
    return abl.map { $0.mNumberChannels }
}

/// Virtual stream formats for all streams on `scope`, ordered identically to `kAudioDevicePropertyStreams`.
/// Returns `nil` if Core Audio fails to query stream metadata; returns `[]` when a device has zero streams.
func deviceStreamVirtualFormats(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamBasicDescription]? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr else { return nil }
    guard dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioStreamID>.size
    var streams = [AudioStreamID](repeating: 0, count: count)
    var sz = dataSize
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &streams) == noErr else { return nil }
    var out: [AudioStreamBasicDescription] = []
    out.reserveCapacity(streams.count)
    var fmtAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    for stream in streams {
        var asbd = AudioStreamBasicDescription()
        var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fsz, &asbd) == noErr else { return nil }
        out.append(asbd)
    }
    return out
}

func deviceID(forUID targetUID: String) -> AudioDeviceID? {
    guard !targetUID.isEmpty else { return nil }
    return allDeviceIDs().first { deviceUID($0) == targetUID }
}

func aggregateMainSubDeviceUID(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyMainSubDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfStr: Unmanaged<CFString>? = nil
    var sz = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &cfStr) == noErr, let s = cfStr else { return nil }
    let uid = s.takeRetainedValue() as String
    return uid.isEmpty ? nil : uid
}

/// Enable only `enabledStreams` for `proc` on `scope` (disabling all other streams, e.g. a
/// duplex physical device's microphone input on a tap aggregate).
@discardableResult
func setIOProcStreamUsage(
    _ deviceID: AudioDeviceID,
    proc: AudioDeviceIOProcID,
    scope: AudioObjectPropertyScope,
    enabledStreams: Set<Int>,
    totalStreams: Int
) -> OSStatus {
    guard totalStreams > 0,
          let arrayOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else {
        return noErr
    }
    let byteCount = arrayOffset + totalStreams * MemoryLayout<UInt32>.stride
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
    usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
    usage.pointee.mNumberStreams = UInt32(totalStreams)
    let flags = raw.advanced(by: arrayOffset).assumingMemoryBound(to: UInt32.self)
    for i in 0..<totalStreams {
        flags[i] = enabledStreams.contains(i) ? 1 : 0
    }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIOProcStreamUsage,
        mScope: scope, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(byteCount), raw)
}

/// Total channel count across all streams on `scope` (0 = none / unreadable). Used to tell
/// the 12-channel surround loopback driver apart from the legacy stereo one.
func deviceChannelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    deviceStreamChannelCounts(id, scope: scope).reduce(0) { $0 + Int($1) }
}

func findAtmosControlDevice() -> AudioDeviceID? {
    for id in allDeviceIDs() where deviceUID(id) == kAtmosControlUID { return id }
    // Process-tap aggregates are named atmos-control-tap; only the HAL UID identifies the driver.
    return nil
}

func deviceNominalSampleRate(_ id: AudioDeviceID) -> Double? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var sz = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &rate) == noErr, rate > 0 else { return nil }
    return rate
}

func deviceBufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var frames: UInt32 = 512
    var sz = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &frames) == noErr, frames > 0 else { return 512 }
    return frames
}

func defaultOutputDeviceID(system: Bool = false) -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    return dev
}

@discardableResult
func setDefaultOutputDeviceID(_ id: AudioDeviceID, system: Bool) -> OSStatus {
    var dev = id
    var addr = AudioObjectPropertyAddress(
        mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                          : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}
