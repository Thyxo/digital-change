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
    mutating func gauss() -> Double {
        let u = max(1e-12, unit()), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// Baggrunde i de syntetiske billeder.
enum Backdrop: String, CaseIterable {
    case ceiling, whiteWall, wood, darkTable, gray, green, hand, gradient
}

/// Et rigtigt Rider Back-kort (skabelonens pixels) lagt ind i billedet med en homografi.
struct SynthCard {
    var template: CardTemplate
    /// Kanoniske kortkoordinater → billedets pixels.
    var homography: Homography
    /// Lineært lys pr. kanal (fx rødt lys fra skærmen) og lidt spredt lys.
    var gain = SIMD3<Double>(1, 1, 1)
    var offset = SIMD3<Double>(0, 0, 0)
    /// Ekstra uskarphed i pyramide-niveauer (0 = skarpt).
    var blur = 0

    var quad: Quad { homography.quad(width: template.geometry.width, height: template.geometry.height) }

    /// Kort med centrum, bredde (px), drejning (radianer) og vipning (perspektiv, −0,3…0,3).
    static func placed(_ t: CardTemplate, center: Point2, width: Double, angle: Double, tiltX: Double = 0, tiltY: Double = 0) -> SynthCard {
        let g = t.geometry
        let h = width * g.height / g.width
        let c = cos(angle), s = sin(angle)
        let local = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { p -> Point2 in
            // vipning: den ene side tættere på kameraet (større)
            let k = 1 + tiltY * p.1 * 2 + tiltX * p.0 * 2
            return Point2(p.0 * width * k, p.1 * h * k)
        }
        let pts = local.map { Point2(center.x + $0.x * c - $0.y * s, center.y + $0.x * s + $0.y * c) }
        return SynthCard(template: t, homography: Homography.from(g.corners, to: pts)!)
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
    var brightness = 1.0
    var noise = 2.0
    var seed: UInt64 = 1
}

struct SynthOutput {
    var image: RGBAImage
    /// Pixels inde i kortets omrids.
    var cardMask: [Bool]
    /// Pixels i overlay-området (mønster + halv kant), som ikke er dækket af fingre.
    var overlayMask: [Bool]
    /// Pixels i overlay-området, der er dækket af fingre.
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
        var cardM = [Bool](repeating: false, count: w * h)
        var overM = [Bool](repeating: false, count: w * h)
        var fingM = [Bool](repeating: false, count: w * h)
        let lin = ColorMath.linearTable
        func L(_ c: RGB8) -> SIMD3<Double> { SIMD3(lin[Int(c.r)], lin[Int(c.g)], lin[Int(c.b)]) }
        let bg1 = L(s.backdropColor), bg2 = L(s.backdropColor2)
        let fingers = s.fingers.map { f in (f, L(f.color), cos(-f.angle), sin(-f.angle)) }

        struct CardInfo { var inv: Homography; var tex: ColorImage; var k: Double; var ppu: Double; var c: SynthCard }
        var info: CardInfo?
        if let c = s.card, let inv = c.homography.inverse {
            let q = c.quad
            let ppu = (q.corners[0].distance(q.corners[1]) + q.corners[3].distance(q.corners[2])) / 2 / c.template.geometry.width
            let lv = min(c.template.colors.count - 1, c.template.level(forPixelsPerUnit: ppu) + c.blur)
            info = CardInfo(inv: inv, tex: c.template.colors[lv], k: c.template.scale(level: lv), ppu: ppu, c: c)
        }

        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let i = y * w + x
                var col = backdrop(s, px, py, bg1, bg2)
                var inOverlay = false

                if let ci = info {
                    let q = ci.inv.apply(Point2(px, py))
                    let g = ci.c.template.geometry
                    let a = min(1, max(0, 0.5 - g.cardDistance(q) * ci.ppu))
                    if a > 0, let t = ci.tex.sample(q.x * ci.k, q.y * ci.k) {
                        let cc = ci.c.gain * t + ci.c.offset
                        col = col + (cc - col) * a
                        if a >= 0.5 { cardM[i] = true }
                        if g.overlayDistance(q) < 0 { inOverlay = true }
                    }
                }

                var covered = false
                for (f, fc, ca, sa) in fingers {
                    let dx = px - f.center.x, dy = py - f.center.y
                    let u = (dx * ca - dy * sa) / f.rx, v = (dx * sa + dy * ca) / f.ry
                    let d = u * u + v * v
                    if d <= 1 {
                        col = fc * (1 - 0.35 * d)
                        covered = true
                    }
                }
                if inOverlay { if covered { fingM[i] = true } else { overM[i] = true } }

                col *= s.brightness
                func enc(_ v: Double) -> UInt8 {
                    let e = ColorMath.linearToSrgb(min(1, max(0, v))) * 255 + (rng.unit() + rng.unit() - 1) * 2.449 * s.noise
                    return UInt8(min(255, max(0, e.rounded())))
                }
                img.pixels[i * 4] = enc(col.x)
                img.pixels[i * 4 + 1] = enc(col.y)
                img.pixels[i * 4 + 2] = enc(col.z)
                img.pixels[i * 4 + 3] = 255
            }
        }
        return SynthOutput(image: img, cardMask: cardM, overlayMask: overM, fingerMask: fingM)
    }

    private static func backdrop(_ s: SynthScene, _ x: Double, _ y: Double,
                                 _ c1: SIMD3<Double>, _ c2: SIMD3<Double>) -> SIMD3<Double> {
        let w = Double(s.width), h = Double(s.height)
        switch s.backdrop {
        case .ceiling:
            let dx = (x - w * 0.5) / w, dy = (y - h * 0.4) / h
            return c1 * (1 - 0.5 * (dx * dx + dy * dy))
        case .whiteWall:
            return c1 * (0.92 + 0.08 * (y / h))
        case .wood:
            return c1 * (0.85 + 0.15 * sin(y * 0.25 + sin(x * 0.04) * 2.5))
        case .darkTable, .gray, .green:
            return c1
        case .hand:
            let dx = (x - w * 0.5) / w
            return c1 * (1 - 0.6 * dx * dx)
        case .gradient:
            return c1 + (c2 - c1) * (y / h)
        }
    }

    static func randomBackdrop(_ rng: inout SplitMix64) -> (Backdrop, RGB8, RGB8) {
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
            case .gradient: return RGB8(UInt8(rng.range(20, 240)), UInt8(rng.range(20, 240)), UInt8(rng.range(20, 240)))
            }
        }
        return (kind, color(), color())
    }

    /// Tilfældig scene: kortet (eller intet) med tilfældig placering, perspektiv, lys, uskarphed, støj og fingre.
    static func randomScene(_ rng: inout SplitMix64, width: Int, height: Int, card template: CardTemplate?,
                            fingers maxFingers: Int = 2) -> SynthScene {
        var s = SynthScene(width: width, height: height)
        let (kind, c1, c2) = randomBackdrop(&rng)
        s.backdrop = kind
        s.backdropColor = c1
        s.backdropColor2 = c2
        s.brightness = rng.range(0.8, 1.1)
        s.noise = rng.range(0.5, 3)
        s.seed = rng.next()
        let W = Double(width), H = Double(height)
        if let t = template {
            let cw = rng.range(0.38, 0.7) * W
            var card = SynthCard.placed(t, center: Point2(rng.range(0.38, 0.62) * W, rng.range(0.4, 0.6) * H), width: cw,
                                        angle: rng.range(-0.6, 0.6), tiltX: rng.range(-0.12, 0.12), tiltY: rng.range(-0.15, 0.15))
            // lys: lysstyrke, farvestik og skærmens røde/blå lys på kortet
            let b = rng.range(0.6, 1.05)
            var tint = SIMD3(rng.range(0.92, 1.08), rng.range(0.95, 1.04), rng.range(0.9, 1.08))
            if rng.chance(0.5) { tint.x *= rng.range(1, 1.35) } else { tint.z *= rng.range(1, 1.25) }
            card.gain = tint * b
            card.offset = SIMD3(repeating: rng.range(0, 0.025))
            card.blur = rng.chance(0.35) ? 1 : 0
            s.card = card
            let nf = rng.int(maxFingers + 1)
            let q = card.quad
            for _ in 0..<nf {
                // finger der griber om en kant og når ind over mønstret
                let e = rng.int(4)
                let a = q.corners[e], bb = q.corners[(e + 1) % 4]
                let tt = rng.range(0.25, 0.75)
                let p = Point2(a.x + (bb.x - a.x) * tt, a.y + (bb.y - a.y) * tt)
                s.fingers.append(Finger(center: p, rx: cw * rng.range(0.09, 0.14), ry: cw * rng.range(0.22, 0.34),
                                        angle: atan2(bb.y - a.y, bb.x - a.x) + .pi / 2, color: rng.pick(skinTones)))
            }
        } else {
            let nf = rng.int(maxFingers + 2)
            for _ in 0..<nf {
                s.fingers.append(Finger(center: Point2(rng.range(0.1, 0.9) * W, rng.range(0.1, 0.9) * H),
                                        rx: W * rng.range(0.06, 0.12), ry: W * rng.range(0.2, 0.4),
                                        angle: rng.range(0, .pi), color: rng.pick(skinTones)))
            }
        }
        return s
    }

    /// Vision-agtigt startgæt: kortets hjørner med lidt støj (Vision rammer afrundede hjørner med nogle procents fejl).
    static func noisyQuad(_ q: Quad, rng: inout SplitMix64, sigma: Double) -> Quad {
        Quad(corners: q.corners.map { Point2($0.x + rng.gauss() * sigma, $0.y + rng.gauss() * sigma) })
    }
}
