import SwiftUI

/// Hemmelig menu (5 hurtige tryk øverst til venstre). tr("Done", "Færdig") ignoreres det første sekund.
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
                        Text(tr("PANIC", "PANIK")).font(.headline).frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.red.opacity(0.85))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("panicButton")
                } footer: {
                    Text(tr("Menu: 5 quick taps at the top left. Panic: hold a finger at the top left for 1 s – the effect is switched off silently and the app is an ordinary camera. Switch it on again with Effect active.", "Menu: 5 hurtige tryk øverst til venstre. Panik: hold fingeren øverst til venstre i 1 sek. – effekten slås stille fra, og appen er et almindeligt kamera. Tænd igen med Effekt aktiv."))
                }
            }
            .navigationTitle("KameraPlus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done", "Færdig")) {
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
            Picker("Language / Sprog", selection: $s.language) {
                ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("languagePicker")
            Toggle(tr("Effect active", "Effekt aktiv"), isOn: $s.effectActive)
                .accessibilityIdentifier("effectToggle")
            if s.has(.menuButton) {
                Button(tr("Restore disguise now", "Genskab forklædning nu")) { engine.restore(.menuButton) }
            }
        }
    }

    // MARK: Effekt

    private var effectSection: some View {
        Section {
            Picker(tr("Disguise", "Forklædning"), selection: $s.disguise) {
                ForEach(DisguiseMode.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Triggers (can be combined)", "Trigger (kan kombineres)")).font(.subheadline)
                triggerToggle(.tapCard, tr("Tap the card", "Tryk på kortet"))
                triggerToggle(.shakeCard, tr("Shake the card", "Ryst kortet"))
                triggerToggle(.tapAnywhere, tr("Tap anywhere", "Tryk hvor som helst"))
                triggerToggle(.volumeUp, tr("Volume up", "Volumen op"))
                triggerToggle(.hiddenZone, tr("Hidden zone (black area right of the shutter)", "Skjult zone (sort felt højre for lukkeren)"))
            }
            if s.has(.shakeCard) {
                Picker(tr("Shake sensitivity", "Ryst-følsomhed"), selection: $s.shakeSensitivity) {
                    Text(tr("Light", "Let")).tag(ShakeSensitivity.light)
                    Text(tr("Normal", "Normal")).tag(ShakeSensitivity.normal)
                    Text(tr("Hard", "Hård")).tag(ShakeSensitivity.hard)
                }
                .pickerStyle(.segmented)
                ShakeMeter(readout: engine.readout)
            }
            Picker(tr("Transition", "Overgang"), selection: $s.transition) {
                Text(tr("Wave from the finger", "Bølge fra fingeren")).tag(TransitionKind.wave)
                Text(tr("Instant", "Øjeblikkeligt")).tag(TransitionKind.instant)
                Text(tr("Fade", "Fade")).tag(TransitionKind.fade)
                Text(tr("Sweep from top", "Fej oppefra")).tag(TransitionKind.sweep)
            }
            if s.transition != .instant {
                slider(tr("Duration", "Varighed"), value: $s.duration, range: 0.15...1.5, text: String(format: "%.2f s", s.duration))
            }
            slider(tr("Edge softness", "Kantblødhed"), value: $s.softness, range: 0...1, text: "\(Int(s.softness * 100)) %")
            Button(tr("Test reveal", "Test afsløring")) { engine.testReveal() }
        } header: { Text(tr("Effect", "Effekt")) } footer: {
            Text(tr("Blue shown as red: the blue Rider Back card the camera sees is shown as the red one. A tap on the card switches the disguise off with the chosen transition. A tap beside it only gives a focus square.", "Blå vises som rødt: det blå Rider Back-kort, kameraet ser, vises som det røde. Et tryk på kortet slukker forklædningen med den valgte overgang. Tryk ved siden af giver kun fokusfirkant."))
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
            restoreToggle(.menuButton, tr("Button in the menu", "Knap i menuen"))
            restoreToggle(.hiddenZoneHold, tr("Hidden zone at the bottom left (hold 1 s)", "Skjult zone nederst til venstre (hold 1 sek.)"))
            restoreToggle(.volumeDown, tr("Volume down", "Volumen ned"))
            restoreToggle(.phoneShake, tr("Shake the phone", "Ryst telefonen"))
            restoreToggle(.shutterDoubleTap, tr("Double-tap the shutter button", "Dobbelttryk på lukkerknappen"))
            restoreToggle(.autoNoCard, tr("Automatically when no card is seen", "Automatisk når intet kort er set"))
            if s.has(.autoNoCard) {
                Picker(tr("After", "Efter"), selection: $s.autoRestoreSeconds) {
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
                .pickerStyle(.segmented)
            }
            restoreToggle(.onLaunch, tr("Always disguised when the app opens", "Altid forklædt, når appen åbnes"))
        } header: { Text(tr("Restore disguise", "Genskab forklædning")) } footer: {
            Text(tr("After a reveal everything shows the camera's own colour until the disguise is restored. It never falls back by itself while you handle the card (so automatic restore is off by default). Restoring gives a small, discreet vibration.", "Efter afsløring er alt kameraets egen farve, indtil forklædningen genskabes. Den falder aldrig tilbage af sig selv, mens du håndterer kortet (automatisk genskab er derfor slået fra som standard). Genskab giver en lille diskret vibration."))
        }
    }

    private func restoreToggle(_ m: RestoreMethod, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { s.has(m) }, set: { s.set(m, $0) }))
    }

    // MARK: Kort og sporing

    private var cardSection: some View {
        Section {
            slider(tr("Finger sensitivity", "Fingerfølsomhed"), value: $s.occlusionSensitivity, range: 0...1, text: "\(Int(s.occlusionSensitivity * 100)) %")
            slider(tr("Card blur", "Uskarphed på kortet"), value: $s.blur, range: 0...1, text: "\(Int(s.blur * 100)) %")
            slider(tr("Grain", "Korn"), value: $s.grain, range: 0...1, text: "\(Int(s.grain * 100)) %")
            Picker(tr("Search for the card", "Søg efter kortet"), selection: $s.searchArea) {
                Text(tr("Middle square", "Midterfeltet")).tag(SearchArea.middle)
                Text(tr("Around the middle", "Omkring midten")).tag(SearchArea.aroundMiddle)
                Text(tr("Whole image", "Hele billedet")).tag(SearchArea.whole)
            }
            Toggle(tr("Lock exposure and white balance", "Lås eksponering og hvidbalance"), isOn: $s.lockExposure)
            Toggle(tr("Show tracking", "Vis sporing"), isOn: $s.showMask)
            Button(tr("Reset to default", "Nulstil til standard"), role: .destructive) { confirmReset = true }
                .confirmationDialog(tr("Reset effect and tracking?", "Nulstil effekt og sporing?"), isPresented: $confirmReset) {
                    Button(tr("Reset", "Nulstil"), role: .destructive) { s.resetToDefaults() }
                }
        } header: { Text(tr("Card and tracking", "Kort og sporing")) } footer: {
            Text(tr("Bicycle Rider Back only (red and blue). The app knows both backs and lays the real target card exactly over the pattern of the card the camera sees – no calibration. Hold the whole card in the image around the middle (see Search for the card) until it is found; after that it is followed, even partly outside the image. The outermost part of the white border is always the camera's own card. Finger sensitivity: higher = fingers over the card are found more easily (too high can leave holes in the card).", "Kun Bicycle Rider Back (rød og blå). Appen kender begge bagsider og lægger det ægte målkort præcist over mønstret på det kort, kameraet ser – ingen kalibrering. Hold hele kortet i billedet omkring midten (se Søg efter kortet), til det er fundet; derefter følges det, også delvist uden for billedet. Den yderste del af den hvide kant er altid kameraets eget kort. Fingerfølsomhed: højere = fingre over kortet findes lettere (for højt kan give huller i kortet)."))
        }
    }

    // MARK: Sløret opstart

    private var warmupSection: some View {
        Section {
            Toggle(tr("Blurred start", "Sløret opstart"), isOn: $s.warmupBlur)
            if s.warmupBlur {
                Picker(tr("At most", "Højst"), selection: $s.warmupMax) {
                    ForEach(AppSettings.warmupChoices, id: \.self) { Text(String(format: "%g s", $0).replacingOccurrences(of: ".", with: L10n.lang == .da ? "," : ".")).tag($0) }
                }
                .pickerStyle(.segmented)
                slider(tr("Strength", "Styrke"), value: $s.warmupStrength, range: 0...1, text: "\(Int(s.warmupStrength * 100)) %")
            }
            Picker(tr("Marker: card found", "Markør: kortet er fundet"), selection: $s.lockMarker) {
                Text(tr("Dot at ⌄ (more)", "Prik ved ⌄ (mere)")).tag(LockMarker.moreDot)
                Text(tr("Dot at Live", "Prik ved Live")).tag(LockMarker.liveDot)
                Text(tr("Small vibration", "Lille vibration")).tag(LockMarker.haptic)
                Text(tr("None", "Ingen")).tag(LockMarker.none)
            }
        } header: { Text(tr("Blurred start", "Sløret opstart")) } footer: {
            Text(tr("When the app opens, the viewfinder is blurred (like the iPhone camera for a moment) while the card is found and covered. The blur disappears as soon as the card is covered, or after the chosen time at most. Marker: the dot disappears the moment the card is found and covered – if it is still visible when the blur is gone, the card is not covered yet. Hold the card around the middle square of the grid until it is found.", "Når appen åbnes, er søgeren sløret (som iPhonens kamera et øjeblik), mens kortet findes og dækkes. Sløringen forsvinder, så snart kortet er dækket, eller efter højst den valgte tid. Markøren: prikken forsvinder i det øjeblik, kortet er fundet og dækket – ses den stadig, når sløringen er væk, er kortet ikke dækket endnu. Hold kortet omkring midterfeltet i gitteret, til det er fundet."))
        }
    }

    // MARK: Kamera-realisme

    private var realismSection: some View {
        Section(tr("Camera realism", "Kamera-realisme")) {
            Toggle(tr("Grid", "Gitter"), isOn: $s.grid)
            Toggle(tr("Level line", "Vaterlinje"), isOn: $s.level)
            Toggle(tr("Mirror viewfinder", "Spejl søgeren"), isOn: $s.mirrorViewfinder)
            Toggle(tr("Mirror saved photos", "Spejl gemte billeder"), isOn: $s.mirrorSaved)
            Toggle(tr("Focus square", "Fokusfirkant"), isOn: $s.focusSquare)
            Toggle(tr("Shutter sound", "Lukkerlyd"), isOn: $s.shutterSound)
            Toggle(tr("Shutter blink", "Lukkerblink"), isOn: $s.shutterBlink)
            Toggle(tr("Save to Photos", "Gem i Fotos"), isOn: $s.saveToPhotos)
            Toggle(tr("Test video instead of camera", "Testvideo i stedet for kamera"), isOn: $s.testVideo)
                .accessibilityIdentifier("testVideoToggle")
        }
    }

    // MARK: Log og selvtest

    private var logSection: some View {
        Section(tr("Log and self-test", "Log og selvtest")) {
            if engine.log.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(engine.log.prefix(12)) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                    Text(e.text).font(.caption)
                }
            }
            Button(engine.selfTestProgress != nil ? tr("Self-test running …", "Selvtest kører …") : tr("Run self-test (300 frames)", "Kør selvtest (300 billeder)")) { engine.runSelfTest() }
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
            case .ready: return (tr("READY", "KLAR"), .green)
            case .off: return (tr("OFF", "FRA"), .gray)
            case .noCard: return (tr("NO CARD", "INTET KORT"), .orange)
            case .revealed: return (tr("REVEALED – restore to use again", "AFSLØRET – genskab for at bruge igen"), .yellow)
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
                Text(String(format: tr("Match %.0f %% · covered %.0f %%", "Match %.0f %% · dækket %.0f %%"), readout.score, readout.occluded)).monospacedDigit()
                Text(String(format: tr("%.1f ms per frame", "%.1f ms pr. billede"), readout.ms)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// Live-måler for tr("Shake the card", "Ryst kortet"): retningsskift i forhold til de krævede 4.
struct ShakeMeter: View {
    @ObservedObject var readout: LiveReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Shake meter", "Ryst-måler")).font(.caption).foregroundStyle(.secondary)
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
