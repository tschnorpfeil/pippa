import AppKit
import Foundation
import PippaCore

/// Read-only probe in the original signed executable. No AppModel, preferences, history,
/// model download or updater. A modified notarized copy is no longer a useful launch test.
@MainActor
enum BundleVerification {
    static func run() throws {
        progress("start")
        DisplayFont.register()
        let bundle = Bundle.main.bundleURL
        // Checks what the Pi RPC path needs (install payload, Pippa's fetcher, capabilities), no longer
        // the old runtime `pi-runtime`.
        let release = bundle.appendingPathComponent("Contents/Resources/pi-payload/release")
        let web = bundle.appendingPathComponent("Contents/Resources/pippa-web")
        let piManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: release.appendingPathComponent("package.json"))) as? [String: Any]
        guard let dependencies = piManifest?["dependencies"] as? [String: String],
              let piVersion = dependencies["@earendil-works/pi-coding-agent"] else { throw Failure.piVersion }
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: PippaSkill.bundledDirectory().path)) ?? []).filter { !$0.hasPrefix(".") }
        guard !PippaSkill.bundled.isEmpty, PippaSkill.bundled.count == folders.count else { throw Failure.missingSkills }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/node-release.json"))) as? [String: Any]
        guard let version = manifest?["version"] as? String else { throw Failure.nodeVersion }
        progress("resources_ok")
        let llama = try child(bundle, "llama-server", ["--version"])
        guard llama.contains("version:") else { throw Failure.llama }
        progress("llama_ok")
        let native = release.appendingPathComponent("node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-arm64/darwin-platform.node")
        let js = """
        const fetcher=await import(process.argv[1]);
        if(typeof fetcher.createFetcher!=='function'||typeof fetcher.serve!=='function')throw Error('fetcher exports missing');
        await import(process.argv[2]);
        const {createRequire}=await import('node:module');
        createRequire(import.meta.url)(process.argv[3]);
        const esbuild=await import(process.argv[4]);
        const result=await esbuild.transform('const x:number=1',{loader:'ts'});
        if(!result.code.includes('const x = 1'))throw Error('esbuild failed');
        if(process.version!==process.argv[5])throw Error('Node version mismatch');
        console.log('pippa_node_ok',process.version);
        """
        // pi-web-access reads its settings folder on import: an empty one, never ~/.pi.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let node = try child(bundle, "node", ["--input-type=module", "-e", js,
            web.appendingPathComponent("src/fetcher.mjs").absoluteString, web.appendingPathComponent("src/generated/extract.mjs").absoluteString,
            native.path, release.appendingPathComponent("node_modules/esbuild/lib/main.js").absoluteString, version],
            environment: ["PI_CODING_AGENT_DIR": empty.path, "HOME": empty.path])
        guard node.contains("pippa_node_ok") else { throw Failure.nodeVersion }
        let pi = try child(bundle, "node", [release.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js").path, "--version"],
                           environment: ["HOME": empty.path, "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1", "PI_TELEMETRY": "0"])
        guard pi.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(piVersion) else { throw Failure.piVersion }
        progress("node_ok")
        print("pippa_bundle_ok skills=\(PippaSkill.bundled.count) node=\(version) pi=\(piVersion) web=ok")
    }

    private static func progress(_ stage: String) {
        FileHandle.standardOutput.write(Data("pippa_probe \(stage)\n".utf8))
    }

    private static func child(_ bundle: URL, _ name: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = bundle.appendingPathComponent("Contents/Helpers/" + name)
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            merged.merge(environment) { _, new in new }
            process.environment = merged
        }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.child(name, process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }

    enum Failure: Error { case missingSkills, nodeVersion, piVersion, llama, child(String, Int32) }
}
