import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

/// Skal matche `Uniforms` i Shaders.metal.
struct RenderUniforms {
    var hinv0 = SIMD4<Float>(1, 0, 0, 0)
    var hinv1 = SIMD4<Float>(0, 1, 0, 0)
    var hinv2 = SIMD4<Float>(0, 0, 1, 0)
    var gain = SIMD4<Float>(1, 1, 1, 1)
    var offset = SIMD4<Float>(0, 0, 0, 0)
    var overlay = SIMD4<Float>(0, 0, 0, 0)
    var cardSize = SIMD2<Float>(1, 1)
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
    var white: Float = 0
    var feather: Float = 1
    var overlayRadius: Float = 0
    var lodBias: Float = 0
    var grain: Float = 0
    var seed: Float = 0
}

/// Skal matche `BlurUniforms` i Shaders.metal.
struct BlurUniforms {
    var lod: Float
    var dim: Float
    var texel: SIMD2<Float>
}

/// Hvad motoren vil have tegnet.
struct EffectRenderState: Equatable {
    /// Forklædningen tegnes (det fysiske kort vises som målkortet).
    var disguise = false
    /// Afsløring i gang (forklædningen slukkes efter planen).
    var plan: RevealPlan?
}

/// Metal-søgeren: kamerabillede (nul-kopi via CVMetalTextureCache) + det ægte målkort (Rider Back-PNG med mipmaps),
/// lagt ind med kortets homografi, lys og fingermaske fra pipelinen.
/// Tegner ved skærmens takt (30 Hz, 60 Hz under afsløring) og bruger altid det nyeste billede.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    let mailbox: FrameMailbox
    private var queue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var blurState: MTLRenderPipelineState?
    /// Det færdige billede (med målkortet) til sløret opstart, med mipmaps.
    private var blurSource: MTLTexture?
    private var warmOn = false
    private var warmOffAt: CFTimeInterval = 0
    private var textureCache: CVMetalTextureCache?
    private var visTexture: MTLTexture?
    private var emptyVis: MTLTexture?
    private var cardTextures: [CardColor: MTLTexture] = [:]
    private var uploadedSerial = -1
    private var recordedSerial = -1
    private var frameCounter: Float = 0

    var effect = EffectRenderState() { didSet { updateRate() } }
    /// Kortet publikum skal se (rødt i "blå vises som rødt").
    var targetColor: CardColor = .red
    var geometry: CardGeometry?
    var mirror = true
    var mirrorSaved = false
    var zoom = 1.0
    var showMask = false
    /// Uskarphed på målkortet (mipmap-niveauer) og korn.
    var lodBias: Float = 0.5
    var grain: Float = 0.3
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
            d.fragmentFunction = lib.makeFunction(name: "kp_blur")
            blurState = try? device.makeRenderPipelineState(descriptor: d)
        }
        emptyVis = makeVisTexture(width: 1, height: 1)
        emptyVis?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8(0), UInt8(128)], bytesPerRow: 2)
    }

    /// Indlæser de ægte kortbilleder (rider-blue.png / rider-red.png) med mipmaps. Værdierne bruges rå (sRGB-kodet),
    /// shaderen omregner selv til lineært lys.
    func loadCards(directory: URL) {
        guard let device else { return }
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: false, .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        for c in CardColor.allCases {
            let url = directory.appendingPathComponent("rider-\(c.rawValue).png")
            if let t = try? loader.newTexture(URL: url, options: opts) { cardTextures[c] = t }
        }
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

    /// Sløret opstart: hele søgerens billede (også målkortet) sløres og dæmpes lidt, som når iPhonens kamera åbner.
    /// Slås den fra, skarpes billedet op over 0,3 sek.
    func setWarmBlur(_ on: Bool) {
        if on { warmOn = true } else if warmOn { warmOn = false; warmOffAt = CACurrentMediaTime() }
    }

    private var warmAmount: Float {
        if warmOn { return 1 }
        let t = Float((CACurrentMediaTime() - warmOffAt) / 0.3)
        guard t < 1 else { return 0 }
        let k = 1 - max(0, t)
        return k * k * (3 - 2 * k)
    }

    private func blurTarget(width: Int, height: Int) -> MTLTexture? {
        if let t = blurSource, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        blurSource = device?.makeTexture(descriptor: d)
        return blurSource
    }

    private func updateRate() {
        view?.preferredFramesPerSecond = effect.plan != nil ? 60 : 30
    }

    private func makeVisTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: width, height: height, mipmapped: false)
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

    private func uploadVis(_ f: FrameOutput) {
        guard f.serial != uploadedSerial else { return }
        uploadedSerial = f.serial
        guard !f.visibility.isEmpty, f.visibility.count == f.visWidth * f.visHeight * 2 else { return }
        if visTexture == nil || visTexture!.width != f.visWidth || visTexture!.height != f.visHeight {
            visTexture = makeVisTexture(width: f.visWidth, height: f.visHeight)
        }
        f.visibility.withUnsafeBytes { raw in
            visTexture?.replace(region: MTLRegionMake2D(0, 0, f.visWidth, f.visHeight), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: f.visWidth * 2)
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
        if let card = f.card, let g = geometry, let inv = card.homography.inverse {
            let m = inv.m.map { Float($0) }
            u.hinv0 = SIMD4(m[0], m[1], m[2], 0)
            u.hinv1 = SIMD4(m[3], m[4], m[5], 0)
            u.hinv2 = SIMD4(m[6], m[7], m[8], 0)
            u.gain = SIMD4(Float(card.gain.x), Float(card.gain.y), Float(card.gain.z), 1)
            u.offset = SIMD4(Float(card.offset.x), Float(card.offset.y), Float(card.offset.z), 0)
            let o = g.overlay
            u.overlay = SIMD4(Float(o.minX), Float(o.minY), Float(o.maxX), Float(o.maxY))
            u.cardSize = SIMD2(Float(g.width), Float(g.height))
            u.feather = Float(g.overlayFeather)
            u.overlayRadius = Float(g.overlayRadius)
        }
        u.lodBias = lodBias
        u.grain = capture ? grain * 0.5 : grain
        frameCounter += 1
        u.seed = frameCounter.truncatingRemainder(dividingBy: 97) * 13.7
        u.cropOrigin = SIMD2(Float(map.cropOrigin.x), Float(map.cropOrigin.y))
        u.cropSize = SIMD2(Float(map.cropSize.x), Float(map.cropSize.y))
        u.frameSize = SIMD2(Float(f.frameWidth), Float(f.frameHeight))
        u.mirror = mirrored ? 1 : 0
        u.effect = (effect.disguise || effect.plan != nil) && f.card != nil && geometry != nil
            && cardTextures[targetColor] != nil && !f.visibility.isEmpty ? 1 : 0
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
        return u
    }

    private func encode(_ enc: MTLRenderCommandEncoder, camera: MTLTexture, uniforms: RenderUniforms) {
        guard let pipelineState else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(camera, index: 0)
        enc.setFragmentTexture(u.effect > 0.5 ? (visTexture ?? emptyVis) : emptyVis, index: 1)
        enc.setFragmentTexture(cardTextures[targetColor] ?? emptyVis, index: 2)
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
        var keep: CVMetalTexture?
        let amount = warmAmount
        if let f = mailbox.latest, let ct = cameraTexture(f.pixelBuffer) {
            let tex = ct.0
            keep = ct.1
            uploadVis(f)
            let u = uniforms(f, mirrored: mirror, capture: false)
            if amount > 0.001, let blurState, let src = blurTarget(width: drawable.texture.width, height: drawable.texture.height) {
                // 1) det færdige billede (kamera + målkort) → 2) mipmaps → 3) sløret på skærmen
                let first = MTLRenderPassDescriptor()
                first.colorAttachments[0].texture = src
                first.colorAttachments[0].loadAction = .dontCare
                first.colorAttachments[0].storeAction = .store
                if let enc = cb.makeRenderCommandEncoder(descriptor: first) {
                    encode(enc, camera: tex, uniforms: u)
                    enc.endEncoding()
                }
                if let blit = cb.makeBlitCommandEncoder() {
                    blit.generateMipmaps(for: src)
                    blit.endEncoding()
                }
                if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                    var b = BlurUniforms(lod: 5.5 * amount, dim: 1 - 0.25 * amount,
                                         texel: SIMD2(1 / Float(src.width), 1 / Float(src.height)))
                    enc.setRenderPipelineState(blurState)
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentBytes(&b, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }
            } else if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                encode(enc, camera: tex, uniforms: u)
                enc.endEncoding()
            }
            if let rec = recorder, f.serial != recordedSerial {
                recordedSerial = f.serial
                record(f, camera: tex, recorder: rec, commandBuffer: cb)
            }
        } else if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.endEncoding()
        }
        cb.present(drawable)
        let hold = keep
        cb.addCompletedHandler { _ in _ = hold }
        cb.commit()
    }

    // MARK: Billeder og video

    /// Gengiv det seneste billede (med effekten, uden lukkerblink og markering) til et billede.
    func capturePhoto() -> CGImage? {
        guard let device, let queue, let f = mailbox.latest, let ct = cameraTexture(f.pixelBuffer) else { return nil }
        let tex = ct.0
        uploadVis(f)
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
