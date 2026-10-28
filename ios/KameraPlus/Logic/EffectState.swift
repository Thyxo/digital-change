import Foundation

/// Hvad der kan starte afsløringen. Kan kombineres i menuen.
enum TriggerSource: String, CaseIterable, Identifiable, Codable {
    case tapCard       // tryk på kortet (standard)
    case shakeCard     // ryst kortet
    case tapAnywhere   // tryk hvor som helst i søgeren
    case volumeUp      // volumen op
    case hiddenZone    // skjult zone (sort felt til højre for lukkeren)
    case test          // testknap i menuen
    var id: String { rawValue }
}

/// Måder at genskabe forklædningen på. Hver har sin egen kontakt.
enum RestoreMethod: String, CaseIterable, Identifiable, Codable {
    case menuButton        // knap i menuen
    case hiddenZoneHold    // hold 1 sek. nederst til venstre
    case volumeDown        // volumen ned
    case phoneShake        // ryst telefonen
    case shutterDoubleTap  // dobbelttryk på lukkeren
    case autoNoCard        // automatisk når intet kort er set i x sek.
    case onLaunch          // altid forklædt, når appen åbnes
    var id: String { rawValue }
}

struct EffectConfig: Equatable {
    var triggers: Set<TriggerSource> = [.tapCard]
    var restores: Set<RestoreMethod> = [.menuButton, .hiddenZoneHold, .onLaunch]
    /// Sekunder uden kort før automatisk genskab (kun når `.autoNoCard` er slået til).
    var autoRestoreSeconds: Double = 5
}

enum EffectPhase: Equatable {
    case disguised
    case revealing(RevealPlan)
    case revealed

    var isDisguised: Bool { if case .disguised = self { return true } else { return false } }
}

enum EffectEvent: Equatable {
    case revealStarted(TriggerSource)
    case revealFinished
    case restored(RestoreMethod)
}

/// Forklædt → (tryk på kortet) → afslører → afsløret → (genskab) → forklædt.
/// Falder aldrig tilbage til forklædt af sig selv – kun via en genskab-metode, der er slået til.
final class EffectStateMachine {
    private(set) var phase: EffectPhase = .disguised
    /// Slås fra af panik. Fra = helt almindeligt kamera.
    var effectActive = true
    var config = EffectConfig()
    private(set) var lastCardSeen: Double?
    private(set) var cardVisible = false

    init(config: EffectConfig = EffectConfig(), effectActive: Bool = true) {
        self.config = config
        self.effectActive = effectActive
    }

    /// Skal forklædningen tegnes lige nu (helt eller delvist)?
    var disguiseShown: Bool {
        guard effectActive else { return false }
        if case .revealed = phase { return false }
        return true
    }

    var isRevealed: Bool { if case .revealed = phase { return true } else { return false } }

    /// Kaldes for hvert analyseret billede.
    func noteCard(visible: Bool, at t: Double) {
        cardVisible = visible
        if visible { lastCardSeen = t }
    }

    /// Kan denne kilde afsløre lige nu?
    func canTrigger(_ source: TriggerSource, hitCard: Bool) -> Bool {
        guard effectActive, phase.isDisguised, cardVisible else { return false }
        if source != .test && !config.triggers.contains(source) { return false }
        if source == .tapCard && !hitCard { return false }
        return true
    }

    @discardableResult
    func trigger(_ source: TriggerSource, hitCard: Bool, plan: RevealPlan) -> EffectEvent? {
        guard canTrigger(source, hitCard: hitCard) else { return nil }
        phase = plan.kind == .instant ? .revealed : .revealing(plan)
        return .revealStarted(source)
    }

    /// Fremdrift i tiden: afslutter overgangen og laver evt. automatisk genskab.
    func tick(now: Double) -> [EffectEvent] {
        var events: [EffectEvent] = []
        if case .revealing(let plan) = phase, plan.isComplete(at: now) {
            phase = .revealed
            events.append(.revealFinished)
        }
        if case .revealed = phase, config.restores.contains(.autoNoCard), !cardVisible {
            let since = lastCardSeen ?? -Double.infinity
            if now - since >= config.autoRestoreSeconds {
                phase = .disguised
                events.append(.restored(.autoNoCard))
            }
        }
        return events
    }

    /// Genskab. Returnerer true, når metoden er slået til (så der kan gives en diskret haptik).
    @discardableResult
    func restore(_ method: RestoreMethod) -> Bool {
        guard config.restores.contains(method) else { return false }
        phase = .disguised
        return true
    }

    /// Panik: effekten slukkes stille, og alt er bare kameraets egen farve.
    func panic() {
        effectActive = false
        phase = .disguised
    }

    /// Ved opstart: forklædt hvis "altid forklædt ved åbning" er slået til, ellers som sidst.
    func launch(wasRevealed: Bool) {
        if config.restores.contains(.onLaunch) || !wasRevealed {
            phase = .disguised
        } else {
            phase = .revealed
        }
    }
}

/// Lås eksponering og hvidbalance, når kortet er set stabilt i 5 billeder; frigør efter 1,5 sek. uden kort.
struct ExposureLockPolicy {
    var stableFrames = 5
    var releaseAfter = 1.5
    private(set) var locked = false
    private var seenInRow = 0
    private var lastSeen: Double?

    /// Returnerer den nye ønskede tilstand, når den skifter.
    mutating func update(cardVisible: Bool, at t: Double) -> Bool? {
        if cardVisible {
            seenInRow += 1
            lastSeen = t
            if !locked && seenInRow >= stableFrames {
                locked = true
                return true
            }
        } else {
            seenInRow = 0
            if locked, let s = lastSeen, t - s >= releaseAfter {
                locked = false
                return false
            }
        }
        return nil
    }

    mutating func reset() -> Bool? {
        seenInRow = 0
        lastSeen = nil
        if locked { locked = false; return false }
        return nil
    }
}
