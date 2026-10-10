import AppKit
import Contacts
import Foundation
import Photos

// "What Pippa may": every macOS permission Pippa uses, one row each, each asked only when the person presses its own
// Allow button (no automatic chain: a dialog that was declined never comes back by itself). Full Disk Access is
// deliberately missing: it cannot be asked for with a dialog, and Pippa's shell would inherit it.
// Checking never shows a dialog; only `request` does.

public enum MacPermission: String, CaseIterable, Sendable, Identifiable {
    /// Desktop, Documents and Downloads: one row, one dialog per folder on first read.
    case folders
    case iCloudDrive
    case externalDrives
    case calendar
    case reminders
    case contacts
    /// The photo library (PhotoKit) and steering the Photos app (search): one row, two dialogs.
    case photos
    case mail
    case notes
    case excel

    public var id: String { rawValue }

    public enum Group: Sendable { case files, apps }

    public var group: Group {
        switch self {
        case .folders, .iCloudDrive, .externalDrives: .files
        default: .apps
        }
    }

    /// Info.plist text macOS shows in the dialog. Without it macOS ends the app on asking, so the row stays hidden.
    public var usageKey: String {
        switch self {
        case .folders: "NSDesktopFolderUsageDescription"
        case .iCloudDrive: "NSFileProviderDomainUsageDescription"
        case .externalDrives: "NSRemovableVolumesUsageDescription"
        case .calendar: "NSCalendarsFullAccessUsageDescription"
        case .reminders: "NSRemindersFullAccessUsageDescription"
        case .contacts: "NSContactsUsageDescription"
        case .photos: "NSPhotoLibraryUsageDescription"
        case .mail, .notes, .excel: "NSAppleEventsUsageDescription"
        }
    }

    /// Area in System Settings → Privacy & Security, for a permission that was declined.
    public var settingsURL: URL {
        let anchor = switch self {
        case .folders, .iCloudDrive: "Privacy_FilesAndFolders"
        case .externalDrives: "Privacy_RemovableVolume"
        case .calendar: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .photos: "Privacy_Photos"
        case .mail, .notes, .excel: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// App steered by Apple Events, if this is an automation permission.
    var automationTarget: (bundle: String, name: String)? {
        switch self {
        case .mail: (Integration.mail.bundleIdentifier, Integration.mail.appName)
        case .notes: ("com.apple.Notes", L("Notes", table: "Core"))
        case .excel: (ExcelScript.bundleIdentifier, ExcelScript.appName)
        case .photos: (PhotosLibrary.bundleIdentifier, PhotosLibrary.appName)
        default: nil
        }
    }
}

public enum PermissionState: Sendable, Equatable {
    case granted
    /// Never asked: the row offers "Allow".
    case notAsked
    /// Declined: only System Settings can change it now.
    case denied
    /// Cannot be asked right now, with a short reason (e.g. no drive connected).
    case unavailable(String)
}

/// Reads and asks for permissions. `state` never shows a dialog.
public protocol PermissionDesk: Sendable {
    /// Is the row shown on this Mac (app installed, iCloud Drive on, dialog text present)?
    func applies(_ permission: MacPermission) -> Bool
    func state(_ permission: MacPermission) async -> PermissionState
    /// Shows the system dialog(s) for this one permission and returns the outcome.
    func request(_ permission: MacPermission) async -> PermissionState
}

// MARK: - Real

/// Calendar, Reminders and Mail go through the engine's integrations (one EventKit store, refreshed after a new
/// permission); everything else is asked here.
public final class SystemPermissions: PermissionDesk, @unchecked Sendable {
    private let access: @Sendable (Integration) async -> IntegrationAccess
    private let ask: @Sendable (Integration) async -> IntegrationAccess
    private let defaults: UserDefaults
    private let home: URL

    public init(access: @escaping @Sendable (Integration) async -> IntegrationAccess,
                request: @escaping @Sendable (Integration) async -> IntegrationAccess,
                defaults: UserDefaults = .standard,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.access = access
        self.ask = request
        self.defaults = defaults
        self.home = home
    }

    // Folders

    var standardFolders: [URL] {
        ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    var iCloudFolder: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true) }

    /// Mounted drives that are not part of this Mac (USB sticks, external disks, SD cards).
    var externalVolumes: [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.volumeIsInternal == false && v.volumeIsRootFileSystem != true && v.volumeIsLocal != false
        }
    }

    public func applies(_ permission: MacPermission) -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: permission.usageKey) != nil else { return false }
        switch permission {
        case .iCloudDrive: return FileManager.default.fileExists(atPath: iCloudFolder.path)
        case .excel: return AppleEvents.isInstalled(bundle: ExcelScript.bundleIdentifier)
        default: return true
        }
    }

    public func state(_ permission: MacPermission) async -> PermissionState {
        switch permission {
        case .folders:
            return await folderState(standardFolders, remembered: "folders", ask: false)
        case .iCloudDrive:
            return await folderState([iCloudFolder], remembered: "icloud", ask: false)
        case .externalDrives:
            if let known = remembered("external") { return known }
            return externalVolumes.isEmpty
                ? .unavailable(L("When you connect a drive, your Mac asks the first time Pippa opens it.", table: "Core")) : .notAsked
        case .calendar: return Self.from(await access(.calendar))
        case .reminders: return Self.from(await access(.reminders))
        case .contacts: return Self.contactsState
        case .photos:
            let library = Self.photosState
            guard library == .granted else { return library }
            return await automationState(.photos)
        case .mail, .notes, .excel:
            return await automationState(permission)
        }
    }

    public func request(_ permission: MacPermission) async -> PermissionState {
        let result: PermissionState
        switch permission {
        case .folders:
            result = await folderState(standardFolders, remembered: "folders", ask: true)
        case .iCloudDrive:
            result = await folderState([iCloudFolder], remembered: "icloud", ask: true)
        case .externalDrives:
            guard let volume = externalVolumes.first else { return await state(permission) }
            result = await Self.read([volume])
            remember("external", result)
        case .calendar: result = Self.from(await ask(.calendar))
        case .reminders: result = Self.from(await ask(.reminders))
        case .contacts:
            if Self.contactsState == .notAsked { _ = try? await CNContactStore().requestAccess(for: .contacts) }
            result = Self.contactsState
        case .photos:
            if Self.photosState == .notAsked { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            let library = Self.photosState
            if library == .granted { result = await askAutomation(.photos) } else { result = library }
        case .mail:
            result = Self.from(await ask(.mail))
            if result == .granted || result == .denied { remember(permission.rawValue, result) }
        case .notes, .excel:
            result = await askAutomation(permission)
        }
        return result
    }

    // MARK: Files

    /// Each folder once: reading shows the dialog if macOS has not asked yet. Only read when asking or when the answer is
    /// already known (then no dialog can appear).
    private func folderState(_ folders: [URL], remembered key: String, ask: Bool) async -> PermissionState {
        if !ask, remembered(key) == nil { return .notAsked }
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        let result = await Self.read(existing)
        if ask || result != .notAsked { remember(key, result) }
        return result
    }

    /// Lists each folder in turn (off the main thread: the call waits for the dialog). Any refusal counts as declined.
    static func read(_ folders: [URL]) async -> PermissionState {
        await Task.detached(priority: .userInitiated) { () -> PermissionState in
            var denied = false
            for folder in folders {
                do { _ = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch {
                    if SystemPermissions.isPermissionError(error) { denied = true }
                }
            }
            return denied ? .denied : .granted
        }.value
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? ns
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    // MARK: Contacts, Photos

    static var contactsState: PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        // authorized, and limited where macOS knows it
        default: .granted
        }
    }

    static var photosState: PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: .granted
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // MARK: Apple Events

    /// macOS only answers while the app runs; otherwise the last known answer, or "not asked".
    private func automationState(_ permission: MacPermission) async -> PermissionState {
        guard let target = permission.automationTarget else { return .notAsked }
        if AppleEvents.isRunning(bundle: target.bundle) {
            let live = Self.from(await AppleEvents.permission(bundle: target.bundle, appName: target.name, ask: false))
            if live == .granted || live == .denied { remember(permission.rawValue, live); return live }
        }
        return remembered(permission.rawValue) ?? .notAsked
    }

    /// The dialog only appears while the app runs: start it hidden first.
    private func askAutomation(_ permission: MacPermission) async -> PermissionState {
        guard let target = permission.automationTarget else { return .notAsked }
        guard await AppleEvents.launchHidden(bundle: target.bundle) else {
            return .unavailable(L("%@ isn’t open right now.", table: "Core", target.name))
        }
        let result = Self.from(await AppleEvents.permission(bundle: target.bundle, appName: target.name, ask: true))
        if result == .granted || result == .denied { remember(permission.rawValue, result) }
        return result
    }

    // MARK: Memory

    private func remembered(_ key: String) -> PermissionState? {
        switch defaults.string(forKey: "permission.\(key)") {
        case "granted": .granted
        case "denied": .denied
        default: nil
        }
    }

    private func remember(_ key: String, _ state: PermissionState) {
        switch state {
        case .granted: defaults.set("granted", forKey: "permission.\(key)")
        case .denied: defaults.set("denied", forKey: "permission.\(key)")
        default: break
        }
    }

    static func from(_ access: IntegrationAccess) -> PermissionState {
        switch access {
        case .granted: .granted
        case .notDetermined: .notAsked
        case .denied: .denied
        case .unavailable(let why): .unavailable(why)
        }
    }
}

// MARK: - Demo

/// Fixed answers for PIPPA_DEMO=1, snapshots and checks; asking flips a row to granted. Never touches the real Mac.
public final class DemoPermissions: PermissionDesk, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [MacPermission: PermissionState]

    public init(_ states: [MacPermission: PermissionState]? = nil) {
        self.states = states ?? [
            .folders: .granted, .iCloudDrive: .notAsked,
            .externalDrives: .unavailable(L("When you connect a drive, your Mac asks the first time Pippa opens it.", table: "Core")),
            .calendar: .granted, .reminders: .notAsked, .contacts: .notAsked, .photos: .denied,
            .mail: .granted, .notes: .notAsked, .excel: .notAsked,
        ]
    }

    public func applies(_ permission: MacPermission) -> Bool { lock.withLock { states[permission] != nil } }

    public func state(_ permission: MacPermission) async -> PermissionState { lock.withLock { states[permission] ?? .notAsked } }

    public func request(_ permission: MacPermission) async -> PermissionState {
        try? await Task.sleep(for: .milliseconds(300))
        return lock.withLock {
            if states[permission] == .notAsked { states[permission] = .granted }
            return states[permission] ?? .notAsked
        }
    }
}
