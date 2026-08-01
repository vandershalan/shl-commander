import SwiftUI

/// Multiplier applied to every font size, row height and bar height in the main window.
///
/// The app draws itself from hard-coded point sizes rather than from Dynamic Type, because a
/// file panel is a dense table whose columns, icons and rows have to stay in proportion with
/// each other. Scaling them all by one factor keeps that proportion at any size, which is
/// what ⌘+, ⌘- and ⌘0 adjust.
struct UIScale: Equatable, Sendable {
    /// The steps ⌘+ and ⌘- walk through. Centred on 1.0, so Actual Size is always a step.
    static let steps: [Double] = [0.75, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static let standard = UIScale(factor: 1)

    static var minimum: Double { steps.first ?? 1 }
    static var maximum: Double { steps.last ?? 1 }

    var factor: Double

    /// Scales a point value, rounded to whole points so rows and bars keep landing on pixel
    /// boundaries rather than drifting half a point out of alignment with each other.
    func callAsFunction(_ points: CGFloat) -> CGFloat {
        max(1, (points * factor).rounded())
    }

    /// The next step up, or the current factor when already at the largest.
    ///
    /// Compared with a tolerance so a factor restored from `UserDefaults` — a decimal that
    /// does not round-trip exactly — still counts as sitting on its step.
    static func zoomedIn(from factor: Double) -> Double {
        steps.first { $0 > factor + tolerance } ?? maximum
    }

    static func zoomedOut(from factor: Double) -> Double {
        steps.last { $0 < factor - tolerance } ?? minimum
    }

    private static let tolerance = 0.001
}

// MARK: - Environment

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue = UIScale.standard
}

extension EnvironmentValues {
    /// Set once by `MainWindow`; every view below it reads its sizes through this.
    var uiScale: UIScale {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}
