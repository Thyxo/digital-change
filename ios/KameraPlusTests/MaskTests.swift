import XCTest
#if canImport(KameraLogic)
@testable import KameraLogic
#endif

/// Maske på syntetiske kortbilleder i analyseopløsning (270×360, som ¼ af 1080×1440).
final class MaskTests: XCTestCase {
    let blue = RGB8(hex: Palette.defaultBlueHex)
    let red = RGB8(hex: Palette.defaultRedHex)
    static let W = 270, H = 360

    /// Scene i "fuld" opløsning (540×720) nedskaleret ×2, så mønstret blandes som i appen.
    func render(_ s: SynthScene) -> (RGBAImage, SynthOutput) {
        let out = Synth.render(s)
        return (Downsample.box(out.image, factor: 2), out)
    }

    func downMask(_ m: [Bool], w: Int, h: Int) -> [Bool] {
        let ow = w / 2, oh = h / 2
        var r = [Bool](repeating: false, count: ow * oh)
        for y in 0..<oh { for x in 0..<ow {
            var c = 0
            for dy in 0...1 { for dx in 0...1 where m[(y * 2 + dy) * w + x * 2 + dx] { c += 1 } }
            r[y * ow + x] = c >= 2
        } }
        return r
    }

    func scene(_ backdrop: Backdrop, _ color: RGB8, ink: RGB8?, fingers: [RGB8] = [], angle: Double = 0.15,
               tint: (Double, Double, Double) = (1, 1, 1), cardTint: (Double, Double, Double) = (1, 1, 1)) -> SynthScene {
        var s = SynthScene(width: Self.W * 2, height: Self.H * 2)
        s.backdrop = backdrop
        s.backdropColor = color
        s.tint = tint
        s.cardTint = cardTint
        s.noise = 2
        if let ink {
            var c = SynthCard(center: Point2(Double(Self.W), Double(Self.H) * 1.05), width: Double(Self.W) * 0.9, angle: angle, ink: ink)
            c.lineSpacing = 5
            s.card = c
            for (i, f) in fingers.enumerated() {
                let q = c.quad
                let a = q.corners[i % 4], b = q.corners[(i + 1) % 4]
                let p = Point2((a.x + b.x) / 2, (a.y + b.y) / 2)
                s.fingers.append(Finger(center: p, rx: 22, ry: 60, angle: atan2(b.y - a.y, b.x - a.x) + .pi / 2, color: f))
            }
        } else {
            for (i, f) in fingers.enumerated() {
                s.fingers.append(Finger(center: Point2(Double(150 + 120 * i), 380), rx: 50, ry: 160, angle: 0.3 * Double(i), color: f))
            }
        }
        return s
    }

    func analyzer(_ ink: RGB8) -> CardAnalyzer {
        let src = TestCards.learned(ink)
        let dst = TestCards.learned(ink == blue ? red : blue)
        let a = CardAnalyzer(classifier: CardClassifier(source: src))
        a.illumination = IlluminationModel(source: src, target: dst)
        return a
    }

    func settle(_ a: CardAnalyzer, _ img: RGBAImage, quads: [Quad] = [], frames: Int = 4) -> MaskResult {
        var r = MaskResult()
        for _ in 0..<frames { r = a.analyze(img, quads: quads) }
        return r
    }

    func testCardOnManyBackgroundsAndSkinTones() {
        let backs: [(Backdrop, RGB8)] = [(.ceiling, RGB8(225, 225, 222)), (.whiteWall, RGB8(236, 233, 226)), (.wood, RGB8(150, 100, 60)),
                                         (.darkTable, RGB8(30, 30, 32)), (.gray, RGB8(128, 128, 128)), (.green, RGB8(70, 120, 80)),
                                         (.hand, RGB8(224, 172, 105))]
        for ink in [blue, red] {
            let a = analyzer(ink)
            for (i, (b, col)) in backs.enumerated() {
                let skins = [Synth.skinTones[i % Synth.skinTones.count], Synth.skinTones[(i + 3) % Synth.skinTones.count]]
                let s = scene(b, col, ink: ink, fingers: skins, angle: Double(i) * 0.12 - 0.3)
                let (img, out) = render(s)
                a.reset()
                let r = settle(a, img)
                let gt = downMask(out.inkMask, w: s.width, h: s.height)
                let iou = MaskMetrics.iou(a.processor!.core, gt)
                XCTAssertTrue(r.cardVisible, "\(ink.hex) på \(b) ikke fundet")
                XCTAssertGreaterThanOrEqual(iou, 0.9, "\(ink.hex) på \(b): IoU \(iou)")
            }
        }
    }

    func testNoFalsePositivesOnSkinWoodWall() {
        let backs: [(Backdrop, RGB8)] = [(.hand, RGB8(224, 172, 105)), (.hand, RGB8(141, 85, 36)), (.hand, RGB8(250, 205, 190)),
                                         (.wood, RGB8(150, 100, 60)), (.wood, RGB8(185, 140, 95)), (.whiteWall, RGB8(236, 233, 226)),
                                         (.ceiling, RGB8(240, 238, 230)), (.darkTable, RGB8(25, 25, 25))]
        for ink in [blue, red] {
            let a = analyzer(ink)
            for (b, col) in backs {
                let s = scene(b, col, ink: nil, fingers: [Synth.skinTones[2], Synth.skinTones[5]])
                let (img, _) = render(s)
                a.reset()
                let r = settle(a, img, frames: 8)
                XCTAssertFalse(r.cardVisible, "falsk kort (\(ink.hex)) på \(b) \(col.hex)")
                XCTAssertLessThan(r.coverage, 0.005, "maske på \(b) \(col.hex): \(r.coverage)")
            }
        }
    }

    func testCardFillingWholeFrameIsWholeFrame() {
        var s = SynthScene(width: Self.W * 2, height: Self.H * 2)
        var c = SynthCard(center: Point2(Double(Self.W), Double(Self.H)), width: Double(Self.W) * 4, angle: 0.1, ink: blue)
        c.lineSpacing = 5
        s.card = c
        let (img, _) = render(s)
        let a = analyzer(blue)
        let r = settle(a, img)
        XCTAssertTrue(r.fullFrame)
        XCTAssertTrue(r.cardVisible)
        XCTAssertGreaterThan(r.coverage, 0.99)
    }

    func testCardPartlyOutsideFrame() {
        var s = scene(.ceiling, RGB8(225, 225, 222), ink: blue)
        s.card!.center = Point2(40, Double(Self.H))
        let (img, out) = render(s)
        let a = analyzer(blue)
        let r = settle(a, img)
        XCTAssertTrue(r.cardVisible)
        let iou = MaskMetrics.iou(a.processor!.core, downMask(out.inkMask, w: s.width, h: s.height))
        XCTAssertGreaterThan(iou, 0.88, "IoU \(iou)")
    }

    func testQuadPriorCoversWholeCardIncludingBorder() {
        let s = scene(.wood, RGB8(150, 100, 60), ink: blue, fingers: [Synth.skinTones[1]])
        let (img, out) = render(s)
        let q = Quad(corners: s.card!.quad.corners.map { $0 * 0.5 })
        let a = analyzer(blue)
        let r = settle(a, img, quads: [q])
        XCTAssertNotNil(r.quad)
        let iou = MaskMetrics.iou(a.processor!.core, downMask(out.cardMask, w: s.width, h: s.height))
        XCTAssertGreaterThanOrEqual(iou, 0.9, "IoU \(iou)")
    }

    func testWrongQuadIsIgnored() {
        let s = scene(.ceiling, RGB8(225, 225, 222), ink: blue)
        let (img, _) = render(s)
        let wrong = Quad.rect(center: Point2(40, 40), width: 50, height: 70, angle: 0)
        let a = analyzer(blue)
        let r = settle(a, img, quads: [wrong])
        XCTAssertNil(r.quad)
        XCTAssertTrue(r.cardVisible)
    }

    func testMaskDoesNotBlinkWhenOneFrameDrops() {
        let s = scene(.ceiling, RGB8(225, 225, 222), ink: blue)
        let (img, _) = render(s)
        var empty = SynthScene(width: s.width, height: s.height)
        empty.backdropColor = RGB8(225, 225, 222)
        let (none, _) = render(empty)
        let a = analyzer(blue)
        let full = settle(a, img)
        let before = full.coverage
        let dropped = a.analyze(none)
        XCTAssertGreaterThan(dropped.coverage, before * 0.95, "masken blinkede ved ét tabt billede")
        let back = a.analyze(img)
        XCTAssertGreaterThan(back.coverage, before * 0.95)
        // Efter et stykke tid uden kort er masken væk
        var r = MaskResult()
        for _ in 0..<15 { r = a.analyze(none) }
        XCTAssertLessThan(r.coverage, 0.001)
    }

    func testMovingCardHasNoLeadingEdgeLeak() {
        let a = analyzer(blue)
        var s = scene(.ceiling, RGB8(225, 225, 222), ink: blue)
        s.card!.width = Double(Self.W) * 0.6
        var worst = 1.0
        for f in 0..<20 {
            s.card!.center = Point2(200 + Double(f) * 14, Double(Self.H) + Double(f) * 4)   // 7 px pr. billede i analyse
            s.card!.angle = 0.02 * Double(f)
            let (img, out) = render(s)
            let r = a.analyze(img)
            guard f >= 3 else { continue }
            let gt = downMask(out.inkMask, w: s.width, h: s.height)
            var covered = 0, total = 0
            for i in 0..<gt.count where gt[i] { total += 1; if r.mask[i] >= 128 { covered += 1 } }
            worst = min(worst, Double(covered) / Double(total))
        }
        XCTAssertGreaterThan(worst, 0.97, "forkant ikke dækket: \(worst)")
    }

    func testScreenLightChangeKeepsMask() {
        // Skærmen lyser kortet op nedefra: rødt lys under forklædning, blåt efter afsløring.
        let a = analyzer(blue)
        for tint in [(1.18, 0.92, 0.9), (0.9, 0.95, 1.15), (1.0, 1.0, 1.0), (1.25, 0.88, 0.88), (1.0, 1.0, 1.0)] {
            let s = scene(.ceiling, RGB8(225, 225, 222), ink: blue, cardTint: tint)
            let (img, out) = render(s)
            let r = a.analyze(img)
            let iou = MaskMetrics.iou(a.processor!.core, downMask(out.inkMask, w: s.width, h: s.height))
            XCTAssertTrue(r.cardVisible, "kort tabt ved lys \(tint)")
            XCTAssertGreaterThan(iou, 0.85, "IoU \(iou) ved lys \(tint)")
        }
    }

    func testCoolRoomLightDoesNotMakeWallACard() {
        // Hele rummet i køligt lys: en hvid væg bliver blålig, men er ikke et kort.
        let a = analyzer(blue)
        for back in [Backdrop.ceiling, .whiteWall] {
            let s = scene(back, RGB8(232, 232, 228), ink: nil, tint: (0.93, 0.97, 1.08))
            let (img, _) = render(s)
            a.reset()
            let r = settle(a, img, frames: 6)
            XCTAssertFalse(r.cardVisible, "\(back) i køligt lys regnet for kort")
        }
    }

    func testHitTest() {
        let s = scene(.ceiling, RGB8(225, 225, 222), ink: blue)
        let (img, _) = render(s)
        let a = analyzer(blue)
        _ = settle(a, img)
        let c = s.card!.center * 0.5
        XCTAssertGreaterThanOrEqual(a.processor!.hitFraction(x: c.x, y: c.y, radius: 25), 0.3)
        XCTAssertLessThan(a.processor!.hitFraction(x: 10, y: 10, radius: 25), 0.3)
        // Lige ved kanten: delvist på kortet tæller, hvis mindst 30 %
        let b = a.processor!.last.bounds!
        XCTAssertGreaterThanOrEqual(a.processor!.hitFraction(x: b.minX + 5, y: b.center.y, radius: 25), 0.3)
        XCTAssertLessThan(a.processor!.hitFraction(x: b.minX - 40, y: b.center.y, radius: 25), 0.3)
    }
}
