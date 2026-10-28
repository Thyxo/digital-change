import Foundation

/// Hvor kortet ledes efter første gang, målt i søgerens 3×3-gitter. Følges kortet, må det bevæge sig frit.
enum SearchArea: String, CaseIterable, Identifiable, Codable {
    case middle         // kun midterfeltet
    case aroundMiddle   // midterfeltet + en tredjedel felt hele vejen rundt (standard)
    case whole          // hele billedet
    var id: String { rawValue }

    /// Området for kortets centrum i søgeren (0…1). nil = hele billedet.
    var viewRegion: RectD? {
        switch self {
        case .middle: return RectD(minX: 1.0 / 3, minY: 1.0 / 3, maxX: 2.0 / 3, maxY: 2.0 / 3)
        case .aroundMiddle: return RectD(minX: 2.0 / 9, minY: 2.0 / 9, maxX: 7.0 / 9, maxY: 7.0 / 9)
        case .whole: return nil
        }
    }

    /// Samme område i kamerabilledets pixels (søgeren er 3:4 og viser billedet "aspect fill" med `zoom`).
    func frameRegion(frameWidth: Double, frameHeight: Double, zoom: Double) -> RectD? {
        guard let r = viewRegion else { return nil }
        let map = ViewMapping(viewWidth: 3, viewHeight: 4, frameWidth: frameWidth, frameHeight: frameHeight,
                              zoom: zoom, mirrored: false)
        let a = map.framePoint(fromView: Point2(r.minX * 3, r.minY * 4))
        let b = map.framePoint(fromView: Point2(r.maxX * 3, r.maxY * 4))
        return RectD(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }
}

/// Hemmelig markør, der viser dig, at kortet er fundet og dækket.
enum LockMarker: String, CaseIterable, Identifiable, Codable {
    case moreDot   // lille prik ved "mere"-ikonet øverst til højre forsvinder
    case liveDot   // lille prik ved Live-ikonet forsvinder
    case haptic    // et svagt tik
    case none
    var id: String { rawValue }
}

enum WarmupEvent: Equatable {
    /// Kortet er fundet og dækket (markøren slukkes).
    case locked
    /// Sløringen fjernes.
    case unblur
}

/// Sløret opstart: søgeren er sløret, indtil kortet er fundet og dækket i et par billeder i træk, dog mindst
/// `minSeconds` (som iPhonens egen opstart) og højst `maxSeconds` (så det aldrig ser mistænkeligt ud).
/// Tiden tælles fra første kamerabillede. Findes kortet først efter sløringen, slukkes markøren stadig.
struct WarmupGate: Equatable {
    var minSeconds = 0.25
    var maxSeconds = 1.5
    var lockFrames = 2
    private(set) var blurred = false
    /// Kortet er fundet og dækket siden start.
    private(set) var locked = true
    private var running = false
    private var startedAt: Double?
    private var inRow = 0

    /// Markøren vises, indtil kortet er fundet.
    var markerShown: Bool { running && !locked }

    mutating func begin() {
        blurred = true; locked = false; running = true; startedAt = nil; inRow = 0
    }

    /// Stop uden at vente (fx effekten slået fra). Returnerer de hændelser, der mangler.
    mutating func cancel() -> [WarmupEvent] {
        guard running else { return [] }
        var ev: [WarmupEvent] = []
        if !locked { locked = true; ev.append(.locked) }
        if blurred { blurred = false; ev.append(.unblur) }
        running = false
        return ev
    }

    /// Kaldes for hvert kamerabillede. `covered`: kortet er fundet, og forklædningen tegnes over det.
    mutating func update(covered: Bool, at t: Double) -> [WarmupEvent] {
        guard running else { return [] }
        let start = startedAt ?? t
        startedAt = start
        var ev: [WarmupEvent] = []
        inRow = covered ? inRow + 1 : 0
        if !locked && inRow >= lockFrames { locked = true; ev.append(.locked) }
        let elapsed = t - start
        if blurred && elapsed >= minSeconds && (locked || elapsed >= maxSeconds) { blurred = false; ev.append(.unblur) }
        if !blurred && locked { running = false }
        return ev
    }
}
