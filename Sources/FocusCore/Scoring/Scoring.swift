import Foundation

// The score for one focus block, ported from brain/focus.py so Hermes Focus can score with no
// server. Same constants, same rules, same output keys; the module docstring of brain/focus.py is
// the spec (two sub-scores 1..1000 from a geometric mean of parts with SCORE_CURVE, scaled by
// completion, then caps; with a rubric the balance, milestones and the hyperfocus ceiling).
//
// Blocks, frames and rubrics come in as `JSONValue` (the brain's wire shape) and the result goes
// out as `JSONValue` with exactly the Python keys, so stored blocks, fixtures and the day report
// all read the same thing. Parity with the Python is checked by Tests/Fixtures/scoring (generated
// by scripts/fixtures_scoring.py).

public enum Scoring {
    // ------------------------------------------------------------ constants (focus.py)

    /// FOCUS_WEIGHTS, in the Python order (the order matters for the float sums).
    public static let focusWeights: [(String, Double)] = [("on_goal", 0.60), ("mono", 0.40)]
    /// OUTPUT_WEIGHTS, in the Python order.
    public static let outputWeights: [(String, Double)] = [("progress", 0.35), ("quality", 0.25),
                                                           ("smart", 0.15), ("engaged", 0.25)]
    public static let scoreCurve = 1.6
    public static let hyperfocusShare = 0.95
    public static let hyperfocusCap = 940
    public static let onTaskFrame = 0.5
    public static let consumingWorking = 0.35
    public static let consumingCap = 450
    public static let idleHands = 0.15
    public static let idleScreens = 0.5
    public static let idleCap = 350
    public static let unseenCap = 750
    public static let readingFullCredit = 0.6
    public static let unverifiedReading = 0.6
    public static let readingInput = 0.25
    public static let relevantOnGoal = 0.6
    public static let readingEvidence = 0.35
    public static let eyeMinSamples = 20.0
    public static let switchPenalty = 0.20
    public static let activeFullCredit = 0.75
    public static let neutral = 0.5
    public static let engagedBlend = (working: 0.5, handsOn: 0.5)
    public static let nothingWorking = 0.15
    public static let nothingHands = 0.05

    public static let distractOnGoal = 0.3
    public static let frameFreshS = 4.0 * 60
    public static let tickGapS = 150.0
    public static let callAfterS = 6 * 60

    public static let distractionHosts = ["youtube.com", "instagram.com", "tiktok.com", "twitter.com", "x.com",
                                          "reddit.com", "facebook.com", "netflix.com", "twitch.tv",
                                          "news.ycombinator.com", "9gag.com", "hulu.com", "primevideo.com",
                                          "disneyplus.com", "snapchat.com"]
    public static let distractionApps = ["messages", "whatsapp", "discord", "tv", "music", "spotify", "photos",
                                         "facetime", "telegram", "steam"]
    static let stopWords: Set<String> = ["the", "and", "for", "with", "work", "working", "on", "my", "a", "an",
                                         "to", "of", "in", "at", "do", "get", "some", "this", "that", "finish",
                                         "start", "make", "more"]
    static let urlHost = ScorePy.regex(#"https?://([^/:?#]+)"#)

    // ------------------------------------------------------------ small readers

    /// Epoch seconds from epoch seconds, epoch milliseconds or an ISO string; 0 when none of those.
    public static func toTs(_ value: JSONValue?) -> Double {
        guard let value else { return 0 }
        switch value {
        case .null, .bool, .array, .object: return 0
        case .number(let v): return v > 1e11 ? v / 1000 : v
        case .string(let raw):
            if raw.isEmpty { return 0 }
            let s = ScorePy.strip(raw)
            if let v = ScorePy.parseFloat(s) { return v > 1e11 ? v / 1000 : v }
            return isoSeconds(s.replacingOccurrences(of: "Z", with: "+00:00")) ?? 0
        }
    }

    public static func toTs(_ value: Double) -> Double { toTs(.number(value)) }

    static let isoPattern = ScorePy.regex(
        #"^(\d{4})-(\d{2})-(\d{2})(?:.(\d{2})(?::(\d{2})(?::(\d{2})(?:\.(\d{3}|\d{6}))?)?)?)?(?:([+-])(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{6}))?)?)?$"#)

    /// `datetime.fromisoformat` (Python 3.9 forms), naive read as UTC.
    static func isoSeconds(_ s: String) -> Double? {
        guard let m = ScorePy.firstMatch(isoPattern, s) else { return nil }
        func g(_ i: Int) -> String { ScorePy.group(m, i, in: s) }
        guard let y = Int(g(1)), let mo = Int(g(2)), let d = Int(g(3)) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        c.hour = Int(g(4)) ?? 0; c.minute = Int(g(5)) ?? 0; c.second = Int(g(6)) ?? 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let hh = c.hour!, mm = c.minute!, ss = c.second!
        guard (1...12).contains(mo), (0...23).contains(hh), (0...59).contains(mm), (0...59).contains(ss) else { return nil }
        guard let date = cal.date(from: c), cal.component(.day, from: date) == d else { return nil }
        var t = date.timeIntervalSince1970
        let frac = g(7)
        if !frac.isEmpty {
            let fv: Double = Double(frac) ?? 0
            let scale: Double = pow(10.0, Double(frac.count))
            t += fv / scale
        }
        if !g(8).isEmpty {
            let oh: Int = Int(g(9)) ?? 0
            let om: Int = Int(g(10)) ?? 0
            let os: Int = Int(g(11)) ?? 0
            let off = Double(oh * 3600 + om * 60 + os)
            t -= g(8) == "-" ? -off : off
        }
        return t
    }

    public static func hostOf(_ url: String) -> String {
        guard let m = ScorePy.firstMatch(urlHost, url) else { return "" }
        let h = ScorePy.group(m, 1, in: url).lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The thing he was in: the website for a browser, else the app.
    static func siteKey(_ row: ScoreObj) -> String {
        let h = hostOf(ScorePy.str(row["url"]))
        if !h.isEmpty { return h }
        let a = ScorePy.cut(ScorePy.ws(ScorePy.str(row["app"])), 40)
        return a.isEmpty ? "?" : a
    }

    public static func siteKey(_ row: JSONValue) -> String { siteKey(ScorePy.obj(row) ?? [:]) }

    public static func isDistraction(_ row: JSONValue?) -> Bool { isDistraction(ScorePy.obj(row) ?? [:]) }
    public static func completionOf(_ block: JSONValue) -> Double { completionOf(ScorePy.obj(block) ?? [:]) }
    public static func servesGoal(_ frame: JSONValue?) -> Bool { servesGoal(ScorePy.obj(frame)) }

    static func goalWords(_ goal: String) -> Set<String> {
        Set(ScorePy.asciiWords(goal.lowercased()).filter { $0.count > 2 && !stopWords.contains($0) })
    }

    static func isDistraction(_ row: ScoreObj) -> Bool {
        let host = hostOf(ScorePy.str(row["url"]))
        if !host.isEmpty, distractionHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        let app = ScorePy.strip(ScorePy.str(row["app"])).lowercased()
        return distractionApps.contains(app)
    }

    /// 1 when the app/title/site names the goal, 0 for a known distraction, NEUTRAL otherwise.
    static func goalMatch(_ goal: String, _ row: ScoreObj) -> Double {
        if isDistraction(row) { return 0 }
        let words = goalWords(goal)
        let text = ["app", "title", "url"].map { ScorePy.str(row[$0]) }.joined(separator: " ").lowercased()
        let have = Set(ScorePy.asciiWords(text))
        if !words.isEmpty && !words.isDisjoint(with: have) { return 1 }
        return neutral
    }

    /// Every judged value for `key`, leaving out pending frames and lone detours.
    static func frameValues(_ frames: [ScoreObj], _ key: String) -> [Double] {
        frames.compactMap { f in
            guard !ScorePy.truthy(f["pending"]), !ScorePy.truthy(f["detour"]),
                  let v = ScorePy.num(f[key]) else { return nil }
            return ScorePy.clamp(v)
        }
    }

    struct AppRow {
        var row: ScoreObj
        var seconds: Double
    }

    static func appRows(_ apps: JSONValue?) -> [AppRow] {
        ScorePy.dicts(apps).compactMap { a in
            let secs = ScorePy.nz(ScorePy.num(a["seconds"]), 0)
            guard secs > 0 else { return nil }
            var r = a
            r["seconds"] = .number(secs)
            return AppRow(row: r, seconds: secs)
        }
    }

    static func timeBySite(_ rows: [AppRow]) -> OrderedTally {
        var by = OrderedTally()
        for r in rows { by.add(siteKey(r.row), r.seconds) }
        return by
    }

    static func singleAppPart(_ apps: JSONValue?, _ switches: JSONValue?, _ workedS: Double) -> ScoreObj {
        let by = timeBySite(appRows(apps))
        let total = by.items.reduce(0.0) { $0 + $1.1 }
        var topKey = "", topShare = neutral
        if total > 0, let k = by.argmax() {
            topKey = k
            topShare = by[k]! / total
        }
        let minutes = max(1.0, workedS / 60.0)
        let perMin = max(0.0, ScorePy.nz(ScorePy.num(switches), 0)) / minutes
        let value = ScorePy.clamp(topShare * (1.0 - switchPenalty * perMin))
        return ["value": .number(value), "top": .string(topKey), "top_share": .number(ScorePy.round(topShare, 3)),
                "switches_per_min": .number(ScorePy.round(perMin, 2))]
    }

    /// nil when no screenshot was judged; then only a plainly distracting site counts.
    static func onGoalPart(_ goal: String, _ apps: JSONValue?, _ frames: [ScoreObj]) -> ScoreObj? {
        let vals = frameValues(frames, "on_goal")
        if !vals.isEmpty {
            return ["value": .number(vals.reduce(0, +) / Double(vals.count)), "from": .string("screenshots"),
                    "n": ScorePy.n(vals.count)]
        }
        let rows = appRows(apps)
        let total = rows.reduce(0.0) { $0 + $1.seconds }
        if total <= 0 { return nil }
        let wasted = rows.filter { isDistraction($0.row) }.reduce(0.0) { $0 + $1.seconds } / total
        if wasted < 0.15 { return nil }
        return ["value": .number(ScorePy.clamp(1.0 - wasted)), "from": .string("apps"), "n": ScorePy.n(rows.count)]
    }

    // ------------------------------------------------------------ the eyes (stored blocks only)

    static let eyeShares = ["on_screen", "reading", "blank", "away", "unknown"]
    public static let frameModes = ["making", "studying", "consuming", "other"]

    /// The stored camera report, sanitised (blocks from before 2026-10-16 only; never scored).
    public static func eyeClean(_ eye: JSONValue?) -> JSONValue? {
        guard let e = ScorePy.obj(eye) else { return nil }
        var out: ScoreObj = [:]
        for k in eyeShares {
            if let v = ScorePy.num(e[k]) { out[k] = .number(ScorePy.round(ScorePy.clamp(v), 3)) }
        }
        if out.isEmpty { return nil }
        if let bpm = ScorePy.num(e["blinks_per_min"]) {
            out["blinks_per_min"] = .number(ScorePy.round(max(0.0, min(120.0, bpm)), 1))
        } else {
            out["blinks_per_min"] = .null
        }
        if let n = ScorePy.num(e["samples"]) {
            out["samples"] = .number(Double(Int(max(0, n))))
        } else {
            out["samples"] = .null
        }
        out["quality"] = .string(ScorePy.str(e["quality"]).lowercased() == "good" ? "good" : "poor")
        return .object(out)
    }

    /// The stored eye report when it could be trusted, else nil.
    static func eyeGood(_ eye: JSONValue?) -> ScoreObj? {
        guard let c = eyeClean(eye), var e = ScorePy.obj(c), ScorePy.str(e["quality"]) == "good",
              e["on_screen"] != nil else { return nil }
        if let s = ScorePy.num(e["samples"]), s < eyeMinSamples { return nil }
        if (ScorePy.num(e["unknown"]) ?? 0) >= 0.9 { return nil }
        for k in ["reading", "blank", "away"] where e[k] == nil { e[k] = .number(0) }
        return e
    }

    // ------------------------------------------------------------ output parts

    static func studyingShare(_ frames: [ScoreObj]) -> Double {
        let modes = frames.filter { ScorePy.truthy($0["mode"]) }.map { ScorePy.str($0["mode"]) }
        guard !modes.isEmpty else { return 0 }
        return Double(modes.filter { $0 == "studying" }.count) / Double(modes.count)
    }

    /// Share of the work minutes with any scroll, keys or other input; nil with no work minute.
    public static func inputMinutes(_ ticks: JSONValue?) -> Double? {
        let work = ScorePy.dicts(ticks).filter { (ScorePy.str($0["phase"]).isEmpty ? "work" : ScorePy.str($0["phase"])) == "work" }
        if work.isEmpty { return nil }
        let touched = work.filter { t in
            ScorePy.nz(ScorePy.num(t["scroll_s"]), 0) > 0 || ScorePy.nz(ScorePy.num(t["keys_s"]), 0) > 0
                || ScorePy.nz(ScorePy.num(t["active_s"]), 0) > 0
        }.count
        return ScorePy.round(Double(touched) / Double(work.count), 3)
    }

    static func readingCredit(_ frames: [ScoreObj], _ inputShare: JSONValue?, _ onGoal: Double) -> Double {
        let share = studyingShare(frames)
        if let inp = ScorePy.num(inputShare), inp >= readingInput {
            return ScorePy.clamp(share / readingFullCredit) * ScorePy.clamp(onGoal)
        }
        return unverifiedReading * share * ScorePy.clamp(onGoal)
    }

    static func completionOf(_ block: ScoreObj) -> Double {
        let planned = max(60.0, ScorePy.nz(ScorePy.num(block["planned_s"]), 1500))
        if ScorePy.isTrue(block["completed"]) { return 1 }
        let start = toTs(block["started_at"]), end = toTs(block["ended_at"])
        if start != 0 && end != 0 && end > start { return ScorePy.clamp((end - start) / planned) }
        let active = ScorePy.num(block["active_s"])
        if let a = active, a != 0 { return ScorePy.clamp(a / planned) }
        return 0
    }

    static func mins(_ seconds: Double) -> Int { max(1, ScorePy.iround(seconds / 60.0)) }

    /// The judge said this distraction site was serving the goal.
    static func servesGoal(_ frame: ScoreObj?) -> Bool {
        guard let frame else { return false }
        return ScorePy.truthy(frame["serves_goal"])
    }

    /// Every site the judge cleared as serving the goal.
    public static func servingSites(_ frames: JSONValue?) -> Set<String> {
        Set(ScorePy.dicts(frames).filter { servesGoal($0) && (ScorePy.truthy($0["url"]) || ScorePy.truthy($0["app"])) }
            .map { siteKey($0) })
    }

    static func servingSites(_ frames: [ScoreObj]) -> Set<String> { servingSites(.array(frames.map { .object($0) })) }

    /// (where, seconds) of the off-goal thing that took the most time, or nil.
    static func biggestDistraction(_ goal: String, _ apps: JSONValue?, _ frames: [ScoreObj]) -> (String, Double)? {
        let rows = appRows(apps)
        let serving = servingSites(frames)
        var offFrames = Set<String>()
        for f in frames where !servesGoal(f) && !ScorePy.truthy(f["detour"])
            && ScorePy.nz(ScorePy.num(f["on_goal"]), 0) < 0.4
            && (ScorePy.truthy(f["url"]) || ScorePy.truthy(f["app"])) {
            offFrames.insert(siteKey(f))
        }
        offFrames.subtract(serving)
        var by = OrderedTally()
        for r in rows {
            let k = siteKey(r.row)
            if serving.contains(k) { continue }
            if offFrames.contains(k) || goalMatch(goal, r.row) == 0 { by.add(k, r.seconds) }
        }
        guard let k = by.argmax() else { return nil }
        return by[k]! >= 60 ? (k, by[k]!) : nil
    }

    static func automatable(_ frames: [ScoreObj]) -> String {
        var seen = OrderedTally()
        for f in frames {
            let s = ScorePy.ws(ScorePy.str(f["automatable"]))
            if !s.isEmpty { seen.add(s, 1) }
        }
        guard let k = seen.argmax() else { return "" }
        return ScorePy.cut(k, 160)
    }

    static let studyingOrMaking = ["studying", "making"]

    /// The highest progress estimate the screens showed (cumulative within a block); nil when none.
    static func goalProgress(_ frames: [ScoreObj], _ floor: JSONValue?) -> Double? {
        var vals = frameValues(frames, "progress")
        if let f = ScorePy.num(floor), !vals.isEmpty || f > 0 { vals.append(ScorePy.clamp(f)) }
        return vals.max()
    }

    static func engagedPart(_ frames: [ScoreObj], _ activeS: JSONValue?, _ plannedS: Double,
                            _ inputShare: JSONValue?, _ onGoal: Double?) -> ScoreObj {
        let planned = max(60.0, ScorePy.nz(plannedS, 1500))
        let hands = ScorePy.clamp(ScorePy.nz(ScorePy.num(activeS), 0) / (planned * activeFullCredit))
        let reading = readingCredit(frames, inputShare, onGoal ?? neutral)
        let engaged = max(hands, reading)
        let vals = frameValues(frames, "working")
        var out: ScoreObj = ["hands_on": .number(ScorePy.round(engaged, 3)), "typing": .number(ScorePy.round(hands, 3)),
                             "reading": .number(ScorePy.round(reading, 3))]
        if !vals.isEmpty {
            let seen = vals.reduce(0, +) / Double(vals.count)
            out["value"] = .number(engagedBlend.working * seen + engagedBlend.handsOn * engaged)
            out["screens"] = .number(ScorePy.round(seen, 3))
        } else {
            out["value"] = .number(engaged)
            out["screens"] = .null
        }
        return out
    }

    static func relevantReading(_ onGoal: ScoreObj?, _ frames: [ScoreObj], _ inputShare: JSONValue?) -> Bool {
        guard let g = onGoal, let v = ScorePy.num(g["value"]), v >= relevantOnGoal else { return false }
        if let inp = ScorePy.num(inputShare), inp < readingInput { return false }
        return studyingShare(frames) >= readingEvidence
    }

    /// Nothing made AND nothing read, and every source agrees. No judged screen is never nothing.
    static func nothingDone(_ frames: [ScoreObj], _ activeS: JSONValue?, _ plannedS: Double) -> Bool {
        if frames.isEmpty { return false }
        for f in frames {
            if studyingOrMaking.contains(ScorePy.str(f["mode"])) { return false }
            if ScorePy.nz(ScorePy.num(f["working"]), 0) > nothingWorking
                || ScorePy.nz(ScorePy.num(f["progress"]), 0) > 0.05 { return false }
        }
        let planned = max(60.0, ScorePy.nz(plannedS, 1500))
        return ScorePy.nz(ScorePy.num(activeS), 0) / (planned * activeFullCredit) < nothingHands
    }

    // ------------------------------------------------------------ the sub-scores

    static func geo(_ parts: [String: ScoreObj?], _ weights: [(String, Double)]) -> (Double, ScoreObj) {
        let used = weights.filter { parts[$0.0] != nil && parts[$0.0]! != nil }
        let total = used.reduce(0.0) { $0 + $1.1 }
        if total == 0 { return (0, [:]) }
        var s = 0.0
        for (k, w) in used { s += w * log(max(ScorePy.num(parts[k]!!["value"]) ?? 0, 0.02)) }
        let raw = exp(s / total)
        var ws: ScoreObj = [:]
        for (k, w) in used { ws[k] = .number(ScorePy.round(w / total, 3)) }
        return (ScorePy.clamp(raw), ws)
    }

    static func subScore(_ raw: Double, _ completion: Double) -> Int {
        let v = 1 + ScorePy.iround(999 * pow(ScorePy.clamp(raw), scoreCurve) * completion)
        return max(1, min(1000, v))
    }

    /// The share of the judged seconds he was on task; nil when nothing was judged.
    public static func onTaskShare(_ frames: JSONValue?) -> Double? { onTaskShare(ScorePy.dicts(frames)) }

    static func onTaskShare(_ frames: [ScoreObj]) -> Double? {
        var total = 0.0, off = 0.0
        for f in frames where !ScorePy.truthy(f["pending"]) && !ScorePy.truthy(f["detour"]) {
            guard let g = ScorePy.num(f["on_goal"]) else { continue }
            let secs = max(1.0, ScorePy.nz(ScorePy.num(f["seconds"]), 60))
            total += secs
            if g < onTaskFrame && !servesGoal(f) {
                off += secs
            } else {
                off += min(secs, ScorePy.nz(ScorePy.num(f["distraction_s"]), 0) + ScorePy.nz(ScorePy.num(f["away_s"]), 0))
            }
        }
        return total <= 0 ? nil : ScorePy.clamp(1.0 - off / total)
    }

    /// Seconds on a plainly distracting site: the judged minutes' count when there is one, else the block's.
    static func distractionSiteS(_ block: ScoreObj, _ frames: [ScoreObj]) -> Double {
        let judged = frames.filter { $0["distraction_s"] != nil }
        if !judged.isEmpty { return judged.reduce(0.0) { $0 + ScorePy.nz(ScorePy.num($1["distraction_s"]), 0) } }
        return ScorePy.nz(ScorePy.num(block["distraction_s"]), 0)
    }

    static func rubricInForce(_ rubric: JSONValue?) -> ScoreObj? {
        guard let r = ScorePy.obj(rubric), !ScorePy.truthy(r["fallback"]) else { return nil }
        let b = ScorePy.obj(r["balance"]) ?? [:]
        guard let f = ScorePy.num(b["focus"]), f >= 0, f <= 1 else { return nil }
        return r
    }

    // ------------------------------------------------------------ score_block

    /// `score_block(block, rubric)`: {score, focus_score, output_score, parts, weights_used, completion,
    /// reading_counted, nothing_done, goal_used, why, advice} and, with a rubric in force, balance, kind,
    /// balance_line, milestones {total, reached, missed}, on_task_share and distraction_site_s.
    /// Pure and deterministic.
    public static func scoreBlock(_ blockValue: JSONValue, rubric rubricValue: JSONValue? = nil) -> JSONValue {
        let block = ScorePy.obj(blockValue) ?? [:]
        let rubric = rubricInForce(rubricValue)
        var goal = ScorePy.str(block["goal"])
        if needsInferredGoal(goal, specificGoal: block["specific_goal"]) && ScorePy.truthy(block["inferred_goal"]) {
            goal = ScorePy.str(block["inferred_goal"])
        }
        var specific = ScorePy.ws(ScorePy.str(block["specific_goal"]))
        if specific.isEmpty { specific = goal }
        var frameList: [JSONValue] = ScorePy.dicts(block["frames"]).map { .object($0) }
        _ = markDetours(&frameList)
        let frames = frameList.compactMap { ScorePy.obj($0) }
        let apps = block["apps"]
        let planned = max(60.0, ScorePy.nz(ScorePy.num(block["planned_s"]), 1500))
        let completion = completionOf(block)
        let worked = max(60.0, planned * completion)
        let inputShare = block["input_minutes"]
        let onGoal = onGoalPart(goal, apps, frames)
        var quals = frameValues(frames, "quality")
        if quals.isEmpty { quals = frameValues(frames, "working") }
        let smarts = frameValues(frames, "smart")
        var progress = goalProgress(frames, block["goal_achieved"])
        let engaged = engagedPart(frames, block["active_s"], planned * max(completion, 0.05), inputShare,
                                  onGoal.map { ScorePy.num($0["value"]) ?? 0 } ?? 1.0)
        let msAll = ScorePy.dicts(rubric?["milestones"]).filter { ScorePy.truthy($0["id"]) }
        let gotIds: Set<String>
        if case .string(let s) = block["milestones_reached"] {
            gotIds = Set(s.map { String($0) })
        } else {
            gotIds = Set(ScorePy.list(block["milestones_reached"]).map { ScorePy.strRaw($0) })
        }
        let msHit = msAll.filter { gotIds.contains(ScorePy.strRaw($0["id"])) }
        if !msAll.isEmpty { progress = Double(msHit.count) / Double(msAll.count) }

        var parts: [String: ScoreObj?] = [
            "on_goal": onGoal,
            "mono": singleAppPart(apps, block["switches"], worked),
            "progress": progress.map { ["value": .number($0)] },
            "quality": quals.isEmpty ? nil : ["value": .number(quals.reduce(0, +) / Double(quals.count))],
            "smart": smarts.isEmpty ? nil : ["value": .number(smarts.reduce(0, +) / Double(smarts.count))],
            "engaged": engaged,
        ]
        let (focusRaw, focusW) = geo(parts, focusWeights)
        let (outputRaw, outputW) = geo(parts, outputWeights)
        var focusScore = subScore(focusRaw, completion)
        var outputScore = subScore(outputRaw, completion)
        parts["output"] = ["value": .number(outputRaw), "screens": engaged["screens"] ?? .null,
                           "hands_on": engaged["hands_on"]!, "reading": engaged["reading"]!,
                           "typing": engaged["typing"]!]

        var caps: [(String, Int, String)] = []
        let readingOk = relevantReading(onGoal, frames, inputShare)
        let screens = ScorePy.num(engaged["screens"])
        let handsOn = ScorePy.num(engaged["hands_on"]) ?? 0
        if !readingOk, let sc = screens, sc < consumingWorking {
            caps.append(("output", consumingCap, "mostly reading or watching things that were not the goal"))
        }
        if !readingOk && handsOn < idleHands && (screens == nil || screens! < idleScreens) {
            caps.append(("output", idleCap, "almost nothing typed, made or read"))
        }
        if onGoal == nil {
            caps.append(("focus", unseenCap, "your screen was never read, so the work itself wasn't seen"))
        }
        if frames.isEmpty {
            caps.append(("output", unseenCap, "your screen was never read, so the work itself wasn't seen"))
        }
        for (which, cap, _) in caps {
            if which == "focus" { focusScore = min(focusScore, cap) } else { outputScore = min(outputScore, cap) }
        }
        if !msAll.isEmpty {
            let msCap = max(1, ScorePy.iround(1000 * Double(msHit.count) / Double(msAll.count)))
            if msCap < 1000 {
                caps.append(("output", msCap, "\(msHit.count) of \(msAll.count) milestones reached"))
                outputScore = min(outputScore, msCap)
            }
        }
        let nothing = nothingDone(frames, block["active_s"], planned * max(completion, 0.05))
        if nothing { focusScore = 1; outputScore = 1 }
        var score: Int
        if let rubric {
            let bf = ScorePy.clamp(ScorePy.nz(ScorePy.num(ScorePy.obj(rubric["balance"])?["focus"]), 0.5))
            score = max(1, ScorePy.iround(bf * Double(focusScore) + (1.0 - bf) * Double(outputScore)))
            let share = onTaskShare(frames)
            let siteS = distractionSiteS(block, frames)
            if score > hyperfocusCap && (share == nil || share! < hyperfocusShare || siteS > 0) {
                score = hyperfocusCap
                let whyCap: String
                if let share {
                    if share < hyperfocusShare {
                        whyCap = "on task \(ScorePy.iround(share * 100))% of the time; 1,000 needs "
                            + "\(ScorePy.iround(hyperfocusShare * 100))% and no distraction site"
                    } else {
                        whyCap = "\(ScorePy.iround(siteS)) s on a distraction site; 1,000 needs none"
                    }
                } else {
                    whyCap = "the screen was never judged, so near-total focus was not seen"
                }
                caps.append(("total", hyperfocusCap, whyCap))
            }
        } else {
            score = max(1, ScorePy.iround(Double(focusScore + outputScore) / 2))
        }
        for (k, p) in parts {
            guard var p else { continue }
            p["value"] = .number(ScorePy.round(ScorePy.num(p["value"]) ?? 0, 3))
            parts[k] = p
        }
        let scoreOf = ["focus": focusScore, "output": outputScore, "total": score]
        var reasons: [(String, String)] = []
        for (w, c, r) in caps where scoreOf[w] == c && !reasons.contains(where: { $0.1 == r }) {
            reasons.append(("\(w) capped at \(c)", r))
        }
        var why = whyLine(parts, completion, focusScore, outputScore, nothing)
        var out: ScoreObj = [:]
        if let rubric {
            let kind = ScorePy.truthy(rubric["kind"]) ? ScorePy.str(rubric["kind"]) : "mixed"
            let bf = ScorePy.clamp(ScorePy.nz(ScorePy.num(ScorePy.obj(rubric["balance"])?["focus"]), 0.5))
            let balance: JSONValue = .object(["focus": .number(ScorePy.round(bf, 2)),
                                              "output": .number(ScorePy.round(1.0 - bf, 2))])
            let line = balanceLine(balance, kind: kind)
            let msLine = milestonesLine(msAll, msHit)
            why = line + ". " + why + (msLine.isEmpty ? "" : " " + msLine)
            let share = onTaskShare(frames)
            out["balance"] = balance
            out["kind"] = .string(kind)
            out["balance_line"] = .string(line)
            out["milestones"] = .object([
                "total": ScorePy.n(msAll.count),
                "reached": .array(msHit.map { $0["text"] ?? .null }),
                "missed": .array(msAll.filter { m in !msHit.contains(m) }.map { $0["text"] ?? .null }),
            ])
            out["on_task_share"] = share.map { .number(ScorePy.round($0, 3)) } ?? .null
            out["distraction_site_s"] = .number(ScorePy.round(distractionSiteS(block, frames), 1))
        }
        for (k, r) in reasons { why += " \(ScorePy.capFirst(k)): \(r)." }
        var partsJSON: ScoreObj = [:]
        for (k, p) in parts { partsJSON[k] = p.map { .object($0) } ?? .null }
        out["score"] = ScorePy.n(score)
        out["focus_score"] = ScorePy.n(focusScore)
        out["output_score"] = ScorePy.n(outputScore)
        out["parts"] = .object(partsJSON)
        out["weights_used"] = .object(["focus": .object(focusW), "output": .object(outputW)])
        out["completion"] = .number(ScorePy.round(completion, 3))
        out["reading_counted"] = .bool(readingOk)
        out["nothing_done"] = .bool(nothing)
        out["goal_used"] = .string(goal)
        out["why"] = .string(why)
        out["advice"] = .string(advice(goal, specific, parts, completion, planned, apps, frames, readingOk, nothing))
        return .object(out)
    }

    // ------------------------------------------------------------ the words

    static let kindWords = ["reading": "a reading block", "study": "a study block", "writing": "a writing block",
                            "building": "a building block", "outreach": "an outreach block",
                            "planning": "a planning block", "review": "a review block", "mixed": "a mixed block"]

    /// 'Judged 90% on focus, 10% on output: a reading block' ('' without a balance).
    public static func balanceLine(_ balance: JSONValue?, kind: String = "") -> String {
        guard let b = ScorePy.obj(balance), let fv = ScorePy.num(b["focus"]) else { return "" }
        let f = ScorePy.iround(100 * ScorePy.clamp(fv))
        let line = "Judged \(f)% on focus, \(100 - f)% on output"
        return line + (kind.isEmpty ? "" : ": " + (kindWords[kind] ?? "a mixed block"))
    }

    /// 'Milestones: 2 of 3 reached (A; B). Missed: C.' ('' with none).
    static func milestonesLine(_ all: [ScoreObj], _ hit: [ScoreObj]) -> String {
        if all.isEmpty { return "" }
        let missed = all.filter { !hit.contains($0) }
        func text(_ m: ScoreObj) -> String { ScorePy.rstrip(ScorePy.str(m["text"]), ".") }
        var line = "Milestones: \(hit.count) of \(all.count) reached"
        if !hit.isEmpty { line += " (" + hit.map(text).joined(separator: "; ") + ")" }
        line += "."
        if !missed.isEmpty { line += " Missed: " + missed.map(text).joined(separator: "; ") + "." }
        return line
    }

    public static func milestonesLine(_ all: JSONValue?, _ hit: JSONValue?) -> String {
        milestonesLine(ScorePy.dicts(all), ScorePy.dicts(hit))
    }

    static func pv(_ p: ScoreObj?) -> Double { ScorePy.num(p?["value"]) ?? 0 }

    static func advice(_ goal: String, _ specific: String, _ parts: [String: ScoreObj?], _ completion: Double,
                       _ plannedS: Double, _ apps: JSONValue?, _ frames: [ScoreObj], _ readingOk: Bool,
                       _ nothing: Bool) -> String {
        let goalS = ScorePy.strip(goal).isEmpty ? "your goal" : ScorePy.strip(goal)
        let specStripped = ScorePy.rstrip(ScorePy.strip(specific), ".")
        let specS = specStripped.isEmpty ? goalS : specStripped
        let names = ["on_goal", "mono", "progress", "quality", "smart", "engaged"]
        var weakest = ""
        var worst = 1.0
        for k in names {
            guard let p = parts[k], let p else { continue }
            if weakest.isEmpty || pv(p) < worst { weakest = k; worst = pv(p) }
        }
        let distraction = biggestDistraction(goal, apps, frames)
        let auto = automatable(frames)
        if completion < 0.8 {
            let done = ScorePy.iround(completion * plannedS / 60)
            return "You stopped after \(done) of \(ScorePy.iround(plannedS / 60)) minutes — "
                + "try to see the next one through, even if it goes slowly."
        }
        if nothing {
            return "Nothing got made or read this block — next time, open the work and write the "
                + "first line before anything else."
        }
        if worst < 0.5 && (weakest == "mono" || weakest == "on_goal"), let (whereS, secs) = distraction {
            return "The biggest pull away was \(whereS) (\(mins(secs)) minutes) — close it "
                + "before the next block starts."
        }
        let prog = parts["progress"] ?? nil
        if let prog, pv(prog) < 0.5, ["progress", "engaged", "quality"].contains(weakest) {
            return "You got about \(ScorePy.iround(pv(prog) * 100))% of the way to \"\(specS)\" — start the next block "
                + "straight on the part that's left."
        }
        if !auto.isEmpty {
            return "This could be done for you: \(ScorePy.rstrip(auto, ".")). Worth handing to an AI next time."
        }
        if let (whereS, secs) = distraction, secs >= 3 * 60 {
            return "You lost \(mins(secs)) minutes to \(whereS) — close it before the next block starts."
        }
        if worst >= 0.75 { return "That was a strong block on \(goalS) — do the next one exactly the same way." }
        if weakest == "smart" {
            return "Work smarter, not just harder — ask the AI for exactly what you need in one "
                + "clear line instead of doing it by hand."
        }
        if weakest == "quality" {
            return "The work was thin for the goal — aim for one finished piece that does the job "
                + "rather than lots of rough starts."
        }
        if weakest == "mono" {
            return "You kept jumping between apps — keep one window open for the next block "
                + "and leave the rest closed."
        }
        if weakest == "on_goal" {
            return "A lot of this block wasn't on \(goalS) — write down the first small step "
                + "before the next one starts."
        }
        if readingOk {
            return "Good, focused reading — end the next block by writing down the three things "
                + "you took from it."
        }
        if weakest == "progress", let prog {
            return "You got about \(ScorePy.iround(pv(prog) * 100))% of the way to \"\(specS)\" — start the next block "
                + "straight on the part that's left."
        }
        return "You were mostly reading and watching rather than making something — start "
            + "the next block by writing or building straight away."
    }

    /// `_why`.
    static func whyLine(_ parts: [String: ScoreObj?], _ completion: Double, _ focusScore: Int,
                        _ outputScore: Int, _ nothing: Bool) -> String {
        if nothing {
            return "Focus 1, output 1: the screens and the keyboard both showed nothing made and "
                + "nothing read."
        }
        var f: [String] = []
        let m = (parts["mono"] ?? nil) ?? [:]
        f.append("one thing \(ScorePy.iround((ScorePy.num(m["top_share"]) ?? 0) * 100))% of the time, "
                 + "\(ScorePy.repr(ScorePy.num(m["switches_per_min"]) ?? 0)) switches a minute")
        if let g = parts["on_goal"] ?? nil {
            f.append("on your goal \(ScorePy.iround(pv(g) * 100))%"
                     + (ScorePy.str(g["from"]) == "screenshots" ? "" : " (from the sites you had open)"))
        } else {
            f.append("your screen wasn't read, so whether it was on your goal was left out "
                     + "(this score is incomplete)")
        }
        var o: [String] = []
        if let p = parts["progress"] ?? nil { o.append("got \(ScorePy.iround(pv(p) * 100))% of the way to the goal") }
        if let q = parts["quality"] ?? nil { o.append("quality \(ScorePy.iround(pv(q) * 100))%") }
        if let sm = parts["smart"] ?? nil { o.append("working smart \(ScorePy.iround(pv(sm) * 100))%") }
        o.append("making or reading for it \(ScorePy.iround(pv(parts["engaged"] ?? nil) * 100))%")
        var line = "Focus \(focusScore): " + f.joined(separator: "; ") + ". Output \(outputScore): "
            + o.joined(separator: "; ") + "."
        if completion < 1.0 { line += " Finished \(ScorePy.iround(completion * 100))% of the block." }
        return line
    }
}
