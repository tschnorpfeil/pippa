import Foundation

/// Shared by the native tray and Pi's prepare_files tool. Saved requests contain no password or execution authority.
public struct FilePreparationDraft: Codable, Sendable, Equatable {
    public var items: [TrayItem]
    public var sources: [FilePreparationSource]
    public var grants: [DurableJobInput]
    public var plan: FilePreparationPlan
    public init(items: [TrayItem], sources: [FilePreparationSource], grants: [DurableJobInput], plan: FilePreparationPlan) {
        self.items = items; self.sources = sources; self.grants = grants; self.plan = plan
    }
}

public struct FilePreparationSavedResult: Codable, Sendable {
    public var items: [TrayItem]
    public var sources: [TrayItem]
    public init(items: [TrayItem], sources: [TrayItem]) { self.items = items; self.sources = sources }
}
