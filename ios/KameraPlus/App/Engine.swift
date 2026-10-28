import AudioToolbox
import Combine
import QuartzCore
import SwiftUI
import UIKit

enum CaptureMode { case photo, video }

enum PanelStatus {
    case ready, off, noCard, revealed
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

struct FocusMark: Equatable {
    let id: Int
    let point: CGPoint
}

/// Live-tal til menuen (eget objekt, så kun den del af menuen tegnes om).
@MainActor
final class LiveReadout: ObservableObject {
    @Published var status: PanelStatus = .noCard
    @Published var fps = 0.0
    @Published var score = 0.0
    @Published var occluded = 0.0
    @Published var ms = 0.0
    @Published var preview: UIImage?
    @Published var shake = 0.0
}

/// Binder kamera, analyse, tilstandsmaskine, visning og knapper sammen (som Engine i MindTrace).
@MainActor
final class Engine: ObservableObject, PipelineDelegate {
    // Kameraets UI
    @Published private(set) var rotation: IconRotation = .portrait
    @Published private(set) var levelVisible = false
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var recording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var expanded = false
    @Published private(set) var isFront = true
    @Published private(set) var flipping = false
    @Published private(set) var flipAngle = 0.0
    @Published var flashOn = false
    @Published var nightOn = false
    @Published var liveOn = false
    @Published var moreOpen = false
    @Published private(set) var focus: FocusMark?
    @Published private(set) var blink = 0.0
    @Published private(set) var frontFlash = 0.0
    @Published private(set) var cameraDenied = false
    /// Hemmelig markør: prikken vises, indtil kortet er fundet og dækket (efter åbning).
    @Published private(set) var markerShown = false

    // Menu
    @Published var panelOpen = false { didSet { if panelOpen != oldValue { panelChanged() } } }
    @Published var galleryOpen = false { didSet { if galleryOpen != oldValue { galleryChanged() } } }
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var selfTestLines: [String] = []
    @Published private(set) var selfTestProgress: Double?
    let readout = LiveReadout()

    let settings: AppSettings
    let pipeline: Pipeline
    let renderer: Renderer
    let store = PhotoStore()
    let haptics = Haptics()
    let volume = VolumeButtons()
    let state = EffectStateMachine()
    private let motion = MotionManager()
    private var camera: CameraSource?
    private let synthetic = SyntheticSource()
    private var source: FrameSource?
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var wasInBackground = false
    private var cardVisible = false
    private var lastReadout = 0.0
    private var lastShutterTap = Date.distantPast
    private var recordTimer: Timer?
    private var focusCounter = 0
    /// De ægte Rider Back-skabeloner (ios/Cards i app-bundtet).
    let templates: CardTemplates?
    private var sourceColor: CardColor?
    private var warmup = WarmupGate()

    init(settings: AppSettings) {
        self.settings = settings
        let p = Pipeline()
        pipeline = p
        renderer = Renderer(mailbox: p.mailbox)
        let dir = Bundle.main.url(forResource: "Cards", withExtension: nil)
        templates = dir.flatMap { try? CardTemplates.load(directory: $0) }
        if let dir { renderer.loadCards(directory: dir) }
        renderer.geometry = templates?.blue.geometry
        state.config = settings.effectConfig
        state.effectActive = settings.effectActive
        state.launch(wasRevealed: settings.wasRevealed)
        pipeline.delegate = self
        motion.state = pipeline.motion
        motion.onRotation = { [weak self] r in
            withAnimation(.easeInOut(duration: 0.3)) { self?.rotation = r }
        }
        motion.onLevel = { [weak self] v in self?.levelVisible = v }
        motion.onPhoneShake = { [weak self] in self?.restore(.phoneShake) }
        volume.onUp = { [weak self] in self?.volumeUp() }
        volume.onDown = { [weak self] in self?.volumeDown() }
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &bag)
        settingsChanged()
    }

    // MARK: Start og livscyklus

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        motion.start()
        volume.activate()
        chooseSource()
        beginWarmup()
    }

    func scenePhase(_ p: ScenePhase) {
        switch p {
        case .active:
            guard started else { return }
            // "Altid forklædt, når appen åbnes" – kun efter baggrund (ikke kontrolcenter/notifikationer)
            if wasInBackground && settings.has(.onLaunch) && state.restore(.onLaunch) { updateRenderEffect() }
            if wasInBackground { beginWarmup() }
            wasInBackground = false
            volume.activate()
            motion.start()
            if !galleryOpen { source?.start() }
        case .background:
            wasInBackground = true
            if recording { stopRecording() }
            source?.stop()
            motion.stop()
        default:
            break
        }
    }

    private var useSynthetic: Bool { settings.testVideo || !CameraSource.hasCamera }

    private func chooseSource() {
        source?.stop()
        pipeline.mailbox.clear()
        pipeline.resetTracking()
        if useSynthetic {
            synthetic.template = templates?.of(settings.disguise.source)
            synthetic.sink = pipeline
            source = synthetic
            pipeline.camera = nil
            isFront = true
            synthetic.start()
        } else {
            let cam = camera ?? CameraSource()
            camera = cam
            cam.sink = pipeline
            pipeline.camera = cam
            source = cam
            isFront = cam.isFront
            CameraSource.requestAccess { [weak self] ok in
                guard let self else { return }
                self.cameraDenied = !ok
                if ok, self.source === cam { cam.start() }
            }
        }
        applyRender()
        updatePipelineConfig()
        updateRenderEffect()
    }

    // MARK: Indstillinger → motor

    private func settingsChanged() {
        state.config = settings.effectConfig
        if state.effectActive != settings.effectActive {
            state.effectActive = settings.effectActive
            if !settings.effectActive { state.panic() }
        }
        applyRender()
        updatePipelineConfig()
        updateRenderEffect()
        applyCards()
        if !settings.warmupBlur { handleWarmup(warmup.cancel()) } else { updateMarker() }
        if started {
            let wantSynthetic = useSynthetic
            if wantSynthetic != (source === synthetic) { chooseSource() }
        }
    }

    private func applyRender() {
        renderer.mirror = settings.mirrorViewfinder && isFront
        renderer.mirrorSaved = settings.mirrorSaved && isFront
        renderer.zoom = zoomFactor
        renderer.showMask = settings.showMask
        renderer.targetColor = settings.disguise.target
        renderer.lodBias = Float(-0.25 + 2.25 * settings.blur)
        renderer.grain = Float(settings.grain)
    }

    /// Kortet kameraet ser (kilde) til sporingen, målkortet til visningen.
    private func applyCards() {
        let src = settings.disguise.source
        guard src != sourceColor, let t = templates?.of(src) else { return }
        sourceColor = src
        pipeline.setSource(t)
        synthetic.template = t
        pipeline.resetTracking()
    }

    /// Frontkameraet viser som standard et beskåret udsnit (som iPhone: 1×), "udvid" viser hele billedet (0,8×).
    var zoomFactor: Double { isFront && !expanded ? 1.25 : 1.0 }

    private func updatePipelineConfig() {
        pipeline.setConfig(PipelineConfig(
            analyze: isFront && (settings.effectActive || panelOpen),
            lockExposure: settings.lockExposure && settings.effectActive,
            shake: settings.has(.shakeCard),
            shakeSensitivity: settings.shakeSensitivity,
            occlusionSensitivity: settings.occlusionSensitivity,
            wantPreview: panelOpen,
            searchArea: settings.searchArea,
            zoom: zoomFactor))
    }

    // MARK: Sløret opstart

    /// Søgeren sløres, indtil kortet er fundet og dækket (højst `warmupMax` sek. fra første billede).
    /// Kun når forklædningen skal tegnes – ellers er det bare et almindeligt kamera.
    private func beginWarmup() {
        guard settings.warmupBlur, settings.effectActive, isFront, state.phase.isDisguised else {
            handleWarmup(warmup.cancel())
            return
        }
        warmup.maxSeconds = settings.warmupMax
        warmup.begin()
        // et kort, der kun "holdes" fra før baggrunden, må ikke tælle som fundet
        pipeline.resetTracking()
        renderer.setWarmBlur(true)
        updateMarker()
    }

    private func handleWarmup(_ events: [WarmupEvent]) {
        for e in events {
            switch e {
            case .unblur: renderer.setWarmBlur(false)
            case .locked: if settings.lockMarker == .haptic { haptics.select() }
            }
        }
        updateMarker()
    }

    private func updateMarker() {
        let dot = settings.lockMarker == .moreDot || settings.lockMarker == .liveDot
        let shown = dot && warmup.markerShown
        if markerShown != shown { withAnimation(.easeOut(duration: 0.12)) { markerShown = shown } }
    }

    /// Hvad visningen skal tegne lige nu.
    private func updateRenderEffect() {
        var e = EffectRenderState()
        if state.effectActive && isFront {
            switch state.phase {
            case .disguised: e.disguise = true
            case .revealing(let plan): e.plan = plan
            case .revealed: break
            }
        }
        if renderer.effect != e { renderer.effect = e }
        let revealed = !state.phase.isDisguised
        if settings.wasRevealed != revealed { settings.wasRevealed = revealed }
    }

    // MARK: PipelineDelegate

    func pipelineDidAnalyze(_ s: PipelineSummary) {
        cardVisible = s.cardVisible
        state.noteCard(visible: s.cardVisible, at: s.time)
        if settings.effectActive && isFront {
            handleWarmup(warmup.update(covered: s.cardFresh && renderer.effect.disguise, at: s.time))
        } else {
            handleWarmup(warmup.cancel())
        }
        for e in state.tick(now: CACurrentMediaTime()) {
            if case .restored(let m) = e {
                haptics.restored()
                addLog("Genskab: \(restoreName(m))")
            }
        }
        updateRenderEffect()
        if panelOpen && s.time - lastReadout >= 0.2 {
            lastReadout = s.time
            readout.fps = s.fps
            readout.score = s.score * 100
            readout.occluded = s.occluded * 100
            readout.ms = s.ms
            readout.shake = s.shake
            let st: PanelStatus
            if !settings.effectActive { st = .off }
            else if !state.phase.isDisguised { st = .revealed }
            else if s.cardVisible { st = .ready }
            else { st = .noCard }
            readout.status = st
        }
    }

    func pipelineDidShake() {
        if trigger(.shakeCard, hitCard: true, at: nil) { addLog("Ryst kortet · afsløret (\(transitionName))") }
    }

    func pipelineDidPreview(_ preview: CGImage) {
        guard panelOpen else { return }
        readout.preview = UIImage(cgImage: preview)
    }

    // MARK: Afsløring

    @discardableResult
    func trigger(_ src: TriggerSource, hitCard: Bool, at point: Point2?) -> Bool {
        guard isFront, let f = pipeline.mailbox.latest else { return false }
        let center = point ?? f.centroid ?? Point2(Double(f.frameWidth) / 2, Double(f.frameHeight) / 2)
        let soft = (4 + 56 * settings.softness) * Double(f.frameWidth) / 1080
        let plan = RevealPlan.make(kind: settings.transition, center: center, cardBounds: f.bounds,
                                   frameWidth: Double(f.frameWidth), frameHeight: Double(f.frameHeight),
                                   duration: settings.duration, softness: soft, start: CACurrentMediaTime())
        guard state.trigger(src, hitCard: hitCard, plan: plan) != nil else { return false }
        updateRenderEffect()
        return true
    }

    /// Testknap i menuen: afslør (også uden kort) og genskab efter 2 sek.
    func testReveal() {
        state.noteCard(visible: true, at: CACurrentMediaTime())
        if trigger(.test, hitCard: true, at: nil) {
            addLog("Test: afsløring")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    _ = self.state.restore(.menuButton) || self.forceDisguise()
                    self.updateRenderEffect()
                }
            }
        }
    }

    private func forceDisguise() -> Bool {
        let restores = state.config.restores
        state.config.restores.insert(.menuButton)
        let ok = state.restore(.menuButton)
        state.config.restores = restores
        return ok
    }

    func restore(_ m: RestoreMethod) {
        if m == .menuButton {
            guard forceDisguise() else { return }
        } else {
            guard state.restore(m) else { return }
        }
        haptics.restored()
        updateRenderEffect()
        addLog("Genskab: \(restoreName(m))")
    }

    func panic() {
        state.panic()
        settings.effectActive = false
        updateRenderEffect()
        addLog("PANIK – effekten er slået fra")
    }

    var transitionName: String { Engine.name(settings.transition) }

    static func name(_ t: TransitionKind) -> String {
        switch t {
        case .wave: return "bølge"
        case .instant: return "øjeblikkeligt"
        case .fade: return "fade"
        case .sweep: return "fej oppefra"
        }
    }

    func restoreName(_ m: RestoreMethod) -> String {
        switch m {
        case .menuButton: return "knap i menuen"
        case .hiddenZoneHold: return "skjult zone"
        case .volumeDown: return "volumen ned"
        case .phoneShake: return "ryst telefonen"
        case .shutterDoubleTap: return "dobbelttryk på lukker"
        case .autoNoCard: return "intet kort set"
        case .onLaunch: return "appen åbnet"
        }
    }

    // MARK: Tryk i søgeren

    func viewfinderTap(_ p: CGPoint, size: CGSize) {
        guard !flipping else { return }
        if moreOpen { moreOpen = false }
        var hit = false
        var framePoint: Point2?
        if let f = pipeline.mailbox.latest {
            let map = ViewMapping(viewWidth: size.width, viewHeight: size.height, frameWidth: Double(f.frameWidth),
                                  frameHeight: Double(f.frameHeight), zoom: zoomFactor, mirrored: renderer.mirror)
            let fp = map.framePoint(fromView: Point2(p.x, p.y))
            framePoint = fp
            // ramt = fingeren er på kortet (med lidt margen: et tryk lige på kanten tæller)
            if let card = f.card, let g = templates?.blue.geometry, let inv = card.homography.inverse {
                let q = inv.apply(fp)
                hit = g.cardDistance(q) < 0.04 * g.width
            }
            camera?.focus(at: CGPoint(x: fp.x / Double(f.frameWidth), y: fp.y / Double(f.frameHeight)))
        }
        if settings.focusSquare {
            focusCounter += 1
            focus = FocusMark(id: focusCounter, point: p)
        }
        var triggered = false
        if hit { triggered = trigger(.tapCard, hitCard: true, at: framePoint) }
        if !triggered && settings.has(.tapAnywhere) { triggered = trigger(.tapAnywhere, hitCard: hit, at: framePoint) }
        let shown = triggered ? "afsløret (\(transitionName))" : (state.isRevealed ? "allerede afsløret" : "kun fokus")
        addLog("Tryk · \(hit ? "ramte kortet" : "ved siden af") · \(shown)")
    }

    func hiddenZoneTap() {
        if trigger(.hiddenZone, hitCard: false, at: nil) { addLog("Skjult zone · afsløret (\(transitionName))") }
    }

    func restoreZoneHold() { restore(.hiddenZoneHold) }

    private func volumeUp() {
        guard !panelOpen else { return }
        if settings.has(.volumeUp) {
            if trigger(.volumeUp, hitCard: false, at: nil) { addLog("Volumen op · afsløret (\(transitionName))") }
        } else {
            shutterTap()
        }
    }

    private func volumeDown() {
        guard !panelOpen else { return }
        if settings.has(.volumeDown) { restore(.volumeDown) } else { shutterTap() }
    }

    // MARK: Kamera-knapper

    func setMode(_ m: CaptureMode) {
        guard m != mode, !recording else { return }
        haptics.select()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { mode = m }
    }

    func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
        renderer.zoom = zoomFactor
        updatePipelineConfig()
    }

    func flipCamera() {
        guard !flipping, !recording else { return }
        flipping = true
        haptics.select()
        withAnimation(.easeInOut(duration: 0.4)) { flipAngle = 180 }
        let finish = { [weak self] in
            guard let self else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.flipAngle = 0 }
            self.applyRender()
            self.updatePipelineConfig()
            self.updateRenderEffect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { [weak self] in self?.flipping = false }
            }
        }
        if let cam = camera, source === cam {
            pipeline.resetTracking()
            cam.setFront(!cam.isFront) { [weak self] in
                self?.isFront = cam.isFront
                finish()
                self?.beginWarmup()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { finish() } }
        }
    }

    func shutterTap() {
        let now = Date()
        if now.timeIntervalSince(lastShutterTap) < 0.35 && settings.has(.shutterDoubleTap) { restore(.shutterDoubleTap) }
        lastShutterTap = now
        if mode == .video { toggleRecording() } else { takePhoto() }
    }

    private var photoOrientation: UIImage.Orientation {
        switch rotation {
        case .portrait: return .up
        case .landscapeLeft: return .left
        case .landscapeRight: return .right
        }
    }

    private func takePhoto() {
        haptics.shutter()
        if settings.shutterSound { AudioServicesPlaySystemSound(1108) }
        let image = renderer.capturePhoto()
        if settings.shutterBlink {
            blink = 1
            withAnimation(.easeOut(duration: 0.18)) { blink = 0 }
        }
        if flashOn && isFront {
            frontFlash = 1
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) { frontFlash = 0 }
        }
        if let image { store.savePhoto(image, orientation: photoOrientation, toPhotos: settings.saveToPhotos) }
    }

    private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard let size = renderer.outputSize(),
              let rec = VideoRecorder(url: store.newVideoURL(), width: size.0, height: size.1) else { return }
        AudioServicesPlaySystemSound(1117)
        renderer.recorder = rec
        recording = true
        recordingSeconds = 0
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordingSeconds += 1 }
        }
    }

    private func stopRecording() {
        guard let rec = renderer.recorder else { return }
        renderer.recorder = nil
        recording = false
        recordTimer?.invalidate()
        recordTimer = nil
        AudioServicesPlaySystemSound(1118)
        let toPhotos = settings.saveToPhotos
        rec.finish { [weak self] url in
            guard let url else { return }
            self?.store.addVideo(url, toPhotos: toPhotos)
        }
    }

    // MARK: Menu og galleri

    private func panelChanged() {
        renderer.paused = panelOpen || galleryOpen
        if panelOpen { readout.preview = nil }
        updatePipelineConfig()
    }

    private func galleryChanged() {
        renderer.paused = panelOpen || galleryOpen
        if galleryOpen { source?.stop() } else { source?.start() }
    }

    // MARK: Selvtest

    func runSelfTest() {
        guard selfTestProgress == nil, let templates else { return }
        selfTestProgress = 0
        selfTestLines = []
        let source = settings.disguise.source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = SelfTest.run(templates: templates, source: source, count: 300, seed: 2026) { p in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.selfTestProgress = p } }
            }
            let lines = r.lines
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.selfTestLines = lines
                    self?.selfTestProgress = nil
                }
            }
        }
    }

    func addLog(_ s: String) {
        log.insert(LogEntry(time: Date(), text: s), at: 0)
        if log.count > 20 { log.removeLast(log.count - 20) }
    }
}
