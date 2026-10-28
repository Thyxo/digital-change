import Foundation

/// 8-bit sRGB-farve.
struct RGB8: Equatable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// sRGB ↔ lineært lys og små hjælpere. Ren matematik uden UIKit, så den kan testes på Mac og Linux.
enum ColorMath {
    /// Opslagstabel: 8-bit sRGB → lineær (0…1).
    static let linearTable: [Double] = (0..<256).map { srgbToLinear(Double($0) / 255) }
    static let linearTableF: [Float] = linearTable.map { Float($0) }

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    @inline(__always) static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        if e1 <= e0 { return x < e0 ? 0 : 1 }
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}
