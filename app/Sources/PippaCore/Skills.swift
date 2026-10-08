import Foundation

/// What Pippa can do with paperwork, texts and Office files: Pi skills, only from the app bundle
/// (runtime/pippa-skills -> Contents/Resources/pippa-skills). Pi loads them with `--skill` (PippaPiLaunch); a button sends
/// `/skill:<name>` (`PiSkillTurn`) and Pi puts the instructions before the message.
/// Swift keeps no list of its own: button and suggestion are in the header of the respective SKILL.md.
/// A new skill is a new folder, no Swift. All of them are `disable-model-invocation: true`: only a button invokes one.
///
/// Header (Pi's rules: `name` like the folder, `description`), plus Pippa's own fields, all optional:
/// - `pippa-label`: button text, English. Without it there is no button.
/// - `pippa-prompt`: the message in the history, English (otherwise the button text).
/// - `pippa-label-de`, `pippa-prompt-de`: the same in German, used when the UI is German (`prefersGerman`).
/// - `pippa-suggest`: where the button appears, list of `brief` (letter), `text`, `tabelle` (table), `dokument` (document), `immer` (always: empty conversation).
/// - `pippa-draft: true`: the result is a draft to copy.
public struct PippaSkill: Identifiable, Sendable, Hashable {
    public var name: String
    public var description: String
    /// Button in the conversation.
    public var title: String?
    /// Appears as your message in the history; only Pi sees the instruction behind it.
    public var prompt: String
    /// Result is a draft to copy ("Copy" button on the answer).
    public var writesDraft: Bool
    public var places: Set<Place>

    public var id: String { name }

    /// Where in the conversation the buttons appear: at the letter or mail, at selected text, at table or document, in the empty conversation.
    public enum Place: String, Sendable, Hashable, CaseIterable { case brief, text, tabelle, dokument, immer }

    /// German buttons and messages when the UI is German: the same choice as `L` (Bundle.module.preferredLocalizations).
    public static var prefersGerman: Bool {
        (Bundle.module.preferredLocalizations.first ?? "").hasPrefix("de")
    }

    /// Reads a SKILL.md. Nil if the header violates Pi's rules (name like the folder, description present).
    /// `german` selects `pippa-label-de` / `pippa-prompt-de` where present; otherwise the English text applies.
    public static func parse(_ markdown: String, folder: String, german: Bool = PippaSkill.prefersGerman) -> PippaSkill? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            fields[key] = value
        }
        guard let name = fields["name"], name == folder, isValid(name: name),
              let description = fields["description"], !description.isEmpty, description.count <= 1024 else { return nil }
        let label = field("pippa-label", in: fields, german: german)
        let prompt = field("pippa-prompt", in: fields, german: german) ?? label ?? description
        let places = Set((fields["pippa-suggest"] ?? "").split(separator: ",").compactMap { Place(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        return PippaSkill(name: name, description: description, title: label, prompt: prompt,
                          writesDraft: fields["pippa-draft"] == "true", places: label == nil ? [] : places)
    }

    /// A header field in the UI language: `<key>-de` for German, otherwise (or if missing) `<key>`. Empty counts as missing.
    private static func field(_ key: String, in fields: [String: String], german: Bool) -> String? {
        let english = fields[key].flatMap { $0.isEmpty ? nil : $0 }
        guard german, let translated = fields[key + "-de"], !translated.isEmpty else { return english }
        return translated
    }

    /// Pi's name rule: lowercase letters, digits, hyphens; none at the edge or doubled; at most 64 characters.
    public static func isValid(name: String) -> Bool {
        name.count <= 64 && name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    /// All valid capabilities in a folder (one SKILL.md per subfolder), sorted by name.
    public static func load(from directory: URL, german: Bool = PippaSkill.prefersGerman) -> [PippaSkill] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return folders.filter { !$0.hasPrefix(".") }.sorted().compactMap { folder in
            let file = directory.appendingPathComponent(folder).appendingPathComponent("SKILL.md")
            return (try? String(contentsOf: file, encoding: .utf8)).flatMap { parse($0, folder: folder, german: german) }
        }
    }

    /// `PIPPA_SKILLS_DIR`, otherwise the app bundle (`Contents/Resources/pippa-skills`); in a debug run without bundle the folder in the repo.
    public static func bundledDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["PIPPA_SKILLS_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app" { return repositoryDirectory }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/pippa-skills", isDirectory: true)
    }

    /// `runtime/pippa-skills` in this checkout (checks, debug runs).
    public static var repositoryDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("runtime/pippa-skills", isDirectory: true)
    }

    /// Only the instruction of a valid bundled capability; never Markdown from user files.
    public static func instructions(named name: String) -> String? {
        guard isValid(name: name), let markdown = try? String(contentsOf: bundledDirectory().appendingPathComponent(name).appendingPathComponent("SKILL.md"), encoding: .utf8),
              parse(markdown, folder: name) != nil else { return nil }
        let lines = markdown.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bundled capabilities, read once.
    public static let bundled: [PippaSkill] = load(from: bundledDirectory())

    /// A few fitting suggestions instead of a list with everything.
    public static func suggestions(for place: Place, in skills: [PippaSkill] = bundled) -> [PippaSkill] {
        skills.filter { $0.places.contains(place) }
    }

    /// Format alone permits a spreadsheet check. Generic prose and Office documents need semantic evidence.
    /// Explicit text selections keep their separate `.text` palette.
    public static func place(for kind: DropKind, fileExtension: String? = nil) -> Place? {
        let ext = fileExtension?.lowercased() ?? ""
        switch kind {
        case .mail, .pdf, .image: return nil
        case .text: return ["csv", "tsv"].contains(ext) ? .tabelle : nil
        case .office:
            if ["xlsx", "xls", "ods", "numbers"].contains(ext) { return .tabelle }
            return nil
        case .folder, .mixed, .link, .other: return nil
        }
    }
}
