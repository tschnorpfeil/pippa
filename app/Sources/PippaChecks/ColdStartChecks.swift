import Foundation
import PippaCore

/// Cold start (PippaCore/ColdStart.swift): progress from the server's memory against the model size, capped until
/// `/health` is 200, a time-based fallback, a bar that never moves backwards, and plain words in both languages.
func runColdStartChecks() {
    let gib: UInt64 = 1 << 30
    func sample(_ resident: UInt64?, health: ColdStart.Health = .loading, elapsed: Double = 5, last: Double? = nil) -> ColdStart.Sample {
        ColdStart.Sample(residentBytes: resident, modelBytes: 8 * gib, health: health, elapsed: elapsed, lastLoadSeconds: last)
    }

    check("Cold start: memory against model size, capped below 100 % until the server answers") {
        ColdStart.estimate(sample(2 * gib)) == .loading(fraction: 0.25)
            && ColdStart.estimate(sample(0)) == .loading(fraction: 0)
            // Context buffers on top of the weights: still not "done" before /health is 200.
            && ColdStart.estimate(sample(10 * gib)) == .loading(fraction: ColdStart.cap)
            && ColdStart.estimate(sample(8 * gib, health: .silent)) == .loading(fraction: ColdStart.cap)
            && ColdStart.estimate(sample(1 * gib, health: .ready)) == .warming
    }

    check("Cold start: without a memory reading the last load time estimates, otherwise no number") {
        ColdStart.estimate(sample(nil, elapsed: 10, last: 40)) == .loading(fraction: 0.25)
            && ColdStart.estimate(sample(nil, elapsed: 90, last: 40)) == .loading(fraction: ColdStart.cap)
            && ColdStart.estimate(sample(nil, elapsed: 10)) == .loading(fraction: nil)
            && ColdStart.estimate(ColdStart.Sample(residentBytes: 4 * gib, modelBytes: 0, health: .loading, elapsed: 10, lastLoadSeconds: nil))
                == .loading(fraction: nil)
            && ColdStart.Health(status: 503) == .loading && ColdStart.Health(status: 0) == .silent && ColdStart.Health(status: 200) == .ready
    }

    check("Cold start: the bar never moves backwards, whole percent only, warming stays") {
        var tracker = ColdStart.Tracker()
        let first = tracker.update(sample(nil))                       // nothing measurable yet
        let a = tracker.update(sample(UInt64(Double(8 * gib) * 0.403)))
        let same = tracker.update(sample(UInt64(Double(8 * gib) * 0.405)))   // same whole percent: no redraw
        let back = tracker.update(sample(1 * gib))                     // memory dipped: bar holds
        let b = tracker.update(sample(6 * gib))
        let warm = tracker.update(sample(6 * gib, health: .ready))
        let late = tracker.update(sample(2 * gib))                     // late loading sample after warming
        return first == .loading(fraction: nil) && a == .loading(fraction: 0.4) && same == nil && back == nil
            && b == .loading(fraction: 0.75) && warm == .warming && late == nil && tracker.stage == .warming
    }

    check("Cold start: thought line keeps the order (loading, then warming; late progress dropped)") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: Date())
        line.apply(.phase(.wakingUp(progress: nil)), request: request, at: Date())
        line.apply(.phase(.wakingUp(progress: 0.4)), request: request, at: Date())
        let loading = line.phase == .wakingUp(progress: 0.4)
        line.apply(.phase(.warmingUp), request: request, at: Date())
        line.apply(.phase(.wakingUp(progress: 0.9)), request: request, at: Date())
        let warming = line.phase == .warmingUp && line.isVisible
        line.textArrived(request: request)
        return loading && warming && !line.isVisible
            && WorkPhase.wakingUp(progress: 0.1).kind == WorkPhase.wakingUp(progress: 0.9).kind
            && ColdStart.Stage.loading(fraction: 0.5).phase == .wakingUp(progress: 0.5) && ColdStart.Stage.warming.phase == .warmingUp
    }

    check("Cold start: pill and line in plain words, German and English, no technical terms") {
        let banned = ["model", "modell", "ram", "token", "speicher", "memory", "server", "laden", "load", "gb"]
        var texts: [String] = []
        for language in ["en", "de"] {
            texts += [ColdStart.pillLabel(.wakingUp(progress: 0.3), language: language) ?? "",
                      ColdStart.pillLabel(.warmingUp, language: language) ?? "",
                      L("Waking up…", table: "Thought", language: language), L("Almost ready…", table: "Thought", language: language),
                      L("Takes a moment now, then it’s quicker", table: "Thought", language: language)]
        }
        let german = ColdStart.pillLabel(.wakingUp(progress: nil), language: "de") == "Pippa wird wach …"
            && L("Takes a moment now, then it’s quicker", table: "Thought", language: "de") == "Dauert nur jetzt etwas, danach geht’s schneller"
            && ColdStart.spokenProgress(0.42, language: "de") == "42 Prozent"
        let english = ColdStart.pillLabel(.warmingUp, language: "en") == "Pippa is almost ready…"
            && ColdStart.spokenProgress(0.42, language: "en") == "42 percent"
        let words = texts.allSatisfy { text in
            !text.isEmpty && !banned.contains { word in text.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == word } }
        }
        return german && english && words
            && ColdStart.pillLabel(.writing) == nil && ColdStart.pillLabel(.starting) == nil
            && ColdStart.pillProgress(.wakingUp(progress: 0.6)) == 0.6 && ColdStart.pillProgress(.warmingUp) == nil
    }

    check("Cold start: own process memory is readable") {
        guard let own = ColdStart.memory(pid: getpid()) else { return false }
        return own.resident > 0 && own.footprint > 0 && ColdStart.memory(pid: -1) == nil
    }
}
