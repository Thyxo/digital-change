import Foundation

/// De to fysiske kort (Bicycle Rider Back).
enum CardColor: String, CaseIterable, Codable {
    case blue, red
    var other: CardColor { self == .blue ? .red : .blue }
}

/// Kortets geometri i kanoniske koordinater (fra ios/Cards/rider.json, målt af scripts/prepare-cards.py).
struct CardGeometry: Codable, Equatable {
    struct Rect: Codable, Equatable { var minX, minY, maxX, maxY: Double }
    struct Size: Codable, Equatable { var width, height: Int }
    var width: Double
    var height: Double
    var cornerRadius: Double
    /// Mønstrets ydre ramme (yderkanten af blækket).
    var pattern: Rect
    var analysis: Size

    /// Den del af kortet, der tegnes over: mønstret plus halvdelen af den hvide kant. Den yderste halvdel af kanten
    /// er altid kameraets eget kort – rigtige kort er skåret lidt forskelligt, og hvidt mod hvidt kan ikke ses.
    var overlay: Rect {
        let bx = min(pattern.minX, width - pattern.maxX), by = min(pattern.minY, height - pattern.maxY)
        let e = 0.5 * min(bx, by)
        return Rect(minX: pattern.minX - e, minY: pattern.minY - e, maxX: pattern.maxX + e, maxY: pattern.maxY + e)
    }
    /// Blød overgang i kanten af overlay-området (kanoniske enheder).
    var overlayFeather: Double { 0.25 * min(pattern.minX, pattern.minY) }
    var overlayRadius: Double { 0.5 * cornerRadius }

    /// Signeret afstand til overlay-områdets afrundede rektangel (negativ indenfor).
    func overlayDistance(_ p: Point2) -> Double {
        let o = overlay, r = overlayRadius
        let cx = (o.minX + o.maxX) / 2, cy = (o.minY + o.maxY) / 2
        let qx = abs(p.x - cx) - ((o.maxX - o.minX) / 2 - r), qy = abs(p.y - cy) - ((o.maxY - o.minY) / 2 - r)
        let out = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
        return out + min(max(qx, qy), 0) - r
    }

    /// Signeret afstand til kortets omrids (negativ indenfor).
    func cardDistance(_ p: Point2) -> Double {
        let r = cornerRadius
        let qx = abs(p.x - width / 2) - (width / 2 - r), qy = abs(p.y - height / 2) - (height / 2 - r)
        let out = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
        return out + min(max(qx, qy), 0) - r
    }

    /// Kortets hjørner (kanoniske), med uret fra øverst til venstre.
    var corners: [Point2] { [Point2(0, 0), Point2(width, 0), Point2(width, height), Point2(0, height)] }
}

/// Gråtonebillede (Float). Koordinater i kant-konvention: pixel i har centrum i i + 0,5.
struct GrayImage {
    var width: Int
    var height: Int
    var data: [Float]

    init(width: Int, height: Int, data: [Float]? = nil) {
        self.width = width; self.height = height
        self.data = data ?? [Float](repeating: 0, count: width * height)
    }

    /// Bilineær prøve; nil uden for billedet.
    @inline(__always) func sample(_ x: Double, _ y: Double) -> Float? {
        let fx = x - 0.5, fy = y - 0.5
        guard fx >= 0, fy >= 0, fx <= Double(width - 1), fy <= Double(height - 1) else { return nil }
        let x0 = min(Int(fx), width - 2), y0 = min(Int(fy), height - 2)
        let ax = Float(fx - Double(x0)), ay = Float(fy - Double(y0))
        let i = y0 * width + x0
        let top = data[i] + (data[i + 1] - data[i]) * ax
        let bot = data[i + width] + (data[i + width + 1] - data[i + width]) * ax
        return top + (bot - top) * ay
    }

    /// Halv størrelse (2×2-gennemsnit).
    func half() -> GrayImage {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = GrayImage(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (2 * y) * width + 2 * x
                out.data[y * w + x] = 0.25 * (data[i] + data[i + 1] + data[i + width] + data[i + width + 1])
            }
        }
        return out
    }
}

/// Lineært RGB-billede (tre gråtonekanaler).
struct ColorImage {
    var r: GrayImage
    var g: GrayImage
    var b: GrayImage
    var width: Int { r.width }
    var height: Int { r.height }

    func half() -> ColorImage { ColorImage(r: r.half(), g: g.half(), b: b.half()) }

    @inline(__always) func sample(_ x: Double, _ y: Double) -> SIMD3<Double>? {
        guard let rr = r.sample(x, y), let gg = g.sample(x, y), let bb = b.sample(x, y) else { return nil }
        return SIMD3(Double(rr), Double(gg), Double(bb))
    }

    /// Fra 8-bit sRGB (RGBA) til lineært lys.
    init(_ img: RGBAImage) {
        let n = img.width * img.height
        var rr = [Float](repeating: 0, count: n), gg = rr, bb = rr
        let lin = ColorMath.linearTableF
        img.pixels.withUnsafeBufferPointer { p in
            for i in 0..<n {
                rr[i] = lin[Int(p[i * 4])]; gg[i] = lin[Int(p[i * 4 + 1])]; bb[i] = lin[Int(p[i * 4 + 2])]
            }
        }
        r = GrayImage(width: img.width, height: img.height, data: rr)
        g = GrayImage(width: img.width, height: img.height, data: gg)
        b = GrayImage(width: img.width, height: img.height, data: bb)
    }

    init(r: GrayImage, g: GrayImage, b: GrayImage) { self.r = r; self.g = g; self.b = b }
}

enum Luma {
    /// Lysstyrke (0…1) af 8-bit sRGB – samme formel for kamera og skabelon.
    @inline(__always) static func of(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Float {
        (0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)) * (1 / 255)
    }

    static func image(_ img: RGBAImage) -> GrayImage {
        var out = GrayImage(width: img.width, height: img.height)
        img.pixels.withUnsafeBufferPointer { p in
            for i in 0..<(img.width * img.height) { out.data[i] = of(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) }
        }
        return out
    }

    /// Pyramide: niveau 0 = billedet, hvert næste halv størrelse.
    static func pyramid(_ base: GrayImage, levels: Int) -> [GrayImage] {
        var out = [base]
        while out.count < levels, out.last!.width >= 16, out.last!.height >= 16 { out.append(out.last!.half()) }
        return out
    }
}

/// Én Rider Back-skabelon i analyseopløsning (256 px bred) med pyramider til sporing og farvetilpasning.
/// Billedet er en nedskalering af ios/Cards/rider-<farve>.png – samme pixels som appen tegner.
final class CardTemplate {
    let color: CardColor
    let geometry: CardGeometry
    let image: RGBAImage
    /// Lysstyrke-pyramide (niveau 0 = 256 px bred).
    let luma: [GrayImage]
    /// Lineær farve-pyramide.
    let colors: [ColorImage]
    /// Skabelonpixels pr. kanonisk enhed på niveau 0.
    let scale0: Double
    /// Papirets lineære farve (målt i den hvide kant).
    let paper: SIMD3<Double>

    init(color: CardColor, geometry: CardGeometry, image: RGBAImage) {
        self.color = color
        self.geometry = geometry
        self.image = image
        scale0 = Double(image.width) / geometry.width
        luma = Luma.pyramid(Luma.image(image), levels: 4)
        var c = [ColorImage(image)]
        while c.count < luma.count { c.append(c.last!.half()) }
        colors = c
        // papir: medianen af kantbåndet (mellem 30 % og 70 % af kantbredden inde fra kanten)
        var rs: [Float] = [], gs: [Float] = [], bs: [Float] = []
        let b = min(geometry.pattern.minX, geometry.pattern.minY)
        let lv = colors[0]
        for y in 0..<lv.height {
            for x in 0..<lv.width {
                let p = Point2((Double(x) + 0.5) / scale0, (Double(y) + 0.5) / scale0)
                let d = -geometry.cardDistance(p)
                if d > 0.3 * b && d < 0.7 * b {
                    let i = y * lv.width + x
                    rs.append(lv.r.data[i]); gs.append(lv.g.data[i]); bs.append(lv.b.data[i])
                }
            }
        }
        func med(_ a: [Float]) -> Double { a.isEmpty ? 0.85 : Double(a.sorted()[a.count / 2]) }
        paper = SIMD3(med(rs), med(gs), med(bs))
    }

    /// Skabelonpixels pr. kanonisk enhed på et niveau.
    func scale(level: Int) -> Double { scale0 / Double(1 << level) }

    /// Det niveau, hvis opløsning passer bedst til `pixelsPerUnit` (skabelonen må gerne være lidt skarpere).
    func level(forPixelsPerUnit p: Double) -> Int {
        var best = 0
        for l in 0..<luma.count where scale(level: l) >= p * 0.75 { best = l }
        return best
    }

    // MARK: Indlæsning

    enum LoadError: Error { case missing(String), badSize }

    /// Indlæser rider.json og rider-<farve>.rgb fra en mappe (appens "Cards" eller ios/Cards i tests).
    static func load(directory: URL, color: CardColor) throws -> CardTemplate {
        let geo = try loadGeometry(directory: directory)
        let url = directory.appendingPathComponent("rider-\(color.rawValue).rgb")
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing(url.path) }
        let w = geo.analysis.width, h = geo.analysis.height
        guard data.count == w * h * 3 else { throw LoadError.badSize }
        var img = RGBAImage(width: w, height: h)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                img.pixels[i * 4] = p[i * 3]; img.pixels[i * 4 + 1] = p[i * 3 + 1]; img.pixels[i * 4 + 2] = p[i * 3 + 2]
                img.pixels[i * 4 + 3] = 255
            }
        }
        return CardTemplate(color: color, geometry: geo, image: img)
    }

    static func loadGeometry(directory: URL) throws -> CardGeometry {
        let url = directory.appendingPathComponent("rider.json")
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing(url.path) }
        return try JSONDecoder().decode(CardGeometry.self, from: data)
    }
}

/// Begge skabeloner.
struct CardTemplates {
    let blue: CardTemplate
    let red: CardTemplate
    func of(_ c: CardColor) -> CardTemplate { c == .blue ? blue : red }

    static func load(directory: URL) throws -> CardTemplates {
        CardTemplates(blue: try CardTemplate.load(directory: directory, color: .blue),
                      red: try CardTemplate.load(directory: directory, color: .red))
    }
}
