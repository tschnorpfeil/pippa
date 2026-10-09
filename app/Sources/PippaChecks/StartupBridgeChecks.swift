import Foundation
import PippaCore

/// The first minutes (PippaCore/StartupBridge.swift, AppLocation.swift): which messages Apple Intelligence answers while
/// Pippa's AI loads, that the hand-over token never shows, that Pi gets what was answered in between, and where the
/// app counts as installed.
func runStartupBridgeChecks() {
    func route(_ text: String, files: Bool = false, selected: String = "", skill: Bool = false, system: Bool = true) -> StartupBridge.Route {
        StartupBridge.route(text, hasFiles: files, selectedText: selected, skill: skill, systemModel: system)
    }

    check("Start bridge: plain questions get a quick answer while Pippa's AI loads") {
        route("Wie lange kocht ein weiches Ei?") == .quick
            && route("Was ist der Unterschied zwischen Brutto und Netto?") == .quick
            && route("Write me a short birthday poem for my sister.") == .quick
            && route("What does briefly mean?") == .quick
            && route("Kannst du mir ein Rezept für Pfannkuchen geben?") == .quick
    }

    check("Start bridge: files, mail, calendar, the web and changes wait for Pi") {
        route("Wo ist die Rechnung von der Heizung?") == .waitForPi
            && route("Räum meine Downloads auf") == .waitForPi
            && route("Beantworte die E-Mail von Anna") == .waitForPi
            && route("Hab ich morgen einen Termin?") == .waitForPi
            && route("Wie wird das Wetter morgen?") == .waitForPi
            && route("Erinnere mich um 5 an den Müll") == .waitForPi
            && route("What's in this letter?") == .waitForPi
            && route("Find my tax documents") == .waitForPi
            && route("Can you open my calendar?") == .waitForPi
    }

    check("Start bridge: attachments, skills, long text and no Apple Intelligence wait for Pi") {
        route("Was steht da drin?", files: true) == .waitForPi
            && route("Erklär das einfach", skill: true) == .waitForPi
            && route("Wie lange kocht ein Ei?", system: false) == .waitForPi
            && route("Erklär mir das", selected: String(repeating: "Text ", count: 400)) == .waitForPi
            && route("Erklär mir das", selected: "Ein kurzer Satz.") == .quick
            && route(String(repeating: "Frage ", count: 400)) == .waitForPi
    }

    check("Start bridge: the hand-over token is kept back until the answer is clear, then never shown") {
        StartupBridge.opening("") == .undecided
            && StartupBridge.opening("[") == .undecided
            && StartupBridge.opening("[[WA") == .undecided
            && StartupBridge.opening("[[WAIT]]") == .deferred
            && StartupBridge.opening(" WAIT") == .deferred
            && StartupBridge.opening("W") == .undecided
            && StartupBridge.opening("Wa") == .undecided
            && StartupBridge.opening("Was") == .answer
            && StartupBridge.opening("Ein weiches Ei") == .answer
            && StartupBridge.cleaned("Gern! [[WAIT]]") == "Gern!"
            && StartupBridge.cleaned(" [[WAIT]] ") == nil
    }

    check("Start bridge: instructions in the app's language, with today's date and the hand-over rule") {
        let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 10, day: 9).date!
        let de = StartupBridge.instructions(language: "de", today: day)
        let en = StartupBridge.instructions(language: "en", today: day)
        return de.contains("Pippa") && de.contains("9. Oktober 2026") && de.contains(StartupBridge.waitToken) && de.contains("Duze")
            && en.contains("October 9, 2026") && en.contains(StartupBridge.waitToken) && !en.contains("Duze")
    }

    check("Start bridge: earlier quick answers go along, newest kept, and Pi gets them once it is ready") {
        let turns = [StartupBridge.Turn(person: "Wie lange kocht ein Ei?", pippa: "Etwa sieben Minuten."),
                     StartupBridge.Turn(person: "Und ein hartes?", pippa: "Zehn Minuten.")]
        let prompt = StartupBridge.prompt("Und Wachteleier?", selectedText: "", history: turns, language: "de")
        let handover = StartupBridge.handover("Such mir ein Rezept in meinen Dokumenten", history: turns, language: "de")
        let many = (0..<200).map { StartupBridge.Turn(person: "Frage \($0)", pippa: String(repeating: "Antwort ", count: 10)) }
        let trimmed = StartupBridge.prompt("Noch eine?", selectedText: "", history: many, language: "de")
        return prompt.contains("Etwa sieben Minuten.") && prompt.hasSuffix("Und Wachteleier?")
            && handover.contains("Zehn Minuten.") && handover.hasSuffix("Such mir ein Rezept in meinen Dokumenten")
            && StartupBridge.handover("Hallo", history: [], language: "de") == "Hallo"
            && trimmed.contains("Frage 199") && !trimmed.contains("Frage 0\n") && trimmed.count < 2600
    }

    check("App location: Applications counts as installed; disk image, Downloads copy and elsewhere do not") {
        let home = URL(fileURLWithPath: "/Users/anna", isDirectory: true)
        return AppLocation.place(of: URL(fileURLWithPath: "/Applications/Pippa.app"), home: home) == .applications
            && AppLocation.place(of: URL(fileURLWithPath: "/Users/anna/Applications/Pippa.app"), home: home) == .applications
            && AppLocation.place(of: URL(fileURLWithPath: "/Volumes/Pippa/Pippa.app"), home: home)
                == .volume(URL(fileURLWithPath: "/Volumes/Pippa", isDirectory: true))
            && AppLocation.place(of: URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Pippa.app"), home: home) == .translocated
            && AppLocation.place(of: URL(fileURLWithPath: "/Users/anna/Downloads/Pippa.app"), home: home) == .elsewhere
            && AppLocation.destination(appName: "Pippa.app", systemApplicationsWritable: true, home: home).path == "/Applications/Pippa.app"
            && AppLocation.destination(appName: "Pippa.app", systemApplicationsWritable: false, home: home).path == "/Users/anna/Applications/Pippa.app"
    }
}
