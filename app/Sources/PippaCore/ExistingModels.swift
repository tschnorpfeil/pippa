import Foundation

/// A place on this Mac that belongs to another program: a search folder or a catalog file found there.
public struct ModelLocation: Sendable, Hashable {
    public var url: URL
    /// Where from, for the UI: "LM Studio", "Ollama" …
    public var source: String
    public init(url: URL, source: String) { self.url = url; self.source = source }
}

/// Finds GGUF files from Pippa's catalog that other programs already downloaded (LM Studio, Ollama, Hugging Face,
/// llama.cpp, Jan, GPT4All). They are found only by name and size, without reading anything; adoption happens only after the
/// SHA256 check (`ModelDownloader.adopt`). Foreign files stay untouched.
/// Without the App Sandbox these folders are directly readable (previously a list in Pippa.entitlements allowed it).
public enum ExistingModels {
    /// Real user folder; in the sandbox `NSHomeDirectory()` points into the container.
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Known storage locations (programs' default settings).
    public static func defaultRoots(home: URL = realHome) -> [ModelLocation] {
        [(".lmstudio/models", "LM Studio"),
         (".cache/lm-studio/models", "LM Studio"),
         (".cache/huggingface/hub", "Hugging Face"),
         ("Library/Caches/llama.cpp", "llama.cpp"),
         (".ollama/models/blobs", "Ollama"),
         ("Library/Application Support/Jan", "Jan"),
         ("Library/Application Support/nomic.ai/GPT4All", "GPT4All")]
            .map { ModelLocation(url: home.appendingPathComponent($0.0, isDirectory: true), source: $0.1) }
    }

    /// Found files by SHA256 from the catalog. Fast: only directory entries and sizes, no contents.
    public static func find(_ catalog: ModelCatalog, roots: [ModelLocation] = defaultRoots()) -> [String: ModelLocation] {
        var wanted: [Int64: [(file: CatalogModel.File, repo: String)]] = [:]
        for model in catalog.models {
            for file in model.pinned?.files ?? [] { wanted[file.size, default: []].append((file, model.repo)) }
        }
        var found: [String: ModelLocation] = [:]
        let fm = FileManager.default
        for root in roots where fm.fileExists(atPath: root.url.path) {
            guard let walk = fm.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            var visited = 0
            while let url = walk.nextObject() as? URL {
                visited += 1
                if visited > 50_000 { break }                       // foreign folder: never search endlessly
                if walk.level > 8 { walk.skipDescendants(); continue }
                let name = url.lastPathComponent
                // Hugging Face points from snapshots/ via symlink to blobs/: resolve, size of the real file.
                let real = url.resolvingSymlinksInPath()
                guard let candidates = wanted[ModelDownloader.fileSize(real)] else { continue }
                for (file, repo) in candidates where found[file.sha256] == nil && matches(name: name, file: file, repo: repo) {
                    found[file.sha256] = ModelLocation(url: real, source: root.source)
                }
            }
        }
        return found
    }

    /// Name as with Hugging Face (LM Studio, Jan, GPT4All), with exactly llama.cpp's repo prefix
    /// (`owner_repo_file.gguf`) or named by content (Hugging Face blobs, Ollama: `sha256-…`).
    /// The size must also match; adoption is what verifies the content.
    static func matches(name: String, file: CatalogModel.File, repo: String) -> Bool {
        let expected = (file.path as NSString).lastPathComponent
        return name == expected || name == repo.replacingOccurrences(of: "/", with: "_") + "_" + expected
            || name == file.sha256 || name == "sha256-" + file.sha256
    }
}
