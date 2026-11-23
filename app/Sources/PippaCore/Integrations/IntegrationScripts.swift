import Foundation

/// For checks only: can the scripts be compiled? (Only reads the apps' dictionaries, sends nothing.)
public enum IntegrationScripts {
    /// Pure native-response parser checks: descriptors are supplied by the check, never obtained from Mail.
    public static func mailSearchMailboxes(_ response: NSAppleEventDescriptor) throws -> [MailLocator] {
        try MailReplyScript.searchMailboxes(ScriptValue(response).items)
    }

    /// The per-account answers (`{"ok", payload}` or a reason), parsed without Mail.
    public static func mailAccountPayload(_ response: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try MailAccountParse.payload(response)
    }

    public static func mailAccountMessageIsAmbiguous(_ response: NSAppleEventDescriptor) -> Bool { MailScript.isAmbiguous(response) }

    public static func mailMessage(_ response: NSAppleEventDescriptor) -> MailMessage? { MailScript.message(response) }

    public static func mailSearchMatches(_ response: NSAppleEventDescriptor, in box: MailLocator) throws -> [MailLocator] {
        try MailReplyScript.searchMatches(ScriptValue(response).items, in: box)
    }

    /// Name and text of all scripts, for `compileAll` and the check that only `MailSend` calls `send`, once.
    public static var sources: [(name: String, source: String)] {
        var all = [("Mail", MailScript.source), ("MailReply", MailReplyScript.source), ("MailSearch", MailSearchScript.source), ("MailAccounts", MailAccountScript.source),
                   ("MailMove", MailAccountScript.moveSource), ("MailSend", MailSendScript.source), ("Excel", ExcelScript.source),
                   ("PhotosSearch", PhotosSearchScript.source), ("PhotosShow", PhotosShowScript.source), ("Notes", NotesScript.source),
                   ("Safari", FrontAppScript.safari), ("Chrome", FrontAppScript.chrome), ("FrontDocument", FrontAppScript.documentSource)]
        #if DEBUG || PIPPA_PROBES
        all.insert(("MailMoveDiagnose", MailAccountScript.diagnoseSource), at: 5)
        all.insert(("MailSendProbe", MailSendProbeLive.source), at: 7)
        #endif
        return all
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
