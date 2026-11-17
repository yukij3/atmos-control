import CoreAudio
import Foundation
import XCTest
@testable import SpatialEngine

final class DevicesTests: XCTestCase {
    func testProcessTapAggregateDoesNotBecomeLoopbackDriver() throws {
        let driverBefore = findAtmosControlDevice()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "atmos-control-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
        ]
        var aggregate: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        XCTAssertEqual(status, noErr)
        guard status == noErr else { return }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        let detected = findAtmosControlDevice()
        XCTAssertNotEqual(detected, aggregate,
                          "The private capture aggregate must not activate loopback drift correction")
        XCTAssertEqual(detected, driverBefore)
    }
}
