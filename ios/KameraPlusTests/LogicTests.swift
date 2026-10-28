import XCTest
#if canImport(KameraLogic)
@testable import KameraLogic
#endif

final class TransitionTests: XCTestCase {
    func testEasingMonotone() {
        var prev = -1.0
        for i in 0...1000 {
            let v = Easing.easeInOut(Double(i) / 1000)
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
        XCTAssertEqual(Easing.easeInOut(0), 0)
        XCTAssertEqual(Easing.easeInOut(1), 1)
    }

    func testRevealMonotoneInTimeForAllKinds() {
        var rng = SplitMix64(seed: 5)
        let box = RectD(minX: 200, minY: 300, maxX: 800, maxY: 1100)
        for kind in TransitionKind.allCases {
            let plan = RevealPlan.make(kind: kind, center: Point2(500, 700), cardBounds: box, frameWidth: 1080, frameHeight: 1440,
                                       duration: 0.5, softness: 24, start: 10)
            for _ in 0..<200 {
                let p = Point2(rng.range(0, 1080), rng.range(0, 1440))
                var prev = -1.0
                for k in 0...60 {
                    let t = 9.9 + Double(k) * 0.01
                    let r = plan.reveal(at: p, time: t)
                    XCTAssertGreaterThanOrEqual(r + 1e-12, prev, "\(kind) ikke monoton")
                    XCTAssertTrue((0...1).contains(r))
                    prev = r
                }
            }
            // Før start: forklædt overalt. Efter slut: afsløret overalt.
            XCTAssertEqual(plan.reveal(at: Point2(500, 700), time: 9.99), 0, accuracy: 1e-9)
            XCTAssertEqual(plan.reveal(at: Point2(201, 1099), time: 10.6), 1)
        }
    }

    func testWaveStartsAtFingerAndReachesCorners() {
        let box = RectD(minX: 200, minY: 300, maxX: 800, maxY: 1100)
        let plan = RevealPlan.make(kind: .wave, center: Point2(300, 400), cardBounds: box, frameWidth: 1080, frameHeight: 1440,
                                   duration: 0.5, softness: 20, start: 0)
        XCTAssertGreaterThan(plan.reveal(at: Point2(300, 400), time: 0.2), 0.99)
        XCTAssertLessThan(plan.reveal(at: Point2(800, 1100), time: 0.2), 0.01)
        XCTAssertGreaterThan(plan.reveal(at: Point2(799, 1099), time: 0.4999), 0.5)
        XCTAssertGreaterThan(plan.glow(at: Point2(300 + plan.radius(at: 0.25), 400), time: 0.25), 0.3)
    }

    func testInstantIsHardCut() {
        let plan = RevealPlan.make(kind: .instant, center: .zero, cardBounds: nil, frameWidth: 100, frameHeight: 100,
                                   duration: 0.5, softness: 5, start: 1)
        XCTAssertEqual(plan.reveal(at: Point2(50, 50), time: 0.999), 0)
        XCTAssertEqual(plan.reveal(at: Point2(50, 50), time: 1.0), 1)
        XCTAssertTrue(plan.isComplete(at: 1.0))
    }

    func testSweepGoesTopToBottom() {
        let box = RectD(minX: 0, minY: 100, maxX: 100, maxY: 500)
        let plan = RevealPlan.make(kind: .sweep, center: .zero, cardBounds: box, frameWidth: 100, frameHeight: 600,
                                   duration: 1, softness: 10, start: 0)
        XCTAssertGreaterThan(plan.reveal(at: Point2(50, 120), time: 0.5), plan.reveal(at: Point2(50, 480), time: 0.5))
    }
}

final class StateMachineTests: XCTestCase {
    func plan(_ kind: TransitionKind = .wave, at t: Double = 0) -> RevealPlan {
        RevealPlan.make(kind: kind, center: Point2(50, 50), cardBounds: RectD(minX: 0, minY: 0, maxX: 100, maxY: 140),
                        frameWidth: 270, frameHeight: 360, duration: 0.5, softness: 5, start: t)
    }

    func testTapOnCardRevealsAndStaysRevealed() {
        let m = EffectStateMachine()
        m.noteCard(visible: true, at: 0)
        XCTAssertTrue(m.disguiseShown)
        XCTAssertNil(m.trigger(.tapCard, hitCard: false, plan: plan()), "tryk ved siden af må ikke afsløre")
        XCTAssertEqual(m.trigger(.tapCard, hitCard: true, plan: plan()), .revealStarted(.tapCard))
        XCTAssertTrue(m.disguiseShown, "under bølgen vises forklædningen stadig delvist")
        XCTAssertEqual(m.tick(now: 0.6), [.revealFinished])
        XCTAssertFalse(m.disguiseShown)
        // Kortet forsvinder og kommer igen mange gange (double lift, vending) – forbliver afsløret
        for i in 0..<300 {
            let t = 1 + Double(i) * 0.1
            m.noteCard(visible: i % 7 > 2, at: t)
            XCTAssertTrue(m.tick(now: t).isEmpty)
            XCTAssertTrue(m.isRevealed)
        }
        // Nyt tryk på kortet gør intet
        XCTAssertNil(m.trigger(.tapCard, hitCard: true, plan: plan(at: 40)))
    }

    func testNoCardNoReveal() {
        let m = EffectStateMachine()
        m.config.triggers = Set(TriggerSource.allCases)
        m.noteCard(visible: false, at: 0)
        for s in TriggerSource.allCases { XCTAssertNil(m.trigger(s, hitCard: true, plan: plan())) }
        XCTAssertTrue(m.phase.isDisguised)
    }

    func testOnlyEnabledTriggersWork() {
        let m = EffectStateMachine()
        m.noteCard(visible: true, at: 0)
        XCTAssertNil(m.trigger(.volumeUp, hitCard: false, plan: plan()))
        XCTAssertNil(m.trigger(.shakeCard, hitCard: false, plan: plan()))
        m.config.triggers = [.volumeUp]
        XCTAssertNotNil(m.trigger(.volumeUp, hitCard: false, plan: plan(.instant)))
        XCTAssertTrue(m.isRevealed, "øjeblikkelig afsløring er færdig med det samme")
    }

    func testRestoreMethodsAndHaptic() {
        let m = EffectStateMachine()
        m.config.restores = [.volumeDown]
        m.noteCard(visible: true, at: 0)
        m.trigger(.tapCard, hitCard: true, plan: plan(.instant))
        XCTAssertFalse(m.restore(.phoneShake), "slået fra")
        XCTAssertTrue(m.isRevealed)
        XCTAssertTrue(m.restore(.volumeDown))
        XCTAssertTrue(m.phase.isDisguised)
    }

    func testAutoRestoreOnlyAfterCardGoneLongEnough() {
        let m = EffectStateMachine()
        m.config.restores = [.autoNoCard]
        m.config.autoRestoreSeconds = 3
        m.noteCard(visible: true, at: 0)
        m.trigger(.tapCard, hitCard: true, plan: plan(.instant))
        // kortet væk i 2,5 s (vending) og tilbage → ingen genskab
        m.noteCard(visible: false, at: 0.1)
        XCTAssertTrue(m.tick(now: 2.5).isEmpty)
        m.noteCard(visible: true, at: 2.6)
        m.noteCard(visible: false, at: 2.7)
        XCTAssertTrue(m.tick(now: 5.5).isEmpty)
        XCTAssertEqual(m.tick(now: 5.7), [.restored(.autoNoCard)])
        XCTAssertTrue(m.phase.isDisguised)
    }

    func testAutoRestoreOffByDefault() {
        let m = EffectStateMachine()
        m.noteCard(visible: true, at: 0)
        m.trigger(.tapCard, hitCard: true, plan: plan(.instant))
        m.noteCard(visible: false, at: 1)
        XCTAssertTrue(m.tick(now: 1000).isEmpty)
        XCTAssertTrue(m.isRevealed)
    }

    func testPanicTurnsEffectOffSilently() {
        let m = EffectStateMachine()
        m.noteCard(visible: true, at: 0)
        m.panic()
        XCTAssertFalse(m.effectActive)
        XCTAssertFalse(m.disguiseShown)
        XCTAssertNil(m.trigger(.tapCard, hitCard: true, plan: plan()))
        m.effectActive = true
        XCTAssertTrue(m.disguiseShown)
    }

    func testLaunchBehaviour() {
        let m = EffectStateMachine()
        m.config.restores = [.onLaunch]
        m.launch(wasRevealed: true)
        XCTAssertTrue(m.phase.isDisguised)
        m.config.restores = []
        m.launch(wasRevealed: true)
        XCTAssertTrue(m.isRevealed)
        m.launch(wasRevealed: false)
        XCTAssertTrue(m.phase.isDisguised)
    }

    func testExposureLockPolicy() {
        var p = ExposureLockPolicy()
        var t = 0.0
        for i in 0..<4 { XCTAssertNil(p.update(cardVisible: true, at: t)); t += 0.033; _ = i }
        XCTAssertEqual(p.update(cardVisible: true, at: t), true)
        t += 0.033
        XCTAssertNil(p.update(cardVisible: false, at: t + 1.0))
        XCTAssertNil(p.update(cardVisible: true, at: t + 1.1))
        XCTAssertNil(p.update(cardVisible: false, at: t + 2.0))
        XCTAssertEqual(p.update(cardVisible: false, at: t + 2.7), false)
    }
}

final class ShakeTests: XCTestCase {
    let width = 300.0

    func run(_ d: ShakeDetector, seconds: Double = 2, still: (Double) -> Bool = { _ in true },
             _ f: (Double) -> (Point2, [Point2]?)) -> [Double] {
        var fired: [Double] = []
        var t = 0.0
        while t < seconds {
            let (c, corners) = f(t)
            if d.push(CardTrackSample(t: t, center: c, corners: corners, cardWidth: width, phoneStill: still(t))) { fired.append(t) }
            t += 1.0 / 30
        }
        return fired
    }

    func corners(center c: Point2, angle: Double, scale: Double = 1, tilt: Double = 0) -> [Point2] {
        Quad.rect(center: c, width: width * scale, height: width * 1.4 * scale, angle: angle).corners.enumerated().map { i, p in
            i < 2 ? Point2(c.x + (p.x - c.x) * (1 - tilt), p.y) : p
        }
    }

    func testShakingCardTriggers() {
        for hz in [2.5, 3.0, 4.0] {
            let d = ShakeDetector()
            let fired = run(d) { t in
                let c = Point2(500 + 0.12 * self.width * sin(2 * .pi * hz * t), 700)
                return (c, self.corners(center: c, angle: 0.1))
            }
            XCTAssertFalse(fired.isEmpty, "\(hz) Hz udløste ikke")
            XCTAssertLessThan(fired.first!, 1.6)
        }
    }

    func testTwistShakeTriggersViaCorners() {
        let d = ShakeDetector()
        let fired = run(d) { t in
            let c = Point2(500, 700)
            return (c, self.corners(center: c, angle: 0.25 * sin(2 * .pi * 3 * t)))
        }
        XCTAssertFalse(fired.isEmpty)
    }

    func testCalmMovesDoNotTrigger() {
        let cases: [(String, (Double) -> (Point2, [Point2]?))] = [
            ("roligt flyt", { t in let c = Point2(300 + 150 * t, 600 + 40 * t); return (c, self.corners(center: c, angle: 0)) }),
            ("frem og tilbage én gang", { t in let c = Point2(500 + 120 * sin(.pi * t), 700); return (c, self.corners(center: c, angle: 0)) }),
            ("løft", { t in let c = Point2(500, 700); return (c, self.corners(center: c, angle: 0, scale: 1 + 0.4 * t)) }),
            ("vipning", { t in let c = Point2(500, 700); return (c, self.corners(center: c, angle: 0, tilt: min(0.3, 0.2 * t))) }),
            ("drejning", { t in let c = Point2(500, 700); return (c, self.corners(center: c, angle: 0.8 * t)) }),
            ("rolig drejning frem og tilbage", { t in let c = Point2(500, 700); return (c, self.corners(center: c, angle: 0.3 * sin(.pi * 0.8 * t))) }),
            ("lille rysten (støj)", { t in let c = Point2(500 + 0.02 * self.width * sin(2 * .pi * 5 * t), 700); return (c, self.corners(center: c, angle: 0)) }),
        ]
        for (name, f) in cases {
            let d = ShakeDetector()
            XCTAssertTrue(run(d, seconds: 3, f).isEmpty, "\(name) udløste")
        }
    }

    func testTablePushDoesNotTrigger() {
        // Bordet skubbes: telefonen bevæger sig kort, billedet svinger dæmpet bagefter.
        let d = ShakeDetector()
        let fired = run(d, seconds: 4, still: { t in !(1.0...1.25).contains(t) }) { t in
            let a = t > 1 ? 0.25 * self.width * exp(-(t - 1) * 3.5) * sin(2 * .pi * 4 * (t - 1)) : 0
            let c = Point2(500 + a, 700)
            return (c, self.corners(center: c, angle: 0))
        }
        XCTAssertTrue(fired.isEmpty, "skub udløste ved \(fired)")
    }

    func testCooldownAndSensitivity() {
        let d = ShakeDetector()
        let fired = run(d, seconds: 4) { t in
            let c = Point2(500 + 0.12 * self.width * sin(2 * .pi * 3 * t), 700)
            return (c, nil)
        }
        XCTAssertGreaterThanOrEqual(fired.count, 1)
        for i in 1..<max(1, fired.count) { XCTAssertGreaterThanOrEqual(fired[i] - fired[i - 1], 2.0 - 1e-9) }
        // Hård kræver større udsving
        let hard = ShakeDetector()
        hard.sensitivity = .hard
        XCTAssertTrue(run(hard) { t in (Point2(500 + 0.035 * self.width * sin(2 * .pi * 3 * t), 700), nil) }.isEmpty)
        let light = ShakeDetector()
        light.sensitivity = .light
        XCTAssertFalse(run(light) { t in (Point2(500 + 0.035 * self.width * sin(2 * .pi * 3 * t), 700), nil) }.isEmpty)
    }
}

final class MotionAndGeometryTests: XCTestCase {
    func testOrientation() {
        var o = OrientationTracker()
        XCTAssertFalse(o.update(gravity: (0, -1, 0)))
        XCTAssertTrue(o.update(gravity: (-0.95, -0.1, 0.1)))
        XCTAssertEqual(o.current, .landscapeLeft)
        XCTAssertFalse(o.update(gravity: (0.1, 0, -0.99)), "fladt: behold")
        XCTAssertEqual(o.current, .landscapeLeft)
        XCTAssertTrue(o.update(gravity: (0.9, 0.1, 0)))
        XCTAssertEqual(o.current.degrees, -90)
    }

    func testLevelOnlyWhenFlat() {
        var l = LevelIndicator()
        XCTAssertTrue(l.update(tiltDegrees: MotionMath.tiltFromFlat(gravity: (0.02, 0.03, -0.999))))
        XCTAssertTrue(l.visible)
        XCTAssertFalse(l.update(tiltDegrees: 7))
        XCTAssertTrue(l.update(tiltDegrees: 9))
        XCTAssertFalse(l.visible)
    }

    func testPhoneShakeAndStillness() {
        var p = PhoneShakeDetector()
        var fired = false
        for i in 0..<30 {
            let t = Double(i) / 50
            let a = i % 5 == 0 ? 2.0 : 0.1
            fired = fired || p.push(userAcceleration: (a, 0, 0), t: t)
        }
        XCTAssertTrue(fired)
        var q = PhoneShakeDetector()
        var calm = false
        for i in 0..<200 { calm = calm || q.push(userAcceleration: (0.3, 0.2, 0), t: Double(i) / 50) }
        XCTAssertFalse(calm)
        XCTAssertTrue(MotionMath.isStill(userAcceleration: (0.005, 0.01, 0.0), rotationRate: (0.01, 0, 0.02)))
        XCTAssertFalse(MotionMath.isStill(userAcceleration: (0.2, 0, 0), rotationRate: (0, 0, 0)))
    }

    func testViewMappingRoundTripAndMirror() {
        let m = ViewMapping(viewWidth: 393, viewHeight: 524, frameWidth: 1080, frameHeight: 1440, zoom: 1.25, mirrored: true)
        let p = Point2(100, 200)
        let f = m.framePoint(fromView: p)
        let back = m.viewPoint(fromFrame: f)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        // Venstre side af søgeren er højre side af billedet, når det er spejlet
        XCTAssertGreaterThan(m.framePoint(fromView: Point2(10, 262)).x, 540)
        XCTAssertEqual(m.framePoint(fromView: Point2(196.5, 262)).x, 540, accuracy: 1e-9)
        XCTAssertEqual(m.cropSize.x, 0.8, accuracy: 1e-9)
    }

    func testQuadBasics() {
        let q = Quad.rect(center: Point2(50, 50), width: 20, height: 28, angle: 0.3)
        XCTAssertEqual(q.area, 560, accuracy: 1e-6)
        XCTAssertEqual(q.aspect, 20.0 / 28, accuracy: 1e-9)
        XCTAssertTrue(q.contains(Point2(50, 50)))
        XCTAssertFalse(q.contains(Point2(80, 50)))
        var n = 0
        q.forEachPixel(width: 100, height: 100) { _ in n += 1 }
        XCTAssertEqual(Double(n), 560, accuracy: 30)
    }
}

final class SelfTestTests: XCTestCase {
    func testRandomizedSelfTest5000() {
        let r = SelfTest.run(count: 5000, seed: 2026)
        r.lines.forEach { print("Selvtest:", $0) }
        r.notes.prefix(25).forEach { print("  note:", $0) }
        XCTAssertTrue(r.passed, r.lines.joined(separator: "\n"))
    }

    func testRandomizedSelfTestReverse() {
        let r = SelfTest.run(count: 1500, seed: 77, reverse: true)
        r.lines.forEach { print("Selvtest (omvendt):", $0) }
        r.notes.prefix(25).forEach { print("  note:", $0) }
        XCTAssertTrue(r.passed, r.lines.joined(separator: "\n"))
    }
}
