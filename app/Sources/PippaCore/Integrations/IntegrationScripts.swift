import Foundation

/// For checks only: can the scripts be compiled? (Only reads the apps' dictionaries, sends nothing.)
public enum IntegrationScripts {
    /// Pure native-response parser checks: descriptors are supplied by the check, never obtained from Mail.
    public static func mailSearchMailboxes(_ response: NSAppleEventDescriptor) throws -> [MailLocator] {
        try MailReplyScript.searchMailboxes(ScriptValue(response).items)
    }

    public static func mailSearchMatches(_ response: NSAppleEventDescriptor, in box: MailLocator) throws -> [MailLocator] {
        try MailReplyScript.searchMatches(ScriptValue(response).items, in: box)
    }

    /// Name and text of all scripts, for `compileAll` and the check that none calls `send`.
    public static var sources: [(name: String, source: String)] {
        [("Mail", MailScript.source), ("MailReply", MailReplyScript.source), ("MailSearch", MailSearchScript.source), ("Excel", ExcelScript.source),
         ("PhotosSearch", PhotosSearchScript.source), ("PhotosShow", PhotosShowScript.source),
         ("Safari", FrontAppScript.safari), ("Chrome", FrontAppScript.chrome), ("FrontDocument", FrontAppScript.documentSource)]
    }

    /// Scripts for apps that are not part of macOS. Their terms (`active workbook`, `used range` ...) exist only in the
    /// app's dictionary; without the app the script cannot be compiled (AppleScript then asks for the app).
    /// CI has no Excel: there "Excel" is missing from the result of `compileAll` instead of being `false`. Chrome likewise.
    public static let thirdPartyApps: [String: String] = ["Excel": ExcelScript.bundleIdentifier, "Chrome": FrontApp.chrome]

    @MainActor
    public static func compileAll() -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (name, source) in sources {
            if let bundle = thirdPartyApps[name], !AppleEvents.isInstalled(bundle: bundle) { continue }
            var error: NSDictionary?
            out[name] = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
        }
        return out
    }
}
