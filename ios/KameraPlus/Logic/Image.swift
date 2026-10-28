import Foundation

/// Simpelt RGBA-billede (8 bit pr. kanal). Bruges af den rene logik, tests og selvtest.
struct RGBAImage: Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: RGB8 = RGB8(0, 0, 0)) {
        self.width = width
        self.height = height
        var px = [UInt8](repeating: 255, count: width * height * 4)
        var i = 0
        while i < px.count { px[i] = fill.r; px[i + 1] = fill.g; px[i + 2] = fill.b; i += 4 }
        pixels = px
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> RGB8 {
        get { let i = (y * width + x) * 4; return RGB8(pixels[i], pixels[i + 1], pixels[i + 2]) }
        set { let i = (y * width + x) * 4; pixels[i] = newValue.r; pixels[i + 1] = newValue.g; pixels[i + 2] = newValue.b; pixels[i + 3] = 255 }
    }
}

enum Downsample {
    /// Boks-nedskalering med heltalsfaktor fra en rå BGRA- eller RGBA-buffer til RGBA.
    /// Gennemsnittet dæmper støj og blander kortets mønster til en jævn farve.
    static func box(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, bgra: Bool,
                    factor: Int, into out: inout RGBAImage) {
        let f = max(1, factor)
        let ow = width / f, oh = height / f
        if out.width != ow || out.height != oh || out.pixels.count != ow * oh * 4 {
            out = RGBAImage(width: ow, height: oh)
        }
        let area = UInt32(f * f)
        let half = area / 2
        let ri = bgra ? 2 : 0, bi = bgra ? 0 : 2
        var acc = [UInt32](repeating: 0, count: ow * 3)
        acc.withUnsafeMutableBufferPointer { a in
            out.pixels.withUnsafeMutableBufferPointer { o in
                for oy in 0..<oh {
                    for k in 0..<(ow * 3) { a[k] = 0 }
                    for fy in 0..<f {
                        let row = base.advanced(by: (oy * f + fy) * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        var xi = 0
                        for ox in 0..<ow {
                            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0
                            for _ in 0..<f {
                                let p = row + xi * 4
                                r &+= UInt32(p[ri]); g &+= UInt32(p[1]); b &+= UInt32(p[bi])
                                xi += 1
                            }
                            a[ox * 3] &+= r; a[ox * 3 + 1] &+= g; a[ox * 3 + 2] &+= b
                        }
                    }
                    let base = oy * ow * 4
                    for ox in 0..<ow {
                        o[base + ox * 4] = UInt8((a[ox * 3] + half) / area)
                        o[base + ox * 4 + 1] = UInt8((a[ox * 3 + 1] + half) / area)
                        o[base + ox * 4 + 2] = UInt8((a[ox * 3 + 2] + half) / area)
                        o[base + ox * 4 + 3] = 255
                    }
                }
            }
        }
    }

    /// Samme på et RGBAImage (til tests og selvtest).
    static func box(_ img: RGBAImage, factor: Int) -> RGBAImage {
        var out = RGBAImage(width: max(1, img.width / factor), height: max(1, img.height / factor))
        img.pixels.withUnsafeBytes { raw in
            box(base: raw.baseAddress!, width: img.width, height: img.height, bytesPerRow: img.width * 4,
                bgra: false, factor: factor, into: &out)
        }
        return out
    }
}
