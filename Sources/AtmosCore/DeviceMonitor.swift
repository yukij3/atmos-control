// DeviceMonitor — watches CoreAudio for device-list and default-output changes
// so the app can fail over gracefully when the real sink disappears (e.g. AirPods
// disconnect) instead of black-holing audio into the virtual default device.

import CoreAudio
import Dispatch

@MainActor
final class DeviceMonitor {
    /// Fired on the main queue when the device list or default output changes.
    var onChange: (() -> Void)?

    private var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start() {
        observe(kAudioHardwarePropertyDevices)
        observe(kAudioHardwarePropertyDefaultOutputDevice)
    }

    func stop() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for (addr, block) in registered {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(sys, &a, DispatchQueue.main, block)
        }
        registered.removeAll()
    }

    // Balance the AudioObjectAddPropertyListenerBlock registrations: stop() had no callers,
    // so the two system-global listeners outlived the monitor. (isolated deinit so the
    // @MainActor-isolated stop() is reachable from teardown.)
    isolated deinit { stop() }

    private func observe(_ selector: AudioObjectPropertySelector) {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        // Block is dispatched on the main queue, so MainActor.assumeIsolated is valid.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                               DispatchQueue.main, block) == noErr {
            registered.append((addr, block))
        }
    }
}
