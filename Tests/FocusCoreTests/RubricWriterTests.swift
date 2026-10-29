import XCTest
@testable import FocusCore

/// The Swift rubric writer against brain/rubric.py: each fixture (scripts/fixtures_rubric.py) is one writer
/// output run through the Python; the Swift must give the same rubric, markdown (exact), questions and prompt.
final class RubricWriterTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rubric")
    static let cases = ["good_reading", "building", "outreach", "malformed_json", "empty_tells",
                        "balance_out_of_range", "note_applied", "rulings_merged"]

    func load(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent(name + ".json"))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func run(_ f: JSONValue) -> Rubric {
        var r = RubricWriter.parse(text: f["text"]?.stringValue,
                                   note: f["note"]?.stringValue ?? "")
        if let labels = f["labels"]?.arrayValue, !labels.isEmpty { r = RubricWriter.mergeRulings(r, labels: labels) }
        return r
    }

    func testEveryFixtureMatchesThePython() throws {
        for name in Self.cases {
            let f = try load(name)
            let r = run(f)
            XCTAssertEqual(r.md, f["md"]?.stringValue, name)
            XCTAssertEqual(RubricWriter.json(r), f["rubric"], name)
            XCTAssertEqual(.object(RubricWriter.questionsJSON(r)), f["questions"], name)
            XCTAssertEqual(.array(RubricWriter.goalQuestions(r).map(\.json)), f["goal_questions"], name)
            // The order Jev is asked in: on tells, off tells, milestones.
            let ids = RubricWriter.questions(r).map(\.id)
            XCTAssertEqual(ids, r.onTells.map { "rub_on_" + $0.id } + r.offTells.map { "rub_off_" + $0.id }
                           + r.milestones.map { "ms_" + $0.id }, name)
        }
    }

    func testEveryPromptMatchesThePython() throws {
        for name in Self.cases {
            let f = try load(name)
            let p = try XCTUnwrap(f["prompt_input"])
            let related = (p["related"]?.arrayValue ?? []).map { pair -> (key: String, values: [String]) in
                let a = pair.arrayValue ?? []
                return (a[0].stringValue ?? "", (a[1].arrayValue ?? []).compactMap(\.stringValue))
            }
            let got = RubricWriter.prompt(goal: p.strRaw("goal"), specific: p.strRaw("specific"),
                                          understood: p.strRaw("understood"), related: related,
                                          pastRubricMd: p.strRaw("past_rubric_md"),
                                          rulings: (p["rulings"]?.arrayValue ?? []).compactMap(\.stringValue),
                                          note: p.strRaw("note"),
                                          blockMinutes: Int(p["block_min"]?.doubleValue ?? 25),
                                          currentMd: p.strRaw("current_md"))
            XCTAssertEqual(got, f["prompt"]?.stringValue, name)
        }
        XCTAssertEqual(RubricWriter.systemPrompt(), try load("system")["system"]?.stringValue)
    }

    func testBalanceRules() {
        XCTAssertEqual(RubricWriter.balance(for: .reading, raw: nil), .init(focus: 0.9, output: 0.1))
        XCTAssertEqual(RubricWriter.balance(for: .building, raw: .object(["focus": .number(7), "output": .number(13)])),
                       .init(focus: 0.35, output: 0.65))
        XCTAssertEqual(RubricWriter.balance(for: .study, raw: .object(["focus": .number(1), "output": .number(0)])),
                       .init(focus: 0.95, output: 0.05))
        XCTAssertEqual(RubricWriter.balance(for: .mixed, raw: .string("half")), .init(focus: 0.5, output: 0.5))
        XCTAssertEqual(RubricWriter.balance(for: .writing, raw: .object(["focus": .string("0.4")])),
                       .init(focus: 0.4, output: 0.6))
        XCTAssertEqual(RubricWriter.balance(for: .writing, raw: .object(["focus": .bool(true)])),
                       .init(focus: 0.4, output: 0.6))
    }

    func testBadAnswersFallBack() {
        for raw: JSONValue? in [nil, .string("not json"), .object(["kind": .string("reading")]),
                                .object(["on_tells": .array([])]), .number(42)] {
            let r = RubricWriter.parse(raw)
            XCTAssertTrue(r.fallback)
            XCTAssertEqual(r.kind, .mixed)
            XCTAssertEqual(r.balance, .init(focus: 0.5, output: 0.5))
            XCTAssertTrue(r.milestones.isEmpty)
            XCTAssertTrue(r.md.contains("_The rubric writer could not answer"))
        }
        XCTAssertTrue(RubricWriter.parse(text: nil).fallback)
    }

    func testMilestonesReached() throws {
        let r = run(try load("rulings_merged"))
        let answers: JSONValue = .object(["ms_m1": .object(["noul": .number(0.8)]),
                                          "ms_m2": .object(["noul": .number(0.5)])])
        XCTAssertEqual(RubricWriter.milestonesReached(answers: answers, rubric: r), ["m1"])
        XCTAssertEqual(RubricWriter.milestonesReached(answers: nil, rubric: r), [])
    }

    func testTheDisplayModelStillReadsTheParsedRubric() throws {
        let r = run(try load("rulings_merged"))
        XCTAssertEqual(Rubric.parse(RubricWriter.publicJSON(r))?.balance, r.balance)
        XCTAssertEqual(r.balanceLine, "Judged 40% on focus, 60% on output")
        XCTAssertEqual(r.onTells.last?.from, "ruling")
    }
}

private extension JSONValue {
    /// The string as stored (not trimmed).
    func strRaw(_ k: String) -> String { self[k]?.stringValue ?? "" }
}
