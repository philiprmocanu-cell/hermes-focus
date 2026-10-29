import Foundation
import FocusCore
import os

let log = Logger(subsystem: "app.hermesfocus.mac", category: "focus")

/// Best-effort HTTP client for the brain. Every call: 20 s timeout, never throws, never blocks the UI.
/// The token lives in the URL path, so URLs are never logged.
///
/// "Run on my own keys" (local mode): a `hermes-local://focus/<route>` address (`LocalRoute`, from
/// `BrainDispatch.target`) is answered by the one shared `LocalBrain` on this Mac instead of the network —
/// same JSON replies, same statuses (402 without a TypeSafe key), so no caller changes.
final class BrainClient: @unchecked Sendable {
    let config: BrainConfig?
    private let session: URLSession
    private let lock = NSLock()
    private var _local: LocalBrain?

    /// The local brain, once local mode is on (nil in owner and friend mode).
    var local: LocalBrain? {
        get { lock.lock(); defer { lock.unlock() }; return _local }
        set { lock.lock(); _local = newValue; lock.unlock() }
    }

    init(envPath: String) {
        if let text = try? String(contentsOfFile: envPath, encoding: .utf8) {
            config = BrainConfig.parse(env: text)
        } else {
            config = nil
        }
        if config == nil { log.error("brain config missing or has no BRAIN_API_TOKEN (\(envPath, privacy: .public))") }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": BrainConfig.userAgent]
        session = URLSession(configuration: c)
    }

    /// POST `body` as JSON to `path`; returns the decoded JSON response, or nil on any failure.
    func post<Body: Encodable & Sendable>(_ path: String, _ body: Body, timeout: TimeInterval = 20) async -> JSONValue? {
        guard let config, let url = config.url(path: path) else { return nil }
        return await send(url: url, label: path, body: body, timeout: timeout)
    }

    /// GET `path` (owner routes behind the secret URL).
    func get(_ path: String, timeout: TimeInterval = 12) async -> JSONValue? {
        guard let config, let url = config.url(path: path) else { return nil }
        return await send(url: url, label: path, body: Optional<JSONValue>.none, timeout: timeout)
    }

    /// Any URL (friend leaderboard routes: plain `{base}/lb/...`). `body` nil = GET.
    func send<Body: Encodable & Sendable>(url: URL, label: String, body: Body?, headers: [String: String] = [:],
                                          timeout: TimeInterval = 20) async -> JSONValue? {
        let r = await sendWithStatus(url: url, label: label, body: body, headers: headers, timeout: timeout)
        return (200..<300).contains(r.status) ? r.json : nil
    }

    /// Same, but also the HTTP status (0 = no answer at all) and, on an error status, the decoded error body —
    /// a friend's sense / frame without a TypeSafe key comes back 402 with `{"typesafe": "missing"}`.
    func sendWithStatus<Body: Encodable & Sendable>(url: URL, label: String, body: Body?, headers: [String: String] = [:],
                                                    timeout: TimeInterval = 20) async -> (status: Int, json: JSONValue?) {
        if let route = LocalRoute.route(from: url) {
            return await answerLocally(route, body: body, query: LocalRoute.query(from: url))
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(BrainConfig.userAgent, forHTTPHeaderField: "User-Agent")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            guard let data = try? JSONEncoder().encode(body) else { return (0, nil) }
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
        } else {
            req.httpMethod = "GET"
        }
        let path = label
        do {
            let (respData, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: respData)
            guard (200..<300).contains(status) else {
                log.error("brain \(path, privacy: .public) -> HTTP \(status)")
                return (status, decoded)
            }
            return (status, decoded ?? .object([:]))
        } catch {
            log.error("brain \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return (0, nil)
        }
    }

    /// A local route: `LocalBrain.handle`, with the body as the same JSON the server would have received.
    private func answerLocally<Body: Encodable & Sendable>(_ route: FocusRoute, body: Body?, query: String) async -> (status: Int, json: JSONValue?) {
        guard let local else {
            log.error("local \(route.rawValue, privacy: .public): no local brain")
            return (0, nil)
        }
        var json: JSONValue?
        if let body {
            guard let data = try? JSONEncoder().encode(body),
                  let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return (0, nil) }
            json = v
        }
        let (status, reply) = await local.handle(route, body: json, query: query)
        if !(200..<300).contains(status) { log.error("local \(route.rawValue, privacy: .public) -> \(status)") }
        return (status, reply)
    }
}
