import Foundation

/// Deterministisk tilfældighed (SplitMix64), så tests og selvtest altid giver samme billeder.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ≤ x < 1
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

/// Baggrunde i de syntetiske billeder.
enum Backdrop: String, CaseIterable {
    case ceiling, whiteWall, wood, darkTable, gray, green, hand, gradient
}

/// Et syntetisk Rider Back-agtigt kort: hvid kant, tynd rammelinje og krydsskraveret mønster i én blækfarve.
struct SynthCard {
    var center: Point2
    var width: Double              // kortets korte side i pixels
    var angle: Double              // radianer
    var ink: RGB8
    var paper = RGB8(244, 243, 238)
    var border = 0.075             // hvid kant som andel af bredden
    var lineSpacing = 6.0          // mønstrets periode i pixels
    var inkCoverage = 0.55         // bruges når mønstret er finere end pixlerne
    var tilt = 0.0                 // vipning: toppen smallere/bredere (−0,3…0,3)
    var aspect = 0.714             // 2,5 × 3,5 tommer

    var height: Double { width / aspect }

    var quad: Quad {
        let h = height
        let local = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { p -> Point2 in
            let k = 1 + tilt * (p.1 * 2) * -1   // vipning: top (v<0) skaleres med 1+tilt
            return Point2(p.0 * width * k, p.1 * h)
        }
        let c = cos(angle), s = sin(angle)
        return Quad(corners: local.map { Point2(center.x + $0.x * c - $0.y * s, center.y + $0.x * s + $0.y * c) })
    }
}

struct Finger {
    var center: Point2
    var rx: Double
    var ry: Double
    var angle: Double
    var color: RGB8
}

struct SynthScene {
    var width: Int
    var height: Int
    var backdrop: Backdrop = .ceiling
    var backdropColor = RGB8(220, 220, 218)
    var backdropColor2 = RGB8(120, 120, 120)
    var card: SynthCard?
    var fingers: [Finger] = []
    /// Lys: lysstyrke og farvestik (lineær multiplikator pr. kanal), fx rødt lys fra skærmen.
    var brightness = 1.0
    var tint = (1.0, 1.0, 1.0)
    /// Ekstra lys kun på kortet (skærmen lyser kortet op nedefra – rødt under forklædning, blåt efter).
    var cardTint = (1.0, 1.0, 1.0)
    var noise = 2.0
    var seed: UInt64 = 1
}

struct SynthOutput {
    var image: RGBAImage
    /// Kortets mønsterflade (inden for den hvide kant), ikke dækket af fingre.
    var inkMask: [Bool]
    /// Hele kortet inkl. kant (fingre ignoreres – rumligt område).
    var cardMask: [Bool]
    /// Pixels dækket af fingre.
    var fingerMask: [Bool]
}

enum Synth {
    static let skinTones: [RGB8] = [
        RGB8(255, 219, 172), RGB8(241, 194, 125), RGB8(224, 172, 105), RGB8(198, 134, 66),
        RGB8(141, 85, 36), RGB8(232, 190, 172), RGB8(250, 205, 190), RGB8(110, 68, 40),
        RGB8(236, 188, 150), RGB8(205, 150, 125),
    ]

    static func render(_ s: SynthScene) -> SynthOutput {
        var rng = SplitMix64(seed: s.seed)
        let w = s.width, h = s.height
        var img = RGBAImage(width: w, height: h)
        var ink = [Bool](repeating: false, count: w * h)
        var card = [Bool](repeating: false, count: w * h)
        var fing = [Bool](repeating: false, count: w * h)
        let lin = ColorMath.linearTable
        func L(_ c: RGB8) -> (Double, Double, Double) { (lin[Int(c.r)], lin[Int(c.g)], lin[Int(c.b)]) }
        let bg1 = L(s.backdropColor), bg2 = L(s.backdropColor2)
        let fingers = s.fingers.map { f in (f, L(f.color), cos(-f.angle), sin(-f.angle)) }
        let cardInfo = s.card.map { c in (c, L(c.ink), L(c.paper), cos(-c.angle), sin(-c.angle)) }

        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let i = y * w + x
                var col = backdrop(s, px, py, bg1, bg2)

                if let (c, cInk, cPaper, ca, sa) = cardInfo {
                    let dx = px - c.center.x, dy = py - c.center.y
                    let u0 = dx * ca - dy * sa, v = dx * sa + dy * ca
                    let ch = c.height
                    let k = 1 + c.tilt * (v / ch * 2) * -1
                    let u = u0 / max(0.2, k)
                    let hw = c.width / 2, hh = ch / 2
                    let r = 0.06 * c.width
                    let qx = abs(u) - (hw - r), qy = abs(v) - (hh - r)
                    let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() - r
                    if outside <= 0 {
                        card[i] = true
                        let bw = c.border * c.width
                        var t = 0.0
                        if abs(u) <= hw - bw && abs(v) <= hh - bw {
                            ink[i] = true
                            let inner = min(hw - bw - abs(u), hh - bw - abs(v))
                            if inner < 0.035 * c.width {
                                t = 0.85     // rammelinjen
                            } else if c.lineSpacing < 2.5 {
                                t = c.inkCoverage
                            } else {
                                t = pattern(u, v, c.lineSpacing)
                            }
                        }
                        col = (cPaper.0 + t * (cInk.0 - cPaper.0), cPaper.1 + t * (cInk.1 - cPaper.1), cPaper.2 + t * (cInk.2 - cPaper.2))
                        col = (col.0 * s.cardTint.0, col.1 * s.cardTint.1, col.2 * s.cardTint.2)
                    }
                }

                for (f, fc, ca, sa) in fingers {
                    let dx = px - f.center.x, dy = py - f.center.y
                    let u = (dx * ca - dy * sa) / f.rx, v = (dx * sa + dy * ca) / f.ry
                    let d = u * u + v * v
                    if d <= 1 {
                        let shade = 1 - 0.35 * d
                        col = (fc.0 * shade, fc.1 * shade, fc.2 * shade)
                        fing[i] = true
                        ink[i] = false
                    }
                }

                let b = s.brightness
                let r = col.0 * b * s.tint.0, g = col.1 * b * s.tint.1, bl = col.2 * b * s.tint.2
                func enc(_ v: Double) -> UInt8 {
                    let e = ColorMath.linearToSrgb(min(1, max(0, v))) * 255 + (rng.unit() - 0.5) * 2 * s.noise
                    return UInt8(min(255, max(0, e.rounded())))
                }
                img.pixels[i * 4] = enc(r)
                img.pixels[i * 4 + 1] = enc(g)
                img.pixels[i * 4 + 2] = enc(bl)
                img.pixels[i * 4 + 3] = 255
            }
        }
        return SynthOutput(image: img, inkMask: ink, cardMask: card, fingerMask: fing)
    }

    /// Krydsskravering (±45°) med blød kant – en enkel efterligning af Rider Back-mønstret.
    static func pattern(_ u: Double, _ v: Double, _ spacing: Double) -> Double {
        func line(_ a: Double) -> Double {
            let f = a / spacing - (a / spacing).rounded(.down)
            let d = abs(f - 0.5) * spacing           // afstand til linjens midte i pixels
            let half = spacing * 0.22
            return 1 - ColorMath.smoothstep(half - 0.5, half + 0.5, d)
        }
        let a = line(u + v), b = line(u - v)
        return max(a, b) * 0.95
    }

    private static func backdrop(_ s: SynthScene, _ x: Double, _ y: Double,
                                 _ c1: (Double, Double, Double), _ c2: (Double, Double, Double)) -> (Double, Double, Double) {
        let w = Double(s.width), h = Double(s.height)
        switch s.backdrop {
        case .ceiling:
            let dx = (x - w * 0.5) / w, dy = (y - h * 0.4) / h
            let v = 1 - 0.5 * (dx * dx + dy * dy)
            return (c1.0 * v, c1.1 * v, c1.2 * v)
        case .whiteWall:
            let v = 0.92 + 0.08 * (y / h)
            return (c1.0 * v, c1.1 * v, c1.2 * v)
        case .wood:
            let v = 0.85 + 0.15 * sin(y * 0.25 + sin(x * 0.04) * 2.5)
            return (c1.0 * v, c1.1 * v, c1.2 * v)
        case .darkTable, .gray, .green:
            return c1
        case .hand:
            let dx = (x - w * 0.5) / w
            let v = 1 - 0.6 * dx * dx
            return (c1.0 * v, c1.1 * v, c1.2 * v)
        case .gradient:
            let t = y / h
            return (c1.0 + t * (c2.0 - c1.0), c1.1 + t * (c2.1 - c1.1), c1.2 + t * (c2.2 - c1.2))
        }
    }

    /// Tilfældig baggrund, der ikke ligner kildekortets farve (til test af falske positiver).
    static func randomBackdrop(_ rng: inout SplitMix64, avoidHue: Double?) -> (Backdrop, RGB8, RGB8) {
        let kind = rng.pick(Backdrop.allCases)
        func color() -> RGB8 {
            switch kind {
            case .ceiling: let v = UInt8(rng.range(170, 250)); return RGB8(v, v, UInt8(max(0, Double(v) - rng.range(0, 12))))
            case .whiteWall: let v = UInt8(rng.range(200, 245)); return RGB8(v, UInt8(Double(v) - rng.range(0, 6)), UInt8(Double(v) - rng.range(0, 14)))
            case .wood: return rng.pick([RGB8(150, 100, 60), RGB8(120, 80, 45), RGB8(185, 140, 95), RGB8(95, 60, 35)])
            case .darkTable: let v = UInt8(rng.range(15, 60)); return RGB8(v, v, v)
            case .gray: let v = UInt8(rng.range(70, 180)); return RGB8(v, v, v)
            case .green: return rng.pick([RGB8(70, 120, 80), RGB8(40, 90, 50), RGB8(110, 140, 90)])
            case .hand: return rng.pick(skinTones)
            case .gradient:
                // tilfældig farve, men ikke tæt på kildens farvetone
                for _ in 0..<50 {
                    let c = RGB8(UInt8(rng.range(20, 240)), UInt8(rng.range(20, 240)), UInt8(rng.range(20, 240)))
                    let p = ColorMath.lab(c)
                    if let h = avoidHue, p.chroma > 8, ColorMath.angleDiff(p.hue, h) < 70 * .pi / 180 { continue }
                    return c
                }
                return RGB8(128, 128, 128)
            }
        }
        return (kind, color(), color())
    }

    /// Tilfældig scene med eller uden kort, fingre, lys og støj.
    static func randomScene(_ rng: inout SplitMix64, width: Int, height: Int, ink: RGB8?, avoidHue: Double?,
                            fingers maxFingers: Int = 2, fineLines: Bool = true) -> SynthScene {
        var s = SynthScene(width: width, height: height)
        let (kind, c1, c2) = randomBackdrop(&rng, avoidHue: avoidHue)
        s.backdrop = kind
        s.backdropColor = c1
        s.backdropColor2 = c2
        s.brightness = rng.range(0.75, 1.15)
        // svagt farvestik i rummet (kortets lys sættes af kalderen med screenLight)
        s.tint = (rng.range(0.94, 1.06), rng.range(0.96, 1.03), rng.range(0.94, 1.06))
        // Støj efter 4×4-nedskalering (kameraets egen støj midles ca. 4× ned)
        s.noise = rng.range(0.5, 2.5)
        s.seed = rng.next()
        let W = Double(width), H = Double(height)
        if let ink {
            let cw = rng.range(0.4, 0.62) * W
            var card = SynthCard(center: Point2(rng.range(0.35, 0.65) * W, rng.range(0.38, 0.62) * H),
                                 width: cw, angle: rng.range(-0.5, 0.5), ink: ink)
            card.tilt = rng.range(-0.15, 0.15)
            card.lineSpacing = fineLines ? 1.5 : rng.range(4, 8)
            card.inkCoverage = rng.range(0.5, 0.62)
            s.card = card
            let nf = rng.int(maxFingers + 1)
            let q = card.quad
            for _ in 0..<nf {
                // finger der griber om en kant
                let e = rng.int(4)
                let a = q.corners[e], b = q.corners[(e + 1) % 4]
                let t = rng.range(0.25, 0.75)
                let p = Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                s.fingers.append(Finger(center: p, rx: cw * rng.range(0.09, 0.14), ry: cw * rng.range(0.2, 0.32),
                                        angle: atan2(b.y - a.y, b.x - a.x) + .pi / 2, color: rng.pick(skinTones)))
            }
        } else {
            // ingen kort: evt. en hånd eller fingre i billedet
            let nf = rng.int(maxFingers + 2)
            for _ in 0..<nf {
                s.fingers.append(Finger(center: Point2(rng.range(0.1, 0.9) * W, rng.range(0.1, 0.9) * H),
                                        rx: W * rng.range(0.06, 0.12), ry: W * rng.range(0.2, 0.4),
                                        angle: rng.range(0, .pi), color: rng.pick(skinTones)))
            }
        }
        return s
    }

    /// Lys fra skærmen på kortet: skærmen viser et kort (blæk blandet med papir), og `amount` (0…1) er
    /// skærmens andel af lyset. Lidt tilfældig afvigelse, så lyset ikke passer præcist til appens model.
    static func screenLight(ink: RGB8, amount: Double, rng: inout SplitMix64, coverage: Double = 0.55) -> (Double, Double, Double) {
        let lin = ColorMath.linearTable
        let paper = (0.9, 0.9, 0.86)
        let c = (paper.0 + coverage * (lin[Int(ink.r)] - paper.0),
                 paper.1 + coverage * (lin[Int(ink.g)] - paper.1),
                 paper.2 + coverage * (lin[Int(ink.b)] - paper.2))
        let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        var r = 1 - amount + amount * c.0 / y, g = 1 - amount + amount * c.1 / y, b = 1 - amount + amount * c.2 / y
        r *= rng.range(0.97, 1.03); g *= rng.range(0.97, 1.03); b *= rng.range(0.97, 1.03)
        let yy = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (r / yy, g / yy, b / yy)
    }

    /// Kalibreringsbillede: kortet midt i billedet uden fingre, neutralt lys.
    static func calibrationScene(width: Int, height: Int, ink: RGB8, fineLines: Bool = true) -> SynthScene {
        var s = SynthScene(width: width, height: height)
        s.backdrop = .ceiling
        s.backdropColor = RGB8(215, 215, 212)
        var c = SynthCard(center: Point2(Double(width) / 2, Double(height) / 2), width: Double(width) * 0.55, angle: 0.05, ink: ink)
        c.lineSpacing = fineLines ? 1.5 : 6
        s.card = c
        s.noise = 1.5
        return s
    }
}
