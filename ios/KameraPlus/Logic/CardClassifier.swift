import Foundation

/// Afgør pr. pixel, om farven ligner kildekortet (0…1).
/// Mahalanobis-afstand til kortets Gauss-model i Lab (lysstyrken vægtes ned, fordi lyset varierer),
/// krav om kromatisk mætning (hvid kant, sort, grå udelukkes), farvetone-vindue (hud ved et rødt kort
/// udelukkes) og evt. den lærte baggrund (farver der er almindelige uden kort, fx hud og trøje).
struct CardClassifier {
    let source: Palette
    let background: BackgroundModel
    let sensitivity: Double
    let inverse: Mat3x3
    let tau: Double
    let minChroma: Double
    let hueIn: Double
    let hueOut: Double
    let guardSkin: Bool
    let skinLow: Double

    /// sensitivity 0…1 (menuens følsomhed). Højere = flere pixels regnes for kort.
    init(source: Palette, background: BackgroundModel = .empty, sensitivity: Double = 0.5) {
        self.source = source
        self.background = background
        self.sensitivity = min(1, max(0, sensitivity))
        let c = source.cov.m
        // Lysstyrke-variansen ×2,5 (lyset varierer) + regularisering, så en "for pæn" kalibrering ikke bliver for snæver.
        let k = 1.58   // √2,5
        let inflated = Mat3x3([c[0] * 2.5, c[1] * k, c[2] * k,
                               c[3] * k, c[4], c[5],
                               c[6] * k, c[7], c[8]])
        inverse = (inflated + .diag(25, 9, 9)).inverse ?? .diag(0.01, 0.01, 0.01)
        tau = 2.0 + 3.0 * self.sensitivity
        // Mætningskrav: mindst halvdelen af kortets middelmætning. Lyse, svagt farvede flader (hvid væg i køligt lys)
        // ligger ellers langs blandingslinjen papir–blæk og ligner et "tyndt" kort.
        minChroma = max(6, 0.5 * source.chroma) * (1.15 - 0.3 * self.sensitivity)
        let deg = Double.pi / 180
        hueIn = min(24 * deg, max(10 * deg, 2.5 * source.hueSpread + 2 * deg))
        hueOut = hueIn + 8 * deg
        guardSkin = ColorMath.skinGuardApplies(sourceHue: source.hue)
        skinLow = ColorMath.skinHueLow(sourceHue: source.hue)
    }

    func mahalanobis(_ p: Lab) -> Double {
        inverse.quadratic(p.L - source.mean.L, p.a - source.mean.a, p.b - source.mean.b).squareRoot()
    }

    func score(_ p: Lab) -> Double {
        let d = mahalanobis(p)
        let sM = 1 - ColorMath.smoothstep(tau - 0.75, tau + 0.75, d)
        guard sM > 0 else { return 0 }
        let sC = ColorMath.smoothstep(minChroma * 0.75, minChroma * 1.25, p.chroma)
        guard sC > 0 else { return 0 }
        var sH = 1 - ColorMath.smoothstep(hueIn, hueOut, ColorMath.angleDiff(p.hue, source.hue))
        if guardSkin && sH > 0 { sH *= ColorMath.skinGuard(hue: p.hue, low: skinLow) }
        var s = sM * sC * sH
        if s > 0, !background.isEmpty, d > 1.5 {
            let f = background.fraction(a: p.a, b: p.b)
            if f > 0.002 { s *= max(0, 1 - (f - 0.002) / 0.008) }
        }
        return s
    }

    func score(_ c: RGB8) -> Double { score(ColorMath.lab(c)) }

    /// Opslagstabel med `bits` bit pr. kanal (6 → 64³ = 262.144 felter à 1 byte).
    func buildLUT(bits: Int = 6) -> [UInt8] {
        let n = 1 << bits
        let step = 256 / n
        var out = [UInt8](repeating: 0, count: n * n * n)
        out.withUnsafeMutableBufferPointer { o in
            for r in 0..<n {
                for g in 0..<n {
                    for b in 0..<n {
                        let p = ColorMath.lab(UInt8(r * step + step / 2), UInt8(g * step + step / 2), UInt8(b * step + step / 2))
                        o[(r << (2 * bits)) | (g << bits) | b] = UInt8((score(p) * 255).rounded())
                    }
                }
            }
        }
        return out
    }

    @inline(__always) static func lutIndex(_ r: UInt8, _ g: UInt8, _ b: UInt8, bits: Int) -> Int {
        let s = 8 - bits
        return (Int(r >> UInt8(s)) << (2 * bits)) | (Int(g >> UInt8(s)) << bits) | Int(b >> UInt8(s))
    }

    /// Scorer et helt billede via opslagstabellen (0…255 pr. pixel), efter hvidbalance (`gain`).
    static func scores(_ img: RGBAImage, lut: [UInt8], bits: Int, gain: GainTable? = nil, into out: inout [UInt8]) {
        let n = img.width * img.height
        if out.count != n { out = [UInt8](repeating: 0, count: n) }
        let s = UInt8(8 - bits)
        let identity = (0..<256).map { UInt8($0) }
        let tr = gain?.r ?? identity, tg = gain?.g ?? identity, tb = gain?.b ?? identity
        img.pixels.withUnsafeBufferPointer { px in
            lut.withUnsafeBufferPointer { l in
                tr.withUnsafeBufferPointer { gr in
                    tg.withUnsafeBufferPointer { gg in
                        tb.withUnsafeBufferPointer { gb in
                            out.withUnsafeMutableBufferPointer { o in
                                for i in 0..<n {
                                    let k = i * 4
                                    let r = gr[Int(px[k])], g = gg[Int(px[k + 1])], b = gb[Int(px[k + 2])]
                                    o[i] = l[(Int(r >> s) << (2 * bits)) | (Int(g >> s) << bits) | Int(b >> s)]
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
