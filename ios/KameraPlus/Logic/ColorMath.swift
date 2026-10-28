import Foundation

/// Farve i CIE L*a*b* (D65). L 0–100, a/b ca. −128…127.
struct Lab: Equatable, Codable {
    var L: Double
    var a: Double
    var b: Double

    /// Kromatisk mætning (afstand fra den grå akse).
    var chroma: Double { (a * a + b * b).squareRoot() }
    /// Farvetone i radianer (−π…π).
    var hue: Double { atan2(b, a) }
}

/// 8-bit sRGB-farve.
struct RGB8: Equatable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// "#B3202A" eller "B3202A".
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// sRGB ↔ lineær ↔ XYZ ↔ Lab. Ren matematik uden UIKit, så den kan testes på Mac og Linux.
enum ColorMath {
    // D65-hvidpunkt
    static let xn = 0.95047, yn = 1.0, zn = 1.08883

    /// Opslagstabel: 8-bit sRGB → lineær (0…1).
    static let linearTable: [Double] = (0..<256).map { srgbToLinear(Double($0) / 255) }

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static let eps = 216.0 / 24389.0      // (6/29)^3
    private static let kappa = 24389.0 / 27.0

    @inline(__always) private static func f(_ t: Double) -> Double {
        t > eps ? cbrt(t) : (kappa * t + 16) / 116
    }

    @inline(__always) private static func finv(_ t: Double) -> Double {
        let t3 = t * t * t
        return t3 > eps ? t3 : (116 * t - 16) / kappa
    }

    /// Lineær RGB (0…1) → Lab.
    static func labFromLinear(_ r: Double, _ g: Double, _ b: Double) -> Lab {
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// sRGB (0…1) → Lab.
    static func lab(r: Double, g: Double, b: Double) -> Lab {
        labFromLinear(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
    }

    /// 8-bit sRGB → Lab (via opslagstabel).
    static func lab(_ c: RGB8) -> Lab {
        labFromLinear(linearTable[Int(c.r)], linearTable[Int(c.g)], linearTable[Int(c.b)])
    }

    static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Lab {
        labFromLinear(linearTable[Int(r)], linearTable[Int(g)], linearTable[Int(b)])
    }

    /// Lab → lineær RGB (kan ligge uden for 0…1).
    static func linear(_ p: Lab) -> (r: Double, g: Double, b: Double) {
        let fy = (p.L + 16) / 116
        let fx = fy + p.a / 500
        let fz = fy - p.b / 200
        let x = xn * finv(fx), y = yn * finv(fy), z = zn * finv(fz)
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (r, g, b)
    }

    /// Lab → sRGB (0…1), uden klipning.
    static func srgb(_ p: Lab) -> (r: Double, g: Double, b: Double) {
        let l = linear(p)
        return (linearToSrgbSigned(l.r), linearToSrgbSigned(l.g), linearToSrgbSigned(l.b))
    }

    private static func linearToSrgbSigned(_ c: Double) -> Double {
        c < 0 ? -linearToSrgb(-c) : linearToSrgb(c)
    }

    /// Ligger farven inden for sRGB (med lille tolerance)?
    static func inGamut(_ p: Lab, tolerance: Double = 0.001) -> Bool {
        let l = linear(p)
        return l.r >= -tolerance && l.g >= -tolerance && l.b >= -tolerance
            && l.r <= 1 + tolerance && l.g <= 1 + tolerance && l.b <= 1 + tolerance
    }

    /// Lab → sRGB (0…1). Uden for sRGB mindskes mætningen (samme L og farvetone), før der klippes.
    static func srgbGamutMapped(_ p: Lab) -> (r: Double, g: Double, b: Double) {
        var q = p
        q.L = min(100, max(0, q.L))
        if !inGamut(q) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                if inGamut(Lab(L: q.L, a: q.a * mid, b: q.b * mid)) { lo = mid } else { hi = mid }
            }
            q.a *= lo
            q.b *= lo
        }
        let c = srgb(q)
        return (min(1, max(0, c.r)), min(1, max(0, c.g)), min(1, max(0, c.b)))
    }

    static func rgb8(_ p: Lab) -> RGB8 {
        let c = srgbGamutMapped(p)
        return RGB8(UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()))
    }

    /// CIE76-farveafstand.
    static func deltaE(_ p: Lab, _ q: Lab) -> Double {
        let dl = p.L - q.L, da = p.a - q.a, db = p.b - q.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// Mindste vinkelforskel (radianer, 0…π).
    static func angleDiff(_ x: Double, _ y: Double) -> Double {
        var d = (x - y).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return abs(d)
    }

    /// Hudtoner ligger i farvetone ca. 40–80° (Lab) for alle hudfarver. Ved et rødt kildekort (ca. 20–35°)
    /// ligger lys/rosa hud tæt på, så dette bånd beskyttes altid. Den nedre grænse følger kortets farvetone:
    /// 11° over kortet, dog mellem 34° og 50° (varmt lys flytter både kort og hud mod gult).
    static let skinHueHigh = 80.0 * .pi / 180
    static let skinHueEdge = 5.0 * .pi / 180

    static func skinHueLow(sourceHue h: Double) -> Double {
        min(50 * .pi / 180, max(34 * .pi / 180, h + 11 * .pi / 180))
    }

    /// 0 inde i hudbåndet, 1 mindst 5° udenfor.
    static func skinGuard(hue h: Double, low: Double = 40 * .pi / 180) -> Double {
        let d = max(low - h, h - skinHueHigh)
        return smoothstep(0, skinHueEdge, d)
    }

    /// Beskyttelsen gælder kun, når kildekortet selv ligger uden for hudbåndet (rødt eller blåt kort).
    static func skinGuardApplies(sourceHue h: Double) -> Bool {
        let deg = h * 180 / .pi
        return deg < 38 || deg > 85
    }

    @inline(__always) static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        if e1 <= e0 { return x < e0 ? 0 : 1 }
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}
