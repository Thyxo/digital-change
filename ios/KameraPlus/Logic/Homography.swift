import Foundation

/// 3×3 projektiv afbildning (rækkevis, m[8] normaliseres til 1 hvor muligt).
/// Bruges mellem kortets kanoniske koordinater (0…1024 × 0…1424) og billedets pixels (kant-konvention:
/// pixel i har centrum i i + 0,5).
struct Homography: Equatable {
    var m: [Double]

    init(_ m: [Double]) { precondition(m.count == 9); self.m = m }
    static let identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    static func scale(_ sx: Double, _ sy: Double, tx: Double = 0, ty: Double = 0) -> Homography {
        Homography([sx, 0, tx, 0, sy, ty, 0, 0, 1])
    }

    func apply(_ p: Point2) -> Point2 {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        return Point2((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    /// Nævneren (w) – positiv for punkter foran "kameraet".
    func w(_ p: Point2) -> Double { m[6] * p.x + m[7] * p.y + m[8] }

    /// a * b: først b, så a.
    static func * (a: Homography, b: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 {
            r[i * 3 + j] = a.m[i * 3] * b.m[j] + a.m[i * 3 + 1] * b.m[3 + j] + a.m[i * 3 + 2] * b.m[6 + j]
        } }
        return Homography(r).normalized
    }

    var normalized: Homography {
        guard abs(m[8]) > 1e-12 else { return self }
        return Homography(m.map { $0 / m[8] })
    }

    var inverse: Homography? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7], c01 = a[5] * a[6] - a[3] * a[8], c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-15 else { return nil }
        let inv = [
            c00, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            c01, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            c02, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
        ].map { $0 / det }
        return Homography(inv).normalized
    }

    /// Homografien der sender de fire `src`-punkter til de fire `dst`-punkter.
    static func from(_ src: [Point2], to dst: [Point2]) -> Homography? {
        guard src.count == 4, dst.count == 4 else { return nil }
        var A = [Double](repeating: 0, count: 64), b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let (x, y, u, v) = (src[i].x, src[i].y, dst[i].x, dst[i].y)
            let r0 = i * 2, r1 = i * 2 + 1
            A.replaceSubrange(r0 * 8..<r0 * 8 + 8, with: [x, y, 1, 0, 0, 0, -u * x, -u * y]); b[r0] = u
            A.replaceSubrange(r1 * 8..<r1 * 8 + 8, with: [0, 0, 0, x, y, 1, -v * x, -v * y]); b[r1] = v
        }
        guard let h = LinearSolve.solve(A, b, n: 8) else { return nil }
        return Homography(h + [1])
    }

    func quad(width: Double, height: Double) -> Quad {
        Quad(apply(Point2(0, 0)), apply(Point2(width, 0)), apply(Point2(width, height)), apply(Point2(0, height)))
    }
}

enum LinearSolve {
    /// Løser A·x = b (n×n, rækkevis) med Gauss-elimination og delvis pivotering.
    static func solve(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        var a = A, x = b
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(a[r * n + c]) > abs(a[p * n + c]) { p = r }
            guard abs(a[p * n + c]) > 1e-14 else { return nil }
            if p != c {
                for k in 0..<n { a.swapAt(c * n + k, p * n + k) }
                x.swapAt(c, p)
            }
            let d = a[c * n + c]
            for r in (c + 1)..<max(c + 1, n) {
                let f = a[r * n + c] / d
                if f == 0 { continue }
                for k in c..<n { a[r * n + k] -= f * a[c * n + k] }
                x[r] -= f * x[c]
            }
        }
        for c in stride(from: n - 1, through: 0, by: -1) {
            var s = x[c]
            for k in (c + 1)..<max(c + 1, n) { s -= a[c * n + k] * x[k] }
            x[c] = s / a[c * n + c]
        }
        return x
    }
}
