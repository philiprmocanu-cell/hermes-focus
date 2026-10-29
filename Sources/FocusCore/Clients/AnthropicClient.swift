import Foundation

// MARK: - Anthropic (Claude), on the user's own key
//
// Port of app.py `_focus_opus_json`: one Messages API call, raw HTTP (there is no official Swift SDK),
//   POST https://api.anthropic.com/v1/messages
//   x-api-key: <key>, anthropic-version: 2023-06-01, content-type: application/json[, anthropic-beta: …]
//   {"model", "max_tokens", "system", "messages": [{"role": "user", "content": [image?, text]}], …extras}
// The screenshot, when there is one, rides as a base64 JPEG image block before the text. No `temperature`
// (current models reject a non-default one). JSON is asked for in the prompt and dug out of the reply text.
// A refusal (stop_reason "refusal"), any 4xx/5xx, a timeout or an unreadable reply is an `AnthropicError`,
// never a crash; every caller has a fallback. On Sonnet 5.5 / Opus 5.5 / Opus 5 the strong calls opt into the
// server-side refusal fallback (`fallbacks: "default"`, beta server-side-fallback-2026-07-01); an account that
// rejects it gets the same call once more without it, exactly as app.py does.

public enum AnthropicAPI {
    public static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let version = "2023-06-01"
    /// Rubric, second opinion and (unless he picks another) the end-of-block advice.
    public static let defaultModel = "claude-sonnet-5-5"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Models that accept `fallbacks: "default"` (app.py's list).
    public static let fallbackModels: Set<String> = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5"]
    /// app.py `_FOCUS_OPUS_MAX_TOKENS`.
    public static let defaultMaxTokens = 600
}

/// One call's inputs.
public struct AnthropicCall: Equatable, Sendable {
    public var system: String
    public var user: String
    /// Base64 JPEG ("" = none).
    public var jpegBase64: String
    public var model: String
    public var maxTokens: Int
    public var timeout: TimeInterval
    /// Extra request fields (thinking, output_config, fallbacks).
    public var extra: [String: JSONValue]
    /// The anthropic-beta header ("" = none).
    public var betas: String

    public init(system: String, user: String, jpegBase64: String = "", model: String = AnthropicAPI.defaultModel,
                maxTokens: Int = AnthropicAPI.defaultMaxTokens, timeout: TimeInterval = 30,
                extra: [String: JSONValue] = [:], betas: String = "") {
        self.system = system; self.user = user; self.jpegBase64 = jpegBase64; self.model = model
        self.maxTokens = maxTokens; self.timeout = timeout; self.extra = extra; self.betas = betas
    }

    /// app.py's settings for a quick structured answer (rubric, second opinion, goal step): effort low; on
    /// Sonnet 5.5 thinking `between_tools` (its thinking-off setting); on Sonnet 5.5 / Opus 5.5 / Opus 5 a safety
    /// decline is retried on Anthropic's recommended model (`fallbacks: "default"` + the beta header).
    public static func quickExtras(model: String) -> (extra: [String: JSONValue], betas: String) {
        var extra: [String: JSONValue] = ["output_config": .object(["effort": .string("low")])]
        var betas = ""
        if model == "claude-sonnet-5-5" { extra["thinking"] = .object(["type": .string("between_tools")]) }
        if AnthropicAPI.fallbackModels.contains(model) {
            extra["fallbacks"] = .string("default")
            betas = AnthropicAPI.fallbackBeta
        }
        return (extra, betas)
    }
}

public enum AnthropicRequest {
    public static func body(_ c: AnthropicCall) -> JSONValue {
        var content: [JSONValue] = []
        if !c.jpegBase64.isEmpty {
            content.append(.object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string(c.jpegBase64)])]))
        }
        content.append(.object(["type": .string("text"), "text": .string(c.user)]))
        var o: [String: JSONValue] = ["model": .string(c.model), "max_tokens": .number(Double(c.maxTokens)),
                                      "system": .string(c.system),
                                      "messages": .array([.object(["role": .string("user"), "content": .array(content)])])]
        for (k, v) in c.extra { o[k] = v }
        return .object(o)
    }

    /// The whole request, ready to send. Pure: no network.
    public static func build(key: String, call c: AnthropicCall, url: URL = AnthropicAPI.url) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: c.timeout)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicAPI.version, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !c.betas.isEmpty { req.setValue(c.betas, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = ClientJSON.encode(body(c))
        return req
    }
}

public enum AnthropicError: Error, Equatable, Sendable {
    case noKey
    /// Out of credit ("credit balance" / "billing" in a 400/402/429): stop asking for a while.
    case billing
    case http(status: Int, detail: String)
    /// The model (and any fallback) declined.
    case refusal
    /// No reply at all (offline, timeout).
    case transport
    /// A reply with no usable text / JSON in it.
    case unreadable
}

public struct AnthropicReply: Equatable, Sendable {
    public var text: String
    public var stopReason: String
    public var inputTokens: Int
    public var outputTokens: Int

    public static func parse(_ data: Data) -> AnthropicReply? {
        guard let v = ClientJSON.decode(data), case .object = v else { return nil }
        let text = (v["content"]?.arrayValue ?? []).compactMap { part -> String? in
            part["type"]?.stringValue == "text" ? (part["text"]?.stringValue ?? "") : nil
        }.joined()
        return AnthropicReply(text: text, stopReason: v["stop_reason"]?.stringValue ?? "",
                              inputTokens: Int(PortedText.number(v["usage"]?["input_tokens"]) ?? 0),
                              outputTokens: Int(PortedText.number(v["usage"]?["output_tokens"]) ?? 0))
    }
}

public struct AnthropicClient: Sendable {
    public var key: String
    public var url: URL
    public var transport: any HTTPTransport

    public init(key: String, url: URL = AnthropicAPI.url, transport: any HTTPTransport = URLSessionTransport()) {
        self.key = key; self.url = url; self.transport = transport
    }

    /// One call → the reply text, or why not.
    public func send(_ call: AnthropicCall) async -> Result<AnthropicReply, AnthropicError> {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.noKey) }
        var call = call
        for attempt in 0...1 {
            let reply: HTTPReply
            do { reply = try await transport.send(AnthropicRequest.build(key: key, call: call, url: url)) }
            catch { return .failure(.transport) }
            if !(200..<300).contains(reply.status) {
                let detail = PortedText.prefix(String(decoding: reply.body, as: UTF8.self), 300)
                let low = detail.lowercased()
                if [400, 402, 429].contains(reply.status) && (low.contains("credit balance") || low.contains("billing")) {
                    return .failure(.billing)
                }
                // The refusal fallback is a beta: if this account rejects it, ask once more without it.
                if attempt == 0 && reply.status == 400 && low.contains("fallback") && call.extra["fallbacks"] != nil {
                    call.extra["fallbacks"] = nil
                    call.betas = ""
                    continue
                }
                return .failure(.http(status: reply.status, detail: detail))
            }
            guard let out = AnthropicReply.parse(reply.body) else { return .failure(.unreadable) }
            if out.stopReason == "refusal" { return .failure(.refusal) }
            return .success(out)
        }
        return .failure(.unreadable)
    }

    /// `_focus_opus_json`: the JSON object in the reply.
    public func json(_ call: AnthropicCall) async -> Result<JSONValue, AnthropicError> {
        switch await send(call) {
        case .failure(let e): return .failure(e)
        case .success(let r):
            guard let v = RubricWriter.decodeObject(r.text) else { return .failure(.unreadable) }
            return .success(v)
        }
    }

    // MARK: The four focus calls

    /// app.py `_RUBRIC_TIMEOUT_S` / `_RUBRIC_MAX_TOKENS`.
    public static let rubricTimeout: TimeInterval = 12
    public static let rubricMaxTokens = 2500

    /// The rubric writer call (brain/rubric.py prompt). Never fails: anything wrong is the fallback rubric.
    /// Rulings are not merged here — call `RubricWriter.mergeRulings` with the label rows after.
    public func writeRubric(prompt: String, note: String = "", model: String = AnthropicAPI.defaultModel) async -> Rubric {
        let q = AnthropicCall.quickExtras(model: model)
        let call = AnthropicCall(system: RubricWriter.systemPrompt(), user: prompt, model: model,
                                 maxTokens: Self.rubricMaxTokens, timeout: Self.rubricTimeout,
                                 extra: q.extra, betas: q.betas)
        guard case .success(let raw) = await json(call) else { return RubricWriter.fallback(note: note) }
        return RubricWriter.parse(raw, note: note)
    }

    /// The second opinion (6 s). Nil = no answer: Jev's verdict stands.
    public func secondOpinion(_ ctx: SecondOpinion.Context, jpegBase64: String = "",
                              model: String = AnthropicAPI.defaultModel) async -> SecondOpinion.Verdict? {
        guard case .success(let v) = await json(SecondOpinion.call(ctx, jpegBase64: jpegBase64, model: model))
        else { return nil }
        return SecondOpinion.parse(v)
    }

    /// The end-of-block work-smarter paragraph. Nil = keep the plain advice the block was scored with.
    public func blockAdvice(_ input: BlockAdvice.Input, jpegBase64: String = "", profile: String = "",
                            model: String = AnthropicAPI.defaultModel) async -> String? {
        guard case .success(let v) = await json(BlockAdvice.call(input, jpegBase64: jpegBase64, profile: profile,
                                                                 model: model)) else { return nil }
        return BlockAdvice.parse(v)
    }

    /// The goal step: what he typed → one specific goal, its world (`related`) and questions. `.failure` = the
    /// caller takes the goal as typed (app.py's "model unavailable" path).
    public func goalStep(_ input: GoalStep.Input, profile: String = "",
                         model: String = AnthropicAPI.defaultModel) async -> Result<GoalStep.Reply, AnthropicError> {
        switch await json(GoalStep.call(input, profile: profile, model: model)) {
        case .failure(let e): return .failure(e)
        case .success(let v): return .success(GoalStep.parse(v, input: input))
        }
    }
}
