import XCTest
#if canImport(KameraLogic)
@testable import KameraLogic
#endif

final class ClassifierTests: XCTestCase {
    let blue = RGB8(hex: Palette.defaultBlueHex)
    let red = RGB8(hex: Palette.defaultRedHex)
    let others: [RGB8] = [RGB8(150, 100, 60), RGB8(120, 80, 45), RGB8(235, 233, 228), RGB8(128, 128, 128),
                          RGB8(30, 30, 32), RGB8(70, 120, 80), RGB8(244, 243, 238), RGB8(250, 250, 250)]

    func testBlueCardScoresHighOthersLow() {
        for src in [Palette.defaultBlue, TestCards.learned(blue)] {
            let c = CardClassifier(source: src)
            XCTAssertGreaterThan(c.score(ColorMath.lab(ColorMath.rgb8(src.mean))), 0.95)
            for o in others + Synth.skinTones + [red] {
                XCTAssertLessThan(c.score(o), 0.05, "\(o.hex) regnet for blåt kort")
            }
        }
    }

    func testRedCardScoresHighButSkinDoesNot() {
        for src in [Palette.defaultRed, TestCards.learned(red)] {
            let c = CardClassifier(source: src)
            XCTAssertGreaterThan(c.score(ColorMath.lab(ColorMath.rgb8(src.mean))), 0.95)
            for o in others + [blue] {
                XCTAssertLessThan(c.score(o), 0.05, "\(o.hex) regnet for rødt kort")
            }
            for skin in Synth.skinTones {
                for k in [0.55, 0.75, 1.0] {
                    let s = RGB8(UInt8(Double(skin.r) * k), UInt8(Double(skin.g) * k), UInt8(Double(skin.b) * k))
                    XCTAssertLessThan(c.score(s), 0.1, "hud \(s.hex) regnet for rødt kort (\(c.score(s)))")
                }
            }
        }
    }

    func testSensitivityWidensAcceptance() {
        let src = TestCards.learned(blue)
        let lo = CardClassifier(source: src, sensitivity: 0), hi = CardClassifier(source: src, sensitivity: 1)
        let off = Lab(L: src.mean.L + 25, a: src.mean.a * 0.75, b: src.mean.b * 0.75)
        XCTAssertGreaterThanOrEqual(hi.score(off), lo.score(off))
        XCTAssertGreaterThan(hi.tau, lo.tau)
    }

    func testLUTEqualsDirectScore() {
        let c = CardClassifier(source: TestCards.learned(blue))
        let lut = c.buildLUT(bits: 6)
        var rng = SplitMix64(seed: 11)
        var bad = 0
        for _ in 0..<5000 {
            let r = UInt8(rng.int(256)), g = UInt8(rng.int(256)), b = UInt8(rng.int(256))
            let v = Double(lut[CardClassifier.lutIndex(r, g, b, bits: 6)]) / 255
            let center = RGB8(r & 0xFC | 2, g & 0xFC | 2, b & 0xFC | 2)
            if abs(v - c.score(center)) > 0.01 { bad += 1 }
        }
        XCTAssertEqual(bad, 0)
    }

    func testLearnedBackgroundSuppressesBlueShirt() {
        let src = TestCards.learned(blue)
        // en blålig trøje, der ligner kortet lidt
        let shirt = RGB8(70, 95, 150)
        let plain = CardClassifier(source: src, sensitivity: 1)
        var s = SynthScene(width: 80, height: 100)
        s.backdrop = .gray
        s.backdropColor = shirt
        let bg = BackgroundModel.learn([Synth.render(s).image])
        let withBg = CardClassifier(source: src, background: bg, sensitivity: 1)
        XCTAssertGreaterThan(plain.score(shirt), 0.3, "testen giver kun mening, hvis trøjen ligner kortet")
        XCTAssertLessThan(withBg.score(shirt), 0.05)
        // Selve kortets middelfarve er stadig kort
        XCTAssertGreaterThan(withBg.score(ColorMath.lab(ColorMath.rgb8(src.mean))), 0.9)
    }
}
