import Foundation

// MARK: - TypeSafe (Jev), on the user's own key
//
// Port of app.py `_jev_systemone` / `_jev_judge` / `_jev_key_check`. One call:
//   POST https://api.typesafe.ai/v1/systemone
//   Authorization: Bearer <key>, Content-Type: application/json
//   {"model": "jev-latest", "state": {...}, "questions": {...}}
// With a screenshot the body also carries `"assets": {<ref>: {"type": "image", "format": "jpg",
// "data_base64": ...}}` (brain/jev.image_asset; the state names <ref> at screen_now.screenshot) and the request
// carries `TypeSafe-Danger-Zone-Images: true`. 4 s limit. The reply's `answers` object is the verdict; `usage`
// has input/output tokens. A failed call is just a second with no verdict: nil, never a throw. The key is never
// logged and never leaves the request header.

public enum TypeSafeAPI {
    public static let baseURL = "https://api.typesafe.ai"
    public static let path = "/v1/systemone"
    /// app.py `_JEV_URL` with the default base.
    public static var url: URL { URL(string: baseURL + path)! }
    /// brain/jev.MODEL.
    public static let model = "jev-latest"
    /// app.py `_JEV_TIMEOUT_S`.
    public static let timeout: TimeInterval = 4
    /// app.py `_jev_key_check` waits a little longer.
    public static let keyCheckTimeout: TimeInterval = 6
    /// brain/jev.IMAGE_HEADER.
    public static let imageHeader = (name: "TypeSafe-Danger-Zone-Images", value: "true")
}

public enum TypeSafeRequest {
    /// brain/jev.image_asset: the `assets` map for one screenshot (base64 JPEG under a unique reference).
    public static func imageAsset(jpegBase64: String, ref: String) -> JSONValue {
        .object([ref: .object(["type": .string("image"), "format": .string("jpg"),
                               "data_base64": .string(jpegBase64)])])
    }

    /// The body: {model, state, questions[, assets]}.
    public static func body(state: JSONValue, questions: JSONValue, assets: JSONValue? = nil,
                            model: String = TypeSafeAPI.model) -> JSONValue {
        var o: [String: JSONValue] = ["model": .string(model), "state": state, "questions": questions]
        if let assets, PortedText.truthy(assets) { o["assets"] = assets }
        return .object(o)
    }

    /// The whole request, ready to send. Pure: no network.
    public static func build(key: String, state: JSONValue, questions: JSONValue, assets: JSONValue? = nil,
                             model: String = TypeSafeAPI.model, url: URL = TypeSafeAPI.url,
                             timeout: TimeInterval = TypeSafeAPI.timeout) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let assets, PortedText.truthy(assets) {
            req.setValue(TypeSafeAPI.imageHeader.value, forHTTPHeaderField: TypeSafeAPI.imageHeader.name)
        }
        req.httpBody = ClientJSON.encode(body(state: state, questions: questions, assets: assets, model: model))
        return req
    }

    /// `_jev_key_check`: one tiny one-question call, no image.
    public static func keyCheck(key: String, url: URL = TypeSafeAPI.url) -> URLRequest {
        build(key: key, state: .object(["check": .string("Is this a key check? Answer yes.")]),
              questions: .object(["ok": .object(["type": .string("noul"), "instructions": .string("Answer yes.")])]),
              url: url, timeout: TypeSafeAPI.keyCheckTimeout)
    }

    /// brain/jev.without_image: the same state with `screen_now.screenshot` taken out (the text-only retry).
    public static func withoutImage(_ state: JSONValue) -> JSONValue {
        guard case .object(var o) = state else { return state }
        var screen: [String: JSONValue] = [:]
        if case .object(let s)? = o["screen_now"] { screen = s }
        screen["screenshot"] = nil
        o["screen_now"] = .object(screen)
        return .object(o)
    }
}

/// One Jev answer: `answers` (question id → {type, noul, …}) and the tokens it cost.
public struct TypeSafeReply: Equatable, Sendable {
    public var answers: [String: JSONValue]
    public var inputTokens: Int
    public var outputTokens: Int
    public var tokens: Int { inputTokens + outputTokens }

    public init(answers: [String: JSONValue], inputTokens: Int = 0, outputTokens: Int = 0) {
        self.answers = answers; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }

    /// A 2xx body with an `answers` object; nil for anything else.
    public static func parse(_ reply: HTTPReply) -> TypeSafeReply? {
        guard (200..<300).contains(reply.status), let v = ClientJSON.decode(reply.body),
              case .object(let answers)? = v["answers"] else { return nil }
        func int(_ k: String) -> Int { Int(PortedText.number(v["usage"]?[k]) ?? 0) }
        return TypeSafeReply(answers: answers, inputTokens: int("input_tokens"), outputTokens: int("output_tokens"))
    }
}

public struct TypeSafeClient: Sendable {
    public var key: String
    public var model: String
    public var url: URL
    public var transport: any HTTPTransport

    public init(key: String, model: String = TypeSafeAPI.model, url: URL = TypeSafeAPI.url,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.key = key; self.model = model; self.url = url; self.transport = transport
    }

    /// One Jev call: the answers, or nil (no key, offline, timeout, HTTP error, no `answers`).
    public func systemOne(state: JSONValue, questions: JSONValue, assets: JSONValue? = nil,
                          timeout: TimeInterval = TypeSafeAPI.timeout) async -> TypeSafeReply? {
        guard !key.isEmpty else { return nil }
        let req = TypeSafeRequest.build(key: key, state: state, questions: questions, assets: assets,
                                        model: model, url: url, timeout: timeout)
        guard let reply = try? await transport.send(req) else { return nil }
        return TypeSafeReply.parse(reply)
    }

    /// `_jev_judge`: with the screenshot first (when there is one); if that call fails, the same second from the
    /// text alone. Returns the answers and whether the screenshot was used.
    public func judge(state: JSONValue, questions: JSONValue, jpegBase64: String = "", ref: String = "",
                      imagesOn: Bool = true) async -> (reply: TypeSafeReply?, usedImage: Bool) {
        var state = state
        if !jpegBase64.isEmpty, !ref.isEmpty, imagesOn {
            if let out = await systemOne(state: state, questions: questions,
                                         assets: TypeSafeRequest.imageAsset(jpegBase64: jpegBase64, ref: ref)) {
                return (out, true)
            }
            state = TypeSafeRequest.withoutImage(state)
        } else if !ref.isEmpty {
            state = TypeSafeRequest.withoutImage(state)
        }
        return (await systemOne(state: state, questions: questions), false)
    }

    /// app.py's shape check before a key is tried: 8–300 printable characters, no whitespace.
    public static func keyLooksValid(_ raw: String) -> Bool {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = k.unicodeScalars.count
        return n >= 8 && n <= 300 && !k.unicodeScalars.contains {
            PortedText.isPyWhitespace($0) || $0.properties.generalCategory == .control
                || $0.properties.generalCategory == .format
        }
    }

    /// `_jev_key_check`: does this key answer one tiny question? False for a malformed key without a call.
    public static func verifyKey(_ raw: String, url: URL = TypeSafeAPI.url,
                                 transport: any HTTPTransport = URLSessionTransport()) async -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyLooksValid(key) else { return false }
        guard let reply = try? await transport.send(TypeSafeRequest.keyCheck(key: key, url: url)) else { return false }
        return TypeSafeReply.parse(reply) != nil
    }
}
