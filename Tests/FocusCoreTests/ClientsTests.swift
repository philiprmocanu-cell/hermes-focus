import XCTest
@testable import FocusCore

/// The TypeSafe and Anthropic clients, built and read without the network: a stub transport records every
/// request and plays back canned replies. No test here ever reaches a real API.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<HTTPReply, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Result<HTTPReply, Error>]) { self.replies = replies }
    convenience init(json: [String]) { self.init(json.map { .success(HTTPReply(status: 200, body: Data($0.utf8))) }) }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        let next: Result<HTTPReply, Error> = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .failure(URLError(.notConnectedToInternet)) : replies.removeFirst()
        }
        return try next.get()
    }

    var bodies: [JSONValue] { requests.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } }
}

private func reply(_ status: Int, _ body: String) -> Result<HTTPReply, Error> { .success(HTTPReply(status: status, body: Data(body.utf8))) }

private func claudeText(_ text: String, stop: String = "end_turn") -> String {
    let t = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    return "{\"content\": [{\"type\": \"text\", \"text\": \(t)}], \"stop_reason\": \"\(stop)\", " +
        "\"usage\": {\"input_tokens\": 120, \"output_tokens\": 30}}"
}

final class TypeSafeClientTests: XCTestCase {
    let state: JSONValue = .object(["goal": .string("HIST 2 paper"),
                                    "screen_now": .object(["app": .string("Pages"), "screenshot": .string("img1")])])
    let questions: JSONValue = .object(["on_goal": .object(["type": .string("noul"), "instructions": .string("?")])])

    func testTheRequestIsTheServersRequest() throws {
        let req = TypeSafeRequest.build(key: "ts_live_abc123", state: state, questions: questions)
        XCTAssertEqual(req.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ts_live_abc123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"))
        XCTAssertEqual(req.timeoutInterval, 4)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(req.httpBody))
        XCTAssertEqual(body, .object(["model": .string("jev-latest"), "state": state, "questions": questions]))
    }

    func testAScreenshotRidesAsAnAssetBehindTheImagesHeader() throws {
        let assets = TypeSafeRequest.imageAsset(jpegBase64: "/9j/AAA", ref: "img1")
        XCTAssertEqual(assets, .object(["img1": .object(["type": .string("image"), "format": .string("jpg"),
                                                         "data_base64": .string("/9j/AAA")])]))
        let req = TypeSafeRequest.build(key: "k", state: state, questions: questions, assets: assets)
        XCTAssertEqual(req.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(req.httpBody))
        XCTAssertEqual(body["assets"], assets)
        XCTAssertTrue(String(decoding: req.httpBody!, as: UTF8.self).contains("\"data_base64\":\"/9j/AAA\""))
    }

    func testAnswersAndUsage() async {
        let stub = StubTransport(json: ["{\"answers\": {\"on_goal\": {\"type\": \"noul\", \"noul\": 0.9}}, " +
                                        "\"usage\": {\"input_tokens\": 900, \"output_tokens\": 12}}"])
        let out = await TypeSafeClient(key: "k", transport: stub).systemOne(state: state, questions: questions)
        XCTAssertEqual(out?.answers["on_goal"]?["noul"], .number(0.9))
        XCTAssertEqual(out?.inputTokens, 900)
        XCTAssertEqual(out?.tokens, 912)
    }

    func testFailuresAreNoVerdictNeverAThrow() async {
        let stub = StubTransport([reply(401, "{\"error\": \"bad key\"}"), reply(200, "{\"usage\": {}}"),
                                  reply(200, "not json")])
        let c = TypeSafeClient(key: "k", transport: stub)
        for _ in 0..<4 { let out = await c.systemOne(state: state, questions: questions); XCTAssertNil(out) }   // 4th: offline
        let none = StubTransport([])
        let noKey = await TypeSafeClient(key: "", transport: none).systemOne(state: state, questions: questions)
        XCTAssertNil(noKey)
        XCTAssertTrue(none.requests.isEmpty)
    }

    func testAFailedImageCallIsJudgedFromTheTextAlone() async throws {
        let stub = StubTransport([reply(500, "oops"), reply(200, "{\"answers\": {}}")])
        let out = await TypeSafeClient(key: "k", transport: stub).judge(state: state, questions: questions,
                                                                         jpegBase64: "/9j/AAA", ref: "img1")
        XCTAssertNotNil(out.reply)
        XCTAssertFalse(out.usedImage)
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
        XCTAssertNil(stub.requests[1].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"))
        XCTAssertNil(stub.bodies[1]["assets"])
        XCTAssertNil(stub.bodies[1]["state"]?["screen_now"]?["screenshot"])
        XCTAssertEqual(stub.bodies[1]["state"]?["screen_now"]?["app"], .string("Pages"))
    }

    func testVerifyKeyIsOneTinyCall() async throws {
        let stub = StubTransport(json: ["{\"answers\": {\"ok\": {\"type\": \"noul\", \"noul\": 1}}}"])
        let ok = await TypeSafeClient.verifyKey("  ts_live_abcdef12 ", transport: stub)
        XCTAssertTrue(ok)
        let req = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(req.timeoutInterval, 6)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ts_live_abcdef12")
        XCTAssertEqual(stub.bodies[0], .object([
            "model": .string("jev-latest"),
            "state": .object(["check": .string("Is this a key check? Answer yes.")]),
            "questions": .object(["ok": .object(["type": .string("noul"), "instructions": .string("Answer yes.")])])]))
        let refused = StubTransport([reply(401, "{}")])
        let no = await TypeSafeClient.verifyKey("ts_live_abcdef12", transport: refused)
        XCTAssertFalse(no)
        let none = StubTransport([])
        for bad in ["short", "has a space inside", String(repeating: "k", count: 301)] {
            let v = await TypeSafeClient.verifyKey(bad, transport: none)
            XCTAssertFalse(v)
        }
        XCTAssertTrue(none.requests.isEmpty)
    }
}

final class AnthropicClientTests: XCTestCase {
    func testTheRequestShape() throws {
        let q = AnthropicCall.quickExtras(model: "claude-sonnet-5-5")
        let call = AnthropicCall(system: "SYS", user: "USER", jpegBase64: "/9j/AAA", model: "claude-sonnet-5-5",
                                 maxTokens: 300, timeout: 6, extra: q.extra, betas: q.betas)
        let req = AnthropicRequest.build(key: "sk-ant-test", call: call)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(req.timeoutInterval, 6)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(req.httpBody))
        XCTAssertEqual(body["model"], .string("claude-sonnet-5-5"))
        XCTAssertEqual(body["max_tokens"], .number(300))
        XCTAssertEqual(body["system"], .string("SYS"))
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["thinking"], .object(["type": .string("between_tools")]))
        XCTAssertEqual(body["output_config"], .object(["effort": .string("low")]))
        XCTAssertEqual(body["fallbacks"], .string("default"))
        let content = try XCTUnwrap(body["messages"]?.arrayValue?.first?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0], .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string("/9j/AAA")])]))
        XCTAssertEqual(content[1], .object(["type": .string("text"), "text": .string("USER")]))
    }

    func testQuickExtrasPerModel() {
        XCTAssertNil(AnthropicCall.quickExtras(model: "claude-opus-5-5").extra["thinking"])
        XCTAssertEqual(AnthropicCall.quickExtras(model: "claude-opus-5-5").betas, "server-side-fallback-2026-07-01")
        let haiku = AnthropicCall.quickExtras(model: "claude-haiku-5-5")
        XCTAssertNil(haiku.extra["fallbacks"])
        XCTAssertEqual(haiku.betas, "")
        XCTAssertEqual(haiku.extra["output_config"], .object(["effort": .string("low")]))
        // Without a screenshot there is only the text block, and no beta header without fallbacks.
        let req = AnthropicRequest.build(key: "k", call: AnthropicCall(system: "s", user: "u", model: "claude-haiku-5-5"))
        XCTAssertNil(req.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testErrorsNeverCrash() async {
        let call = AnthropicCall(system: "s", user: "u")
        func run(_ r: [Result<HTTPReply, Error>], key: String = "k") async -> Result<AnthropicReply, AnthropicError> {
            await AnthropicClient(key: key, transport: StubTransport(r)).send(call)
        }
        let cases: [([Result<HTTPReply, Error>], String, AnthropicError)] = [
            ([], " ", .noKey),
            ([reply(200, claudeText("", stop: "refusal"))], "k", .refusal),
            ([reply(400, "{\"error\": {\"message\": \"Your credit balance is too low\"}}")], "k", .billing),
            ([reply(401, "{\"error\": \"invalid x-api-key\"}")], "k",
             .http(status: 401, detail: "{\"error\": \"invalid x-api-key\"}")),
            ([reply(529, "overloaded")], "k", .http(status: 529, detail: "overloaded")),
            ([], "k", .transport),
            ([reply(200, "<html>")], "k", .unreadable),
        ]
        for (replies, key, want) in cases {
            let got = await run(replies, key: key)
            XCTAssertEqual(got, .failure(want))
        }
        guard case .success(let ok) = await run([reply(200, claudeText("hi"))]) else { return XCTFail() }
        XCTAssertEqual(ok.text, "hi")
        XCTAssertEqual(ok.inputTokens, 120)
    }

    func testARejectedFallbackIsRetriedOnceWithoutIt() async {
        let stub = StubTransport([reply(400, "{\"error\": \"fallbacks: unknown field\"}"), reply(200, claudeText("{\"a\": 1}"))])
        let q = AnthropicCall.quickExtras(model: "claude-sonnet-5-5")
        let out = await AnthropicClient(key: "k", transport: stub)
            .json(AnthropicCall(system: "s", user: "u", extra: q.extra, betas: q.betas))
        XCTAssertEqual(out, .success(.object(["a": .number(1)])))
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertNil(stub.bodies[1]["fallbacks"])
        XCTAssertNil(stub.requests[1].value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual(stub.bodies[1]["thinking"], .object(["type": .string("between_tools")]))
    }

    func testTheRubricCall() async throws {
        let writer = "```json\n{\"kind\": \"reading\", \"balance\": {\"focus\": 0.9, \"output\": 0.1}, " +
            "\"milestones\": [], \"on_tells\": [\"Is he reading the chapter?\"], \"off_tells\": [], \"smart\": []}\n```"
        let stub = StubTransport([reply(200, claudeText(writer))])
        let prompt = RubricWriter.prompt(goal: "reading", specific: "Read ch 3", understood: "Reading")
        let r = await AnthropicClient(key: "k", transport: stub).writeRubric(prompt: prompt, note: "reading only")
        XCTAssertEqual(r.kind, .reading)
        XCTAssertEqual(r.onTells.map(\.id), ["t1"])
        XCTAssertEqual(r.note, "reading only")
        let req = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(req.timeoutInterval, 12)
        XCTAssertEqual(stub.bodies[0]["max_tokens"], .number(2500))
        XCTAssertEqual(stub.bodies[0]["system"], .string(RubricWriter.systemPrompt()))
        XCTAssertEqual(stub.bodies[0]["model"], .string("claude-sonnet-5-5"))
        // A timeout or refusal: the half-and-half fallback, and the block starts anyway.
        let failed = await AnthropicClient(key: "k", transport: StubTransport([])).writeRubric(prompt: prompt)
        XCTAssertTrue(failed.fallback)
        XCTAssertEqual(failed.balance, .init(focus: 0.5, output: 0.5))
    }
}

final class FocusPromptTests: XCTestCase {
    func testSecondOpinionPromptAndAnswer() async throws {
        let ctx = SecondOpinion.Context(
            goal: "Respond to Dana", specific: "Send the reply to Dana",
            related: .object(["people": .array([.string("Dana (pilot customer)"), .string("dana (pilot customer)")]),
                              "sites": .string("Gmail")]),
            story: "Gmail for 3 min", rows: [.init(at: 990, app: "Google Chrome", title: "Inbox", mode: "making",
                                                   onGoal: 0.2, confidence: 0.55),
                                             .init(at: nil, app: "", title: "", mode: "", onGoal: nil)],
            tellsText: "Leaning on task: chk_contact 0.92.", app: "Google Chrome", title: "Re: pilot",
            url: "https://mail.google.com", text: "  Hi   Dana,\n thanks ", now: 1000)
        let p = SecondOpinion.prompt(ctx, hasImage: false)
        XCTAssertEqual(p, """
            Goal: Respond to Dana
            Specific goal for this block: Send the reply to Dana
            What the goal involves: people: Dana (pilot customer); sites: Gmail
            The last minutes: Gmail for 3 min
            The fast judge's last seconds, oldest first:
            10 s ago: Google Chrome — Inbox (making, on goal 0.2, sure 0.55)
            0 s ago: ? (?, on goal None, sure None)
            Why the fast judge was torn on this second (its yes/no checks, probability of yes): Leaning on task: chk_contact 0.92.

            Screen now — app: Google Chrome
            Window title: Re: pilot
            URL: https://mail.google.com
            Visible text: Hi Dana, thanks
            (No screenshot this time.)

            Is he on task for this goal right now? yes/no + one sentence.
            """)
        let stub = StubTransport([reply(200, claudeText("{\"on_task\": \"Yes\", \"reason\": \"  Replying   to Dana. \"}"))])
        let v = await AnthropicClient(key: "k", transport: stub).secondOpinion(ctx, jpegBase64: "/9j/AAA")
        XCTAssertEqual(v, SecondOpinion.Verdict(onTask: true, reason: "Replying to Dana."))
        XCTAssertEqual(stub.requests[0].timeoutInterval, 6)
        XCTAssertEqual(stub.bodies[0]["max_tokens"], .number(300))
        XCTAssertEqual(stub.bodies[0]["system"], .string(SecondOpinion.system))
        XCTAssertFalse((stub.bodies[0]["messages"]?.arrayValue?[0]["content"]?.arrayValue?[1]["text"]?.stringValue ?? "")
            .contains("No screenshot"))
        XCTAssertNil(SecondOpinion.parse(.object(["on_task": .string("maybe")])))
        XCTAssertNil(SecondOpinion.parse(.object(["on_task": .bool(true)])))
    }

    func testBlockAdvicePrompt() async {
        let input = BlockAdvice.Input(
            goal: "HIST 2 paper", judgedGoal: "Draft the intro", originalGoal: "",
            frames: [.init(doing: "typing the intro", quality: 0.8, onGoal: 1.0, mode: "making"),
                     .init(note: "renaming files", pending: true, automatable: "a script could rename them")],
            stats: .init(minutes: 25, switches: 3, activeS: 1400, typingSeconds: 900, scrollingSeconds: 60,
                         distractionS: 0, eyes: [("reading", 0.6)], score: 812, focusScore: 900, outputScore: 700))
        XCTAssertEqual(BlockAdvice.prompt(input), """
            The goal he named: HIST 2 paper
            The specific goal this block was judged against: Draft the intro

            The screenshot verdicts, oldest first:
            - doing: typing the intro; quality 0.8; on_goal 1.0; making
            - doing: ?; note: renaming files; pending — it was waiting to be explained; could be automated: a script could rename them

            How the block went (seconds unless said otherwise):
            {"minutes": 25, "switches": 3.0, "active_s": 1400.0, "typing_seconds": 900, "scrolling_seconds": 60, "distraction_s": 0.0, "eyes": {"reading": 0.6}, "score": 812, "focus_score": 900, "output_score": 700}

            The last screenshot of the block is attached.
            """)
        XCTAssertEqual(BlockAdvice.systemPrompt(profile: "HOW HE WORKS"), BlockAdvice.system + "\n\nHOW HE WORKS")
        let stub = StubTransport([reply(200, claudeText("{\"advice\": \"Renaming by hand was repetitive.\"}"))])
        let text = await AnthropicClient(key: "k", transport: stub).blockAdvice(input, model: "claude-opus-5-5")
        XCTAssertEqual(text, "Renaming by hand was repetitive.")
        XCTAssertEqual(stub.bodies[0]["model"], .string("claude-opus-5-5"))
        XCTAssertNil(stub.bodies[0]["fallbacks"])            // app.py sends the advice call plain
        XCTAssertNil(BlockAdvice.parse(.object(["advice": .string("  ")])))
    }

    func testGoalStepPromptAndParse() async {
        let input = GoalStep.Input(text: "hist 2 paper", vague: "unknown", blockMinutes: 25,
                                   context: "Their focus blocks earlier today (what got done, what was left):\n- Outline")
        XCTAssertEqual(GoalStep.prompt(input), "What he typed: hist 2 paper\n" +
            "A quick check found none of these words in his context: ask, unless it clearly means something there.\n" +
            "This block is 25 minutes long.\n\nTheir focus blocks earlier today (what got done, what was left):\n- Outline")
        let same = GoalStep.Input(text: "same", sameAchieved: true, previousGoal: "HIST 2 paper",
                                  previousUnderstood: "Writing the HIST 2 paper", previousSpecific: "Draft the intro")
        XCTAssertTrue(GoalStep.prompt(same).hasPrefix("What he typed: same as the last block — \"Writing the HIST 2 paper\". " +
            "Its specific goal (\"Draft the intro\") was achieved: set the NEXT concrete chunk of the same goal\n"))
        XCTAssertTrue(GoalStep.prompt(same).hasSuffix("\n\n(no context available)"))
        XCTAssertTrue(GoalStep.system.contains("questions: up to 8 yes/no questions"))
        XCTAssertTrue(GoalStep.system.contains("related: what this block's work will plausibly touch"))

        let answer = """
            {"status": "ok", "goal": "HIST 2  paper", "understood": "Writing the HIST 2 reaction paper",
             "question": "", "specific_goal": "", "specificity": 1.4, "specificity_hint": "",
             "related": {"people": [], "projects": ["HIST 2"], "sites": ["Canvas", "canvas", "Pages"]},
             "questions": [{"id": "x", "text": "Is the paper open?", "means": "on-task"},
                           {"id": "q9", "text": "is the paper open?", "means": "on_task"},
                           {"id": "rub_on_t1", "text": "Is he typing in the paper?", "means": "on_task"},
                           {"id": "q3", "text": "Is he on YouTube?", "means": "off task"},
                           {"id": "q4", "text": "Bad means", "means": "maybe"}]}
            """
        let stub = StubTransport([reply(200, claudeText(answer))])
        guard case .success(let r) = await AnthropicClient(key: "k", transport: stub).goalStep(input) else { return XCTFail() }
        XCTAssertFalse(r.wantsClarify)
        XCTAssertEqual(r.goal, "HIST 2 paper")
        XCTAssertEqual(r.specificGoal, "Writing the HIST 2 reaction paper")     // empty → understood
        XCTAssertEqual(r.specificity, 1)
        XCTAssertEqual(r.related.map(\.key), ["projects", "sites"])
        XCTAssertEqual(r.related.last?.values, ["Canvas", "Pages"])
        XCTAssertEqual(r.questions, [.init(id: "q1", text: "Is the paper open?", means: "on_task"),
                                     .init(id: "rub_on_t1", text: "Is he typing in the paper?", means: "on_task"),
                                     .init(id: "q2", text: "Is he on YouTube?", means: "off_task")])
        XCTAssertEqual(stub.requests[0].timeoutInterval, 30)
        XCTAssertEqual(stub.bodies[0]["system"], .string(GoalStep.system))
        // A clarify answer and the hint rule.
        let clarify = GoalStep.parse(.object(["status": .string("CLARIFY"), "question": .string("Which paper?")]),
                                     input: input)
        XCTAssertTrue(clarify.wantsClarify)
        XCTAssertEqual(clarify.understood, "hist 2 paper")
        XCTAssertNil(clarify.specificity)
        XCTAssertEqual(GoalStep.hint(specificity: 0.8, said: "x"), "")
        XCTAssertEqual(GoalStep.hint(specificity: 0.3, said: "Name the output. Then more."), "Name the output.")
        XCTAssertEqual(GoalStep.hint(specificity: 0.3, said: ""), GoalStep.defaultHint)
    }
}
