import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

/// Skal matche `Uniforms` i Shaders.metal.
struct RenderUniforms {
    var gain = SIMD4<Float>(1, 1, 1, 1)
    var cropOrigin = SIMD2<Float>(0, 0)
    var cropSize = SIMD2<Float>(1, 1)
    var frameSize = SIMD2<Float>(1, 1)
    var center = SIMD2<Float>(0, 0)
    var mirror: Float = 0
    var effect: Float = 0
    var kind: Float = 2
    var progress: Float = 0
    var radius: Float = 0
    var softness: Float = 1
    var sweepY: Float = 0
    var glow: Float = 0
    var showMask: Float = 0
    var flash: Float = 0
    var lutSize: Float = 2
    var white: Float = 0
}

/// Hvad motoren vil have tegnet.
struct EffectRenderState: Equatable {
    /// Forklædningen tegnes (kort i masken vises som målfarven).
    var disguise = false
    /// Afsløring i gang (forklædningen slukkes efter planen).
    var plan: RevealPlan?
}

/// Metal-søgeren: kamerabillede (nul-kopi via CVMetalTextureCache) + kortmaske + 3D-farvetabel.
/// Tegner ved skærmens takt (30 Hz, 60 Hz under afsløring) og bruger altid det nyeste billede.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    let mailbox: FrameMailbox
    private var queue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var maskTexture: MTLTexture?
    private var emptyMask: MTLTexture?
    private var lutTexture: MTLTexture?
    private var lutSize = 2
    private var uploadedSerial = -1
    private var recordedSerial = -1

    var effect = EffectRenderState() { didSet { updateRate() } }
    var mirror = true
    var mirrorSaved = false
    var zoom = 1.0
    var showMask = false
    var flash: Float = 0
    var white: Float = 0
    var paused = false { didSet { view?.isPaused = paused } }
    var recorder: VideoRecorder?
    private(set) weak var view: MTKView?

    init(mailbox: FrameMailbox) {
        self.mailbox = mailbox
        super.init()
        guard let device else { return }
        queue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        if let lib = device.makeDefaultLibrary() {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "kp_vertex")
            d.fragmentFunction = lib.makeFunction(name: "kp_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try? device.makeRenderPipelineState(descriptor: d)
        }
        emptyMask = makeMaskTexture(width: 1, height: 1)
        if let t = emptyMask { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8(0)], bytesPerRow: 1) }
        setLUT(Renderer.identityLUT(size: 2), size: 2)
    }

    func makeView() -> MTKView {
        let v = MTKView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.backgroundColor = .black
        v.isOpaque = true
        v.preferredFramesPerSecond = 30
        v.isPaused = paused
        v.enableSetNeedsDisplay = false
        v.delegate = self
        view = v
        return v
    }

    private func updateRate() {
        view?.preferredFramesPerSecond = effect.plan != nil ? 60 : 30
    }

    static func identityLUT(size n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 4
            out[i] = UInt8(r * 255 / (n - 1)); out[i + 1] = UInt8(g * 255 / (n - 1)); out[i + 2] = UInt8(b * 255 / (n - 1))
        } } }
        return out
    }

    /// Ny 3D-farvetabel (RGBA8, n³) fra ColorTransfer.buildLUT.
    func setLUT(_ bytes: [UInt8], size n: Int) {
        guard let device, bytes.count == n * n * n * 4 else { return }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return }
        bytes.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: n * 4, bytesPerImage: n * n * 4)
        }
        lutTexture = t
        lutSize = n
    }

    private func makeMaskTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        return device?.makeTexture(descriptor: d)
    }

    private func cameraTexture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
        guard let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
        return (t, cv)
    }

    private func uploadMask(_ f: FrameOutput) {
        guard f.serial != uploadedSerial else { return }
        uploadedSerial = f.serial
        guard !f.mask.isEmpty else { return }
        if maskTexture == nil || maskTexture!.width != f.maskWidth || maskTexture!.height != f.maskHeight {
            maskTexture = makeMaskTexture(width: f.maskWidth, height: f.maskHeight)
        }
        f.mask.withUnsafeBytes { raw in
            maskTexture?.replace(region: MTLRegionMake2D(0, 0, f.maskWidth, f.maskHeight), mipmapLevel: 0,
                                 withBytes: raw.baseAddress!, bytesPerRow: f.maskWidth)
        }
    }

    func mapping(_ f: FrameOutput, mirrored: Bool) -> ViewMapping {
        ViewMapping(viewWidth: 3, viewHeight: 4, frameWidth: Double(f.frameWidth), frameHeight: Double(f.frameHeight),
                    zoom: zoom, mirrored: mirrored)
    }

    func uniforms(_ f: FrameOutput, mirrored: Bool, capture: Bool) -> RenderUniforms {
        let now = CACurrentMediaTime()
        let map = mapping(f, mirrored: mirrored)
        var u = RenderUniforms()
        u.gain = SIMD4(Float(f.gain.r), Float(f.gain.g), Float(f.gain.b), 1)
        u.cropOrigin = SIMD2(Float(map.cropOrigin.x), Float(map.cropOrigin.y))
        u.cropSize = SIMD2(Float(map.cropSize.x), Float(map.cropSize.y))
        u.frameSize = SIMD2(Float(f.frameWidth), Float(f.frameHeight))
        u.mirror = mirrored ? 1 : 0
        u.effect = (effect.disguise || effect.plan != nil) && !f.mask.isEmpty ? 1 : 0
        if let plan = effect.plan {
            switch plan.kind {
            case .wave: u.kind = 0
            case .instant: u.kind = 1
            case .fade: u.kind = 2
            case .sweep: u.kind = 3
            }
            u.progress = Float(plan.progress(at: now))
            u.radius = Float(plan.radius(at: now))
            u.softness = Float(plan.softness)
            u.sweepY = Float(plan.sweepFront(at: now))
            u.center = SIMD2(Float(plan.center.x), Float(plan.center.y))
            u.glow = plan.kind == .wave ? Float(1 - plan.linear(at: now)) : 0
        } else {
            u.kind = 2
            u.progress = 0
        }
        u.showMask = showMask && !capture ? 1 : 0
        u.flash = capture ? 0 : flash
        u.white = capture ? 0 : white
        u.lutSize = Float(lutSize)
        return u
    }

    private func encode(_ enc: MTLRenderCommandEncoder, camera: MTLTexture, uniforms: RenderUniforms) {
        guard let pipelineState else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(camera, index: 0)
        enc.setFragmentTexture(u.effect > 0.5 ? (maskTexture ?? emptyMask) : emptyMask, index: 1)
        enc.setFragmentTexture(lutTexture, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { self.drawFrame(view) }
    }

    private func drawFrame(_ view: MTKView) {
        guard let queue, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var keep: CVMetalTexture?
        if let f = mailbox.latest, let ct = cameraTexture(f.pixelBuffer) {
            let tex = ct.0
            keep = ct.1
            uploadMask(f)
            encode(enc, camera: tex, uniforms: uniforms(f, mirrored: mirror, capture: false))
            if let rec = recorder, f.serial != recordedSerial {
                recordedSerial = f.serial
                record(f, camera: tex, recorder: rec, commandBuffer: cb)
            }
        }
        enc.endEncoding()
        cb.present(drawable)
        let hold = keep
        cb.addCompletedHandler { _ in _ = hold }
        cb.commit()
    }

    // MARK: Billeder og video

    /// Gengiv det seneste billede (med effekten, uden lukkerblink og maske) til et billede.
    func capturePhoto() -> CGImage? {
        guard let device, let queue, let f = mailbox.latest, let ct = cameraTexture(f.pixelBuffer) else { return nil }
        let tex = ct.0
        uploadMask(f)
        let map = mapping(f, mirrored: mirrorSaved)
        let w = Int(map.visibleWidth.rounded()), h = Int(map.visibleHeight.rounded())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encode(enc, camera: tex, uniforms: uniforms(f, mirrored: mirrorSaved, capture: true))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Størrelsen på gemte billeder/video (det synlige udsnit), lige tal.
    func outputSize() -> (Int, Int)? {
        guard let f = mailbox.latest else { return nil }
        let map = mapping(f, mirrored: false)
        return (Int(map.visibleWidth / 2) * 2, Int(map.visibleHeight / 2) * 2)
    }

    private func record(_ f: FrameOutput, camera: MTLTexture, recorder: VideoRecorder, commandBuffer: MTLCommandBuffer) {
        guard let pb = recorder.makeBuffer(), let ct = cameraTexture(pb),
              ct.0.width == recorder.width, ct.0.height == recorder.height else { return }
        let target = ct.0, cv = ct.1
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encode(enc, camera: camera, uniforms: uniforms(f, mirrored: mirrorSaved, capture: true))
        enc.endEncoding()
        let time = f.time
        commandBuffer.addCompletedHandler { _ in
            _ = cv
            recorder.append(pb, time: time)
        }
    }
}

/// Optager søgerens billede (med effekten) til en .mov-fil uden lyd.
final class VideoRecorder: @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var started = false
    private var finished = false

    init?(url: URL, width: Int, height: Int) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        self.url = url
        self.width = width
        self.height = height
        writer = w
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
    }

    func makeBuffer() -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    func append(_ pb: CVPixelBuffer, time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
        }
        if input.isReadyForMoreMediaData { adaptor.append(pb, withPresentationTime: time) }
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        lock.lock()
        finished = true
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { writer.cancelWriting(); done(nil); return }
        input.markAsFinished()
        let url = self.url
        writer.finishWriting { [writer] in
            let ok = writer.status == .completed
            DispatchQueue.main.async { done(ok ? url : nil) }
        }
    }
}

/// SwiftUI-indpakning af søgeren.
struct MetalViewfinder: UIViewRepresentable {
    let renderer: Renderer
    func makeUIView(context: Context) -> MTKView { renderer.makeView() }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
