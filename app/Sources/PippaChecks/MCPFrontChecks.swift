import Foundation
import PippaCore

extension MCPCheckContext {
    func excelChecks() async {
        // MARK: Excel

        await checkAsync("MCP excel_selection: sheet with values and formulas (stand-in), plain text without permission") {
            let s = setup()
            let r = await call(s.tools, "excel_selection")
            let sheet = (r.json["data"] as? [String: Any])?["sheet"] as? String ?? ""
            let no = setup(granted: false)
            let notYet = await call(no.tools, "excel_selection")
            return !r.isError && sheet.contains("Kosten 2026") && sheet.contains("[=SUM(B2:B4)]") && r.json["untrusted"] as? Bool == true
                && notYet.isError && notYet.json["status"] as? String == "needs_access"
        }
    }

    func frontChecks() async {
        // MARK: App in front

        check("Front app label: app and title on one line, cut at 80 characters; title equal to the name is left out") {
            let safari = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: "Mietrecht Kaution – Beispielseite")
            let plain = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 2, title: "TextEdit")
            let long = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: String(repeating: "Kaution ", count: 30) + "\nzweite Zeile")
            let cut = long.shortTitle ?? ""
            return safari.label(german: true) == "[Im Vordergrund: Safari – „Mietrecht Kaution – Beispielseite“]"
                && safari.label(german: false) == "[In front: Safari – “Mietrecht Kaution – Beispielseite”]"
                && plain.label(german: true) == "[Im Vordergrund: TextEdit]"
                && cut.count == FrontApp.titleLimit && cut.hasSuffix("…") && !cut.contains("\n")
        }
        await checkAsync("MCP front_read: only the chip's app; page text as untrusted data; without chip, permission or window plain text") {
            let safari = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: "Mietkaution – Beispielseite")
            func host(_ shown: FrontApp?, _ front: DemoFrontApp, notes: Box<PippaMCPReadNote>? = nil, asked: Box<String>? = nil) -> PippaMCPTools {
                let demo = DemoIntegrations(granted: true)
                var h = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                     askForAccess: asked != nil, now: { now }, calendar: berlin,
                                     explainAccess: { subject, sentence in asked?.append("\(subject.appName)|\(sentence)"); return true },
                                     onRead: { notes?.append($0) })
                h.shownFront = { shown }
                h.front = front
                return PippaMCPTools(host: h)
            }
            let notes = Box<PippaMCPReadNote>()
            let read = await call(host(safari, DemoFrontApp(), notes: notes), "front_read")
            let data = read.json["data"] as? [String: Any] ?? [:]
            let none = await call(host(nil, DemoFrontApp()), "front_read")
            let denied = await call(host(safari, DemoFrontApp(access: .denied)), "front_read")
            let empty = await call(host(safari, DemoFrontApp(content: nil)), "front_read")
            let asked = Box<String>()
            let first = await call(host(safari, DemoFrontApp(access: .notDetermined), asked: asked), "front_read")
            return !read.isError && read.json["untrusted"] as? Bool == true && data["app"] as? String == "Safari"
                && (data["text"] as? String)?.contains("drei Nettokaltmieten") == true && data["url"] as? String == "https://beispiel.example/kaution"
                && notes.all.first?.line == L("Read %@: “%@”", table: "MCP", "Safari", "Mietkaution – Beispielseite")
                && none.isError && none.json["status"] as? String == "nothing_shown"
                && denied.isError && (denied.json["tell"] as? String)?.contains("Automation") == true
                && empty.isError && empty.json["status"] as? String == "nothing_open"
                && !first.isError && asked.all == ["Safari|\(PippaMCPTools.accessExplanation(.front("Safari")))"]
        }
        await checkAsync("MCP front_read: with Mail in front it reads the selected mail (same receipt as mail_selected)") {
            let notes = Box<PippaMCPReadNote>()
            let demo = DemoIntegrations(granted: true)
            var h = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                 askForAccess: false, now: { now }, calendar: berlin, onRead: { notes.append($0) })
            h.shownFront = { FrontApp(name: "Mail", bundleID: Integration.mail.bundleIdentifier, pid: 3) }
            h.front = DemoFrontApp(access: .denied)
            let r = await call(PippaMCPTools(host: h), "front_read")
            let direct = await call(setup().tools, "mail_selected")
            return !r.isError && (r.json["data"] as? [String: Any])?["subject"] as? String == (direct.json["data"] as? [String: Any])?["subject"] as? String
                && notes.all.first?.tool == "mail_selected"
        }
    }
}
