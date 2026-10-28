import CoreVideo
import QuartzCore
import Vision

/// Finder kortets firkant med Vision – kun som startgæt til mønster-sporingen (CardTracker), som selv følger kortet.
/// Ca. 10 Hz, når kortet ikke følges sikkert, ellers 2 Hz (spar batteri).
/// Koordinater: normaliseret 0…1 med origo øverst til venstre (som kamerabilledet).
final class RectangleTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kamera.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastDetect: CFTimeInterval = 0
    private var latest: [Quad] = []
    private var latestTime: CFTimeInterval = 0

    /// Firkanter fra de seneste 0,3 sek.
    func quads(now: CFTimeInterval) -> [Quad] {
        lock.lock(); defer { lock.unlock() }
        return now - latestTime < 0.3 ? latest : []
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        latest = []
    }

    func submit(_ pb: CVPixelBuffer, often: Bool, now: CFTimeInterval) {
        lock.lock()
        let interval = often ? 1.0 / 10 : 1.0 / 2
        if busy || now - lastDetect < interval { lock.unlock(); return }
        busy = true
        lastDetect = now
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let req = VNDetectRectanglesRequest()
            req.minimumAspectRatio = 0.55
            req.maximumAspectRatio = 0.85
            req.quadratureTolerance = 25
            req.minimumSize = 0.12
            req.minimumConfidence = 0.4
            req.maximumObservations = 3
            try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]).perform([req])
            let found = (req.results ?? []).sorted { Self.area($0) > Self.area($1) }.map(Self.quad)
            self.lock.lock()
            if !found.isEmpty {
                self.latest = found
                self.latestTime = CACurrentMediaTime()
            }
            self.busy = false
            self.lock.unlock()
        }
    }

    private static func area(_ o: VNRectangleObservation) -> CGFloat { o.boundingBox.width * o.boundingBox.height }

    /// Vision har origo nederst til venstre.
    private static func quad(_ o: VNRectangleObservation) -> Quad {
        func p(_ c: CGPoint) -> Point2 { Point2(Double(c.x), Double(1 - c.y)) }
        return Quad(p(o.topLeft), p(o.topRight), p(o.bottomRight), p(o.bottomLeft))
    }
}
