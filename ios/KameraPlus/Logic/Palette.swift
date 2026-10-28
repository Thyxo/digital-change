import Foundation

/// Simpel 3×3-matrix (række-orden) til kovarians og Mahalanobis-afstand.
struct Mat3x3: Equatable, Codable {
    var m: [Double]

    init(_ m: [Double]) { precondition(m.count == 9); self.m = m }
    static let identity = Mat3x3([1, 0, 0, 0, 1, 0, 0, 0, 1])
    static func diag(_ a: Double, _ b: Double, _ c: Double) -> Mat3x3 { Mat3x3([a, 0, 0, 0, b, 0, 0, 0, c]) }

    subscript(r: Int, c: Int) -> Double { m[r * 3 + c] }

    var determinant: Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }

    var inverse: Mat3x3? {
        let d = determinant
        guard abs(d) > 1e-12, d.isFinite else { return nil }
        let i = 1 / d
        return Mat3x3([
            (m[4] * m[8] - m[5] * m[7]) * i, (m[2] * m[7] - m[1] * m[8]) * i, (m[1] * m[5] - m[2] * m[4]) * i,
            (m[5] * m[6] - m[3] * m[8]) * i, (m[0] * m[8] - m[2] * m[6]) * i, (m[2] * m[3] - m[0] * m[5]) * i,
            (m[3] * m[7] - m[4] * m[6]) * i, (m[1] * m[6] - m[0] * m[7]) * i, (m[0] * m[4] - m[1] * m[3]) * i,
        ])
    }

    static func + (x: Mat3x3, y: Mat3x3) -> Mat3x3 { Mat3x3(zip(x.m, y.m).map { $0 + $1 }) }

    /// xᵀ·M·x
    func quadratic(_ x: Double, _ y: Double, _ z: Double) -> Double {
        x * (m[0] * x + m[1] * y + m[2] * z) + y * (m[3] * x + m[4] * y + m[5] * z) + z * (m[6] * x + m[7] * y + m[8] * z)
    }
}

/// Gaussisk farvemodel for ét kort (middel + kovarians i Lab).
/// Kildepalet = det fysiske kort kameraet ser, målpalet = det kort, det skal ligne.
struct Palette: Equatable, Codable {
    var mean: Lab
    var cov: Mat3x3
    var count: Int

    var sigmaL: Double { max(1, cov[0, 0]).squareRoot() }
    var chroma: Double { mean.chroma }
    var hue: Double { mean.hue }
    var hueDegrees: Double { mean.hue * 180 / .pi }

    /// Spredning vinkelret på farvetonen i ab-planen, udtrykt som vinkel (radianer).
    var hueSpread: Double {
        let c = max(mean.chroma, 1)
        let vx = -sin(hue), vy = cos(hue)
        let varPerp = vx * vx * cov[1, 1] + 2 * vx * vy * cov[1, 2] + vy * vy * cov[2, 2]
        return max(0, varPerp).squareRoot() / c
    }

    /// Model af et trykt kort ud fra én blækfarve: mønstret blander blæk og papir, så farverne
    /// spreder sig langs farvetonen (fra papirhvid mod blæk) og meget lidt på tværs.
    static func ink(_ c: RGB8, lSigma: Double = 14, alongFraction: Double = 0.35, perpendicular: Double = 5) -> Palette {
        let p = ColorMath.lab(c)
        let h = p.hue
        let ux = cos(h), uy = sin(h), vx = -sin(h), vy = cos(h)
        let su = max(4, alongFraction * p.chroma), sv = perpendicular
        let aa = su * su * ux * ux + sv * sv * vx * vx
        let ab = su * su * ux * uy + sv * sv * vx * vy
        let bb = su * su * uy * uy + sv * sv * vy * vy
        return Palette(mean: p, cov: Mat3x3([lSigma * lSigma, 0, 0, 0, aa, ab, 0, ab, bb]), count: 0)
    }

    /// Startværdier uden kalibrering (justeres mod det rigtige kort i menuen).
    static let defaultRedHex = "#B3202A"
    static let defaultBlueHex = "#1E3F8F"
    static let defaultRed = Palette.ink(RGB8(hex: defaultRedHex))
    static let defaultBlue = Palette.ink(RGB8(hex: defaultBlueHex))

    var isRedLike: Bool { chroma > 12 && (-35...85).contains(hueDegrees) }
    var isBlueLike: Bool { chroma > 12 && (-150 ... -35).contains(hueDegrees) }
}

/// Løbende middel og kovarians.
struct LabStats {
    private(set) var n = 0
    private var s = [Double](repeating: 0, count: 3)
    private var ss = [Double](repeating: 0, count: 6) // LL, La, Lb, aa, ab, bb

    mutating func add(_ p: Lab) {
        n += 1
        s[0] += p.L; s[1] += p.a; s[2] += p.b
        ss[0] += p.L * p.L; ss[1] += p.L * p.a; ss[2] += p.L * p.b
        ss[3] += p.a * p.a; ss[4] += p.a * p.b; ss[5] += p.b * p.b
    }

    var mean: Lab {
        guard n > 0 else { return Lab(L: 0, a: 0, b: 0) }
        let k = Double(n)
        return Lab(L: s[0] / k, a: s[1] / k, b: s[2] / k)
    }

    var covariance: Mat3x3 {
        guard n > 1 else { return .diag(1, 1, 1) }
        let k = Double(n), mu = mean
        let ll = ss[0] / k - mu.L * mu.L, la = ss[1] / k - mu.L * mu.a, lb = ss[2] / k - mu.L * mu.b
        let aa = ss[3] / k - mu.a * mu.a, ab = ss[4] / k - mu.a * mu.b, bb = ss[5] / k - mu.b * mu.b
        return Mat3x3([ll, la, lb, la, aa, ab, lb, ab, bb])
    }

    var palette: Palette { Palette(mean: mean, cov: covariance, count: n) }
}

/// Resultat af "Lær rødt/blåt kort".
struct LearnOutcome: Equatable {
    var palette: Palette?
    var chromaticFraction: Double   // andel farvede pixels i midten af billedet
    var hueDegrees: Double?
}

/// Lærer et korts farve ud fra billeder med kortet foran kameraet.
/// Kun pixels i midten af billedet med tydelig farve tælles, og kun omkring den dominerende farvetone,
/// så hvid kant, fingre og baggrund ikke trækker modellen. Kalibreringen sker, mens menuen dækker skærmen,
/// så kortet kun er belyst af rummets lys (skærmens eget lys håndteres af IlluminationModel).
enum PaletteLearner {
    static func learn(_ images: [RGBAImage], centerFraction: Double = 0.7, minChroma fixedMin: Double? = nil,
                      hueWindowDegrees: Double = 30, minPixels: Int = 300) -> LearnOutcome {
        let window = hueWindowDegrees * .pi / 180
        let balanced = images
        // Mætningsgrænse efter kortets egen fordeling: 35 % af 95 %-fraktilen (mindst 4,5). Et kort i lav
        // opløsning er blæk blandet med papir, så de fleste pixels er langt mindre mættede end blækket.
        var chromaHist = [Int](repeating: 0, count: 128)
        var chromaN = 0
        forEachCenterPixel(balanced, centerFraction) { p, _, _ in
            chromaHist[min(127, Int(p.chroma))] += 1
            chromaN += 1
        }
        var acc = 0, p95 = 0
        for c in 0..<128 { acc += chromaHist[c]; if Double(acc) >= 0.95 * Double(chromaN) { p95 = c; break } }
        let minChroma = fixedMin ?? max(4.5, 0.35 * Double(p95))

        // 1) Dominerende farvetone (histogram vægtet med mætning)
        var total = 0, chromatic = 0
        forEachCenterPixel(balanced, centerFraction) { p, _, _ in
            total += 1
            if p.chroma >= minChroma { chromatic += 1 }
        }
        let fraction = total > 0 ? Double(chromatic) / Double(total) : 0
        guard chromatic >= minPixels, let h0 = dominantHue(balanced, centerFraction, minChroma, minPixels: minPixels) else {
            return LearnOutcome(palette: nil, chromaticFraction: fraction, hueDegrees: nil)
        }

        // 2) Middel og kovarians omkring den farvetone
        var stats = LabStats()
        forEachCenterPixel(balanced, centerFraction) { p, _, _ in
            guard p.chroma >= minChroma, ColorMath.angleDiff(p.hue, h0) <= window else { return }
            stats.add(p)
        }
        guard stats.n >= minPixels else { return LearnOutcome(palette: nil, chromaticFraction: fraction, hueDegrees: nil) }
        let pal = stats.palette
        return LearnOutcome(palette: pal, chromaticFraction: fraction, hueDegrees: pal.hueDegrees)
    }

    private static func dominantHue(_ images: [RGBAImage], _ frac: Double, _ minChroma: Double, minPixels: Int) -> Double? {
        let bins = 72
        var hist = [Double](repeating: 0, count: bins)
        var n = 0
        forEachCenterPixel(images, frac) { p, _, _ in
            let c = p.chroma
            guard c >= minChroma else { return }
            n += 1
            var h = p.hue
            if h < 0 { h += 2 * .pi }
            hist[min(bins - 1, Int(h / (2 * .pi) * Double(bins)))] += c
        }
        guard n >= max(1, minPixels) else { return nil }
        var best = 0, bestV = -1.0
        for i in 0..<bins {
            let v = hist[(i + bins - 1) % bins] + 2 * hist[i] + hist[(i + 1) % bins]
            if v > bestV { bestV = v; best = i }
        }
        return (Double(best) + 0.5) / Double(bins) * 2 * .pi
    }

    private static func forEachCenterPixel(_ images: [RGBAImage], _ frac: Double, _ body: (Lab, Int, Int) -> Void) {
        for img in images {
            let w = img.width, h = img.height
            let x0 = Int(Double(w) * (1 - frac) / 2), x1 = w - x0
            let y0 = Int(Double(h) * (1 - frac) / 2), y1 = h - y0
            img.pixels.withUnsafeBufferPointer { px in
                var y = y0
                while y < y1 {
                    var x = x0
                    while x < x1 {
                        let i = (y * w + x) * 4
                        body(ColorMath.lab(px[i], px[i + 1], px[i + 2]), x, y)
                        x += 1
                    }
                    y += 1
                }
            }
        }
    }
}

/// "Lær baggrund (uden kort)": hvilke farver (ab-plan) findes i billedet uden kort, fx hud og trøje.
/// Farver, der er hyppige i baggrunden og ikke ligner kortet tydeligt, regnes ikke for kort.
struct BackgroundModel: Equatable, Codable {
    static let bins = 32
    static let range = 80.0   // a og b fra −80 til 80
    var fractions: [Float]    // andel af baggrundens farvede pixels pr. felt
    var pixelCount: Int

    static let empty = BackgroundModel(fractions: [Float](repeating: 0, count: bins * bins), pixelCount: 0)
    var isEmpty: Bool { pixelCount == 0 }

    @inline(__always) static func bin(_ a: Double, _ b: Double) -> Int? {
        let ia = Int(((a + range) / (2 * range) * Double(bins)).rounded(.down))
        let ib = Int(((b + range) / (2 * range) * Double(bins)).rounded(.down))
        guard ia >= 0, ia < bins, ib >= 0, ib < bins else { return nil }
        return ib * bins + ia
    }

    func fraction(a: Double, b: Double) -> Double {
        guard !isEmpty, let i = BackgroundModel.bin(a, b) else { return 0 }
        return Double(fractions[i])
    }

    static func learn(_ images: [RGBAImage], minChroma: Double = 6) -> BackgroundModel {
        var counts = [Int](repeating: 0, count: bins * bins)
        var n = 0
        for img in images {
            img.pixels.withUnsafeBufferPointer { px in
                var i = 0
                while i < px.count {
                    let p = ColorMath.lab(px[i], px[i + 1], px[i + 2])
                    if p.chroma >= minChroma, let k = bin(p.a, p.b) {
                        counts[k] += 1
                        n += 1
                    }
                    i += 4
                }
            }
        }
        guard n > 0 else { return BackgroundModel(fractions: [Float](repeating: 0, count: bins * bins), pixelCount: 0) }
        // Spred lidt til nabofelterne, så små farveskift i lyset også dækkes.
        var smooth = [Float](repeating: 0, count: bins * bins)
        for y in 0..<bins {
            for x in 0..<bins {
                var acc = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < bins, yy >= 0, yy < bins else { continue }
                        acc += Double(counts[yy * bins + xx]) * (dx == 0 && dy == 0 ? 1 : 0.5)
                    }
                }
                smooth[y * bins + x] = Float(acc / Double(n))
            }
        }
        return BackgroundModel(fractions: smooth, pixelCount: n)
    }
}
