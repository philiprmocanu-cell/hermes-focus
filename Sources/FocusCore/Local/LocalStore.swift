import Foundation

// MARK: - The local brain's files (no server)
//
// Everything the server kept on its disk, kept under one folder on the Mac instead
// (the app passes ~/Library/Application Support/HermesFocus/local/):
//   state.json               the session: goal, its world and rubric, the running block's ticks and
//                            minute frames, rulings, settings, recent events
//   history.jsonl            one scored block per line (the server's blocks/<day>.json, flattened)
//   labels.jsonl             one nudge label per line (the server's focus_labels.jsonl)
//   rubrics/<slug>.md|.json  the newest rubric for a goal label; <slug>.jsonl the last 5 versions
//   reports/<YYYY-MM-DD>.md  the day's report (FocusDay markdown; the server's Google Doc)
// Every write is atomic (write a temp file, then rename). Nothing here ever holds the visible screen
// text or a screenshot: those live in memory for the running block only (`LocalSenseMemory`).

struct LocalStore: Sendable {
    let root: URL

    var stateURL: URL { root.appendingPathComponent("state.json") }
    var historyURL: URL { root.appendingPathComponent("history.jsonl") }
    var labelsURL: URL { root.appendingPathComponent("labels.jsonl") }
    var rubricsDir: URL { root.appendingPathComponent("rubrics", isDirectory: true) }
    var reportsDir: URL { root.appendingPathComponent("reports", isDirectory: true) }

    static let rubricVersionsKept = 5

    // MARK: Plumbing

    static func encode(_ v: JSONValue) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)) ?? Data("null".utf8)
    }

    static func line(_ v: JSONValue) -> String { String(decoding: encode(v), as: UTF8.self) }

    static func decode(_ data: Data) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }

    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    func readLines(_ url: URL) -> [JSONValue] {
        guard let data = read(url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            Self.decode(Data($0.utf8))
        }
    }

    func writeLines(_ rows: [JSONValue], to url: URL) {
        let text = rows.map(Self.line).joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
        write(Data(text.utf8), to: url)
    }

    /// Append one row (read, add, rewrite atomically — the files are small).
    func append(_ row: JSONValue, to url: URL) {
        writeLines(readLines(url) + [row], to: url)
    }

    // MARK: State

    func loadState() -> Judge.Dict? {
        guard let data = read(stateURL), case .object(let o)? = Self.decode(data) else { return nil }
        return o
    }

    func saveState(_ st: Judge.Dict) { write(Self.encode(.object(st)), to: stateURL) }

    // MARK: History and labels

    func loadHistory() -> [JSONValue] { readLines(historyURL) }
    func saveHistory(_ rows: [JSONValue]) { writeLines(rows, to: historyURL) }
    func appendLabel(_ row: JSONValue) { append(row, to: labelsURL) }
    func loadLabels() -> [JSONValue] { readLines(labelsURL) }

    // MARK: Rubrics

    /// `_focus_rubric_slug`: the goal label, normalised, as a file name ("goal" when empty).
    static func slug(_ label: String) -> String {
        var out = ""
        var dash = false
        for u in Scoring.norm(label).unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) {
                out.unicodeScalars.append(u)
                dash = false
            } else if !dash {
                out.append("-")
                dash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(60))
        return out.isEmpty ? "goal" : out
    }

    func rubricPast(_ label: String) -> JSONValue? {
        guard let data = read(rubricsDir.appendingPathComponent("\(Self.slug(label)).json")),
              let v = Self.decode(data), case .object = v else { return nil }
        return v
    }

    /// Newest wins in <slug>.md / <slug>.json; <slug>.jsonl keeps the last five versions. A fallback rubric
    /// is never stored.
    func storeRubric(_ label: String, rubric: JSONValue, note: String, at: Double) {
        guard case .object = rubric, !Judge.truthy(rubric["fallback"]) else { return }
        let slug = Self.slug(label)
        write(Data(Judge.pyStrOr(rubric["md"]).utf8), to: rubricsDir.appendingPathComponent("\(slug).md"))
        write(Self.encode(rubric), to: rubricsDir.appendingPathComponent("\(slug).json"))
        let hist = rubricsDir.appendingPathComponent("\(slug).jsonl")
        let rows = readLines(hist) + [.object(["at": .number(at), "goal": .string(String(label.prefix(200))),
                                               "note": .string(note), "rubric": rubric])]
        writeLines(Array(rows.suffix(Self.rubricVersionsKept)), to: hist)
    }

    // MARK: Reports

    func writeReport(day: String, markdown: String) {
        write(Data(markdown.utf8), to: reportsDir.appendingPathComponent("\(day).md"))
    }
}

// MARK: - Counters (`health`)

/// Calls, errors, time and tokens since this brain started. Lock-protected so `LocalBrain.health` can be
/// read synchronously while the brain works.
final class LocalCounters: @unchecked Sendable {
    /// TypeSafe's price per million tokens (app.py `_jev_health`).
    static let typesafePerMTok = 0.042
    /// Input / output dollars per million tokens for the second opinion (app.py `_SECOND_PRICES`).
    static let secondPrices: [String: (Double, Double)] = [
        "claude-sonnet-5-5": (2.0, 10.0), "claude-opus-5-5": (4.0, 20.0), "claude-haiku-5-5": (0.10, 0.50)]

    private let lock = NSLock()
    private var jev = (calls: 0, errors: 0, ms: 0, tokens: 0, inputTokens: 0, images: 0, imageErrors: 0,
                       imageTokens: 0, nudges: 0)
    private var second = (calls: 0, errors: 0, gate: 0, unsure: 0, yes: 0, no: 0, ms: 0, cost: 0.0)
    private var secondLast: JSONValue = .null
    private var claude = (calls: 0, errors: 0)

    func jevCall(ms: Int, reply: TypeSafeReply?, imageSent: Bool, usedImage: Bool) {
        lock.withLock {
            jev.calls += 1
            jev.ms += ms
            guard let reply else { jev.errors += 1; if imageSent { jev.imageErrors += 1 }; return }
            jev.tokens += reply.tokens
            jev.inputTokens += reply.inputTokens
            if usedImage { jev.images += 1; jev.imageTokens += reply.tokens }
            if imageSent && !usedImage { jev.imageErrors += 1 }
        }
    }

    func nudge() { lock.withLock { jev.nudges += 1 } }

    func claudeCall(ok: Bool) { lock.withLock { claude.calls += 1; if !ok { claude.errors += 1 } } }

    func secondCall(trigger: String, model: String, ms: Int, inputTokens: Int, outputTokens: Int,
                    verdict: SecondOpinion.Verdict?, last: JSONValue) {
        let (pin, pout) = Self.secondPrices[model] ?? Self.secondPrices["claude-sonnet-5-5"]!
        lock.withLock {
            second.calls += 1
            if trigger == "gate" { second.gate += 1 } else { second.unsure += 1 }
            second.ms += ms
            second.cost += (Double(inputTokens) * pin + Double(outputTokens) * pout) / 1_000_000
            if let verdict {
                if verdict.onTask { second.yes += 1 } else { second.no += 1 }
                secondLast = last
            } else {
                second.errors += 1
            }
        }
    }

    func json(typesafeReady: Bool, anthropicKey: Bool, model: String) -> JSONValue {
        lock.withLock {
            let calls = jev.calls
            func avg(_ total: Int, _ n: Int) -> Double { n > 0 ? Double(total / n) : 0 }
            let jevJSON: JSONValue = .object([
                "state": .string(typesafeReady ? "ready" : "no_key"),
                "calls": .number(Double(calls)), "errors": .number(Double(jev.errors)),
                "avg_ms": .number(avg(jev.ms, calls)), "tokens": .number(Double(jev.tokens)),
                "avg_tokens": .number(avg(jev.inputTokens, calls)),
                "cost_usd": .number(Judge.pyRound(Double(jev.tokens) * Self.typesafePerMTok / 1_000_000, 4)),
                "images": .number(Double(jev.images)), "image_errors": .number(Double(jev.imageErrors)),
                "image_cost_usd": .number(Judge.pyRound(Double(jev.imageTokens) * Self.typesafePerMTok / 1_000_000, 4)),
                "nudges": .number(Double(jev.nudges)), "questions": .number(Double(Judge.generalChecks.count)),
            ])
            let secondJSON: JSONValue = .object([
                "on": .bool(anthropicKey), "key": .bool(anthropicKey), "model": .string(model),
                "calls": .number(Double(second.calls)), "errors": .number(Double(second.errors)),
                "gate": .number(Double(second.gate)), "unsure": .number(Double(second.unsure)),
                "yes": .number(Double(second.yes)), "no": .number(Double(second.no)),
                "avg_ms": .number(avg(second.ms, second.calls)),
                "cost_usd": .number(Judge.pyRound(second.cost, 4)), "last": secondLast,
            ])
            let totalCost = Double(jev.tokens) * Self.typesafePerMTok / 1_000_000 + second.cost
            return .object([
                "jev": jevJSON, "second_opinion": secondJSON,
                "claude": .object(["calls": .number(Double(claude.calls)), "errors": .number(Double(claude.errors))]),
                "calls": .number(Double(calls + second.calls + claude.calls)),
                "errors": .number(Double(jev.errors + second.errors + claude.errors)),
                "avg_ms": .number(avg(jev.ms, calls)), "tokens": .number(Double(jev.tokens)),
                "images": .number(Double(jev.images)), "second_opinion_calls": .number(Double(second.calls)),
                "cost_usd": .number(Judge.pyRound(totalCost, 4)),
            ])
        }
    }
}
