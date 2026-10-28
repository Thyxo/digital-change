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
                cardSection
                warmupSection
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
                        // (UI-testen kan forlænge tiden med startargumentet -doneDelay.)
                        let delay = max(1, UserDefaults.standard.double(forKey: "doneDelay"))
                        if Date().timeIntervalSince(openedAt) > delay { engine.panelOpen = false }
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
            Text("Blå vises som rødt: det blå Rider Back-kort, kameraet ser, vises som det røde. Et tryk på kortet slukker forklædningen med den valgte overgang. Tryk ved siden af giver kun fokusfirkant.")
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

    // MARK: Kort og sporing

    private var cardSection: some View {
        Section {
            slider("Fingerfølsomhed", value: $s.occlusionSensitivity, range: 0...1, text: "\(Int(s.occlusionSensitivity * 100)) %")
            slider("Uskarphed på kortet", value: $s.blur, range: 0...1, text: "\(Int(s.blur * 100)) %")
            slider("Korn", value: $s.grain, range: 0...1, text: "\(Int(s.grain * 100)) %")
            Picker("Søg efter kortet", selection: $s.searchArea) {
                Text("Midterfeltet").tag(SearchArea.middle)
                Text("Omkring midten").tag(SearchArea.aroundMiddle)
                Text("Hele billedet").tag(SearchArea.whole)
            }
            Toggle("Lås eksponering og hvidbalance", isOn: $s.lockExposure)
            Toggle("Vis sporing", isOn: $s.showMask)
            Button("Nulstil til standard", role: .destructive) { confirmReset = true }
                .confirmationDialog("Nulstil effekt og sporing?", isPresented: $confirmReset) {
                    Button("Nulstil", role: .destructive) { s.resetToDefaults() }
                }
        } header: { Text("Kort og sporing") } footer: {
            Text("Kun Bicycle Rider Back (rød og blå). Appen kender begge bagsider og lægger det ægte målkort præcist over mønstret på det kort, kameraet ser – ingen kalibrering. Hold hele kortet i billedet omkring midten (se Søg efter kortet), til det er fundet; derefter følges det, også delvist uden for billedet. Den yderste del af den hvide kant er altid kameraets eget kort. Fingerfølsomhed: højere = fingre over kortet findes lettere (for højt kan give huller i kortet).")
        }
    }

    // MARK: Sløret opstart

    private var warmupSection: some View {
        Section {
            Toggle("Sløret opstart", isOn: $s.warmupBlur)
            if s.warmupBlur {
                Picker("Højst", selection: $s.warmupMax) {
                    ForEach(AppSettings.warmupChoices, id: \.self) { Text(String(format: "%g s", $0).replacingOccurrences(of: ".", with: ",")).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Styrke", value: $s.warmupStrength, range: 0...1, text: "\(Int(s.warmupStrength * 100)) %")
            }
            Picker("Markør: kortet er fundet", selection: $s.lockMarker) {
                Text("Prik ved ⌄ (mere)").tag(LockMarker.moreDot)
                Text("Prik ved Live").tag(LockMarker.liveDot)
                Text("Lille vibration").tag(LockMarker.haptic)
                Text("Ingen").tag(LockMarker.none)
            }
        } header: { Text("Sløret opstart") } footer: {
            Text("Når appen åbnes, er søgeren sløret (som iPhonens kamera et øjeblik), mens kortet findes og dækkes. Sløringen forsvinder, så snart kortet er dækket, eller efter højst den valgte tid. Markøren: prikken forsvinder i det øjeblik, kortet er fundet og dækket – ses den stadig, når sløringen er væk, er kortet ikke dækket endnu. Hold kortet omkring midterfeltet i gitteret, til det er fundet.")
        }
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
            Button(engine.selfTestProgress != nil ? "Selvtest kører …" : "Kør selvtest (300 billeder)") { engine.runSelfTest() }
                .disabled(engine.selfTestProgress != nil)
            if let p = engine.selfTestProgress { ProgressView(value: p) }
            ForEach(engine.selfTestLines, id: \.self) { Text($0).font(.caption.monospacedDigit()) }
        }
    }
}

/// Statusmærke, forhåndsvisning med sporing, fps og match (opdateres alene, ca. 5 gange i sekundet).
struct LiveStatus: View {
    @ObservedObject var readout: LiveReadout

    var body: some View {
        let b: (String, Color) = {
            switch readout.status {
            case .ready: return ("KLAR", .green)
            case .off: return ("FRA", .gray)
            case .noCard: return ("INTET KORT", .orange)
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
                Text(String(format: "Match %.0f %% · dækket %.0f %%", readout.score, readout.occluded)).monospacedDigit()
                Text(String(format: "%.1f ms pr. billede", readout.ms)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
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
