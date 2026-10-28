# CLAUDE.md

Vejledning til Claude Code i dette repo.

## Hvad det er

**KameraPlus** (visningsnavn "Kamera", effekten hedder *Digital Flap*): en native iPhone-app (SwiftUI, iOS 17+, sideloadet via SideStore), der er en pixel-klon af iPhones Kamera med frontkameraet. Det er et magi-rekvisit: et blåt spillekort vises live som rødt, og et tryk på kortet afslører den ægte blå farve med en bølge fra fingeren. Appen må aldrig afsløre sig selv. Al UI-tekst er dansk (kameraets egne tekster følger iPhonens sprog).

## Byg og test

- `cd ios && xcodegen generate` → `KameraPlus.xcodeproj` (genereret, ikke i git; det er `KameraPlus/Info.plist` heller ikke).
- Logik-tests uden Mac: `cd ios && swift test -c release -Xswiftc -enable-testing` (Package.swift peger på `KameraPlus/Logic` og `KameraPlusTests`). Selvtesten tager ca. 1 min.
- CI (`.github/workflows/ipa.yml`, macos-15): logik-tests på macOS → UI-tests i simulator → usigneret IPA. `dev` = test + build, `main` = release `build-N` + `sidestore/source.json` (committes af CI – hent `main` før du pusher).
- Ikoner/glyffer: `python3 scripts/extract-icons.py` (skærer fra `ref/`).

## Arkitektur

- **Ren logik** i `ios/KameraPlus/Logic/` (kun Foundation, kompilerer på Linux): farvemodel, farveskift, maske, lys, overgange, tilstandsmaskine, ryst, syntetiske kort, selvtest. Alt her skal have tests i `ios/KameraPlusTests/`. Testfilerne bruger `#if canImport(KameraLogic)` – behold det (Xcode kompilerer logikken direkte ind i testbundtet).
- **iOS-lag** i `ios/KameraPlus/App/`: `Engine` (MainActor, binder alt), `Pipeline` (seriel kø pr. kamerabillede), `Renderer` + `Shaders.metal`, `RectangleTracker` (Vision), `CameraSource`/`SyntheticSource` (FrameSource), `CameraUI`, `SecretPanel`, `Gallery`.
- Shaderen og Swift skal give samme resultat: farveskiftet ligger i en 3D-tabel bygget af `ColorTransfer.buildLUT`, og overgangene bruger samme formler som `RevealPlan`. Ændrer du den ene, så ret den anden.

## UI: målt, ikke vilkårligt

Tallene i `enum L` (CameraUI.swift) er målt på `ref/kamera-1.webp` og `ref/kamera-2.webp` (923×2000 px = 393×852 pt, 2,349 px/pt). Fx søger y 118–642, top-pille 141×35 ved (306,5; 89,5), lukker Ø 79,2/67,4 ved (196,5; 697,3), bundrække y 793 med Ø 47,7-cirkler og tilstandspille 164×42. Ret dem kun efter nye målinger. Glyfferne er skåret ud af screenshots (`glyph-*` i Assets) og vises i 27,3 pt (top), 23,8 pt (søger-knap) og 33,2 pt (vend).

## Nemme at ødelægge

- **Farveskiftet er forankret i papirhvidt** (blæk-andel w), ikke i kortets middelfarve. Går du tilbage til ren Reinhard, bliver hvid kant og hud farvet.
- **Hudbeskyttelse** (`ColorMath.skinGuard`, farvetone 40–80°) gælder både klassifikator og overførsel. Testen `testSkinNeverRecoloredInEitherDirection` skal forblive grøn.
- **Skærmens lys** (`IlluminationModel`, k): uden kort søges kun k ≤ 0 (kildens lys). Søges der også i målets lys uden kort, kommer der falske positiver.
- **Masken holdes 4 billeder** og har hurtig attack/langsom release. Gør du den "pænere" med symmetrisk udglatning, kommer der blå forkanter og blink.
- **Tilstanden må aldrig gå tilbage til forklædt af sig selv** – kun via en genskab-metode, der er slået til. Automatisk genskab er fra som standard.
- **Hemmelig zone** øverst til venstre (90×90 pt): 5 tryk inden for 2,5 sek. = menu, hold 1 sek. = panik. "Færdig" ignoreres i 1 sek. UI-testene tjekker det.
- Kameraet leverer uspejlede portrætbilleder (`videoRotationAngle = 90`, `isVideoMirrored = false`); spejling sker kun i shaderen. Gemte billeder er uspejlede som standard.
- `Engine` er `@MainActor`; arbejde fra andre køer går via `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`.
