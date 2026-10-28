import Foundation
import Combine

/// Hvilket fysisk kort vises som hvilket.
enum DisguiseMode: String, CaseIterable, Identifiable {
    case blueAsRed   // det blå kort vises som rødt (standard)
    case redAsBlue   // omvendt
    var id: String { rawValue }
    var label: String { self == .blueAsRed ? "Blå vises som rødt" : "Rød vises som blåt" }
    /// Kortet kameraet ser.
    var source: CardColor { self == .blueAsRed ? .blue : .red }
    /// Kortet publikum ser.
    var target: CardColor { source.other }
}

/// Alle indstillinger gemmes lokalt i UserDefaults (som AppSettings i MindTrace).
/// Startargumenter (fx "-effectActive NO") overskriver, hvilket UI-testene bruger.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    // Effekt
    @Published var effectActive: Bool { didSet { d.set(effectActive, forKey: "effectActive") } }
    @Published var disguise: DisguiseMode { didSet { d.set(disguise.rawValue, forKey: "disguise") } }
    @Published var triggers: Set<TriggerSource> { didSet { d.set(triggers.map(\.rawValue), forKey: "triggers") } }
    @Published var transition: TransitionKind { didSet { d.set(transition.rawValue, forKey: "transition") } }
    @Published var duration: Double { didSet { d.set(duration, forKey: "duration") } }
    /// Kantblødhed 0…1 (omregnes til pixels efter billedets bredde).
    @Published var softness: Double { didSet { d.set(softness, forKey: "softness") } }
    @Published var shakeSensitivity: ShakeSensitivity { didSet { d.set(shakeSensitivity.rawValue, forKey: "shakeSensitivity") } }

    // Genskab forklædning
    @Published var restores: Set<RestoreMethod> { didSet { d.set(restores.map(\.rawValue), forKey: "restores") } }
    @Published var autoRestoreSeconds: Double { didSet { d.set(autoRestoreSeconds, forKey: "autoRestoreSeconds") } }
    @Published var wasRevealed: Bool { didSet { d.set(wasRevealed, forKey: "wasRevealed") } }

    // Kort og sporing
    /// 0…1: højere = flere pixels regnes for fingre over kortet.
    @Published var occlusionSensitivity: Double { didSet { d.set(occlusionSensitivity, forKey: "occlusionSensitivity") } }
    /// 0…1: uskarphed på målkortet (så det passer til kameraets skarphed).
    @Published var blur: Double { didSet { d.set(blur, forKey: "blur") } }
    /// 0…1: korn på målkortet (kameraets støj).
    @Published var grain: Double { didSet { d.set(grain, forKey: "grain") } }
    @Published var lockExposure: Bool { didSet { d.set(lockExposure, forKey: "lockExposure") } }
    @Published var showMask: Bool { didSet { d.set(showMask, forKey: "showMask") } }
    /// Hvor kortet ledes efter første gang (i søgerens gitter).
    @Published var searchArea: SearchArea { didSet { d.set(searchArea.rawValue, forKey: "searchArea") } }

    // Sløret opstart
    /// Søgeren er sløret ved åbning, indtil kortet er fundet og dækket (højst `warmupMax` sek.).
    @Published var warmupBlur: Bool { didSet { d.set(warmupBlur, forKey: "warmupBlur") } }
    @Published var warmupMax: Double { didSet { d.set(warmupMax, forKey: "warmupMax") } }
    @Published var lockMarker: LockMarker { didSet { d.set(lockMarker.rawValue, forKey: "lockMarker") } }

    // Kamera-realisme
    @Published var grid: Bool { didSet { d.set(grid, forKey: "grid") } }
    @Published var level: Bool { didSet { d.set(level, forKey: "level") } }
    @Published var mirrorViewfinder: Bool { didSet { d.set(mirrorViewfinder, forKey: "mirrorViewfinder") } }
    @Published var mirrorSaved: Bool { didSet { d.set(mirrorSaved, forKey: "mirrorSaved") } }
    @Published var focusSquare: Bool { didSet { d.set(focusSquare, forKey: "focusSquare") } }
    @Published var shutterSound: Bool { didSet { d.set(shutterSound, forKey: "shutterSound") } }
    @Published var shutterBlink: Bool { didSet { d.set(shutterBlink, forKey: "shutterBlink") } }
    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: "saveToPhotos") } }
    @Published var testVideo: Bool { didSet { d.set(testVideo, forKey: "testVideo") } }

    static let defaultTriggers: Set<TriggerSource> = [.tapCard]
    static let defaultRestores: Set<RestoreMethod> = [.menuButton, .hiddenZoneHold, .onLaunch]
    static let warmupChoices: [Double] = [1, 1.5, 2, 3]

    init() {
        d.register(defaults: [
            "effectActive": true, "disguise": DisguiseMode.blueAsRed.rawValue,
            "triggers": AppSettings.defaultTriggers.map(\.rawValue),
            "transition": TransitionKind.wave.rawValue, "duration": 0.5, "softness": 0.4,
            "shakeSensitivity": ShakeSensitivity.normal.rawValue,
            "restores": AppSettings.defaultRestores.map(\.rawValue), "autoRestoreSeconds": 5.0, "wasRevealed": false,
            "occlusionSensitivity": 0.5, "blur": 0.35, "grain": 0.35, "lockExposure": true, "showMask": false,
            "searchArea": SearchArea.aroundMiddle.rawValue, "warmupBlur": true, "warmupMax": 1.5,
            "lockMarker": LockMarker.moreDot.rawValue,
            "grid": true, "level": true, "mirrorViewfinder": true, "mirrorSaved": false, "focusSquare": true,
            "shutterSound": true, "shutterBlink": true, "saveToPhotos": false, "testVideo": false,
        ])
        effectActive = d.bool(forKey: "effectActive")
        disguise = DisguiseMode(rawValue: d.string(forKey: "disguise") ?? "") ?? .blueAsRed
        triggers = Set((d.stringArray(forKey: "triggers") ?? []).compactMap(TriggerSource.init(rawValue:)))
        transition = TransitionKind(rawValue: d.string(forKey: "transition") ?? "") ?? .wave
        duration = min(1.5, max(0.15, d.double(forKey: "duration")))
        softness = min(1, max(0, d.double(forKey: "softness")))
        shakeSensitivity = ShakeSensitivity(rawValue: d.string(forKey: "shakeSensitivity") ?? "") ?? .normal
        restores = Set((d.stringArray(forKey: "restores") ?? []).compactMap(RestoreMethod.init(rawValue:)))
        autoRestoreSeconds = [3.0, 5.0, 10.0].contains(d.double(forKey: "autoRestoreSeconds")) ? d.double(forKey: "autoRestoreSeconds") : 5
        wasRevealed = d.bool(forKey: "wasRevealed")
        occlusionSensitivity = min(1, max(0, d.double(forKey: "occlusionSensitivity")))
        blur = min(1, max(0, d.double(forKey: "blur")))
        grain = min(1, max(0, d.double(forKey: "grain")))
        lockExposure = d.bool(forKey: "lockExposure")
        showMask = d.bool(forKey: "showMask")
        searchArea = SearchArea(rawValue: d.string(forKey: "searchArea") ?? "") ?? .aroundMiddle
        warmupBlur = d.bool(forKey: "warmupBlur")
        warmupMax = AppSettings.warmupChoices.contains(d.double(forKey: "warmupMax")) ? d.double(forKey: "warmupMax") : 1.5
        lockMarker = LockMarker(rawValue: d.string(forKey: "lockMarker") ?? "") ?? .moreDot
        grid = d.bool(forKey: "grid")
        level = d.bool(forKey: "level")
        mirrorViewfinder = d.bool(forKey: "mirrorViewfinder")
        mirrorSaved = d.bool(forKey: "mirrorSaved")
        focusSquare = d.bool(forKey: "focusSquare")
        shutterSound = d.bool(forKey: "shutterSound")
        shutterBlink = d.bool(forKey: "shutterBlink")
        saveToPhotos = d.bool(forKey: "saveToPhotos")
        testVideo = d.bool(forKey: "testVideo")
    }

    // MARK: Hjælpere

    func has(_ t: TriggerSource) -> Bool { triggers.contains(t) }
    func set(_ t: TriggerSource, _ on: Bool) { if on { triggers.insert(t) } else { triggers.remove(t) } }
    func has(_ r: RestoreMethod) -> Bool { restores.contains(r) }
    func set(_ r: RestoreMethod, _ on: Bool) { if on { restores.insert(r) } else { restores.remove(r) } }

    var effectConfig: EffectConfig {
        EffectConfig(triggers: triggers, restores: restores, autoRestoreSeconds: autoRestoreSeconds)
    }

    /// Nulstil effekt og sporing til standard (kamera-realisme røres ikke).
    func resetToDefaults() {
        effectActive = true
        disguise = .blueAsRed
        triggers = AppSettings.defaultTriggers
        transition = .wave
        duration = 0.5
        softness = 0.4
        shakeSensitivity = .normal
        restores = AppSettings.defaultRestores
        autoRestoreSeconds = 5
        occlusionSensitivity = 0.5
        blur = 0.35
        grain = 0.35
        lockExposure = true
        showMask = false
        searchArea = .aroundMiddle
        warmupBlur = true
        warmupMax = 1.5
        lockMarker = .moreDot
    }
}
