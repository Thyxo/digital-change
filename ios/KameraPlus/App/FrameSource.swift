import AVFoundation
import CoreVideo
import UIKit

/// Modtager kamerabilleder (BGRA, portræt, uspejlet) på pipelinens kø.
protocol FrameSink: AnyObject {
    var queue: DispatchQueue { get }
    func handle(_ pixelBuffer: CVPixelBuffer, time: CMTime)
}

/// Billedkilde: det rigtige kamera eller en syntetisk testvideo (simulator, CI og "Testvideo" i menuen).
protocol FrameSource: AnyObject {
    var sink: FrameSink? { get set }
    var isFront: Bool { get }
    var isRunning: Bool { get }
    func start()
    func stop()
}

// MARK: - Kamera

/// AVCaptureSession med frontkameraet i 4:3 (helst 1440×1080), BGRA, portræt, uspejlet.
/// Spejling sker først i visningen (Metal), så gemte billeder kan være uspejlede.
final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var sink: FrameSink?
    private(set) var isFront = true
    private(set) var isRunning = false

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "kamera.session")
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var exposureLocked = false

    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure(front: self.isFront) }
            if !self.session.isRunning { self.session.startRunning() }
            self.isRunning = self.session.isRunning
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.isRunning = false
        }
    }

    /// Skift mellem front- og bagkamera.
    func setFront(_ front: Bool, completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isFront = front
            self.configure(front: front)
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func configure(front: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input); self.input = nil }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let inp = try? AVCaptureDeviceInput(device: dev), session.canAddInput(inp) else { return }
        session.addInput(inp)
        input = inp
        device = dev
        exposureLocked = false

        if let format = CameraSource.bestFormat(dev) {
            session.sessionPreset = .inputPriority
            if (try? dev.lockForConfiguration()) != nil {
                dev.activeFormat = format
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                dev.unlockForConfiguration()
            }
        } else if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        } else {
            session.sessionPreset = .high
        }

        if !configured {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(output) { session.addOutput(output) }
            configured = true
        }
        if let q = sink?.queue { output.setSampleBufferDelegate(self, queue: q) }
        if let c = output.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false
            }
        }
    }

    /// 4:3-format med bredde tættest på 1440 og mindst 30 billeder/s.
    static func bestFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let ratio = Double(d.width) / Double(max(1, d.height))
            return abs(ratio - 4.0 / 3.0) < 0.01 && d.width >= 1280 && d.width <= 2016
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return abs(Int(d.width) - 1440) * 2 + (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 0 : 1)
        }
        return candidates.min { score($0) < score($1) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sink?.handle(pb, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Lås eksponering og hvidbalance (så et stort farvet kort ikke får farven til at flyde).
    func setExposureLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device, self.exposureLocked != locked else { return }
            guard (try? dev.lockForConfiguration()) != nil else { return }
            if locked {
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
            } else {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            dev.unlockForConfiguration()
            self.exposureLocked = locked
        }
    }

    /// Fokus/eksponering på et punkt (0…1 i det uspejlede portrætbillede), som når man trykker i Kamera.
    func focus(at p: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let sensor = CGPoint(x: p.y, y: 1 - p.x)
            if dev.isFocusPointOfInterestSupported {
                dev.focusPointOfInterest = sensor
                if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
            }
            if !self.exposureLocked, dev.isExposurePointOfInterestSupported {
                dev.exposurePointOfInterest = sensor
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            }
            dev.unlockForConfiguration()
        }
    }
}

// MARK: - Testvideo

/// Syntetisk testvideo: et blåt Rider-agtigt kort, der bevæger sig rundt, vipper og forlader billedet en gang imellem,
/// med en finger på kanten. Bruges i simulatoren, i CI og når "Testvideo" er valgt i menuen.
final class SyntheticSource: FrameSource, @unchecked Sendable {
    weak var sink: FrameSink?
    let isFront = true
    private(set) var isRunning = false
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var t0 = CACurrentMediaTime()
    private var frame = 0
    var ink = RGB8(hex: Palette.defaultBlueHex)

    static let renderWidth = 270, renderHeight = 360   // tegnes i analyseopløsning og forstørres ×2
    static let width = 540, height = 720

    func start() {
        guard !isRunning, let q = sink?.queue else { return }
        isRunning = true
        t0 = CACurrentMediaTime()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 15)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    private func tick() {
        guard let sink else { return }
        let time = CACurrentMediaTime() - t0
        frame += 1
        var s = SynthScene(width: SyntheticSource.renderWidth, height: SyntheticSource.renderHeight)
        s.backdrop = .ceiling
        s.backdropColor = RGB8(214, 214, 210)
        s.noise = 1.5
        s.seed = UInt64(frame)
        let phase = time.truncatingRemainder(dividingBy: 12)
        if phase < 10 {   // kortet er væk de sidste 2 sekunder af hver runde
            let W = Double(s.width), H = Double(s.height)
            var c = SynthCard(center: Point2(W * (0.5 + 0.12 * sin(time * 0.7)), H * (0.5 + 0.08 * sin(time * 1.1))),
                              width: W * (0.55 + 0.05 * sin(time * 0.5)), angle: 0.25 * sin(time * 0.4), ink: ink)
            c.lineSpacing = 3
            c.tilt = 0.08 * sin(time * 0.9)
            s.card = c
            let q = c.quad
            let a = q.corners[3], b = q.corners[0]
            s.fingers = [Finger(center: Point2((a.x + b.x) / 2, (a.y + b.y) / 2), rx: c.width * 0.1, ry: c.width * 0.26,
                                angle: atan2(b.y - a.y, b.x - a.x) + .pi / 2, color: Synth.skinTones[2])]
        }
        let img = Synth.render(s).image
        guard let pb = makeBuffer() else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let dst = base.assumingMemoryBound(to: UInt8.self)
            img.pixels.withUnsafeBufferPointer { src in
                for y in 0..<SyntheticSource.height {
                    let sy = y / 2
                    let row = dst + y * bpr
                    for x in 0..<SyntheticSource.width {
                        let si = (sy * SyntheticSource.renderWidth + x / 2) * 4
                        row[x * 4] = src[si + 2]
                        row[x * 4 + 1] = src[si + 1]
                        row[x * 4 + 2] = src[si]
                        row[x * 4 + 3] = 255
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        sink.handle(pb, time: CMTime(seconds: time, preferredTimescale: 600))
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: SyntheticSource.width,
                kCVPixelBufferHeightKey as String: SyntheticSource.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}
