import CoreMotion
import QuartzCore

/// CoreMotion: ikonernes drejning, vaterlinje, "ligger telefonen stille" (til ryst kortet) og "ryst telefonen" (genskab).
@MainActor
final class MotionManager {
    private let manager = CMMotionManager()
    private var orientation = OrientationTracker()
    private var level = LevelIndicator()
    private var phoneShake = PhoneShakeDetector()

    var onRotation: ((IconRotation) -> Void)?
    var onLevel: ((Bool) -> Void)?
    var onPhoneShake: (() -> Void)?
    weak var state: MotionState?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let m else { return }
            MainActor.assumeIsolated { self?.handle(m) }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    private func handle(_ m: CMDeviceMotion) {
        let g = (m.gravity.x, m.gravity.y, m.gravity.z)
        if orientation.update(gravity: g) { onRotation?(orientation.current) }
        if level.update(tiltDegrees: MotionMath.tiltFromFlat(gravity: g)) { onLevel?(level.visible) }
        let a = (m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z)
        let r = (m.rotationRate.x, m.rotationRate.y, m.rotationRate.z)
        state?.phoneStill = MotionMath.isStill(userAcceleration: a, rotationRate: r)
        if phoneShake.push(userAcceleration: a, t: CACurrentMediaTime()) { onPhoneShake?() }
    }
}
