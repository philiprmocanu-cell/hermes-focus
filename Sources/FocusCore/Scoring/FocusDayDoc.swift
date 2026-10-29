import Foundation

// The day's page (brain/focus_day.py `doc_paragraphs` and the sections it pulls in), as plain
// paragraphs: text, a Docs named style, a bullet flag and how many leading characters are bold.
// `docText` and `docHTML` draw it exactly as the Python does; `markdown` is the Swift-only
// rendering for the app's own day report (no Google Doc on the Mac).

public struct DayParagraph: Equatable, Sendable {
    public var text: String
    /// "NORMAL_TEXT", "TITLE", "HEADING_1" or "HEADING_2".
    public var style: String
    public var bullet: Bool
    /// Leading characters (code points) in bold.
    public var bold: Int

    public init(_ text: String, style: String = "NORMAL_TEXT", bullet: Bool = false, bold: Int = 0) {
        self.text = ScorePy.ws(text)
        self.style = style
        self.bullet = bullet
        self.bold = bold
    }

    public var json: JSONValue {
        .object(["text": .string(text), "style": .string(style), "bullet": .bool(bullet), "bold": .number(Double(bold))])
    }
}

extension FocusDay {
    typealias P = DayParagraph

    static func share(_ seconds: Double, _ whole: Double) -> String {
        whole != 0 && seconds != 0 ? " (\(ScorePy.iround(100 * seconds / whole))%)" : ""
    }

    static func rows(_ v: JSONValue?) -> [(String, Double)] {
        ScorePy.list(v).map { (ScorePy.strRaw(ScorePy.at($0, 0)), ScorePy.num(ScorePy.at($0, 1)) ?? 0) }
    }

    /// The Hours section: the total, then where every minute of it went.
    public static func hoursParagraphs(_ hv: JSONValue?) -> [DayParagraph] {
        guard let h = ScorePy.obj(hv), ScorePy.truthy(h["worked_s"]) else { return [] }
        let whole = ScorePy.num(h["worked_s"]) ?? 0
        var out = [P("Hours", style: "HEADING_1"),
                   P("Hours worked today: " + hoursSentence(hv), bold: ScorePy.len("Hours worked today:"))]
        if let ss = ScorePy.num(h["session_s"]), ss != 0, ss >= whole + 60 {
            out.append(P("Counting the breaks in between, you were in a focus session for \(hm(ss))."))
        }
        out.append(P("Where your hours went", style: "HEADING_2"))
        for (title, key) in [("By project", "projects"), ("What you were doing", "activity")] {
            let rs = rows(h[key]).filter { $0.1 >= minRowS }
            if rs.isEmpty { continue }
            out.append(P(title, bold: ScorePy.len(title)))
            for (label, secs) in rs { out.append(P("\(label) — \(hm(secs))\(share(secs, whole))", bullet: true)) }
        }
        let eyes = rows(h["eyes"])
        if !eyes.isEmpty {
            let eyesS = ScorePy.num(h["eyes_s"]) ?? 0
            let title = eyesS >= whole - 60 ? "What your eyes were doing"
                : "What your eyes were doing (of the \(hm(eyesS)) the camera watched)"
            out.append(P(title, bold: ScorePy.len(title)))
            for (label, secs) in eyes {
                out.append(P("\(label) — \(hm(secs))\(share(secs, ScorePy.nz(eyesS, whole)))", bullet: true))
            }
        }
        var leakRows: [String] = []
        let off = ScorePy.num(h["off_goal_s"]) ?? 0
        if off >= minRowS { leakRows.append("Off your goal — \(hm(off))\(share(off, whole))") }
        let dist = ScorePy.num(h["distraction_s"]) ?? 0
        if dist >= minRowS { leakRows.append("Plainly distracting sites and apps — \(hm(dist))") }
        leakRows += rows(h["sites"]).map { "\($0.0) — \(hm($0.1))" }
        if !leakRows.isEmpty {
            out.append(P("Where it leaked", bold: ScorePy.len("Where it leaked")))
            out += leakRows.map { P($0, bullet: true) }
        }
        var breaks: [String] = []
        for (key, word) in [("short_breaks", "short"), ("long_breaks", "long")] {
            let n = Int(ScorePy.num(ScorePy.at(h[key], 0)) ?? 0)
            if n != 0 { breaks.append("\(n) \(word) break\(n != 1 ? "s" : "") — \(hm(ScorePy.num(ScorePy.at(h[key], 1))))") }
        }
        if let k = ScorePy.intValue(h["skipped_breaks"]), k != 0 {
            breaks.append("\(k) break\(k != 1 ? "s" : "") skipped (your call, it costs you nothing)")
        }
        if !breaks.isEmpty {
            out.append(P("Breaks", bold: ScorePy.len("Breaks")))
            out += breaks.map { P($0, bullet: true) }
        }
        return out
    }

    /// Plain words for how much of the day went to one thing at a time.
    public static func monoSentence(_ m: JSONValue?) -> String {
        guard let share = ScorePy.num(m?["top_share"]) else { return "" }
        let pct = ScorePy.iround(100 * ScorePy.clamp(share))
        let how = share >= monoTight ? "you mostly stayed in one thing at a time"
            : share >= monoLoose ? "you held one thing at a time about half of it"
            : "your time was spread across several things at once"
        var line = "Mono-focus: \(pct)% of your block time went to the single thing you were most in — \(how)"
        if let sw = ScorePy.num(m?["switches_per_min"]) {
            let rate = sw < switchCalm ? "hardly switching apps" : sw < switchBusy ? "switching apps now and then"
                : "switching apps constantly"
            line += ", \(rate) (\(ScorePy.fmt(sw, "%.1f")) a minute)"
        }
        return line + "."
    }

    public static func attentionSentence(_ a: JSONValue?) -> String {
        guard let value = ScorePy.num(a?["value"]) else { return "" }
        let pct = ScorePy.iround(100 * ScorePy.clamp(value))
        let how = pct >= 85 ? "your eyes were on the work nearly all of it"
            : pct >= 65 ? "your eyes were on the work most of it" : "your eyes were off the work a good part of it"
        return "Attention: \(pct)% on average — \(how)."
    }

    /// How many separate stretches of focus the day had.
    public static func periodsSentence(_ h: JSONValue?, totals: JSONValue?) -> String {
        let n = Int(ScorePy.nz(ScorePy.num(h?["sessions"]), 0))
        let blocks = Int(ScorePy.nz(ScorePy.num(totals?["blocks"]), 0))
        if n == 0 { return "" }
        var line = "Focus periods: \(n) \(n == 1 ? "focus period" : "focus periods")"
        if blocks != 0 { line += " — \(blocks) block\(blocks != 1 ? "s" : "") in all" }
        if blocks != 0 && blocks > n { line += ", about \(ScorePy.fmt(Double(blocks) / Double(n), "%.1f")) blocks a period" }
        return line + "."
    }

    /// The final section: what he completed today, and what he did not.
    public static func goalsParagraphs(_ blocks: JSONValue?) -> [DayParagraph] {
        goalsParagraphs(goalsToday(scoredRows(blocks)))
    }

    static func goalsParagraphs(_ g: (done: [(String, Double?, Double)], open: [(String, Double?, Double)])) -> [DayParagraph] {
        if g.done.isEmpty && g.open.isEmpty { return [] }
        var out = [P("Completed today", style: "HEADING_1")]
        if g.done.isEmpty {
            out.append(P("Nothing reached the finish line today."))
        } else {
            for (goal, _, secs) in g.done { out.append(P("\(goal) — \(hm(secs))", bullet: true)) }
        }
        if !g.open.isEmpty {
            out.append(P("Started but not finished", style: "HEADING_2"))
            for (goal, got, secs) in g.open {
                let how = got.map { "\(ScorePy.iround(100 * $0))% of the way there" } ?? "no progress the screens could measure"
                out.append(P("\(goal) — \(how), \(hm(secs)) spent", bullet: true))
            }
        }
        return out
    }

    // ------------------------------------------------------- the weekly review

    public static let weeklyHeading = "The week"
    public static let weeklyRowsMax = 5

    public static func weeklyClean(_ raw: JSONValue?) -> JSONValue? {
        guard let r = ScorePy.obj(raw) else { return nil }
        func rowsOf(_ key: String, _ n: Int = 140) -> [JSONValue] {
            Array(ScorePy.list(r[key]).filter { !ScorePy.strip(sentence($0, n)).isEmpty }
                .map { JSONValue.string(ScorePy.rstrip(sentence($0, n), ".")) }.prefix(weeklyRowsMax))
        }
        let patterns = rowsOf("patterns", 200), leaks = rowsOf("leaks"), change = rowsOf("change", 200)
        if patterns.isEmpty && leaks.isEmpty && change.isEmpty { return nil }
        return .object(["patterns": .array(patterns), "leaks": .array(leaks), "change": .array(change),
                        "best_hours": .string(sentence(r["best_hours"], 160)),
                        "worst_hours": .string(sentence(r["worst_hours"], 160)), "from": "opus".scoreJSON])
    }

    /// Seven stored day-rows read without a model.
    public static func weeklyFallback(_ days: JSONValue?) -> JSONValue {
        let rowsIn = ScorePy.dicts(days).filter { ScorePy.intValue($0["score"]) != nil }
        var patterns: [String] = [], leaksOut: [String] = [], change: [String] = []
        func sc(_ d: ScoreObj) -> Int { ScorePy.intValue(d["score"])! }
        if !rowsIn.isEmpty {
            var best = rowsIn[0], worst = rowsIn[0]
            for d in rowsIn.dropFirst() {
                if sc(d) > sc(best) { best = d }
                if sc(d) < sc(worst) { worst = d }
            }
            let avg = ScorePy.iround(Double(rowsIn.map(sc).reduce(0, +)) / Double(rowsIn.count))
            patterns.append("\(rowsIn.count) days scored, averaging \(avg) out of 1000")
            let bd = ScorePy.truthy(best["day"]) ? ScorePy.str(best["day"]) : "?"
            let wd = ScorePy.truthy(worst["day"]) ? ScorePy.str(worst["day"]) : "?"
            patterns.append("Best day \(bd) at \(sc(best)); worst \(wd) at \(sc(worst))")
            let hours = rowsIn.filter { ScorePy.nz(ScorePy.num($0["worked_s"]), 0) != 0 }
            if !hours.isEmpty {
                let total = hours.reduce(0.0) { $0 + ScorePy.num($1["worked_s"])! }
                patterns.append("\(hm(total)) of work across the week, \(hm(total / Double(hours.count))) a day")
            }
        }
        var by = OrderedTally()
        for d in rowsIn {
            for row in ScorePy.list(d["leaks"]) {
                by.add(ScorePy.strRaw(ScorePy.at(row, 0)), ScorePy.nz(ScorePy.num(ScorePy.at(row, 1)), 0))
            }
        }
        for (what, secs) in by.sortedDesc().prefix(weeklyRowsMax) { leaksOut.append("\(what) — \(hm(secs)) across the week") }
        if let first = leaksOut.first {
            change.append("Cut the biggest leak in half: \(first.components(separatedBy: " — ")[0])")
        }
        change.append("Start the first block before anything else opens")
        return .object(["patterns": .array(patterns.prefix(weeklyRowsMax).map { .string($0) }),
                        "leaks": .array(leaksOut.map { .string($0) }), "change": .array(change.map { .string($0) }),
                        "best_hours": "".scoreJSON, "worst_hours": "".scoreJSON, "from": "fallback".scoreJSON])
    }

    public static func weeklyParagraphs(_ weekly: JSONValue?) -> [DayParagraph] {
        guard let w = ScorePy.obj(weekly) else { return [] }
        var out = [P(weeklyHeading, style: "HEADING_1"), P("The last seven days, read together.")]
        for (title, key) in [("Patterns", "patterns"), ("What leaked, every day", "leaks"), ("Change this next week", "change")] {
            let rs = ScorePy.list(w[key])
            if rs.isEmpty { continue }
            out.append(P(title, style: "HEADING_2"))
            out += rs.map { P(ScorePy.strRaw($0), bullet: true) }
        }
        for (label, key) in [("Your best hours: ", "best_hours"), ("Your worst hours: ", "worst_hours")] where ScorePy.truthy(w[key]) {
            out.append(P(label + ScorePy.str(w[key]), bold: ScorePy.len(label) - 1))
        }
        return out
    }

    // ------------------------------------------------------------ the page

    /// `doc_paragraphs`: the whole page, top down.
    public static func docParagraphs(_ report: JSONValue, tz: TimeZone?, updatedAt: Double? = nil) -> [DayParagraph] {
        let t = ScorePy.obj(report["totals"]) ?? [:]
        let verdict = ScorePy.str(report["verdict"])
        var out = [P("\(verdict) — \(ScorePy.strRaw(report["score"])) out of 1000", style: "TITLE", bold: ScorePy.len(verdict)),
                   P("\(ScorePy.str(report["why"])) It was \(ScorePy.str(report["rank"]?["line"]))."),]
        if !ScorePy.truthy(report["final"]) {
            out.append(P("So far — this page is rewritten after every block and finished at 11:30 pm."))
        }
        out += hoursParagraphs(report["hours"])

        out.append(P("What you got done", style: "HEADING_1"))
        let blocks = ScorePy.list(report["blocks"])
        if blocks.isEmpty { out.append(P("No focus blocks were finished today.")) }
        for bv in blocks {
            guard let b = ScorePy.obj(bv) else { continue }
            let when = timeRange(Scoring.toTs(b["started_at"]), Scoring.toTs(b["ended_at"]), tz)
            let done = ScorePy.isTrue(b["completed"]) ? "" : " (stopped early)"
            var split = ""
            if let f = ScorePy.intValue(b["focus_score"]), let o = ScorePy.intValue(b["output_score"]) {
                split = " · focus \(f), output \(o)"
            }
            out.append(P("\(when) · \(ScorePy.strRaw(b["score"])) / 1000\(split)\(done)", style: "HEADING_2"))
            if ScorePy.truthy(b["balance_line"]) { out.append(P(ScorePy.rstrip(sentence(b["balance_line"], 120), ".") + ".")) }
            let ms = ScorePy.obj(b["milestones"]) ?? [:]
            if ScorePy.truthy(ms["total"]) {
                let reached = ScorePy.list(ms["reached"]), missed = ScorePy.list(ms["missed"])
                let line = Scoring.milestonesLine((reached + missed).map { ["text": $0] }, reached.map { ["text": $0] })
                if !line.isEmpty { out.append(P(line)) }
            }
            let (goal, inferred) = blockGoal(b)
            if !goal.isEmpty {
                let label = inferred ? "Goal (worked out from your screen): " : "Goal: "
                out.append(P(label + sentence(goal, 240), bold: ScorePy.len(label) - 1))
            }
            let was = ScorePy.rstrip(sentence(b["original_goal"], 240), ".")
            if !was.isEmpty && ScorePy.ws(was.lowercased()) != ScorePy.ws(goal.lowercased()) {
                out.append(P("You started this block on \"\(was)\" and moved to what is above — "
                             + "scored against what you actually did."))
            }
            out += blockBullets(bv).map { P($0, bullet: true) }
            if let got = ScorePy.num(b["goal_achieved"]) {
                out.append(P("Got \(ScorePy.iround(ScorePy.clamp(got) * 100))% of the way to that goal."))
            }
            if ["opus", "gemini"].contains(ScorePy.str(b["advice_from"])) && ScorePy.truthy(b["advice"]) {
                out.append(P("Work smarter: " + sentence(b["advice"], 600), bold: 13))
            }
        }

        out.append(P("Totals", style: "HEADING_1"))
        out.append(P("Blocks: \(ScorePy.strRaw(t["done"])) finished of \(ScorePy.strRaw(t["started"])) started", bullet: true))
        let hours = hoursGoalLine(ScorePy.num(t["in_blocks_s"]) ?? 0, goalHours: report["goal_hours"])
        if !hours.isEmpty { out.append(P("Hours worked: \(hours)", bullet: true)) }
        out.append(P("Focused time: \(hm(ScorePy.num(t["focused_s"]))) (of \(hm(ScorePy.num(t["in_blocks_s"]))) in blocks)", bullet: true))
        if let avg = t["avg"], avg != .null {
            out.append(P("Average block: \(ScorePy.strRaw(avg)) · best: \(ScorePy.strRaw(t["best"]))", bullet: true))
        }
        for line in [periodsSentence(report["hours"], totals: .object(t)), monoSentence(report["mono"]),
                     attentionSentence(report["attention"])] where !line.isEmpty {
            out.append(P(line, bullet: true))
        }

        out += goalsParagraphs(report["blocks"])
        out += weeklyParagraphs(report["weekly"])

        out.append(P("Tomorrow: \(ScorePy.str(report["tomorrow"]))", bold: 9))
        if let updatedAt, updatedAt != 0 {
            out.append(P("Updated \(clock(updatedAt, tz)). 1000 is an elite performer's best; 700 is strong."))
        }
        return out
    }

    /// Plain text of the page (for logs and tests).
    public static func docText(_ paragraphs: [DayParagraph]) -> String {
        paragraphs.map { ($0.bullet ? "• " : "") + $0.text }.joined(separator: "\n")
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    /// The same page as HTML.
    public static func docHTML(_ paragraphs: [DayParagraph]) -> String {
        let tags = ["TITLE": "h1", "HEADING_1": "h2", "HEADING_2": "h3"]
        var out = ["<html><body>"]
        var inList = false
        for p in paragraphs {
            let escB = htmlEscape(ScorePy.cut(p.text, p.bold)), escR = htmlEscape(ScorePy.drop(p.text, p.bold))
            let inner = (escB.isEmpty ? "" : "<b>\(escB)</b>") + escR
            if p.bullet {
                if !inList { out.append("<ul>"); inList = true }
                out.append("<li>\(inner)</li>")
                continue
            }
            if inList { out.append("</ul>"); inList = false }
            let tag = tags[p.style] ?? "p"
            out.append("<\(tag)>\(inner)</\(tag)>")
        }
        if inList { out.append("</ul>") }
        out.append("</body></html>")
        return out.joined(separator: "\n")
    }

    /// The page as Markdown, for the app's own day report: TITLE `#`, HEADING_1 `##`, HEADING_2 `###`,
    /// bullets `- `, the bold lead in `**…**`. Blank lines between blocks; consecutive bullets stay a list.
    public static func markdown(_ paragraphs: [DayParagraph]) -> String {
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s {
                if "\\*_`[]#<>".contains(ch) { out.append("\\") }
                out.append(ch)
            }
            return out
        }
        var lines: [String] = []
        var prevBullet = false
        for p in paragraphs {
            let lead = ScorePy.strip(ScorePy.cut(p.text, p.bold)), rest = ScorePy.drop(p.text, p.bold)
            let gap = ScorePy.len(ScorePy.cut(p.text, p.bold)) - ScorePy.len(ScorePy.rstrip(ScorePy.cut(p.text, p.bold)))
            let body = lead.isEmpty ? esc(p.text) : "**\(esc(lead))**" + String(repeating: " ", count: gap) + esc(rest)
            let prefix = ["TITLE": "# ", "HEADING_1": "## ", "HEADING_2": "### "][p.style] ?? ""
            let line = p.bullet ? "- " + body : prefix + body
            if !lines.isEmpty && !(p.bullet && prevBullet) { lines.append("") }
            lines.append(line)
            prevBullet = p.bullet
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

extension String {
    /// A JSON string value (internal sugar for the day report).
    var scoreJSON: JSONValue { .string(self) }
}
