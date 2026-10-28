import Foundation

struct Point2: Equatable, Codable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static let zero = Point2(0, 0)
    static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    static func * (a: Point2, k: Double) -> Point2 { Point2(a.x * k, a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
    func distance(_ p: Point2) -> Double { (self - p).length }
}

struct RectD: Equatable {
    var minX: Double, minY: Double, maxX: Double, maxY: Double
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: Point2 { Point2((minX + maxX) / 2, (minY + maxY) / 2) }

    /// Afstand mellem to rektangler (0 hvis de overlapper).
    func gap(_ o: RectD) -> Double {
        let dx = max(0, max(o.minX - maxX, minX - o.maxX))
        let dy = max(0, max(o.minY - maxY, minY - o.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Længste afstand fra et punkt til et af hjørnerne.
    func farthestCornerDistance(from p: Point2) -> Double {
        [Point2(minX, minY), Point2(maxX, minY), Point2(minX, maxY), Point2(maxX, maxY)].map { $0.distance(p) }.max() ?? 0
    }
}

/// Firkant (kortets omrids) med fire hjørner i rækkefølge rundt.
struct Quad: Equatable {
    var corners: [Point2]

    init(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) { corners = [a, b, c, d] }
    init(corners: [Point2]) { precondition(corners.count == 4); self.corners = corners }

    /// Rektangel med centrum, størrelse og drejning (radianer).
    static func rect(center: Point2, width: Double, height: Double, angle: Double) -> Quad {
        let c = cos(angle), s = sin(angle)
        let hw = width / 2, hh = height / 2
        let pts = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { p in
            Point2(center.x + p.0 * c - p.1 * s, center.y + p.0 * s + p.1 * c)
        }
        return Quad(corners: pts)
    }

    var centroid: Point2 {
        Point2(corners.map(\.x).reduce(0, +) / 4, corners.map(\.y).reduce(0, +) / 4)
    }

    var area: Double {
        var s = 0.0
        for i in 0..<4 {
            let p = corners[i], q = corners[(i + 1) % 4]
            s += p.x * q.y - q.x * p.y
        }
        return abs(s) / 2
    }

    var bounds: RectD {
        RectD(minX: corners.map(\.x).min()!, minY: corners.map(\.y).min()!,
              maxX: corners.map(\.x).max()!, maxY: corners.map(\.y).max()!)
    }

    /// Gennemsnit af to modstående sider.
    var sideLengths: (Double, Double) {
        let a = (corners[0].distance(corners[1]) + corners[2].distance(corners[3])) / 2
        let b = (corners[1].distance(corners[2]) + corners[3].distance(corners[0])) / 2
        return (a, b)
    }

    var shortSide: Double { min(sideLengths.0, sideLengths.1) }
    var longSide: Double { max(sideLengths.0, sideLengths.1) }
    var aspect: Double { longSide > 0 ? shortSide / longSide : 0 }

    /// Vinkel for den lange akse (radianer, 0…π).
    var longAxisAngle: Double {
        let (a, b) = sideLengths
        let v = a >= b ? (corners[1] - corners[0]) + (corners[2] - corners[3]) : (corners[2] - corners[1]) + (corners[3] - corners[0])
        var ang = atan2(v.y, v.x)
        if ang < 0 { ang += .pi }
        if ang >= .pi { ang -= .pi }
        return ang
    }

    func contains(_ p: Point2) -> Bool {
        var inside = false
        var j = 3
        for i in 0..<4 {
            let a = corners[i], b = corners[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    func scaled(_ k: Double) -> Quad {
        let c = centroid
        return Quad(corners: corners.map { c + ($0 - c) * k })
    }

    /// Kalder `body(i)` for hver pixel (indeks i) hvis centrum ligger inde i firkanten.
    func forEachPixel(width: Int, height: Int, _ body: (Int) -> Void) {
        let b = bounds
        let y0 = max(0, Int(b.minY.rounded(.down))), y1 = min(height - 1, Int(b.maxY.rounded(.up)))
        let x0 = max(0, Int(b.minX.rounded(.down))), x1 = min(width - 1, Int(b.maxX.rounded(.up)))
        guard y0 <= y1, x0 <= x1 else { return }
        for y in y0...y1 {
            for x in x0...x1 where contains(Point2(Double(x) + 0.5, Double(y) + 0.5)) {
                body(y * width + x)
            }
        }
    }
}

/// Omregning mellem søgeren (punkter, origo øverst til venstre) og kamerabilledet (pixels).
/// Billedet vises "aspect fill" i søgeren, beskåret om centrum med `zoom` (≥ 1), evt. spejlet.
struct ViewMapping: Equatable {
    var viewWidth: Double
    var viewHeight: Double
    var frameWidth: Double
    var frameHeight: Double
    var zoom: Double = 1
    var mirrored: Bool = true

    private var scale: Double { max(viewWidth / frameWidth, viewHeight / frameHeight) * max(1, zoom) }
    var visibleWidth: Double { viewWidth / scale }
    var visibleHeight: Double { viewHeight / scale }
    var originX: Double { (frameWidth - visibleWidth) / 2 }
    var originY: Double { (frameHeight - visibleHeight) / 2 }

    /// Synligt udsnit af billedet i tekstur-koordinater (0…1).
    var cropOrigin: Point2 { Point2(originX / frameWidth, originY / frameHeight) }
    var cropSize: Point2 { Point2(visibleWidth / frameWidth, visibleHeight / frameHeight) }

    /// Punkter i søgeren pr. pixel i kamerabilledet.
    var pointsPerPixel: Double { scale }

    func framePoint(fromView p: Point2) -> Point2 {
        var x = originX + p.x / viewWidth * visibleWidth
        let y = originY + p.y / viewHeight * visibleHeight
        if mirrored { x = frameWidth - x }
        return Point2(x, y)
    }

    func viewPoint(fromFrame p: Point2) -> Point2 {
        let x = mirrored ? frameWidth - p.x : p.x
        return Point2((x - originX) / visibleWidth * viewWidth, (p.y - originY) / visibleHeight * viewHeight)
    }
}
