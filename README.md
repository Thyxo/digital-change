# KameraPlus – kamera med skjult kortskift (Digital Flap)

Native iPhone-app (SwiftUI, iOS 17+), der ser ud og opfører sig som iPhones **Kamera** med frontkameraet. I hemmelighed viser den et blåt **Bicycle Rider Back**-kort som det røde Rider Back – live – og afslører det ægte blå kort, når du trykker på det. For alle andre er det bare et kamera. Visningsnavn: **Kamera**.

Appen bruger **de ægte kortdesigns** (dine to referencebilleder), ikke en farveomregning eller en tegnet efterligning: appen finder det fysiske korts mønster i kamerabilledet med subpixel-præcision og lægger det ægte røde kortbillede præcist oven på.

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

**Demo på computeren:** https://digital-flap-demo.vercel.app (WebGL, `demo/index.html`): de to ægte kortbilleder på et bord med perspektiv, samme overlay-område og overgange som appen, plus kontrolvisninger (ternet, gardin, blink), hvor du kan se, at rødt og blåt flugter. Vercel-projektet *digital-flap-demo* udgiver mappen `demo/` ved hvert push til produktions-branchen.

**Ingen kalibrering.** Appen kender begge bagsider. Brug kun Bicycle Rider Back (standard, rød og blå).

---

## Kortbillederne

`scripts/prepare-cards.py` laver de to kortbilleder i `ios/Cards/` (og `demo/`) ud fra `ref/rider-blue.jpg` og `ref/rider-red.jpg`. Ingen pixels tegnes – hvert pixel er en prøve af dit originalfoto, kun flyttet geometrisk:

1. **Blåt kort (scanning):** venstre-, højre- og topkant målt med subpixel-præcision (spredning 0,12–0,28 px); scanningen er drejet ca. 0,6°. Bunden er beskåret i scanningen og sat ud fra mønstrets 180°-symmetri (usikkerhed 1–3 px af 717). Hjørneradius målt langs diagonalen (27–31 px). Rettet op til et kanonisk kort på **1024×1424 px** (scanningens egne proportioner, 0,719).
2. **Rødt kort (produktfoto):** registreret på selve mønstret (ECC på lysstyrke – JPEG'ens farver er kun halv opløsning – homografi, grov → fin) plus en blød 3.-grads korrektion af fotoets resterende forvrængning. **Rest mellem rødt og blåt mønster: gns. 0,22 px, 90 % under 0,47 px, maks. 0,78 px** (i scanningens pixels, målt i 459 felter). Korrelation 0,98.
3. **Hvid baggrund fjernet** (alfa = kortets afrundede omrids, antialiaseret). Scannerens skyggelinje langs den blå kant, og den yderste kant på det røde (produktfotoet har smallere kant end det fysiske kort), er fyldt ved at spejle kortets egen papirstruktur ind fra kanten.
4. **Samme papirhvidt** i begge (blækket er uændret i forhold til papiret).

Kontrolbillede: `ref/rider-check.png` (blå | rød | ternet blanding | forskel). Målingerne står i `ios/Cards/rider.json`.

---

## 2. Menuen

**Åbn:** 5 hurtige tryk (inden for 2,5 sek.) i **øverste venstre hjørne** (usynlig zone på 90×90 pt). **Færdig** lukker (første sekund ignoreres). Intet i kameraet viser, at menuen findes.

| Sektion | Indhold |
|---|---|
| Top | Statusmærke **KLAR / FRA / INTET KORT** (+ AFSLØRET), live-forhåndsvisning med sporing (hvidt omrids, grønt = her tegnes målkortet, magenta = finger), fps, match %, dækket %, ms pr. billede, **Effekt aktiv**, *Genskab forklædning nu* |
| Effekt | Forklædning (*Blå vises som rødt* = standard / *Rød vises som blåt*), trigger (Tryk på kortet = standard, Ryst kortet, Tryk hvor som helst, Volumen op, Skjult zone – kan kombineres), ryst-følsomhed (let/normal/hård) med live-måler, overgang, varighed, kantblødhed, **Test afsløring** |
| Genskab forklædning | Én kontakt pr. metode: knap i menuen, skjult zone nederst til venstre (hold 1 sek.), volumen ned, ryst telefonen, dobbelttryk på lukkeren, automatisk efter 3/5/10 sek. uden kort (standard **fra**), altid forklædt når appen åbnes |
| Kort og sporing | Fingerfølsomhed, uskarphed på kortet (så det passer til kameraets skarphed), korn, søg efter kortet (midterfeltet / **omkring midten** / hele billedet), lås eksponering og hvidbalance, vis sporing, nulstil til standard |
| Sløret opstart | Søgeren er sløret ved åbning (og efter baggrund/vend kamera), indtil kortet er fundet og dækket – mindst 0,25 sek., højst 1/**1,5**/2/3 sek. Styrke 0–100 % (standard **85 %**): mere sløring, mørkere og farverne trukket ud, så kortets farve ikke kan anes. Hemmelig markør: **prik ved ⌄ (mere)**, prik ved Live, lille vibration eller ingen. Prikken forsvinder, når kortet er dækket; ses den efter sløringen, er kortet ikke dækket endnu |
| Kamera-realisme | Gitter, vaterlinje, spejl søger, spejl gemte billeder, fokusfirkant, lukkerlyd, lukkerblink, gem i Fotos, testvideo i stedet for kamera |
| Log og selvtest | Seneste tryk (tid, ramte kort ja/nej, hvad der blev vist) og randomiseret selvtest (300 billeder med de ægte kort) |
| PANIK | Rød knap |

**Valg jeg har truffet (ret dem gerne):**
- *Skjult zone* som trigger = et tryk i det sorte felt **til højre for lukkeren**.
- *Skjult zone* som genskab = **hold 1 sek.** nederst til venstre (også på miniaturen; et kort tryk på miniaturen åbner galleriet).
- Volumenknapperne tager et billede (som i Kamera), medmindre de er valgt som trigger/genskab.
- Test afsløring genskaber selv forklædningen efter 2 sek.

---

## 3. Forløbet

1. Telefonen ligger med skærmen op. Hold det **blå** kort 10–15 cm over frontkameraet, så det meste af kortet er i billedet. Det findes ud fra mønstrets farve (fingre over kanten gør ikke noget) og følges derefter, også delvist uden for billedet.
2. Skærmen viser kortet som det **røde** Rider Back (forklædt). Fingre over kortet, baggrund og andre ting er urørte.
3. **Tryk på kortet** på skærmen → forklædningen slukkes med en bølge fra fingeren (0,5 sek.), og den ægte blå farve kommer frem. Tryk ved siden af kortet giver kun den gule fokusfirkant.
4. Afsløret bliver ved, også når kortet forlader billedet, vendes eller dækkes – indtil du genskaber forklædningen.

Er der intet kort i billedet, sker der intet ved tryk (kun fokus).

---

## 4. Sådan virker det

**Kamera:** AVCaptureSession, frontkamera i 4:3 (helst 1440×1080, 30 fps), BGRA, `alwaysDiscardsLateVideoFrames`, portræt, uspejlet. Søgeren spejles i Metal (som Apples frontkamera); gemte billeder er uspejlede som standard.

**Pr. billede (seriel kø):**
1. Nedskalering til ca. 540×720 (fra 1440×1080).
2. **Startgæt:** blækkets farve (blå/rød) i lav opløsning → konvekst hylster → rektangel og trapez om mønstret, plus Vision-firkanter (`VNDetectRectanglesRequest`, 10 Hz når kortet ikke følges sikkert, ellers 2 Hz). Første gang kun gæt med centrum omkring gitterets midterfelt (nærmeste først). Søgning grov → fin: forskydning (±6 px) og derefter drejning ±6°/størrelse ±8 % med lille forskydning (±2 px) og affin start på de groveste niveauer; begge 180°-drejninger prøves. Første fund ca. 90 ms (før 235 ms) på Linux-serveren.
3. **Mønster-sporing** (`CardTracker`): det ægte blå Rider Back (256 px skabelon, samme pixels som PNG'en) lægges ned over kamerabilledet med en **homografi** (perspektiv), fundet med Lucas–Kanade på lysstyrke, grov → fin over 3–4 pyramide-niveauer, med lys-forstærkning og Huber-vægte, så fingre og blænding ikke trækker. Hurtig bevægelse: forskydningssøgning på et groft niveau først. Kortet godtages kun ved korrelation ≥ 0,6 med mønstret og rigtig farve (et rødt kort, en bog eller et billede afvises). Holdes i 4 billeder ved udfald.
4. **Lys:** kamera ≈ forstærkning pr. kanal × skabelon + én fælles forskydning (lineært lys), målt på kortet hvert billede (fanger rummets lys og skærmens røde/blå lys på kortet). Samme lys bruges på målkortet. Lokal lysstyrke (skygge fra hånden) måles også.
5. **Fingre:** hver pixel på kortet sammenlignes med den forventede farve fra skabelonen (farvetone, så skygger ikke tæller; tåler 1 pixels fejl). Det, der ikke passer *og hænger sammen med kortets kant* (fingre kommer altid udefra), er noget over kortet – der vises kameraets eget billede. Pletter midt i mønstret ignoreres.
6. Eksponering og hvidbalance låses, når kortet er set i 5 billeder, og frigøres efter 1,5 sek. uden kort.

**Visning:** Metal (MTKView, CVMetalTextureCache, nul-kopi). Shaderen: kamera → **det ægte røde kort** (1024 px PNG med mipmaps) slået op gennem homografien → kameraets lys og skygge → fingermaske → afsløringens overgang → skærm. Det tegnes over mønstret og den inderste halvdel af den hvide kant; **den yderste halvdel af kanten er altid det fysiske kort**, fordi rigtige kort er skåret lidt forskelligt (hvidt mod hvidt kan ikke ses). Uskarphed og korn kan justeres, så kortet ligner resten af kamerabilledet.

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

**Billeder og video:** lukkeren gemmer det bearbejdede billede (med kortskiftet) i appens eget galleri (miniaturen åbner det). Gem i Fotos er en kontakt (kun tilføj). VIDEO optager søgerens billede med effekten (H.264, uden lyd).

**Batteri og varme:** galleriet stopper kameraet helt. Når menuen er åben, tegnes søgeren ikke; analysen kører videre, fordi forhåndsvisningen skal bruge den. Vision kører højst 10 Hz og kun 2 Hz, mens kortet følges. Panik slår analysen fra.

---

## 5. Panik

**Hold fingeren i øverste venstre hjørne i ca. 1 sekund.** Effekten slås stille fra, og appen er et helt almindeligt kamera. Intet vises. Der er også en rød **PANIK**-knap i menuen. Tænd igen med *Effekt aktiv*.

---

## 6. Kendte begrænsninger

- **Ikke testet på fysisk iPhone.** Testvideoen er syntetisk (men med det ægte kortbillede). Tjek især: kamerabilledets retning/spejling (vinkel 90°), at Vision finder et rigtigt kort, skarphed på kort afstand (frontkameraets fokus), og tiden pr. billede (menuen viser ms; målt ca. 30 ms på en langsom Linux-server, forventet 10–15 ms på iPhone).
- **Kun Bicycle Rider Back.** Andre bagsider findes ikke (korrelationen med mønstret er for lav).
- **Det meste af kortet skal ses først.** Ligger kortet helt tæt på linsen eller mest uden for billedet fra start, findes det ikke. I selvtesten findes 98 % af kortene uden Vision-firkant og med fingre.
- **Fingre over kortet** vises korrekt (kameraets billede). Over det røde kort (omvendt tilstand) ligner hud blækket mere: 93 % af fingerpixels findes i selvtesten mod 99,6 % ved blåt.
- **Stærk refleks** (blankt lys) på kortet bliver set som "noget over kortet" og vises som det ægte kort.
- **Meget svagt lys / uskarpt kort:** mønstret bliver svært at finde; kortet godtages så ikke (ingen forkert visning, bare ingen effekt).
- **iPhone SE** (16:9 uden Face ID): layoutet skaleres ned med sorte kanter i siderne, fordi målene er taget på en 19,5:9-skærm. Den hemmelige zone sidder stadig i skærmens hjørne.
- **Kort der bevæger sig meget hurtigt** (over ca. 25 px mellem to billeder) kan tabes et øjeblik og findes igen af Vision; i de 4 holdte billeder står målkortet stille.
- **App-ikonet** er tegnet (Kamera-agtigt), fordi `ref/hjemmeskaerm.png` mangler. Læg dit hjemmeskærm-screenshot i `ref/` og kør `python3 scripts/extract-icons.py --icon x,y,størrelse`.
- **Video** optages uden lyd (ingen mikrofon-tilladelse). Natfunktion, flash, live og "⋯" er kun udseende (flash med frontkamera giver hvid skærm ved billede).
- Repoets **standard-branch** blev `claude/…` (første push). Sæt den til `main` under Settings → Branches.

---

## 7. Hvad er testet

`ios/KameraPlusTests` (kører på macOS i CI før hver build; lokalt: `cd ios && swift test -c release -Xswiftc -enable-testing`) – **36 tests, alle grønne**:

- **Kortbillederne:** begge skabeloner indlæses med målt geometri; blå er blå og rød er rød; samme papirhvidt; **rødt og blåt mønster flugter** (korrelation 0,97 – én pixels forskydning giver 0,55–0,59).
- **Homografi:** fra 4 punkter, invers, sammensætning.
- **Sporing** (det ægte kort i syntetiske scener med perspektiv, farvet lys, støj): låser fra en firkant med 4 px støj til **0,05 px hjørnefejl**; følger et kort i bevægelse i 12 billeder uden nye firkanter; finger set som dækket (100 %) og kortet ikke (< 2 %); rødt kort og tom firkant afvises; holder 4 billeder og slipper så.
- **Overgange:** easing og afsløring monoton i tiden for alle fire typer, bølge fra fingeren til kortets hjørner, hårdt klip, fej oppefra.
- **Tilstandsmaskine:** tryk på/ved siden af kortet, intet kort = ingen afsløring, kun valgte triggere, genskab-metoder, automatisk genskab kun efter nok tid uden kort (og fra som standard), kortet forlader billedet 300 gange uden at falde tilbage, panik, opstart, eksponeringslås.
- **Ryst:** 2,5/3/4 Hz rysten og drejerysten udløser; roligt flyt, frem-og-tilbage én gang, løft, vipning, drejning, støj og skub til bordet gør ikke; nedkøling 2 sek.; følsomhed.
- **Bevægelse/geometri:** orientering med hysterese, vaterlinje, ryst telefonen, stilstand, omregning søger ↔ billede (spejlet, beskåret), firkanter.
- **Randomiseret selvtest** (fast seed, ægte kortbilleder, 360×480: tilfældig placering/drejning/perspektiv, baggrunde, hudtoner, 0–2 fingre, rum- og skærmlys, uskarphed, støj; Vision-agtigt startgæt med 1,2 % støj; 10 % det andet kort, 20 % tomme firkanter) – kan også køres i appen:

```
600 billeder (420 med blåt kort, 60 med det andet kort, 120 uden)
Kort ikke fundet: 1 (0,2 %)
Hjørnefejl: median 0,16 px, 95 % 1,13 px
Fingre fundet: 99,6 % · kort fejlagtigt dækket: gns. 0,7 %, 95 % 1,7 %
Falske kort (tomme firkanter): 0 (0,0 %) · forkert farve godtaget: 0 (0,0 %)
```
Rødt kort vist som blåt (300 billeder): 0,5 % ikke fundet, hjørnefejl median 0,08 px, fingre 93,3 %, ingen falske.

**CI** kører kun de hurtige logik-tests og bygger IPA'en (ca. 3 min). Selvtesten og UI-testene køres lokalt/manuelt.

**UI-tests** (køres ikke i CI; `ios/KameraPlusUITests`, iPhone 17 Pro-simulator med iOS 26.2, Release-byg, testvideo i stedet for kamera) – **6 tests, alle grønne**: 5 tryk øverst til venstre åbner menuen, 4 tryk gør ikke, 5 tryk over 3 sek. gør ikke, 5 tryk øverst til højre gør intet, "Færdig" ignoreres i spærretiden (testen forlænger den til 4 sek. med `-doneDelay`, fordi simulatoren er for langsom til at ramme 1 sek. præcist), panik (hold 1,4 sek.) slår effekten fra. CI fejler på røde tests.

**Ikke testet automatisk:** selve kameraet (AVFoundation), Vision på rigtige kort, sporing på et rigtigt kamerabillede, Metal-billedet på en rigtig skærm, lukker/galleri/video og volumenknapper – det kræver en fysisk iPhone.

---

## Filer
```
ios/project.yml                 XcodeGen (app, logik-tests på macOS, UI-tests)
ios/Package.swift               kun til at køre logik-testene lokalt (fx Linux)
ios/Cards/                      de ægte kortbilleder (rider-blue/red .png 1024 px, .rgb 256 px) + rider.json
ios/KameraPlus/Logic/           ren logik uden UI (testet)
  CardTemplate, Homography      kortskabeloner, pyramider, geometri; homografier
  CardTracker                   mønster-sporing, lys, fingermaske
  Geometry, ColorMath, Image    firkanter, søger ↔ billede, sRGB/lineær, nedskalering
  Transition, EffectState       overgange, tilstandsmaskine, eksponeringslås
  Shake, Synthetic, SelfTest    ryst/bevægelse, syntetiske scener med de ægte kort, selvtest
ios/KameraPlus/App/             iOS (SwiftUI, AVFoundation, Metal, Vision, CoreMotion)
  Engine.swift                  binder alt sammen (som Engine i MindTrace)
  Pipeline.swift                arbejde pr. kamerabillede
  FrameSource.swift             kamera + syntetisk testvideo (FrameSource-protokol)
  Renderer.swift, Shaders.metal Metal-søger, billeder og video
  RectangleTracker.swift        Vision (kun startgæt)
  CameraUI.swift                kamera-klonen (alle mål i enum L)
  SecretPanel.swift             hemmelig menu
  Gallery.swift                 eget galleri
  AppSettings, Haptics, VolumeButtons, MotionManager
ios/KameraPlusTests/            logik-tests
ios/KameraPlusUITests/          UI-tests
.github/workflows/ipa.yml       test → build → IPA → release → SideStore-kilde
scripts/prepare-cards.py        kortbillederne fra ref/rider-*.jpg (pip install opencv-python-headless numpy)
scripts/extract-icons.py        glyffer (og ikon) skåret ud af ref/
scripts/make-icon.py            tegnet Kamera-ikon (indtil hjemmeskærm-screenshot)
scripts/make_source.py          SideStore-kilde
ref/                            dine screenshots og kortreferencer, rider-check.png
```
