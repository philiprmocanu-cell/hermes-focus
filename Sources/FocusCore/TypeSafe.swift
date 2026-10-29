import Foundation

// MARK: - A friend's own TypeSafe key
//
// Friends are judged by Jev on THEIR OWN TypeSafe key, not the user's. The key is sent once to
// `POST /lb/focus/settings {"typesafe_key"}` (`""` clears it) and kept on this Mac only in the Keychain
// (service `TypeSafeKeyField.keychainService`, account `TypeSafeKeyField.keychainAccount`) — never in
// UserDefaults, never in a log. The brain answers `"typesafe": "ok" | "invalid" | "missing"` there and on
// `GET /lb/focus/now`; a friend's sense or frame without a key comes back HTTP 402. Owner mode never uses any of this.

/// The key as typed or pasted: trimmed; nil when empty or when it still has a space / line break inside.
public enum TypeSafeKeyField {
    public static let keychainService = "app.hermesfocus.mac"
    public static let keychainAccount = "typesafe_key"

    public static func clean(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !k.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return k
    }

    public static func isValid(_ raw: String) -> Bool { clean(raw) != nil }
}

/// What the brain says about the friend's key.
public enum TypeSafeStatus: String, Equatable, Sendable {
    case ok, invalid, missing

    /// `{"typesafe": "..."}` → the status; nil when the reply says nothing about it (older brain, owner).
    public static func parse(_ json: JSONValue?) -> TypeSafeStatus? {
        guard let json else { return nil }
        return TypeSafeStatus(rawValue: json.str("typesafe").lowercased())
    }
}

/// `POST /lb/focus/settings` — `""` removes the key.
public struct TypeSafeKeyRequest: Codable, Equatable, Sendable {
    public var typesafeKey: String
    public init(typesafeKey: String) { self.typesafeKey = typesafeKey }
    public static let remove = TypeSafeKeyRequest(typesafeKey: "")
    enum CodingKeys: String, CodingKey { case typesafeKey = "typesafe_key" }
}

/// Every word a friend sees about the key, in one place.
public enum TypeSafeText {
    public static let stepTitle = "Your TypeSafe key"
    public static let explainer = "Hermes judges your screen with TypeSafe's Jev model, on your own key, so the cost is yours — about a dollar or two for a full day. Get a key at console.typesafe.ai/keys."
    public static let fieldLabel = "TypeSafe key"
    public static let save = "Save key"
    public static let saving = "Checking…"
    public static let later = "Later"
    public static let done = "Done"
    public static let works = "Key works"
    public static let refused = "That key was refused — check it and try again"
    public static let unreachable = "Couldn't reach the server — try again in a minute"
    public static let badFormat = "Paste the whole key — no spaces"
    public static let reminder = "Add your TypeSafe key in Settings to be judged"
    public static let reminderLink = "Add key"
    public static let change = "Change"
    public static let remove = "Remove"
    public static let removed = "Key removed"
    public static func row(set: Bool) -> String { "TypeSafe key: " + (set ? "set" : "not set") }

    /// What the save reply means for the line under the field (nil reply = the server was unreachable).
    public static func result(for status: TypeSafeStatus?) -> (text: String, ok: Bool) {
        switch status {
        case .ok?: return (works, true)
        case .invalid?, .missing?: return (refused, false)
        case nil: return (unreachable, false)
        }
    }
}

/// Is the friend being judged, and may a sense / frame post go out now? While the key is missing the app
/// does not knock every second: one probe a minute (sense and frame share it) until a key is set, then
/// everything resumes at once. The timer and the rest of the app never wait on this.
public struct TypeSafeState: Equatable, Sendable {
    public static let retryEvery: TimeInterval = 60

    /// The brain said there is no key (402, or `now` / `settings` said "missing").
    public private(set) var missing = false
    /// While `missing`: when the next probe may go out.
    public private(set) var nextProbeAt: TimeInterval = 0
    /// The last thing the brain said about the key (nil = nothing yet).
    public private(set) var status: TypeSafeStatus?

    public init() {}

    /// The calm line on the goal screen and in the control window.
    public var showsReminder: Bool { missing }

    /// A sense or frame post may go out now. Call `sent(now:)` when it does.
    public func canJudge(now: TimeInterval) -> Bool { !missing || now >= nextProbeAt }

    /// A post went out: while missing, that was this minute's probe.
    public mutating func sent(now: TimeInterval) {
        if missing { nextProbeAt = now + Self.retryEvery }
    }

    /// HTTP status and body of a sense / frame reply. True = "no key" (the caller treats it as no verdict,
    /// not as the brain being unreachable).
    @discardableResult
    public mutating func judged(httpStatus: Int, body: JSONValue?, now: TimeInterval) -> Bool {
        if Self.isMissingKey(httpStatus: httpStatus, body: body) {
            markMissing(now: now)
            return true
        }
        if (200..<300).contains(httpStatus) { clearMissing(status: .ok) }
        return false
    }

    /// `GET now` / `GET settings` reply.
    public mutating func observe(_ s: TypeSafeStatus?, now: TimeInterval) {
        switch s {
        case .missing?: if !missing { markMissing(now: now) }
        case .ok?: clearMissing(status: .ok)
        case .invalid?: status = .invalid
        case nil: break
        }
    }

    /// The reply to saving a key. Ok = judging resumes at once. A refused key changes nothing else: if an
    /// older key still works the brain keeps judging on it, and the next sense reply says so.
    public mutating func saved(_ s: TypeSafeStatus?, now: TimeInterval) {
        switch s {
        case .ok?: clearMissing(status: .ok)
        case .invalid?: status = .invalid
        case .missing?: if !missing { markMissing(now: now) }
        case nil: break
        }
    }

    /// The Settings row: "set" once the brain accepted a key, or (before it has said anything) when this
    /// Mac's Keychain holds one.
    public func keyIsSet(storedLocally: Bool) -> Bool {
        if missing { return false }
        switch status {
        case .ok?: return true
        case .invalid?, .missing?: return false
        case nil: return storedLocally
        }
    }

    /// The brain says "missing" but the Keychain still holds a key (the server lost it): send it again,
    /// once per launch. True = send it now.
    public mutating func takeResend(storedLocally: Bool) -> Bool {
        guard missing, storedLocally, !resent else { return false }
        resent = true
        return true
    }
    private var resent = false

    /// He removed the key: back to not judged (and one probe a minute).
    public mutating func removed(now: TimeInterval) { markMissing(now: now) }

    public static func isMissingKey(httpStatus: Int, body: JSONValue?) -> Bool {
        httpStatus == 402 || TypeSafeStatus.parse(body) == .missing
    }

    private mutating func markMissing(now: TimeInterval) {
        missing = true
        status = status == .invalid ? .invalid : .missing
        nextProbeAt = now + Self.retryEvery
    }

    private mutating func clearMissing(status s: TypeSafeStatus) {
        missing = false
        nextProbeAt = 0
        status = s
    }
}
