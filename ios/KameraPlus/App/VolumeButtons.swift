import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Registrerer tryk på volumenknapperne (som i MindTrace). Et skjult MPVolumeView skjuler iOS' lydstyrke-boble,
/// og lydstyrken sættes tilbage til midten, så både op og ned altid kan registreres.
@MainActor
final class VolumeButtons: NSObject {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?

    let volumeView: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.alpha = 0.011
        v.isUserInteractionEnabled = false
        return v
    }()

    private let session = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private var last: Float = 0.5
    private var resetting = false
    private var resetDeadline = Date.distantPast
    private let mid: Float = 0.5

    func activate() {
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        last = session.outputVolume
        if observation == nil {
            observation = session.observe(\.outputVolume, options: [.new]) { [weak self] s, _ in
                let v = s.outputVolume
                Task { @MainActor in self?.changed(v) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.recenter() }
    }

    private func changed(_ v: Float) {
        if resetting && Date() < resetDeadline {
            if abs(v - mid) < 0.02 { resetting = false }
            last = v
            return
        }
        resetting = false
        if v > last || (v >= 0.999 && last >= 0.999) { onUp?() }
        else if v < last || (v <= 0.001 && last <= 0.001) { onDown?() }
        last = v
        recenter()
    }

    private func recenter() {
        guard abs(session.outputVolume - mid) > 0.02,
              let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        resetting = true
        resetDeadline = Date().addingTimeInterval(0.6)
        let target = mid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { slider.value = target }
    }
}

/// Lægger MPVolumeView ind i visningen (skal være i hierarkiet for at skjule boblen).
struct HiddenVolumeView: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
