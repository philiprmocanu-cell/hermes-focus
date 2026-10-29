import XCTest
@testable import FocusCore
private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

// MARK: - The board: hours vs output

final class LeaderboardOutputTests: XCTestCase {
    private let board = """
    {"rows":[
      {"name":"Riley","today_s":9000,"week_s":40000,"blocks_today":6,"me":true,"score_today":700,
       "output_today":610,"output_week":580},
      {"name":"Marius","today_s":3600,"week_s":18000,"blocks_today":2,"output_today":820,"output_week":700},
      {"name":"Sam","today_s":5400,"week_s":9000,"blocks_today":3},
      {"name":"Ana","today_s":1800,"week_s":20000,"blocks_today":1,"output_today":610,"output_week":600}
    ]}
    """

    func testParsesOutputForEveryRowAndTreatsItAsOptional() throws {
        let rows = Leaderboard.parse(try json(board))
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        XCTAssertEqual(byName["Riley"]?.outputToday, 610)
        XCTAssertEqual(byName["Riley"]?.outputWeek, 580)
        XCTAssertEqual(byName["Marius"]?.outputToday, 820, "friends carry output too")
        XCTAssertNil(byName["Sam"]?.outputToday)
        XCTAssertNil(byName["Sam"]?.outputWeek)
        XCTAssertEqual(byName["Sam"]?.outputText, "—")
        XCTAssertEqual(byName["Marius"]?.outputText, "820")

        let odd = Leaderboard.parse(try json("""
        {"rows":[{"name":"A","output_today":null,"output_week":"x"},{"name":"B","output_today":1234.4,"output_week":0},
                 {"name":"C","output_today":512.6}]}
        """))
        XCTAssertNil(odd.first { $0.name == "A" }?.outputToday)
        XCTAssertNil(odd.first { $0.name == "A" }?.outputWeek)
        XCTAssertEqual(odd.first { $0.name == "B" }?.outputToday, 1000, "clamped to 1000")
        XCTAssertNil(odd.first { $0.name == "B" }?.outputWeek, "0 is no score")
        XCTAssertEqual(odd.first { $0.name == "C" }?.outputToday, 513)
    }

    func testHardestWorkingSortsByHours() throws {
        let rows = Leaderboard.rank(Leaderboard.parse(try json(board)), by: .hours)
        XCTAssertEqual(rows.map(\.name), ["Riley", "Sam", "Marius", "Ana"])
        XCTAssertEqual(rows.map(\.rank), [1, 2, 3, 4])
        XCTAssertEqual(Leaderboard.parse(try json(board)).map(\.name), rows.map(\.name), "parse keeps the hours order")
    }

    func testMostOutputSortsByOutputScore() throws {
        let rows = Leaderboard.rank(Leaderboard.parse(try json(board)), by: .output)
        // Marius 820; Riley and Ana both 610 today → this week's decides (600 > 580); Sam has none → last.
        XCTAssertEqual(rows.map(\.name), ["Marius", "Ana", "Riley", "Sam"])
        XCTAssertEqual(rows.map(\.rank), [1, 2, 3, 4])
    }

    func testOutputTiesShareARankAndRowsWithoutScoresGoByHours() {
        let rows = Leaderboard.rank([
            LeaderboardRow(name: "A", todayS: 100, weekS: 100, blocksToday: 1, me: false, outputToday: 500, outputWeek: 500),
            LeaderboardRow(name: "B", todayS: 900, weekS: 900, blocksToday: 1, me: false, outputToday: 500, outputWeek: 500),
            LeaderboardRow(name: "C", todayS: 50, weekS: 50, blocksToday: 1, me: false),
            LeaderboardRow(name: "D", todayS: 800, weekS: 800, blocksToday: 1, me: false),
        ], by: .output)
        XCTAssertEqual(rows.map(\.name), ["B", "A", "D", "C"], "equal output: more hours first; no output: by hours")
        XCTAssertEqual(rows.map(\.rank), [1, 1, 3, 4])
    }

    func testSortToggleTitlesAndStoredValue() {
        XCTAssertEqual(LeaderboardSort.hours.title, "Hardest working")
        XCTAssertEqual(LeaderboardSort.output.title, "Most output")
        XCTAssertEqual(LeaderboardSort(stored: "output"), .output)
        XCTAssertEqual(LeaderboardSort(stored: nil), .hours)
        XCTAssertEqual(LeaderboardSort(stored: "junk"), .hours)
    }
}
