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

/// Total channel count across all streams on `scope` (0 = none / unreadable). Used to tell
/// the 12-channel surround loopback driver apart from the legacy stereo one.
func deviceChannelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    var sz = dataSize
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
    var total = 0
    for buf in abl { total += Int(buf.mNumberChannels) }
    return total
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
