import SwiftUI

/// Mål fra dine screenshots (ref/kamera-1.webp og -2.webp: 923×2000 px = 393×852 pt).
/// Alt skaleres efter skærmens bredde (eller højden på meget lave skærme). Ret ikke tallene uden nye målinger.
enum L {
    static let width: CGFloat = 393
    static let height: CGFloat = 852
    static let vfTop: CGFloat = 118
    static let vfHeight: CGFloat = 524
    static let pillCenter = CGPoint(x: 306.5, y: 89.5)
    static let pillSize = CGSize(width: 141, height: 35)
    static let pillIconsX: [CGFloat] = [254, 289, 324, 359]
    static let topGlyph: CGFloat = 27.3        // glyffer skåret som 64 px-kvadrater
    static let vfButton = CGPoint(x: 196.3, y: 605.4)
    static let vfButtonD: CGFloat = 37.5
    static let vfGlyph: CGFloat = 23.8
    static let shutter = CGPoint(x: 196.5, y: 697.3)
    static let shutterOuter: CGFloat = 79.2
    static let shutterInner: CGFloat = 67.4
    static let rowY: CGFloat = 793.3
    static let thumbX: CGFloat = 57.95
    static let roundD: CGFloat = 47.7
    static let flipX: CGFloat = 334.65
    static let flipGlyph: CGFloat = 33.2
    static let modeCenter = CGPoint(x: 196.5, y: 793.5)
    static let modeSize = CGSize(width: 164, height: 42)
    static let videoX: CGFloat = 159.6
    static let photoX: CGFloat = 233.6
    static let capsuleSize = CGSize(width: 83, height: 41)
    static let capsulePhotoX: CGFloat = 233.1
    static let capsuleVideoX: CGFloat = 159.9
    static let levelWidth: CGFloat = 181
    static let focusSize: CGFloat = 80

    static let yellow = Color(red: 254 / 255, green: 246 / 255, blue: 87 / 255)      // #FEF657
    static let levelYellow = Color(red: 232 / 255, green: 202 / 255, blue: 69 / 255) // #E8CA45
    static let pillBG = Color(white: 30 / 255)        // #1E1E1E
    static let modeBG = Color(white: 20 / 255)        // #141414
    static let capsuleBG = Color(white: 31 / 255)     // #1F1F1F
    static let ring = Color(white: 50 / 255)          // #323232
    static let ringEdge = Color(white: 99 / 255)      // #636363
    static let recordRed = Color(red: 1, green: 59 / 255, blue: 48 / 255)
}

/// Kameraets tekster følger iPhonens sprog (ellers engelsk).
enum CameraText {
    static var lang: String { String((Locale.preferredLanguages.first ?? "en").prefix(2)) }
    private static let modes: [String: (String, String)] = [
        "da": ("FOTO", "VIDEO"), "en": ("PHOTO", "VIDEO"), "de": ("FOTO", "VIDEO"), "sv": ("FOTO", "VIDEO"),
        "nb": ("FOTO", "VIDEO"), "nn": ("FOTO", "VIDEO"), "no": ("FOTO", "VIDEO"), "nl": ("FOTO", "VIDEO"),
        "it": ("FOTO", "VIDEO"), "fr": ("PHOTO", "VIDÉO"), "es": ("FOTO", "VÍDEO"), "pt": ("FOTO", "VÍDEO"),
        "fi": ("KUVA", "VIDEO"), "pl": ("ZDJĘCIE", "WIDEO"), "is": ("MYND", "MYNDSKEIÐ"),
    ]
    static var photo: String { modes[lang]?.0 ?? "PHOTO" }
    static var video: String { modes[lang]?.1 ?? "VIDEO" }
    static var noPhotos: String { lang == "da" ? "Ingen billeder" : "No Photos" }
    static var delete: String { lang == "da" ? "Slet billede" : "Delete Photo" }
    static var deleteTitle: String { lang == "da" ? "Dette billede slettes." : "This photo will be deleted." }
    static var denied: String { lang == "da" ? "Giv Kamera adgang til kameraet i Indstillinger." : "Allow camera access in Settings." }
}

struct RootView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.scenePhase) private var phase
    @State private var secretTaps: [Date] = []

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / L.width, geo.size.height / L.height)
            ZStack {
                Color.black
                CameraScreen(store: engine.store, s: s, onSecretTap: secretTap)
                    .frame(width: L.width * s, height: L.height * s)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                HiddenVolumeView(view: engine.volume.volumeView)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                Color.white.opacity(engine.frontFlash)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $engine.panelOpen) {
            SecretPanel()
                .environmentObject(engine)
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: $engine.galleryOpen) {
            GalleryView(store: engine.store).environmentObject(engine)
        }
        .onChange(of: phase) { _, p in engine.scenePhase(p) }
        .onAppear { engine.start() }
    }

    /// 5 hurtige tryk (inden for 2,5 sek.) øverst til venstre åbner menuen.
    private func secretTap() {
        let now = Date()
        secretTaps = secretTaps.filter { now.timeIntervalSince($0) < 2.5 } + [now]
        if secretTaps.count >= 5 {
            secretTaps = []
            engine.panelOpen = true
        }
    }
}

struct CameraScreen: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var store: PhotoStore
    let s: CGFloat
    let onSecretTap: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Viewfinder(s: s)
                .frame(width: L.width * s, height: L.vfHeight * s)
                .position(x: L.width / 2 * s, y: (L.vfTop + L.vfHeight / 2) * s)

            TopPill(s: s).position(x: L.pillCenter.x * s, y: L.pillCenter.y * s)
            if engine.mode == .video {
                RecordTimer(s: s).position(x: 120 * s, y: L.pillCenter.y * s)
            }

            // Skjult zone (trigger): det sorte felt til højre for lukkeren
            Color.clear.contentShape(Rectangle())
                .frame(width: 133 * s, height: 96 * s)
                .position(x: 326.5 * s, y: 698 * s)
                .onTapGesture { engine.hiddenZoneTap() }

            ShutterButton(s: s).position(x: L.shutter.x * s, y: L.shutter.y * s)

            // Skjult zone (genskab): hold 1 sek. nederst til venstre
            Color.clear.contentShape(Rectangle())
                .frame(width: 110 * s, height: 117 * s)
                .position(x: 55 * s, y: 793.5 * s)
                .onLongPressGesture(minimumDuration: 1) { engine.restoreZoneHold() }

            ThumbnailButton(store: store, s: s).position(x: L.thumbX * s, y: L.rowY * s)
            ModePill(s: s).position(x: L.modeCenter.x * s, y: L.modeCenter.y * s)
            FlipButton(s: s).position(x: L.flipX * s, y: L.rowY * s)

            // Hemmelig zone øverst til venstre: 5 tryk = menu, hold 1 sek. = panik
            Color.clear.contentShape(Rectangle())
                .frame(width: 90 * s, height: 90 * s)
                .position(x: 45 * s, y: 45 * s)
                .onTapGesture { onSecretTap() }
                .onLongPressGesture(minimumDuration: 1) { engine.panic() }
                .accessibilityIdentifier("secretZone")
        }
        .frame(width: L.width * s, height: L.height * s)
    }
}

// MARK: - Søgeren

struct Viewfinder: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: AppSettings
    let s: CGFloat

    var body: some View {
        let w = L.width * s, h = L.vfHeight * s
        ZStack {
            MetalViewfinder(renderer: engine.renderer)
            if engine.cameraDenied {
                Text(CameraText.denied).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).padding(30)
            }
            if settings.grid {
                GridLines().stroke(Color.white.opacity(0.45), lineWidth: 0.8).allowsHitTesting(false)
            }
            if settings.level && engine.levelVisible {
                Rectangle().fill(L.levelYellow).frame(width: L.levelWidth * s, height: 1).allowsHitTesting(false)
            }
            if let f = engine.focus {
                FocusSquare(point: f.point, s: s).id(f.id)
            }
            Color.black.opacity(engine.blink).allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .clipped()
        .blur(radius: engine.flipping ? 18 : 0)
        .rotation3DEffect(.degrees(engine.flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
        .overlay(alignment: .top) {
            if engine.moreOpen { MoreRow(s: s).padding(.top, 10 * s) }
        }
        .overlay {
            if engine.isFront {
                ViewfinderButton(s: s).position(x: L.vfButton.x * s, y: (L.vfButton.y - L.vfTop) * s)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in
            engine.viewfinderTap(v.location, size: CGSize(width: w, height: h))
        })
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { v in
            if v.translation.width > 60 { engine.setMode(.video) }
            if v.translation.width < -60 { engine.setMode(.photo) }
        })
    }
}

struct GridLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = r.width * CGFloat(i) / 3, y = r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: r.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: r.width, y: y))
        }
        return p
    }
}

/// Apples gule fokusfirkant: 80 pt, 1 pt streg med små streger midt på siderne, 1,25 → 1, tones ud efter ca. 1 sek.
struct FocusSquare: View {
    let point: CGPoint
    let s: CGFloat
    @State private var scale: CGFloat = 1.25
    @State private var opacity = 1.0

    var body: some View {
        FocusShape()
            .stroke(L.yellow, lineWidth: 1)
            .frame(width: L.focusSize * s, height: L.focusSize * s)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(point)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { scale = 1 }
                withAnimation(.easeIn(duration: 0.4).delay(1.0)) { opacity = 0 }
            }
    }
}

struct FocusShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(r)
        let t = r.width * 0.07
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY + t))
        p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY - t))
        p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX + t, y: r.midY))
        p.move(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX - t, y: r.midY))
        return p
    }
}

struct ViewfinderButton: View {
    @EnvironmentObject var engine: Engine
    let s: CGFloat

    var body: some View {
        Button { engine.toggleExpanded() } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.4))
                Glyph(name: engine.expanded ? "glyph-collapse" : "glyph-expand", size: L.vfGlyph * s)
                    .rotationEffect(.degrees(engine.rotation.degrees))
            }
            .frame(width: L.vfButtonD * s, height: L.vfButtonD * s)
        }
        .buttonStyle(.plain)
    }
}

/// Skabelon-billede skåret ud af screenshot (hvidt, farves efter behov).
struct Glyph: View {
    let name: String
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

// MARK: - Top

struct TopPill: View {
    @EnvironmentObject var engine: Engine
    let s: CGFloat

    var body: some View {
        ZStack {
            Capsule().fill(L.pillBG).frame(width: L.pillSize.width * s, height: L.pillSize.height * s)
            icon(0) { engine.nightOn.toggle() } content: {
                Glyph(name: "glyph-moon", size: L.topGlyph * s, color: engine.nightOn ? L.yellow : .white)
            }
            icon(1) { engine.flashOn.toggle() } content: {
                if engine.flashOn {
                    Image(systemName: "bolt.fill").font(.system(size: 15 * s, weight: .semibold)).foregroundStyle(L.yellow)
                        .frame(width: L.topGlyph * s, height: L.topGlyph * s)
                } else {
                    Glyph(name: "glyph-flash-off", size: L.topGlyph * s)
                }
            }
            icon(2) { engine.liveOn.toggle() } content: {
                Glyph(name: "glyph-live-auto", size: L.topGlyph * s, color: engine.liveOn ? L.yellow : .white)
            }
            icon(3) { withAnimation(.easeInOut(duration: 0.2)) { engine.moreOpen.toggle() } } content: {
                Glyph(name: "glyph-more", size: L.topGlyph * s, color: engine.moreOpen ? L.yellow : .white)
            }
        }
    }

    private func icon<C: View>(_ i: Int, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .rotationEffect(.degrees(engine.rotation.degrees))
                .frame(width: 34 * s, height: 34 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: (L.pillIconsX[i] - L.pillCenter.x) * s)
    }
}

/// "⋯" åbner en simpel ekstra række (kun udseende).
struct MoreRow: View {
    let s: CGFloat
    @State private var selected: Int?

    var body: some View {
        HStack(spacing: 22 * s) {
            ForEach(Array(["timer", "plusminus.circle", "camera.filters", "aspectratio"].enumerated()), id: \.offset) { i, name in
                Button { selected = selected == i ? nil : i } label: {
                    Image(systemName: name)
                        .font(.system(size: 17 * s))
                        .foregroundStyle(selected == i ? L.yellow : .white)
                        .frame(width: 30 * s, height: 30 * s)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16 * s)
        .padding(.vertical, 6 * s)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

struct RecordTimer: View {
    @EnvironmentObject var engine: Engine
    let s: CGFloat

    var body: some View {
        let t = engine.recordingSeconds
        Text(String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60))
            .font(.system(size: 17 * s, weight: .regular).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6 * s)
            .padding(.vertical, 2 * s)
            .background(RoundedRectangle(cornerRadius: 5 * s).fill(engine.recording ? L.recordRed : .clear))
    }
}

// MARK: - Bund

struct ShutterButton: View {
    @EnvironmentObject var engine: Engine
    let s: CGFloat

    var body: some View {
        Button { engine.shutterTap() } label: { Color.clear }
            .buttonStyle(ShutterStyle(s: s, video: engine.mode == .video, recording: engine.recording))
            .accessibilityIdentifier("shutter")
    }
}

struct ShutterStyle: ButtonStyle {
    let s: CGFloat
    let video: Bool
    let recording: Bool

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().fill(L.ring)
            Circle().stroke(L.ringEdge, lineWidth: 0.6)
            Group {
                if video && recording {
                    RoundedRectangle(cornerRadius: 7 * s).fill(L.recordRed).frame(width: 30 * s, height: 30 * s)
                } else {
                    Circle().fill(video ? L.recordRed : .white).frame(width: L.shutterInner * s, height: L.shutterInner * s)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.2), value: recording)
        }
        .frame(width: L.shutterOuter * s, height: L.shutterOuter * s)
        .contentShape(Circle())
    }
}

struct ThumbnailButton: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var store: PhotoStore
    let s: CGFloat

    var body: some View {
        ZStack {
            if let t = store.thumbnail {
                Image(uiImage: t).resizable().scaledToFill()
            } else {
                L.pillBG
            }
        }
        .frame(width: L.roundD * s, height: L.roundD * s)
        .clipShape(Circle())
        .rotationEffect(.degrees(engine.rotation.degrees))
        .contentShape(Circle())
        .onTapGesture { engine.galleryOpen = true }
        .onLongPressGesture(minimumDuration: 1) { engine.restoreZoneHold() }
    }
}

struct ModePill: View {
    @EnvironmentObject var engine: Engine
    let s: CGFloat

    var body: some View {
        let video = engine.mode == .video
        ZStack {
            Capsule().fill(L.modeBG).frame(width: L.modeSize.width * s, height: L.modeSize.height * s)
            Capsule()
                .fill(L.capsuleBG)
                .overlay(Capsule().stroke(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.2), Color(white: 0.3)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: L.capsuleSize.width * s, height: (L.capsuleSize.height - 1) * s)
                .offset(x: ((video ? L.capsuleVideoX : L.capsulePhotoX) - L.modeCenter.x) * s)
            label(CameraText.video, selected: video, x: L.videoX) { engine.setMode(.video) }
            label(CameraText.photo, selected: !video, x: L.photoX) { engine.setMode(.photo) }
        }
    }

    private func label(_ text: String, selected: Bool, x: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14 * s, weight: .regular))
                .tracking(0.6 * s)
                .foregroundStyle(selected ? L.yellow : .white)
                .frame(width: 80 * s, height: 40 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: (x - L.modeCenter.x) * s)
    }
}

struct FlipButton: View {
    @EnvironmentObject var engine: Engine
    let s: CGFloat

    var body: some View {
        Button { engine.flipCamera() } label: {
            ZStack {
                Circle().fill(L.pillBG)
                Glyph(name: "glyph-flip", size: L.flipGlyph * s)
                    .rotationEffect(.degrees(engine.rotation.degrees))
            }
            .frame(width: L.roundD * s, height: L.roundD * s)
        }
        .buttonStyle(.plain)
    }
}
