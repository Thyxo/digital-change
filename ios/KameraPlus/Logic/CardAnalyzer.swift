import Foundation

/// Samler klassifikator-tabel, lys-tilpasning og maske for ét lavopløsningsbillede.
/// Bruges både af appen (pr. kamerabillede) og af tests/selvtest.
final class CardAnalyzer {
    let bits: Int
    private(set) var lut: [UInt8]
    private(set) var classifier: CardClassifier
    private var scores: [UInt8] = []
    private(set) var processor: MaskProcessor?
    var maskConfig: MaskConfig?

    /// Skærmens lys på kortet (se IlluminationModel). nil = ingen tilpasning.
    var illumination: IlluminationModel? { didSet { if illumination != oldValue { rebuildLightTables() } } }
    var adaptiveLight = true
    /// Aktuel lysparameter og den forstærkning, der fjerner lyset (bruges også af shaderen).
    private(set) var k = 0.0
    private(set) var gain = ChannelGain.identity
    private var grid: [Double] = []
    private var tables: [GainTable] = []
    private var current = 0
    private var frameCount = 0
    private var samples: [Int] = []

    init(classifier: CardClassifier, bits: Int = 6, lut: [UInt8]? = nil) {
        self.bits = bits
        self.classifier = classifier
        self.lut = lut ?? classifier.buildLUT(bits: bits)
    }

    /// Ny farvemodel (efter kalibrering eller ændret følsomhed).
    func update(classifier: CardClassifier, lut: [UInt8]? = nil) {
        self.classifier = classifier
        self.lut = lut ?? classifier.buildLUT(bits: bits)
    }

    func reset() {
        processor?.reset()
        frameCount = 0
        setK(0)
    }

    private func rebuildLightTables() {
        guard let m = illumination else { grid = []; tables = []; current = 0; k = 0; gain = .identity; return }
        grid = m.grid(step: 0.02)
        tables = grid.map { GainTable(m.gain($0)) }
        setK(k)
    }

    private func setK(_ v: Double) {
        guard let m = illumination, !grid.isEmpty else { k = 0; gain = .identity; return }
        k = min(m.kMax, max(-m.kMax, v))
        var best = 0
        for i in grid.indices where abs(grid[i] - k) < abs(grid[best] - k) { best = i }
        current = best
        gain = m.gain(grid[best])
    }

    /// Scorer og laver masken. Firkanter i samme pixelkoordinater som billedet.
    @discardableResult
    func analyze(_ img: RGBAImage, quads: [Quad] = []) -> MaskResult {
        if processor == nil || processor!.width != img.width || processor!.height != img.height {
            processor = MaskProcessor(width: img.width, height: img.height, config: maskConfig ?? MaskConfig.forWidth(img.width))
        }
        frameCount += 1
        if adaptiveLight && !tables.isEmpty { fitLight(img) }
        CardClassifier.scores(img, lut: lut, bits: bits, gain: tables.isEmpty ? nil : tables[current], into: &scores)
        return processor!.process(scores: scores, quads: quads)
    }

    // MARK: Lys

    @inline(__always) private func score(_ px: UnsafeBufferPointer<UInt8>, _ i: Int, _ t: GainTable, _ l: UnsafeBufferPointer<UInt8>) -> Int {
        let k4 = i * 4
        let s = UInt8(8 - bits)
        let r = t.r[Int(px[k4])] >> s, g = t.g[Int(px[k4 + 1])] >> s, b = t.b[Int(px[k4 + 2])] >> s
        return Int(l[(Int(r) << (2 * bits)) | (Int(g) << bits) | Int(b)])
    }

    private func countCoarse(_ px: UnsafeBufferPointer<UInt8>, _ w: Int, _ h: Int, _ t: GainTable, _ l: UnsafeBufferPointer<UInt8>) -> Int {
        var c = 0
        var y = 1
        while y < h {
            var x = 1
            while x < w {
                if score(px, y * w + x, t, l) >= 160 { c += 1 }
                x += 3
            }
            y += 3
        }
        return c
    }

    /// Finder det k, der får kortets pixels (fra sidste maske) til at ligne kortet mest.
    /// Uden kort: en grovere søgning over hele billedet hvert 3. billede, så kortet også findes,
    /// når det dukker op i farvet lys.
    private func fitLight(_ img: RGBAImage) {
        guard let p = processor else { return }
        let held = p.heldMask
        samples.removeAll(keepingCapacity: true)
        if p.last.cardVisible {
            var count = 0
            for v in held where v >= 128 { count += 1 }
            let step = max(1, count / 600)
            var seen = 0
            for i in 0..<held.count where held[i] >= 128 {
                if seen % step == 0 { samples.append(i) }
                seen += 1
            }
        }
        let w = img.width, h = img.height
        img.pixels.withUnsafeBufferPointer { px in
            lut.withUnsafeBufferPointer { l in
                if samples.count >= 30 {
                    var bestJ = current, bestV = -Double.infinity
                    for j in grid.indices {
                        var sum = 0
                        for i in samples { sum += score(px, i, tables[j], l) }
                        let v = Double(sum) / Double(samples.count * 255) - 0.05 * abs(grid[j])
                        if v > bestV + 1e-9 { bestV = v; bestJ = j }
                    }
                    setK(k + 0.6 * (grid[bestJ] - k))
                } else if frameCount % 3 == 0 {
                    let nowCount = countCoarse(px, w, h, tables[current], l)
                    // Uden kort viser søgeren rummet og kortets ægte farve – aldrig forklædningen –
                    // så der søges kun i lys mod kildens farve (k ≤ 0).
                    var best = current, bestCount = nowCount
                    for j in stride(from: 0, to: grid.count, by: 3) where grid[j] <= 0.001 && grid[j] >= -0.5 {
                        let c = countCoarse(px, w, h, tables[j], l)
                        if c > bestCount { bestCount = c; best = j }
                    }
                    let minCount = max(6, (w / 3) * (h / 3) * 3 / 200)
                    if bestCount >= minCount && bestCount > nowCount + nowCount / 3 {
                        setK(grid[best])
                    } else if nowCount < minCount {
                        setK(k * 0.95)
                    }
                }
            }
        }
    }

    /// Seneste pixelscorer (0–255) – til menuens forhåndsvisning.
    var lastScores: [UInt8] { scores }
}

/// Mål for, hvor godt to masker passer sammen.
enum MaskMetrics {
    static func iou(_ a: [UInt8], _ b: [Bool]) -> Double {
        var inter = 0, uni = 0
        for i in 0..<min(a.count, b.count) {
            let x = a[i] != 0, y = b[i]
            if x && y { inter += 1 }
            if x || y { uni += 1 }
        }
        return uni == 0 ? 1 : Double(inter) / Double(uni)
    }

    static func fraction(_ a: [UInt8], threshold: UInt8 = 128) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }) / Double(a.count)
    }
}
