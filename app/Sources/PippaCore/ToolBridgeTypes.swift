import Foundation

// Shared values between host (Swift) and model: letter action choices, web citations, online
// lookup in conversation (WebAccessGate, Pi tools via PippaMCP), reading the calendar (MCP).
// Everything that comes from the model is unchecked: `LetterActions.validated` checks suggestions, `WebQuotes.verify` quotes.
// The network is never the model's, always the host's (Lookup/LookupHost.swift, WebAccessGate.swift).

/// One action that may be offered for a letter (only ids from this list are allowed).
public struct AgentActionChoice: Sendable, Equatable {
    public var id: String          // LetterActions id, e.g. "object"
    public var label: String       // English verb for the model, e.g. "Object"
    public var does: String        // English one-liner for the model
    public init(id: String, label: String, does: String) {
        self.id = id; self.label = label; self.does = does
    }
}

/// Untrusted proposal from the model (validated again by LetterActions.validated).
public struct AgentActionProposal: Sendable, Equatable, Codable {
    public var id: String
    public var instruction: String
    public var reason: String
    public init(id: String, instruction: String, reason: String) {
        self.id = id; self.instruction = instruction; self.reason = reason
    }
}

public struct LookupRequest: Sendable, Equatable {
    /// `lookup`: request for "Check online" (letter, LookupHost). `search`/`page`: `web_search`/`read_web_page` in conversation (FLOW-7,
    /// WebAccessGate); for `page` the address is in `query`.
    public enum Kind: String, Sendable { case lookup, search, page }
    public var query: String
    public var why: String
    public var kind: Kind
    public init(query: String, why: String, kind: Kind = .lookup) {
        self.query = query; self.why = why; self.kind = kind
    }
}

public struct LookupPassage: Sendable, Equatable {
    public var id: String          // "w1" … unique within one prompt
    public var site: String        // host without "www."
    public var title: String
    public var url: String
    public var asOf: String?       // "yyyy-mm-dd" or nil
    public var text: String        // excerpt, ≤ 1200 chars
    public init(id: String, site: String, title: String, url: String, asOf: String?, text: String) {
        self.id = id; self.site = site; self.title = title; self.url = url; self.asOf = asOf; self.text = text
    }
}

public struct LookupReply: Sendable, Equatable {
    public enum Status: String, Sendable { case done, needsPerson = "needs_person", refused, failed }
    public var status: Status
    public var passages: [LookupPassage]
    public init(status: Status, passages: [LookupPassage]) {
        self.status = status; self.passages = passages
    }
}

/// Untrusted citation from the model; the host verifies quote against the fetched page.
public struct WebCitation: Sendable, Equatable, Codable {
    public var sourceID: String
    public var quote: String
    public var statement: String
    public init(sourceID: String, quote: String, statement: String) {
        self.sourceID = sourceID; self.quote = quote; self.statement = statement
    }
}

// FLOW-10 "Read calendar": Pi asks via Pippa's MCP tool for a kind of period; the host (Swift) computes it,
// reads EventKit itself and returns finished days and times formatted in code (PippaMCPTools).
// The agent never gets access to EventKit and never asks for permissions itself.

/// Untrusted request from the calendar tool. `period`: today, tomorrow, rest_of_week, next_week, weekend, next_days (with `days`)
/// or dates (with `start`/`end` as YYYY-MM-DD). Anything else is refused as `invalid_range`.
public struct CalendarToolRequest: Sendable, Equatable {
    public var period: String
    public var start: String?
    public var end: String?
    public var days: Int?
    public init(period: String, start: String? = nil, end: String? = nil, days: Int? = nil) {
        self.period = period; self.start = start; self.end = end; self.days = days
    }
}

public struct CalendarToolReply: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ok
        /// Never asked: the app offers the permission (button), never the tool itself.
        case needsAccess = "needs_access"
        case denied, failed
        case invalidRange = "invalid_range"
    }
    public var status: Status
    /// On `ok`: JSON object from `CalendarDigest.toolPayload` (source, period, days, events), otherwise empty.
    public var payload: Data?
    public init(status: Status, payload: Data? = nil) { self.status = status; self.payload = payload }
}
