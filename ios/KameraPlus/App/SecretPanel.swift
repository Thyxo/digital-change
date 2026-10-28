import SwiftUI

/// Hemmelig menu (5 hurtige tryk øverst til venstre). "Færdig" ignoreres det første sekund.
/// Live-delen ligger i `LiveStatus`, så kun den tegnes om – resten kun når du ændrer noget.
struct SecretPanel: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var s: AppSettings
    @State private var openedAt = Date()
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                effectSection
                restoreSection
                calibrationSection
                realismSection
                logSection
                Section {
                    Button(role: .destructive) { engine.panic() } label: {
                        Text("PANIK").font(.headline).frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.red.opacity(0.85))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("panicButton")
                } footer: {
                    Text("Menu: 5 hurtige tryk øverst til venstre. Panik: hold fingeren øverst til venstre i 1 sek. – effekten slås stille fra, og appen er et almindeligt kamera. Tænd igen med Effekt aktiv.")
                }
            }
            .navigationTitle("KameraPlus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Færdig") {
                        // Første sekund ignoreres, så et ekstra hemmeligt tryk ikke lukker menuen.
                        if Date().timeIntervalSince(openedAt) > 1 { engine.panelOpen = false }
                    }
                    .accessibilityIdentifier("doneButton")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { openedAt = Date() }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LiveStatus(readout: engine.readout)
            Toggle("Effekt aktiv", isOn: $s.effectActive)
                .accessibilityIdentifier("effectToggle")
            if s.has(.menuButton) {
                Button("Genskab forklædning nu") { engine.restore(.menuButton) }
            }
        }
    }

    // MARK: Effekt

    private var effectSection: some View {
        Section {
            Picker("Forklædning", selection: $s.disguise) {
                ForEach(DisguiseMode.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger (kan kombineres)").font(.subheadline)
                triggerToggle(.tapCard, "Tryk på kortet")
                triggerToggle(.shakeCard, "Ryst kortet")
                triggerToggle(.tapAnywhere, "Tryk hvor som helst")
                triggerToggle(.volumeUp, "Volumen op")
                triggerToggle(.hiddenZone, "Skjult zone (sort felt højre for lukkeren)")
            }
            if s.has(.shakeCard) {
                Picker("Ryst-følsomhed", selection: $s.shakeSensitivity) {
                    Text("Let").tag(ShakeSensitivity.light)
                    Text("Normal").tag(ShakeSensitivity.normal)
                    Text("Hård").tag(ShakeSensitivity.hard)
                }
                .pickerStyle(.segmented)
                ShakeMeter(readout: engine.readout)
            }
            Picker("Overgang", selection: $s.transition) {
                Text("Bølge fra fingeren").tag(TransitionKind.wave)
                Text("Øjeblikkeligt").tag(TransitionKind.instant)
                Text("Fade").tag(TransitionKind.fade)
                Text("Fej oppefra").tag(TransitionKind.sweep)
            }
            if s.transition != .instant {
                slider("Varighed", value: $s.duration, range: 0.15...1.5, text: String(format: "%.2f s", s.duration))
            }
            slider("Kantblødhed", value: $s.softness, range: 0...1, text: "\(Int(s.softness * 100)) %")
            Button("Test afsløring") { engine.testReveal() }
        } header: { Text("Effekt") } footer: {
            Text("Blå vises som rødt: det blå kort, kameraet ser, vises som et rødt kort. Et tryk på kortet (mindst 30 % af området under fingeren er kort) slukker forklædningen med den valgte overgang. Tryk ved siden af giver kun fokusfirkant.")
        }
    }

    private func triggerToggle(_ t: TriggerSource, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { s.has(t) }, set: { s.set(t, $0) }))
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: Genskab

    private var restoreSection: some View {
        Section {
            restoreToggle(.menuButton, "Knap i menuen")
            restoreToggle(.hiddenZoneHold, "Skjult zone nederst til venstre (hold 1 sek.)")
            restoreToggle(.volumeDown, "Volumen ned")
            restoreToggle(.phoneShake, "Ryst telefonen")
            restoreToggle(.shutterDoubleTap, "Dobbelttryk på lukkerknappen")
            restoreToggle(.autoNoCard, "Automatisk når intet kort er set")
            if s.has(.autoNoCard) {
                Picker("Efter", selection: $s.autoRestoreSeconds) {
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
                .pickerStyle(.segmented)
            }
            restoreToggle(.onLaunch, "Altid forklædt, når appen åbnes")
        } header: { Text("Genskab forklædning") } footer: {
            Text("Efter afsløring er alt kameraets egen farve, indtil forklædningen genskabes. Den falder aldrig tilbage af sig selv, mens du håndterer kortet (automatisk genskab er derfor slået fra som standard). Genskab giver en lille diskret vibration.")
        }
    }

    private func restoreToggle(_ m: RestoreMethod, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { s.has(m) }, set: { s.set(m, $0) }))
    }

    // MARK: Kalibrering

    private var calibrationSection: some View {
        Section {
            Text("1. Lær rødt kort: hold et kort fra det røde spil 2–5 cm over kameraet i 3 sek.\n2. Lær blåt kort: samme med det blå kort.\n3. Lær baggrund: vis hånden og rummet uden kort i 3 sek.")
                .font(.footnote)
            learnButton(.red, "Lær rødt kort", done: s.redPalette != nil)
            learnButton(.blue, "Lær blåt kort", done: s.bluePalette != nil)
            learnButton(.background, "Lær baggrund (uden kort)", done: s.background != nil)
            if let m = engine.learnMessage {
                Text(m).font(.footnote).foregroundStyle(.secondary)
            }
            slider("Følsomhed", value: $s.sensitivity, range: 0...1, text: "\(Int(s.sensitivity * 100)) %")
            Toggle("Geometri (Vision-firkant)", isOn: $s.geometry)
            Toggle("Lås eksponering og hvidbalance", isOn: $s.lockExposure)
            Toggle("Vis maske", isOn: $s.showMask)
            Button("Nulstil til standard", role: .destructive) { confirmReset = true }
                .confirmationDialog("Nulstil effekt og kalibrering?", isPresented: $confirmReset) {
                    Button("Nulstil", role: .destructive) { s.resetToDefaults() }
                }
        } header: { Text("Kalibrering") } footer: {
            Text("Uden kalibrering bruges rød #B3202A og blå #1E3F8F. Lær kortene i det lys, du optræder i. Følsomhed: højere = flere pixels regnes for kort.")
        }
    }

    private func learnButton(_ kind: LearnKind, _ title: String, done: Bool) -> some View {
        Button {
            engine.learn(kind)
        } label: {
            HStack {
                Text(engine.learning == kind ? "Måler … hold stille" : title)
                Spacer()
                if engine.learning == kind { ProgressView() } else if done { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
        }
        .disabled(engine.learning != nil)
    }

    // MARK: Kamera-realisme

    private var realismSection: some View {
        Section("Kamera-realisme") {
            Toggle("Gitter", isOn: $s.grid)
            Toggle("Vaterlinje", isOn: $s.level)
            Toggle("Spejl søgeren", isOn: $s.mirrorViewfinder)
            Toggle("Spejl gemte billeder", isOn: $s.mirrorSaved)
            Toggle("Fokusfirkant", isOn: $s.focusSquare)
            Toggle("Lukkerlyd", isOn: $s.shutterSound)
            Toggle("Lukkerblink", isOn: $s.shutterBlink)
            Toggle("Gem i Fotos", isOn: $s.saveToPhotos)
            Toggle("Testvideo i stedet for kamera", isOn: $s.testVideo)
                .accessibilityIdentifier("testVideoToggle")
        }
    }

    // MARK: Log og selvtest

    private var logSection: some View {
        Section("Log og selvtest") {
            if engine.log.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(engine.log.prefix(12)) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                    Text(e.text).font(.caption)
                }
            }
            Button(engine.selfTestProgress != nil ? "Selvtest kører …" : "Kør selvtest (5.000 billeder)") { engine.runSelfTest() }
                .disabled(engine.selfTestProgress != nil)
            if let p = engine.selfTestProgress { ProgressView(value: p) }
            ForEach(engine.selfTestLines, id: \.self) { Text($0).font(.caption.monospacedDigit()) }
        }
    }
}

/// Statusmærke, forhåndsvisning med maske, fps og maske-procent (opdateres alene, ca. 5 gange i sekundet).
struct LiveStatus: View {
    @ObservedObject var readout: LiveReadout

    var body: some View {
        let b: (String, Color) = {
            switch readout.status {
            case .ready: return ("KLAR", .green)
            case .off: return ("FRA", .gray)
            case .noCard: return ("INTET KORT", .orange)
            case .calibrating: return ("KALIBRERER", .blue)
            case .revealed: return ("AFSLØRET – genskab for at bruge igen", .yellow)
            }
        }()
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Color.black
                if let img = readout.preview {
                    Image(uiImage: img).resizable().scaledToFit()
                }
            }
            .frame(width: 90, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(b.0).font(.headline).foregroundStyle(b.1).accessibilityIdentifier("statusBadge")
                Text(String(format: "%.0f fps", readout.fps)).monospacedDigit()
                Text(String(format: "Maske %.1f %%", readout.maskPercent)).monospacedDigit()
                Text(String(format: "Skærmlys k %.2f", readout.light)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// Live-måler for "Ryst kortet": retningsskift i forhold til de krævede 4.
struct ShakeMeter: View {
    @ObservedObject var readout: LiveReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ryst-måler").font(.caption).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.22))
                    Capsule().fill(readout.shake >= 1 ? Color.green : Color.blue)
                        .frame(width: g.size.width * min(1, readout.shake))
                }
            }
            .frame(height: 10)
        }
    }
}
