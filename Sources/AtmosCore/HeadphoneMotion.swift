// HeadphoneMotion — reads live AirPods head orientation (yaw) via CoreMotion to
// drive the radar's head-pose visualization. The actual audio head-tracking is
// done inside AUSpatialMixer (property 3111); this is the matching UI mirror.
// Degrades silently when no motion-capable headphones are present.

import CoreMotion

@MainActor
final class HeadphoneMotion {
    /// Called on the main queue with the latest yaw (radians) while active.
    var onYaw: ((Double) -> Void)?

    private let manager = CMHeadphoneMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.onYaw?(motion.attitude.yaw) }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }
}
