import Foundation

struct MaskConfig: Equatable {
    /// Radier er sat til en analysebredde på ca. 270 px (¼ af 1080). Skaleres til andre bredder.
    static func forWidth(_ w: Int) -> MaskConfig {
        var c = MaskConfig()
        let k = Double(w) / 270
        c.closeRadius = max(1, Int((2 * k).rounded()))
        c.openRadius = k >= 0.5 ? 1 : 0
        c.safetyDilate = 1
        return c
    }

    /// Tidslig udglatning af pixelscoren: hurtig op (ingen blå kant foran et kort i bevægelse), langsom ned.
    var attack = 0.75
    var release = 0.35
    /// Hysterese på grænsen.
    var onThreshold = 0.5
    var offThreshold = 0.28
    /// Morfologi (pixels i analyseopløsning): lukning fylder mønstrets huller, åbning fjerner støj.
    var closeRadius = 2
    var openRadius = 1
    var safetyDilate = 1
    var minComponentFraction = 0.003
    /// Andre områder beholdes, hvis de er ≥ 20 % af det største og ligger tæt på (kort delt af en finger).
    var neighborFraction = 0.2
    var neighborGap = 0.12
    /// Dækker farven over 70 % af billedet, er hele billedet kortet (kort på linsen).
    var fullFrameEnter = 0.70
    var fullFrameExit = 0.60
    /// En firkant fra Vision bruges, hvis mindst 35 % af den er kortfarvet.
    var quadMinOverlap = 0.35
    var quadComponentOverlap = 0.3
    /// Masken holdes i 4 billeder efter et udfald og tones derefter ud (ingen blinkende kanter).
    var holdFrames = 4
    var decay = 0.6
    /// Kortet regnes for "set", når det dækker mindst 1,2 % af billedet.
    var visibleFraction = 0.012
}

struct MaskResult {
    var width = 0
    var height = 0
    /// Maske til visning (0–255), udglattet i tid og med blød kant.
    var mask: [UInt8] = []
    /// Andel af billedet, masken dækker (≥ 50 %).
    var coverage = 0.0
    /// Kortet er set i dette billede.
    var cardVisible = false
    var fullFrame = false
    var centroid: Point2?
    var bounds: RectD?
    var quad: Quad?
    /// Andel af kortets område (firkant eller farveområde), som er sat i masken.
    var selectedFraction = 0.0
}

/// Laver kortmasken i lav opløsning ud fra pixelscorer (0–255) og evt. firkanter fra Vision.
final class MaskProcessor {
    let width: Int
    let height: Int
    var config: MaskConfig

    private var ema: [Float]
    private var state: [UInt8]
    private var bin: [UInt8]
    private var tmp: [UInt8]
    private var target: [UInt8]
    private var value: [UInt8]
    private var age: [UInt8]
    private var soft: [UInt8]
    private var labels: [Int32]
    private var stack: [Int32]
    private var fullFrame = false

    private(set) var last = MaskResult()
    /// Valgt kortområde før sikkerhedsudvidelse (til tests og selvtest).
    private(set) var core: [UInt8] = []
    /// Kun de farvede områder (uden firkantens fyld) – papirets ring ligger lige udenfor.
    private(set) var colorCore: [UInt8] = []

    init(width: Int, height: Int, config: MaskConfig = MaskConfig()) {
        self.width = width
        self.height = height
        self.config = config
        let n = width * height
        ema = [Float](repeating: 0, count: n)
        state = [UInt8](repeating: 0, count: n)
        bin = [UInt8](repeating: 0, count: n)
        tmp = [UInt8](repeating: 0, count: n)
        target = [UInt8](repeating: 0, count: n)
        value = [UInt8](repeating: 0, count: n)
        age = [UInt8](repeating: 255, count: n)
        soft = [UInt8](repeating: 0, count: n)
        labels = [Int32](repeating: 0, count: n)
        stack = []
        stack.reserveCapacity(n)
    }

    func reset() {
        let n = width * height
        ema = [Float](repeating: 0, count: n)
        state = [UInt8](repeating: 0, count: n)
        value = [UInt8](repeating: 0, count: n)
        age = [UInt8](repeating: 255, count: n)
        fullFrame = false
        last = MaskResult()
    }

    // MARK: Hovedtrin

    @discardableResult
    func process(scores: [UInt8], quads: [Quad] = []) -> MaskResult {
        let n = width * height
        precondition(scores.count == n)
        let c = config

        // 1) Tidslig udglatning + hysterese
        let attack = Float(c.attack), release = Float(c.release)
        let on = Float(c.onThreshold), off = Float(c.offThreshold)
        scores.withUnsafeBufferPointer { s in
            ema.withUnsafeMutableBufferPointer { e in
                state.withUnsafeMutableBufferPointer { st in
                    for i in 0..<n {
                        let v = Float(s[i]) * (1 / 255)
                        let old = e[i]
                        let nv = v > old ? old + attack * (v - old) : old + release * (v - old)
                        e[i] = nv
                        st[i] = st[i] != 0 ? (nv > off ? 1 : 0) : (nv > on ? 1 : 0)
                    }
                }
            }
        }
        bin = state

        // 2) Morfologi: lukning (fylder mønstret) og åbning (fjerner støj)
        if c.closeRadius > 0 {
            MaskProcessor.dilate(&bin, &tmp, width, height, c.closeRadius)
            MaskProcessor.erode(&bin, &tmp, width, height, c.closeRadius)
        }
        if c.openRadius > 0 {
            MaskProcessor.erode(&bin, &tmp, width, height, c.openRadius)
            MaskProcessor.dilate(&bin, &tmp, width, height, c.openRadius)
        }

        let coverage = Double(bin.reduce(0) { $0 + Int($1) }) / Double(n)
        fullFrame = fullFrame ? coverage > c.fullFrameExit : coverage > c.fullFrameEnter

        var result = MaskResult()
        result.width = width
        result.height = height
        result.fullFrame = fullFrame

        // 3) Vælg kortets område
        for i in 0..<n { target[i] = 0 }
        colorCore = target
        var selectedArea = 0
        var usedQuad: Quad?
        if fullFrame {
            for i in 0..<n { target[i] = 1 }
            selectedArea = n
            result.selectedFraction = coverage
        } else {
            let comps = labelComponents()
            let minArea = max(4, Int(Double(n) * c.minComponentFraction))
            let big = comps.filter { $0.area >= minArea }
            if let (q, overlap) = MaskProcessor.bestQuad(quads, binary: bin, width: width, height: height, minOverlap: c.quadMinOverlap) {
                usedQuad = q
                result.selectedFraction = overlap
                // Områder, der ligger i firkanten (lidt forstørret), beholdes; firkanten selv fyldes.
                var inside = [Int](repeating: 0, count: comps.count + 1)
                q.scaled(1.15).forEachPixel(width: width, height: height) { i in
                    let l = Int(labels[i])
                    if l > 0 { inside[l] += 1 }
                }
                var keep = Set<Int32>()
                for comp in big where Double(inside[Int(comp.label)]) / Double(comp.area) >= c.quadComponentOverlap {
                    keep.insert(comp.label)
                }
                for i in 0..<n where labels[i] > 0 && keep.contains(labels[i]) { target[i] = 1 }
                colorCore = target
                q.forEachPixel(width: width, height: height) { i in target[i] = 1 }
            } else if let largest = big.max(by: { $0.area < $1.area }) {
                var keep: Set<Int32> = [largest.label]
                let gapLimit = c.neighborGap * Double(width)
                for comp in big where comp.label != largest.label {
                    if Double(comp.area) >= c.neighborFraction * Double(largest.area), comp.bounds.gap(largest.bounds) <= gapLimit {
                        keep.insert(comp.label)
                    }
                }
                for i in 0..<n where labels[i] > 0 && keep.contains(labels[i]) { target[i] = 1 }
                colorCore = target
                let area = big.filter { keep.contains($0.label) }.reduce(0) { $0 + $1.area }
                let bbox = big.filter { keep.contains($0.label) }.map(\.bounds).reduce(largest.bounds) {
                    RectD(minX: min($0.minX, $1.minX), minY: min($0.minY, $1.minY), maxX: max($0.maxX, $1.maxX), maxY: max($0.maxY, $1.maxY))
                }
                result.selectedFraction = Double(area) / max(1, bbox.width * bbox.height)
            }
            core = target
            if c.safetyDilate > 0 { MaskProcessor.dilate(&target, &tmp, width, height, c.safetyDilate) }
            selectedArea = target.reduce(0) { $0 + Int($1) }
        }
        if fullFrame { core = target; colorCore = target }
        if colorCore.count != n { colorCore = [UInt8](repeating: 0, count: n) }
        result.quad = usedQuad

        // 4) Hold og udtoning (ingen blink, når et billede falder ud)
        let hold = UInt8(min(250, c.holdFrames))
        let decay = Float(c.decay)
        target.withUnsafeBufferPointer { t in
            value.withUnsafeMutableBufferPointer { v in
                age.withUnsafeMutableBufferPointer { a in
                    for i in 0..<n {
                        if t[i] != 0 {
                            v[i] = 255
                            a[i] = 0
                        } else if a[i] < hold {
                            a[i] += 1
                        } else if v[i] > 0 {
                            v[i] = UInt8(Float(v[i]) * decay)
                        }
                    }
                }
            }
        }

        // 5) Blød kant (3×3-boks)
        MaskProcessor.boxBlur3(value, into: &soft, width, height)
        result.mask = soft

        // 6) Statistik
        var covered = 0, sx = 0.0, sy = 0.0, cnt = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if value[i] >= 128 { covered += 1 }
                if target[i] != 0 {
                    cnt += 1
                    sx += Double(x); sy += Double(y)
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        result.coverage = Double(covered) / Double(n)
        result.cardVisible = fullFrame || Double(selectedArea) >= c.visibleFraction * Double(n)
        if cnt > 0 {
            result.centroid = Point2(sx / Double(cnt) + 0.5, sy / Double(cnt) + 0.5)
            result.bounds = RectD(minX: Double(minX), minY: Double(minY), maxX: Double(maxX + 1), maxY: Double(maxY + 1))
        }
        last = result
        return result
    }

    /// Den aktuelle (holdte) binære maske før blød kant – til tests.
    var heldMask: [UInt8] { value }

    // MARK: Tryk

    /// Andel af maskens pixels (≥ 50 %) inden for `radius` fra (x, y) i analyseopløsning.
    func hitFraction(x: Double, y: Double, radius: Double) -> Double {
        MaskProcessor.hitFraction(value, width: width, height: height, x: x, y: y, radius: radius)
    }

    static func hitFraction(_ mask: [UInt8], width: Int, height: Int, x: Double, y: Double, radius: Double) -> Double {
        let r = max(0.5, radius)
        let y0 = max(0, Int((y - r).rounded(.down))), y1 = min(height - 1, Int((y + r).rounded(.up)))
        let x0 = max(0, Int((x - r).rounded(.down))), x1 = min(width - 1, Int((x + r).rounded(.up)))
        guard y0 <= y1, x0 <= x1 else { return 0 }
        var inside = 0, set = 0
        for yy in y0...y1 {
            for xx in x0...x1 {
                let dx = Double(xx) + 0.5 - x, dy = Double(yy) + 0.5 - y
                guard dx * dx + dy * dy <= r * r else { continue }
                inside += 1
                if mask[yy * width + xx] >= 128 { set += 1 }
            }
        }
        return inside > 0 ? Double(set) / Double(inside) : 0
    }

    // MARK: Firkant

    /// Firkanten med størst andel kortfarve (mindst `minOverlap`).
    static func bestQuad(_ quads: [Quad], binary: [UInt8], width: Int, height: Int, minOverlap: Double) -> (Quad, Double)? {
        var best: (Quad, Double)?
        for q in quads {
            var total = 0, on = 0
            q.forEachPixel(width: width, height: height) { i in
                total += 1
                if binary[i] != 0 { on += 1 }
            }
            guard total >= 16 else { continue }
            let f = Double(on) / Double(total)
            if f >= minOverlap, f > (best?.1 ?? -1) { best = (q, f) }
        }
        return best
    }

    // MARK: Sammenhængende områder (8-naboskab)

    struct Component {
        var label: Int32
        var area: Int
        var bounds: RectD
    }

    private func labelComponents() -> [Component] {
        let n = width * height
        for i in 0..<n { labels[i] = 0 }
        var comps: [Component] = []
        var next: Int32 = 0
        for start in 0..<n where bin[start] != 0 && labels[start] == 0 {
            next += 1
            labels[start] = next
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(start))
            var area = 0
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            while let p = stack.popLast() {
                let i = Int(p)
                let x = i % width, y = i / width
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < width else { continue }
                        let j = yy * width + xx
                        if bin[j] != 0 && labels[j] == 0 {
                            labels[j] = next
                            stack.append(Int32(j))
                        }
                    }
                }
            }
            comps.append(Component(label: next, area: area,
                                   bounds: RectD(minX: Double(minX), minY: Double(minY), maxX: Double(maxX + 1), maxY: Double(maxY + 1))))
        }
        return comps
    }

    // MARK: Morfologi (kvadratisk element, adskilt i to gennemløb med løbende tælling)

    static func dilate(_ a: inout [UInt8], _ tmp: inout [UInt8], _ w: Int, _ h: Int, _ r: Int) {
        pass(&a, &tmp, w, h, r, erode: false)
    }

    static func erode(_ a: inout [UInt8], _ tmp: inout [UInt8], _ w: Int, _ h: Int, _ r: Int) {
        pass(&a, &tmp, w, h, r, erode: true)
    }

    /// Ved billedkanten tælles kun pixels inden for billedet, så et kort, der går ud over kanten, ikke ædes.
    private static func pass(_ a: inout [UInt8], _ tmp: inout [UInt8], _ w: Int, _ h: Int, _ r: Int, erode: Bool) {
        if tmp.count != a.count { tmp = [UInt8](repeating: 0, count: a.count) }
        a.withUnsafeMutableBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                // vandret: src → dst
                for y in 0..<h {
                    let row = y * w
                    var count = 0
                    var lo = 0, hi = -1
                    for x in 0..<w {
                        let nlo = max(0, x - r), nhi = min(w - 1, x + r)
                        while hi < nhi { hi += 1; count += Int(src[row + hi]) }
                        while lo < nlo { count -= Int(src[row + lo]); lo += 1 }
                        let size = hi - lo + 1
                        dst[row + x] = erode ? (count == size ? 1 : 0) : (count > 0 ? 1 : 0)
                    }
                }
                // lodret: dst → src
                for x in 0..<w {
                    var count = 0
                    var lo = 0, hi = -1
                    for y in 0..<h {
                        let nlo = max(0, y - r), nhi = min(h - 1, y + r)
                        while hi < nhi { hi += 1; count += Int(dst[hi * w + x]) }
                        while lo < nlo { count -= Int(dst[lo * w + x]); lo += 1 }
                        let size = hi - lo + 1
                        src[y * w + x] = erode ? (count == size ? 1 : 0) : (count > 0 ? 1 : 0)
                    }
                }
            }
        }
    }

    static func boxBlur3(_ a: [UInt8], into out: inout [UInt8], _ w: Int, _ h: Int) {
        if out.count != a.count { out = [UInt8](repeating: 0, count: a.count) }
        a.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    for x in 0..<w {
                        var sum = 0, cnt = 0
                        for dy in -1...1 {
                            let yy = y + dy
                            guard yy >= 0, yy < h else { continue }
                            for dx in -1...1 {
                                let xx = x + dx
                                guard xx >= 0, xx < w else { continue }
                                sum += Int(s[yy * w + xx]); cnt += 1
                            }
                        }
                        o[y * w + x] = UInt8(sum / cnt)
                    }
                }
            }
        }
    }
}
