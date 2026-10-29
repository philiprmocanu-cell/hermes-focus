import XCTest
@testable import FocusCore

// MARK: - Jev's judge, ported from brain/jev.py
//
// Two halves: parity with the Python (Tests/Fixtures/judge/*.json, written by
// scripts/fixtures_judge.py from brain.jev itself; floats within 1e-6, keys
// exact), and the pure assertions of tests/test_jev.py ported one for one.

private typealias D = Judge.Dict

// MARK: Fixture plumbing

private func fixture(_ name: String) throws -> JSONValue {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/judge/\(name)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

/// Differences between two JSON values: keys exact, numbers within 1e-6.
private func diff(_ a: JSONValue?, _ b: JSONValue?, _ path: String = "$") -> [String] {
    switch (a ?? .null, b ?? .null) {
    case (.number(let x), .number(let y)):
        return abs(x - y) <= 1e-6 ? [] : ["\(path): \(x) != \(y)"]
    case (.object(let x), .object(let y)):
        var out: [String] = []
        for k in Set(x.keys).union(y.keys).sorted() {
            if x[k] == nil { out.append("\(path).\(k): missing in Swift"); continue }
            if y[k] == nil { out.append("\(path).\(k): extra in Swift"); continue }
            out += diff(x[k], y[k], "\(path).\(k)")
        }
        return out
    case (.array(let x), .array(let y)):
        if x.count != y.count { return ["\(path): \(x.count) items != \(y.count)"] }
        return zip(x, y).enumerated().flatMap { diff($1.0, $1.1, "\(path)[\($0)]") }
    case let (x, y):
        return x == y ? [] : ["\(path): \(x) != \(y)"]
    }
}

private func assertSame(_ swift: JSONValue?, _ python: JSONValue?, _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) {
    let d = diff(swift, python)
    XCTAssert(d.isEmpty, "\(what): " + d.prefix(8).joined(separator: "; "), file: file, line: line)
}

private func obj(_ d: D?) -> JSONValue { d.map { .object($0) } ?? .null }
private func dicts(_ v: JSONValue?) -> [D] { (v?.arrayValue ?? []).compactMap { if case .object(let o) = $0 { return o }; return nil } }
private func dct(_ v: JSONValue?) -> D { if case .object(let o)? = v { return o }; return [:] }
private func strs(_ v: JSONValue?) -> [String]? { v?.arrayValue.map { $0.compactMap(\.stringValue) } }
private func num(_ v: JSONValue?) -> Double { v?.doubleValue ?? 0 }

final class JudgeParityTests: XCTestCase {
    func testBuildStateOnSixScreens() throws {
        let f = try fixture("state.json")
        let cases = f["cases"]?.arrayValue ?? []
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let a = dct(c["args"])
            let name = c.str("name")
            let st = Judge.buildState(
                goal: a.str("goal"), specific: a.str("specific"), understood: a.str("understood"),
                progressSoFar: num(a["progress_so_far"]), screen: dct(a["screen"]), change: dct(a["change"]),
                recent: dicts(a["recent"]), story: a.raw("story"), related: a["related"],
                rulings: strs(a["rulings"]), imageRef: a.raw("image_ref"), site: a.raw("site"),
                siteS: num(a["site_s"]), rules: strs(a["rules"]), profile: a.raw("profile"),
                goalQuestions: a["goal_questions"], today: a.raw("today"), milestones: a["milestones"])
            assertSame(.object(st), c["out"], "build_state \(name)")
            assertSame(.object(Judge.withoutImage(st)), c["without_image"], "without_image \(name)")
        }
        let img = try XCTUnwrap(f["image_asset"])
        assertSame(.object(Judge.imageAsset(img.str("jpeg_b64"), ref: img.str("ref"))), img["out"], "image_asset")
        XCTAssertEqual(strs(f["image_header"]), [Judge.imageHeader.name, Judge.imageHeader.value])
        XCTAssertEqual(f.str("model"), Judge.model)
    }

    func testTwelveAnswerSetsThroughThePipeline() throws {
        let f = try fixture("answers.json")
        let cases = f["cases"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for c in cases {
            let name = c.str("name")
            let answers = c["answers"]
            let parsed = Judge.parseAnswers(answers, goalQuestions: c["goal_questions"], rubric: c["rubric"])
            assertSame(obj(parsed), c["parsed"], "parse_answers \(name)")
            assertSame(.object(Judge.combineChecks(answers, answers?["on_goal"])), c["combined"], "combine_checks \(name)")
            guard let v = parsed else { XCTFail("no verdict \(name)"); continue }
            let screen = dct(c["screen"])
            let at = num(c["at"])
            let row = Judge.verdictRow(v, screen: screen, at: at)
            assertSame(.object(row), c["row"], "verdict_row \(name)")
            let settle = dct(c["settle"])
            let ruled = settle["ruling"].map { Judge.exceptionMatches($0, screen) } ?? false
            XCTAssertEqual(ruled, c["ruled"]?.boolValue, "ruled \(name)")
            let settled = Judge.settleRow(row, site: settle.raw("site"), siteS: num(settle["site_s"]), ruled: ruled,
                                          away: settle["away"]?.boolValue ?? false)
            assertSame(.object(settled), c["settled"], "settle_row \(name)")
            XCTAssertEqual(Judge.rowRelated(settled), c["related"]?.boolValue, "row_related \(name)")
            XCTAssertEqual(Judge.rowOffTask(settled), c["off_task"]?.boolValue, "row_off_task \(name)")
            XCTAssertEqual(Judge.escalate(settled), c["escalate"]?.boolValue, "escalate \(name)")
            XCTAssertEqual(Judge.tellsText(settled), c.raw("tells_text"), "tells_text \(name)")
            let label = Judge.labelRow(at: at, user: "owner", blockId: "b1", goal: "Send response to Dana",
                                       specific: "Reply sent", screen: screen, text: "secret visible words",
                                       row: settled, label: "on_task", source: "button")
            assertSame(.object(label), c["label_row"], "label_row \(name)")
        }
        let extra = try XCTUnwrap(f["extra"])
        XCTAssertEqual(extra["parse_junk"], .bool(Judge.parseAnswers(.string("junk")) == nil))
        XCTAssertEqual(extra["parse_missing_on_goal"], .null)
        assertSame(.object(Judge.combineChecks(.object(["chk_making": .object(["noul": .number(0.9)])]), nil)),
                   extra["combine_none_score"], "combine with no score")
        for e in extra["escalate"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.escalate(dct(e["row"])), e["out"]?.boolValue, "\(e)")
        }
        for t in extra["tells_text"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.tellsText(dct(t["row"])), t.raw("out"))
        }
    }

    func testNudgesMinuteFramesAndThrottle() throws {
        let f = try fixture("nudge.json")
        for s in f["sequences"]?.arrayValue ?? [] {
            let name = s.str("name")
            let rows = dicts(s["rows"])
            XCTAssertEqual(Judge.offTaskRun(rows, now: num(s["now"])), s["off_task_run"]?.boolValue, "run \(name)")
            XCTAssertEqual(Judge.nudgeDue(rows, now: num(s["now"]), blockStarted: num(s["block_started"]),
                                          lastNudgeAt: num(s["last_nudge_at"]), gapS: num(s["gap_s"])),
                           s["nudge_due"]?.boolValue, "nudge \(name)")
            XCTAssertEqual(rows.map { Judge.rowOffTask($0) }, s["off_task"]?.arrayValue?.compactMap(\.boolValue), name)
            XCTAssertEqual(rows.map { Judge.rowRelated($0) }, s["related"]?.arrayValue?.compactMap(\.boolValue), name)
        }
        for fr in f["frames"]?.arrayValue ?? [] {
            let out = Judge.minuteFrame(dicts(fr["rows"]), screen: dct(fr["screen"]), at: num(fr["at"]))
            assertSame(obj(out), fr["out"], "minute_frame \(fr.str("name"))")
        }
        for t in f["throttle"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.throttle(changed: t["changed"]?.boolValue ?? false, lastCallAt: num(t["last"]),
                                          now: num(t["now"])), t["out"]?.boolValue)
        }
    }

    func testStoryAndTrail() throws {
        let f = try fixture("story.json")
        for c in f["cases"]?.arrayValue ?? [] {
            var trail: [D] = []
            for op in c["ops"]?.arrayValue ?? [] {
                let o = op.arrayValue ?? []
                trail = Judge.trailAdd(trail, screen: dct(o[0]), mode: o[1].stringValue ?? "", now: num(o[2]))
            }
            assertSame(.array(trail.map { .object($0) }), c["trail"], "trail_add \(c.str("name"))")
            XCTAssertEqual(Judge.storyLine(trail, now: num(c["now"])), c.raw("story"), c.str("name"))
            XCTAssertEqual(Judge.storyLine(dicts(c["trail"]), now: num(c["now"])), c.raw("story"), c.str("name"))
        }
        for s in f["spans"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.span(num(s["s"])), s.raw("out"), "\(s)")
        }
    }

    func testTables() throws {
        let f = try fixture("tables.json")
        for c in f["search_words"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.searchWords(c.raw("url")), c.raw("out"), c.raw("url"))
        }
        for c in f["distraction_site"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.distractionSite(c.raw("url"), app: c.raw("app"), goal: c.raw("goal")), c.raw("out"),
                           "\(c)")
        }
        for c in f["picture_app"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.pictureApp(c.raw("app"), c.raw("url")), c["out"]?.boolValue, "\(c)")
        }
        for c in f["reading_material"]?.arrayValue ?? [] {
            let screen = dct(c["screen"]), n = Int(num(c["text_len"]))
            XCTAssertEqual(Judge.readingMaterial(screen, textLen: n), c["out"]?.boolValue, "\(c)")
            XCTAssertEqual(Double(Judge.idleLimit(screen, textLen: n)), c["idle_limit"]?.doubleValue)
            XCTAssertEqual(Double(Judge.idleLimit(screen, textLen: n, studying: true)), c["idle_limit_studying"]?.doubleValue)
        }
        for c in f["is_away"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.isAway(c["idle_s"], dct(c["screen"]), textLen: Int(num(c["text_len"])),
                                        studying: c["studying"]?.boolValue ?? false), c["out"]?.boolValue, "\(c)")
        }
        for c in f["text_digest"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.textDigest(c.raw("text")), c.raw("out"))
        }
        for c in f["related_terms"]?.arrayValue ?? [] {
            assertSame(.object(Judge.relatedTerms(c["related"])), c["out"], "related_terms \(c)")
        }
        let exc = f["exceptions"]?.arrayValue ?? []
        let screens = exc.prefix(7).map { dct($0["screen"]) }
        for c in exc {
            let made = Judge.exceptionFrom(dct(c["screen"]), at: 1_790_000_000, by: c.raw("by"))
            assertSame(.object(made), c["exc"], "exception_from")
            XCTAssertEqual(screens.map { Judge.exceptionMatches(.object(made), $0) },
                           c["matches"]?.arrayValue?.compactMap(\.boolValue), "\(c)")
        }
        for c in f["exception_junk"]?.arrayValue ?? [] {
            XCTAssertEqual(Judge.exceptionMatches(c["exc"], screens[0]), c["out"]?.boolValue, "\(c)")
        }
        for c in f["goal_questions_clean"]?.arrayValue ?? [] {
            assertSame(.array(Judge.goalQuestionsClean(c["raw"]).map(\.json)), c["out"], "goal_questions_clean")
        }
        for c in f["today_line"]?.arrayValue ?? [] {
            let goals = (c["goals"]?.arrayValue ?? []).map(\.stringValue)
            let evs = (c["events"]?.arrayValue ?? []).map { e -> (clock: String, title: String?) in
                let p = e.arrayValue ?? []
                return (p[0].stringValue ?? "", p[1].stringValue)
            }
            XCTAssertEqual(Judge.todayLine(goals, evs), c.raw("out"))
        }
    }

    func testQuestionsChecksAndConstants() throws {
        let f = try fixture("questions.json")
        assertSame(.object(Judge.questions), f["QUESTIONS"], "QUESTIONS")
        assertSame(.object(Judge.checkQuestions), f["CHECK_QUESTIONS"], "CHECK_QUESTIONS")
        assertSame(.array(Judge.generalChecks.map(\.json)), f["GENERAL_CHECKS"], "GENERAL_CHECKS")
        XCTAssertEqual(strs(f["CHECK_IDS"]), Judge.checkIds)
        XCTAssertEqual(strs(f["STANDING_RULES"]), Judge.standingRules)
        assertSame(Judge.activity, f["ACTIVITY"], "ACTIVITY")
        assertSame(.array(Judge.checksListing()), f["checks_listing"], "checks_listing")
        for key in ["questions_for_gq", "questions_for_rubric", "questions_for_empty"] {
            let c = try XCTUnwrap(f[key])
            let qs = Judge.questionsFor(c["goal_questions"] ?? .array([]), rubric: c["rubric"])
            assertSame(.object(qs), c["out"], key)
            XCTAssertEqual(Double(Judge.questionTokens(qs)), c["tokens"]?.doubleValue, key)
        }
        let ga = try XCTUnwrap(f["goal_answers"])
        let gq = f["questions_for_gq"]?["goal_questions"]
        let (on, off) = Judge.goalAnswers(ga["answers"], gq)
        XCTAssertEqual([on, off], ga["out"]?.arrayValue?.map { strs($0) ?? [] })
        let k = dct(f["constants"])
        let mine: [String: JSONValue] = [
            "MAX_TEXT_CHARS": .number(Double(Judge.maxTextChars)), "RECENT_ROWS": .number(Double(Judge.recentRows)),
            "IMAGE_FRESH_S": .number(Judge.imageFreshS), "OFF_TASK_S": .number(Judge.offTaskS),
            "OFF_TASK_GAP_S": .number(Judge.offTaskGapS), "OFF_TASK_ON_GOAL": .number(Judge.offTaskOnGoal),
            "OFF_TASK_CONFIDENCE": .number(Judge.offTaskConfidence), "RELATED": .number(Judge.related),
            "STEP": .number(Judge.step), "STEP_ON_GOAL": .number(Judge.stepOnGoal),
            "DISTRACTION_S": .number(Judge.distractionS), "DISTRACTION_ON_GOAL": .number(Judge.distractionOnGoal),
            "NUDGE_GRACE_S": .number(Judge.nudgeGraceS), "IDLE_S": .number(Double(Judge.idleS)),
            "READING_IDLE_S": .number(Double(Judge.readingIdleS)), "HEARTBEAT_S": .number(Judge.heartbeatS),
            "MINUTE_S": .number(Judge.minuteS), "MINUTE_MIN_ROWS": .number(Double(Judge.minuteMinRows)),
            "PROGRESS_CONFIDENCE": .number(Judge.progressConfidence), "STORY_WINDOW_S": .number(Judge.storyWindowS),
            "STORY_MAX_CHARS": .number(Double(Judge.storyMaxChars)), "STORY_MIN_S": .number(Judge.storyMinS),
            "GOAL_Q_PREFIX": .string(Judge.goalQPrefix), "GOAL_Q_MAX": .number(Double(Judge.goalQMax)),
            "GOAL_Q_RUBRIC_MAX": .number(Double(Judge.goalQRubricMax)),
            "GOAL_Q_MAX_CHARS": .number(Double(Judge.goalQMaxChars)), "GOAL_TELL": .number(Judge.goalTell),
            "GOAL_OFF_ON_GOAL": .number(Judge.goalOffOnGoal), "TODAY_MAX_CHARS": .number(Double(Judge.todayMaxChars)),
            "LONG_TEXT": .number(Double(Judge.longText)), "CHECK_PREFIX": .string(Judge.checkPrefix),
            "CHECK_TELL": .number(Judge.checkTell), "CHECK_CAP": .number(Judge.checkCap),
            "CHECK_CAP_TO": .number(Judge.checkCapTo), "CHECK_FLOOR": .number(Judge.checkFloor),
            "CHECK_BLEND": .number(Judge.checkBlend), "CHECK_MAX_CHARS": .number(Double(Judge.checkMaxChars)),
            "ESCALATE_CONFIDENCE": .number(Judge.escalateConfidence), "ESCALATE_LOW": .number(Judge.escalateLow),
            "ESCALATE_HIGH": .number(Judge.escalateHigh), "TELLS_SHOWN": .number(Double(Judge.tellsShown)),
            "MODEL": .string(Judge.model)]
        assertSame(.object(mine), .object(k), "constants")
    }

    func testFixtureCount() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/judge")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(Set(files), ["state.json", "answers.json", "nudge.json", "story.json", "tables.json",
                                     "questions.json"])
    }
}

private extension JSONValue {
    /// The string exactly (no trimming), "" when missing.
    func raw(_ key: String) -> String { self[key]?.stringValue ?? "" }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func str(_ key: String) -> String { (self[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func raw(_ key: String) -> String { self[key]?.stringValue ?? "" }
}

// MARK: - tests/test_jev.py, the pure assertions

private let T0 = 1_790_000_000.0

private func answers(onGoal: Int = 3, activity: String = "making", conf: Double = 0.9, serves: Double = 0.05,
                     step: Double = 0.05, progress: Int = 2, working: Int = 3, producing: Int = 3,
                     quality: Int = 2, smart: Int = 2) -> D {
    func score(_ level: Int, _ n: Int) -> JSONValue {
        var probs: D = [:]
        for i in 0..<n { probs[String(i)] = .number(0.02) }
        probs[String(level)] = .number(1 - 0.02 * Double(n - 1))
        return .object(["type": .string("score"), "score": .number(Double(level) / Double(n - 1)),
                        "probabilities": .object(probs), "confidence": .number(conf)])
    }
    var on = score(onGoal, 4)
    if conf < 0.6, case .object(var o) = on {
        o["probabilities"] = .object(["0": .number(0.25), "1": .number(0.25), "2": .number(0.25), "3": .number(0.25)])
        on = .object(o)
    }
    var act: D = [:]
    for k in Judge.activityKeys { act[k] = .number(0.02) }
    act[activity] = .number(1 - 0.02 * Double(Judge.activityKeys.count - 1))
    return ["activity": .object(["type": .string("choice"), "choice": .string(activity), "probabilities": .object(act),
                                 "confidence": .number(conf)]),
            "on_goal": on, "working": score(working, 4), "producing": score(producing, 4),
            "quality": score(quality, 4), "smart": score(smart, 4), "progress": score(progress, 5),
            "serves_goal": .object(["type": .string("noul"), "noul": .number(serves)]),
            "step_toward_goal": .object(["type": .string("noul"), "noul": .number(step)])]
}

private func offAnswers(step: Double = 0.05) -> D {
    answers(onGoal: 0, activity: "consuming", step: step, working: 0, producing: 0, quality: 0)
}

private func noul(_ p: Double) -> JSONValue { .object(["type": .string("noul"), "noul": .number(p)]) }

private func checks(_ ps: [String: Double] = [:], low: Double = 0) -> D {
    var out: D = [:]
    for c in Judge.generalChecks { out[Judge.checkPrefix + c.id] = noul(ps[c.id] ?? low) }
    return out
}

private func scoreAnswer(_ level: Int? = nil, probs: [String: Double]? = nil, conf: Double = 0.9) -> JSONValue {
    let p = probs ?? Dictionary(uniqueKeysWithValues: (0..<4).map { (String($0), $0 == level ? 1.0 : 0.0) })
    return .object(["type": .string("score"), "probabilities": .object(p.mapValues { .number($0) }),
                    "confidence": .number(conf)])
}

private let SCREEN: D = ["app": .string("Xcode"), "title": .string("OnboardingView.swift — Acme"), "url": .string(""),
                         "text": .string("struct OnboardingView")]

private let GQ: JSONValue = .array([
    .object(["id": .string("x"), "text": .string("Is the screen a Gmail thread with Dana or anyone at Acme about the response?"),
             "means": .string("on_task")]),
    .object(["text": .string("Is it a Loom recording for Dana?"), "means": .string("on-task")]),
    .object(["text": .string("Is he watching a YouTube video unrelated to Acme?"), "means": .string("off_task")]),
    .object(["text": .string("no meaning given")]),
    .object(["text": .string("Is it a Loom recording for Dana?"), "means": .string("on_task")]),
])

private func row(_ at: Double, _ over: D = [:]) -> D {
    var r: D = ["at": .number(at), "on_goal": .number(0.05), "confidence": .number(0.9), "mode": .string("consuming")]
    r.merge(over) { $1 }
    return r
}

private func d(_ v: JSONValue?) -> Double { v?.doubleValue ?? .nan }
private func parse(_ a: D, _ gq: JSONValue? = nil) -> D { Judge.parseAnswers(.object(a), goalQuestions: gq)! }
private func merged(_ a: D, _ b: D) -> D { a.merging(b) { $1 } }

final class JudgePortedTests: XCTestCase {
    // ParseTests
    func testScoresAreExpectationsOverLevels() {
        let v = parse(answers(onGoal: 3, progress: 4))
        XCTAssertGreaterThan(d(v["on_goal"]), 0.95)
        XCTAssertGreaterThanOrEqual(d(v["progress"]), 0.95)
        XCTAssertEqual(v["mode"], .string("making"))
        XCTAssertGreaterThanOrEqual(d(v["confidence"]), 0.9)
    }

    func testConfidenceIsAboutOnVersusOffNotTheExactLevel() {
        var a = answers()
        var on = a["on_goal"]!
        if case .object(var o) = on {
            o["probabilities"] = .object(["0": .number(0.02), "1": .number(0.03), "2": .number(0.5), "3": .number(0.45)])
            on = .object(o)
        }
        a["on_goal"] = on
        let v = parse(a)
        XCTAssertEqual(d(v["p_on_task"]), 0.95, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(d(v["confidence"]), 0.9)
        if case .object(var o) = on {
            o["probabilities"] = .object(["0": .number(0.25), "1": .number(0.25), "2": .number(0.25), "3": .number(0.25)])
            a["on_goal"] = .object(o)
        }
        XCTAssertEqual(d(parse(a)["confidence"]), 0, accuracy: 1e-9)
    }

    func testMissingOnGoalMeansNoVerdict() {
        var a = answers()
        a["on_goal"] = nil
        XCTAssertNil(Judge.parseAnswers(.object(a)))
        XCTAssertNil(Judge.parseAnswers(.string("junk")))
    }

    func testStaticChoiceIsModeOtherAndFlagged() {
        let v = parse(answers(onGoal: 0, activity: "static"))
        XCTAssertEqual(v["mode"], .string("other"))
        XCTAssertEqual(v["static"], .bool(true))
    }

    func testTheStepQuestionIsRead() {
        XCTAssertEqual(d(parse(answers(step: 0.8))["step"]), 0.8, accuracy: 1e-9)
    }

    func testRowHasTheScreenshotJudgeShape() {
        let r = Judge.verdictRow(parse(answers()), screen: SCREEN, at: T0)
        for k in ["on_goal", "working", "quality", "producing", "progress", "smart", "mode", "doing",
                  "serves_goal", "evidence", "at", "app", "url", "step"] {
            XCTAssertNotNil(r[k], k)
        }
        XCTAssertEqual(r["judge"], .string("jev"))
    }

    // QuestionTests
    func testStrictCoachOnlyForQualityAndSmart() {
        for (k, q) in Judge.questions {
            let has = (q["instructions"]?.stringValue ?? "").contains("most productive people alive")
            XCTAssertEqual(has, ["quality", "smart"].contains(k), k)
        }
        XCTAssertFalse(Judge.standingRules.joined(separator: " ").contains("most productive"))
    }

    func testNoLookQuestionAndAStepQuestion() {
        XCTAssertNil(Judge.questions["needs_look"])
        XCTAssertNotNil(Judge.questions["step_toward_goal"])
        XCTAssertTrue(Judge.questions["step_toward_goal"]!.str("instructions").contains("story_so_far"))
        XCTAssertTrue(Judge.questions["serves_goal"]!.str("instructions").contains("goal.related.people"))
    }

    // SiteTests
    func testTheObviousDistractions() {
        let cases = ["https://www.instagram.com/": "Instagram", "https://www.tiktok.com/foryou": "TikTok",
                     "https://www.youtube.com/shorts/abc": "YouTube Shorts",
                     "https://www.youtube.com/": "YouTube home", "https://www.youtube.com/feed/subscriptions": "YouTube home",
                     "https://www.reddit.com/": "the Reddit front page", "https://reddit.com/r/popular/": "the Reddit front page",
                     "https://x.com/home": "the X feed", "https://twitter.com/": "the X feed",
                     "https://www.linkedin.com/feed/": "the LinkedIn feed",
                     "https://www.linkedin.com/feed/foryou/": "the LinkedIn feed",
                     "https://www.amazon.com/dp/B0": "a shopping site", "https://www.etsy.com/listing/1": "a shopping site"]
        for (url, label) in cases { XCTAssertEqual(Judge.distractionSite(url), label, url) }
    }

    func testWorkPagesOnTheSameSitesAreNotListed() {
        for url in ["https://www.youtube.com/watch?v=fq3wx", "https://www.reddit.com/r/swift/comments/1",
                    "https://x.com/someone/status/1", "https://www.linkedin.com/feed/update/urn:li:activity:7",
                    "https://www.linkedin.com/messaging/thread/1", "https://console.aws.amazon.com/ec2",
                    "https://mail.google.com/mail/u/0/#inbox", "https://www.cosmos.so/e/1"] {
            XCTAssertEqual(Judge.distractionSite(url), "", url)
        }
    }

    func testAGoalThatNamesTheSiteExemptsIt() {
        XCTAssertEqual(Judge.distractionSite("https://www.instagram.com/", goal: "post the Acme reel on Instagram"), "")
        XCTAssertEqual(Judge.distractionSite("https://www.linkedin.com/feed/", goal: "LinkedIn outreach"), "")
        XCTAssertEqual(Judge.distractionSite("https://www.amazon.com/x", goal: "buy a USB-C hub"), "")
        XCTAssertEqual(Judge.distractionSite("", app: "Instagram"), "Instagram")
    }

    func testSearchWords() {
        XCTAssertEqual(Judge.searchWords("https://www.google.com/search?q=time+in+japan+now&rlz=1"), "time in japan now")
        XCTAssertEqual(Judge.searchWords("https://www.youtube.com/results?search_query=fisheye+dewarp"), "fisheye dewarp")
        XCTAssertEqual(Judge.searchWords("https://www.youtube.com/watch?v=1"), "")
        XCTAssertEqual(Judge.searchWords(""), "")
    }

    // IdleTests
    func testTwoMinutesNormallySixOnReading() {
        let slack: D = ["app": .string("Slack"), "url": .string("")]
        XCTAssertFalse(Judge.isAway(100, slack))
        XCTAssertTrue(Judge.isAway(130, slack))
        for screen: D in [["app": .string("Google Chrome"), "url": .string("https://nerd.wwnorton.com/nerd/75821/r/goto/cfi/304!/4")],
                          ["app": .string("Google Chrome"), "url": .string("https://learn.zybooks.com/zybook/CS110A/chapter/3")],
                          ["app": .string("Google Chrome"), "url": .string("https://school.instructure.com/courses/1/pages/x")],
                          ["app": .string("Preview"), "url": .string("")],
                          ["app": .string("Google Chrome"), "url": .string("https://example.com/paper.pdf")]] {
            XCTAssertFalse(Judge.isAway(300, screen), "\(screen)")
            XCTAssertTrue(Judge.isAway(400, screen), "\(screen)")
        }
        XCTAssertFalse(Judge.isAway(300, ["app": .string("Claude")], textLen: 5000))
        XCTAssertFalse(Judge.isAway(300, slack, studying: true))
    }

    // StoryTests
    func testTheLastTenMinutesInOneLine() {
        var trail: [D] = []
        let gmail: D = ["app": .string("Google Chrome"), "title": .string("Re: contract - Northwind"),
                        "url": .string("https://mail.google.com/mail/u/0/#inbox/1")]
        let search: D = ["app": .string("Google Chrome"), "title": .string("time in japan now - Google Search"),
                         "url": .string("https://www.google.com/search?q=time+in+japan+now")]
        for t in 0..<180 { trail = Judge.trailAdd(trail, screen: gmail, mode: "making", now: T0 + Double(t)) }
        for t in 180..<200 { trail = Judge.trailAdd(trail, screen: search, mode: "other", now: T0 + Double(t)) }
        let line = Judge.storyLine(trail, now: T0 + 200)
        XCTAssertTrue(line.hasPrefix("Last 10 min, oldest first: mail.google.com — Re: contract"), line)
        XCTAssertTrue(line.contains("(making, 3 min)"))
        XCTAssertTrue(line.contains("searched \"time in japan now\" (20 s)"))
        XCTAssertLessThanOrEqual(line.unicodeScalars.count, Judge.storyMaxChars)
        trail = Judge.trailAdd(trail, screen: search, mode: "other", now: T0 + 900)
        XCTAssertFalse(Judge.storyLine(trail, now: T0 + 900).contains("mail.google.com"))
    }

    func testALongStoryKeepsItsNewestScreens() {
        var trail: [D] = []
        for i in 0..<30 {
            trail = Judge.trailAdd(trail, screen: ["app": .string("App number \(i)"), "title": .string("window \(i)")],
                                   mode: "making", now: T0 + Double(i * 10))
        }
        let line = Judge.storyLine(trail, now: T0 + 300)
        XCTAssertLessThanOrEqual(line.unicodeScalars.count, Judge.storyMaxChars)
        XCTAssertTrue(line.contains("App number 29"))
        XCTAssertFalse(line.contains("App number 0 "))
    }

    // SettleTests
    private func base(_ a: D) -> D {
        Judge.verdictRow(parse(a), screen: ["app": .string("Google Chrome"), "url": .string("x")], at: T0)
    }

    func testADistractionSiteCountsAfterFiveSeconds() {
        let r = base(answers(onGoal: 2, activity: "studying"))
        XCTAssertFalse(Judge.truthy(Judge.settleRow(r, site: "the LinkedIn feed", siteS: 3)["off_site"]))
        let late = Judge.settleRow(r, site: "the LinkedIn feed", siteS: 5)
        XCTAssertEqual(late["off_site"], .bool(true))
        XCTAssertLessThanOrEqual(d(late["on_goal"]), Judge.distractionOnGoal)
        XCTAssertEqual(late["mode"], .string("consuming"))
        XCTAssertTrue(Judge.rowOffTask(late))
    }

    func testMessagingAboutTheTaskOnADistractionSiteIsOnTask() {
        let out = Judge.settleRow(base(answers(onGoal: 1, serves: 0.9)), site: "Instagram", siteS: 30)
        XCTAssertFalse(Judge.truthy(out["off_site"]))
        XCTAssertGreaterThanOrEqual(d(out["on_goal"]), 0.6)
        XCTAssertTrue(Judge.rowRelated(out))
    }

    func testAStepTowardTheGoalIsOnTaskButNotOnAFeed() {
        let out = Judge.settleRow(base(answers(onGoal: 0, activity: "other", step: 0.85)))
        XCTAssertEqual(out["stepped"], .bool(true))
        XCTAssertGreaterThanOrEqual(d(out["on_goal"]), 0.6)
        XCTAssertFalse(Judge.rowOffTask(out))
        let feed = Judge.settleRow(base(answers(onGoal: 0, activity: "consuming", step: 0.85)))
        XCTAssertFalse(Judge.truthy(feed["stepped"]))
    }

    func testHisRulingWins() {
        let out = Judge.settleRow(base(offAnswers()), site: "Instagram", siteS: 60, ruled: true)
        XCTAssertEqual(out["ruled"], .bool(true))
        XCTAssertFalse(Judge.rowOffTask(out))
    }

    func testAwayIsNotOffTaskForTheNudge() {
        let out = Judge.settleRow(base(offAnswers()), away: true)
        XCTAssertEqual(out["away"], .bool(true))
        XCTAssertFalse(Judge.rowOffTask(out))
    }

    // NudgeTests
    func testTwentyContinuousSecondsAreNeeded() {
        var rows = (0..<20).map { row(T0 + Double($0)) }
        XCTAssertFalse(Judge.offTaskRun(rows, now: T0 + 19))
        rows.append(row(T0 + 20))
        XCTAssertTrue(Judge.offTaskRun(rows, now: T0 + 20))
    }

    func testEightOfTenNoLongerNudges() {
        let rows = (0..<8).map { row(T0 + Double($0)) } + (0..<2).map { row(T0 + 8 + Double($0), ["on_goal": .number(0.9)]) }
        XCTAssertFalse(Judge.offTaskRun(rows, now: T0 + 10))
    }

    func testAnythingRelatedInTheWindowCancelsIt() {
        let related: [D] = [["serves_goal": .bool(true)], ["stepped": .bool(true)], ["ruled": .bool(true)],
                            ["step": .number(0.9), "mode": .string("other")], ["on_goal": .number(0.8)],
                            ["confidence": .number(0.4)], ["mode": .string("studying")]]
        for rel in related {
            var rows = (0..<25).map { row(T0 + Double($0)) }
            rows[10].merge(rel) { $1 }
            XCTAssertFalse(Judge.offTaskRun(rows, now: T0 + 24), "\(rel)")
        }
    }

    func testAGapInTheSecondsBreaksTheRun() {
        let rows = (0..<5).map { row(T0 + Double($0)) } + (0..<5).map { row(T0 + 25 + Double($0)) }
        XCTAssertFalse(Judge.offTaskRun(rows, now: T0 + 29))
        let sparse = (0..<6).map { row(T0 + Double($0 * 5)) }
        XCTAssertTrue(Judge.offTaskRun(sparse, now: T0 + 25))
    }

    func testNeverInTheFirstSecondsOfABlockAndFourMinutesApart() {
        let gap = 240.0         // brain/focus.py NUDGE_GAP_S
        let rows = (0..<30).map { row(T0 + Double($0)) }
        XCTAssertFalse(Judge.nudgeDue(rows, now: T0 + 25, blockStarted: T0 + 5, lastNudgeAt: 0, gapS: gap))
        XCTAssertTrue(Judge.nudgeDue(rows, now: T0 + 29, blockStarted: T0 - 60, lastNudgeAt: 0, gapS: gap))
        XCTAssertFalse(Judge.nudgeDue(rows, now: T0 + 29, blockStarted: T0 - 600, lastNudgeAt: T0 - 100, gapS: gap))
    }

    // StateTests
    func testStateCarriesTheStoryTheGoalsWorldAndHisRulings() {
        let st = Judge.buildState(
            goal: "Send response to Dana", specific: "Reply to Dana sent", understood: "", progressSoFar: 0.3,
            screen: ["app": .string("Google Chrome"), "title": .string("Re: pilot"),
                     "url": .string("https://www.google.com/search?q=loom+pricing"), "text": .string(String(repeating: "x", count: 10))],
            change: ["typed": .bool(true), "idle_s": .number(1), "text_changed_share": .number(0.2)],
            recent: [["mode": .string("making"), "on_goal": .number(0.9), "working": .number(0.8), "ago": .number(3),
                      "stepped": .bool(true)]],
            story: "Last 10 min, oldest first: mail.google.com — Re: pilot (making, 4 min)",
            related: .object(["people": .array([.string("Dana"), .string("Dana")]),
                              "sites": .array([.string("Gmail"), .string("Loom")]), "junk": .number(1)]),
            rulings: ["He said loom.com was for work during this block: treat it as on task."], imageRef: "shot-1")
        XCTAssertEqual(st["goal"]?["related"], .object(["people": .array([.string("Dana")]),
                                                        "sites": .array([.string("Gmail"), .string("Loom")])]))
        XCTAssertTrue(st["story_so_far"]!.stringValue!.contains("mail.google.com"))
        XCTAssertEqual(st["screen_now"]?["search_words"], .string("loom pricing"))
        XCTAssertEqual(st["screen_now"]?["screenshot"], .string("shot-1"))
        XCTAssertEqual(st["recent_verdicts_oldest_first"]?.arrayValue?[0]["tied_to_task"], .bool(true))
        XCTAssertTrue(st["his_rulings_this_block"]!.arrayValue![0].stringValue!.contains("loom.com"))
        XCTAssertEqual(st["since_last_second"]?["idle_allowance_s"]?.doubleValue, Double(Judge.idleS))
        XCTAssertNil(st["last_screenshot_ruling"])
        XCTAssertNil(Judge.withoutImage(st)["screen_now"]?["screenshot"])
    }

    func testReadingMaterialGetsTheLongAllowanceInTheState() {
        let st = Judge.buildState(goal: "Geo reading", specific: "", understood: "", progressSoFar: 0,
                                  screen: ["app": .string("Google Chrome"), "title": .string("Lab 13"),
                                           "url": .string("https://nerd.wwnorton.com/nerd/1"), "text": .string("x")],
                                  change: ["idle_s": .number(200)], recent: [])
        XCTAssertEqual(st["screen_now"]?["reading_material"], .bool(true))
        XCTAssertEqual(st["since_last_second"]?["idle_allowance_s"]?.doubleValue, Double(Judge.readingIdleS))
        XCTAssertEqual(st["since_last_second"]?["no_input_too_long"], .bool(false))
    }

    func testTheImageAssetIsTheTypeSafeShape() {
        XCTAssertEqual(Judge.imageAsset("QUJD", ref: "shot-x"),
                       ["shot-x": .object(["type": .string("image"), "format": .string("jpg"), "data_base64": .string("QUJD")])])
        XCTAssertEqual(Judge.imageHeader.name, "TypeSafe-Danger-Zone-Images")
        XCTAssertEqual(Judge.imageHeader.value, "true")
    }

    func testExceptionsMatchTheScreenTheyWereAbout() {
        let gmail: D = ["app": .string("Google Chrome"), "title": .string("Re: pilot - Gmail"),
                        "url": .string("https://mail.google.com/mail/u/0/#inbox/1")]
        let rule = Judge.exceptionFrom(gmail, at: T0)
        XCTAssertTrue(rule["rule"]!.stringValue!.contains("mail.google.com"))
        XCTAssertTrue(Judge.exceptionMatches(.object(rule), gmail))
        XCTAssertFalse(Judge.exceptionMatches(.object(rule), ["app": .string("Google Chrome"), "title": .string("Inbox (3)"),
                                                              "url": .string("https://mail.google.com/mail/u/0/#inbox")]))
        let claude = Judge.exceptionFrom(["app": .string("Claude"), "title": .string("Claude"), "url": .string("")], at: T0)
        XCTAssertTrue(Judge.exceptionMatches(.object(claude), ["app": .string("Claude"), "title": .string("anything"),
                                                               "url": .string("")]))
    }

    // MinuteTests
    func testMinuteFrameFoldsSecondsAndKeepsTheHighestSureProgress() {
        let rows = (0..<40).map { Judge.verdictRow(parse(answers(progress: $0 % 3)), screen: SCREEN, at: T0 + Double($0)) }
        let m = Judge.minuteFrame(rows, screen: SCREEN, at: T0 + 60)!
        XCTAssertEqual(m["mode"], .string("making"))
        XCTAssertEqual(m["seconds"]?.doubleValue, 40)
        XCTAssertEqual(d(m["progress"]), d(rows[2]["progress"]), accuracy: 1e-9)
        XCTAssertNil(Judge.minuteFrame(Array(rows.prefix(5)), screen: SCREEN, at: T0))
    }

    func testDistractionAndAwaySecondsAreCounted() {
        let rows = (0..<30).map { row(T0 + Double($0), ["off_site": .bool(true)]) }
            + (0..<10).map { row(T0 + 30 + Double($0), ["away": .bool(true)]) }
        let m = Judge.minuteFrame(rows, screen: ["url": .string("")], at: T0 + 60)!
        XCTAssertEqual(m["distraction_s"]?.doubleValue, 30)
        XCTAssertEqual(m["away_s"]?.doubleValue, 10)
    }

    func testThrottleAsksOnChangeElseEveryFiveSeconds() {
        XCTAssertTrue(Judge.throttle(changed: true, lastCallAt: T0, now: T0 + 1))
        XCTAssertFalse(Judge.throttle(changed: false, lastCallAt: T0, now: T0 + 1))
        XCTAssertTrue(Judge.throttle(changed: false, lastCallAt: T0, now: T0 + 5))
    }

    // GoalQuestionTests
    func testQuestionsAreCleanedRenumberedAndCapped() {
        let qs = Judge.goalQuestionsClean(GQ)
        XCTAssertEqual(qs.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(qs.map(\.means), ["on_task", "on_task", "off_task"])
        let many: JSONValue = .array((0..<12).map { .object(["text": .string("Is it doc \($0)?"), "means": .string("on_task")]) })
        XCTAssertEqual(Judge.goalQuestionsClean(many).count, Judge.goalQMax)
        XCTAssertEqual(Judge.goalQuestionsClean(.string("nope")), [])
        let long: JSONValue = .array([.object(["text": .string(String(repeating: "x", count: 500)), "means": .string("on_task")])])
        XCTAssertLessThanOrEqual(Judge.goalQuestionsClean(long)[0].text.count, 160)
    }

    func testQuestionsForAddsNoulQuestionsAndKeepsTheFixedOnes() {
        let qs = Judge.questionsFor(GQ)
        for k in Judge.questions.keys { XCTAssertNotNil(qs[k], k) }
        XCTAssertEqual(qs["goal_q1"]?["type"], .string("noul"))
        XCTAssertTrue(qs["goal_q1"]!.str("instructions").contains("Gmail thread with Dana"))
        XCTAssertNil(qs["goal_q4"])
        XCTAssertEqual(Judge.questionsFor(.array([])), Judge.questions.merging(Judge.checkQuestions) { $1 })
    }

    func testTheStateListsTheChecksSoJevSeesThem() {
        let st = Judge.buildState(goal: "Respond to Dana", specific: "", understood: "", progressSoFar: 0, screen: SCREEN,
                                  change: [:], recent: [], goalQuestions: GQ)
        let checks = st["goal"]?["checks"]?.arrayValue ?? []
        XCTAssertEqual(checks[0]["id"], .string("goal_q1"))
        XCTAssertEqual(checks[2]["if_yes"], .string("off task"))
        XCTAssertNil(Judge.buildState(goal: "g", specific: "", understood: "", progressSoFar: 0, screen: SCREEN,
                                      change: [:], recent: [])["goal"]?["checks"])
    }

    func testAnOnTaskTellLiftsTheSecondAndMarksIt() {
        var a = answers(onGoal: 0, activity: "other", step: 0.1)
        a["goal_q1"] = noul(0.85)
        a["goal_q3"] = noul(0.9)
        let v = parse(a, GQ)
        XCTAssertEqual(v["tells_on"], .array([.string("q1")]))
        XCTAssertEqual(v["tells_off"], .array([.string("q3")]))
        let r = Judge.settleRow(Judge.verdictRow(v, screen: SCREEN, at: T0))
        XCTAssertGreaterThanOrEqual(d(r["on_goal"]), Judge.stepOnGoal)
        XCTAssertEqual(r["tells"], .array([.string("q1")]))
        XCTAssertNil(r["off_tells"])
        XCTAssertTrue(Judge.rowRelated(r))
        XCTAssertFalse(Judge.rowOffTask(r))
    }

    func testAnOffTaskTellCapsOnGoalAndBlocksTheStepLift() {
        var a = answers(onGoal: 2, activity: "other", step: 0.9)
        a["goal_q3"] = noul(0.8)
        a["goal_q1"] = noul(0.4)
        let r = Judge.settleRow(Judge.verdictRow(parse(a, GQ), screen: SCREEN, at: T0))
        XCTAssertLessThanOrEqual(d(r["on_goal"]), Judge.goalOffOnGoal)
        XCTAssertEqual(r["off_tells"], .array([.string("q3")]))
        XCTAssertFalse(Judge.truthy(r["stepped"]))
        XCTAssertFalse(Judge.rowRelated(r))
    }

    func testAnOnTaskTellClearsADistractionSiteLikeServingTheGoal() {
        var a = answers(onGoal: 0, activity: "consuming")
        a["goal_q1"] = noul(0.9)
        let row = Judge.verdictRow(parse(a, GQ), screen: ["app": .string("Chrome"), "url": .string("https://instagram.com/")],
                                   at: T0)
        let r = Judge.settleRow(row, site: "Instagram", siteS: 30)
        XCTAssertFalse(Judge.truthy(r["off_site"]))
        XCTAssertGreaterThanOrEqual(d(r["on_goal"]), Judge.stepOnGoal)
    }

    func testNoGoalQuestionsChangesNothing() {
        let v = parse(answers())
        XCTAssertEqual(v["tells_on"], .array([]))
        XCTAssertEqual(v["tells_off"], .array([]))
    }

    func testASecondOpinionYesIsTiedToTheTask() {
        XCTAssertTrue(Judge.rowRelated(row(T0, ["second": .string("yes")])))
        XCTAssertFalse(Judge.rowOffTask(row(T0, ["second": .string("yes")])))
        XCTAssertFalse(Judge.rowRelated(row(T0, ["second": .string("no"), "step": .number(0.9), "mode": .string("other")])))
    }

    // LabelRowTests
    func testTheLabelRowShapeNeverCarriesTheText() {
        let r = Judge.settleRow(Judge.verdictRow(parse(offAnswers()), screen: SCREEN, at: T0))
        let out = Judge.labelRow(at: T0, user: "owner", blockId: "b1", goal: "Acme onboarding", specific: "fix the crash",
                                 screen: ["app": .string("Google Chrome"), "title": .string("Loom"),
                                          "url": .string("https://www.loom.com/share/1")],
                                 text: "secret visible words", row: r, label: "on_task", source: "button")
        XCTAssertEqual(Set(out.keys), ["at", "user", "block_id", "goal", "specific_goal", "app", "title", "url",
                                       "text_digest", "jev", "image_used", "label", "source"])
        XCTAssertEqual(out["text_digest"], .string(Judge.textDigest("secret visible words")))
        XCTAssertFalse("\(out)".contains("secret"))
        XCTAssertEqual(out["label"], .string("on_task"))
        XCTAssertEqual(out["source"], .string("button"))
        for k in ["on_goal", "working", "mode", "serves_goal", "confidence", "step", "stepped", "related",
                  "tells", "off_tells"] {
            XCTAssertNotNil(out["jev"]?[k], k)
        }
    }

    // TodayLineTests
    func testPlanAndNextTwoCalendarItemsIn400Chars() {
        let line = Judge.todayLine(["Acme onboarding", "HIST reading"],
                                   [("14:00", "Team standup"), ("16:30", "Call Robin"), ("18:00", "Dinner")])
        XCTAssertTrue(line.contains("Today's plan: Acme onboarding; HIST reading."))
        XCTAssertTrue(line.contains("14:00 Team standup; 16:30 Call Robin"))
        XCTAssertFalse(line.contains("Dinner"))
        XCTAssertEqual(Judge.todayLine([], []), "")
        XCTAssertLessThanOrEqual(Judge.todayLine(Array(repeating: String(repeating: "x", count: 300), count: 5),
                                           Array(repeating: ("1", String(repeating: "y", count: 300)), count: 2)).count, 400)
        let st = Judge.buildState(goal: "g", specific: "", understood: "", progressSoFar: 0, screen: SCREEN, change: [:],
                                  recent: [], today: line)
        XCTAssertEqual(st["today"], .string(line))
    }

    // GeneralCheckBankTests
    func testTheBankShape() {
        let bank = Judge.generalChecks
        XCTAssertTrue((30...36).contains(bank.count))
        XCTAssertEqual(Set(bank.map(\.id)).count, bank.count)
        for c in bank {
            XCTAssertTrue((0.5...1.0).contains(c.weight), c.id)
            XCTAssertLessThanOrEqual(c.text.count, 110, c.id)
            XCTAssertTrue(c.text.hasSuffix("?"), c.id)
            XCTAssertTrue(Set(c.feeds).isSubset(of: ["on_goal", "working", "quality", "smart"]), c.id)
            XCTAssertFalse(c.text.lowercased().contains("gmail"))
        }
        let need: Set = ["contact", "search", "ai_agent", "reference", "making", "title", "testing", "lookup",
                         "planning", "meeting", "waiting", "sub_problem", "form", "lecture", "feed", "entertainment",
                         "shopping", "chat_unrelated", "news", "game", "hopping", "new_topic", "personal_admin",
                         "notifications", "other_project", "repeating", "ai_unrelated", "passive", "settings",
                         "finder", "switching"]
        XCTAssertTrue(need.isSubset(of: Set(Judge.checkIds)))
        let by = Dictionary(uniqueKeysWithValues: bank.map { ($0.id, $0) })
        XCTAssertFalse(by["repeating"]!.feeds.contains("on_goal"))
        XCTAssertTrue(by["repeating"]!.feeds.contains("working"))
        XCTAssertTrue(by["hopping"]!.feeds.contains("smart"))
    }

    func testEveryCallCarriesTheBankOnceAsNoulQuestions() {
        let qs = Judge.questionsFor(GQ)
        XCTAssertEqual(qs.keys.filter { $0.hasPrefix(Judge.checkPrefix) }.count, Judge.generalChecks.count)
        XCTAssertEqual(qs["chk_contact"]?["type"], .string("noul"))
        XCTAssertNotNil(qs["goal_q1"])
        XCTAssertTrue(Judge.standingRules.joined(separator: " ").contains("chk_"))
    }

    // CombineTests
    private func combine(_ a: D, _ s: JSONValue?) -> D { Judge.combineChecks(.object(a), s) }

    func testPureOn() {
        let c = combine(checks(["contact": 0.95, "making": 0.9], low: 0.01), scoreAnswer(3))
        XCTAssertGreaterThan(d(c["on"]), 0.95)
        XCTAssertLessThan(d(c["off"]), 0.2)
        XCTAssertGreaterThan(d(c["on_goal"]), 0.9)
        XCTAssertGreaterThan(d(c["confidence"]), 0.85)
        XCTAssertEqual(c["tells"], .array([.string("contact"), .string("making")]))
        XCTAssertEqual(c["off_tells"], .array([]))
        XCTAssertFalse(Judge.escalate(["on_goal": c["on_goal"]!, "confidence": c["confidence"]!]))
    }

    func testPureOff() {
        let c = combine(checks(["feed": 0.8, "entertainment": 0.95], low: 0.01), scoreAnswer(0))
        XCTAssertGreaterThan(d(c["off"]), 0.95)
        XCTAssertLessThan(d(c["on_goal"]), 0.1)
        XCTAssertGreaterThan(d(c["confidence"]), 0.85)
        XCTAssertEqual(c["off_tells"], .array([.string("entertainment"), .string("feed")]))
        XCTAssertLessThan(d(c["on_goal"]), Judge.offTaskOnGoal)
        XCTAssertGreaterThanOrEqual(d(c["confidence"]), Judge.offTaskConfidence)
    }

    func testTornMeansLowConfidenceAndEscalation() {
        let c = combine(checks(["contact": 0.9, "chat_unrelated": 0.9]),
                        scoreAnswer(probs: ["0": 0.3, "1": 0.2, "2": 0.2, "3": 0.3]))
        XCTAssertEqual(d(c["on"]), 0.9, accuracy: 1e-7)
        XCTAssertEqual(d(c["off"]), 0.72, accuracy: 1e-7)
        XCTAssertEqual(d(c["confidence"]), 0.09, accuracy: 1e-3)
        XCTAssertEqual(c["tells"], .array([.string("contact")]))
        XCTAssertEqual(c["off_tells"], .array([.string("chat_unrelated")]))
        XCTAssertTrue(Judge.escalate(["on_goal": c["on_goal"]!, "confidence": c["confidence"]!]))
    }

    func testTheBlendWithTheOldScore() {
        let a: D = ["chk_contact": noul(1.0)]
        var c = combine(a, scoreAnswer(0, conf: 0.2))
        XCTAssertEqual(d(c["on"]), 1.0)
        XCTAssertEqual(d(c["off"]), 0.0)
        XCTAssertEqual(d(c["on_goal"]), 0.6, accuracy: 1e-7)
        XCTAssertEqual(d(c["on_goal_raw"]), 0.0)
        XCTAssertEqual(d(c["confidence"]), 1.0, accuracy: 1e-7)
        c = combine(a, scoreAnswer(probs: ["0": 0.5, "1": 0, "2": 0, "3": 0.5]))
        XCTAssertEqual(d(c["on_goal"]), 0.6 + 0.4 * 0.5, accuracy: 1e-7)
        XCTAssertEqual(d(c["confidence"]), 0.5, accuracy: 1e-7)
        c = combine(["chk_title": .object(["noul": .number(1)]), "chk_files": .object(["noul": .number(1)])], scoreAnswer(3))
        XCTAssertEqual(d(c["on"]), 1 - 0.4 * 0.4, accuracy: 1e-7)
    }

    func testNoCheckAnsweredKeepsTheScoreAsItWas() {
        let c = combine([:], scoreAnswer(probs: ["0": 0.02, "1": 0.03, "2": 0.5, "3": 0.45]))
        XCTAssertEqual(d(c["answered"]), 0)
        XCTAssertEqual(d(c["on_goal"]), d(c["on_goal_raw"]), accuracy: 1e-7)
        XCTAssertEqual(d(c["confidence"]), 0.9, accuracy: 1e-7)
        let v = parse(answers())
        XCTAssertEqual(v["on_goal"], v["on_goal_raw"])
    }

    func testNeutralChecksMoveNothing() {
        let c = combine(checks(["settings": 0.95, "finder": 0.9]), scoreAnswer(3))
        XCTAssertEqual(d(c["on"]), 0)
        XCTAssertEqual(d(c["off"]), 0)
        XCTAssertEqual(c["neutral"], .array([.string("settings"), .string("finder")]))
        XCTAssertEqual(c["tells"], .array([]))
        XCTAssertEqual(c["off_tells"], .array([]))
    }

    func testRepeatingOrHoppingCapsWorkingAndSmart() {
        var v = parse(merged(answers(working: 3, smart: 3), checks(["repeating": 0.75, "making": 0.9])))
        XCTAssertLessThanOrEqual(d(v["working"]), 0.4)
        XCTAssertLessThanOrEqual(d(v["smart"]), 0.4)
        XCTAssertGreaterThan(d(v["quality"]), 0.5)
        XCTAssertEqual(d(v["off"]), 0)
        XCTAssertTrue(v["check_off_tells"]!.arrayValue!.contains(.string("repeating")))
        v = parse(merged(answers(working: 3, smart: 3), checks(["hopping": 0.7])))
        XCTAssertLessThanOrEqual(d(v["working"]), 0.4)
        XCTAssertLessThanOrEqual(d(v["smart"]), 0.4)
        XCTAssertGreaterThan(d(v["off"]), 0.4)
        v = parse(merged(answers(working: 3, smart: 3), checks(["repeating": 0.65])))
        XCTAssertGreaterThan(d(v["working"]), 0.9)
    }

    func testParseThroughTheRealQuestionsDict() {
        let qs = Judge.questionsFor(GQ)
        var out: D = [:]
        for (k, q) in qs {
            switch q["type"]?.stringValue {
            case "noul": out[k] = noul(0.02)
            case "choice":
                var p: D = [:]
                if case .object(let crit)? = q["criteria"] { for c in crit.keys { p[c] = .number(c == "making" ? 0.9 : 0.025) } }
                out[k] = .object(["type": .string("choice"), "choice": .string("making"), "probabilities": .object(p)])
            default:
                let n = q["criteria"]?.arrayValue?.count ?? 4
                var p: D = [:]
                for i in 0..<n { p[String(i)] = .number(i == n - 1 ? 0.9 : 0.1 / Double(n - 1)) }
                out[k] = .object(["type": .string("score"), "probabilities": .object(p)])
            }
        }
        out["chk_search"] = noul(0.92)
        out["chk_lookup"] = noul(0.7)
        out["chk_notifications"] = noul(0.61)
        out["goal_q1"] = noul(0.9)
        let v = parse(out, GQ)
        XCTAssertEqual(d(v["checks_answered"]), Double(Judge.generalChecks.count))
        XCTAssertEqual(v["check_tells"], .array([.string("search"), .string("lookup")]))
        XCTAssertEqual(v["check_off_tells"], .array([.string("notifications")]))
        XCTAssertEqual(v["tells_on"], .array([.string("q1")]))
        XCTAssertNotEqual(v["on_goal_raw"], .null)
        let r = Judge.settleRow(Judge.verdictRow(v, screen: SCREEN, at: T0))
        XCTAssertEqual(r["tells"], .array([.string("q1"), .string("search"), .string("lookup")]))
        XCTAssertEqual(r["off_tells"], .array([.string("notifications")]))
        XCTAssertEqual(d(r["check_p"]?["search"]), 0.92)
        for k in ["on", "off", "on_goal_raw"] { XCTAssertNotNil(r[k], k) }
        XCTAssertTrue(Judge.rowRelated(r))
    }

    func testGeneralOffTellsNeverBlockAStepOrMakeARowUnrelated() {
        let a = merged(answers(onGoal: 2, activity: "other", step: 0.9), checks(["notifications": 0.65, "search": 0.9]))
        let r = Judge.settleRow(Judge.verdictRow(parse(a), screen: SCREEN, at: T0))
        XCTAssertEqual(r["stepped"], .bool(true))
        XCTAssertTrue(Judge.rowRelated(r))
        XCTAssertEqual(r["off_tells"], .array([.string("notifications")]))
        XCTAssertNil(r["goal_off_tells"])
    }

    func testEscalateRulesAndTheTellsText() {
        func row(_ on: Double, _ conf: Double, _ extra: D = [:]) -> D {
            merged(["on_goal": .number(on), "confidence": .number(conf)], extra)
        }
        XCTAssertTrue(Judge.escalate(row(0.9, 0.59)))
        XCTAssertTrue(Judge.escalate(row(0.35, 0.9)))
        XCTAssertTrue(Judge.escalate(row(0.64, 0.9)))
        XCTAssertFalse(Judge.escalate(row(0.65, 0.6)))
        XCTAssertFalse(Judge.escalate(row(0.34, 0.9)))
        XCTAssertFalse(Judge.escalate(row(0.5, 0.1, ["ruled": .bool(true)])))
        XCTAssertFalse(Judge.escalate(row(0.5, 0.1, ["off_site": .bool(true)])))
        let tt: D = ["tells": .array(["a", "b", "c", "d", "e", "f"].map { .string($0) }), "off_tells": .array([.string("feed")]),
                     "check_p": .object(["a": .number(0.9), "b": .number(0.8), "c": .number(0.7), "d": .number(0.66),
                                         "e": .number(0.65), "f": .number(0.6), "feed": .number(0.71)]),
                     "on": .number(0.95), "off": .number(0.5), "on_goal_raw": .number(0.4)]
        let t = Judge.tellsText(tt)
        XCTAssertTrue(t.contains("Leaning on task: a 0.90, b 0.80, c 0.70, d 0.66, e 0.65."), t)
        XCTAssertFalse(t.contains("f 0.60"))
        XCTAssertTrue(t.contains("Leaning off task: feed 0.71."))
        XCTAssertTrue(t.contains("on 0.95, off 0.5"))
        XCTAssertEqual(Judge.tellsText([:]), "")
    }

    // CheckFloorTest
    func testFaintMaybesDoNotAddUp() {
        let out = combine(checks(low: 0.03), nil)
        XCTAssertEqual(d(out["on"]), 0)
        XCTAssertEqual(d(out["off"]), 0)
    }

    func testARealYesStillCounts() {
        let out = combine(checks(["making": 0.9], low: 0.03), nil)
        XCTAssertGreaterThanOrEqual(d(out["on"]), 0.85)
        XCTAssertEqual(d(out["off"]), 0)
    }
}
