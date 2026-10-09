import Foundation
import PippaCore

// Text size setting: steps, mapping of stored values, scaling of font sizes. Pure functions.
func runTextScaleChecks() async {
    print("\n— Text size —")

    check("TextScale: three steps 1.0 / 1.18 / 1.36") { TextScale.steps == [1.0, 1.18, 1.36] }
    check("TextScale: stored values map to the nearest step; garbage and 0 → normal") {
        TextScale.step(for: 1.0) == 1.0 && TextScale.step(for: 1.18) == 1.18 && TextScale.step(for: 1.36) == 1.36
            && TextScale.step(for: 1.2) == 1.18 && TextScale.step(for: 5) == 1.36
            && TextScale.step(for: 0) == 1.0 && TextScale.step(for: -3) == 1.0
            && TextScale.step(for: .nan) == 1.0 && TextScale.step(for: .infinity) == 1.0
    }
    check("TextScale: default without stored value is normal; stored step is read back") {
        let name = "textscale-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { dropDefaultsSuite(defaults, name) }
        let fresh = TextScale.load(defaults)
        defaults.set(1.36, forKey: TextScale.key)
        let big = TextScale.load(defaults)
        defaults.set("kaputt", forKey: TextScale.key)
        return fresh == 1.0 && big == 1.36 && TextScale.load(defaults) == 1.0
    }
    check("TextScale: font sizes scale (13.5 → 16 / 18.5) and never shrink") {
        TextScale.scaled(13.5, by: 1.0) == 13.5
            && TextScale.scaled(13.5, by: 1.18) == 16
            && TextScale.scaled(13.5, by: 1.36) == 18.5
            && TextScale.scaled(12, by: 1.36) == 16.5
            && TextScale.scaled(11, by: 1.36) == 15
            && [8.5, 11, 12, 13.5, 28, 44].allSatisfy { TextScale.scaled($0, by: 1.18) >= $0 && TextScale.scaled($0, by: 1.36) >= TextScale.scaled($0, by: 1.18) }
    }
}
