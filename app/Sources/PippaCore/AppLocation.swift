import Foundation

/// Where Pippa.app runs from. Outside Applications (straight from the disk image, or from Downloads, where macOS runs it
/// from a hidden read-only copy) updates cannot install, "Start with my Mac" fails, and once the disk image is
/// ejected Pippa is gone. So the first launch from there offers once to move her (app: `AppMover`).
public enum AppLocation {
    public enum Place: Equatable, Sendable {
        /// /Applications or ~/Applications: nothing to do.
        case applications
        /// On a mounted volume (`/Volumes/…`), usually the opened disk image.
        case volume(URL)
        /// App Translocation: macOS runs a read-only copy; the original lies elsewhere (Downloads).
        case translocated
        /// Anywhere else, e.g. Desktop or Downloads without translocation.
        case elsewhere
    }

    public static func place(of bundle: URL, home: URL) -> Place {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        let homeApps = home.appendingPathComponent("Applications").standardizedFileURL.path
        if path.hasPrefix("/Applications/") || path.hasPrefix(homeApps + "/") { return .applications }
        if path.contains("/AppTranslocation/") { return .translocated }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" {
            return .volume(URL(fileURLWithPath: "/Volumes/" + parts[1], isDirectory: true))
        }
        return .elsewhere
    }

    /// Where the move goes: /Applications if this account may write there, otherwise ~/Applications.
    public static func destination(appName: String, systemApplicationsWritable: Bool, home: URL) -> URL {
        let folder = systemApplicationsWritable ? URL(fileURLWithPath: "/Applications", isDirectory: true)
                                                : home.appendingPathComponent("Applications", isDirectory: true)
        return folder.appendingPathComponent(appName, isDirectory: true)
    }

    public enum Install: Equatable, Sendable {
        /// Nothing there yet: copy.
        case copy
        /// An older Pippa there: to the Trash, then copy.
        case replaceOlder
        /// The same or a newer Pippa (or one whose version cannot be read) is there: leave it and open that one.
        case openExisting
    }

    /// What to do at the destination. `existing`: CFBundleVersion of the Pippa already there, `nil` if none is there;
    /// an unreadable version counts as not older (never trash what cannot be compared).
    public static func install(existing: String??, moving new: String?) -> Install {
        guard let existing else { return .copy }
        guard let existing, let new, !existing.isEmpty, !new.isEmpty else { return .openExisting }
        return existing.compare(new, options: .numeric) == .orderedAscending ? .replaceOlder : .openExisting
    }
}
