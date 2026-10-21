import Foundation

/// A retry belongs to the exact ordered selection that failed. Native file tools only read these originals and
/// create new results, so a deliberate retry cannot replay a change to an original or an external application.
public struct NativeFileRequest: Sendable, Equatable {
    public let tool: ToolID
    public let inputIDs: [UUID]

    public init(tool: ToolID, inputIDs: [UUID]) {
        self.tool = tool
        self.inputIDs = inputIDs
    }

    public func matches(_ currentIDs: [UUID]) -> Bool {
        !inputIDs.isEmpty && inputIDs == currentIDs
    }
}
