import Foundation
import Combine

/// Hvilket fysisk kort vises som hvilket.
enum DisguiseMode: String, CaseIterable, Identifiable {
    case blueAsRed   // det blå kort vises som rødt (standard)
    case redAsBlue   // omvendt
    var id: String { rawValue }
    var label: String { self == .blueAsRed ? "Blå vises som rødt" : "Rød vises som blåt" }
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

    // Kalibrering
    @Published var redPalette: Palette? { didSet { save(redPalette, "redPalette") } }
    @Published var bluePalette: Palette? { didSet { save(bluePalette, "bluePalette") } }
    @Published var background: BackgroundModel? { didSet { save(background, "background") } }
    @Published var sensitivity: Double { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var geometry: Bool { didSet { d.set(geometry, forKey: "geometry") } }
    @Published var lockExposure: Bool { didSet { d.set(lockExposure, forKey: "lockExposure") } }
    @Published var showMask: Bool { didSet { d.set(showMask, forKey: "showMask") } }

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

    init() {
        d.register(defaults: [
            "effectActive": true, "disguise": DisguiseMode.blueAsRed.rawValue,
            "triggers": AppSettings.defaultTriggers.map(\.rawValue),
            "transition": TransitionKind.wave.rawValue, "duration": 0.5, "softness": 0.4,
            "shakeSensitivity": ShakeSensitivity.normal.rawValue,
            "restores": AppSettings.defaultRestores.map(\.rawValue), "autoRestoreSeconds": 5.0, "wasRevealed": false,
            "sensitivity": 0.5, "geometry": true, "lockExposure": true, "showMask": false,
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
        redPalette = AppSettings.load(d, "redPalette")
        bluePalette = AppSettings.load(d, "bluePalette")
        background = AppSettings.load(d, "background")
        sensitivity = min(1, max(0, d.double(forKey: "sensitivity")))
        geometry = d.bool(forKey: "geometry")
        lockExposure = d.bool(forKey: "lockExposure")
        showMask = d.bool(forKey: "showMask")
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

    private func save<T: Encodable>(_ v: T?, _ key: String) {
        if let v, let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) } else { d.removeObject(forKey: key) }
    }

    private static func load<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Hjælpere

    func has(_ t: TriggerSource) -> Bool { triggers.contains(t) }
    func set(_ t: TriggerSource, _ on: Bool) { if on { triggers.insert(t) } else { triggers.remove(t) } }
    func has(_ r: RestoreMethod) -> Bool { restores.contains(r) }
    func set(_ r: RestoreMethod, _ on: Bool) { if on { restores.insert(r) } else { restores.remove(r) } }

    var effectConfig: EffectConfig {
        EffectConfig(triggers: triggers, restores: restores, autoRestoreSeconds: autoRestoreSeconds)
    }

    /// Kilde (det kameraet ser) og mål (det publikum skal se), lærte eller standard.
    var sourcePalette: Palette {
        disguise == .blueAsRed ? (bluePalette ?? .defaultBlue) : (redPalette ?? .defaultRed)
    }
    var targetPalette: Palette {
        disguise == .blueAsRed ? (redPalette ?? .defaultRed) : (bluePalette ?? .defaultBlue)
    }

    /// Nulstil effekt og kalibrering til standard (kamera-realisme røres ikke).
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
        redPalette = nil
        bluePalette = nil
        background = nil
        sensitivity = 0.5
        geometry = true
        lockExposure = true
        showMask = false
    }
}
