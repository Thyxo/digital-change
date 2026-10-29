# CLAUDE.md

Vejledning til Claude Code i dette repo.

## Hvad det er

**KameraPlus** (visningsnavn "Kamera", effekten hedder *Digital Flap*): en native iPhone-app (SwiftUI, iOS 17+, sideloadet via SideStore), der er en pixel-klon af iPhones Kamera med frontkameraet. Det er et magi-rekvisit: et blåt **Bicycle Rider Back**-kort vises live som det **ægte røde Rider Back** (referencebillederne, ikke en farveomregning), og et tryk på kortet afslører det ægte blå kort med en bølge fra fingeren. Appen må aldrig afsløre sig selv. Appens egne tekster (hemmelig menu, log) er engelske som standard og kan skiftes til dansk i menuen (`tr("English", "Dansk")` i `Localization.swift`; nye tekster skal have begge). Kameraets egne tekster følger iPhonens sprog.

## Byg og test

- `cd ios && xcodegen generate` → `KameraPlus.xcodeproj` (genereret, ikke i git; det er `KameraPlus/Info.plist` heller ikke).
- Logik-tests uden Mac: `cd ios && swift test -c release -Xswiftc -enable-testing` (Package.swift peger på `KameraPlus/Logic` og `KameraPlusTests`). Selvtesten tager ca. 1 min.
- CI (`.github/workflows/ipa.yml`, macos-15): logik-tests på macOS → UI-tests i simulator → usigneret IPA. `dev` = test + build, `main` = release `build-N` + `sidestore/source.json` (committes af CI – hent `main` før du pusher).
- Ikoner/glyffer: `python3 scripts/extract-icons.py` (skærer fra `ref/`).
- Kortbilleder: `python3 scripts/prepare-cards.py` (kræver opencv-python-headless + numpy) → `ios/Cards/` (PNG 1024 px til visning, rå RGB 256 px til analyse, `rider.json` med geometri og målinger), `demo/rider-*.png` og `ref/rider-check.png`. Kør det igen, hvis referencerne skiftes, og tjek `residualAfterPx` i `rider.json`.

## Arkitektur

- **Ren logik** i `ios/KameraPlus/Logic/` (kun Foundation, kompilerer på Linux): kortskabeloner (`CardTemplate`), homografi, mønster-sporing + lys + fingermaske (`CardTracker`), overgange, tilstandsmaskine, ryst, syntetiske scener med de ægte kort, selvtest. Tests læser `ios/Cards` via `#filePath` (`Fixtures` i CardTests.swift). Alt her skal have tests i `ios/KameraPlusTests/`. Testfilerne bruger `#if canImport(KameraLogic)` – behold det (Xcode kompilerer logikken direkte ind i testbundtet).
- **iOS-lag** i `ios/KameraPlus/App/`: `Engine` (MainActor, binder alt), `Pipeline` (seriel kø pr. kamerabillede, ca. 540 px), `Renderer` + `Shaders.metal`, `RectangleTracker` (Vision – kun startgæt), `CameraSource`/`SyntheticSource` (FrameSource), `CameraUI`, `SecretPanel`, `Gallery`. `ios/Cards` ligger som mappe i app-bundtet (`Cards/`).
- Shaderen og Swift skal give samme resultat: overlay-området er `CardGeometry.overlay`/`overlayDistance`, lyset er `CardTracker`s model (lineært: gain pr. kanal + fælles offset, gange lokal skygge), og overgangene bruger samme formler som `RevealPlan`. Ændrer du den ene, så ret den anden. Demoen (`demo/index.html`) har de samme formler.

## UI: målt, ikke vilkårligt

Tallene i `enum L` (CameraUI.swift) er målt på `ref/kamera-1.webp` og `ref/kamera-2.webp` (923×2000 px = 393×852 pt, 2,349 px/pt). Fx søger y 118–642, top-pille 141×35 ved (306,5; 89,5), lukker Ø 79,2/67,4 ved (196,5; 697,3), bundrække y 793 med Ø 47,7-cirkler og tilstandspille 164×42. Ret dem kun efter nye målinger. Glyfferne er skåret ud af screenshots (`glyph-*` i Assets) og vises i 27,3 pt (top), 23,8 pt (søger-knap) og 33,2 pt (vend).

## Nemme at ødelægge

- **Ingen farveomregning, ingen gentegning.** Målkortet er altid `ios/Cards/rider-<farve>.png` (de ægte referencer, registreret af `prepare-cards.py`). Erstat det aldrig med noget genereret.
- **Kanonisk kort 1024×1424**: alle homografier går fra kanoniske kortkoordinater til billedets pixels (kant-konvention: pixel i har centrum i i + 0,5). Skabelonerne er lagt præcist oven på hinanden i dette system.
- **Yderste halvdel af den hvide kant tegnes aldrig over** (`CardGeometry.overlay`) – fysiske kort er skåret forskelligt; overlay helt ud til kanten giver hvide/mørke striber.
- **Lysmodellen har én fælles offset**, ikke én pr. kanal: med offset pr. kanal kan et blåt kort "forklares" som et rødt, og farvetjekket svigter.
- **Sporingen starter på et niveau med kortet ≥ 56 px bredt**; grovere niveauer konvergerer til forkerte minima i det fine mønster. Hurtig bevægelse klares af `translationSearch` på niveauet over.
- **Mønstret er næsten 180°-symmetrisk**: ved start justeres begge drejninger helt, og den bedste vælges. Fjern det ikke.
- **Fingermasken** bruger farvetone (lysstyrke-uafhængig, dæmpet i mørke områder) og mindste afstand over 3×3 naboer. Ren lysstyrke-forskel giver falske fingre i skygger.
- **Tilstanden må aldrig gå tilbage til forklædt af sig selv** – kun via en genskab-metode, der er slået til. Automatisk genskab er fra som standard.
- **Hemmelig zone** øverst til venstre (90×90 pt): 5 tryk inden for 2,5 sek. = menu, hold 1 sek. = panik. "Færdig" ignoreres i 1 sek. UI-testene tjekker det.
- Kameraet leverer uspejlede portrætbilleder (`videoRotationAngle = 90`, `isVideoMirrored = false`); spejling sker kun i shaderen. Gemte billeder er uspejlede som standard.
- **Sløret opstart** sker i Metal (`kp_blur`) på det *færdige* billede med målkortet – aldrig SwiftUI `.blur` på søgeren alene, ellers anes det blå kort som en klat, der skifter farve. Sløringen slipper kun på et *friskt* fund (`cardFresh`), ikke et kort, der holdes fra før baggrunden (`WarmupGate` i Logic).
- **Søgeområdet** (`SearchArea`, gitteret i søgeren omregnet med zoom) gælder kun første fund; et kort, der følges, må bevæge sig frit.
- `Engine` er `@MainActor`; arbejde fra andre køer går via `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`.
