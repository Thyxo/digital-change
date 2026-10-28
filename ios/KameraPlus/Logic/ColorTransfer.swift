import Foundation

/// Farveoverførsel fra kildekortet (det kameraet ser) til målkortet (det publikum skal se).
///
/// Udgangspunktet er Reinhard-overførsel i Lab:
///   L' = μL_mål + (L − μL_kilde) · k,   k = σL_mål / σL_kilde begrænset til 0,7–1,4
///   (a,b)' = A·((a,b) − μ_kilde) + μ_mål
/// men forankret i papirhvidt i stedet for kortets middelfarve: et trykt kort er blæk på hvidt papir,
/// så hver pixel er en blanding af papir og blæk. Blæk-andelen w (projektion af pixlens (a,b) på
/// kildens farveretning) styrer, hvor meget L flyttes, og (a,b) roteres/skaleres omkring den grå akse,
/// så kildens middelfarve rammer målets præcist. Hvid kant, mønstrets hvide streger, skygger og hud
/// (w ≈ 0 eller forkert farvetone) bliver derfor urørte, og mønstrets lysforløb bevares.
/// Hudtoner (farvetone 40–80°) ændres aldrig, heller ikke ved et rødt kildekort.
struct ColorTransfer {
    let source: Palette
    let target: Palette
    // (a,b)-afbildning: rotation med farvetone-forskellen og skalering med mætningsforholdet
    let m00: Double, m01: Double, m10: Double, m11: Double
    let lShift: Double
    let lScale: Double
    /// Farvetone-vindue omkring kilden (radianer): fuld effekt inden for hueIn, ingen uden for hueOut.
    let hueIn: Double
    let hueOut: Double
    let maxInk = 1.5
    let guardSkin: Bool
    let skinLow: Double

    init(source: Palette, target: Palette) {
        self.source = source
        self.target = target
        let s = target.chroma / max(source.chroma, 1)
        let dh = target.hue - source.hue
        m00 = s * cos(dh); m01 = -s * sin(dh)
        m10 = s * sin(dh); m11 = s * cos(dh)
        lShift = target.mean.L - source.mean.L
        lScale = min(1.4, max(0.7, target.sigmaL / source.sigmaL))
        let deg = Double.pi / 180
        hueIn = min(20 * deg, max(8 * deg, 2 * source.hueSpread))
        hueOut = hueIn + 8 * deg
        guardSkin = ColorMath.skinGuardApplies(sourceHue: source.hue)
        skinLow = ColorMath.skinHueLow(sourceHue: source.hue)
    }

    /// Hvor meget blæk (0…1,5) pixlen indeholder, målt langs kildens farveretning.
    func inkFraction(_ p: Lab) -> Double {
        let sa = source.mean.a, sb = source.mean.b
        let cs2 = sa * sa + sb * sb
        guard cs2 > 1 else { return 0 }
        return min(maxInk, max(0, (p.a * sa + p.b * sb) / cs2))
    }

    /// 1 når farvetonen ligger tæt på kilden, 0 langt fra (fx hud ved et rødt kildekort).
    func hueGate(_ p: Lab) -> Double {
        guard p.chroma > 1e-6 else { return 0 }
        let g = 1 - ColorMath.smoothstep(hueIn, hueOut, ColorMath.angleDiff(p.hue, source.hue))
        return guardSkin && g > 0 ? g * ColorMath.skinGuard(hue: p.hue, low: skinLow) : g
    }

    func apply(_ p: Lab) -> Lab {
        let g = hueGate(p)
        guard g > 0 else { return p }
        let w = inkFraction(p)
        let a2 = m00 * p.a + m01 * p.b
        let b2 = m10 * p.a + m11 * p.b
        let l2 = p.L + w * (lShift + (lScale - 1) * (p.L - source.mean.L))
        return Lab(L: p.L + g * (l2 - p.L), a: p.a + g * (a2 - p.a), b: p.b + g * (b2 - p.b))
    }

    func apply(_ c: RGB8) -> RGB8 { ColorMath.rgb8(apply(ColorMath.lab(c))) }

    /// 3D-opslagstabel (RGBA8, n³) til Metal: indeks = (b·n + g)·n + r, værdier i sRGB.
    func buildLUT(size n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: n * n * n * 4)
        let inv = 1 / Double(n - 1)
        out.withUnsafeMutableBufferPointer { o in
            for bi in 0..<n {
                for gi in 0..<n {
                    for ri in 0..<n {
                        let p = ColorMath.lab(r: Double(ri) * inv, g: Double(gi) * inv, b: Double(bi) * inv)
                        let q = apply(p)
                        let idx = ((bi * n + gi) * n + ri) * 4
                        if q == p {
                            o[idx] = UInt8((Double(ri) * inv * 255).rounded())
                            o[idx + 1] = UInt8((Double(gi) * inv * 255).rounded())
                            o[idx + 2] = UInt8((Double(bi) * inv * 255).rounded())
                        } else {
                            let c = ColorMath.srgbGamutMapped(q)
                            o[idx] = UInt8((c.r * 255).rounded())
                            o[idx + 1] = UInt8((c.g * 255).rounded())
                            o[idx + 2] = UInt8((c.b * 255).rounded())
                        }
                    }
                }
            }
        }
        return out
    }

    /// Trilineær opslag i en LUT (samme som GPU'en gør). Indgang og udgang i 0…1.
    static func sampleLUT(_ lut: [UInt8], size n: Int, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let s = Double(n - 1)
        let x = min(s, max(0, r * s)), y = min(s, max(0, g * s)), z = min(s, max(0, b * s))
        let x0 = min(n - 2, Int(x)), y0 = min(n - 2, Int(y)), z0 = min(n - 2, Int(z))
        let fx = x - Double(x0), fy = y - Double(y0), fz = z - Double(z0)
        var res = (0.0, 0.0, 0.0)
        for dz in 0...1 {
            for dy in 0...1 {
                for dx in 0...1 {
                    let w = (dx == 1 ? fx : 1 - fx) * (dy == 1 ? fy : 1 - fy) * (dz == 1 ? fz : 1 - fz)
                    let i = (((z0 + dz) * n + (y0 + dy)) * n + (x0 + dx)) * 4
                    res.0 += w * Double(lut[i]); res.1 += w * Double(lut[i + 1]); res.2 += w * Double(lut[i + 2])
                }
            }
        }
        return (res.0 / 255, res.1 / 255, res.2 / 255)
    }

    /// Anvend overførslen på et helt billede, kun hvor `weight` (0…1, samme størrelse) er sat.
    /// Med `gain` sker skiftet i hvidbalanceret lys, og lyset lægges på igen bagefter (som i shaderen).
    func apply(to img: RGBAImage, weight: [Double]? = nil, gain: ChannelGain = .identity) -> RGBAImage {
        var out = img
        let n = img.width * img.height
        let lin = ColorMath.linearTable
        for i in 0..<n {
            let w = weight?[i] ?? 1
            guard w > 0 else { continue }
            let k = i * 4
            let c = RGB8(img.pixels[k], img.pixels[k + 1], img.pixels[k + 2])
            let d: RGB8
            if gain == .identity {
                d = apply(c)
            } else {
                let p = ColorMath.labFromLinear(lin[Int(c.r)] * gain.r, lin[Int(c.g)] * gain.g, lin[Int(c.b)] * gain.b)
                let q = apply(p)
                if q == p { d = c } else {
                    let l = ColorMath.linear(q)
                    func enc(_ v: Double, _ k: Double) -> UInt8 {
                        UInt8((ColorMath.linearToSrgb(min(1, max(0, v / k))) * 255).rounded())
                    }
                    d = RGB8(enc(l.r, gain.r), enc(l.g, gain.g), enc(l.b, gain.b))
                }
            }
            out.pixels[k] = UInt8((Double(c.r) + w * (Double(d.r) - Double(c.r))).rounded())
            out.pixels[k + 1] = UInt8((Double(c.g) + w * (Double(d.g) - Double(c.g))).rounded())
            out.pixels[k + 2] = UInt8((Double(c.b) + w * (Double(d.b) - Double(c.b))).rounded())
        }
        return out
    }
}
