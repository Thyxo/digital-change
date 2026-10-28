import Foundation

/// Hvordan forklædningen slukkes ved afsløring.
enum TransitionKind: String, CaseIterable, Identifiable, Codable {
    case wave      // bølge fra fingeren (standard)
    case instant   // nul bevægelse: hårdt klip
    case fade
    case sweep     // fej oppefra
    var id: String { rawValue }
}

enum Easing {
    /// Kubisk ease-in-out (monoton fra 0 til 1).
    static func easeInOut(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

/// Én afsløring: hvor, hvornår og hvordan. Koordinater i kamerabilledets pixels.
/// Shaderen bruger præcis de samme formler (smoothstep om bølgefronten).
struct RevealPlan: Equatable {
    var kind: TransitionKind
    var start: Double
    var duration: Double
    /// Kantblødhed i pixels (halv bredde af overgangszonen).
    var softness: Double
    var center: Point2
    /// Bølgen skal nå kortets fjerneste hjørne.
    var maxRadius: Double
    /// Fej: fra kortets top til bund (skærmens retning).
    var top: Double
    var bottom: Double

    static func make(kind: TransitionKind, center: Point2, cardBounds: RectD?, frameWidth: Double, frameHeight: Double,
                     duration: Double, softness: Double, start: Double) -> RevealPlan {
        let box = cardBounds ?? RectD(minX: 0, minY: 0, maxX: frameWidth, maxY: frameHeight)
        return RevealPlan(kind: kind, start: start, duration: max(0.05, duration), softness: max(0.5, softness),
                          center: center, maxRadius: max(1, box.farthestCornerDistance(from: center)),
                          top: box.minY, bottom: box.maxY)
    }

    /// Lineær tid 0…1.
    func linear(at t: Double) -> Double { min(1, max(0, (t - start) / duration)) }

    /// Easet fremdrift 0…1.
    func progress(at t: Double) -> Double {
        kind == .instant ? (t >= start ? 1 : 0) : Easing.easeInOut(linear(at: t))
    }

    func isComplete(at t: Double) -> Bool { kind == .instant ? t >= start : t >= start + duration }

    /// Bølgefrontens radius.
    func radius(at t: Double) -> Double { progress(at: t) * (maxRadius + 2 * softness) - softness }

    /// Fej-frontens y.
    func sweepFront(at t: Double) -> Double { top - softness + progress(at: t) * (bottom - top + 2 * softness) }

    /// 0 = stadig forklædt, 1 = ægte farve.
    func reveal(at p: Point2, time t: Double) -> Double {
        if isComplete(at: t) { return 1 }
        switch kind {
        case .instant: return t >= start ? 1 : 0
        case .fade: return progress(at: t)
        case .wave:
            let r = radius(at: t)
            return 1 - ColorMath.smoothstep(r - softness, r + softness, p.distance(center))
        case .sweep:
            let y = sweepFront(at: t)
            return 1 - ColorMath.smoothstep(y - softness, y + softness, p.y)
        }
    }

    /// Meget svag lys kant i bølgefronten (0…1), aftager mod slutningen.
    func glow(at p: Point2, time t: Double) -> Double {
        guard kind == .wave, !isComplete(at: t) else { return 0 }
        let d = p.distance(center) - radius(at: t)
        let w = max(1, 0.6 * softness)
        return exp(-(d * d) / (w * w)) * (1 - linear(at: t))
    }
}
