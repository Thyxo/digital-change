import XCTest
#if canImport(KameraLogic)
@testable import KameraLogic
#endif

final class ColorTests: XCTestCase {
    func testLabRoundTrip() {
        var rng = SplitMix64(seed: 7)
        var worst = 0
        for _ in 0..<20000 {
            let c = RGB8(UInt8(rng.int(256)), UInt8(rng.int(256)), UInt8(rng.int(256)))
            let back = ColorMath.rgb8(ColorMath.lab(c))
            worst = max(worst, abs(Int(back.r) - Int(c.r)), abs(Int(back.g) - Int(c.g)), abs(Int(back.b) - Int(c.b)))
        }
        XCTAssertLessThanOrEqual(worst, 1, "Lab-rundtur afviger mere end 1 trin")
    }

    func testKnownLabValues() {
        let white = ColorMath.lab(RGB8(255, 255, 255))
        XCTAssertEqual(white.L, 100, accuracy: 0.05)
        XCTAssertEqual(white.a, 0, accuracy: 0.05)
        XCTAssertEqual(white.b, 0, accuracy: 0.05)
        let black = ColorMath.lab(RGB8(0, 0, 0))
        XCTAssertEqual(black.L, 0, accuracy: 0.01)
        // sRGB rød (255,0,0) ≈ Lab(53,24, 80,09, 67,20)
        let red = ColorMath.lab(RGB8(255, 0, 0))
        XCTAssertEqual(red.L, 53.24, accuracy: 0.1)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.2)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.2)
    }

    func testDefaultPalettesHaveExpectedHues() {
        XCTAssertTrue(Palette.defaultRed.isRedLike, "rød: \(Palette.defaultRed.hueDegrees)°")
        XCTAssertTrue(Palette.defaultBlue.isBlueLike, "blå: \(Palette.defaultBlue.hueDegrees)°")
        print("Standard rød Lab:", Palette.defaultRed.mean, "blå Lab:", Palette.defaultBlue.mean)
    }
}

/// Hjælpere til farvetests.
enum TestCards {
    /// Kort i fuld opløsning (fint mønster) + samme scene med anden blæk.
    static func pair(_ src: RGB8, _ dst: RGB8, size: (Int, Int) = (240, 320), spacing: Double = 6) -> (SynthOutput, SynthOutput) {
        var s = Synth.calibrationScene(width: size.0, height: size.1, ink: src, fineLines: false)
        s.card?.lineSpacing = spacing
        s.noise = 0
        let a = Synth.render(s)
        s.card?.ink = dst
        return (a, Synth.render(s))
    }

    static func learned(_ ink: RGB8) -> Palette {
        let img = Downsample.box(Synth.render(Synth.calibrationScene(width: 480, height: 640, ink: ink, fineLines: false)).image, factor: 4)
        return PaletteLearner.learn([img]).palette!
    }
}

final class TransferTests: XCTestCase {
    let blue = RGB8(hex: Palette.defaultBlueHex)
    let red = RGB8(hex: Palette.defaultRedHex)

    func testDefaultTransferMapsBlueInkToRedInk() {
        let t = ColorTransfer(source: .defaultBlue, target: .defaultRed)
        let out = ColorMath.lab(t.apply(blue))
        XCTAssertLessThan(ColorMath.deltaE(out, Palette.defaultRed.mean), 1.5)
    }

    func testMeanColorMatchesTargetAndPatternPreserved() {
        for (src, dst) in [(blue, red), (red, blue)] {
            let t = ColorTransfer(source: TestCards.learned(src), target: TestCards.learned(dst))
            let (a, b) = TestCards.pair(src, dst)
            let moved = t.apply(to: a.image)
            var sa = LabStats(), sb = LabStats()
            var xs: [Double] = [], ys: [Double] = []
            for i in 0..<(a.image.width * a.image.height) where a.inkMask[i] {
                let k = i * 4
                let o = ColorMath.lab(a.image.pixels[k], a.image.pixels[k + 1], a.image.pixels[k + 2])
                let p = ColorMath.lab(moved.pixels[k], moved.pixels[k + 1], moved.pixels[k + 2])
                let q = ColorMath.lab(b.image.pixels[k], b.image.pixels[k + 1], b.image.pixels[k + 2])
                sa.add(p); sb.add(q)
                xs.append(o.L); ys.append(p.L)
            }
            let dE = ColorMath.deltaE(sa.mean, sb.mean)
            XCTAssertLessThan(dE, 5, "middelfarve \(src.hex)→\(dst.hex): ΔE \(dE)")
            let r = correlation(xs, ys)
            XCTAssertGreaterThan(r, 0.98, "lysstyrkemønster \(src.hex)→\(dst.hex): r = \(r)")
            print(String(format: "Overførsel %@→%@: ΔE %.2f, korrelation %.4f", src.hex, dst.hex, dE, r))
        }
    }

    func testWhiteBorderGreysAndBlackUntouched() {
        for t in [ColorTransfer(source: .defaultBlue, target: .defaultRed), ColorTransfer(source: .defaultRed, target: .defaultBlue)] {
            for v in stride(from: 0, through: 255, by: 15) {
                let c = RGB8(UInt8(v), UInt8(v), UInt8(v))
                XCTAssertEqual(t.apply(c), c, "grå \(v) ændret")
            }
            let paper = RGB8(244, 243, 238)
            let p = ColorMath.lab(paper), q = ColorMath.lab(t.apply(paper))
            XCTAssertLessThan(ColorMath.deltaE(p, q), 1.0, "papirhvidt ændret")
        }
    }

    func testSkinNeverRecoloredInEitherDirection() {
        let transfers = [
            ColorTransfer(source: .defaultBlue, target: .defaultRed),
            ColorTransfer(source: .defaultRed, target: .defaultBlue),
            ColorTransfer(source: TestCards.learned(blue), target: TestCards.learned(red)),
            ColorTransfer(source: TestCards.learned(red), target: TestCards.learned(blue)),
        ]
        for (n, t) in transfers.enumerated() {
            for skin in Synth.skinTones {
                for k in [0.6, 0.8, 1.0] {
                    let c = RGB8(UInt8(Double(skin.r) * k), UInt8(Double(skin.g) * k), UInt8(Double(skin.b) * k))
                    let d = ColorMath.deltaE(ColorMath.lab(c), ColorMath.lab(t.apply(c)))
                    XCTAssertLessThan(d, 1.0, "hud \(c.hex) ændret ΔE \(d) (overførsel \(n))")
                }
            }
        }
    }

    func testLUTMatchesDirectTransfer() {
        let t = ColorTransfer(source: TestCards.learned(blue), target: TestCards.learned(red))
        let n = 65
        let lut = t.buildLUT(size: n)
        var rng = SplitMix64(seed: 3)
        var sum = 0.0, worst = 0.0, count = 0
        var all: [Double] = []
        for _ in 0..<20000 {
            let c = RGB8(UInt8(rng.int(256)), UInt8(rng.int(256)), UInt8(rng.int(256)))
            let direct = ColorMath.lab(t.apply(c))
            let s = ColorTransfer.sampleLUT(lut, size: n, Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255)
            let viaLUT = ColorMath.lab(r: s.0, g: s.1, b: s.2)
            let d = ColorMath.deltaE(direct, viaLUT)
            sum += d; worst = max(worst, d); count += 1
            all.append(d)
        }
        all.sort()
        let p99 = all[Int(Double(all.count) * 0.99)]
        print(String(format: "LUT %d³: gns. ΔE %.3f, 99 %% %.2f, maks %.2f", n, sum / Double(count), p99, worst))
        XCTAssertLessThan(sum / Double(count), 0.6)
        XCTAssertLessThan(p99, 4.0)
        XCTAssertLessThan(worst, 12)
    }

    func testLearnedPalettesFromCalibration() {
        let b = TestCards.learned(blue), r = TestCards.learned(red)
        XCTAssertTrue(b.isBlueLike, "blå lært som \(b.hueDegrees)°")
        XCTAssertTrue(r.isRedLike, "rød lært som \(r.hueDegrees)°")
        XCTAssertGreaterThan(b.count, 1000)
        // Intet kort (grå loft) → ingen palet
        var s = SynthScene(width: 120, height: 160)
        s.backdropColor = RGB8(200, 200, 198)
        XCTAssertNil(PaletteLearner.learn([Synth.render(s).image]).palette)
    }

    private func correlation(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx); syy += (y[i] - my) * (y[i] - my)
        }
        return sxy / max(1e-12, (sxx * syy).squareRoot())
    }
}
