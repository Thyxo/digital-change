import Foundation

struct SelfTestReport {
    var images = 0
    var cardImages = 0
    var noCardImages = 0
    var iouSum = 0.0
    var ious: [Double] = []
    var missedCards = 0
    var falsePositives = 0
    var transferChecks = 0
    var transferDeltaESum = 0.0
    var transferDeltaEMax = 0.0
    var skinMaxChange = 0.0
    var seconds = 0.0
    var reverse = false
    /// Eksempler på fejl (til fejlsøgning).
    var notes: [String] = []

    var meanIoU: Double { ious.isEmpty ? 0 : iouSum / Double(ious.count) }
    var p05IoU: Double {
        guard !ious.isEmpty else { return 0 }
        let s = ious.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * 0.05))]
    }
    var falsePositiveRate: Double { noCardImages == 0 ? 0 : Double(falsePositives) / Double(noCardImages) }
    var missRate: Double { cardImages == 0 ? 0 : Double(missedCards) / Double(cardImages) }
    var meanTransferDeltaE: Double { transferChecks == 0 ? 0 : transferDeltaESum / Double(transferChecks) }

    /// Omvendt tilstand (rødt kort vist som blåt) tåler flere falske positiver: lys/rosa hud ligger tæt på et
    /// rødt kort i lav opløsning. Huden farves aldrig om (hudbeskyttelse), men kan tælle som "kort set".
    var passed: Bool {
        meanIoU >= 0.9 && p05IoU >= 0.75 && falsePositiveRate <= (reverse ? 0.08 : 0.005) && missRate <= 0.01
            && meanTransferDeltaE <= 6 && skinMaxChange <= 1.5
    }

    /// Kort dansk opsummering til menuen og CI-loggen.
    var lines: [String] {
        func pct(_ v: Double) -> String { String(format: "%.1f %%", v * 100) }
        return [
            "\(images) billeder (\(cardImages) med kort, \(noCardImages) uden)\(reverse ? ", omvendt" : "") · \(String(format: "%.1f", seconds)) s",
            "Maske IoU: gns. \(String(format: "%.3f", meanIoU)), 5 %-fraktil \(String(format: "%.3f", p05IoU))",
            "Kort ikke fundet: \(missedCards) (\(pct(missRate)))",
            "Falske positiver (hud, træ, væg …): \(falsePositives) (\(pct(falsePositiveRate)))",
            "Farveskift ΔE mod ægte kort: gns. \(String(format: "%.2f", meanTransferDeltaE)), maks \(String(format: "%.2f", transferDeltaEMax))",
            "Største ændring af hud: ΔE \(String(format: "%.2f", skinMaxChange))",
            passed ? "BESTÅET" : "IKKE BESTÅET",
        ]
    }
}

/// Randomiseret selvtest: tusindvis af syntetiske kortbilleder (fast seed) gennem hele den rene kæde:
/// kalibrering → klassifikator → maske → farveskift.
enum SelfTest {
    static let blueInk = RGB8(hex: Palette.defaultBlueHex)
    static let redInk = RGB8(hex: Palette.defaultRedHex)

    static func run(count: Int = 5000, seed: UInt64 = 2026, width: Int = 72, height: Int = 96,
                    reverse: Bool = false, progress: ((Double) -> Void)? = nil) -> SelfTestReport {
        let started = Date()
        var report = SelfTestReport()
        report.reverse = reverse
        let srcInk = reverse ? redInk : blueInk
        let dstInk = reverse ? blueInk : redInk

        // 1) "Lær kort" på syntetiske kalibreringsbilleder
        let srcCal = Synth.render(Synth.calibrationScene(width: width * 2, height: height * 2, ink: srcInk, fineLines: true)).image
        let dstCal = Synth.render(Synth.calibrationScene(width: width * 2, height: height * 2, ink: dstInk, fineLines: true)).image
        guard let src = PaletteLearner.learn([srcCal]).palette, let dst = PaletteLearner.learn([dstCal]).palette else {
            return report
        }
        let classifier = CardClassifier(source: src, sensitivity: 0.5)
        let analyzer = CardAnalyzer(classifier: classifier)
        analyzer.illumination = IlluminationModel(source: src, target: dst)
        let transfer = ColorTransfer(source: src, target: dst)

        var rng = SplitMix64(seed: seed)
        for i in 0..<count {
            let withCard = i % 3 != 2
            var ink = srcInk
            if withCard {
                func jitter(_ v: UInt8) -> UInt8 { UInt8(min(255, max(0, Double(v) + rng.range(-10, 10)))) }
                ink = RGB8(jitter(ink.r), jitter(ink.g), jitter(ink.b))
            }
            var scene = Synth.randomScene(&rng, width: width, height: height, ink: withCard ? ink : nil,
                                          avoidHue: src.hue, fingers: 2, fineLines: true)
            // Realistisk lys fra skærmen: først viser søgeren kortets ægte farve (lys i kildens farve),
            // så tændes forklædningen, og skærmen lyser kortet op i målets farve.
            scene.cardTint = Synth.screenLight(ink: srcInk, amount: rng.range(0, 0.4), rng: &rng)
            let before = Synth.render(scene)
            scene.cardTint = Synth.screenLight(ink: dstInk, amount: rng.range(0, 0.6), rng: &rng)
            let out = Synth.render(scene)
            var quads: [Quad] = []
            let useQuad = withCard && rng.chance(0.5)
            if useQuad, let c = scene.card {
                // Vision-firkant med lidt rystelse
                quads = [Quad(corners: c.quad.corners.map { Point2($0.x + rng.range(-1, 1), $0.y + rng.range(-1, 1)) })]
            }
            analyzer.reset()
            var res = MaskResult()
            for _ in 0..<3 { res = analyzer.analyze(before.image, quads: quads) }
            for _ in 0..<4 { res = analyzer.analyze(out.image, quads: quads) }
            report.images += 1

            if withCard {
                report.cardImages += 1
                if !res.cardVisible { report.missedCards += 1 }
                let core = analyzer.processor!.core
                let gt = res.quad != nil ? out.cardMask : out.inkMask
                let iou = MaskMetrics.iou(core, gt)
                report.ious.append(iou)
                report.iouSum += iou
                if iou < 0.6 {
                    report.notes.append(String(format: "#%d IoU %.2f på %@ %@ (kortlys %.2f/%.2f/%.2f, k %.2f, dækning %.2f, hel %@, fingre %d, firkant %@)",
                        i, iou, scene.backdrop.rawValue, scene.backdropColor.hex,
                        scene.cardTint.0, scene.cardTint.1, scene.cardTint.2, analyzer.k, res.coverage, res.fullFrame ? "ja" : "nej",
                        scene.fingers.count, useQuad ? "ja" : "nej"))
                }

                if i % 10 == 0 {
                    checkTransfer(scene: scene, mask: res.mask, gain: analyzer.gain, transfer: transfer, dstInk: dstInk, report: &report)
                }
            } else {
                report.noCardImages += 1
                if res.cardVisible || res.coverage > 0.005 {
                    report.falsePositives += 1
                    report.notes.append("#\(i) falsk positiv på \(scene.backdrop.rawValue) \(scene.backdropColor.hex), k \(String(format: "%.2f", analyzer.k)), fingre \(scene.fingers.count)")
                }
            }
            if let progress, i % 100 == 0 { progress(Double(i) / Double(count)) }
        }
        report.seconds = Date().timeIntervalSince(started)
        progress?(1)
        return report
    }

    /// Samme scene og samme lys (uden støj): det skiftede kildekort sammenlignet med det ægte målkort.
    private static func checkTransfer(scene: SynthScene, mask: [UInt8], gain: ChannelGain, transfer: ColorTransfer, dstInk: RGB8,
                                      report: inout SelfTestReport) {
        var s = scene
        s.noise = 0
        let a = Synth.render(s)
        s.card?.ink = dstInk
        let b = Synth.render(s)
        let weight = mask.map { Double($0) / 255 }
        let moved = transfer.apply(to: a.image, weight: weight, gain: gain)
        var sa = LabStats(), sb = LabStats()
        var skin = 0.0
        for i in 0..<(s.width * s.height) {
            let k = i * 4
            if a.inkMask[i] {
                let p = ColorMath.lab(moved.pixels[k], moved.pixels[k + 1], moved.pixels[k + 2])
                let q = ColorMath.lab(b.image.pixels[k], b.image.pixels[k + 1], b.image.pixels[k + 2])
                sa.add(p); sb.add(q)
            }
            if a.fingerMask[i] {
                let p = ColorMath.lab(a.image.pixels[k], a.image.pixels[k + 1], a.image.pixels[k + 2])
                let q = ColorMath.lab(moved.pixels[k], moved.pixels[k + 1], moved.pixels[k + 2])
                skin = max(skin, ColorMath.deltaE(p, q))
            }
        }
        guard sa.n > 20 else { return }
        let d = ColorMath.deltaE(sa.mean, sb.mean)
        report.transferChecks += 1
        report.transferDeltaESum += d
        report.transferDeltaEMax = max(report.transferDeltaEMax, d)
        report.skinMaxChange = max(report.skinMaxChange, skin)
    }
}
