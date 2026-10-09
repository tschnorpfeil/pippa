import Foundation

/// Models Pippa handed out as its standard before and no table row hands out any more. After a table change the old
/// file stays while the new one loads (`PiSetupFlow.fallback`); once the new model has answered, the old one is only
/// taking space. Owner decision 2026-10-09: delete it then, silently.
public enum SupersededModels {
    /// K2 Horizon 7B was the standard from 16 GB until Qwen3.5 9B (docs/rebuild/measurements/model-compare).
    public static let keys: Set<String> = ["k2-horizon-7b"]

    /// Deletes superseded models from Pippa's own model folder after a successful answer with `activeModelID`.
    /// Only when the active model is a table model (a developer's `PIPPA_PI_MODEL` never triggers it), never the active
    /// model, never a table model, never outside `folder` (a shared `~/models` is the person's own and is not passed in).
    /// Removes the file and its `.ok` marker; a hardlink or clone from LM Studio and the like leaves the original untouched.
    /// Returns what was removed.
    @discardableResult
    public static func remove(activeModelID: String, folder: URL, catalog: ModelCatalog = .bundled(),
                              tableKeys: [String] = ModelSelector.tableKeys) -> [URL] {
        guard tableKeys.contains(activeModelID) else { return [] }
        let fm = FileManager.default
        let downloader = ModelDownloader(directory: folder)
        var removed: [URL] = []
        for key in keys.sorted() where key != activeModelID && !tableKeys.contains(key) {
            for file in catalog.model(key)?.pinned?.files ?? [] {
                let url = downloader.localURL(file)
                for target in [url, url.appendingPathExtension("ok")] where (try? fm.attributesOfItem(atPath: target.path)) != nil {
                    if (try? fm.removeItem(at: target)) != nil { removed.append(target) }
                }
            }
        }
        return removed
    }
}
