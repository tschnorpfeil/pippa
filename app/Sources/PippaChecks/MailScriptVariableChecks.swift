import AppKit
import Carbon
import Foundation
import PippaCore

/// AppleScript compiles a handler that reads a variable nobody set (`item 5 of current`) without complaint; it fails
/// only when that line runs, against the real Mail. These checks find such reads without Mail:
///
/// - `undefinedVariables` asks the AppleScript compiler which words are variables (its own formatting styles them as
///   "variables and subroutine names") and reports, per handler, each one that is neither a parameter, nor set in that
///   handler (`set x to`, `set {x, y} to`, `repeat with x`, `on error … number x`, `copy … to x`), nor a handler or a
///   top-level script object, nor called (`my f(…)`, `NSDate's now()`: a missing handler fails differently).
///   It cannot tell order or branches apart: a variable read before it is set, or set only in one branch of an `if`,
///   passes. It cannot see a wrong but defined variable, a wrong property of Mail, or anything Mail does at runtime.
/// - The pure handlers of the send script (no `tell`, no Apple Event) also run for real through NSAppleScript.
///
/// Compiling reads Mail's dictionary from disk, as `IntegrationScripts.compileAll` does; nothing is sent to Mail.
/// Runs on the main thread only (the checks' top level): NSAppleScript is not thread-safe.
enum AppleScriptVariables {
    /// Per handler, the variables it reads but never gets. `nil`: the script does not compile, or this Mac's
    /// AppleScript formatting gives variables the same style as other words (then the scan cannot work).
    static func undefinedVariables(in source: String) -> [String: Set<String>]? {
        guard let style = variableStyle(), let rich = compiled(source)?.richTextSource else { return nil }
        let text = rich.string as NSString
        // Each word in the variable style, with the text before it on its line; calls (`f(`) are left out.
        var tokens: [(line: Int, word: String, before: String)] = []
        var lineStarts: [Int] = [0]
        for i in 0..<text.length where text.character(at: i) == 10 || text.character(at: i) == 13 { lineStarts.append(i + 1) }
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            guard NSDictionary(dictionary: attributes).isEqual(to: style) else { return }
            let words = text.substring(with: range).components(separatedBy: CharacterSet.alphanumerics.union(["_"]).inverted).filter { !$0.isEmpty }
            guard words.count == 1, let line = lineStarts.lastIndex(where: { $0 <= range.location }) else { return }
            let before = text.substring(with: NSRange(location: lineStarts[line], length: range.location - lineStarts[line]))
                .trimmingCharacters(in: .whitespaces)
            let end = range.location + range.length
            if end < text.length, text.character(at: end) == 40, before != "on", before != "to" { return }      // a call: "f("
            tokens.append((line, words[0], before))
        }
        let handlers = Set(tokens.filter { ["on", "to", "script"].contains($0.before) }.map(\.word))
        var out: [String: Set<String>] = [:]
        var current: (name: String, line: Int, known: Set<String>, read: Set<String>)?
        func close() {
            guard let handler = current else { return }
            let missing = handler.read.subtracting(handler.known).subtracting(handlers)
            if !missing.isEmpty { out[handler.name] = missing }
            current = nil
        }
        for token in tokens {
            if token.before == "on" || token.before == "to" {
                close()
                current = (token.word, token.line, [], [])
                continue
            }
            if token.before == "end", token.word == current?.name { close(); continue }
            guard current != nil else { continue }
            if token.line == current?.line {
                current?.known.insert(token.word)                           // a parameter
            } else if assigns(token.before) {
                current?.known.insert(token.word)
            } else {
                current?.read.insert(token.word)
            }
        }
        close()
        return out
    }

    /// The text before a variable on its line makes it the target of an assignment.
    private static func assigns(_ before: String) -> Bool {
        before.range(of: #"(^|\s)(set|set \{[^}]*|repeat with|copy .+ to|on error( number)?|on error .*\bnumber)$"#, options: .regularExpression) != nil
    }

    /// The attributes the compiler gives a variable on this Mac, when they differ from every other kind of word.
    private static func variableStyle() -> NSDictionary? {
        let probe = "on probeHandler(probeParameter)\n\tset probeVariable to probeParameter\n\treturn {probeVariable, \"probeText\", (count of {1}), AppleScript's text item delimiters, (current date)}\nend probeHandler"
        guard let rich = compiled(probe)?.richTextSource else { return nil }
        func style(of word: String) -> NSDictionary? {
            let range = (rich.string as NSString).range(of: word)
            guard range.location != NSNotFound else { return nil }
            return NSDictionary(dictionary: rich.attributes(at: range.location, effectiveRange: nil))
        }
        guard let variable = style(of: "probeVariable") else { return nil }
        let others = ["\"probeText\"", "count", "return", "text item delimiters", "current date"].compactMap(style(of:))
        return others.count == 5 && !others.contains(variable) ? variable : nil
    }

    static func compiled(_ source: String) -> NSAppleScript? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(&error) else { return nil }
        return script
    }

    /// Runs one handler of a compiled script: its result, or the AppleScript error number.
    static func call(_ script: NSAppleScript, _ handler: String, _ args: [NSAppleEventDescriptor]) -> (result: NSAppleEventDescriptor?, error: Int?) {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(a, at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { return (nil, (error[NSAppleScript.errorNumber] as? Int) ?? 0) }
        return (result, nil)
    }
}

func runMailScriptVariableChecks() {
    func text(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: s) }
    func texts(_ list: [String]) -> NSAppleEventDescriptor {
        let d = NSAppleEventDescriptor.list()
        for (i, s) in list.enumerated() { d.insert(text(s), at: i + 1) }
        return d
    }
    func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let d = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { d.insert(item, at: i + 1) }
        return d
    }
    let missingValue = NSAppleEventDescriptor(typeCode: OSType(0x6D73_6E67))   // 'msng'

    check("Mail scripts: the variable scan finds a read of a variable that was never set, and passes a correct handler") {
        let broken = """
        on demo(theID)
            set nowMail to {1, 2}
            set {alpha, beta} to nowMail
            if (item 1 of current) is theID then return nowMail
            repeat with r in nowMail
                set end of found to r
            end repeat
            try
                return my demo(alpha + beta)
            on error number errNum
                return errNum
            end try
        end demo
        """
        return AppleScriptVariables.undefinedVariables(in: broken) == ["demo": ["current", "found"]]
    }
    check("Mail scripts: every handler of the send, move, folder and other Mail scripts reads only variables it set or got") {
        let names = ["Mail", "MailReply", "MailSearch", "MailAccounts", "MailMove", "MailMoveDiagnose", "MailSend"]
        var clean = true
        for name in names {
            guard let source = IntegrationScripts.sources.first(where: { $0.name == name })?.source,
                  let undefined = AppleScriptVariables.undefinedVariables(in: source) else {
                print("  \(name): could not scan"); clean = false; continue
            }
            for (handler, words) in undefined.sorted(by: { $0.key < $1.key }) {
                print("  \(name) \(handler): \(words.sorted().joined(separator: ", ")) never set"); clean = false
            }
        }
        return clean
    }
    check("Mail send script: its pure handlers run without Mail; addresses compare as a multiset; no sender or file name reads as \"missing value\"") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "MailSend" })?.source,
              let script = AppleScriptVariables.compiled(source) else { return false }
        func same(_ found: [String], _ expected: [String]) -> Bool? {
            AppleScriptVariables.call(script, "sameAddresses", [texts(found), texts(expected)]).result.map(\.booleanValue)
        }
        let snapshot = ["Me <me@example.test>", "Termin", "Hallo Anna", "anna@example.test|ben@example.test", "", "", "Protokoll.pdf"]
        func mail(_ f: [String]) -> [NSAppleEventDescriptor] {
            func split(_ s: String) -> [String] { s.isEmpty ? [] : s.components(separatedBy: "|") }
            return [text(f[0]), text(f[1]), text(f[2]), texts(split(f[3])), texts(split(f[4])), texts(split(f[5])), texts(split(f[6]))]
        }
        func differs(_ now: [String], _ expected: [String]) -> Bool? {
            let nowMail = list([text("ok")] + mail(now))
            return AppleScriptVariables.call(script, "differs", [nowMail] + mail(expected)).result.map(\.booleanValue)
        }
        var duplicate = snapshot; duplicate[3] = "anna@example.test|anna@example.test"
        var changedBody = snapshot; changedBody[2] = "Hallo anna"
        var reordered = snapshot; reordered[3] = "BEN@example.test|anna@example.test"
        let plain = AppleScriptVariables.call(script, "textOf", [missingValue]).result?.stringValue
        let plainText = AppleScriptVariables.call(script, "textOf", [text("a@b")]).result?.stringValue
        let noName = AppleScriptVariables.call(script, "fileName", [missingValue])
        let name = AppleScriptVariables.call(script, "fileName", [text("Macintosh HD:Users:me:Protokoll.pdf")]).result?.stringValue
        let folder = AppleScriptVariables.call(script, "lastPart", [text("a:b:")]).result?.stringValue
        return same(["anna@example.test", "ben@example.test"], ["anna@example.test", "anna@example.test"]) == false
            && same(["anna@example.test", "anna@example.test"], ["anna@example.test", "ben@example.test"]) == false
            && same(["Anna@example.test", "ben@example.test"], ["ben@example.test", "anna@example.test"]) == true
            && same(["a@x", "a@x", "b@x"], ["a@x", "b@x", "a@x"]) == true && same([], []) == true && same(["a@x"], []) == false
            && differs(snapshot, snapshot) == false && differs(reordered, snapshot) == false
            && differs(duplicate, snapshot) == true && differs(snapshot, duplicate) == true && differs(changedBody, snapshot) == true
            && plain == "" && plainText == "a@b" && noName.result == nil && noName.error == -10000
            && name == "Protokoll.pdf" && folder == "b"
    }
}
