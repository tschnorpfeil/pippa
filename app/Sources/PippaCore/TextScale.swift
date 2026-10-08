import Foundation

/// Text size setting (macOS has no Dynamic Type): three steps, stored as `ui.textScale` (the factor).
public enum TextScale {
    public static let key = "ui.textScale"
    public static let normal = 1.0, large = 1.18, extraLarge = 1.36
    public static let steps: [Double] = [normal, large, extraLarge]

    /// Maps any stored value to the nearest known step (garbage, zero or missing -> normal).
    public static func step(for stored: Double) -> Double {
        guard stored.isFinite, stored > 0 else { return normal }
        return steps.min { abs($0 - stored) < abs($1 - stored) } ?? normal
    }

    /// Scaled size, rounded to half points so text stays crisp.
    public static func scaled(_ size: Double, by factor: Double) -> Double {
        (size * factor * 2).rounded() / 2
    }

    public static func load(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: key) == nil ? normal : step(for: defaults.double(forKey: key))
    }
}
