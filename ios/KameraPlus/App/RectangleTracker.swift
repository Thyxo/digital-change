import CoreVideo
import QuartzCore
import Vision

/// Finder kortets firkant med Vision og følger den frem i tid.
/// Detektion ca. 15 Hz når et kort ses (3 Hz ellers, for at spare batteri), sporing i billederne imellem.
/// Koordinater: normaliseret 0…1 med origo øverst til venstre (som kamerabilledet).
final class RectangleTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kamera.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastDetect: CFTimeInterval = 0
    private var tracking: VNRectangleObservation?
    private var sequence = VNSequenceRequestHandler()
    private var latest: [Quad] = []
    private var latestTime: CFTimeInterval = 0

    /// Firkanter fra de seneste 0,25 sek.
    func quads(now: CFTimeInterval) -> [Quad] {
        lock.lock(); defer { lock.unlock() }
        return now - latestTime < 0.25 ? latest : []
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracking = nil
        latest = []
        sequence = VNSequenceRequestHandler()
    }

    func submit(_ pb: CVPixelBuffer, cardVisible: Bool, now: CFTimeInterval) {
        lock.lock()
        if busy { lock.unlock(); return }
        let interval = cardVisible ? 1.0 / 15 : 1.0 / 3
        let detect = now - lastDetect >= interval
        let track = tracking
        if !detect && track == nil { lock.unlock(); return }
        busy = true
        if detect { lastDetect = now }
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            var found: [Quad] = []
            var newTracking: VNRectangleObservation?
            if detect {
                let req = VNDetectRectanglesRequest()
                req.minimumAspectRatio = 0.64
                req.maximumAspectRatio = 0.80
                req.quadratureTolerance = 20
                req.minimumSize = 0.12
                req.minimumConfidence = 0.5
                req.maximumObservations = 4
                try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]).perform([req])
                let obs = (req.results ?? []).sorted { Self.area($0) > Self.area($1) }
                found = obs.map(Self.quad)
                newTracking = obs.first
                if newTracking != nil { self.sequence = VNSequenceRequestHandler() }
            } else if let t = track {
                let req = VNTrackRectangleRequest(rectangleObservation: t)
                req.trackingLevel = .fast
                try? self.sequence.perform([req], on: pb, orientation: .up)
                if let r = req.results?.first as? VNRectangleObservation, r.confidence > 0.3 {
                    newTracking = r
                    found = [Self.quad(r)]
                }
            }
            self.lock.lock()
            if detect {
                if !found.isEmpty { self.tracking = newTracking }
            } else {
                self.tracking = newTracking
            }
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
