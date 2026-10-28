# KameraPlus – kamera med skjult farveskift (Digital Flap)

Native iPhone-app (SwiftUI, iOS 17+), der ser ud og opfører sig som iPhones **Kamera** med frontkameraet. I hemmelighed kan den vise et blåt spillekort som rødt – live – og afsløre den ægte blå farve, når du trykker på kortet. For alle andre er det bare et kamera. Visningsnavn: **Kamera**.

> Ikke testet på en fysisk iPhone endnu. Logikken er testet automatisk (se *Hvad er testet*), og appen bygges og UI-testes i simulatoren på GitHub. Se *Kendte begrænsninger*.

---

## 1. Opsætning (SideStore)

Kilde-URL (opdateres automatisk ved hver build på `main`):
```
https://raw.githubusercontent.com/Thyxo/digital-change/main/sidestore/source.json
```
SideStore → **Sources** → **+** → indsæt URL → KameraPlus → **Install**. IPA'en ligger også under *Releases* (nyeste: `releases/latest/download/KameraPlus.ipa`). Virker også i AltStore/Sideloadly.

Første start: giv adgang til kameraet. "Gem i Fotos" spørger først, når du slår det til.

**Branches:** push til `dev` = test + build (ingen release). Push til `main` = release + ny SideStore-version. CI bruger kun `git` og `gh` (repoets Actions-politik tillader kun handlinger ejet af Thyxo).

**Demo på computeren:** https://digital-flap-demo.vercel.app (WebGL + webcam, `demo/index.html`). Samme farveskift og overgange, så du kan vælge udseende og parametre. Vercel-projektet *digital-flap-demo* udgiver mappen `demo/` ved hvert push til produktions-branchen.

**Før første optræden (3 trin i menuen → Kalibrering):**
1. **Lær rødt kort** – hold et kort fra det røde spil 2–5 cm over kameraet i 3 sek.
2. **Lær blåt kort** – samme med det blå kort.
3. **Lær baggrund** – vis hånden og rummet uden kort i 3 sek. (anbefales især i omvendt tilstand).

Uden kalibrering bruges rød `#B3202A` og blå `#1E3F8F`.

---

## 2. Menuen

**Åbn:** 5 hurtige tryk (inden for 2,5 sek.) i **øverste venstre hjørne** (usynlig zone på 90×90 pt). **Færdig** lukker (første sekund ignoreres). Intet i kameraet viser, at menuen findes.

| Sektion | Indhold |
|---|---|
| Top | Statusmærke **KLAR / FRA / INTET KORT / KALIBRERER** (+ AFSLØRET), live-forhåndsvisning med maske, fps, maske-procent, skærmlys k, **Effekt aktiv**, *Genskab forklædning nu* |
| Effekt | Forklædning (*Blå vises som rødt* = standard / *Rød vises som blåt*), trigger (Tryk på kortet = standard, Ryst kortet, Tryk hvor som helst, Volumen op, Skjult zone – kan kombineres), ryst-følsomhed (let/normal/hård) med live-måler, overgang, varighed, kantblødhed, **Test afsløring** |
| Genskab forklædning | Én kontakt pr. metode: knap i menuen, skjult zone nederst til venstre (hold 1 sek.), volumen ned, ryst telefonen, dobbelttryk på lukkeren, automatisk efter 3/5/10 sek. uden kort (standard **fra**), altid forklædt når appen åbnes |
| Kalibrering | Vejledning i 3 trin, Lær rødt/blåt kort, Lær baggrund, følsomhed, geometri (Vision) til/fra, lås eksponering og hvidbalance, vis maske, nulstil til standard |
| Kamera-realisme | Gitter, vaterlinje, spejl søger, spejl gemte billeder, fokusfirkant, lukkerlyd, lukkerblink, gem i Fotos, testvideo i stedet for kamera |
| Log og selvtest | Seneste tryk (tid, ramte kort ja/nej, hvad der blev vist) og randomiseret selvtest (5.000 billeder) |
| PANIK | Rød knap |

**Valg jeg har truffet (ret dem gerne):**
- *Skjult zone* som trigger = et tryk i det sorte felt **til højre for lukkeren**.
- *Skjult zone* som genskab = **hold 1 sek.** nederst til venstre (også på miniaturen; et kort tryk på miniaturen åbner galleriet).
- Volumenknapperne tager et billede (som i Kamera), medmindre de er valgt som trigger/genskab.
- Test afsløring genskaber selv forklædningen efter 2 sek.

---

## 3. Forløbet

1. Telefonen ligger med skærmen op. Hold det **blå** kort 2–5 cm over frontkameraet (eller på linsen).
2. Skærmen viser kortet som **rødt** (forklædt). Fingre, hud, baggrund og røde kort er urørte.
3. **Tryk på kortet** på skærmen → forklædningen slukkes med en bølge fra fingeren (0,5 sek.), og den ægte blå farve kommer frem. Tryk ved siden af kortet giver kun den gule fokusfirkant.
4. Afsløret bliver ved, også når kortet forlader billedet, vendes eller dækkes – indtil du genskaber forklædningen.

Er der intet kort i billedet, sker der intet ved tryk (kun fokus).

---

## 4. Sådan virker det

**Kamera:** AVCaptureSession, frontkamera i 4:3 (helst 1440×1080, 30 fps), BGRA, `alwaysDiscardsLateVideoFrames`, portræt, uspejlet. Søgeren spejles i Metal (som Apples frontkamera); gemte billeder er uspejlede som standard.

**Pr. billede (seriel kø):**
1. Nedskalering 4×4 → ca. 270×360 (blander mønstret til en jævn farve og dæmper støj).
2. **Farvemodel i Lab:** Gauss-model (middel + kovarians) af kortet, Mahalanobis-grænse (følsomhed), krav om kromatisk mætning (≥ halvdelen af kortets), farvetone-vindue og **hudbeskyttelse** (farvetone 40–80°, der aldrig regnes for kort ved rødt kildekort). Evt. lært baggrund undertrykker farver, der er almindelige uden kort. Hele modellen ligger i en 64³-opslagstabel.
3. **Skærmens lys:** skærmen lyser selv kortet op nedefra – rødt mens forklædningen vises, blåt efter. Det flytter kortets farve meget (et lavmættet blåt kort kan flytte 40° i farvetone). Lyset beskrives med ét tal *k* langs den fysisk mulige retning (målfarvens eller kildens lys), og *k* vælges pr. billede, så kortets egne pixels passer bedst. Farven normaliseres før modellen, og lyset lægges på igen efter farveskiftet (von Kries). Uden kort søges kun i kildens lys (søgeren viser aldrig forklædningen uden kort).
4. **Maske:** udglatning i tid (hurtig op, langsom ned – ingen blå forkant på et kort i bevægelse), hysterese, morfologisk lukning/åbning, sammenhængende områder (største + naboer, så en finger kan dele kortet), Vision-firkant som rumligt prior, og over 70 % dækning = hele billedet er kortet. Masken holdes i 4 billeder ved udfald og tones så ud (ingen blink).
5. **Geometri:** `VNDetectRectanglesRequest` (billedformat 0,64–0,80, kvadratur 20°, min. størrelse 0,12) ca. 15 Hz når et kort ses (3 Hz ellers) og `VNTrackRectangleRequest` imellem. Firkanten bruges kun, hvis mindst 35 % af den er kortfarvet.
6. Eksponering og hvidbalance låses, når kortet er set i 5 billeder, og frigøres efter 1,5 sek. uden kort.

**Farveskift (min forbedring af din formel):** din Reinhard-overførsel (L' = μL_mål + (L − μL_kilde)·k, k = σ_mål/σ_kilde begrænset til 0,7–1,4; (a,b) flyttet fra kilde til mål) er **forankret i papirhvidt** i stedet for kortets middelfarve. Et trykt kort er blæk på hvidt papir: hver pixel er en blanding, og blæk-andelen *w* styrer, hvor meget L flyttes, mens (a,b) roteres/skaleres om den grå akse, så kildens middelfarve rammer målets præcist. Derfor bliver **hvid kant, mønstrets hvide streger, skygger og hud urørte**, og mønstrets lysforløb bevares (korrelation > 0,99 i testen). A = Σ_mål^½·Σ_kilde^−½ er erstattet af rotation+skalering, fordi kortets farver ligger på en linje fra papir til blæk. Overførslen ligger i en **65³ 3D-tabel** (gns. ΔE 0,3 mod den direkte beregning), som shaderen slår op i – så Swift-koden, der testes, er præcis det, der vises.

**Visning:** Metal (MTKView, CVMetalTextureCache, nul-kopi). Shaderen: kamera → (forklædning i masken) → afsløringens overgang → skærm. Kantens finhed følger kortets egne farvekanter i fuld opløsning (tabellen ændrer kun kortfarver), så masken i lav opløsning kun skal dække kortet.

**Overgange:** *Bølge fra fingeren* (standard: radius vokser fra trykpunktet til kortets fjerneste hjørne, blød kant, meget svag lys kant i fronten, easeInOut), *Øjeblikkeligt* (hårdt klip), *Fade*, *Fej oppefra*. Varighed 0,15–1,5 sek. og kantblødhed kan justeres.

**Ryst kortet:** kortets centrum eller et hjørne skal skifte retning mindst 4 gange inden for 1 sek. med udsving ≥ 4/6/9 % af kortets bredde (let/normal/hård), mens telefonen har ligget stille (CoreMotion) i hele vinduet. Højst én udløsning pr. 2 sek. Løft, vipning, drejning, roligt flyt og et skub til bordet udløser ikke.

**Kamera-UI** (målt på dine screenshots, 923×2000 px = 393×852 pt; skaleres efter bredden):
| Element | Mål |
|---|---|
| Søger | 393×524 pt, y 118–642, 4:3 |
| Gitter | x 131/262, y 292/467, 0,8 pt, hvid 45 % |
| Vaterlinje | `#E8CA45`, 1 pt, x 106–287, y 379 – vises når telefonen ligger vandret (±6°) |
| Top-pille | x 236–377, y 72–107, `#1E1E1E`; ikoner x 254/289/324/359 (skåret ud af screenshot 2) |
| Søger-knap | centrum (196,3; 605,4), Ø 37,5 pt; *udvid* (1× beskåret, standard) ↔ *sammentryk* (0,8×, hele billedet) |
| Lukker | centrum (196,5; 697,3), ring Ø 79,2 `#323232` med lys kant, skive Ø 67,4 |
| Bundrække | y 793; miniature og vend-kamera **Ø 47,7 pt** (dine tal sagde 52 – målt til 48), tilstandspille 164×42 `#141414` med indrammet kapsel `#1F1F1F` om det valgte, tekst 14 pt, FOTO `#FEF657` |

Ikonerne drejer med telefonen (CoreMotion, blød animation). FOTO/VIDEO følger iPhonens sprog (da, en, de, sv, nb, fr, es, it, nl, fi, pt, pl, is – ellers engelsk). Tryk i søgeren = gul fokusfirkant (80 pt, 1,25 → 1, tones ud efter 1 sek.). Swipe vandret skifter FOTO/VIDEO. Vend kamera skifter til bagkameraet (uden effekt) med en sløret 3D-vending.

**Billeder og video:** lukkeren gemmer det bearbejdede billede (med farveskiftet) i appens eget galleri (miniaturen åbner det). Gem i Fotos er en kontakt (kun tilføj). VIDEO optager søgerens billede med effekten (H.264, uden lyd).

**Batteri og varme:** galleriet stopper kameraet helt. Når menuen er åben, tegnes søgeren ikke; analysen kører videre, fordi forhåndsvisningen og kalibreringen skal bruge den. Vision kører 3 Hz, når intet kort ses. Panik slår analysen fra.

---

## 5. Panik

**Hold fingeren i øverste venstre hjørne i ca. 1 sekund.** Effekten slås stille fra, og appen er et helt almindeligt kamera. Intet vises. Der er også en rød **PANIK**-knap i menuen. Tænd igen med *Effekt aktiv*.

---

## 6. Kendte begrænsninger

- **Ikke testet på fysisk iPhone.** Testvideoen er syntetisk. Tjek især: kamerabilledets retning/spejling (vinkel 90°), Vision-firkanten på et rigtigt kort, hvor stærkt skærmens lys farver kortet, og om 30 fps holder på iPhone 12.
- **Fingre over kortet:** fingre farves aldrig om, men dækker de det meste af kortet, kan masken tabe det.
- **Stærk refleks** på kortet (blankt lys) bliver hvidt og skiftes ikke.
- **Meget svagt lys:** støj og lav mætning gør farvemodellen usikker. Kalibrér i optrædenslyset.
- **iPhone SE** (16:9 uden Face ID): layoutet skaleres ned med sorte kanter i siderne, fordi målene er taget på en 19,5:9-skærm. Den hemmelige zone sidder stadig i skærmens hjørne.
- **Kort der bevæger sig hurtigt:** masken følger med (hurtig op, 4 billeders hold), men meget hurtige bevægelser kan give en kort kant i ægte farve.
- **Omvendt tilstand** (rødt kort vist som blåt): lys/rosa hud ligger tæt på et rødt kort i lav opløsning. Huden farves aldrig, men kan i op til ca. 5 % af tilfældene tælles som "kort set" (selvtest). Brug *Lær baggrund* med hånden i billedet.
- **App-ikonet** er tegnet (Kamera-agtigt), fordi `ref/hjemmeskaerm.png` mangler. Læg dit hjemmeskærm-screenshot i `ref/` og kør `python3 scripts/extract-icons.py --icon x,y,størrelse`.
- **Video** optages uden lyd (ingen mikrofon-tilladelse). Natfunktion, flash, live og "⋯" er kun udseende (flash med frontkamera giver hvid skærm ved billede).
- Repoets **standard-branch** blev `claude/…` (første push). Sæt den til `main` under Settings → Branches.

---

## 7. Hvad er testet

`ios/KameraPlusTests` (kører på macOS i CI før hver build; lokalt: `cd ios && swift test -c release -Xswiftc -enable-testing`) – **51 tests, alle grønne**:

- **Farve:** Lab-rundtur (20.000 farver, maks. 1 trin), kendte Lab-værdier, standardpaletter har rigtig farvetone.
- **Farveoverførsel:** middelfarve ΔE 1,2 mod det ægte målkort (begge retninger), lysmønster bevaret (korrelation 0,998), hvid/grå/sort/papir urørt, **hud aldrig ændret** (10 hudtoner × 3 lysstyrker × 4 paletter), 65³-tabellen mod direkte beregning (gns. ΔE 0,3).
- **Klassifikator:** blåt kort ja, træ/væg/grå/sort/hud/rødt nej; rødt kort ja men hud nej; følsomhed; tabel = direkte; lært baggrund undertrykker en blålig trøje.
- **Maske** (syntetiske Rider-agtige kort med hvid kant og mønster, 540×720 → 270×360): 7 baggrunde × 2 farver med fingre IoU ≥ 0,9; ingen falske positiver på hud/træ/hvid væg/loft; kort der fylder hele billedet; kort delvist uden for billedet; Vision-firkant dækker hele kortet; forkert firkant ignoreres; ét tabt billede blinker ikke; kort i bevægelse uden blå forkant (≥ 97 % dækket); skærmens røde/blå lys; køligt rumlys gør ikke væggen til et kort; hit-test (30 %-regel).
- **Overgange:** easing og afsløring monoton i tiden for alle fire typer, bølge fra fingeren til kortets hjørner, hårdt klip, fej oppefra.
- **Tilstandsmaskine:** tryk på/ved siden af kortet, intet kort = ingen afsløring, kun valgte triggere, genskab-metoder, automatisk genskab kun efter nok tid uden kort (og fra som standard), kortet forlader billedet 300 gange uden at falde tilbage, panik, opstart, eksponeringslås.
- **Ryst:** 2,5/3/4 Hz rysten og drejerysten udløser; roligt flyt, frem-og-tilbage én gang, løft, vipning, drejning, støj og skub til bordet gør ikke; nedkøling 2 sek.; følsomhed.
- **Bevægelse/geometri:** orientering med hysterese, vaterlinje, ryst telefonen, stilstand, omregning søger ↔ billede (spejlet, beskåret), firkanter.
- **Randomiseret selvtest** (fast seed 2026, 5.000 billeder: tilfældige baggrunde, hudtoner, 0–2 fingre, lys, støj, skærmlys der skifter fra kildens til målets farve, halvdelen med Vision-firkant) – kan også køres i appen:

```
5000 billeder (3334 med kort, 1666 uden)
Maske IoU: gns. 0,961, 5 %-fraktil 0,940
Kort ikke fundet: 0 (0,0 %)
Falske positiver (hud, træ, væg …): 2 (0,1 %)
Farveskift ΔE mod ægte kort: gns. 5,05
Største ændring af hud: ΔE 0,00
```
Omvendt (1.500 billeder): IoU 0,977, 0 % misset, 4,8 % falske positiver, hud ΔE 0,00.

**UI-tests** (`ios/KameraPlusUITests`, iPhone 17 Pro-simulator med iOS 26.2, Release-byg, testvideo i stedet for kamera) – **6 tests, alle grønne**: 5 tryk øverst til venstre åbner menuen, 4 tryk gør ikke, 5 tryk over 3 sek. gør ikke, 5 tryk øverst til højre gør intet, "Færdig" ignoreres i spærretiden (testen forlænger den til 4 sek. med `-doneDelay`, fordi simulatoren er for langsom til at ramme 1 sek. præcist), panik (hold 1,4 sek.) slår effekten fra. CI fejler på røde tests.

**Ikke testet automatisk:** selve kameraet (AVFoundation), Vision på rigtige kort, Metal-billedet på en rigtig skærm, lukker/galleri/video og volumenknapper – det kræver en fysisk iPhone.

---

## Filer
```
ios/project.yml                 XcodeGen (app, logik-tests på macOS, UI-tests)
ios/Package.swift               kun til at køre logik-testene lokalt (fx Linux)
ios/KameraPlus/Logic/           ren logik uden UI (testet)
  ColorMath, Palette            Lab, Gauss-paletter, "Lær kort", lært baggrund
  ColorTransfer, CardClassifier farveskift og pixelklassifikator (+ opslagstabeller)
  Illumination, CardAnalyzer    skærmens lys (k) og samlet analyse pr. billede
  MaskProcessor, Geometry       maske, firkanter, søger ↔ billede
  Transition, EffectState       overgange, tilstandsmaskine, eksponeringslås
  Shake, Synthetic, SelfTest    ryst/bevægelse, syntetiske kort, selvtest
ios/KameraPlus/App/             iOS (SwiftUI, AVFoundation, Metal, Vision, CoreMotion)
  Engine.swift                  binder alt sammen (som Engine i MindTrace)
  Pipeline.swift                arbejde pr. kamerabillede
  FrameSource.swift             kamera + syntetisk testvideo (FrameSource-protokol)
  Renderer.swift, Shaders.metal Metal-søger, billeder og video
  RectangleTracker.swift        Vision
  CameraUI.swift                kamera-klonen (alle mål i enum L)
  SecretPanel.swift             hemmelig menu
  Gallery.swift                 eget galleri
  AppSettings, Haptics, VolumeButtons, MotionManager
ios/KameraPlusTests/            logik-tests
ios/KameraPlusUITests/          UI-tests
.github/workflows/ipa.yml       test → build → IPA → release → SideStore-kilde
scripts/extract-icons.py        glyffer (og ikon) skåret ud af ref/
scripts/make-icon.py            tegnet Kamera-ikon (indtil hjemmeskærm-screenshot)
scripts/make_source.py          SideStore-kilde
ref/                            dine screenshots
```
