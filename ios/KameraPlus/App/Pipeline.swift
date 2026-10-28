import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

/// Ét bearbejdet kamerabillede til visningen.
struct FrameOutput {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
    let frameWidth: Int
    let frameHeight: Int
    /// Kortet i kamerabilledets pixels (homografi fra kanoniske kortkoordinater). nil = intet kort.
    let card: CardTrack?
    /// Synlighed og lokal lysstyrke (2 bytes pr. pixel), dækker hele billedet i `visWidth`×`visHeight`.
    let visibility: [UInt8]
    let visWidth: Int
    let visHeight: Int
    let occluded: Double
    var cardVisible: Bool { card != nil }
    /// I kamerabilledets pixels.
    let centroid: Point2?
    let bounds: RectD?
    let cardWidth: Double?
    let serial: Int
}

/// Seneste billede, delt mellem pipelinens kø og visningen.
final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FrameOutput?

    func put(_ f: FrameOutput) { lock.lock(); value = f; lock.unlock() }
    func clear() { lock.lock(); value = nil; lock.unlock() }
    var latest: FrameOutput? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Telefonens bevægelse til pipelinen (skrives af MotionManager).
final class MotionState: @unchecked Sendable {
    private let lock = NSLock()
    private var still = true
    var phoneStill: Bool {
        get { lock.lock(); defer { lock.unlock() }; return still }
        set { lock.lock(); still = newValue; lock.unlock() }
    }
}

struct PipelineConfig: Equatable {
    var analyze = true
    var lockExposure = true
    var shake = false
    var shakeSensitivity: ShakeSensitivity = .normal
    var occlusionSensitivity = 0.5
    var wantPreview = false
}

struct PipelineSummary {
    var time: Double
    var cardVisible: Bool
    var analyzed: Bool
    var score: Double
    var occluded: Double
    var fps: Double
    var ms: Double
    var shake: Double
}

@MainActor
protocol PipelineDelegate: AnyObject {
    func pipelineDidAnalyze(_ summary: PipelineSummary)
    func pipelineDidShake()
    func pipelineDidPreview(_ preview: CGImage)
}

/// Alt arbejde pr. kamerabillede, på én seriel kø: nedskalering til ca. 540 px bredde, mønster-sporing af det
/// fysiske Rider Back-kort (CardTracker), Vision-firkant som startgæt, ryst-detektion og eksponeringslås.
/// Resultatet lægges i postkassen, som Metal-visningen læser.
final class Pipeline: FrameSink, @unchecked Sendable {
    let queue = DispatchQueue(label: "kamera.frames", qos: .userInteractive)
    let mailbox = FrameMailbox()
    let motion = MotionState()
    weak var delegate: PipelineDelegate?
    weak var camera: CameraSource?

    private let rectangles = RectangleTracker()
    private var tracker: CardTracker?
    private var image = RGBAImage(width: 1, height: 1)
    private let configLock = NSLock()
    private var config = PipelineConfig()
    private var exposure = ExposureLockPolicy()
    private let shake = ShakeDetector()
    private var serial = 0
    private var fpsCount = 0
    private var fpsStart = CACurrentMediaTime()
    private var fps = 0.0

    /// Testvideoens egen firkant (i billedets pixels) – i stedet for Vision, som ikke ser den lyse kant mod loftet.
    /// Sættes og læses kun på pipelinens kø.
    var syntheticHint: Quad?

    /// Shake-målerens værdi (0…1) til menuen.
    private(set) var shakeMeter = 0.0

    func setConfig(_ c: PipelineConfig) {
        configLock.lock(); config = c; configLock.unlock()
    }

    private var currentConfig: PipelineConfig {
        configLock.lock(); defer { configLock.unlock() }; return config
    }

    /// Skabelonen for det kort, kameraet ser (blåt i "blå vises som rødt").
    func setSource(_ template: CardTemplate) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.tracker?.template.color != template.color { self.tracker = CardTracker(template: template) }
        }
    }

    func resetTracking() {
        queue.async { [weak self] in
            self?.tracker?.reset()
            self?.rectangles.reset()
            self?.shake.reset()
        }
    }

    // MARK: Pr. billede

    func handle(_ pb: CVPixelBuffer, time: CMTime) {
        let cfg = currentConfig
        let started = CACurrentMediaTime()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let factor = max(1, Int((Double(w) / 540).rounded()))
        let f = Double(factor)
        serial += 1

        var output = TrackerOutput()
        var analyzed = false
        if cfg.analyze, let tracker {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                Downsample.box(base: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               bgra: true, factor: factor, into: &image)
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            tracker.config.occlusionSensitivity = cfg.occlusionSensitivity
            let iw = Double(image.width), ih = Double(image.height)
            var cands = rectangles.quads(now: started).map { Quad(corners: $0.corners.map { Point2($0.x * iw, $0.y * ih) }) }
            if let hint = syntheticHint { cands.insert(Quad(corners: hint.corners.map { $0 * (1 / f) }), at: 0) }
            output = tracker.update(image, candidates: cands)
            analyzed = true
            // Vision kun når kortet ikke allerede følges sikkert
            let needQuads = output.track == nil || !output.fresh || output.track!.score < 0.75
            rectangles.submit(pb, often: needQuads, now: started)
            if cfg.lockExposure {
                if let change = exposure.update(cardVisible: output.track != nil, at: started) { camera?.setExposureLocked(change) }
            } else if exposure.reset() != nil {
                camera?.setExposureLocked(false)
            }
        } else if exposure.reset() != nil {
            camera?.setExposureLocked(false)
        }

        // kort i kamerabilledets pixels
        var card: CardTrack?
        if var t = output.track {
            t.homography = Homography.scale(f, f) * t.homography
            t.quad = Quad(corners: t.quad.corners.map { $0 * f })
            card = t
        }
        let cardWidth = card.map { $0.quad.shortSide }

        // Ryst kortet
        if analyzed && cfg.shake, let c = card, let cw = cardWidth {
            shake.sensitivity = cfg.shakeSensitivity
            if shake.push(CardTrackSample(t: started, center: c.quad.centroid, corners: c.quad.corners, cardWidth: cw,
                                          phoneStill: motion.phoneStill)) {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.delegate?.pipelineDidShake() } }
            }
            shakeMeter = shake.meter
        } else {
            shakeMeter = 0
        }

        // synlighed + lysstyrke flettet til én RG-tekstur
        var vis: [UInt8] = []
        if card != nil, !output.visibility.isEmpty {
            vis = [UInt8](repeating: 0, count: output.visibility.count * 2)
            for i in 0..<output.visibility.count {
                vis[i * 2] = output.visibility[i]
                vis[i * 2 + 1] = output.shade[i]
            }
        }

        let out = FrameOutput(
            pixelBuffer: pb, time: time, frameWidth: w, frameHeight: h, card: card,
            visibility: vis, visWidth: output.visWidth, visHeight: output.visHeight, occluded: output.occluded,
            centroid: card?.quad.centroid, bounds: card?.quad.bounds, cardWidth: cardWidth, serial: serial)
        mailbox.put(out)

        fpsCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            fps = Double(fpsCount) / (now - fpsStart)
            fpsCount = 0
            fpsStart = now
        }
        let summary = PipelineSummary(time: now, cardVisible: card != nil, analyzed: analyzed, score: card?.score ?? 0,
                                      occluded: output.occluded, fps: fps, ms: (now - started) * 1000, shake: shakeMeter)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.delegate?.pipelineDidAnalyze(summary) } }

        if cfg.wantPreview && analyzed && serial % 4 == 0,
           let img = Pipeline.preview(image, track: output.track, visibility: output.visibility, visWidth: output.visWidth,
                                      template: tracker?.template) {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.delegate?.pipelineDidPreview(img) } }
        }
    }

    /// Forhåndsvisning til menuen (spejlet som søgeren, halv størrelse): grønt = her tegnes målkortet,
    /// magenta = noget dækker kortet (fingre), hvid kant = kortets omrids.
    static func preview(_ img: RGBAImage, track: CardTrack?, visibility: [UInt8], visWidth: Int, template: CardTemplate?) -> CGImage? {
        let w = img.width / 2, h = img.height / 2
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let inv = track.flatMap { (Homography.scale(0.5, 0.5) * $0.homography).inverse }
        let geo = template?.geometry
        for y in 0..<h {
            for x in 0..<w {
                let sx = w - 1 - x
                let s = ((y * 2) * img.width + sx * 2) * 4
                var r = Double(img.pixels[s]), g = Double(img.pixels[s + 1]), b = Double(img.pixels[s + 2])
                if let inv, let geo {
                    let q = inv.apply(Point2(Double(sx) + 0.5, Double(y) + 0.5))
                    let cd = geo.cardDistance(q)
                    if abs(cd) < 6 { r = 255; g = 255; b = 255 }
                    else if geo.overlayDistance(q) < 0 {
                        let v = visibility.isEmpty || sx >= visWidth ? 255 : Int(visibility[y * visWidth + sx])
                        if v >= 128 { r *= 0.6; g = g * 0.6 + 100; b *= 0.6 } else { r = r * 0.4 + 150; g *= 0.4; b = b * 0.4 + 150 }
                    }
                }
                let d = (y * w + x) * 4
                px[d] = UInt8(min(255, r)); px[d + 1] = UInt8(min(255, g)); px[d + 2] = UInt8(min(255, b))
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
