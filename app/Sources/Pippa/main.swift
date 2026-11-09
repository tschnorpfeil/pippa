import AppKit

// Pi, the oMLX server and Node are children on pipes: if one dies just before a write, the write fails instead of
// SIGPIPE ending Pippa.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
if CommandLine.arguments.dropFirst().contains("--verify-runtime") {
    do { try BundleVerification.run(); exit(0) }
    catch { FileHandle.standardError.write(Data("Bundle verification failed: \(error)\n".utf8)); exit(1) }
}
// Development and acceptance runs: `Pippa --ask "question"` asks through the same Pi path as the window and prints
// what happens (steps, answer, cards) instead of showing it.
if let index = CommandLine.arguments.firstIndex(of: "--ask"), CommandLine.arguments.count > index + 1 {
    let question = CommandLine.arguments[index + 1]
    Task { @MainActor in exit(await HeadlessAsk.run(question)) }
    app.run()
}
// `Pippa --setup`: runs the first-run setup without the window and agrees to the download, printing each state.
if CommandLine.arguments.dropFirst().contains("--setup") {
    Task { @MainActor in exit(await HeadlessAsk.setup()) }
    app.run()
}
if let index = CommandLine.arguments.firstIndex(of: "--make-pdf") {
    let files = CommandLine.arguments.dropFirst(index + 1).map { URL(fileURLWithPath: $0) }
    Task { @MainActor in
        let result = await PippaMCPService.makePDF(files)
        print(result.failed ? "FAILED: \(result.text)" : "\(result.text)\n\(result.card.map { String(describing: $0) } ?? "")")
        exit(result.failed ? 1 : 0)
    }
    app.run()
}
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task { @MainActor in exit(await Snapshots.run(into: folder)) }
    app.run()
}
// `Pippa --check-approvals`: the in-app question flow (Approvals) and the conversation store, without a window.
if CommandLine.arguments.dropFirst().contains("--check-approvals") {
    Task { @MainActor in
        let approvals = await ApprovalsChecks.run()
        exit(max(approvals, ConversationStoreChecks.run()))
    }
    app.run()
}
// Isolated acceptance run: the harness clones the app under a different bundle ID to keep real preferences intact.
if CommandLine.arguments.dropFirst().contains("--check-window-lifecycle") {
    app.setActivationPolicy(.regular)
    Task { @MainActor in exit(await WindowLifecycleChecks.run()) }
    app.run()
}
// First launch from the disk image or Downloads: offer once to move to Applications.
if AppMover.runIfNeeded() { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
// Pippa is a regular Mac app. The menu bar shortcut and optional pill supplement its Dock icon and windows.
app.setActivationPolicy(.regular)
app.run()
