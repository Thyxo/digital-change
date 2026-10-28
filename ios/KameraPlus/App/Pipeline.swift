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
    let factor: Int
    let maskWidth: Int
    let maskHeight: Int
    /// Kortmasken i analyseopløsning (0–255). Tom når der ikke er analyseret.
    let mask: [UInt8]
    let gain: ChannelGain
    let cardVisible: Bool
    let coverage: Double
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
    var geometry = true
    var lockExposure = true
    var shake = false
    var shakeSensitivity: ShakeSensitivity = .normal
    var wantPreview = false
}

struct PipelineSummary {
    var time: Double
    var cardVisible: Bool
    var analyzed: Bool
    var coverage: Double
    var fps: Double
    var k: Double
    var shake: Double
}

@MainActor
protocol PipelineDelegate: AnyObject {
    func pipelineDidAnalyze(_ summary: PipelineSummary)
    func pipelineDidShake()
    func pipelineDidPreview(_ preview: CGImage)
}

/// Alt arbejde pr. kamerabillede, på én seriel kø: nedskalering til ca. 270 px bredde, farvemaske,
/// lys-tilpasning, Vision-firkant, ryst-detektion og eksponeringslås. Resultatet lægges i postkassen,
/// som Metal-visningen læser.
final class Pipeline: FrameSink, @unchecked Sendable {
    let queue = DispatchQueue(label: "kamera.frames", qos: .userInteractive)
    let mailbox = FrameMailbox()
    let motion = MotionState()
    weak var delegate: PipelineDelegate?
    weak var camera: CameraSource?

    private let tracker = RectangleTracker()
    private var analyzer: CardAnalyzer?
    private var lowres = RGBAImage(width: 1, height: 1)
    private let configLock = NSLock()
    private var config = PipelineConfig()
    private var exposure = ExposureLockPolicy()
    private let shake = ShakeDetector()
    private var serial = 0
    private var fpsCount = 0
    private var fpsStart = CACurrentMediaTime()
    private var fps = 0.0

    private var learnFrames: [RGBAImage] = []
    private var learnUntil = 0.0
    private var learnDone: (([RGBAImage]) -> Void)?

    /// Shake-målerens værdi (0…1) til menuen.
    private(set) var shakeMeter = 0.0

    func setConfig(_ c: PipelineConfig) {
        configLock.lock(); config = c; configLock.unlock()
    }

    private var currentConfig: PipelineConfig {
        configLock.lock(); defer { configLock.unlock() }; return config
    }

    /// Ny farvemodel (bygget i baggrunden).
    func setModels(classifier: CardClassifier, lut: [UInt8], illumination: IlluminationModel) {
        queue.async { [weak self] in
            guard let self else { return }
            if let a = self.analyzer {
                a.update(classifier: classifier, lut: lut)
            } else {
                self.analyzer = CardAnalyzer(classifier: classifier, lut: lut)
            }
            self.analyzer?.illumination = illumination
        }
    }

    func resetTracking() {
        queue.async { [weak self] in
            self?.analyzer?.reset()
            self?.tracker.reset()
            self?.shake.reset()
        }
    }

    /// Saml billeder i `seconds` sekunder til "Lær kort" / "Lær baggrund".
    func learn(seconds: Double, done: @escaping ([RGBAImage]) -> Void) {
        queue.async { [weak self] in
            self?.learnFrames = []
            self?.learnUntil = CACurrentMediaTime() + seconds
            self?.learnDone = done
        }
    }

    // MARK: Pr. billede

    func handle(_ pb: CVPixelBuffer, time: CMTime) {
        let cfg = currentConfig
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let factor = max(1, Int((Double(w) / 270).rounded()))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            Downsample.box(base: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                           bgra: true, factor: factor, into: &lowres)
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let now = CACurrentMediaTime()
        serial += 1

        // Kalibrering
        if learnUntil > 0 {
            if serial % 2 == 0 { learnFrames.append(lowres) }
            if now >= learnUntil {
                let frames = learnFrames, done = learnDone
                learnFrames = []; learnUntil = 0; learnDone = nil
                DispatchQueue.main.async { done?(frames) }
            }
        }

        var result = MaskResult()
        var analyzed = false
        let f = Double(factor)
        if cfg.analyze, let a = analyzer {
            let lw = Double(lowres.width), lh = Double(lowres.height)
            let quads = cfg.geometry
                ? tracker.quads(now: now).map { Quad(corners: $0.corners.map { Point2($0.x * lw, $0.y * lh) }) }
                : []
            result = a.analyze(lowres, quads: quads)
            analyzed = true
            if cfg.geometry { tracker.submit(pb, cardVisible: result.cardVisible, now: now) }
            if cfg.lockExposure {
                if let change = exposure.update(cardVisible: result.cardVisible, at: now) { camera?.setExposureLocked(change) }
            } else if exposure.reset() != nil {
                camera?.setExposureLocked(false)
            }
        } else if exposure.reset() != nil {
            camera?.setExposureLocked(false)
        }

        // Ryst kortet
        var cardWidth: Double?
        if let q = result.quad { cardWidth = q.shortSide * f } else if let b = result.bounds { cardWidth = min(b.width, b.height) * f }
        if analyzed && cfg.shake, result.cardVisible, let c = result.centroid, let cw = cardWidth {
            shake.sensitivity = cfg.shakeSensitivity
            let center = result.quad.map { $0.centroid * f } ?? c * f
            let corners = result.quad?.corners.map { $0 * f }
            if shake.push(CardTrackSample(t: now, center: center, corners: corners, cardWidth: cw, phoneStill: motion.phoneStill)) {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.delegate?.pipelineDidShake() } }
            }
            shakeMeter = shake.meter
        } else {
            shakeMeter = 0
        }

        let out = FrameOutput(
            pixelBuffer: pb, time: time, frameWidth: w, frameHeight: h, factor: factor,
            maskWidth: lowres.width, maskHeight: lowres.height,
            mask: analyzed ? result.mask : [], gain: analyzer?.gain ?? .identity,
            cardVisible: analyzed && result.cardVisible, coverage: analyzed ? result.coverage : 0,
            centroid: result.centroid.map { $0 * f }, bounds: result.bounds.map { RectD(minX: $0.minX * f, minY: $0.minY * f, maxX: $0.maxX * f, maxY: $0.maxY * f) },
            cardWidth: cardWidth, serial: serial)
        mailbox.put(out)

        fpsCount += 1
        if now - fpsStart >= 1 {
            fps = Double(fpsCount) / (now - fpsStart)
            fpsCount = 0
            fpsStart = now
        }
        let summary = PipelineSummary(time: now, cardVisible: out.cardVisible, analyzed: analyzed, coverage: out.coverage,
                                      fps: fps, k: analyzer?.k ?? 0, shake: shakeMeter)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.delegate?.pipelineDidAnalyze(summary) } }

        if cfg.wantPreview && serial % 4 == 0, let img = Pipeline.preview(lowres, mask: analyzed ? result.mask : []) {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.delegate?.pipelineDidPreview(img) } }
        }
    }

    /// Forhåndsvisning til menuen: billedet (spejlet som søgeren) med masken lagt over i magenta.
    static func preview(_ img: RGBAImage, mask: [UInt8]) -> CGImage? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = (y * w + (w - 1 - x)) * 4
                let d = (y * w + x) * 4
                let m = mask.isEmpty ? 0 : Double(mask[y * w + (w - 1 - x)]) / 255 * 0.55
                px[d] = UInt8(Double(img.pixels[s]) * (1 - m) + 255 * m)
                px[d + 1] = UInt8(Double(img.pixels[s + 1]) * (1 - m))
                px[d + 2] = UInt8(Double(img.pixels[s + 2]) * (1 - m) + 255 * m)
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
