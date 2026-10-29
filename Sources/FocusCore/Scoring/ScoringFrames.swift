import Foundation

// The frame and minute helpers the sense path uses (brain/focus.py): pending frames and their retro
// credit, lone detours, the off-task test, distracted minutes and the run that triggers a call, the
// break point and next block length, the nudge, and the old per-day summary lines.

extension Scoring {
    // ------------------------------------------------------------ the sequence

    static let pendingApps = ["finder", "desktop", "preview", "quick look", "quicklook",
                              "system settings", "system preferences", "settings",
                              "terminal", "iterm", "iterm2", "warp", "console",
                              "mail", "outlook", "activity monitor", "calculator"]
    static let pendingHosts = ["mail.google.com", "outlook.office.com", "drive.google.com"]
    static let pendingKeys = ["on_goal", "working", "quality"]
    public static let retroMax = 3

    /// The screen cannot say, by itself, whether this serves the goal.
    public static func looksAmbiguous(_ row: JSONValue?) -> Bool {
        guard let r = ScorePy.obj(row), !isDistraction(r) else { return false }
        let host = hostOf(ScorePy.str(r["url"]))
        if !host.isEmpty, pendingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if !host.isEmpty { return false }
        let app = ScorePy.ws(ScorePy.str(r["app"])).lowercased()
        return !app.isEmpty && pendingApps.contains(where: { app == $0 || app.contains($0) })
    }

    /// Should this screenshot wait for the next one? The judge's own flag (`said`), or an
    /// ambiguous-looking screen. Never a distraction.
    public static func framePending(_ row: JSONValue?, said: JSONValue? = nil) -> Bool {
        guard let r = ScorePy.obj(row), !isDistraction(r) else { return false }
        guard let said, said != .null else { return looksAmbiguous(row) }
        return ScorePy.truthy(said)
    }

    /// The frame as it is stored while it waits: neutral, with what was judged kept under "judged".
    public static func provisional(_ row: JSONValue) -> JSONValue {
        let r = ScorePy.obj(row) ?? [:]
        var out = r
        var judged: ScoreObj = [:]
        for k in pendingKeys { judged[k] = r[k] ?? .null }
        out["judged"] = .object(judged)
        for k in pendingKeys { out[k] = .number(neutral) }
        out["pending"] = .bool(true)
        return .object(out)
    }

    /// `row` just landed and is not pending: the run of pending frames right before it takes its
    /// on_goal, working (and quality) and producing. Returns how many; mutates them.
    @discardableResult
    public static func retroCredit(_ frames: inout [JSONValue], row: JSONValue, limit: Int = retroMax) -> Int {
        guard let r = ScorePy.obj(row), !ScorePy.truthy(r["pending"]) else { return 0 }
        let on = ScorePy.num(r["on_goal"]), working = ScorePy.num(r["working"])
        let producing = ScorePy.num(r["producing"])
        if on == nil && working == nil { return 0 }
        var n = 0
        for i in frames.indices.reversed() {
            guard var f = ScorePy.obj(frames[i]) else { continue }
            if !ScorePy.truthy(f["pending"]) || n >= limit { break }
            if let on { f["on_goal"] = .number(ScorePy.round(ScorePy.clamp(on), 3)) }
            if let working {
                f["working"] = .number(ScorePy.round(ScorePy.clamp(working), 3))
                f["quality"] = .number(ScorePy.round(ScorePy.clamp(working), 3))
            }
            if let producing { f["producing"] = .number(ScorePy.round(ScorePy.clamp(producing), 3)) }
            f["pending"] = .bool(false)
            f["retro"] = .bool(true)
            frames[i] = .object(f)
            n += 1
        }
        return n
    }

    // ------------------------------------------------------------ a lone detour

    public static let detourMaxS = 120.0
    public static let detourOnTask = 0.5

    static func frameOnTask(_ f: ScoreObj?) -> Bool {
        guard let f, !ScorePy.truthy(f["pending"]), !ScorePy.truthy(f["detour"]) else { return false }
        if servesGoal(f) { return true }
        guard let on = ScorePy.num(f["on_goal"]) else { return false }
        return on >= detourOnTask && !frameOffTask(.object(f))
    }

    /// Mark every lone off-task screenshot between two on-task ones (not a distracting site, next one
    /// within DETOUR_MAX_S) as a detour. Idempotent; returns how many were newly marked.
    @discardableResult
    public static func markDetours(_ frames: inout [JSONValue]) -> Int {
        let idx = frames.indices.filter { ScorePy.isDict(frames[$0]) }
        var n = 0
        guard idx.count >= 3 else { return 0 }
        for j in 1..<(idx.count - 1) {
            guard var f = ScorePy.obj(frames[idx[j]]) else { continue }
            if ScorePy.truthy(f["detour"]) || ScorePy.truthy(f["pending"]) || !frameOffTask(.object(f)) { continue }
            if isDistraction(f) && !servesGoal(f) { continue }
            if !(frameOnTask(ScorePy.obj(frames[idx[j - 1]])) && frameOnTask(ScorePy.obj(frames[idx[j + 1]]))) { continue }
            let at = toTs(f["at"]), nxt = toTs(ScorePy.obj(frames[idx[j + 1]])?["at"])
            if at == 0 || nxt == 0 || nxt - at > detourMaxS || nxt < at { continue }
            f["detour"] = .bool(true)
            frames[idx[j]] = .object(f)
            n += 1
        }
        return n
    }

    // ------------------------------------------------------------ the nudge

    public static let nudgeOnGoal = 0.3
    public static let nudgeQuality = 0.25
    public static let nudgeGapS = 4.0 * 60

    /// Openly off task on this screenshot. Reading goal material never is.
    public static func frameOffTask(_ frame: JSONValue?) -> Bool {
        guard let f = ScorePy.obj(frame) else { return false }
        let on = ScorePy.num(f["on_goal"])
        if f["mode"] == .string("studying"), let on, on >= relevantOnGoal { return false }
        let q = ScorePy.num(f["quality"])
        return (on != nil && on! < nudgeOnGoal) || (q != nil && q! < nudgeQuality)
    }

    /// This screenshot AND the one before are openly off task, and no nudge in the last four minutes.
    public static func nudgeAllowed(_ frame: JSONValue?, previous: JSONValue?, lastNudgeAt: Double, now: Double) -> Bool {
        frameOffTask(frame) && frameOffTask(previous) && now - lastNudgeAt >= nudgeGapS
    }

    /// The model's own line (first sentence, ≤120) or a plain one from what was on screen.
    public static func nudgeText(_ modelNudge: String, goal: String, frame: JSONValue?) -> String {
        let said = ScorePy.ws(modelNudge)
        if !said.isEmpty { return ScorePy.cut(ScorePy.firstSentence(said), 120) }
        var goalS = ScorePy.cut(ScorePy.ws(goal), 60)
        if goalS.isEmpty { goalS = "your goal" }
        let f = ScorePy.obj(frame) ?? [:]
        if let on = ScorePy.num(f["on_goal"]), on < nudgeOnGoal {
            var whereS = hostOf(ScorePy.str(f["url"]))
            if whereS.isEmpty { whereS = ScorePy.cut(ScorePy.ws(ScorePy.str(f["app"])), 30) }
            if !whereS.isEmpty { return "Close \(whereS) — back to \(goalS)." }
            return "That's not \(goalS) — back to it."
        }
        return "Stop and do the next concrete step on \(goalS)."
    }

    // ------------------------------------------------------------ the call (jev.py's idle allowance)

    public static let idleS = 120.0
    public static let readingIdleS = 360.0
    static let readingHosts = ["wwnorton.com", "zybooks.com", "instructure.com", "canvas", "docs.", "developer.",
                               "readthedocs", "wikipedia.org", "arxiv.org", "medium.com", "substack.com",
                               "scholar.google", "jstor.org", "pubmed", "openstax.org", "khanacademy.org",
                               "coursera.org", "edx.org", "pearson.com", "mheducation.com", "cengage.com",
                               "notion.site", "gitbook.io", "learn.microsoft.com", "docs.google.com/document"]
    static let readingApps = ["preview", "books", "skim", "acrobat", "pdf expert", "kindle"]
    static let longText = 3000
    static let schemeRe = ScorePy.regex(#"^[a-z][a-z0-9+.-]*://"#, .caseInsensitive)

    /// jev._split: (host without www., lowercased path without trailing slash).
    static func splitURL(_ url: String) -> (host: String, path: String) {
        var raw = ScorePy.strip(url)
        if raw.isEmpty { return ("", "") }
        if ScorePy.firstMatch(schemeRe, raw) == nil { raw = "https://" + raw }
        guard let r = raw.range(of: "://") else { return ("", "") }
        let rest = String(raw[r.upperBound...])
        let netEnd = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        let netloc = String(rest[..<netEnd])
        var tail = String(rest[netEnd...])
        if let q = tail.firstIndex(where: { "?#".contains($0) }) { tail = String(tail[..<q]) }
        var hostPart = netloc
        if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
        if hostPart.hasPrefix("["), let close = hostPart.firstIndex(of: "]") {
            hostPart = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close])
        } else if let colon = hostPart.firstIndex(of: ":") {
            hostPart = String(hostPart[..<colon])
        }
        var host = hostPart.lowercased()
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return (host, ScorePy.rstrip(tail.lowercased(), "/"))
    }

    /// jev.reading_material: a PDF, an ebook, a course page, docs, a long article.
    static func readingMaterial(_ screen: ScoreObj, textLen: Int = 0) -> Bool {
        let url = ScorePy.str(screen["url"]).lowercased()
        let app = ScorePy.ws(ScorePy.str(screen["app"]).lowercased())
        let (host, path) = splitURL(url)
        if path.hasSuffix(".pdf") || readingApps.contains(where: { app == $0 || app.contains($0) }) { return true }
        if !host.isEmpty, readingHosts.contains(where: { host.contains($0) || url.contains($0) }) { return true }
        return textLen >= longText
    }

    /// jev.is_away: no input for longer than the idle allowance (six minutes on reading material).
    static func isAway(_ idle: Double, _ screen: ScoreObj, studying: Bool) -> Bool {
        idle >= (studying || readingMaterial(screen) ? readingIdleS : idleS)
    }

    static func frameAt(_ frames: [ScoreObj], _ at: Double) -> ScoreObj? {
        var best: ScoreObj?
        for f in frames {
            let t = toTs(f["at"])
            if t != 0 && t <= at + 30 && at - t <= frameFreshS && (best == nil || t > toTs(best!["at"])) { best = f }
        }
        return best
    }

    /// Why this minute was off task: "screen", "away", or "" (only work minutes count).
    public static func tickDistracted(_ tick: JSONValue, frames: JSONValue?) -> String {
        tickDistracted(ScorePy.obj(tick) ?? [:], ScorePy.dicts(frames))
    }

    static func tickDistracted(_ tick: ScoreObj, _ frames: [ScoreObj]) -> String {
        let phase = ScorePy.str(tick["phase"])
        if (phase.isEmpty ? "work" : phase) != "work" { return "" }
        let at = toTs(tick["at"])
        let f = at != 0 ? frameAt(frames, at) : nil
        if let f, !ScorePy.truthy(f["detour"]), !servesGoal(f), let on = ScorePy.num(f["on_goal"]), on < distractOnGoal {
            return "screen"
        }
        let studying = f.map { ScorePy.str($0["mode"]) == "studying" } ?? false
        if let idle = ScorePy.num(tick["idle_s"]), isAway(idle, tick, studying: studying) { return "away" }
        return ""
    }

    /// (seconds, why) of unbroken distraction ending now, from minute ticks.
    public static func distractedRun(_ ticks: JSONValue?, frames: JSONValue?, now: Double) -> (seconds: Int, why: String) {
        let sorted = ScorePy.dicts(ticks).filter { toTs($0["at"]) != 0 }.enumerated()
            .sorted { a, b in
                let ta = toTs(a.element["at"]), tb = toTs(b.element["at"])
                return ta != tb ? ta < tb : a.offset < b.offset
            }.map { $0.element }
        guard let last = sorted.last, now - toTs(last["at"]) <= tickGapS else { return (0, "") }
        let fr = ScorePy.dicts(frames)
        let newest = toTs(last["at"])
        var why = "", prev: Double?, oldest: Double?
        for t in sorted.reversed() {
            let at = toTs(t["at"])
            if let prev, prev - at > tickGapS { break }
            let reason = tickDistracted(t, fr)
            if reason.isEmpty { break }
            if why.isEmpty { why = reason }
            prev = at
            oldest = at
        }
        guard let oldest else { return (0, "") }
        return (ScorePy.iround(newest - oldest) + 60, why)
    }

    public static func callSentence(goal: String, why: String, minutes: Int, doing: String = "", app: String = "") -> String {
        var goalS = ScorePy.cut(ScorePy.ws(goal), 80)
        if goalS.isEmpty { goalS = "your goal" }
        let n = [6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten"][minutes] ?? String(minutes)
        if why == "away" || why == "looking" {
            return "You said you'd work on \(goalS), but you've been away from the desk for "
                + "about \(n) minutes — want to get back to it?"
        }
        var what = ScorePy.cut(ScorePy.ws(doing), 60)
        if what.isEmpty { what = ScorePy.cut(ScorePy.ws(app), 40) }
        if what.isEmpty { what = "something else" }
        return "You said you'd work on \(goalS). You've been on \(what) for about \(n) minutes "
            + "— want to get back to it?"
    }

    // ------------------------------------------------------------ the next block

    public static let blockMaxMin = 25
    public static let blockLongestMin = 120
    public static let blockMinMin = 10
    public static let blockStepMin = 5
    public static let switchSpike = 6.0
    public static let testModeBelowS = 5.0 * 60
    public static let testFloorS = 20
    public static let settleS = 120.0
    public static let settleShare = 0.08

    public static func lengthScale(_ plannedS: Double?) -> Double {
        let planned = ScorePy.nz(plannedS, 1500)
        return planned >= testModeBelowS ? 1.0 : max(0.001, planned / (Double(blockMaxMin) * 60.0))
    }

    /// Seconds from the block's start to where his focus first broke, or nil when it held.
    public static func breakPointS(ticks: JSONValue?, frames: JSONValue?, startedAt: JSONValue?,
                                   endedAt: JSONValue? = nil) -> Double? {
        let start = toTs(startedAt)
        if start == 0 { return nil }
        let e = toTs(endedAt)
        let end = e != 0 ? e : Double.infinity
        let tickRows = ScorePy.dicts(ticks).filter { toTs($0["at"]) != 0 }
        let frameRows = ScorePy.dicts(frames)
        var found: [Double] = []
        for t in tickRows {
            let at = toTs(t["at"])
            let phase = ScorePy.str(t["phase"])
            if (phase.isEmpty ? "work" : phase) != "work" || !(start < at && at <= end + 30) { continue }
            let sw = ScorePy.nz(ScorePy.num(t["switches"]), 0)
            var tt = t
            tt["at"] = .number(at)
            if tickDistracted(tt, frameRows) == "away" || sw >= switchSpike { found.append(max(0, at - 60 - start)) }
        }
        for f in frameRows {
            let at = toTs(f["at"])
            if at != 0 && start <= at && at <= end + 30 && frameOffTask(.object(f)) { found.append(max(0, at - start)) }
        }
        let span = end != .infinity ? end - start : Double(blockMaxMin * 60)
        let grace = min(settleS, span * settleShare)
        return found.filter { $0 >= grace }.min()
    }

    static func amount(_ seconds: Double, test: Bool) -> String {
        if test {
            let s = ScorePy.iround(seconds)
            return "\(s) second\(s != 1 ? "s" : "")"
        }
        let m = ScorePy.iround(seconds / 60.0)
        return "\(m) minute\(m != 1 ? "s" : "")"
    }

    /// {next_work_s, next_reason}: the median of today's break points, floored to 5 minutes, kept
    /// between 10 minutes and this block's length — never longer.
    public static func nextBlockLength(breakS: Double?, todayBreaksScaled: [Double], currentS: Double?,
                                       capS: Double? = nil, scale: Double = 1.0) -> (nextWorkS: Int, nextReason: String) {
        let scale = scale > 0 ? scale : 1.0
        let test = scale < 1.0
        let top = Double(blockLongestMin) * 60 * scale
        var current = min(ScorePy.nz(currentS, Double(blockMaxMin) * 60 * scale), top)
        if let capS, capS != 0 { current = min(current, capS) }
        let floor = test ? Double(testFloorS) : 60.0
        current = max(floor, current)
        guard let breakS else {
            let n = ScorePy.iround(current)
            return (n, "You held focus the whole block — keeping \(amount(Double(n), test: test)).")
        }
        let points = (todayBreaksScaled + [breakS / scale]).sorted()
        let mid = points.count / 2
        let median = points.count % 2 == 1 ? points[mid] : (points[mid - 1] + points[mid]) / 2
        let minutes = max(blockMinMin, Int((median / 60.0 / Double(blockStepMin)).rounded(.down)) * blockStepMin)
        var n = ScorePy.iround(min(Double(minutes) * 60 * scale, current))
        if test { n = max(testFloorS, n) }
        let when = test ? "second \(max(1, ScorePy.iround(breakS)))" : "minute \(max(1, ScorePy.iround(breakS / 60.0)))"
        let reason = n < ScorePy.iround(current)
            ? "Your focus slipped around \(when), so the next block is \(amount(Double(n), test: test))."
            : "Your focus slipped around \(when) — keeping \(amount(Double(n), test: test))."
        return (n, reason)
    }

    // ------------------------------------------------------------ the day, in one line

    /// `day_stats`: {count, avg, best {score, goal}, advice} over blocks with an int score.
    public static func dayStats(_ blocks: JSONValue?) -> JSONValue {
        let rows = ScorePy.dicts(blocks).filter { ScorePy.intValue($0["score"]) != nil }
        if rows.isEmpty { return .object(["count": .number(0), "avg": .null, "best": .null, "advice": .string("")]) }
        func sc(_ b: ScoreObj) -> Int { ScorePy.intValue(b["score"])! }
        var best = rows[0], worst = rows[0]
        for b in rows.dropFirst() {
            let (s, e) = (sc(b), toTs(b["ended_at"]))
            if s > sc(best) || (s == sc(best) && e > toTs(best["ended_at"])) { best = b }
            if s < sc(worst) || (s == sc(worst) && -e < -toTs(worst["ended_at"])) { worst = b }
        }
        let avg = ScorePy.iround(Double(rows.map(sc).reduce(0, +)) / Double(rows.count))
        return .object(["count": ScorePy.n(rows.count), "avg": ScorePy.n(avg),
                        "best": .object(["score": ScorePy.n(sc(best)), "goal": .string(ScorePy.str(best["goal"]))]),
                        "advice": .string(ScorePy.str(worst["advice"]))])
    }

    public static func speakDay(_ stats: JSONValue) -> String {
        guard let n = ScorePy.intValue(stats["count"]), n != 0 else { return "" }
        var line = "You did \(n) focus block\(n != 1 ? "s" : "") today, averaging "
            + "\(ScorePy.strRaw(stats["avg"])) out of 1000."
        let best = ScorePy.obj(stats["best"]) ?? [:]
        if n > 1 && !best.isEmpty {
            line += " The best was \(ScorePy.strRaw(best["score"]))"
                + (ScorePy.truthy(best["goal"]) ? ", on \(ScorePy.str(best["goal"]))." : ".")
        }
        let advice = ScorePy.str(stats["advice"])
        if !advice.isEmpty { line += " One thing to try: " + ScorePy.lowerFirst(advice) }
        return line
    }

    /// The focus paragraph of the evening email.
    public static func reportLines(_ stats: JSONValue) -> String {
        guard let n = ScorePy.intValue(stats["count"]), n != 0 else { return "" }
        var lines = ["Focus blocks: \(n) today, averaging \(ScorePy.strRaw(stats["avg"])) out of 1000."]
        let best = ScorePy.obj(stats["best"]) ?? [:]
        if !best.isEmpty {
            lines.append("Your best was \(ScorePy.strRaw(best["score"]))"
                         + (ScorePy.truthy(best["goal"]) ? ", working on \(ScorePy.str(best["goal"]))." : "."))
        }
        let advice = ScorePy.str(stats["advice"])
        if !advice.isEmpty { lines.append("For tomorrow: " + advice) }
        return lines.joined(separator: "\n")
    }
}
