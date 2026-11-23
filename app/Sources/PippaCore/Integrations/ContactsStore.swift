import Contacts
import Foundation

// MARK: Apple Contacts (read only, native CNContactStore, zero Full Disk Access)

/// One contact returned by `contacts_search`, bounded to the fields Pippa needs.
public struct ContactSummary: Sendable, Equatable {
    public var name: String
    public var organization: String?
    public var emails: [String]
    public var phones: [String]
    /// ISO date (`YYYY-MM-DD`) when the year is known, or `--MM-DD` when only month and day are stored.
    public var birthday: String?

    public init(name: String, organization: String? = nil, emails: [String] = [], phones: [String] = [], birthday: String? = nil) {
        self.name = name
        self.organization = organization
        self.emails = emails
        self.phones = phones
        self.birthday = birthday
    }
}

/// Read-only access to macOS Contacts. Real implementation uses `CNContactStore`; checks use `DemoContactsStore`.
public protocol ContactsReading: Sendable {
    func access(ask: Bool) async -> IntegrationAccess
    func search(query: String, limit: Int) async throws -> [ContactSummary]
}

/// Shared constants for macOS Contacts.
public enum ContactsStore {
    public static var appName: String { L("Contacts", table: "Core") }
    public static let settingsURL = PermissionRepairTarget.contacts.settingsURL
    public static let maxLimit = 20
}

/// Real Contacts reader via `CNContactStore` (targeted search, bounded at `limit <= 20`, no background harvesting).
public struct SystemContactsStore: ContactsReading {
    /// Hard upper bound on contacts inspected during email/organization fallback enumeration.
    private static let maxScanCount = 5_000

    public init() {}

    public func access(ask: Bool) async -> IntegrationAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .granted
        case .notDetermined:
            guard ask else { return .notDetermined }
            return await Task.detached(priority: .userInitiated) {
                let store = CNContactStore()
                do {
                    let granted = try await store.requestAccess(for: .contacts)
                    return granted ? .granted : .denied
                } catch {
                    return .denied
                }
            }.value
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    public func search(query: String, limit: Int) async throws -> [ContactSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cap = max(1, min(limit, ContactsStore.maxLimit))
        return try await Task.detached(priority: .userInitiated) { () throws -> [ContactSummary] in
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactBirthdayKey as CNKeyDescriptor,
            ]
            var seen = Set<String>()
            var matches: [ContactSummary] = []

            func append(_ contact: CNContact) {
                guard matches.count < cap, seen.insert(contact.identifier).inserted else { return }
                matches.append(Self.summary(from: contact))
            }

            do {
                let nameMatches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: trimmed),
                                                            keysToFetch: keys)
                for contact in nameMatches {
                    append(contact)
                    if matches.count >= cap { return matches }
                }

                if trimmed.contains("@") {
                    let emailMatches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: trimmed),
                                                                 keysToFetch: keys)
                    for contact in emailMatches {
                        append(contact)
                        if matches.count >= cap { return matches }
                    }
                }

                // Targeted email/organization fallback when name predicate did not fill `cap`.
                let needle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let request = CNContactFetchRequest(keysToFetch: keys)
                var scanned = 0
                try store.enumerateContacts(with: request) { contact, stop in
                    scanned += 1
                    if scanned > Self.maxScanCount {
                        stop.pointee = true
                        return
                    }
                    guard !seen.contains(contact.identifier) else { return }
                    let org = contact.organizationName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let emailHit = contact.emailAddresses.contains {
                        String($0.value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle)
                    }
                    if org.contains(needle) || emailHit {
                        append(contact)
                        if matches.count >= cap { stop.pointee = true }
                    }
                }
                return matches
            } catch let error as CNError where error.code == .authorizationDenied {
                throw PippaError.accessDenied(ContactsStore.appName)
            }
        }.value
    }

    static func summary(from contact: CNContact) -> ContactSummary {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !formatted.isEmpty ? formatted : (!fallbackName.isEmpty ? fallbackName : org)
        let emails = contact.emailAddresses.prefix(5).map { String($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let phones = contact.phoneNumbers.prefix(5).map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let birthday = formatBirthday(contact.birthday)
        return ContactSummary(name: name, organization: org.isEmpty ? nil : org, emails: emails, phones: phones, birthday: birthday)
    }

    static func formatBirthday(_ components: DateComponents?) -> String? {
        guard let components, let month = components.month, let day = components.day,
              month != NSDateComponentUndefined, day != NSDateComponentUndefined else { return nil }
        if let year = components.year, year != NSDateComponentUndefined, year > 0 {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }
}

/// In-memory Contacts store for checks and `PIPPA_DEMO=1`. Never touches the real macOS Contacts database.
public final class DemoContactsStore: ContactsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAccess: IntegrationAccess
    private var storedContacts: [ContactSummary]

    public static var defaultContacts: [ContactSummary] {
        [
            ContactSummary(name: "Anna Berger", organization: "Hausverwaltung Berger",
                           emails: ["info@berger-hv.example"], phones: ["+49 221 5550199"], birthday: "1982-05-14"),
            ContactSummary(name: "Dr. Lukas Weber", organization: "Zahnarztpraxis Weber",
                           emails: ["praxis@weber-dental.example"], phones: ["+49 30 5550142"]),
            ContactSummary(name: "Clara Miller", organization: "Northwind Legal",
                           emails: ["clara@northwind.example"], phones: ["+1 415 555 0184"], birthday: "--11-03"),
        ]
    }

    public init(access: IntegrationAccess = .granted, contacts: [ContactSummary] = DemoContactsStore.defaultContacts) {
        storedAccess = access
        storedContacts = contacts
    }

    public var accessState: IntegrationAccess {
        get { lock.withLock { storedAccess } }
        set { lock.withLock { storedAccess = newValue } }
    }

    public func access(ask: Bool) async -> IntegrationAccess {
        lock.withLock {
            if storedAccess == .notDetermined && ask { storedAccess = .granted }
            return storedAccess
        }
    }

    public func search(query: String, limit: Int) async throws -> [ContactSummary] {
        let (access, contacts) = lock.withLock { (storedAccess, storedContacts) }
        guard access == .granted else { throw PippaError.accessDenied(ContactsStore.appName) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cap = max(1, min(limit, ContactsStore.maxLimit))
        let words = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        let matched = contacts.filter { contact in
            let fields = [contact.name, contact.organization ?? ""] + contact.emails + contact.phones
            let combined = fields.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { combined.contains($0) }
        }
        return Array(matched.prefix(cap))
    }
}
