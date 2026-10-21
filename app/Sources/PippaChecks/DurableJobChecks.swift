import Foundation
import PippaCore
import SQLite3

private func durableFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-durable-check-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
}

private func durableFixtureSQL(_ databaseURL: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw DurableJobError.persistenceFailed }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw DurableJobError.persistenceFailed }
}

private func durableChild(_ directory: URL, hold: Bool) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var environment = ProcessInfo.processInfo.environment
    environment["PIPPA_DURABLE_JOB_CHECKS"] = "1"
    environment["PIPPA_DURABLE_JOB_CHILD_DIRECTORY"] = directory.path
    environment["PIPPA_DURABLE_JOB_CHILD_HOLD"] = hold ? "1" : "0"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func runDurableJobChecks() async {
    // A real subprocess establishes a distinct production process session and PID; it never touches personal data.
    if let path = ProcessInfo.processInfo.environment["PIPPA_DURABLE_JOB_CHILD_DIRECTORY"] {
        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let store = try DurableJobStore(baseDirectory: directory)
            let record = try await store.create(kind: .filePreparation, requestKey: "child-process", title: "Synthetic child")
            _ = try await store.start(id: record.id, expectedRevision: record.revision)
            try Data(record.id.uuidString.utf8).write(to: directory.appendingPathComponent("child-started"), options: .atomic)
            if ProcessInfo.processInfo.environment["PIPPA_DURABLE_JOB_CHILD_HOLD"] == "1" {
                try await Task.sleep(for: .seconds(30))
            }
            exit(0)
        } catch { exit(1) }
    }

    await checkAsync("Durable jobs: request dedup preserves immutable input order and payload across independent connections") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.txt"), secondURL = directory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL); try Data("second".utf8).write(to: secondURL)
        let inputs = try [firstURL, secondURL].map { try DurableJobInput.capture(url: $0) }
        let first = try DurableJobStore(baseDirectory: directory), second = try DurableJobStore(baseDirectory: directory)
        let payload = Data("original choices".utf8)
        let record = try await first.create(kind: .filePreparation, requestKey: "same-request", title: "Prepare files", inputs: inputs, payload: payload)
        let duplicate = try await second.create(kind: .filePreparation, requestKey: "same-request", title: "Localized display title", inputs: inputs, payload: payload)
        do {
            _ = try await second.create(kind: .filePreparation, requestKey: "same-request", title: "Prepare files", inputs: inputs.reversed(), payload: payload)
            return false
        } catch DurableJobError.requestConflict { }
        do {
            _ = try await first.create(kind: .filePreparation, requestKey: "same-request", title: "Prepare files", inputs: inputs, payload: Data("new choices".utf8))
            return false
        } catch DurableJobError.requestConflict { }
        let all = try await second.records()
        return duplicate == record && all.count == 1 && all[0].inputs.map(\.url) == [firstURL, secondURL] && all[0].payload == payload
    }

    await checkAsync("Durable jobs: concurrent connections admit one request and one running revision") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DurableJobStore(baseDirectory: directory), second = try DurableJobStore(baseDirectory: directory)
        async let a = first.create(kind: .morningBriefing, requestKey: "today", title: "Morning")
        async let b = second.create(kind: .morningBriefing, requestKey: "today", title: "Morning")
        let records = try await [a, b]
        guard records[0].id == records[1].id else { return false }
        let run = try await first.start(id: records[0].id, expectedRevision: 0)
        do { _ = try await second.start(id: records[0].id, expectedRevision: 0); return false }
        catch DurableJobError.staleRevision { }
        let reopened = try DurableJobStore(baseDirectory: directory)
        let current = try await reopened.record(id: run.jobID)
        return current.state == .running && current.runToken == run.token && current.revision == 1
    }

    await checkAsync("Durable jobs: restart requires attention, retains request, and refuses the former callback") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DurableJobStore(baseDirectory: directory, processSessionID: UUID())
        let record = try await first.create(kind: .filePreparation, requestKey: "interrupted", title: "Prepare", payload: Data("saved".utf8))
        let run = try await first.start(id: record.id, expectedRevision: record.revision)
        let restarted = try DurableJobStore(baseDirectory: directory, processSessionID: UUID())
        let restored = try await restarted.record(id: record.id)
        guard restored.state == .needsAttention, restored.runToken == nil, restored.issue == "interrupted",
              restored.payload == record.payload, restored.revision == 2 else { return false }
        do { _ = try await first.finish(run: run, state: .completed); return false }
        catch DurableJobError.staleRevision { }
        do { _ = try await restarted.start(id: restored.id, expectedRevision: restored.revision); return false }
        catch DurableJobError.invalidTransition { }
        let queued = try await restarted.retry(id: restored.id, expectedRevision: restored.revision)
        let next = try await restarted.start(id: queued.id, expectedRevision: queued.revision)
        return next.token != run.token && next.revision > run.revision
    }

    await checkAsync("Durable jobs: a real process exit leaves an interrupted run that a new owner cannot replay") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = try durableChild(directory, hold: false)
        let deadline = ContinuousClock.now + .seconds(10)
        while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !child.isRunning else { child.terminate(); child.waitUntilExit(); return false }
        guard child.terminationStatus == 0 else { return false }
        let restarted = try DurableJobStore(baseDirectory: directory)
        guard let record = try await restarted.records().first else { return false }
        do { _ = try await restarted.start(id: record.id, expectedRevision: record.revision); return false }
        catch DurableJobError.invalidTransition { }
        return record.state == .needsAttention && record.issue == "interrupted" && record.runToken == nil
    }

    await checkAsync("Durable jobs: another live process is not mistaken for a restart or allowed to double-start") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = try durableChild(directory, hold: true)
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let marker = directory.appendingPathComponent("child-started")
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: marker.path), child.isRunning else { return false }
        let other = try DurableJobStore(baseDirectory: directory)
        guard let record = try await other.records().first, record.state == .running, record.revision == 1 else { return false }
        do { _ = try await other.start(id: record.id, expectedRevision: record.revision); return false }
        catch DurableJobError.invalidTransition { }
        child.terminate(); child.waitUntilExit()
        let restarted = try DurableJobStore(baseDirectory: directory)
        return try await restarted.record(id: record.id).state == .needsAttention
    }

    await checkAsync("Durable jobs: Stop durably fences late completion and an explicit retry gets a new token") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .filePreparation, requestKey: "stop", title: "Prepare")
        let old = try await store.start(id: record.id, expectedRevision: 0)
        let stopped = try await store.cancel(id: record.id, expectedRevision: old.revision)
        do { _ = try await store.finish(run: old, state: .completed, resultData: Data("late".utf8)); return false }
        catch DurableJobError.staleRevision { }
        let queued = try await store.retry(id: record.id, expectedRevision: stopped.revision)
        let next = try await store.start(id: queued.id, expectedRevision: queued.revision)
        do { _ = try await store.finish(run: old, state: .failed); return false }
        catch DurableJobError.staleRevision { }
        let result = try await store.finish(run: next, state: .completed, resultData: Data("current".utf8))
        return result.state == .completed && result.resultData == Data("current".utf8)
    }

    await checkAsync("Durable jobs: Stop fences its just-committed completion but cannot cancel a later attempt") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .filePreparation, requestKey: "stop-during-delivery", title: "Prepare")
        let old = try await store.start(id: record.id, expectedRevision: 0)
        _ = try await store.finish(run: old, state: .completed, resultData: Data("delivering".utf8))
        let cancelled = try await store.cancel(run: old)
        guard cancelled.state == .cancelled else { return false }
        let queued = try await store.retry(id: record.id, expectedRevision: cancelled.revision)
        let next = try await store.start(id: record.id, expectedRevision: queued.revision)
        do { _ = try await store.cancel(run: old); return false }
        catch DurableJobError.staleRevision { }
        let final = try await store.finish(run: next, state: .completed, resultData: Data("new result".utf8))
        do { _ = try await store.cancel(run: old); return false }
        catch DurableJobError.staleRevision { }
        return try await store.record(id: record.id) == final
    }

    await checkAsync("Durable jobs: completed results survive restart and dismissal cannot resurrect them") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .morningBriefing, requestKey: "briefing-day", title: "Today")
        let run = try await store.start(id: record.id, expectedRevision: 0)
        let done = try await store.finish(run: run, state: .completed, resultData: Data("one card".utf8))
        let reopened = try DurableJobStore(baseDirectory: directory, processSessionID: UUID())
        guard try await reopened.record(id: record.id) == done else { return false }
        let dismissed = try await reopened.cancel(id: record.id, expectedRevision: done.revision)
        let duplicate = try await store.create(kind: .morningBriefing, requestKey: "briefing-day", title: "Today")
        return duplicate == dismissed && duplicate.state == .cancelled && duplicate.resultData == done.resultData
    }

    await checkAsync("Durable jobs: changed sources are rejected, including same-length edits with restored modification time") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        try Data("before".utf8).write(to: source)
        let input = try DurableJobInput.capture(url: source)
        guard try input.resolvedURL() == source else { return false }
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: input.identity.modified], ofItemAtPath: source.path)
        do { _ = try input.resolvedURL(); return false }
        catch DurableJobError.sourceChanged { return true }
    }

    await checkAsync("Durable jobs: artifacts are promoted out of caches, survive pruning, and read back across restarts") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let temporary = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("ready.pdf")
        try Data("synthetic verified result".utf8).write(to: source)
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .filePreparation, requestKey: "retained", title: "Prepare")
        let run = try await store.start(id: record.id, expectedRevision: 0)
        let artifact = try await store.retainArtifact(from: source, run: run)
        _ = try await store.finish(run: run, state: .completed, resultData: Data("card".utf8), artifacts: [artifact])
        _ = InboxCleanup.prune(cache, keeping: [], maxAge: 0, now: Date().addingTimeInterval(3600))
        let reopened = try DurableJobStore(baseDirectory: directory, processSessionID: UUID())
        let restored = try await reopened.verifiedArtifacts(id: record.id)
        let contents = try Data(contentsOf: artifact.url)
        return restored == [artifact] && !FileManager.default.fileExists(atPath: source.path)
            && artifact.url.path.hasPrefix(DurableJobStore.artifactsDirectory(baseDirectory: directory).path + "/")
            && contents == Data("synthetic verified result".utf8)
    }

    await checkAsync("Durable jobs: output ownership excludes external paths, other jobs, symlinks, and hardlinks") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let first = try await store.create(kind: .filePreparation, requestKey: "one", title: "One")
        let second = try await store.create(kind: .filePreparation, requestKey: "two", title: "Two")
        let run = try await store.start(id: first.id, expectedRevision: 0)
        let otherRun = try await store.start(id: second.id, expectedRevision: 0)
        let source = directory.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: source)
        do { _ = try await store.makeArtifact(url: source, run: run); return false }
        catch DurableJobError.artifactOutsideJob { }
        let other = try await store.retainArtifact(from: source, run: otherRun)
        do { _ = try await store.finish(run: run, state: .completed, artifacts: [other]); return false }
        catch DurableJobError.artifactOutsideJob { }
        let owned = try await store.artifactDirectory(for: run)
        let symlink = owned.appendingPathComponent("link.txt"), hardlink = owned.appendingPathComponent("hard.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)
        for url in [symlink, hardlink] {
            do { _ = try await store.makeArtifact(url: url, run: run); return false }
            catch DurableJobError.artifactOutsideJob { }
        }
        return try await store.record(id: first.id).state == .running
    }

    await checkAsync("Durable jobs: redirected artifact directory is rejected before creating files outside the job") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .filePreparation, requestKey: "link-directory", title: "Prepare")
        let run = try await store.start(id: record.id, expectedRevision: 0)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: DurableJobStore.artifactsDirectory(baseDirectory: directory), withDestinationURL: outside)
        do { _ = try await store.artifactDirectory(for: run); return false }
        catch DurableJobError.artifactOutsideJob { }
        return try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty
    }

    await checkAsync("Durable jobs: altered output blocks completion and restored readback") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .filePreparation, requestKey: "altered", title: "Prepare")
        let run = try await store.start(id: record.id, expectedRevision: 0)
        let output = try await store.artifactDirectory(for: run).appendingPathComponent("ready.txt")
        try Data("original".utf8).write(to: output)
        let artifact = try await store.makeArtifact(url: output, run: run)
        try Data("changed".utf8).write(to: output)
        do { _ = try await store.finish(run: run, state: .completed, artifacts: [artifact]); return false }
        catch DurableJobError.artifactChanged { }
        let currentArtifact = try await store.makeArtifact(url: output, run: run)
        _ = try await store.finish(run: run, state: .completed, artifacts: [currentArtifact])
        try Data("changed again".utf8).write(to: output)
        do { _ = try await store.verifiedArtifacts(id: record.id); return false }
        catch DurableJobError.artifactChanged { return true }
    }

    await checkAsync("Durable jobs: pruning retires only old cancelled copies, preserving referenced, completed, edited, and redirected outputs") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let source = directory.appendingPathComponent("source.txt")
        try Data("owned copy".utf8).write(to: source)
        var artifacts: [DurableJobArtifact] = []
        for index in 0..<5 {
            let record = try await store.create(kind: .filePreparation, requestKey: "prune-\(index)", title: "Prepare")
            let run = try await store.start(id: record.id, expectedRevision: 0)
            let artifact = try await store.retainArtifact(from: source, run: run)
            artifacts.append(artifact)
            let done = try await store.finish(run: run, state: .completed, artifacts: [artifact])
            if index != 2 { _ = try await store.cancel(id: record.id, expectedRevision: done.revision) }
        }
        // A person-edited output and a directory containing a link must stay untouched.
        try Data("person edited this".utf8).write(to: artifacts[3].url)
        let link = artifacts[4].url.deletingLastPathComponent().appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let early = try await store.pruneCancelledArtifacts(keeping: [], now: Date().addingTimeInterval(3600))
        let removed = try await store.pruneCancelledArtifacts(keeping: [artifacts[1].url], now: Date().addingTimeInterval(2 * 86_400))
        let remaining = artifacts.map { FileManager.default.fileExists(atPath: $0.url.path) }
        let correct = early == 0 && removed == 1 && remaining == [false, true, true, true, true]
            && FileManager.default.fileExists(atPath: source.path)
        if !correct { print("    Prune counts early=\(early), removed=\(removed); remaining=\(remaining)") }
        return correct
    }

    await checkAsync("Durable jobs: SQLite write failure leaves the former state and never reports completion") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        let record = try await store.create(kind: .filePreparation, requestKey: "write-failure", title: "Prepare")
        let run = try await store.start(id: record.id, expectedRevision: 0)
        try durableFixtureSQL(store.databaseURL, "CREATE TRIGGER fail_write BEFORE UPDATE ON durable_jobs BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END;")
        do { _ = try await store.finish(run: run, state: .completed, resultData: Data("must not appear".utf8)); return false }
        catch DurableJobError.persistenceFailed { }
        let unchanged = try await store.record(id: record.id)
        try durableFixtureSQL(store.databaseURL, "DROP TRIGGER fail_write;")
        let done = try await store.finish(run: run, state: .completed)
        return unchanged.state == .running && unchanged.revision == run.revision && unchanged.resultData == nil && done.state == .completed
    }

    await checkAsync("Durable jobs: corrupt or mismatched records block opening and all later mutations without deletion") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        _ = try await store.create(kind: .filePreparation, requestKey: "corrupt", title: "Prepare")
        try durableFixtureSQL(store.databaseURL, "UPDATE durable_jobs SET record='broken';")
        do { _ = try DurableJobStore(baseDirectory: directory); return false }
        catch DurableJobError.unreadable { }
        do { _ = try await store.create(kind: .morningBriefing, requestKey: "unrelated", title: "Today"); return false }
        catch DurableJobError.unreadable { }
        return FileManager.default.fileExists(atPath: store.databaseURL.path)
    }

    await checkAsync("Durable jobs: future schemas and unwritable destinations fail closed") {
        let directory = try durableFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableJobStore(baseDirectory: directory)
        try durableFixtureSQL(store.databaseURL, "PRAGMA user_version=2;")
        do { _ = try DurableJobStore(baseDirectory: directory); return false }
        catch DurableJobError.unsupportedVersion { }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: file)
        do { _ = try DurableJobStore(baseDirectory: file); return false }
        catch DurableJobError.persistenceFailed { }
        return try Data(contentsOf: file) == Data("preserve".utf8)
    }
}
