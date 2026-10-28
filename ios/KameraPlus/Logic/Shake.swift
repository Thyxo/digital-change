import Foundation

/// Følsomhed for "Ryst kortet": mindste udsving i forhold til kortets bredde.
enum ShakeSensitivity: String, CaseIterable, Identifiable, Codable {
    case light   // let
    case normal
    case hard    // hård
    var id: String { rawValue }
    var amplitudeFraction: Double {
        switch self {
        case .light: return 0.04
        case .normal: return 0.06
        case .hard: return 0.09
        }
    }
}

/// Ét billede af det sporede kort.
struct CardTrackSample {
    var t: Double
    var center: Point2
    /// Firkantens hjørner, hvis Vision kender dem (ellers nil).
    var corners: [Point2]?
    var cardWidth: Double
    /// Ligger telefonen stille (CoreMotion)?
    var phoneStill: Bool
}

/// Tæller retningsskift i ét signal. Et skift tæller kun, når signalet er gået mindst `amplitude` tilbage
/// fra sidste yderpunkt. Første bevægelse fastlægger blot retningen.
struct ReversalCounter {
    private var lo: Double?
    private var hi: Double?
    private var extreme = 0.0
    private var direction = 0
    private(set) var times: [Double] = []

    mutating func reset() { lo = nil; hi = nil; direction = 0; times.removeAll() }

    mutating func push(_ v: Double, t: Double, amplitude: Double, window: Double) {
        switch direction {
        case 0:
            lo = min(lo ?? v, v)
            hi = max(hi ?? v, v)
            if v - lo! >= amplitude { direction = 1; extreme = v }
            else if hi! - v >= amplitude { direction = -1; extreme = v }
        case 1:
            if v > extreme { extreme = v }
            else if extreme - v >= amplitude { times.append(t); direction = -1; extreme = v }
        default:
            if v < extreme { extreme = v }
            else if v - extreme >= amplitude { times.append(t); direction = 1; extreme = v }
        }
        while let f = times.first, t - f > window { times.removeFirst() }
    }

    var count: Int { times.count }
}

/// "Ryst kortet": kortets centrum eller et hjørne skal skifte retning mindst 4 gange inden for ca. 1 sek.
/// med et udsving på mindst ca. 6 % af kortets bredde, mens telefonen ligger stille.
/// Løft, vipning, drejning og roligt flyt giver ikke nok retningsskift. Højst én udløsning pr. 2 sek.
final class ShakeDetector {
    var sensitivity: ShakeSensitivity = .normal
    var window = 1.0
    var requiredReversals = 4
    var cooldown = 2.0
    /// Telefonen skal have ligget stille i hele vinduet + denne margen.
    var stillMargin = 0.3
    /// Huller i sporingen længere end dette nulstiller tællingen.
    var maxGap = 0.25

    private var center = (ReversalCounter(), ReversalCounter())
    private var corners = [ReversalCounter](repeating: ReversalCounter(), count: 8)
    private var lastSample: Double?
    private var hadCorners = false
    private var lastUnstill = -Double.infinity
    private var lastTrigger = -Double.infinity

    /// Live-måler til menuen: 0…1 (retningsskift / krævede).
    private(set) var meter = 0.0
    private(set) var reversals = 0

    func reset() {
        center.0.reset(); center.1.reset()
        for i in 0..<8 { corners[i].reset() }
        lastSample = nil
        hadCorners = false
        meter = 0
        reversals = 0
    }

    /// Returnerer true, når kortet rystes.
    func push(_ s: CardTrackSample) -> Bool {
        if let l = lastSample, s.t - l > maxGap { reset() }
        lastSample = s.t
        if !s.phoneStill {
            lastUnstill = s.t
            center.0.reset(); center.1.reset()
            for i in 0..<8 { corners[i].reset() }
            meter = 0
            reversals = 0
            return false
        }
        let amp = max(1e-6, sensitivity.amplitudeFraction * s.cardWidth)
        center.0.push(s.center.x, t: s.t, amplitude: amp, window: window)
        center.1.push(s.center.y, t: s.t, amplitude: amp, window: window)
        if let c = s.corners, c.count == 4 {
            if !hadCorners { for i in 0..<8 { corners[i].reset() } }
            for i in 0..<4 {
                corners[i * 2].push(c[i].x, t: s.t, amplitude: amp, window: window)
                corners[i * 2 + 1].push(c[i].y, t: s.t, amplitude: amp, window: window)
            }
            hadCorners = true
        } else if hadCorners {
            for i in 0..<8 { corners[i].reset() }
            hadCorners = false
        }
        let best = max(center.0.count, center.1.count, corners.map(\.count).max() ?? 0)
        reversals = best
        meter = min(1, Double(best) / Double(requiredReversals))
        let stillLongEnough = s.t - lastUnstill >= window + stillMargin
        guard best >= requiredReversals, stillLongEnough, s.t - lastTrigger >= cooldown else { return false }
        lastTrigger = s.t
        reset()
        return true
    }
}

/// Telefonens bevægelse (CoreMotion). Ren logik, så den kan testes.
enum MotionMath {
    /// Ligger telefonen stille? userAcceleration i g, rotationRate i rad/s.
    static func isStill(userAcceleration a: (Double, Double, Double), rotationRate r: (Double, Double, Double),
                        accelLimit: Double = 0.04, rotationLimit: Double = 0.2) -> Bool {
        let am = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
        let rm = (r.0 * r.0 + r.1 * r.1 + r.2 * r.2).squareRoot()
        return am < accelLimit && rm < rotationLimit
    }

    /// Hældning fra vandret (grader) ud fra tyngdekraften.
    static func tiltFromFlat(gravity g: (Double, Double, Double)) -> Double {
        let len = max(1e-9, (g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot())
        return acos(min(1, abs(g.2) / len)) * 180 / .pi
    }
}

/// Hvilken vej ikonerne skal vende (kameraets egne ikoner drejer med telefonen).
enum IconRotation: Equatable {
    case portrait, landscapeLeft, landscapeRight
    /// Grader til SwiftUI rotationEffect (positiv = med uret).
    var degrees: Double {
        switch self {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        }
    }
}

/// Orientering med hysterese. Når telefonen ligger fladt, beholdes den sidste.
struct OrientationTracker {
    private(set) var current: IconRotation = .portrait
    var threshold = 0.72

    /// gravity i telefonens akser (x højre, y op, z ud af skærmen). Returnerer true ved skift.
    mutating func update(gravity g: (Double, Double, Double)) -> Bool {
        let flat = abs(g.2) > 0.85
        guard !flat else { return false }
        var next = current
        if g.1 < -threshold { next = .portrait }
        else if g.0 < -threshold { next = .landscapeLeft }
        else if g.0 > threshold { next = .landscapeRight }
        guard next != current else { return false }
        current = next
        return true
    }
}

/// Vaterlinje: vises når telefonen ligger næsten vandret (med hysterese).
struct LevelIndicator {
    private(set) var visible = false
    var showBelow = 6.0
    var hideAbove = 8.0

    mutating func update(tiltDegrees: Double) -> Bool {
        let next = visible ? tiltDegrees < hideAbove : tiltDegrees < showBelow
        guard next != visible else { return false }
        visible = next
        return true
    }
}

/// "Ryst telefonen" (genskab): mindst 3 kraftige stød (> 1,3 g) inden for 1 sek.
struct PhoneShakeDetector {
    var threshold = 1.3
    var required = 3
    var window = 1.0
    var minSpacing = 0.08
    var cooldown = 1.5
    private var peaks: [Double] = []
    private var lastTrigger = -Double.infinity

    mutating func push(userAcceleration a: (Double, Double, Double), t: Double) -> Bool {
        let m = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
        if m > threshold, t - (peaks.last ?? -Double.infinity) >= minSpacing { peaks.append(t) }
        while let f = peaks.first, t - f > window { peaks.removeFirst() }
        guard peaks.count >= required, t - lastTrigger >= cooldown else { return false }
        lastTrigger = t
        peaks.removeAll()
        return true
    }
}
