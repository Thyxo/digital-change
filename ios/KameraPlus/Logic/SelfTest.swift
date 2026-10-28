import Foundation

struct SelfTestReport {
    var images = 0
    var cardImages = 0
    var noCardImages = 0
    var otherColorImages = 0
    var missed = 0
    var falseAccepts = 0
    var otherColorAccepts = 0
    /// Største hjørnefejl pr. billede (px i analysebilledet).
    var cornerErrors: [Double] = []
    /// Andel af fingrenes pixels i overlay-området, der blev set som dækket (bør være ~1).
    var fingerHits: [Double] = []
    /// Andel af kortets synlige pixels, der fejlagtigt blev set som dækket (bør være ~0).
    var falseOcclusion: [Double] = []
    var seconds = 0.0
    var source: CardColor = .blue
    var notes: [String] = []

    private func quantile(_ a: [Double], _ q: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }
    private func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

    var missRate: Double { cardImages == 0 ? 0 : Double(missed) / Double(cardImages) }
    var falseAcceptRate: Double { noCardImages == 0 ? 0 : Double(falseAccepts) / Double(noCardImages) }
    var otherColorRate: Double { otherColorImages == 0 ? 0 : Double(otherColorAccepts) / Double(otherColorImages) }
    var cornerMedian: Double { quantile(cornerErrors, 0.5) }
    var cornerP95: Double { quantile(cornerErrors, 0.95) }
    var fingerMean: Double { mean(fingerHits) }
    var falseOcclusionMean: Double { mean(falseOcclusion) }
    var falseOcclusionP95: Double { quantile(falseOcclusion, 0.95) }

    var passed: Bool {
        missRate <= 0.03 && falseAcceptRate <= 0.01 && otherColorRate <= 0.02
            && cornerMedian <= 0.6 && cornerP95 <= 1.6
            && fingerMean >= 0.9 && falseOcclusionMean <= 0.02 && falseOcclusionP95 <= 0.06
    }

    /// Kort dansk opsummering til menuen og CI-loggen.
    var lines: [String] {
        func pct(_ v: Double) -> String { String(format: "%.1f %%", v * 100) }
        return [
            "\(images) billeder (\(cardImages) med \(source == .blue ? "blåt" : "rødt") kort, \(otherColorImages) med det andet kort, \(noCardImages) uden) · \(String(format: "%.1f", seconds)) s",
            "Kort ikke fundet: \(missed) (\(pct(missRate)))",
            "Hjørnefejl: median \(String(format: "%.2f", cornerMedian)) px, 95 % \(String(format: "%.2f", cornerP95)) px",
            "Fingre fundet: \(pct(fingerMean)) · kort fejlagtigt dækket: gns. \(pct(falseOcclusionMean)), 95 % \(pct(falseOcclusionP95))",
            "Falske kort (tomme firkanter): \(falseAccepts) (\(pct(falseAcceptRate))) · forkert farve godtaget: \(otherColorAccepts) (\(pct(otherColorRate)))",
            passed ? "BESTÅET" : "IKKE BESTÅET",
        ]
    }
}

/// Randomiseret selvtest: syntetiske billeder med de ægte Rider Back-skabeloner (fast seed) gennem hele sporingen:
/// startgæt (Vision-agtig firkant med støj) → mønster-justering → verifikation → lys → fingermaske.
enum SelfTest {
    static func run(templates: CardTemplates, source: CardColor = .blue, count: Int = 600, seed: UInt64 = 2026,
                    width: Int = 360, height: Int = 480, progress: ((Double) -> Void)? = nil) -> SelfTestReport {
        let started = Date()
        var report = SelfTestReport()
        report.source = source
        let src = templates.of(source), other = templates.of(source.other)
        let tracker = CardTracker(template: src)
        var rng = SplitMix64(seed: seed)

        for i in 0..<count {
            let kind = i % 10   // 0–6 kort, 7 andet kort, 8–9 intet kort
            let t: CardTemplate? = kind <= 6 ? src : (kind == 7 ? other : nil)
            let scene = Synth.randomScene(&rng, width: width, height: height, card: t, fingers: 2)
            let out = Synth.render(scene)
            var cand: [Quad] = []
            if let c = scene.card {
                // halvdelen uden Vision-firkant: kortet skal findes ud fra blækkets farve alene
                let noisy = Synth.noisyQuad(c.quad, rng: &rng, sigma: 0.012 * c.quad.shortSide)
                cand = i % 2 == 0 ? [] : [noisy]
            } else {
                // en tom firkant (fx en bog eller et billede) af kortstørrelse
                let cw = rng.range(0.35, 0.65) * Double(width)
                let q = Quad.rect(center: Point2(rng.range(0.35, 0.65) * Double(width), rng.range(0.4, 0.6) * Double(height)),
                                  width: cw, height: cw * 1.39, angle: rng.range(-0.5, 0.5))
                cand = [q]
            }
            tracker.reset()
            let r = tracker.update(out.image, candidates: cand)
            report.images += 1

            switch kind {
            case 0...6:
                report.cardImages += 1
                guard let tr = r.track, let c = scene.card else {
                    report.missed += 1
                    if report.notes.count < 30 { report.notes.append("#\(i) ikke fundet (\(scene.backdrop.rawValue), fingre \(scene.fingers.count), blur \(scene.card?.blur ?? 0)): \(tracker.lastReject)") }
                    continue
                }
                var err = 0.0
                for (a, b) in zip(tr.quad.corners, c.quad.corners) { err = max(err, a.distance(b)) }
                // 180°-symmetrisk mønster: drejet 180° er også rigtigt for mønstret, men hjørnerne byttes
                let rot = zip(tr.quad.corners, c.quad.corners.suffix(2) + c.quad.corners.prefix(2)).map { $0.distance($1) }.max() ?? .infinity
                err = min(err, rot)
                report.cornerErrors.append(err)
                if err > 2, report.notes.count < 30 { report.notes.append(String(format: "#%d hjørnefejl %.2f px", i, err)) }
                // fingermaske
                var fingerTotal = 0, fingerHit = 0, cardTotal = 0, cardFalse = 0
                for y in 0..<height {
                    for x in 0..<width {
                        let j = y * width + x
                        guard out.fingerMask[j] || out.overlayMask[j] else { continue }
                        let vx = min(r.visWidth - 1, x / r.visScale), vy = min(r.visHeight - 1, y / r.visScale)
                        let v = r.visibility[vy * r.visWidth + vx]
                        if out.fingerMask[j] { fingerTotal += 1; if v < 128 { fingerHit += 1 } }
                        if out.overlayMask[j] { cardTotal += 1; if v < 128 { cardFalse += 1 } }
                    }
                }
                // kun fingre der dækker mere end lidt (kantpixels i halv opløsning er usikre)
                if fingerTotal > 60 { report.fingerHits.append(Double(fingerHit) / Double(fingerTotal)) }
                if cardTotal > 0 {
                    let fo = Double(cardFalse) / Double(cardTotal)
                    report.falseOcclusion.append(fo)
                    if fo > 0.05, report.notes.count < 30 {
                        report.notes.append(String(format: "#%d %.1f %% af kortet set som dækket (%@, gain %.2f/%.2f/%.2f)", i, fo * 100,
                                                   scene.backdrop.rawValue, tr.gain.x, tr.gain.y, tr.gain.z))
                    }
                }
            case 7:
                report.otherColorImages += 1
                if r.track != nil {
                    report.otherColorAccepts += 1
                    if report.notes.count < 30 { report.notes.append("#\(i) andet kort godtaget") }
                }
            default:
                report.noCardImages += 1
                if r.track != nil {
                    report.falseAccepts += 1
                    if report.notes.count < 30 { report.notes.append("#\(i) falsk kort på \(scene.backdrop.rawValue)") }
                }
            }
            if let progress, i % 20 == 0 { progress(Double(i) / Double(count)) }
        }
        report.seconds = Date().timeIntervalSince(started)
        progress?(1)
        return report
    }
}
