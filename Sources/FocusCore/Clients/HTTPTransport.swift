import Foundation

// MARK: - The one door to the network for the no-server brain
//
// TypeSafe (Jev) and Anthropic are called straight from the Mac on the user's own keys. Every request is
// built by a pure function (`TypeSafeRequest.build`, `AnthropicRequest.build`) and sent through this protocol,
// so tests and the local brain can stub the network and nothing in a test ever reaches a real API.

public struct HTTPReply: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPTransport: Sendable {
    /// Send it and wait for the reply. The request's own `timeoutInterval` is the time limit. Throws on no reply
    /// at all (offline, timeout); any HTTP status comes back as a reply.
    func send(_ request: URLRequest) async throws -> HTTPReply
}

/// The real network: an ephemeral session (no cookies, no cache, nothing written to disk).
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let (data, response) = try await session.data(for: request)
        return HTTPReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

enum ClientJSON {
    /// Compact, sorted keys, slashes unescaped — stable bytes for the same body.
    static func encode(_ v: JSONValue) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)) ?? Data("{}".utf8)
    }

    static func decode(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }
}
