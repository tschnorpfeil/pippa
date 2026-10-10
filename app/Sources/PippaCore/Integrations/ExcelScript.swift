import AppKit
import Carbon
import Foundation

// MARK: Excel (read only)

/// Reads the workbook, sheet, selection and a limited range (values AND formulas) in Excel via
/// Apple Events, like `MailScript`: NSAppleScript in-process on the main thread, errors as with Mail
/// (no permission → `accessDenied`, Excel not open → `appNotOpen`, otherwise `notAvailable`).
///
/// No accessibility; Apple Events via `automation.apple-events` (Pippa.entitlements, without App Sandbox),
/// macOS asks once per target app. Never writes to the sheet: the script only reads
/// properties (`name`, `get address`, `used range`, `value`, `formula`), it sets and saves nothing.
///
/// Compiling: the terms (`active workbook`, `used range` …) exist only in Excel's dictionary. Without Excel
/// the script cannot be compiled; `IntegrationScripts.compileAll` skips it then (CI has no Excel).
/// [assumption] `get address` is a command in Excel's dictionary with the range as direct parameter
/// (`get address selection`); `value`/`formula` of a multi-cell range are lists of rows.
public enum ExcelScript {
    public static let bundleIdentifier = "com.microsoft.Excel"
    /// At most this many cells are read (target: a check in under a second).
    public static let maxCells = 4000

    /// Name of the app for messages.
    public static var appName: String { L("Excel", table: "Sheet") }

    /// System Settings → Privacy & Security → Automation (Excel is listed under Pippa there, like Mail).
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static let source = """
    on sheetInfo()
        tell application id "com.microsoft.Excel"
            if (count of workbooks) is 0 then return {}
            set wbName to (name of active workbook) as text
            set sh to active sheet
            set shName to (name of sh) as text
            set selAddress to ""
            try
                set selAddress to (get address selection) as text
            end try
            set usedAddress to ""
            try
                set usedAddress to (get address (used range of sh)) as text
            end try
            return {wbName, shName, selAddress, usedAddress}
        end tell
    end sheetInfo

    on cellsOf(theAddress)
        tell application id "com.microsoft.Excel"
            set r to range theAddress of active sheet
            return {value of r, formula of r}
        end tell
    end cellsOf
    """

    /// May Pippa ask Excel? With `ask: true` it asks via the system prompt (don't wait on the main thread).
    public static func access(ask: Bool) async -> IntegrationAccess {
        guard AppleEvents.isRunning(bundle: bundleIdentifier) else {
            return .unavailable(L("First open your table in Excel and select the cells. Then try again.", table: "Sheet"))
        }
        return await AppleEvents.permission(bundle: bundleIdentifier, appName: appName, ask: ask)
    }

    /// Reads the active sheet. nil if no workbook is open or there is nothing to read.
    static func selected() async throws -> SheetSnapshot? {
        try await AppleEvents.perform { () throws -> SheetSnapshot? in
            let infoReply = try AppleEvents.call(source, handler: "sheetInfo", appName: appName)
            let info = AppleEvents.items(infoReply)
            guard info.count >= 4 else { return nil }
            let workbook = info[0].stringValue ?? ""
            let sheet = info[1].stringValue ?? ""
            let selection = CellArea(a1: info[2].stringValue ?? "")
            let used = CellArea(a1: info[3].stringValue ?? "")
            guard let read = readArea(selection: selection, used: used) else { return nil }
            let args = [NSAppleEventDescriptor(string: read.area.a1)]
            let cellsReply = try AppleEvents.call(source, handler: "cellsOf", args, appName: appName)
            let parts = AppleEvents.items(cellsReply)
            guard parts.count >= 2 else { return nil }
            let grid = Self.grid(values: parts[0], formulas: parts[1], area: read.area)
            let focus = selection.flatMap { s in used.map { s.intersection($0) ?? s } ?? s }
            return SheetSnapshot(workbook: workbook, sheet: sheet, selection: focus, grid: grid, isClipped: read.clipped)
        }
    }

    /// Which range is read (pure, public for the checks):
    /// - Multi-cell selection: the selection, extended up and left to the edge of the used range
    ///   (headings, row labels) and down to its end (the totals row), provided that fits in
    ///   `maxCells`; otherwise only the selection. Whole columns or rows are clipped to the used range.
    /// - A single cell or no selection: the used range.
    /// Then at most `maxCells` cells from the top left (`clipped` says whether it was truncated).
    public static func readArea(selection: CellArea?, used: CellArea?, maxCells: Int = ExcelScript.maxCells) -> (area: CellArea, clipped: Bool)? {
        var selected = selection
        if let s = selected, let u = used { selected = s.intersection(u) ?? (s.cellCount <= maxCells ? s : nil) }
        let base: CellArea
        if let s = selected, !s.isSingleCell {
            if let u = used {
                let widened = CellArea(top: min(u.top, s.top), left: min(u.left, s.left), bottom: max(u.bottom, s.bottom), right: s.right)
                base = widened.cellCount <= maxCells ? widened : s
            } else {
                base = s
            }
        } else if let u = used {
            base = u
        } else if let s = selected {
            base = s
        } else {
            return nil
        }
        let columns = max(1, min(base.columnCount, maxCells))
        let rows = max(1, min(base.rowCount, maxCells / columns))
        let area = CellArea(top: base.top, left: base.left, bottom: base.top + rows - 1, right: base.left + columns - 1)
        return (area, rows < base.rowCount || columns < base.columnCount)
    }

    // MARK: Apple Event values → grid

    /// Values and formulas of a range as a grid (public for the checks). For a single cell Excel returns a single value, for several
    /// a list of rows (each a list).
    public static func grid(values: NSAppleEventDescriptor, formulas: NSAppleEventDescriptor, area: CellArea) -> SheetGrid {
        let v = matrix(values, area: area)
        let f = matrix(formulas, area: area)
        var rows: [[SheetCell]] = []
        for r in 0..<min(v.count, area.rowCount) {
            var row: [SheetCell] = []
            for c in 0..<min(v[r].count, area.columnCount) {
                let formula = r < f.count && c < f[r].count ? f[r][c].stringValue : nil
                row.append(SheetCell(value(v[r][c]), formula: formula))
            }
            rows.append(row)
        }
        return SheetGrid(origin: area.topLeft, rows: rows)
    }

    private static func matrix(_ d: NSAppleEventDescriptor, area: CellArea) -> [[NSAppleEventDescriptor]] {
        guard d.descriptorType == typeAEList else { return [[d]] }
        let top = AppleEvents.items(d)
        if !top.isEmpty && top.allSatisfy({ $0.descriptorType == typeAEList }) { return top.map { AppleEvents.items($0) } }
        // Flat list: one row or one column.
        return area.rowCount == 1 ? [top] : top.map { [$0] }
    }

    private static func fourCC(_ s: String) -> DescType { s.utf8.reduce(DescType(0)) { ($0 << 8) | DescType($1) } }
    private static let numberTypes: Set<DescType> = Set(["doub", "sing", "long", "shor", "comp", "magn", "ushr", "ucom", "ldbl", "exte"].map(fourCC))
    private static let boolTypes: Set<DescType> = Set(["bool", "true", "fals"].map(fourCC))
    /// Excel error values arrive as numbers (CVErr): #NULL!, #DIV/0!, #VALUE!, #REF!, #NAME?, #NUM!, #N/A.
    private static let errorValues: [Double: String] = [
        -2146826288: "#NULL!", -2146826281: "#DIV/0!", -2146826273: "#VALUE!", -2146826265: "#REF!",
        -2146826259: "#NAME?", -2146826252: "#NUM!", -2146826246: "#N/A",
    ]

    public static func value(_ d: NSAppleEventDescriptor) -> SheetValue {
        let type = d.descriptorType
        if numberTypes.contains(type) {
            let n = d.doubleValue
            if let error = errorValues[n] { return .text(error) }
            return n.isFinite ? .number(n) : .empty
        }
        if boolTypes.contains(type) { return .bool(d.booleanValue) }
        if type == fourCC("ldt "), let date = d.dateValue { return .date(date) }
        if type == fourCC("type") || type == fourCC("enum") { return .empty }   // missing value
        let text = d.stringValue ?? ""
        return text.isEmpty ? .empty : .text(text)
    }
}

/// Reading a sheet, separate from `AppIntegrations` so existing integrations stay unchanged.
/// No writing: there is no method that writes to a sheet.
public protocol SheetReading: Sendable {
    /// May Pippa read Excel? Never asks on its own.
    func sheetAccess() async -> IntegrationAccess
    /// Shows the system prompt if needed. Call only when the person is currently using the feature.
    func requestSheetAccess() async -> IntegrationAccess
    /// The active sheet with selection; nil if no workbook is open.
    func selectedSheet() async throws -> SheetSnapshot?
}

extension SystemIntegrations: SheetReading {
    public func sheetAccess() async -> IntegrationAccess { await ExcelScript.access(ask: false) }
    /// Does not start Excel: with no open sheet there is nothing to read.
    public func requestSheetAccess() async -> IntegrationAccess { await ExcelScript.access(ask: true) }
    public func selectedSheet() async throws -> SheetSnapshot? { try await ExcelScript.selected() }
}

/// Stand-in without Excel: for PIPPA_DEMO=1 and checks.
public final class DemoSheetReader: SheetReading, @unchecked Sendable {
    private let lock = NSLock()
    private var access: IntegrationAccess
    private let snapshot: SheetSnapshot?

    public init(granted: Bool = false, snapshot: SheetSnapshot? = DemoSheetReader.sample) {
        access = granted ? .granted : .notDetermined
        self.snapshot = snapshot
    }

    public func sheetAccess() async -> IntegrationAccess { lock.withLock { access } }

    public func requestSheetAccess() async -> IntegrationAccess {
        lock.withLock {
            if access == .notDetermined { access = .granted }
            return access
        }
    }

    public func selectedSheet() async throws -> SheetSnapshot? {
        guard lock.withLock({ access }) == .granted else { throw PippaError.accessDenied(ExcelScript.appName) }
        return snapshot
    }

    /// "Kosten 2026": the sum leaves out the last row ("Wasser").
    public static let sample: SheetSnapshot = {
        func text(_ s: String) -> SheetCell { SheetCell(.text(s)) }
        func number(_ n: Double) -> SheetCell { SheetCell(.number(n)) }
        let rows: [[SheetCell]] = [
            [text("Posten"), text("Betrag")],
            [text("Miete"), number(950)],
            [text("Strom"), number(84.2)],
            [text("Internet"), number(39.99)],
            [text("Wasser"), number(36.5)],
            [text("Summe"), SheetCell(.number(1074.19), formula: "=SUM(B2:B4)")],
        ]
        let grid = SheetGrid(origin: CellRef(row: 1, column: 1), rows: rows)
        return SheetSnapshot(workbook: "Kosten 2026.xlsx", sheet: "2026", selection: CellArea(a1: "B2:B6"), grid: grid)
    }()
}
