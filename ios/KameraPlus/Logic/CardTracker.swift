import Foundation

/// Kortets placering og lys i ét billede.
struct CardTrack: Equatable {
    /// Kanoniske kortkoordinater → billedets pixels.
    var homography: Homography
    /// Mønstrets overensstemmelse med skabelonen (normaliseret krydskorrelation, 0…1).
    var score: Double
    /// Lineært lys pr. kanal: kamera ≈ gain · skabelon + offset (målt på kortet, bruges på målkortet).
    var gain: SIMD3<Double>
    var offset: SIMD3<Double>
    /// Kortets hjørner i billedets pixels.
    var quad: Quad
}

/// Resultat for ét billede.
struct TrackerOutput {
    var track: CardTrack?
    /// true når kortet er fundet i netop dette billede (false = holdt fra tidligere billede).
    var fresh = false
    /// Synlighed i halv opløsning: 255 = kortet ses (tegn over), 0 = noget dækker (fx en finger).
    var visibility: [UInt8] = []
    /// Lokal lysstyrke på kortet (128 = gennemsnit) – skygger og blænding fra hånden.
    var shade: [UInt8] = []
    var visWidth = 0
    var visHeight = 0
    /// Billedpixels pr. synligheds-pixel.
    var visScale = 2
    /// Andel af overlay-området, der er dækket.
    var occluded = 0.0
}

struct TrackerConfig: Equatable {
    /// 0…1: højere = flere pixels regnes for fingre (dækker kortet).
    var occlusionSensitivity = 0.5
    /// Hvor mange billeder et tabt kort holdes, før forklædningen slukkes (som den gamle maske: 4).
    var holdFrames = 8
    /// Mønster-korrelation for at finde kortet første gang og for at blive ved med at følge det
    /// (lavere, så bevægelsesslør ikke taber kortet).
    var acceptScore = 0.6
    var keepScore = 0.42
    /// Hvor kortets centrum skal ligge, når det findes første gang (billedets pixels). nil = hele billedet.
    /// Følges kortet, må det bevæge sig frit.
    var searchRegion: RectD?
}

/// Finder og følger det fysiske Rider Back-kort ved at lægge skabelonens mønster præcist ned over kameraets billede
/// (Lucas–Kanade med homografi og lys-forstærkning, grov → fin), og måler bagefter lyset og hvad der dækker kortet.
/// Vision-firkanter bruges kun som startgæt.
final class CardTracker {
    let template: CardTemplate
    var config = TrackerConfig()

    private struct LKPoint { var qx: Double; var qy: Double; var t: Double }
    private var points: [[LKPoint]] = []
    private let N: Homography      // kanonisk → normaliseret (−1…1 i bredden)
    private let Ninv: Homography

    private var last: CardTrack?
    private var lastOutput: TrackerOutput?
    private var prevCorners: [Point2]?
    private var missed = 0
    private var prevOcc: [Float] = []

    private(set) var lastAlignMs = 0.0
    /// Hvorfor det seneste forsøg blev afvist (til selvtest og fejlsøgning).
    private(set) var lastReject = ""

    init(template: CardTemplate) {
        self.template = template
        let g = template.geometry
        let s = g.width / 2
        N = Homography.scale(1 / s, 1 / s, tx: -g.width / 2 / s, ty: -g.height / 2 / s)
        Ninv = Homography.scale(s, s, tx: g.width / 2, ty: g.height / 2)
        points = (0..<template.luma.count).map { selectPoints(level: $0) }
    }

    func reset() {
        last = nil; lastOutput = nil; prevCorners = nil; missed = 0; prevOcc = []
    }

    var isTracking: Bool { last != nil }

    /// Punkter med tydelig gradient i skabelonen (lokale maksima i små celler), inden for kortet.
    private func selectPoints(level l: Int) -> [LKPoint] {
        let L = template.luma[l], k = template.scale(level: l), g = template.geometry
        let cell = [5, 3, 2, 1][min(l, 3)]
        var out: [LKPoint] = []
        let inset = max(2.5 / k, 0.03 * g.width)
        var cy = 1
        while cy < L.height - 1 {
            var cx = 1
            while cx < L.width - 1 {
                var best = -1, bestG: Float = 0.035
                for y in cy..<min(cy + cell, L.height - 1) {
                    for x in cx..<min(cx + cell, L.width - 1) {
                        let i = y * L.width + x
                        let gx = L.data[i + 1] - L.data[i - 1], gy = L.data[i + L.width] - L.data[i - L.width]
                        let m = (gx * gx + gy * gy).squareRoot() * 0.5
                        if m > bestG { bestG = m; best = i }
                    }
                }
                if best >= 0 {
                    let x = best % L.width, y = best / L.width
                    let u = (Double(x) + 0.5) / k, v = (Double(y) + 0.5) / k
                    if g.cardDistance(Point2(u, v)) < -inset {
                        let q = N.apply(Point2(u, v))
                        out.append(LKPoint(qx: q.x, qy: q.y, t: Double(L.data[best])))
                    }
                }
                cx += cell
            }
            cy += cell
        }
        return out
    }

    // MARK: Pr. billede

    /// `image`: kamerabilledet (fx 540×720). `candidates`: Vision-firkanter i samme pixels.
    func update(_ image: RGBAImage, candidates: [Quad] = []) -> TrackerOutput {
        let t0 = Date()
        let pyr = Luma.pyramid(Luma.image(image), levels: 5)
        var found: (CardTrack, Double)?

        if let prev = last {
            // forudsig med hjørnernes hastighed (dæmpet)
            var start = prev.homography
            if let pc = prevCorners {
                let now = prev.quad.corners
                let pred = (0..<4).map { now[$0] + (now[$0] - pc[$0]) * 0.6 }
                if let h = Homography.from(template.geometry.corners, to: pred) { start = h }
            }
            if let r = align(start, pyr: pyr, coarseOnly: false, search: true), verify(r, minScore: config.keepScore) {
                found = (r.track, r.inliers)
            }
            if found == nil || found!.0.score < 0.7 {
                let cands = candidates + (found == nil ? inkCandidates(image) : [])
                if !cands.isEmpty, let c = bestCandidate(cands, pyr: pyr), found == nil || c.0.score > found!.0.score + 0.03 { found = c }
            }
        } else {
            // startgæt: blækkets farve (virker også når fingre dækker kanten) + Vision-firkanter,
            // kun omkring midten (søgeområdet) og nærmeste først
            let cands = nearCenter(inkCandidates(image) + candidates)
            if !cands.isEmpty { found = bestCandidate(cands, pyr: pyr) }
        }

        var out = TrackerOutput()
        if var (track, _) = found {
            let vis = visibility(track, image: image)
            if vis.colorOK {
                if let l = last {
                    // glat lyset lidt over tid (ikke geometrien – den skal følge kortet præcist)
                    track.gain = l.gain * 0.5 + vis.gain * 0.5
                    track.offset = l.offset * 0.5 + vis.offset * 0.5
                } else {
                    track.gain = vis.gain; track.offset = vis.offset
                }
                prevCorners = last?.quad.corners
                last = track
                missed = 0
                out = vis.output
                out.track = track
                out.fresh = true
                lastOutput = out
            } else {
                lastReject = String(format: "farve (gain %.2f/%.2f/%.2f)", vis.gain.x, vis.gain.y, vis.gain.z)
                found = nil
            }
        }
        if found == nil {
            missed += 1
            if missed <= config.holdFrames, var held = lastOutput {
                held.fresh = false
                out = held
            } else {
                last = nil; lastOutput = nil; prevCorners = nil; prevOcc = []
            }
        }
        lastAlignMs = Date().timeIntervalSince(t0) * 1000
        return out
    }

    // MARK: Startgæt fra firkanter

    /// Gæt med centrum i søgeområdet, sorteret efter afstand til områdets midte (færre gæt = hurtigere fund,
    /// og fx en blå trøje i kanten af billedet forstyrrer ikke).
    func nearCenter(_ cands: [Quad]) -> [Quad] {
        guard let r = config.searchRegion else { return cands }
        let c = r.center
        return cands
            .filter { let p = $0.centroid; return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY }
            .sorted { $0.centroid.distance(c) < $1.centroid.distance(c) }
    }

    /// Gitter-søgning for et startgæt: drejning ±6°, størrelse ±8 % (om kortets centrum) og forskydning
    /// på et groft niveau (kortet ca. 40–80 px bredt). Returnerer den homografi, hvis mønster passer bedst.
    private func searchInit(_ h: Homography, pyr: [GrayImage]) -> Homography {
        let cw = cardWidth(h)
        guard cw.isFinite, cw > 12 else { return h }
        var k = 0
        while k + 1 < pyr.count && cw / Double(1 << (k + 1)) >= 40 { k += 1 }
        let s = 1.0 / Double(1 << k)
        let tl = template.level(forPixelsPerUnit: cw * s / template.geometry.width)
        let g = template.geometry
        let cx = g.width / 2, cy = g.height / 2
        // grov → fin: først forskydningen alene (drejning om centrum flytter ikke centrum), så drejning og størrelse
        // med en lille forskydning omkring den. Ca. 5× hurtigere end hele gitteret med fuld forskydning.
        let S = Homography.scale(s, s)
        let (shifted, s0) = translationSearchScored(S * h * Ninv, cam: pyr[k], pts: points[tl], radius: 6)
        let h0 = Homography.scale(1 / s, 1 / s) * shifted * N
        var best = (h0, s0)
        for deg in [-6.0, -3, 0, 3, 6] {
            for sc in [0.92, 0.96, 1.0, 1.04, 1.08] where deg != 0 || sc != 1 {
                let a = deg * .pi / 180
                let ca = cos(a) * sc, sa = sin(a) * sc
                // drejning + skalering om kortets centrum (kanoniske koordinater)
                let R = Homography([ca, -sa, cx - ca * cx + sa * cy, sa, ca, cy - sa * cx - ca * cy, 0, 0, 1])
                let Hn = S * h0 * R * Ninv
                let (moved, score) = translationSearchScored(Hn, cam: pyr[k], pts: points[tl], radius: 2)
                if score > best.1 { best = (Homography.scale(1 / s, 1 / s) * moved * N, score) }
            }
        }
        return best.0
    }

    private func bestCandidate(_ cands: [Quad], pyr: [GrayImage]) -> (CardTrack, Double)? {
        var coarse: [Aligned] = []
        for q in cands.prefix(5) where q.area > 400 {
            let c = q.corners
            let side01 = (c[0].distance(c[1]) + c[2].distance(c[3])) / 2
            let side12 = (c[1].distance(c[2]) + c[3].distance(c[0])) / 2
            // kortets korte side (top) skal ligge på firkantens korte side; begge 180°-drejninger prøves
            let rots = side01 <= side12 ? [0, 2] : [1, 3]
            for r in rots {
                let dst = (0..<4).map { c[($0 + r) % 4] }
                guard let h = Homography.from(template.geometry.corners, to: dst) else { continue }
                // startgættet kan ligge lidt ved siden af (farve-rektangel, Vision på afrundede hjørner):
                // søg drejning, størrelse og forskydning på et groft niveau, så justerer LK resten
                let bestA = align(searchInit(h, pyr: pyr), pyr: pyr, coarseOnly: true, search: false)
                if let a = bestA { coarse.append(a) }
            }
        }
        // mønstret er næsten 180°-symmetrisk, så de to bedste justeres helt, og den bedste til sidst vinder
        var best: Aligned?
        for a in coarse.sorted(by: { $0.track.score > $1.track.score }).prefix(2) {
            guard let full = align(a.track.homography, pyr: pyr, coarseOnly: false), verify(full) else { continue }
            if best == nil || full.track.score > best!.track.score { best = full }
        }
        guard let b = best else { return nil }
        return (b.track, b.inliers)
    }

    // MARK: Lucas–Kanade

    private struct Aligned {
        var track: CardTrack
        var alpha: Double
        var inliers: Double
        var valid: Double
    }

    private func cardWidth(_ h: Homography) -> Double {
        let q = h.quad(width: template.geometry.width, height: template.geometry.height)
        return (q.corners[0].distance(q.corners[1]) + q.corners[3].distance(q.corners[2])) / 2
    }

    /// Justerer homografien (kanonisk → billede) grov → fin. `coarseOnly`: kun det groveste niveau (til at vælge startgæt).
    private func align(_ start: Homography, pyr: [GrayImage], coarseOnly: Bool, search: Bool = false) -> Aligned? {
        var H = start
        let cw0 = cardWidth(H)
        guard cw0.isFinite, cw0 > 12 else { return nil }
        var kStart = 0
        while kStart + 1 < pyr.count && cw0 / Double(1 << (kStart + 1)) >= 56 { kStart += 1 }
        // startgæt: også de grovere niveauer (kortet ned til ca. 24 px), hvor mønstret er glat og fangområdet stort
        var kFirst = kStart
        if coarseOnly { while kFirst + 1 < pyr.count && cw0 / Double(1 << (kFirst + 1)) >= 24 { kFirst += 1 } }
        let levels = coarseOnly ? Array(stride(from: kFirst, through: kStart, by: -1)) : Array(stride(from: kStart, through: 0, by: -1))
        if search {
            // hurtig bevægelse: søg forskydningen på et grovere (glattere) niveau end første justering
            let ks = min(kStart + 1, pyr.count - 1)
            let s = 1.0 / Double(1 << ks)
            let tl = template.level(forPixelsPerUnit: cw0 * s / template.geometry.width)
            let Hs = translationSearch(Homography.scale(s, s) * H * Ninv, cam: pyr[ks], pts: points[tl], radius: 10)
            H = Homography.scale(1 / s, 1 / s) * Hs * N
        }
        var alpha = 0.0, beta = 0.0, haveAB = false
        var stats = (ncc: 0.0, inliers: 0.0, valid: 0.0)
        for k in levels {
            let s = 1.0 / Double(1 << k)
            let S = Homography.scale(s, s), Sinv = Homography.scale(1 / s, 1 / s)
            let ppu = cardWidth(H) * s / template.geometry.width
            let tl = template.level(forPixelsPerUnit: ppu)
            let pts = points[tl]
            var Hn = S * H * Ninv
            let its = k == kStart ? 14 : 7
            if k == kFirst && coarseOnly {
                // startgæt: først kun affin (større fangområde), så fuld homografi
                guard gaussNewton(&Hn, cam: pyr[k], pts: pts, iterations: 10, alpha: &alpha, beta: &beta, haveAB: &haveAB, affine: true) != nil
                else { return nil }
            }
            guard let st = gaussNewton(&Hn, cam: pyr[k], pts: pts, iterations: its, alpha: &alpha, beta: &beta, haveAB: &haveAB) else {
                return nil
            }
            stats = st
            H = Sinv * Hn * N
        }
        guard cardWidth(H).isFinite else { return nil }
        let quad = H.quad(width: template.geometry.width, height: template.geometry.height)
        let track = CardTrack(homography: H, score: max(0, stats.ncc), gain: SIMD3(1, 1, 1), offset: SIMD3(0, 0, 0), quad: quad)
        return Aligned(track: track, alpha: alpha, inliers: stats.inliers, valid: stats.valid)
    }

    /// Grov søgning efter forskydning (hurtig bevægelse mellem to billeder): bedste korrelation over et gitter.
    private func translationSearch(_ Hn: Homography, cam: GrayImage, pts: [LKPoint], radius: Int) -> Homography {
        translationSearchScored(Hn, cam: cam, pts: pts, radius: radius).0
    }

    private func translationSearchScored(_ Hn: Homography, cam: GrayImage, pts: [LKPoint], radius: Int) -> (Homography, Double) {
        let m = Hn.m
        var base: [(Double, Double, Double)] = []
        var i = 0
        while i < pts.count {
            let p = pts[i]
            let w = m[6] * p.qx + m[7] * p.qy + m[8]
            if w > 1e-6 {
                base.append(((m[0] * p.qx + m[1] * p.qy + m[2]) / w, (m[3] * p.qx + m[4] * p.qy + m[5]) / w, p.t))
            }
            i += 2
        }
        guard base.count > 30 else { return (Hn, -1) }
        func ncc(_ dx: Double, _ dy: Double) -> Double {
            var n = 0.0, sI = 0.0, sT = 0.0, sII = 0.0, sTT = 0.0, sIT = 0.0
            for (x, y, t) in base {
                guard let v = cam.sample(x + dx, y + dy) else { continue }
                let I = Double(v)
                n += 1; sI += I; sT += t; sII += I * I; sTT += t * t; sIT += I * t
            }
            guard n > 30 else { return -1 }
            let cov = sIT / n - sI * sT / (n * n)
            let d = ((sII / n - sI * sI / (n * n)) * (sTT / n - sT * sT / (n * n))).squareRoot()
            return d > 1e-12 ? cov / d * min(1, n / Double(base.count) / 0.8) : -1
        }
        // lille præference for ingen bevægelse (gentaget mønster kan give næsten lige gode naboer)
        var best = (0.0, 0.0, ncc(0, 0) + 0.02)
        for dy in -radius...radius {
            for dx in -radius...radius where dx != 0 || dy != 0 {
                let v = ncc(Double(dx), Double(dy))
                if v > best.2 { best = (Double(dx), Double(dy), v) }
            }
        }
        return (Homography.scale(1, 1, tx: best.0, ty: best.1) * Hn, best.2)
    }

    private func verify(_ a: Aligned, minScore: Double? = nil) -> Bool {
        guard a.track.score >= (minScore ?? config.acceptScore), a.inliers >= 0.4, a.valid >= 0.3, a.alpha > 0.06 else {
            lastReject = String(format: "mønster (score %.2f, inliers %.2f, gyldige %.2f, kontrast %.2f)", a.track.score, a.inliers, a.valid, a.alpha)
            return false
        }
        let q = a.track.quad
        guard q.isConvex, q.area > 600 else { return false }
        // grov sanity: perspektiv højst ca. 60°
        let (s1, s2) = q.sideLengths
        let aspect = min(s1, s2) / max(s1, s2)
        let ideal = template.geometry.width / template.geometry.height
        return aspect > ideal * 0.45 && aspect < min(1, ideal * 1.9)
    }

    /// Gauss–Newton/Levenberg–Marquardt på 8 homografi-parametre + lys (alpha, beta), med Huber-vægte
    /// (fingre og blænding vejer ikke). `Hn`: normaliserede kortkoordinater → kameraniveauets pixels.
    private func gaussNewton(_ Hn: inout Homography, cam: GrayImage, pts: [LKPoint], iterations: Int,
                             alpha: inout Double, beta: inout Double, haveAB: inout Bool, affine: Bool = false)
        -> (ncc: Double, inliers: Double, valid: Double)? {
        let n = pts.count
        guard n >= 40 else { return nil }
        var J = [Double](repeating: 0, count: n * 10)
        var r = [Double](repeating: 0, count: n)
        var I = [Double](repeating: 0, count: n)
        var ok = [Bool](repeating: false, count: n)
        var lambda = 1e-3
        var prevCost = Double.infinity
        var prevState = (Hn, alpha, beta)
        var lastA = [Double](), lastG = [Double]()
        var result = (ncc: 0.0, inliers: 0.0, valid: 0.0)

        func evaluate(_ H: Homography, _ a: Double, _ b: Double) -> Int {
            let m = H.m
            var valid = 0
            for i in 0..<n {
                let p = pts[i]
                let w = m[6] * p.qx + m[7] * p.qy + m[8]
                guard w > 1e-6 else { ok[i] = false; continue }
                let yx = (m[0] * p.qx + m[1] * p.qy + m[2]) / w
                let yy = (m[3] * p.qx + m[4] * p.qy + m[5]) / w
                guard let c = cam.sample(yx, yy), let xp = cam.sample(yx + 1, yy), let xm = cam.sample(yx - 1, yy),
                      let yp = cam.sample(yx, yy + 1), let ym = cam.sample(yx, yy - 1) else { ok[i] = false; continue }
                ok[i] = true
                valid += 1
                let gx = Double(xp - xm) * 0.5, gy = Double(yp - ym) * 0.5
                let dxqx = (m[0] - yx * m[6]) / w, dxqy = (m[1] - yx * m[7]) / w
                let dyqx = (m[3] - yy * m[6]) / w, dyqy = (m[4] - yy * m[7]) / w
                let gqx = gx * dxqx + gy * dyqx, gqy = gx * dxqy + gy * dyqy
                let qx = p.qx, qy = p.qy
                let o = i * 10
                J[o] = gqx * qx; J[o + 1] = gqx * qy; J[o + 2] = gqx
                J[o + 3] = gqy * qx; J[o + 4] = gqy * qy; J[o + 5] = gqy
                J[o + 6] = -(gqx * qx + gqy * qy) * qx
                J[o + 7] = -(gqx * qx + gqy * qy) * qy
                J[o + 8] = -p.t; J[o + 9] = -1
                I[i] = Double(c)
                r[i] = Double(c) - a * p.t - b
            }
            return valid
        }

        for it in 0..<iterations {
            let valid = evaluate(Hn, alpha, beta)
            guard Double(valid) >= 0.25 * Double(n) else { return nil }
            if !haveAB {
                // første gang: lys fra lineær regression I ≈ a·t + b
                var st = 0.0, si = 0.0, stt = 0.0, sti = 0.0, c = 0.0
                for i in 0..<n where ok[i] { let t = pts[i].t; st += t; si += I[i]; stt += t * t; sti += t * I[i]; c += 1 }
                let den = c * stt - st * st
                alpha = den > 1e-9 ? (c * sti - st * si) / den : 1
                beta = (si - alpha * st) / c
                haveAB = true
                for i in 0..<n where ok[i] { r[i] = I[i] - alpha * pts[i].t - beta }
            }
            // robust skala (MAD) og Huber-vægte
            var absr: [Double] = []
            absr.reserveCapacity(valid)
            for i in 0..<n where ok[i] { absr.append(abs(r[i])) }
            absr.sort()
            let sigma = max(0.01, 1.4826 * absr[absr.count / 2])
            let kH = 1.345 * sigma
            var cost = 0.0
            var A = [Double](repeating: 0, count: 100), g = [Double](repeating: 0, count: 10)
            var inl = 0
            for i in 0..<n where ok[i] {
                let e = abs(r[i])
                let w = e <= kH ? 1.0 : kH / e
                cost += e <= kH ? 0.5 * e * e : kH * (e - 0.5 * kH)
                if e < 0.15 * abs(alpha) + 0.03 { inl += 1 }
                let o = i * 10
                for a in 0..<10 {
                    let ja = J[o + a] * w
                    g[a] += ja * r[i]
                    for b in a..<10 { A[a * 10 + b] += ja * J[o + b] }
                }
            }
            for a in 0..<10 { for b in 0..<a { A[a * 10 + b] = A[b * 10 + a] } }
            cost /= Double(valid)

            if cost > prevCost * 1.0005 && it > 0 {
                // skridtet gjorde det værre: tilbage og mere dæmpning
                (Hn, alpha, beta) = prevState
                lambda *= 10
                A = lastA; g = lastG
                if lambda > 1e4 { break }
            } else {
                prevCost = cost
                prevState = (Hn, alpha, beta)
                lastA = A; lastG = g
                lambda = max(1e-6, lambda * 0.3)
                // korrelation og inliers for den aktuelle tilstand
                var sw = 0.0, sI = 0.0, sT = 0.0, sII = 0.0, sTT = 0.0, sIT = 0.0
                for i in 0..<n where ok[i] && abs(r[i]) <= 2.5 * sigma {
                    let t = pts[i].t
                    sw += 1; sI += I[i]; sT += t; sII += I[i] * I[i]; sTT += t * t; sIT += I[i] * t
                }
                if sw > 10 {
                    let cov = sIT / sw - sI * sT / (sw * sw)
                    let vI = sII / sw - sI * sI / (sw * sw), vT = sTT / sw - sT * sT / (sw * sw)
                    // korrelation over inliers, ganget med andelen af gyldige inliers (fingre trækker lidt ned)
                    let corr = cov / max(1e-12, (vI * vT).squareRoot())
                    result = (corr * min(1, (sw / Double(valid)) / 0.85), Double(inl) / Double(valid), Double(valid) / Double(n))
                }
            }
            // løs (A + λ·diag(A)) δ = −g
            var M = A
            for a in 0..<10 { M[a * 10 + a] += lambda * max(A[a * 10 + a], 1e-9) + 1e-12 }
            if affine {
                // kun affin: perspektiv-parametrene holdes faste
                for a in 6...7 { for b in 0..<10 { M[a * 10 + b] = 0; M[b * 10 + a] = 0 }; M[a * 10 + a] = 1 }
                g[6] = 0; g[7] = 0
            }
            guard let d = LinearSolve.solve(M, g.map { -$0 }, n: 10) else { break }
            var step = 0.0
            for a in 0..<8 { step = max(step, abs(d[a])) }
            let lim = 0.25
            let f = step > lim ? lim / step : 1
            let D = Homography([1 + d[0] * f, d[1] * f, d[2] * f, d[3] * f, 1 + d[4] * f, d[5] * f, d[6] * f, d[7] * f, 1])
            Hn = Hn * D
            alpha += d[8] * f
            beta += d[9] * f
            if step * f < 2e-5 { break }
        }
        // slut-tilstand: sidste accepterede
        (Hn, alpha, beta) = prevState
        return result
    }

    // MARK: Lys og hvad der dækker kortet

    private struct Visibility {
        var output: TrackerOutput
        var gain: SIMD3<Double>
        var offset: SIMD3<Double>
        var colorOK: Bool
    }

    private func visibility(_ track: CardTrack, image: RGBAImage) -> Visibility {
        let f = 2
        let W = image.width / f, Hh = image.height / f
        let lin = ColorMath.linearTableF
        var out = TrackerOutput()
        out.visWidth = W; out.visHeight = Hh; out.visScale = f
        out.visibility = [UInt8](repeating: 255, count: W * Hh)
        out.shade = [UInt8](repeating: 128, count: W * Hh)
        let g = template.geometry
        let Hv = Homography.scale(1 / Double(f), 1 / Double(f)) * track.homography
        guard let Hvi = Hv.inverse else { return Visibility(output: out, gain: SIMD3(1, 1, 1), offset: .zero, colorOK: false) }
        let o = g.overlay
        let oq = [Point2(o.minX, o.minY), Point2(o.maxX, o.minY), Point2(o.maxX, o.maxY), Point2(o.minX, o.maxY)].map { Hv.apply($0) }
        let x0 = max(0, Int(oq.map(\.x).min()!) - 2), x1 = min(W - 1, Int(oq.map(\.x).max()!) + 2)
        let y0 = max(0, Int(oq.map(\.y).min()!) - 2), y1 = min(Hh - 1, Int(oq.map(\.y).max()!) + 2)
        guard x1 > x0 + 4, y1 > y0 + 4 else { return Visibility(output: out, gain: SIMD3(1, 1, 1), offset: .zero, colorOK: false) }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        let ppu = (oq[0].distance(oq[1]) + oq[3].distance(oq[2])) / 2 / (o.maxX - o.minX)
        let tl = template.level(forPixelsPerUnit: ppu)
        let tex = template.colors[tl], ks = template.scale(level: tl)
        let edge = 1.5 / max(ppu, 1e-6)

        // skabelonens og kameraets farve pr. pixel i området
        var T = [SIMD3<Double>](repeating: .zero, count: bw * bh)
        var C = [SIMD3<Double>](repeating: .zero, count: bw * bh)
        var inside = [UInt8](repeating: 0, count: bw * bh)   // 2 = inde, 1 = i kantzonen (kun som nabo)
        for y in y0...y1 {
            for x in x0...x1 {
                let q = Hvi.apply(Point2(Double(x) + 0.5, Double(y) + 0.5))
                let d = g.overlayDistance(q)
                guard d < edge, let t = tex.sample(q.x * ks, q.y * ks) else { continue }
                let i = (y - y0) * bw + (x - x0)
                T[i] = t
                // kameraets farve: 2×2-gennemsnit (som Downsample.box), så lineært lys
                let k0 = ((2 * y) * image.width + 2 * x) * 4, k1 = k0 + image.width * 4
                let px = image.pixels
                let rr = (Int(px[k0]) + Int(px[k0 + 4]) + Int(px[k1]) + Int(px[k1 + 4]) + 2) / 4
                let gg = (Int(px[k0 + 1]) + Int(px[k0 + 5]) + Int(px[k1 + 1]) + Int(px[k1 + 5]) + 2) / 4
                let bb = (Int(px[k0 + 2]) + Int(px[k0 + 6]) + Int(px[k1 + 2]) + Int(px[k1 + 6]) + 2) / 4
                C[i] = SIMD3(Double(lin[rr]), Double(lin[gg]), Double(lin[bb]))
                inside[i] = d < 0 ? 2 : 1
            }
        }

        // lys: C ≈ gain·T + o, med forstærkning pr. kanal (lysets farve) og én fælles forskydning (spredt lys).
        // En fri forskydning pr. kanal kunne "omfarve" et blåt kort til rødt – den fælles kan ikke.
        // To omgange; anden omgang uden afvigere som fingre.
        var gain = SIMD3<Double>(1, 1, 1), offset = SIMD3<Double>(0, 0, 0)
        var weights = [Double](repeating: 1, count: bw * bh)
        var fitOK = false
        for pass in 0..<2 {
            var A = [Double](repeating: 0, count: 16), rhs = [Double](repeating: 0, count: 4)
            var cnt = 0.0
            for i in 0..<(bw * bh) where inside[i] == 2 && weights[i] > 0 {
                let t = T[i], c = C[i]
                for ch in 0..<3 {
                    let tv = t[ch], cv = c[ch]
                    A[ch * 4 + ch] += tv * tv; A[ch * 4 + 3] += tv; A[3 * 4 + ch] += tv; A[15] += 1
                    rhs[ch] += tv * cv; rhs[3] += cv
                }
                cnt += 1
            }
            guard cnt > 20, let x = LinearSolve.solve(A, rhs, n: 4) else { break }
            gain = SIMD3(min(4, max(0.02, x[0])), min(4, max(0.02, x[1])), min(4, max(0.02, x[2])))
            offset = SIMD3(repeating: min(0.4, max(-0.2, x[3])))
            fitOK = true
            if pass == 0 {
                for i in 0..<(bw * bh) where inside[i] == 2 {
                    weights[i] = CardTracker.distance(C[i], gain * T[i] + offset) < 0.3 ? 1 : 0
                }
            }
        }
        // lysets farve højst ca. 1:2,2 mellem kanalerne, og kun lidt spredt lys
        var colorOK = fitOK && min(gain.x, gain.y, gain.z) / max(gain.x, gain.y, gain.z) >= 0.45
            && offset.x > -0.06 && offset.x < 0.15

        // farvetræk pr. pixel (farvetone uafhængig af lysstyrke + log-lysstyrke) for kamera og forventet farve
        let n = bw * bh
        var cf = [Float](repeating: 0, count: n * 3), pf = [Float](repeating: 0, count: n * 3)
        var predSum = [Float](repeating: 0, count: n), camSum = [Float](repeating: 0, count: n)
        for i in 0..<n where inside[i] != 0 {
            let c = C[i], pr = gain * T[i] + offset
            let lc = (c.x + c.y + c.z) / 3, lp = max(0, (pr.x + pr.y + pr.z) / 3)
            cf[i * 3] = Float((c.x - c.y) / (lc + 0.07)); cf[i * 3 + 1] = Float(((c.x + c.y) / 2 - c.z) / (lc + 0.07))
            cf[i * 3 + 2] = Float(log(lc + 0.02))
            pf[i * 3] = Float((pr.x - pr.y) / (lp + 0.07)); pf[i * 3 + 1] = Float(((pr.x + pr.y) / 2 - pr.z) / (lp + 0.07))
            pf[i * 3 + 2] = Float(log(lp + 0.02))
            camSum[i] = Float(3 * lc); predSum[i] = Float(3 * lp)
        }
        // afstand til forventet farve; mindste over 3×3 naboer (tåler en pixels fejl i placeringen)
        let thr = Float(0.55 - 0.4 * min(1, max(0, config.occlusionSensitivity)))
        let lo = thr * 0.75, hi = thr * 1.25
        var occ = [Float](repeating: 0, count: n)
        for y in 0..<bh {
            for x in 0..<bw {
                let i = y * bw + x
                guard inside[i] == 2 else { continue }
                let a0 = cf[i * 3], a1 = cf[i * 3 + 1], a2 = cf[i * 3 + 2]
                var dmin = Float.infinity
                for yy in max(0, y - 1)...min(bh - 1, y + 1) {
                    for xx in max(0, x - 1)...min(bw - 1, x + 1) {
                        let j = yy * bw + xx
                        if inside[j] == 0 { continue }
                        let d = abs(a0 - pf[j * 3]) + abs(a1 - pf[j * 3 + 1]) + 0.6 * max(0, abs(a2 - pf[j * 3 + 2]) - 0.45)
                        if d < dmin { dmin = d }
                    }
                }
                let t = min(1, max(0, (dmin - lo) / (hi - lo)))
                occ[i] = t * t * (3 - 2 * t)
            }
        }
        // fjern enkeltpixels (3×3-gennemsnit), så udvid 1 pixel (fingerkanten skal med)
        var mean = [Float](repeating: 0, count: n)
        for y in 0..<bh {
            for x in 0..<bw {
                var sm: Float = 0, c: Float = 0
                for yy in max(0, y - 1)...min(bh - 1, y + 1) {
                    for xx in max(0, x - 1)...min(bw - 1, x + 1) {
                        let j = yy * bw + xx
                        if inside[j] == 0 { continue }
                        sm += occ[j]; c += 1
                    }
                }
                let m = c > 0 ? sm / c : 0
                let t = min(1, max(0, (m - 0.3) / 0.3))
                mean[y * bw + x] = t * t * (3 - 2 * t)
            }
        }
        // Fingre kommer altid ind over kortets kant: dækkede områder, der ikke rører overlay-områdets kant,
        // er fejl (fx mørkt blæk, der er uskarpt i kameraet) og fjernes. Ellers ses det ægte kort som pletter.
        CardTracker.keepEdgeConnected(&mean, inside: inside, width: bw, height: bh)
        if prevOcc.count != W * Hh { prevOcc = [Float](repeating: 0, count: W * Hh) }
        var newOcc = [Float](repeating: 0, count: W * Hh)
        var local = [Float](repeating: 0, count: n)
        var occSum = 0.0, occCnt = 0.0
        for y in 0..<bh {
            for x in 0..<bw {
                var m: Float = 0
                for yy in max(0, y - 1)...min(bh - 1, y + 1) {
                    for xx in max(0, x - 1)...min(bw - 1, x + 1) { m = max(m, mean[yy * bw + xx]) }
                }
                let j = (y + y0) * W + (x + x0)
                m = max(m, prevOcc[j] * 0.25)
                newOcc[j] = m
                local[y * bw + x] = m
                out.visibility[j] = UInt8(max(0, min(255, (1 - m) * 255)).rounded())
                if inside[y * bw + x] == 2 { occSum += Double(m); occCnt += 1 }
            }
        }
        prevOcc = newOcc
        out.occluded = occCnt > 0 ? occSum / occCnt : 0
        // passer farven ikke på størstedelen af kortet, er det ikke det rigtige kort (fx det andet kort)
        if out.occluded > 0.55 { colorOK = false }

        // lokal lysstyrke (skygge/blænding): forhold mellem kamera og forventet over 9×9, kun synlige pixels
        // (summerede tabeller, så det er konstant tid pr. pixel)
        let sw = bw + 1
        var ic = [Double](repeating: 0, count: sw * (bh + 1)), ip = ic
        for y in 0..<bh {
            var rc = 0.0, rp = 0.0
            for x in 0..<bw {
                let i = y * bw + x
                if inside[i] == 2 && local[i] < 0.5 { rc += Double(camSum[i]); rp += Double(predSum[i]) }
                ic[(y + 1) * sw + x + 1] = ic[y * sw + x + 1] + rc
                ip[(y + 1) * sw + x + 1] = ip[y * sw + x + 1] + rp
            }
        }
        let r = 4
        for y in 0..<bh {
            let ya = max(0, y - r), yb = min(bh, y + r + 1)
            for x in 0..<bw where inside[y * bw + x] != 0 {
                let xa = max(0, x - r), xb = min(bw, x + r + 1)
                let sc = ic[yb * sw + xb] - ic[ya * sw + xb] - ic[yb * sw + xa] + ic[ya * sw + xa]
                let sp = ip[yb * sw + xb] - ip[ya * sw + xb] - ip[yb * sw + xa] + ip[ya * sw + xa]
                let sh = sp > 1e-6 ? min(1.6, max(0.6, sc / sp)) : 1
                out.shade[(y + y0) * W + x + x0] = UInt8((sh * 128).rounded())
            }
        }
        return Visibility(output: out, gain: gain, offset: offset, colorOK: colorOK)
    }

    /// Beholder kun dækkede områder (> 0,3), der hænger sammen med kanten af området (eller billedets kant).
    static func keepEdgeConnected(_ m: inout [Float], inside: [UInt8], width w: Int, height h: Int) {
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard m[i] > 0.3, !seen[i] else { continue }
                var comp: [Int] = []
                var touches = false
                seen[i] = true
                stack.append(i)
                while let j = stack.popLast() {
                    comp.append(j)
                    let jx = j % w, jy = j / w
                    if jx == 0 || jy == 0 || jx == w - 1 || jy == h - 1 || inside[j] != 2 { touches = true }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = jx + dx, ny = jy + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let k = ny * w + nx
                        if inside[k] != 2 { touches = true; continue }
                        if !seen[k] && m[k] > 0.3 { seen[k] = true; stack.append(k) }
                    }
                }
                if !touches { for j in comp { m[j] = 0 } }
            }
        }
    }

    // MARK: Startgæt fra blækkets farve

    /// Kortet fundet ud fra mønstrets farve (blå/rød blæk) i lav opløsning: største farvede områder → orienteret
    /// rektangel = mønsterrammen → kortets hjørner. Groft (fingre, perspektiv), men justeringen klarer resten.
    func inkCandidates(_ image: RGBAImage) -> [Quad] {
        let st = 4
        let w = image.width / st, h = image.height / st
        guard w > 8, h > 8 else { return [] }
        var mask = [Bool](repeating: false, count: w * h)
        let blue = template.color == .blue
        image.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    let k0 = ((y * st + 1) * image.width + x * st + 1) * 4, k1 = k0 + image.width * 4
                    let r = (Int(p[k0]) + Int(p[k0 + 4]) + Int(p[k1]) + Int(p[k1 + 4])) / 4
                    let g = (Int(p[k0 + 1]) + Int(p[k0 + 5]) + Int(p[k1 + 1]) + Int(p[k1 + 5])) / 4
                    let b = (Int(p[k0 + 2]) + Int(p[k0 + 6]) + Int(p[k1 + 2]) + Int(p[k1 + 6])) / 4
                    mask[y * w + x] = blue ? (b > r + 28 && b > g + 12 && b > 45)
                                           : (r > g + 45 && r > b + 35 && r * 10 > g * 15)
                }
            }
        }
        // luk huller (hvide streger og fingre deler ellers mønstret i stykker): udvid 1 pixel
        var grown = mask
        for y in 0..<h {
            for x in 0..<w where !mask[y * w + x] {
                if (x > 0 && mask[y * w + x - 1]) || (x < w - 1 && mask[y * w + x + 1])
                    || (y > 0 && mask[(y - 1) * w + x]) || (y < h - 1 && mask[(y + 1) * w + x]) { grown[y * w + x] = true }
            }
        }
        let original = mask
        mask = grown
        // sammenhængende områder
        var label = [Int32](repeating: -1, count: w * h)
        var comps: [[Int]] = []
        var stack: [Int] = []
        for i in 0..<(w * h) where mask[i] && label[i] < 0 {
            var comp: [Int] = []
            label[i] = Int32(comps.count); stack.append(i)
            while let j = stack.popLast() {
                comp.append(j)
                let jx = j % w, jy = j / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = jx + dx, ny = jy + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let k = ny * w + nx
                    if mask[k] && label[k] < 0 { label[k] = Int32(comps.count); stack.append(k) }
                }
            }
            comps.append(comp)
        }
        let minArea = max(40, w * h / 70)
        let g = template.geometry
        let pat = [Point2(g.pattern.minX, g.pattern.minY), Point2(g.pattern.maxX, g.pattern.minY),
                   Point2(g.pattern.maxX, g.pattern.maxY), Point2(g.pattern.minX, g.pattern.maxY)]
        var out: [Quad] = []
        for whole in comps.sorted(by: { $0.count > $1.count }).prefix(2) where whole.count >= minArea {
            let comp = whole.filter { original[$0] }
            guard comp.count >= minArea / 2 else { continue }
            // mindste rektangel om det konvekse hylster (fingres indhak i kanten fyldes ud)
            let pts = comp.map { Point2(Double($0 % w) + 0.5, Double($0 / w) + 0.5) }
            let hull = CardTracker.convexHull(pts)
            guard hull.count >= 3 else { continue }
            var bestArea = Double.infinity
            var rectC: [Point2] = []
            for k in 0..<hull.count {
                let e = hull[(k + 1) % hull.count] - hull[k]
                let len = e.length
                guard len > 1e-9 else { continue }
                let ux = Point2(e.x / len, e.y / len), uy = Point2(-ux.y, ux.x)
                var a0 = Double.infinity, a1v = -Double.infinity, b0 = Double.infinity, b1 = -Double.infinity
                for p in hull {
                    let pu = p.x * ux.x + p.y * ux.y, pv = p.x * uy.x + p.y * uy.y
                    a0 = min(a0, pu); a1v = max(a1v, pu); b0 = min(b0, pv); b1 = max(b1, pv)
                }
                // pixelcentre → ydre kant: ½ px udad
                a0 -= 0.5; a1v += 0.5; b0 -= 0.5; b1 += 0.5
                let area = (a1v - a0) * (b1 - b0)
                if area < bestArea {
                    bestArea = area
                    func P(_ u: Double, _ v: Double) -> Point2 { ux * u + uy * v }
                    // kort side først (kortets top)
                    if a1v - a0 <= b1 - b0 { rectC = [P(a0, b0), P(a1v, b0), P(a1v, b1), P(a0, b1)] }
                    else { rectC = [P(a0, b0), P(a0, b1), P(a1v, b1), P(a1v, b0)] }
                }
            }
            guard rectC.count == 4, rectC[0].distance(rectC[1]) > 6 else { continue }
            var box = rectC.map { $0 * Double(st) }
            // med uret i billedet (y nedad)
            let cross = (box[1].x - box[0].x) * (box[2].y - box[1].y) - (box[1].y - box[0].y) * (box[2].x - box[1].x)
            if cross < 0 { box = [box[1], box[0], box[3], box[2]] }
            // to gæt: hylstrets hjørner nærmest rektanglets (følger perspektivet) og selve rektanglet
            // (hvis en finger dækker et hjørne)
            let hullS = hull.map { $0 * Double(st) }
            let trap = box.map { c in hullS.min { $0.distance(c) < $1.distance(c) }! }
            for b in [trap, box] {
                guard let hm = Homography.from(pat, to: b) else { continue }
                out.append(hm.quad(width: g.width, height: g.height))
            }
        }
        return out
    }

    /// Konvekst hylster (monoton kæde), med uret ligegyldigt.
    static func convexHull(_ input: [Point2]) -> [Point2] {
        let p = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: Point2, _ a: Point2, _ b: Point2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Point2] = [], upper: [Point2] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Farveafstand der tåler skygge og lysstyrke (farvetone vejer, lysstyrke kun ved store forskelle).
    static func distance(_ c: SIMD3<Double>, _ p: SIMD3<Double>) -> Double {
        let lc = (c.x + c.y + c.z) / 3, lp = (p.x + p.y + p.z) / 3
        let c1 = (c.x - c.y) / (lc + 0.07), c2 = ((c.x + c.y) / 2 - c.z) / (lc + 0.07)
        let p1 = (p.x - p.y) / (lp + 0.07), p2 = ((p.x + p.y) / 2 - p.z) / (lp + 0.07)
        let dl = max(0, abs(log((lc + 0.02) / (max(0, lp) + 0.02))) - 0.45)
        return abs(c1 - p1) + abs(c2 - p2) + 0.6 * dl
    }
}

extension Quad {
    var isConvex: Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            let z = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(z) < 1e-9 { return false }
            if sign == 0 { sign = z } else if (z > 0) != (sign > 0) { return false }
        }
        return true
    }
}
