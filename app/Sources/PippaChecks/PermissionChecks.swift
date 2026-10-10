import Foundation
import PippaCore

// "What Pippa may do": checking never asks, each Allow asks only its own permission, answers are remembered.
func runPermissionChecks() async {
    print("\n— Permissions —")

    let name = "permission-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { dropDefaultsSuite(defaults, name) }
    let home = fm.temporaryDirectory.appendingPathComponent("pippa-permission-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    for folder in ["Desktop", "Documents", "Downloads"] {
        try? fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let asked = AskLog()
    let desk = SystemPermissions(access: { $0 == .calendar ? .notDetermined : .unavailable("Mail ist nicht offen") },
                                 request: { await asked.add($0); return .granted },
                                 defaults: defaults, home: home)

    await checkAsync("Permissions: folders never asked show Allow, without reading them") {
        let state = await desk.state(.folders)
        return state == .notAsked
    }
    await checkAsync("Permissions: Allow reads the folders once, the answer is remembered") {
        let first = await desk.request(.folders)
        let later = await desk.state(.folders)
        return first == .granted && later == .granted
    }
    await checkAsync("Permissions: a folder that refuses reading counts as declined") {
        let locked = home.appendingPathComponent("Documents")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let answer = await desk.request(.folders)
        let later = await desk.state(.folders)
        return answer == .denied && later == .denied
    }
    await checkAsync("Permissions: Calendar comes from the integrations, asking only the one pressed") {
        let calendar = await desk.state(.calendar)
        let granted = await desk.request(.calendar)
        let log = await asked.all
        return calendar == .notAsked && granted == .granted && log == [.calendar]
    }
    check("Permissions: a row without its dialog text in Info.plist stays hidden (macOS would end the app)") {
        !desk.applies(.contacts) && !desk.applies(.photos) && !desk.applies(.folders)
    }
    await checkAsync("Permissions: demo asks only the pressed row; declined stays declined") {
        let demo = DemoPermissions()
        let reminders = await demo.request(.reminders)
        let photos = await demo.request(.photos)
        let notes = await demo.state(.notes)
        return reminders == .granted && photos == .denied && notes == .notAsked
    }
}

private actor AskLog {
    private(set) var all: [Integration] = []
    func add(_ integration: Integration) { all.append(integration) }
}
