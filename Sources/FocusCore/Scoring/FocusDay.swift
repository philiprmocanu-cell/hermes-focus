import Foundation

// One day of focus blocks, written up (brain/focus_day.py): the day score against top performers,
// the verdict, the rank against his own recent days, where the hours went, and the page itself as
// plain paragraphs (FocusDayDoc.swift). Pure: no model calls, no Google; where the Python writes a
// Google Doc only the paragraph/text/HTML builders are ported, and storage is someone else's job.
//
// `report(...)` returns the same dictionary `day_report` returns (as `JSONValue`), so the page
// builders read a stored report exactly like a fresh one.

public enum FocusDay {
    public static let eliteFocusedMin = 240.0
    public static let fullFocusScore = 700.0
    public static let qualityTop = 850.0
    /// DAY_WEIGHTS, in the Python order.
    public static let dayWeights: [(String, Double)] = [("volume", 0.45), ("substance", 0.35), ("quality", 0.20)]
    public static let proudAt = 700
    public static let solidAt = 450
    public static let proudPersonalAt = 600
    public static let proudPersonalMinDays = 5
    public static let historyDays = 14
    public static let verdicts = ["Proud", "Solid", "Under"]
    public static let maxBullets = 3
    public static let leakMinS = 60.0
    public static let staring = "Staring blankly at the screen"
    public static let lookingAway = "Looking away from the screen"

    public static let sessionGapS = 40.0 * 60
    public static let longBreakS = 15.0 * 60
    public static let minBreakS = 60.0
    public static let minRowS = 30.0
    public static let projectsMax = 5
    public static let sitesMax = 3
    static let activityLabels = [("making", "Making things (writing, coding, building)"),
                                 ("studying", "Studying and reading for the goal"),
                                 ("consuming", "Watching and scrolling"),
                                 ("other", "Something else")]
    static let eyeLabels = [("reading", "Reading the screen"), ("blank", "Staring blankly"),
                            ("away", "Looking away")]
    static let courseRe = ScorePy.regex(#"\b([A-Z]{2,5})[ -]?(\d{1,3}[A-Z]?)\b"#)
    static let courseTightRe = ScorePy.regex(#"\b([a-z]{2,4})(\d{2,3}[a-z]?)\b"#)
    static let properRe = ScorePy.regex(#"[A-Z][A-Za-z0-9]{2,}"#)
    static let workNouns: Set<String> = ["paper", "essay", "homework", "exam", "midterm", "final", "quiz", "lab",
                                         "project", "reading", "report", "assignment", "notes", "presentation",
                                         "discussion", "problems", "lecture", "slides"]
    static let notProjects: Set<String> = ["google", "docs", "doc", "chrome", "safari", "gmail", "mail", "slack",
                                           "notion", "obsidian", "xcode", "terminal", "vscode", "code", "pdf",
                                           "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                                           "sunday", "today", "tomorrow", "the", "and", "for", "write", "draft",
                                           "read", "finish", "keep", "work", "working", "review", "study", "plan"]

    public static let goalDone = 0.9
    public static let monoTight = 0.8
    public static let monoLoose = 0.55
    public static let switchCalm = 0.5
    public static let switchBusy = 1.5

    // ------------------------------------------------------------ small helpers

    /// '2 h 5 min', '45 min', '0 min'.
    public static func hm(_ seconds: Double?) -> String {
        let m = ScorePy.iround(max(0.0, seconds ?? 0) / 60.0)
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h" + (m % 60 != 0 ? " \(m % 60) min" : "")
    }

    static func clock(_ ts: Double, _ tz: TimeZone?) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? .current
        let d = Date(timeIntervalSince1970: ts.rounded(.down))
        let hour = cal.component(.hour, from: d), minute = cal.component(.minute, from: d)
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h):\(String(format: "%02d", minute)) \(hour < 12 ? "am" : "pm")"
    }

    /// '9:05–9:30 am', '11:40 am–12:05 pm'.
    public static func timeRange(_ start: Double, _ end: Double, _ tz: TimeZone?) -> String {
        if start == 0 && end == 0 { return "" }
        let a = clock(start != 0 ? start : end, tz), b = clock(end != 0 ? end : start, tz)
        if a.suffix(2) == b.suffix(2) { return "\(a.dropLast(3))–\(b)" }
        return "\(a)–\(b)"
    }

    static func isoDay(_ day: String) -> DateComponents? {
        let p = day.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// '2026-09-21 — Monday'.
    public static func docTitle(_ day: String) -> String {
        guard let c = isoDay(day), let date = utcCal.date(from: c) else { return day }
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return "\(day) — \(names[utcCal.component(.weekday, from: date) - 1])"
    }

    /// `_sentence`: one tidy sentence, capitalised, ending in punctuation.
    static func sentence(_ text: JSONValue?, _ n: Int = 200) -> String { sentence(ScorePy.str(text), n) }

    static func sentence(_ text: String, _ n: Int = 200) -> String {
        var t = ScorePy.strip(ScorePy.cut(ScorePy.ws(text), n))
        if let last = ScorePy.lastScalar(t), !".!?".contains(last) { t += "." }
        return t.isEmpty ? "" : ScorePy.capFirst(t)
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (10...20).contains(n % 100) ? "th" : ([1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th")
        return "\(n)\(suffix)"
    }

    // ------------------------------------------------------------ per block

    public static func workedS(_ block: JSONValue) -> Double { workedS(ScorePy.obj(block) ?? [:]) }

    static func workedS(_ block: ScoreObj) -> Double {
        let planned = max(60.0, ScorePy.nz(ScorePy.num(block["planned_s"]), 1500))
        let comp = ScorePy.num(block["completion"]) ?? Scoring.completionOf(block)
        return planned * ScorePy.clamp(comp)
    }

    static func focusedS(_ block: ScoreObj) -> Double {
        workedS(block) * ScorePy.clamp(ScorePy.nz(ScorePy.num(block["score"]), 0) / fullFocusScore)
    }

    /// 1–3 bullets from the screenshot verdicts when no model wrote any.
    public static func fallbackBullets(_ block: JSONValue) -> [String] {
        let b = ScorePy.obj(block) ?? [:]
        var on: [String] = [], off: [String] = []
        for fr in ScorePy.dicts(b["frames"]) {
            let what = ScorePy.ws(ScorePy.str(fr["doing"]))
            if what.isEmpty { continue }
            if let g = ScorePy.num(fr["on_goal"]), g < 0.4 { off.append(what) } else { on.append(what) }
        }
        var out: [String] = []
        var seen = Set<String>()
        for what in on {
            let key = Scoring.norm(what)
            if !seen.contains(key) {
                seen.insert(key)
                out.append(ScorePy.rstrip(sentence(what, 90), "."))
            }
            if out.count == maxBullets { break }
        }
        if !out.isEmpty { return out }
        let goal = ScorePy.cut(ScorePy.ws(ScorePy.str(b["goal"])), 80)
        if let first = off.first { return ["Mostly off the goal: \(first)"] }
        return [goal.isEmpty ? "Worked, but the screens showed nothing specific" : "Worked on \(goal)"]
    }

    public static func cleanBullets(_ items: JSONValue?) -> [String] {
        var out: [String] = []
        for it in ScorePy.list(items) {
            let t = ScorePy.rstrip(ScorePy.strip(ScorePy.strip(ScorePy.cut(ScorePy.ws(ScorePy.str(it)), 140)), " -•*"), ".")
            if !t.isEmpty { out.append(ScorePy.capFirst(t)) }
            if out.count == maxBullets { break }
        }
        return out
    }

    public static func blockBullets(_ block: JSONValue) -> [String] {
        let c = cleanBullets(block["done"])
        return c.isEmpty ? fallbackBullets(block) : c
    }

    static func part(_ block: ScoreObj, _ key: String) -> Double? {
        guard let p = ScorePy.obj(ScorePy.obj(block["parts"])?[key]) else { return nil }
        return ScorePy.num(p["value"])
    }

    // ------------------------------------------------------------ the day

    public static func dayTotals(_ blocks: JSONValue?, startedIds: [JSONValue] = []) -> JSONValue {
        .object(totals(scoredRows(blocks), startedIds))
    }

    static func scoredRows(_ blocks: JSONValue?) -> [ScoreObj] {
        ScorePy.dicts(blocks).filter { ScorePy.intValue($0["score"]) != nil }
    }

    static func totals(_ rows: [ScoreObj], _ startedIds: [JSONValue]) -> ScoreObj {
        var ids = Set(rows.map { ScorePy.strRaw($0["block_id"]) })
        for i in startedIds where ScorePy.truthy(i) { ids.insert(ScorePy.strRaw(i)) }
        let done = rows.filter { ScorePy.isTrue($0["completed"]) || ScorePy.nz(ScorePy.num($0["completion"]), 0) >= 0.999 }.count
        let inBlocks = rows.reduce(0.0) { $0 + workedS($1) }
        let focused = rows.reduce(0.0) { $0 + focusedS($1) }
        let scores = rows.map { ScorePy.intValue($0["score"])! }
        var eyeW = 0.0, eyeRead = 0.0, eyeBlank = 0.0, eyeAway = 0.0
        for b in rows {
            if let e = Scoring.eyeGood(b["eye"]) {
                let w = workedS(b)
                eyeW += w
                eyeRead += (ScorePy.num(e["reading"]) ?? 0) * w
                eyeBlank += (ScorePy.num(e["blank"]) ?? 0) * w
                eyeAway += (ScorePy.num(e["away"]) ?? 0) * w
            }
        }
        return ["blocks": ScorePy.n(rows.count), "done": ScorePy.n(done), "started": ScorePy.n(max(ids.count, rows.count)),
                "in_blocks_s": .number(inBlocks), "focused_s": .number(focused),
                "avg": scores.isEmpty ? .null : ScorePy.n(ScorePy.iround(Double(scores.reduce(0, +)) / Double(scores.count))),
                "best": scores.isEmpty ? .null : ScorePy.n(scores.max()!),
                "eye": eyeW != 0 ? .object(["reading": .number(eyeRead / eyeW), "blank": .number(eyeBlank / eyeW),
                                            "away": .number(eyeAway / eyeW), "seconds": .number(eyeW)]) : .null]
    }

    /// on-goal x output per block, weighted by time worked (when the coach cannot be asked).
    public static func fallbackSubstance(_ blocks: JSONValue?) -> Double { fallbackSubstance(scoredRows(blocks)) }

    static func fallbackSubstance(_ rows: [ScoreObj]) -> Double {
        var num = 0.0, den = 0.0
        for b in rows {
            guard let on = part(b, "on_goal"), let out = part(b, "output") else { continue }
            let w = workedS(b)
            num += ScorePy.clamp(on) * ScorePy.clamp(out) * w
            den += w
        }
        return den != 0 ? ScorePy.clamp(num / den) : 0
    }

    public static func dayParts(_ totals: JSONValue, substance: Double) -> JSONValue {
        let t = ScorePy.obj(totals) ?? [:]
        let volume = ScorePy.clamp((ScorePy.num(t["focused_s"]) ?? 0) / 60.0 / eliteFocusedMin)
        let started = ScorePy.num(t["started"]) ?? 0
        let finish = started != 0 ? (ScorePy.num(t["done"]) ?? 0) / started : 0
        let quality = ScorePy.clamp(ScorePy.nz(ScorePy.num(t["avg"]), 0) / qualityTop) * (0.7 + 0.3 * ScorePy.clamp(finish))
        return .object(["volume": .number(ScorePy.round(volume, 3)), "substance": .number(ScorePy.round(ScorePy.clamp(substance), 3)),
                        "quality": .number(ScorePy.round(quality, 3))])
    }

    public static func dayScore(_ parts: JSONValue) -> Int {
        var s = 0.0
        for (k, w) in dayWeights { s += w * log(max(ScorePy.num(parts[k]) ?? 0, 0.02)) }
        return max(1, min(1000, 1 + ScorePy.iround(999 * ScorePy.clamp(exp(s)))))
    }

    /// Where today sits among his own days of the last HISTORY_DAYS.
    public static func rankAmong(_ score: Int, day: String, history: JSONValue?) -> JSONValue {
        var lo = day
        if let c = isoDay(day), let d = utcCal.date(from: c),
           let back = utcCal.date(byAdding: .day, value: -(historyDays - 1), to: d) {
            let bc = utcCal.dateComponents([.year, .month, .day], from: back)
            lo = String(format: "%04d-%02d-%02d", bc.year!, bc.month!, bc.day!)
        }
        var earlier: [Int] = []
        for (k, v) in (ScorePy.obj(history) ?? [:]).sorted(by: { $0.key < $1.key }) {
            if lo <= k && k < day, let x = ScorePy.num(v) { earlier.append(Int(x.rounded(.towardZero))) }
        }
        let n = earlier.count + 1
        let rank = 1 + earlier.filter { $0 > score }.count
        let line: String
        if earlier.isEmpty {
            line = "the first day I've scored, so there is nothing to compare it with yet"
        } else if rank == 1 {
            line = n < historyDays ? "your best day of the last \(n)" : "your best day of the last \(historyDays)"
        } else if rank == n {
            line = "your weakest day of the last \(n)"
        } else {
            line = "your \(ordinal(rank)) best day of the last \(n)"
        }
        return .object(["rank": ScorePy.n(rank), "of": ScorePy.n(n), "earlier": ScorePy.n(earlier.count), "line": .string(line)])
    }

    public static func verdictFor(_ score: Int, rank: JSONValue) -> String {
        if score >= proudAt { return "Proud" }
        if ScorePy.num(rank["rank"]) == 1 && (ScorePy.num(rank["earlier"]) ?? 0) >= Double(proudPersonalMinDays)
            && score >= proudPersonalAt { return "Proud" }
        return score >= solidAt ? "Solid" : "Under"
    }

    /// {site or app: seconds} of one block's time in off-goal apps/sites.
    static func siteLeaks(_ block: ScoreObj) -> OrderedTally {
        var by = OrderedTally()
        let rows = Scoring.appRows(block["apps"])
        let serving = Scoring.servingSites(block["frames"])
        var offFrames = Set(ScorePy.dicts(block["frames"]).filter { fr in
            !Scoring.servesGoal(fr) && ScorePy.nz(ScorePy.num(fr["on_goal"]), 0) < 0.4
                && (ScorePy.truthy(fr["url"]) || ScorePy.truthy(fr["app"]))
        }.map { Scoring.siteKey($0) })
        offFrames.subtract(serving)
        let goal = ScorePy.str(block["goal"])
        for r in rows {
            let k = Scoring.siteKey(r.row)
            if serving.contains(k) { continue }
            if offFrames.contains(k) || Scoring.goalMatch(goal, r.row) == 0 { by.add(k, r.seconds) }
        }
        return by
    }

    /// [(what, seconds)] of the biggest time leaks, biggest first (at most three).
    public static func leaks(_ blocks: JSONValue?) -> [(String, Double)] { leaks(ScorePy.dicts(blocks)) }

    static func leaks(_ blocks: [ScoreObj]) -> [(String, Double)] {
        var by = OrderedTally()
        for b in blocks {
            for (k, v) in siteLeaks(b).items { by.add(k, v) }
            if let e = Scoring.eyeGood(b["eye"]) {
                let w = workedS(b)
                by.add(staring, (ScorePy.num(e["blank"]) ?? 0) * w)
                by.add(lookingAway, (ScorePy.num(e["away"]) ?? 0) * w)
            }
        }
        return Array(by.sortedDesc().filter { $0.1 >= leakMinS }.prefix(3))
    }

    // ------------------------------------------------------- where the hours went

    enum ProjectKey: Equatable {
        case known(String), course(String), proper(String), goal(Set<String>)
    }

    static func projectTexts(_ block: ScoreObj) -> [String] {
        let (goal, _) = blockGoal(block)
        return [ScorePy.ws(ScorePy.str(block["specific_goal"])), goal, ScorePy.ws(ScorePy.str(block["understood"])),
                ScorePy.ws(ScorePy.str(block["inferred_goal"])), ScorePy.ws(ScorePy.str(block["goal"]))].filter { !$0.isEmpty }
    }

    static func knownProject(_ texts: [String], _ known: [JSONValue]) -> String? {
        for name in known {
            let label = ScorePy.ws(ScorePy.str(name).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
            if ScorePy.len(label) < 3 { continue }
            let needle = Scoring.norm(label)
            for t in texts where !needle.isEmpty && Scoring.norm(t).contains(needle) {
                let first = ScorePy.cut(label, 1)
                let isUpper = first.unicodeScalars.first.map { $0.properties.isUppercase } ?? false
                return isUpper ? label : ScorePy.title(label)
            }
        }
        return nil
    }

    static func courseCode(_ texts: [String]) -> (String, String)? {
        for t in texts {
            guard let m = ScorePy.firstMatch(courseRe, t) ?? ScorePy.firstMatch(courseTightRe, t) else { continue }
            let code = "\(ScorePy.group(m, 1, in: t).uppercased()) \(ScorePy.group(m, 2, in: t).uppercased())"
            let rest = (t as NSString).substring(from: m.range.location + m.range.length)
            let after = Scoring.norm(rest).split(separator: " ").map(String.init)
            let noun = (after.first.map { workNouns.contains($0) } ?? false) ? after[0] : ""
            return (code, noun)
        }
        return nil
    }

    static func properName(_ texts: [String]) -> String? {
        for t in texts {
            for m in ScorePy.matches(properRe, t) {
                let word = ScorePy.group(m, 0, in: t)
                let before = ScorePy.rstrip((t as NSString).substring(to: m.range.location))
                guard let last = ScorePy.lastScalar(before), !".!?:;".contains(last) else { continue }
                if notProjects.contains(word.lowercased()) { continue }
                return word
            }
        }
        return nil
    }

    static func dayGoalWords(_ text: String) -> Set<String> {
        Set(Scoring.norm(text).split(separator: " ").map(String.init)
            .filter { ScorePy.len($0) > 2 && !Scoring.goalStop.contains($0) }.map(Scoring.stem))
    }

    static func projectOf(_ block: ScoreObj, _ known: [JSONValue]) -> (ProjectKey, String, String) {
        let texts = projectTexts(block)
        if let name = knownProject(texts, known) { return (.known(Scoring.norm(name)), name, "") }
        if let (code, noun) = courseCode(texts) { return (.course(code), code, noun) }
        if let proper = properName(texts) { return (.proper(proper.lowercased()), proper, "") }
        let first = texts.first ?? ""
        let label = texts.isEmpty ? "" : ScorePy.rstrip(sentence(Scoring.goalLabel(first, 6), 60), ".")
        return (.goal(dayGoalWords(first)), label.isEmpty ? "Unnamed work" : label, "")
    }

    /// [(label, seconds)] biggest first; near-identical goals share a line.
    static func byProject(_ blocks: [ScoreObj], _ known: [JSONValue]) -> [(String, Double)] {
        struct Group { var key: ProjectKey; var label: String; var seconds: Double; var nouns: [String] }
        var groups: [Group] = []
        for b in blocks {
            let (key, label, noun) = projectOf(b, known)
            let secs = workedS(b)
            var hit = groups.firstIndex { $0.key == key }
            if hit == nil, case .goal(let words) = key {
                for (i, g) in groups.enumerated() {
                    if case .goal(let gw) = g.key, !words.isEmpty, !gw.isEmpty {
                        let both = words.intersection(gw)
                        if Double(both.count) / Double(max(1, words.union(gw).count)) >= 0.5 { hit = i; break }
                    }
                }
            }
            if let i = hit {
                groups[i].seconds += secs
                groups[i].nouns.append(noun)
                if ScorePy.len(label) < ScorePy.len(groups[i].label) { groups[i].label = label }
            } else {
                groups.append(Group(key: key, label: label, seconds: secs, nouns: [noun]))
            }
        }
        let out: [(String, Double)] = groups.map { g in
            let nouns = g.nouns.filter { !$0.isEmpty }
            if !nouns.isEmpty && nouns.count == g.nouns.count && Set(nouns).count == 1 { return ("\(g.label) \(nouns[0])", g.seconds) }
            return (g.label, g.seconds)
        }
        return Array(stableDesc(out).prefix(projectsMax))
    }

    static func stableDesc(_ rows: [(String, Double)]) -> [(String, Double)] {
        rows.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map { $0.element }
    }

    static func modeShares(_ block: ScoreObj) -> [(String, Double)] {
        var counts = OrderedTally()
        for fr in ScorePy.dicts(block["frames"]) where Scoring.frameModes.contains(ScorePy.str(fr["mode"])) {
            counts.add(ScorePy.str(fr["mode"]), 1)
        }
        let n = counts.items.reduce(0.0) { $0 + $1.1 }
        return n != 0 ? counts.items.map { ($0.0, $0.1 / n) } : []
    }

    static func byActivity(_ blocks: [ScoreObj]) -> [(String, Double)] {
        var secs: [String: Double] = [:]
        for (k, _) in activityLabels { secs[k] = 0 }
        var unseen = 0.0
        for b in blocks {
            let w = workedS(b)
            let shares = modeShares(b)
            if shares.isEmpty { unseen += w; continue }
            for (mode, share) in shares { secs[mode, default: 0] += share * w }
        }
        var out = activityLabels.map { ($0.1, secs[$0.0] ?? 0) }
        if unseen != 0 { out.append(("No screens were judged", unseen)) }
        return stableDesc(out).filter { $0.1 >= minRowS }
    }

    static func byEyes(_ blocks: [ScoreObj]) -> ([(String, Double)], Double) {
        var secs: [String: Double] = ["reading": 0, "blank": 0, "away": 0]
        var watched = 0.0
        for b in blocks {
            guard let e = Scoring.eyeGood(b["eye"]) else { continue }
            let w = workedS(b)
            watched += w
            for (key, _) in eyeLabels { secs[key]! += (ScorePy.num(e[key]) ?? 0) * w }
        }
        return (eyeLabels.filter { secs[$0.0]! >= minRowS }.map { ($0.1, secs[$0.0]!) }, watched)
    }

    static func offGoalS(_ blocks: [ScoreObj]) -> Double {
        var total = 0.0
        for b in blocks {
            let seen = ScorePy.dicts(b["frames"]).compactMap { ScorePy.num($0["on_goal"]) }
            if !seen.isEmpty { total += workedS(b) * (Double(seen.filter { $0 < 0.4 }.count) / Double(seen.count)) }
        }
        return total
    }

    static func distractionS(_ blocks: [ScoreObj]) -> Double {
        blocks.reduce(0.0) { $0 + ScorePy.nz(ScorePy.num($1["distraction_s"]), 0) }
    }

    static func topSites(_ blocks: [ScoreObj]) -> [(String, Double)] {
        var by = OrderedTally()
        for b in blocks { for (k, v) in siteLeaks(b).items { by.add(k, v) } }
        return Array(by.sortedDesc().filter { $0.1 >= minRowS }.prefix(sitesMax))
    }

    public static func topSites(_ blocks: JSONValue?) -> [(String, Double)] { topSites(ScorePy.dicts(blocks)) }

    struct Breaks {
        var sessionS = 0.0, sessions = 0, short = (0, 0.0), long = (0, 0.0), skipped = 0
    }

    static func sessionsAndBreaks(_ blocks: [ScoreObj], _ events: [JSONValue]) -> Breaks {
        func startOf(_ b: ScoreObj) -> Double {
            let s = Scoring.toTs(b["started_at"])
            return s != 0 ? s : Scoring.toTs(b["ended_at"])
        }
        let rows = blocks.enumerated().sorted { a, b in
            startOf(a.element) != startOf(b.element) ? startOf(a.element) < startOf(b.element) : a.offset < b.offset
        }.map { $0.element }
        let evs = events.compactMap { ScorePy.obj($0) }
        let stops = evs.filter { $0["kind"] == .string("session_stopped") }.map { Scoring.toTs($0["at"]) }.sorted()
        var out = Breaks()
        var start: Double?, end: Double?
        for b in rows {
            let bStart = startOf(b)
            let e = Scoring.toTs(b["ended_at"])
            let bEnd = e != 0 ? e : bStart
            if bStart == 0 { continue }
            let gap = bStart - ScorePy.nz(end, bStart)
            let broke = stops.contains { s in end != nil && end! != 0 && end! <= s && s <= bStart }
            if end == nil || gap > sessionGapS || gap < 0 || broke {
                if let end, let start {
                    out.sessionS += max(0.0, end - start)
                    out.sessions += 1
                }
                start = bStart
            } else if gap >= minBreakS {
                if gap >= longBreakS { out.long.0 += 1; out.long.1 += gap } else { out.short.0 += 1; out.short.1 += gap }
            }
            end = max(bEnd, bStart)
        }
        if let end, let start {
            out.sessionS += max(0.0, end - start)
            out.sessions += 1
        }
        let skipped = evs.filter { $0["kind"] == .string("break_skipped") }.count
        out.skipped = skipped != 0 ? skipped : rows.filter { ScorePy.isTrue($0["after_skipped_break"]) }.count
        return out
    }

    static func pairs(_ rows: [(String, Double)]) -> JSONValue { .array(rows.map { ScorePy.pair($0.0, $0.1) }) }

    /// Everything the Hours section needs: one total, and where every minute of it went.
    static func hoursBreakdown(_ blocks: [ScoreObj], _ totals: ScoreObj, _ goalHours: JSONValue?,
                               _ projects: [JSONValue], _ events: [JSONValue]) -> ScoreObj {
        let worked = ScorePy.num(totals["in_blocks_s"]) ?? 0
        let g = ScorePy.num(goalHours)
        let br = sessionsAndBreaks(blocks, events)
        let (eyes, eyesS) = byEyes(blocks)
        let hasGoal = g != nil && g! != 0 && g! > 0
        return ["worked_s": .number(worked), "blocks": totals["blocks"] ?? .number(0), "focused_s": totals["focused_s"] ?? .number(0),
                "goal_hours": hasGoal ? .number(g!) : .null,
                "goal_pct": hasGoal ? ScorePy.n(ScorePy.iround(100 * worked / (g! * 3600))) : .null,
                "session_s": .number(br.sessionS), "sessions": ScorePy.n(br.sessions),
                "short_breaks": .array([ScorePy.n(br.short.0), .number(br.short.1)]),
                "long_breaks": .array([ScorePy.n(br.long.0), .number(br.long.1)]),
                "skipped_breaks": ScorePy.n(br.skipped),
                "projects": pairs(byProject(blocks, projects)), "activity": pairs(byActivity(blocks)),
                "eyes": pairs(eyes), "eyes_s": .number(eyesS), "off_goal_s": .number(offGoalS(blocks)),
                "distraction_s": .number(distractionS(blocks)), "sites": pairs(topSites(blocks))]
    }

    // ------------------------------------------------------------ how the day felt

    static func weightedPart(_ blocks: [ScoreObj], _ key: String, _ field: String = "value") -> (Double?, Double) {
        var num = 0.0, den = 0.0
        for b in blocks {
            guard let p = ScorePy.obj(ScorePy.obj(b["parts"])?[key]), let v = ScorePy.num(p[field]) else { continue }
            let w = ScorePy.nz(workedS(b), 1.0)
            num += v * w
            den += w
        }
        return (den != 0 ? num / den : nil, den)
    }

    static func monoAverage(_ blocks: [ScoreObj]) -> ScoreObj {
        let (value, seconds) = weightedPart(blocks, "mono")
        let (share, _) = weightedPart(blocks, "mono", "top_share")
        let (switches, _) = weightedPart(blocks, "mono", "switches_per_min")
        return ["value": ScorePy.n(value), "top_share": ScorePy.n(share), "switches_per_min": ScorePy.n(switches),
                "seconds": .number(seconds)]
    }

    static func attentionAverage(_ blocks: [ScoreObj]) -> ScoreObj {
        let (value, seconds) = weightedPart(blocks, "attention")
        return ["value": ScorePy.n(value), "seconds": .number(seconds)]
    }

    /// (what he finished, what he started and did not): one row per goal, (goal, progress?, seconds).
    static func goalsToday(_ blocks: [ScoreObj]) -> (done: [(String, Double?, Double)], open: [(String, Double?, Double)]) {
        var rows: [String: (String, Double?, Double)] = [:]
        var order: [String] = []
        for b in blocks where ScorePy.intValue(b["score"]) != nil {
            let goal = ScorePy.rstrip(sentence(blockGoal(b).0, 240), ".")
            if goal.isEmpty { continue }
            let key = ScorePy.ws(goal.lowercased())
            var got = ScorePy.num(b["goal_achieved"])
            if got == nil && ScorePy.isTrue(b["goal_reached"]) { got = 1.0 }
            got = got.map { ScorePy.clamp($0) }
            if rows[key] == nil {
                rows[key] = (goal, got, 0)
                order.append(key)
            } else {
                let old = rows[key]!.1
                rows[key]!.1 = old == nil ? got : (got == nil ? old : max(old!, got!))
            }
            rows[key]!.2 += workedS(b)
        }
        var done: [(String, Double?, Double)] = [], open: [(String, Double?, Double)] = []
        for key in order {
            let r = rows[key]!
            if let g = r.1, g >= goalDone { done.append(r) } else { open.append(r) }
        }
        return (done, open)
    }

    static func goalsJSON(_ g: (done: [(String, Double?, Double)], open: [(String, Double?, Double)])) -> JSONValue {
        func rows(_ xs: [(String, Double?, Double)]) -> JSONValue {
            .array(xs.map { .array([.string($0.0), ScorePy.n($0.1), .number($0.2)]) })
        }
        return .array([rows(g.done), rows(g.open)])
    }

    /// (the goal the block was judged against, whether it was worked out from the screen).
    static func blockGoal(_ block: ScoreObj) -> (String, Bool) {
        let spec = ScorePy.ws(ScorePy.str(block["specific_goal"]))
        if !spec.isEmpty { return (spec, false) }
        let inferred = ScorePy.ws(ScorePy.str(block["inferred_goal"]))
        if !inferred.isEmpty && Scoring.needsInferredGoal(block["goal"]) { return (inferred, true) }
        let u = ScorePy.truthy(block["understood"]) ? block["understood"] : block["goal"]
        return (ScorePy.ws(ScorePy.str(u)), false)
    }

    public static func blockGoal(_ block: JSONValue) -> (goal: String, inferred: Bool) {
        let (g, i) = blockGoal(ScorePy.obj(block) ?? [:])
        return (g, i)
    }

    static func tomorrowLine(_ totals: ScoreObj, _ leakRows: [(String, Double)], _ blocks: [ScoreObj]) -> String {
        if (ScorePy.num(totals["done"]) ?? 0) < 4 {
            return "Get at least four blocks done tomorrow — start the first one before you "
                + "open anything else."
        }
        if let site = leakRows.first(where: { $0.0 != staring && $0.0 != lookingAway }), site.1 >= 5 * 60 {
            return "Close \(site.0) before your first block tomorrow — it cost you \(hm(site.1)) today."
        }
        if let eye = ScorePy.obj(totals["eye"]), (ScorePy.num(eye["blank"]) ?? 0) >= 0.2 {
            return "When the words stop going in, stand up for a minute instead of staring — "
                + "you blanked out for a good part of today."
        }
        if ScorePy.nz(ScorePy.num(totals["avg"]), 0) < 600 {
            var worst: ScoreObj?
            for b in blocks {
                guard let s = ScorePy.intValue(b["score"]) else { continue }
                if worst == nil || s < ScorePy.intValue(worst!["score"])! { worst = b }
            }
            if let worst, ScorePy.truthy(worst["advice"]) { return sentence(worst["advice"], 200) }
        }
        return "Same again tomorrow — start at the same time and do one more block."
    }

    static func defaultWhy(_ totals: ScoreObj, _ verdict: String) -> String {
        let focused = hm(ScorePy.num(totals["focused_s"]))
        let n = ScorePy.intValue(totals["done"]) ?? 0
        let blocks = "\(n) finished block\(n != 1 ? "s" : "")"
        if verdict == "Proud" { return "\(focused) of real focused work across \(blocks) — that is a top performer's day." }
        if verdict == "Solid" {
            return "\(focused) of focused work across \(blocks) — good, but a top performer's day "
                + "is about four hours."
        }
        return "Only \(focused) of focused work across \(blocks) — a top performer's day is about "
            + "four hours."
    }

    // ------------------------------------------------------------ the report

    /// `day_report`: everything the page, the email and the voice need about one day.
    public static func report(day: String, blocks: JSONValue?, startedIds: [JSONValue] = [],
                              history: JSONValue? = nil, judge: JSONValue? = nil, final: Bool = false,
                              goalHours: JSONValue? = nil, projects: [JSONValue] = [], events: [JSONValue] = [],
                              claude: [JSONValue] = [], coach: JSONValue? = nil, weekly: JSONValue? = nil,
                              modes: [JSONValue] = [], board: JSONValue? = nil) -> JSONValue {
        let rows = scoredRows(blocks).enumerated().sorted { a, b in
            let ta = startTs(a.element), tb = startTs(b.element)
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map { $0.element }
        let tot = totals(rows, startedIds)
        let j = ScorePy.obj(judge) ?? [:]
        let sub = ScorePy.num(j["substance"])
        let substance = sub.map { ScorePy.clamp($0) } ?? fallbackSubstance(rows)
        let parts = dayParts(.object(tot), substance: substance)
        let score = dayScore(parts)
        let rank = rankAmong(score, day: day, history: history ?? .object([:]))
        let verdict = verdictFor(score, rank: rank)
        let why = ScorePy.truthy(j["why"]) ? sentence(j["why"], 220) : defaultWhy(tot, verdict)
        let leakRows = leaks(rows)
        let tomorrow = ScorePy.truthy(j["tomorrow"]) ? sentence(j["tomorrow"], 200) : tomorrowLine(tot, leakRows, rows)
        return .object([
            "day": .string(day), "title": .string(docTitle(day)), "final": .bool(final), "score": ScorePy.n(score),
            "verdict": .string(verdict), "why": .string(why), "rank": rank, "parts": parts, "totals": .object(tot),
            "blocks": .array(rows.map { .object($0) }), "leaks": pairs(leakRows), "tomorrow": .string(tomorrow),
            "judged_by": .string(sub != nil ? "model" : "screens"),
            "goal_hours": ScorePy.n(ScorePy.num(goalHours)),
            "mono": .object(monoAverage(rows)), "attention": .object(attentionAverage(rows)),
            "goals": goalsJSON(goalsToday(rows)),
            "claude": .array(claude.filter { ScorePy.isDict($0) }),
            "coach": ScorePy.isDict(coach) ? coach! : .null,
            "modes": .array(modes.filter { ScorePy.isDict($0) }),
            "board": ScorePy.isDict(board) ? board! : .object([:]),
            "weekly": ScorePy.isDict(weekly) ? weekly! : .null,
            "hours": .object(hoursBreakdown(rows, tot, goalHours, projects, events)),
        ])
    }

    static func startTs(_ b: ScoreObj) -> Double {
        let s = Scoring.toTs(b["started_at"])
        return s != 0 ? s : Scoring.toTs(b["ended_at"])
    }

    /// One sentence for the voice and the email.
    public static func verdictLine(_ report: JSONValue) -> String {
        let soFar = ScorePy.truthy(report["final"]) ? "" : " so far"
        return "Today\(soFar): \(ScorePy.str(report["verdict"])), \(ScorePy.strRaw(report["score"])) out of 1000 — "
            + "\(ScorePy.str(report["rank"]?["line"])). \(ScorePy.str(report["why"]))"
    }

    /// '1 h 40 min of your 4-hour goal (42%)'.
    public static func hoursGoalLine(_ worked: Double, goalHours: JSONValue?) -> String {
        guard let g = ScorePy.num(goalHours), g > 0 else { return "" }
        let pct = ScorePy.iround(100 * max(0.0, worked) / (g * 3600))
        return "\(hm(worked)) of your \(ScorePy.fmt(g, "%g"))-hour goal (\(pct)%)"
    }

    /// One line for the evening email and for when he asks how he is doing.
    public static func hoursSentence(_ h: JSONValue?) -> String {
        guard let h = ScorePy.obj(h), ScorePy.truthy(h["worked_s"]) else { return "" }
        let n = ScorePy.intValue(h["blocks"]) ?? 0
        var line = "\(hm(ScorePy.num(h["worked_s"]))) of work in \(n) block\(n != 1 ? "s" : "")"
        if let pct = ScorePy.intValue(h["goal_pct"]) {
            line += " — \(pct)% of your \(ScorePy.fmt(ScorePy.num(h["goal_hours"]) ?? 0, "%g"))-hour goal"
        }
        line += "."
        if let best = ScorePy.list(h["projects"]).first {
            line += " Most of it went to \(ScorePy.str(ScorePy.at(best, 0))) (\(hm(ScorePy.num(ScorePy.at(best, 1)))))."
        }
        return line
    }
}
