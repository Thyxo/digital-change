import XCTest
#if canImport(KameraLogic)
@testable import KameraLogic
#endif

enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Cards")
    }
    private static var cached: CardTemplates?
    static func templates() throws -> CardTemplates {
        if let c = cached { return c }
        let t = try CardTemplates.load(directory: directory)
        cached = t
        return t
    }
}

final class HomographyTests: XCTestCase {
    func testFromPointsRoundTripAndInverse() {
        let src = [Point2(0, 0), Point2(1024, 0), Point2(1024, 1424), Point2(0, 1424)]
        let dst = [Point2(100, 80), Point2(400, 95), Point2(420, 520), Point2(90, 500)]
        let h = Homography.from(src, to: dst)!
        for (a, b) in zip(src, dst) { XCTAssertLessThan(h.apply(a).distance(b), 1e-6) }
        let inv = h.inverse!
        for (a, b) in zip(src, dst) { XCTAssertLessThan(inv.apply(b).distance(a), 1e-6) }
        let id = (h * inv)
        for p in dst { XCTAssertLessThan(id.apply(p).distance(p), 1e-6) }
    }
}

final class TemplateTests: XCTestCase {
    func testTemplatesLoadWithMeasuredGeometry() throws {
        let t = try Fixtures.templates()
        let g = t.blue.geometry
        XCTAssertEqual(g.width, 1024)
        XCTAssertEqual(g.height / g.width, 1424.0 / 1024, accuracy: 0.01)
        XCTAssertGreaterThan(g.pattern.minX, 40); XCTAssertLessThan(g.pattern.maxX, g.width - 40)
        XCTAssertEqual(t.blue.image.width, 256)
        XCTAssertEqual(t.red.geometry, g)
    }

    func testInkColorsAndSamePaper() throws {
        let t = try Fixtures.templates()
        // gennemsnit af mønstret
        func patternMean(_ c: CardTemplate) -> SIMD3<Double> {
            let L = c.colors[0], g = c.geometry, k = c.scale0
            var s = SIMD3<Double>.zero, n = 0.0
            for y in 0..<L.height { for x in 0..<L.width {
                let p = Point2((Double(x) + 0.5) / k, (Double(y) + 0.5) / k)
                if p.x > g.pattern.minX + 10 && p.x < g.pattern.maxX - 10 && p.y > g.pattern.minY + 10 && p.y < g.pattern.maxY - 10 {
                    s += L.sample(Double(x) + 0.5, Double(y) + 0.5)!; n += 1
                }
            } }
            return s / n
        }
        let b = patternMean(t.blue), r = patternMean(t.red)
        XCTAssertGreaterThan(b.z, b.x * 1.5, "blå skabelon er ikke blå")
        XCTAssertGreaterThan(r.x, r.z * 1.5, "rød skabelon er ikke rød")
        // papirhvidt er normaliseret ens (prepare-cards.py)
        for i in 0..<3 { XCTAssertEqual(t.blue.paper[i], t.red.paper[i], accuracy: 0.03) }
    }

    /// De to skabeloner er lagt præcist oven på hinanden: lysstyrkemønstret falder sammen (en pixels forskydning
    /// giver markant lavere korrelation).
    func testBlueAndRedPatternsAreAligned() throws {
        let t = try Fixtures.templates()
        let a = t.blue.luma[0], b = t.red.luma[0], g = t.blue.geometry, k = t.blue.scale0
        func corr(dx: Int, dy: Int) -> Double {
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
            let x0 = Int(g.pattern.minX * k) + 4, x1 = Int(g.pattern.maxX * k) - 4
            let y0 = Int(g.pattern.minY * k) + 4, y1 = Int(g.pattern.maxY * k) - 4
            for y in y0..<y1 { for x in x0..<x1 {
                let u = Double(a.data[y * a.width + x]), v = Double(b.data[(y + dy) * b.width + x + dx])
                sa += u; sb += v; saa += u * u; sbb += v * v; sab += u * v; n += 1
            } }
            let cov = sab / n - sa * sb / (n * n)
            return cov / ((saa / n - sa * sa / (n * n)) * (sbb / n - sb * sb / (n * n))).squareRoot()
        }
        let c0 = corr(dx: 0, dy: 0)
        print("Korrelation blå/rød: \(c0), forskudt 1 px: \(corr(dx: 1, dy: 0)), \(corr(dx: 0, dy: 1))")
        XCTAssertGreaterThan(c0, 0.9)
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] { XCTAssertGreaterThan(c0, corr(dx: dx, dy: dy) + 0.05) }
    }
}

final class TrackerTests: XCTestCase {
    private func scene(_ t: CardTemplate, center: Point2 = Point2(180, 240), width: Double = 200, angle: Double = 0.2,
                       fingers: [Finger] = []) -> (SynthScene, SynthOutput) {
        var s = SynthScene(width: 360, height: 480)
        s.backdrop = .wood
        s.backdropColor = RGB8(150, 100, 60)
        var c = SynthCard.placed(t, center: center, width: width, angle: angle, tiltX: 0.05, tiltY: -0.08)
        c.gain = SIMD3(1.1, 0.95, 0.9)
        c.offset = SIMD3(repeating: 0.01)
        s.card = c
        s.fingers = fingers
        s.noise = 2
        return (s, Synth.render(s))
    }

    private func maxCornerError(_ a: Quad, _ b: Quad) -> Double {
        let direct = zip(a.corners, b.corners).map { $0.distance($1) }.max()!
        let rot = zip(a.corners, b.corners.suffix(2) + b.corners.prefix(2)).map { $0.distance($1) }.max()!
        return min(direct, rot)
    }

    func testLocksFromRoughQuadWithSubpixelCorners() throws {
        let t = try Fixtures.templates()
        let (s, out) = scene(t.blue)
        let truth = s.card!.quad
        var rng = SplitMix64(seed: 3)
        let tracker = CardTracker(template: t.blue)
        let r = tracker.update(out.image, candidates: [Synth.noisyQuad(truth, rng: &rng, sigma: 4)])
        let tr = try XCTUnwrap(r.track)
        let e = maxCornerError(tr.quad, truth)
        print("Hjørnefejl \(e) px, score \(tr.score), \(tracker.lastAlignMs) ms")
        XCTAssertLessThan(e, 0.6)
        XCTAssertGreaterThan(tr.score, 0.8)
        // lyset er målt: rødt lys > blåt
        XCTAssertGreaterThan(tr.gain.x, tr.gain.z)
    }

    func testLocksFromInkColorWithoutAnyQuad() throws {
        let t = try Fixtures.templates()
        let finger = Finger(center: Point2(180, 115), rx: 25, ry: 60, angle: 1.4, color: Synth.skinTones[1])
        for (tmpl, angle) in [(t.blue, 0.2), (t.blue, -0.5), (t.red, 0.3)] {
            let (s, out) = scene(tmpl, angle: angle, fingers: [finger])
            let tracker = CardTracker(template: tmpl)
            let r = tracker.update(out.image)
            let tr = try XCTUnwrap(r.track, "ikke fundet uden firkant (\(tmpl.color), \(angle)): \(tracker.lastReject)")
            XCTAssertLessThan(maxCornerError(tr.quad, s.card!.quad), 0.8)
        }
    }

    func testInteriorFalseOcclusionIsRemoved() {
        // en "plet" midt i området fjernes, en finger fra kanten bliver
        let w = 20, h = 20
        var m = [Float](repeating: 0, count: w * h)
        var inside = [UInt8](repeating: 2, count: w * h)
        for i in 0..<w { inside[i] = 1 }
        for y in 8...10 { for x in 8...10 { m[y * w + x] = 1 } }       // plet
        for y in 1...6 { for x in 2...4 { m[y * w + x] = 1 } }         // finger fra toppen
        CardTracker.keepEdgeConnected(&m, inside: inside, width: w, height: h)
        XCTAssertEqual(m[9 * w + 9], 0)
        XCTAssertEqual(m[3 * w + 3], 1)
    }

    func testFollowsMovingCardWithoutNewQuads() throws {
        let t = try Fixtures.templates()
        let tracker = CardTracker(template: t.blue)
        var first = true
        for f in 0..<12 {
            let c = Point2(150 + Double(f) * 6, 230 + Double(f) * 3)
            let (s, out) = scene(t.blue, center: c, angle: 0.15 + Double(f) * 0.02)
            let r = tracker.update(out.image, candidates: first ? [s.card!.quad] : [])
            first = false
            let tr = try XCTUnwrap(r.track, "tabt i billede \(f)")
            XCTAssertTrue(r.fresh)
            XCTAssertLessThan(maxCornerError(tr.quad, s.card!.quad), 0.8, "billede \(f)")
        }
    }

    func testFingerIsSeenAsOccludedAndCardIsNot() throws {
        let t = try Fixtures.templates()
        let finger = Finger(center: Point2(120, 250), rx: 22, ry: 60, angle: 0.3, color: Synth.skinTones[1])
        let (s, out) = scene(t.blue, fingers: [finger])
        let tracker = CardTracker(template: t.blue)
        let r = tracker.update(out.image, candidates: [s.card!.quad])
        XCTAssertNotNil(r.track)
        var fh = 0, ft = 0, cf = 0, ct = 0
        for y in 0..<480 { for x in 0..<360 {
            let j = y * 360 + x
            let v = r.visibility[(y / 2) * r.visWidth + x / 2]
            if out.fingerMask[j] { ft += 1; if v < 128 { fh += 1 } }
            if out.overlayMask[j] { ct += 1; if v < 128 { cf += 1 } }
        } }
        print("Finger \(fh)/\(ft), kort fejlagtigt dækket \(cf)/\(ct)")
        XCTAssertGreaterThan(Double(fh) / Double(ft), 0.9)
        XCTAssertLessThan(Double(cf) / Double(ct), 0.02)
    }

    func testRejectsEmptyQuadAndOtherColor() throws {
        let t = try Fixtures.templates()
        let tracker = CardTracker(template: t.blue)
        // rødt kort, når kameraet skal se det blå
        let (s, out) = scene(t.red)
        XCTAssertNil(tracker.update(out.image, candidates: [s.card!.quad]).track, "rødt kort godtaget som blåt")
        tracker.reset()
        // tom firkant på træ
        var e = SynthScene(width: 360, height: 480)
        e.backdrop = .wood; e.backdropColor = RGB8(150, 100, 60)
        let img = Synth.render(e).image
        XCTAssertNil(tracker.update(img, candidates: [Quad.rect(center: Point2(180, 240), width: 200, height: 280, angle: 0.1)]).track)
    }

    func testHoldsBrieflyThenDrops() throws {
        let t = try Fixtures.templates()
        let tracker = CardTracker(template: t.blue)
        let (s, out) = scene(t.blue)
        XCTAssertNotNil(tracker.update(out.image, candidates: [s.card!.quad]).track)
        var e = SynthScene(width: 360, height: 480)
        e.backdrop = .gray; e.backdropColor = RGB8(120, 120, 120)
        let empty = Synth.render(e).image
        for i in 0..<4 {
            let r = tracker.update(empty)
            XCTAssertNotNil(r.track, "holdt i \(i)")
            XCTAssertFalse(r.fresh)
        }
        XCTAssertNil(tracker.update(empty).track)
    }
}

final class TrackerSpeedTests: XCTestCase {
    /// Appens opløsning (540×720): tid pr. billede for sporing + fingermaske.
    func testSpeedAtAppResolution() throws {
        let t = try Fixtures.templates()
        let tracker = CardTracker(template: t.blue)
        var times: [Double] = []
        for f in 0..<15 {
            var s = SynthScene(width: 540, height: 720)
            s.backdrop = .gray; s.backdropColor = RGB8(90, 90, 90)
            let card = SynthCard.placed(t.blue, center: Point2(270 + Double(f) * 4, 360), width: 320, angle: 0.1)
            s.card = card
            let img = Synth.render(s).image
            let r = tracker.update(img, candidates: f == 0 ? [card.quad] : [])
            XCTAssertNotNil(r.track)
            if f > 0 { times.append(tracker.lastAlignMs) }
        }
        let mean = times.reduce(0, +) / Double(times.count)
        print(String(format: "Sporing 540×720: %.1f ms pr. billede (maks %.1f)", mean, times.max()!))
    }
}
