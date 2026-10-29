import XCTest
@testable import FocusCore

// The local brain end to end, with no network: a stub transport answers TypeSafe (Jev) and Anthropic from
// canned replies chosen by what each request asks, and the clock is the test's own.

/// The test's clock.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    init(_ t: Double) { self.t = t }
    var now: Double { lock.withLock { t } }
    func set(_ v: Double) { lock.withLock { t = v } }
}

/// Answers by request: TypeSafe → Jev answers for the screen in the state; Anthropic → by system prompt.
private final class FakeAPIs: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _gate: [Bool] = []
    private(set) var typesafeCalls = 0
    private(set) var imageCalls = 0
    private(set) var anthropicSystems: [String] = []
    private(set) var secondPrompts: [String] = []

    /// The second opinion's next answers (yes = on task), oldest first; none left = "no".
    func gate(_ answers: [Bool]) { lock.withLock { _gate += answers } }
    var anthropicCalls: Int { lock.withLock { anthropicSystems.count } }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        if request.url?.host == "api.typesafe.ai" {
            lock.withLock {
                typesafeCalls += 1
                if request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == "true" { imageCalls += 1 }
            }
            if body["state"]?["check"] != nil { return json(["answers": .object(["ok": .object(["noul": .number(0.99)])])]) }
            return json(["answers": .object(Self.jev(body["state"] ?? .null)),
                         "usage": .object(["input_tokens": .number(900), "output_tokens": .number(40)])])
        }
        let system = body["system"]?.stringValue ?? ""
        let user = body["messages"]?.arrayValue?.first?["content"]?.arrayValue?.last?["text"]?.stringValue ?? ""
        lock.withLock { anthropicSystems.append(system) }
        if system.hasPrefix("Someone typed") {
            return claude("""
            {"status": "ok", "goal": "Essay intro", "understood": "Writing the essay's intro.", "question": "",
             "specific_goal": "Draft the intro paragraph of the essay", "specificity": 0.8, "specificity_hint": "",
             "related": {"terms": ["essay", "intro"]},
             "questions": [{"id": "q1", "text": "Is the essay document open?", "means": "on_task"}]}
            """)
        }
        if system.hasPrefix("You write the RUBRIC") {
            return claude("""
            {"kind": "writing", "balance": {"focus": 0.4, "output": 0.6},
             "milestones": [{"id": "m1", "text": "the intro paragraph is written in the essay doc"}],
             "on_tells": [{"id": "t1", "text": "Is he typing the essay intro?"},
                          {"id": "t2", "text": "Is the essay document on screen?"},
                          {"id": "t3", "text": "Is he reading a source for the essay?"},
                          {"id": "t4", "text": "Is he outlining the intro?"},
                          {"id": "t5", "text": "Is he asking an AI about the essay's argument?"},
                          {"id": "t6", "text": "Is he checking a citation for the essay?"}],
             "off_tells": [{"id": "x1", "text": "Is he watching videos unrelated to the essay?"},
                           {"id": "x2", "text": "Is he on social media?"},
                           {"id": "x3", "text": "Is he shopping?"}],
             "smart": ["Outline with AI, then write by hand."]}
            """)
        }
        if system.hasPrefix("You double-check") {
            let yes = lock.withLock { () -> Bool in
                secondPrompts.append(user)
                return _gate.isEmpty ? false : _gate.removeFirst()
            }
            return claude("{\"on_task\": \"\(yes ? "yes" : "no")\", \"reason\": \"\(yes ? "Researching for the essay." : "Unrelated page.")\"}")
        }
        if system.hasPrefix("A 25-to-60-minute focus block") {
            return claude("{\"advice\": \"Nothing was repetitive; next time outline first with AI.\"}")
        }
        return HTTPReply(status: 500, body: Data("{}".utf8))
    }

    private func json(_ o: [String: JSONValue]) -> HTTPReply {
        HTTPReply(status: 200, body: try! JSONEncoder().encode(JSONValue.object(o)))
    }

    private func claude(_ text: String) -> HTTPReply {
        json(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
              "stop_reason": .string("end_turn"),
              "usage": .object(["input_tokens": .number(500), "output_tokens": .number(60)])])
    }

    /// Jev's answers: the essay screen is plainly on task (and shows the milestone when its title says
    /// "done"); any other screen is plainly a feed.
    static func jev(_ state: JSONValue) -> [String: JSONValue] {
        let app = state["screen_now"]?["app"]?.stringValue ?? ""
        let title = state["screen_now"]?["window_title"]?.stringValue ?? ""
        func noul(_ p: Double) -> JSONValue { .object(["type": .string("noul"), "noul": .number(p)]) }
        func score(_ p: [String: Double]) -> JSONValue {
            .object(["type": .string("score"), "probabilities": .object(p.mapValues { .number($0) })])
        }
        if app == "Pages" {
            var a: [String: JSONValue] = [
                "on_goal": score(["0": 0.02, "3": 0.98]), "working": score(["3": 0.9, "2": 0.1]),
                "producing": score(["3": 1]), "quality": score(["2": 1]), "smart": score(["2": 1]),
                "progress": score(["1": 1]),
                "activity": .object(["choice": .string("making"),
                                     "probabilities": .object(["making": .number(0.9), "studying": .number(0.1)])]),
                "serves_goal": noul(0.1), "step_toward_goal": noul(0.2), "chk_making": noul(0.95)]
            if title.contains("done") { a["ms_m1"] = noul(0.9) }
            return a
        }
        return ["on_goal": score(["0": 0.98, "3": 0.02]), "working": score(["0": 1]), "producing": score(["0": 1]),
                "quality": score(["0": 1]), "smart": score(["0": 1]), "progress": score(["0": 1]),
                "activity": .object(["choice": .string("consuming"),
                                     "probabilities": .object(["consuming": .number(0.95), "other": .number(0.05)])]),
                "serves_goal": noul(0.02), "step_toward_goal": noul(0.02), "chk_feed": noul(0.95),
                "chk_entertainment": noul(0.9)]
    }
}

private let secret = "SECRET-SCREEN-TEXT-42"
// A tiny JPEG header, enough for the brain's check.
private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01]).base64EncodedString()

final class LocalBrainTests: XCTestCase {
    var dir: URL!
    let t0 = 1_793_000_000.0      // 2026-10-28, mid-day

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("localbrain-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func brain(_ apis: FakeAPIs, _ clock: Clock, typesafe: String = "ts_test_key_123",
                       anthropic: String = "sk-test") -> LocalBrain {
        LocalBrain(storeURL: dir, keys: { LocalBrain.Keys(typesafe: typesafe, anthropic: anthropic) },
                   transport: apis, now: { Date(timeIntervalSince1970: clock.now) })
    }

    private func obj(_ o: [String: JSONValue]) -> JSONValue { .object(o) }

    /// One sense second on a screen.
    @discardableResult
    private func sense(_ b: LocalBrain, _ clock: Clock, _ t: Double, block: String, app: String, title: String,
                       url: String = "", image: Bool = false) async -> (Int, JSONValue) {
        clock.set(t0 + t)
        var body: [String: JSONValue] = [
            "block_id": .string(block), "goal": .string("Essay intro"), "at": .number(t0 + t), "app": .string(app),
            "title": .string(title), "url": .string(url), "text": .string("\(secret) \(title)"),
            "text_digest": .string("x"), "text_changed_share": .number(0.1), "typed": .bool(true),
            "scrolled": .bool(false), "idle_s": .number(1), "app_switched": .bool(false)]
        if image { body["image_jpeg_b64"] = .string(jpeg) }
        return await b.handle(.sense, body: .object(body))
    }

    private func labelRows() -> [JSONValue] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("labels.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    private func everyFileText() -> String {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var all = ""
        while let u = e?.nextObject() as? URL {
            if let s = try? String(contentsOf: u, encoding: .utf8) { all += s }
        }
        return all
    }

    // MARK: A whole block

    func testAWholeBlockEndToEnd() async throws {
        let apis = FakeAPIs(), clock = Clock(t0)
        let b = brain(apis, clock)
        XCTAssertTrue(b.ready)

        // The goal: sharpened by Claude, its world, and a rubric (writing: 40% focus, 60% output, one milestone).
        let (gs, goal) = await b.handle(.goal, body: obj(["text": .string("write the essay intro"),
                                                          "previous_goal": .string(""), "previous_understood": .string(""),
                                                          "at": .number(t0)]))
        XCTAssertEqual(gs, 200)
        XCTAssertEqual(goal["status"], .string("ok"))
        XCTAssertEqual(goal["goal"], .string("Essay intro"))
        XCTAssertEqual(goal["specific_goal"], .string("Draft the intro paragraph of the essay"))
        XCTAssertEqual(goal["related"]?["terms"], .array([.string("essay"), .string("intro")]))
        XCTAssertEqual(goal["rubric"]?["kind"], .string("writing"))
        XCTAssertEqual(goal["rubric"]?["balance"]?["focus"], .number(0.4))
        XCTAssertEqual(goal["questions"]?.arrayValue?.first?["id"], .string("rub_on_t1"))
        XCTAssertNotNil(GoalReply.parse(goal)?.rubric)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rubrics/essay-intro.md").path))

        // The fix line re-runs the writer and keeps the goal.
        let (fs, fixed) = await b.handle(.goal, body: obj(["text": .string("write the essay intro"),
                                                           "previous_goal": .string("Essay intro"),
                                                           "previous_understood": .string(""),
                                                           "rubric_note": .string("the outline counts too"),
                                                           "at": .number(t0)]))
        XCTAssertEqual(fs, 200)
        XCTAssertEqual(fixed["rubric_note_applied"], .bool(true))
        XCTAssertEqual(fixed["goal"], .string("Essay intro"))

        let block = "blk-1"
        _ = await b.handle(.event, body: obj(["kind": .string("block_started"), "block_id": .string(block),
                                              "goal": .string("Essay intro"), "at": .number(t0)]))

        // 35 seconds on the essay (the first with a screenshot).
        for t in 0..<35 {
            let (s, r) = await sense(b, clock, Double(t), block: block, app: "Pages", title: "Essay draft", image: t == 0)
            XCTAssertEqual(s, 200)
            XCTAssertEqual(r["nudge"], .string(""))
            XCTAssertEqual(r["verdict"]?["mode"], .string("making"))
        }
        // A screenshot speaks for its screen for 6 s: seconds 0-6 carry it.
        XCTAssertEqual(apis.imageCalls, 7)

        // An off run on a gossip page: at 20 s the nudge is due, the second opinion says he is on task → no nudge.
        apis.gate([true])
        var cleared = false
        for t in 35...56 {
            let (_, r) = await sense(b, clock, Double(t), block: block, app: "Safari", title: "Celebrity gossip",
                                     url: "https://gossip.example.com/a")
            XCTAssertEqual(r["nudge"], .string(""), "t=\(t)")
            if r["verdict"]?["related"] == .bool(true) { cleared = true }
        }
        XCTAssertTrue(cleared, "the gate's yes settles the second as related")
        XCTAssertEqual(apis.secondPrompts.count, 1)

        // The minute fold: a frame came back at the minute.
        let (_, minute) = await sense(b, clock, 61, block: block, app: "Pages", title: "Essay draft")
        XCTAssertNotNil(minute["frame"]?["on_goal"])

        // Another off run (a different page), gate says no → the nudge goes out.
        apis.gate([false])
        var nudgeId = ""
        for t in 62...90 where nudgeId.isEmpty {
            let (_, r) = await sense(b, clock, Double(t), block: block, app: "Safari", title: "Sports scores",
                                     url: "https://news.example.org/b")
            if let id = r["nudge_id"]?.stringValue, !id.isEmpty {
                nudgeId = id
                XCTAssertFalse(r.str("nudge").isEmpty)
                XCTAssertEqual(t, 82)
            }
        }
        XCTAssertFalse(nudgeId.isEmpty)
        XCTAssertEqual(apis.secondPrompts.count, 2)

        // "I'm on task" on it: a label row, a ruling, and the nudge gap starts again.
        let (es, ex) = await b.handle(.exception, body: obj(["block_id": .string(block), "nudge_id": .string(nudgeId),
                                                             "app": .string("Safari"), "title": .string("x"),
                                                             "url": .string(""), "at": .number(t0 + 91)]))
        XCTAssertEqual(es, 200)
        XCTAssertEqual(ex["ok"], .bool(true))
        XCTAssertTrue(ex.str("rule").contains("news.example.org"))
        XCTAssertEqual(labelRows().map { $0["label"] }, [.string("on_task")])
        XCTAssertEqual(labelRows().first?["source"], .string("button"))
        XCTAssertEqual(labelRows().first?["nudge_id"], .string(nudgeId))

        // A third off run: gate no → a second nudge, left unanswered; a minute later it is an off-task label.
        apis.gate([false])
        var second = ""
        for t in 92...175 {
            let (_, r) = await sense(b, clock, Double(t), block: block, app: "Safari", title: "Puzzle",
                                     url: "https://games.example.net/c")
            if let id = r["nudge_id"]?.stringValue, !id.isEmpty { second = id }
        }
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(second, nudgeId)
        let labels = labelRows()
        XCTAssertEqual(labels.map { $0["label"] }, [.string("on_task"), .string("off_task")])
        XCTAssertEqual(labels.last?["source"], .string("no_click"))
        XCTAssertEqual(labels.last?["nudge_id"], .string(second))
        XCTAssertNotNil(labels.last?["text_digest"]?.stringValue)

        // Back on the essay, finished: the milestone is reached and progress is the share of milestones.
        var reached: JSONValue?
        for t in 176...190 {
            let (_, r) = await sense(b, clock, Double(t), block: block, app: "Pages", title: "Essay draft done")
            reached = r["milestones_reached"]
            if t == 190 { XCTAssertEqual(r["goal_progress"], .number(1)) }
        }
        XCTAssertEqual(reached, .array([.string("m1")]))

        // Ticks.
        for (i, t) in [60.0, 120, 192].enumerated() {
            clock.set(t0 + t)
            let (s, r) = await b.handle(.tick, body: obj(["block_id": .string(block), "goal": .string("Essay intro"),
                                                          "understood": .string(""), "at": .number(t0 + t),
                                                          "phase": .string("work"), "active_s": .number(50),
                                                          "switches": .number(Double(i)), "app": .string("Pages"),
                                                          "title": .string("Essay draft"), "url": .string(""),
                                                          "idle_s": .number(2), "distraction_s": .number(0),
                                                          "scroll_s": .number(10), "keys_s": .number(30)]))
            XCTAssertEqual(s, 200)
            XCTAssertEqual(r["ok"], .bool(true))
        }
        let (_, now) = await b.handle(.now, body: nil)
        XCTAssertEqual(now["phase"], .string("work"))
        XCTAssertEqual(now["typesafe"], .string("ok"))
        XCTAssertEqual(now["rubric"]?["milestones_reached"], .array([.string("m1")]))

        // The block: scored with the rubric's balance, kept, reported.
        clock.set(t0 + 195)
        let payload = obj(["block_id": .string(block), "goal": .string("Essay intro"), "understood": .string(""),
                           "started_at": .number(t0), "ended_at": .number(t0 + 195), "planned_s": .number(195),
                           "completed": .bool(true), "active_s": .number(150), "switches": .number(4),
                           "apps": .array([]), "frames": .array([]), "distraction_s": .number(0),
                           "scroll_s": .number(30), "keys_s": .number(90),
                           "specific_goal": .string("Draft the intro paragraph of the essay")])
        let (bs, scored) = await b.handle(.block, body: payload)
        XCTAssertEqual(bs, 200)
        let result = try XCTUnwrap(BlockResult.parse(scored))
        XCTAssertTrue((1...1000).contains(result.score))
        XCTAssertEqual(scored["balance"], .object(["focus": .number(0.4), "output": .number(0.6)]))
        XCTAssertTrue(scored.str("balance_line").hasPrefix("Judged 40% on focus, 60% on output"))
        XCTAssertEqual(scored["milestones"]?["total"], .number(1))
        XCTAssertEqual(scored["goal_achieved"], .number(1))
        XCTAssertNotNil(scored["next_work_s"])

        // Idempotent: the same block again is the stored reply.
        let (_, again) = await b.handle(.block, body: payload)
        XCTAssertEqual(again, scored)

        await b.settle()
        let history = try String(contentsOf: dir.appendingPathComponent("history.jsonl"), encoding: .utf8)
        XCTAssertEqual(history.split(separator: "\n").count, 1)
        XCTAssertTrue(history.contains("\"block_id\":\"blk-1\""))
        XCTAssertTrue(history.contains("outline first with AI"), "the advice landed on the stored block")
        let day = LocalJSON.dayOf(t0)
        let report = try String(contentsOf: dir.appendingPathComponent("reports/\(day).md"), encoding: .utf8)
        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(labelRows().count, 2)

        let (_, hist) = await b.handle(.history, body: nil, query: "days=30")
        let days = FocusHistory.parse(hist)
        XCTAssertEqual(days.map(\.day), [day])
        XCTAssertEqual(days.first?.blocks, 1)

        let (_, lab) = await b.labels(days: 14)
        XCTAssertEqual(lab["count"], .number(2))
        XCTAssertEqual(lab["by_label"], .object(["on_task": .number(1), "off_task": .number(1)]))

        // Nothing of the screen text or the screenshot ever reached the disk.
        let disk = everyFileText()
        XCTAssertFalse(disk.contains(secret))
        XCTAssertFalse(disk.contains(jpeg))

        let health = b.health
        XCTAssertGreaterThan(health["jev"]?["calls"]?.doubleValue ?? 0, 100)
        XCTAssertEqual(health["jev"]?["images"], .number(7))
        XCTAssertEqual(health["second_opinion_calls"], .number(3))
        XCTAssertGreaterThan(health["cost_usd"]?.doubleValue ?? 0, 0)

        // The remaining routes answer without a server.
        let (ss, sug) = await b.handle(.suggestions, body: nil)
        XCTAssertEqual(ss, 200)
        XCTAssertEqual(sug, .object(["suggestions": .array([])]))
        var serverOnly = [FocusRoute.leaderboard]
        for r in serverOnly {
            let (code, _) = await b.handle(r, body: nil)
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: No TypeSafe key

    func testWithoutATypeSafeKeyNothingIsJudged() async {
        let apis = FakeAPIs(), clock = Clock(t0)
        let b = brain(apis, clock, typesafe: "", anthropic: "sk-test")
        XCTAssertFalse(b.ready)
        let missing = JSONValue.object(["error": .string("Add your TypeSafe key in Settings to be judged"),
                                        "typesafe": .string("missing")])
        let (gs, g) = await b.handle(.goal, body: obj(["text": .string("essay"), "previous_goal": .string(""),
                                                       "previous_understood": .string(""), "at": .number(t0)]))
        XCTAssertEqual(gs, 402); XCTAssertEqual(g, missing)
        let (ss, s) = await sense(b, clock, 0, block: "b", app: "Pages", title: "Essay")
        XCTAssertEqual(ss, 402); XCTAssertEqual(s, missing)
        let (fs, f) = await b.handle(.frame, body: obj(["block_id": .string("b"), "goal": .string("x"),
                                                        "image_jpeg_b64": .string(jpeg), "at": .number(t0)]))
        XCTAssertEqual(fs, 402); XCTAssertEqual(f, missing)
        let (_, now) = await b.handle(.now, body: nil)
        XCTAssertEqual(now["typesafe"], .string("missing"))
        XCTAssertEqual(apis.typesafeCalls, 0)
        XCTAssertEqual(apis.anthropicCalls, 0)
    }

    // MARK: TypeSafe only

    func testTypeSafeAloneStillJudgesAndScores() async throws {
        let apis = FakeAPIs(), clock = Clock(t0)
        let b = brain(apis, clock, anthropic: "")
        let (_, goal) = await b.handle(.goal, body: obj(["text": .string("write the essay intro"),
                                                         "previous_goal": .string(""), "previous_understood": .string(""),
                                                         "at": .number(t0)]))
        XCTAssertEqual(goal["status"], .string("ok"))
        XCTAssertEqual(goal["specific_goal"], .string("write the essay intro"))
        XCTAssertEqual(goal["rubric"]?["balance"]?["focus"], .number(0.5), "the fallback rubric")
        XCTAssertEqual(goal["related"], .object([:]))

        let block = "solo"
        _ = await b.handle(.event, body: obj(["kind": .string("block_started"), "block_id": .string(block),
                                              "goal": .string("write the essay intro"), "at": .number(t0)]))
        var nudged = false
        for t in 0..<40 { await sense(b, clock, Double(t), block: block, app: "Pages", title: "Essay draft") }
        for t in 40..<70 {
            let (s, r) = await sense(b, clock, Double(t), block: block, app: "Safari", title: "Feed",
                                     url: "https://feed.example.com/")
            XCTAssertEqual(s, 200)
            if !r.str("nudge").isEmpty { nudged = true }
        }
        XCTAssertTrue(nudged, "without a second opinion the nudge goes straight out")
        clock.set(t0 + 70)
        let (bs, scored) = await b.handle(.block, body: obj([
            "block_id": .string(block), "goal": .string("write the essay intro"), "understood": .string(""),
            "started_at": .number(t0), "ended_at": .number(t0 + 70), "planned_s": .number(70),
            "completed": .bool(true), "active_s": .number(60), "switches": .number(2), "apps": .array([]),
            "frames": .array([])]))
        XCTAssertEqual(bs, 200)
        XCTAssertNotNil(BlockResult.parse(scored))
        XCTAssertNil(scored["balance"], "no rubric in force: scored the usual way")
        await b.settle()
        XCTAssertEqual(apis.anthropicCalls, 0)
        let (_, hist) = await b.handle(.history, body: nil)
        XCTAssertEqual(FocusHistory.parse(hist).first?.blocks, 1)
        XCTAssertEqual(b.health["second_opinion_calls"], .number(0))
    }

    // MARK: Restart

    func testANewBrainOnTheSameStoreSeesHistoryAndTheRunningBlock() async throws {
        let apis = FakeAPIs(), clock = Clock(t0)
        do {
            let b = brain(apis, clock, anthropic: "")
            _ = await b.handle(.goal, body: obj(["text": .string("write the essay intro"), "previous_goal": .string(""),
                                                 "previous_understood": .string(""), "at": .number(t0)]))
            _ = await b.handle(.event, body: obj(["kind": .string("block_started"), "block_id": .string("a"),
                                                  "goal": .string("write the essay intro"), "at": .number(t0)]))
            for t in 0..<30 { await sense(b, clock, Double(t), block: "a", app: "Pages", title: "Essay draft") }
            clock.set(t0 + 30)
            _ = await b.handle(.block, body: obj(["block_id": .string("a"), "goal": .string("write the essay intro"),
                                                  "understood": .string(""), "started_at": .number(t0),
                                                  "ended_at": .number(t0 + 30), "planned_s": .number(30),
                                                  "completed": .bool(true), "active_s": .number(30),
                                                  "switches": .number(0), "apps": .array([]), "frames": .array([])]))
            // The next block starts and runs a minute.
            clock.set(t0 + 100)
            _ = await b.handle(.event, body: obj(["kind": .string("block_started"), "block_id": .string("b"),
                                                  "goal": .string("write the essay intro"), "at": .number(t0 + 100),
                                                  "planned_s": .number(1500)]))
            clock.set(t0 + 160)
            _ = await b.handle(.tick, body: obj(["block_id": .string("b"), "goal": .string("write the essay intro"),
                                                 "at": .number(t0 + 160), "phase": .string("work"),
                                                 "planned_s": .number(1500)]))
        }
        clock.set(t0 + 200)
        let fresh = brain(apis, clock, anthropic: "")
        let (_, now) = await fresh.handle(.now, body: nil)
        XCTAssertEqual(now["active"], .bool(true))
        XCTAssertEqual(now["phase"], .string("work"))
        XCTAssertEqual(now["goal"], .string(Scoring.goalLabel("write the essay intro")))
        XCTAssertEqual(now["block_ends_at"], .number(t0 + 100 + 1500))
        XCTAssertEqual(now["today"]?["blocks"], .number(1))
        let (_, hist) = await fresh.handle(.history, body: nil)
        XCTAssertEqual(FocusHistory.parse(hist).first?.blocks, 1)
        // The stored block answers a retry exactly as before.
        let (s, again) = await fresh.handle(.block, body: obj(["block_id": .string("a")]))
        XCTAssertEqual(s, 200)
        XCTAssertNotNil(BlockResult.parse(again))
    }

    // MARK: Settings

    func testSettingsCheckTheKeyButNeverKeepIt() async {
        let apis = FakeAPIs(), clock = Clock(t0)
        let b = brain(apis, clock)
        let (s1, ok) = await b.handle(.settings, body: obj(["typesafe_key": .string("ts_new_key_456")]))
        XCTAssertEqual(s1, 200)
        XCTAssertEqual(ok, .object(["ok": .bool(true), "typesafe": .string("ok")]))
        let (_, bad) = await b.handle(.settings, body: obj(["typesafe_key": .string("bad")]))
        XCTAssertEqual(bad["typesafe"], .string("invalid"))
        let (s2, hours) = await b.handle(.settings, body: obj(["daily_hours_goal": .number(6)]))
        XCTAssertEqual(s2, 200)
        XCTAssertEqual(hours["daily_hours_goal"], .number(6))
        let (s3, _) = await b.handle(.settings, body: obj(["daily_hours_goal": .number(40)]))
        XCTAssertEqual(s3, 400)
        let (_, got) = await b.handle(.settings, body: nil)
        XCTAssertEqual(got["daily_hours_goal"], .number(6))
        XCTAssertEqual(got["typesafe"], .string("ok"))
        XCTAssertFalse(everyFileText().contains("ts_new_key_456"))
    }
}
