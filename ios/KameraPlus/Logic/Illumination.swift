import Foundation

/// Forstærkning pr. kanal i lineært lys (von Kries).
struct ChannelGain: Equatable, Codable {
    var r: Double
    var g: Double
    var b: Double

    static let identity = ChannelGain(r: 1, g: 1, b: 1)

    func mixed(toward o: ChannelGain, _ k: Double) -> ChannelGain {
        ChannelGain(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k)
    }

    var inverse: ChannelGain { ChannelGain(r: 1 / r, g: 1 / g, b: 1 / b) }
}

/// 8-bit → 8-bit opslag med forstærkningen anvendt i lineært lys.
struct GainTable {
    let r: [UInt8]
    let g: [UInt8]
    let b: [UInt8]

    init(_ gain: ChannelGain) {
        func table(_ k: Double) -> [UInt8] {
            (0..<256).map { v in
                let l = min(1, ColorMath.linearTable[v] * k)
                return UInt8((ColorMath.linearToSrgb(l) * 255).rounded())
            }
        }
        r = table(gain.r); g = table(gain.g); b = table(gain.b)
    }

    func apply(_ c: RGB8) -> RGB8 { RGB8(r[Int(c.r)], g[Int(c.g)], b[Int(c.b)]) }

    func apply(_ img: RGBAImage) -> RGBAImage {
        var out = img
        var i = 0
        while i < out.pixels.count {
            out.pixels[i] = r[Int(img.pixels[i])]
            out.pixels[i + 1] = g[Int(img.pixels[i + 1])]
            out.pixels[i + 2] = b[Int(img.pixels[i + 2])]
            i += 4
        }
        return out
    }
}

/// Skærmen lyser selv kortet op nedefra: i kortets ægte farve, når søgeren viser det ægte kort, og i
/// forklædningens farve, når forklædningen er tændt. Kortets farve flytter sig derfor langs én kendt retning.
/// Lyset beskrives med ét tal k: k > 0 = lys i målets farve (forklædning), k < 0 = lys i kildens farve,
/// 0 = som ved kalibreringen. Appen finder k pr. billede ud fra kortets egne pixels (se CardAnalyzer),
/// normaliserer farven før farvemodellen og lægger lyset på igen efter farveskiftet.
struct IlluminationModel: Equatable {
    /// Lysfarver (lineær RGB, luminans 1).
    let toward: (Double, Double, Double)
    let away: (Double, Double, Double)
    let kMax: Double

    static func == (a: IlluminationModel, b: IlluminationModel) -> Bool {
        a.toward == b.toward && a.away == b.away && a.kMax == b.kMax
    }

    init(source: Palette, target: Palette, kMax: Double = 0.8) {
        toward = IlluminationModel.lightColor(target)
        away = IlluminationModel.lightColor(source)
        self.kMax = kMax
    }

    /// Lineær farve af et korts middelfarve, normaliseret til luminans 1 (ingen kanal helt nul).
    static func lightColor(_ p: Palette) -> (Double, Double, Double) {
        let l = ColorMath.linear(p.mean)
        let r = max(0.02, l.r), g = max(0.02, l.g), b = max(0.02, l.b)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (r / y, g / y, b / y)
    }

    /// Lysets farve ved k (multiplikator pr. kanal, luminans 1).
    func light(_ k: Double) -> ChannelGain {
        let kk = min(kMax, max(-kMax, k))
        let c = kk >= 0 ? toward : away
        let a = abs(kk)
        let r = 1 - a + a * c.0, g = 1 - a + a * c.1, b = 1 - a + a * c.2
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ChannelGain(r: r / y, g: g / y, b: b / y)
    }

    /// Forstærkning der fjerner lyset ved k.
    func gain(_ k: Double) -> ChannelGain { light(k).inverse }

    /// Gitter af k-værdier til søgning.
    func grid(step: Double) -> [Double] {
        stride(from: -kMax, through: kMax + 1e-9, by: step).map { $0 }
    }
}
