import UIKit

/// Vibrationer: let ved lukker, diskret ved genskab.
@MainActor
final class Haptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()

    func shutter() { light.impactOccurred(intensity: 0.7) }

    /// Diskret bekræftelse af "genskab forklædning".
    func restored() { soft.impactOccurred(intensity: 0.55) }

    func select() { selection.selectionChanged() }
}
