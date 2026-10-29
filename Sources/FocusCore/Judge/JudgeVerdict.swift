import Foundation

// MARK: - Questions, answers, the verdict row and the rules on top of it

extension Judge {
    // MARK: The goal's own questions

    /// A goal question's id in the call: a rubric tell keeps its own, the goal step's get `goal_`.
    static func qid(_ id: String) -> String {
        rubricQPrefixes.contains { pyStarts(id, $0) } ? id : goalQPrefix + id
    }

    public struct GoalQuestion: Equatable, Sendable {
        public let id: String
        public let text: String
        public let means: String        // "on_task" | "off_task"
        public var json: JSONValue { .object(["id": .string(id), "text": .string(text), "means": .string(means)]) }
    }

    /// The goal step's questions, cleaned: at most GOAL_Q_MAX, short, no
    /// duplicates, renumbered q1, q2, ... — except the rubric's tells, which
    /// keep their rub_on_ / rub_off_ ids (up to GOAL_Q_RUBRIC_MAX).
    public static func goalQuestionsClean(_ raw: JSONValue?) -> [GoalQuestion] {
        var out: [GoalQuestion] = []
        var seen = Set<String>()
        var plain = 0, rubric = 0
        for item in list(raw) ?? [] {
            guard let d = dict(item) else { continue }
            let text = cut(squash(pyStrOr(d["text"])), goalQMaxChars)
            let means = pyStrip(pyStrOr(d["means"])).lowercased()
                .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            if text.isEmpty || !(means == "on_task" || means == "off_task") || seen.contains(text.lowercased()) {
                continue
            }
            var rid = ""
            for u in pyStrOr(d["id"]).lowercased().unicodeScalars
            where (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) || u == "_" {
                rid.unicodeScalars.append(u)
            }
            rid = cut(rid, 40)
            if rubricQPrefixes.contains(where: { pyStarts(rid, $0) }) {
                if rubric == goalQRubricMax { continue }
                rubric += 1
                seen.insert(text.lowercased())
                out.append(GoalQuestion(id: rid, text: text, means: means))
                continue
            }
            if plain == goalQMax { continue }
            plain += 1
            seen.insert(text.lowercased())
            out.append(GoalQuestion(id: "q\(plain)", text: text, means: means))
        }
        return out
    }

    /// The rubric as `noul` questions: rub_on_<id>, rub_off_<id>, ms_<id> (brain/rubric.py `questions_for`).
    public static func rubricQuestions(_ rubric: JSONValue?) -> Dict {
        guard let r = dict(rubric) else { return [:] }
        var qs: Dict = [:]
        for t in list(r["on_tells"]) ?? [] {
            guard let id = t["id"].map({ pyStr($0) }), let text = t["text"].map({ pyStr($0) }) else { continue }
            qs[rubricPrefixOn + id] = .object([
                "type": .string("noul"),
                "instructions": .string("This goal's rubric, a sign of being ON task (`goal.checks`): " + text
                                        + " Yes only when the screen right now plainly shows it.")])
        }
        for t in list(r["off_tells"]) ?? [] {
            guard let id = t["id"].map({ pyStr($0) }), let text = t["text"].map({ pyStr($0) }) else { continue }
            qs[rubricPrefixOff + id] = .object([
                "type": .string("noul"),
                "instructions": .string("This goal's rubric, a sign of being OFF task (`goal.checks`): " + text
                                        + " Yes only when the screen right now plainly shows it.")])
        }
        for m in list(r["milestones"]) ?? [] {
            guard let id = m["id"].map({ pyStr($0) }), let text = m["text"].map({ pyStr($0) }) else { continue }
            qs[rubricPrefixMs + id] = .object([
                "type": .string("noul"),
                "instructions": .string("Is milestone \"\(text)\" visibly reached on this screen or in the story so "
                                        + "far? Yes only when it is plainly done, not started or half done.")])
        }
        return qs
    }

    /// Milestone ids Jev answered yes to (MILESTONE_YES or more) (brain/rubric.py `milestones_reached`).
    public static func milestonesReached(_ answers: JSONValue?, _ rubric: JSONValue?) -> [String] {
        guard let a = dict(answers), let r = dict(rubric) else { return [] }
        var out: [String] = []
        for m in list(r["milestones"]) ?? [] {
            guard let id = m["id"].map({ pyStr($0) }) else { continue }
            var v: Double?
            if let ans = dict(a[rubricPrefixMs + id]), let x = ans["noul"] {
                if case .bool = x { v = nil } else { v = num(x) }      // rubric._num rejects bools
            }
            if let v, v >= milestoneYes { out.append(id) }
        }
        return out
    }

    /// The fixed QUESTIONS, the general checks (chk_...), this goal's own
    /// yes/no questions (goal_q1 ... or the rubric's own ids) and, with a
    /// rubric, its tells and milestones.
    public static func questionsFor(_ goalQuestions: JSONValue?, rubric: JSONValue? = nil) -> Dict {
        var qs = questions
        qs.merge(checkQuestions) { $1 }
        for q in goalQuestionsClean(goalQuestions) {
            qs[qid(q.id)] = .object([
                "type": .string("noul"),
                "instructions": .string("This goal's own check (`goal.checks`): " + q.text
                                        + " Yes only when the screen right now plainly shows it.")])
        }
        qs.merge(rubricQuestions(rubric)) { $1 }
        return qs
    }

    /// (on-task tells, off-task tells): this goal's questions answered yes (GOAL_TELL or more).
    public static func goalAnswers(_ answers: JSONValue?, _ goalQuestions: JSONValue?) -> (on: [String], off: [String]) {
        var on: [String] = [], off: [String] = []
        guard let a = dict(answers) else { return (on, off) }
        for q in goalQuestionsClean(goalQuestions) {
            if let ans = dict(a[qid(q.id)]), clamp(ans["noul"]) >= goalTell {
                if q.means == "on_task" { on.append(q.id) } else { off.append(q.id) }
            }
        }
        return (on, off)
    }

    // MARK: Reading the answers

    private static func noul(_ answers: Dict?, _ qid: String) -> Double? {
        guard let a = dict(answers?[qid]), num(a["noul"]) != nil else { return nil }
        return clamp(a["noul"])
    }

    /// A score answer as 0..1: the expectation over its levels when the
    /// probabilities are there, else the `score` it gave.
    static func expect(_ answer: Dict, _ levels: Int) -> Double? {
        if let probs = dict(answer["probabilities"]), !probs.isEmpty {
            var total = 0.0, mass = 0.0
            for (k, p) in probs {
                guard let i = Int(pyStrip(k)), let pv = pyFloat(p) else { continue }
                total += (Double(i) / Double(max(1, levels - 1))) * pv
                mass += pv
            }
            if mass > 0 { return clamp(total / mass) }
        }
        guard let s = answer["score"], s != .null else { return nil }
        return clamp(s)
    }

    /// (expectation, p_on_task, confidence) for the on-goal score answer.
    static func scoreDecision(_ answer: JSONValue?) -> (expect: Double?, pOn: Double?, confidence: Double) {
        guard let a = dict(answer) else { return (nil, nil, 0) }
        let e = expect(a, 4)
        if let probs = dict(a["probabilities"]), !probs.isEmpty {
            let pOn = probs.filter { $0.key == "2" || $0.key == "3" }.reduce(0.0) { $0 + num0($1.value) }
            var total = probs.values.reduce(0.0) { $0 + num0($1) }
            if total == 0 { total = 1 }
            let p = clamp(pOn / total)
            return (e, pyRound(p, 3), pyRound(abs(2 * p - 1), 3))
        }
        return (e, nil, pyRound(clamp(a["confidence"]), 3))
    }

    /// The general checks and the old on-goal score as one verdict (noisy-OR
    /// per side, CHECK_FLOOR, CHECK_BLEND; tells strongest first; caps).
    public static func combineChecks(_ answers: JSONValue?, _ scoreAnswer: JSONValue?) -> Dict {
        let (rawE, _, rawConf) = scoreDecision(scoreAnswer)
        let raw = rawE ?? 0
        let a = dict(answers)
        var keepOn = 1.0, keepOff = 1.0
        var answered = 0
        var tells: [String] = [], offTells: [String] = [], neutral: [String] = []
        var probs: [String: Double] = [:]
        var caps: Dict = [:]
        for c in generalChecks {
            guard let p = noul(a, checkPrefix + c.id) else { continue }
            answered += 1
            let feedsOn = c.feeds.contains("on_goal")
            if p >= checkFloor && c.means == .onTask && feedsOn {
                keepOn *= 1 - c.weight * p
            } else if p >= checkFloor && c.means == .offTask && feedsOn {
                keepOff *= 1 - c.weight * p
            }
            if p >= checkTell {
                switch c.means {
                case .onTask: tells.append(c.id)
                case .offTask: offTells.append(c.id)
                case .neutral: neutral.append(c.id)
                }
                probs[c.id] = pyRound(p, 3)
            }
            if c.means == .offTask && p >= checkCap {
                for k in ["working", "smart"] where c.feeds.contains(k) { caps[k] = .number(checkCapTo) }
            }
        }
        let on = clamp(1 - keepOn), off = clamp(1 - keepOff)
        let onGoal: Double, confidence: Double
        if answered > 0 {
            onGoal = checkBlend * ((on + (1 - off)) / 2) + (1 - checkBlend) * raw
            confidence = 0.5 * clamp(abs(on - off)) + 0.5 * rawConf
        } else {
            onGoal = raw
            confidence = rawConf
        }
        func strongestFirst(_ ids: [String]) -> [String] {
            ids.enumerated().sorted { l, r in
                let pl = probs[l.element]!, pr = probs[r.element]!
                return pl != pr ? pl > pr : l.offset < r.offset
            }.map(\.element)
        }
        return ["on": .number(pyRound(on, 3)), "off": .number(pyRound(off, 3)),
                "on_goal": .number(pyRound(clamp(onGoal), 3)), "confidence": .number(pyRound(clamp(confidence), 3)),
                "tells": strings(strongestFirst(tells)), "off_tells": strings(strongestFirst(offTells)),
                "neutral": strings(neutral), "probs": .object(probs.mapValues { .number($0) }),
                "caps": .object(caps), "answered": .number(Double(answered)),
                "on_goal_raw": .number(pyRound(raw, 3)), "confidence_raw": .number(rawConf)]
    }

    /// Jev was torn on this second (never for a ruled, away or distraction-site second).
    public static func escalate(_ row: Dict?) -> Bool {
        guard let row, !truthy(row["ruled"]), !truthy(row["away"]), !truthy(row["off_site"]) else { return false }
        let on = num0(row["on_goal"]), conf = num0(row["confidence"])
        return conf < escalateConfidence || (escalateLow <= on && on < escalateHigh)
    }

    /// 'Leaning on task: search 0.92, contact 0.71. Leaning off task: feed 0.65.' ...
    public static func tellsText(_ row: Dict?, n: Int = tellsShown) -> String {
        guard let row else { return "" }
        let probs = dict(row["check_p"]) ?? [:]
        var parts: [String] = []
        for (label, key) in [("Leaning on task", "tells"), ("Leaning off task", "off_tells")] {
            let ids = Array(strList(row[key]).prefix(n))
            if !ids.isEmpty {
                parts.append(label + ": " + ids.map { i in
                    i + (num(probs[i]).map { String(format: " %.2f", $0) } ?? "")
                }.joined(separator: ", ") + ".")
            }
        }
        if present(row["on"]) || present(row["off"]) {
            parts.append("Checks combined: on \(pyStrFloat(row["on"])), off \(pyStrFloat(row["off"])); "
                         + "on-goal score alone \(pyStrFloat(row["on_goal_raw"])).")
        }
        return parts.joined(separator: " ")
    }

    /// Rough token count of a questions dict as sent: len(json.dumps(q, separators=(",", ":"))) // 4.
    public static func questionTokens(_ questions: Dict) -> Int {
        pyJSONLength(.object(questions)) / 4
    }

    /// Length of Python's compact `json.dumps` (ensure_ascii) of a value.
    static func pyJSONLength(_ v: JSONValue) -> Int {
        switch v {
        case .null: return 4
        case .bool(let b): return b ? 4 : 5
        case .number(let n): return pyStr(.number(n)).count
        case .string(let s): return pyJSONStringLength(s)
        case .array(let a): return 2 + a.reduce(0) { $0 + pyJSONLength($1) } + max(0, a.count - 1)
        case .object(let o):
            return 2 + o.reduce(0) { $0 + pyJSONStringLength($1.key) + 1 + pyJSONLength($1.value) } + max(0, o.count - 1)
        }
    }

    private static func pyJSONStringLength(_ s: String) -> Int {
        var n = 2
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: n += 2
            case 0..<0x20: n += 6
            case 0x20...0x7F: n += 1
            case 0x80..<0x10000: n += 6
            default: n += 12
            }
        }
        return n
    }

    // MARK: Parse, row, settle

    /// Jev's answers as one verdict (on_goal, working, producing, quality,
    /// smart, progress, mode, static, serves_goal, step, confidence,
    /// p_on_task, activity, tells_on, tells_off, on, off, on_goal_raw,
    /// confidence_raw, check_tells, check_off_tells, check_p,
    /// checks_answered, milestones). nil when the on-goal answer is missing.
    public static func parseAnswers(_ answers: JSONValue?, goalQuestions: JSONValue? = nil,
                                    rubric: JSONValue? = nil) -> Dict? {
        guard let a = dict(answers) else { return nil }
        var out: Dict = [:]
        var scores: [String: Double?] = [:]
        for (k, levels) in scoreLevels {
            scores[k] = dict(a[k]).flatMap { expect($0, levels) }
        }
        guard let onGoalExp = scores["on_goal"] ?? nil else { return nil }
        let act = dict(a["activity"]) ?? [:]
        let probs = dict(act["probabilities"]) ?? [:]
        var choice = pyStrOr(act["choice"])
        if !activityKeys.contains(choice) && !probs.isEmpty {
            // max() keeps the first of equal values; Python's order is the
            // answer's key order, which TypeSafe gives in criteria order.
            let keys = probs.keys.sorted { l, r in
                let il = activityKeys.firstIndex(of: l) ?? Int.max, ir = activityKeys.firstIndex(of: r) ?? Int.max
                return il != ir ? il < ir : l < r
            }
            var best = keys[0]
            for k in keys.dropFirst() where num0(probs[k]) > num0(probs[best]) { best = k }
            choice = best
        }
        out["activity"] = .object(probs.mapValues { .number(pyRound(clamp($0), 3)) })
        out["mode"] = .string(["making", "studying", "consuming"].contains(choice) ? choice : "other")
        out["static"] = .bool(choice == "static")
        for (k, q) in [("serves_goal", "serves_goal"), ("step", "step_toward_goal")] {
            out[k] = .number(dict(a[q]).map { clamp($0["noul"]) } ?? 0)
        }
        out["p_on_task"] = jnum(scoreDecision(a["on_goal"]).pOn)
        let comb = combineChecks(answers, a["on_goal"])
        out["on_goal_raw"] = .number(pyRound(onGoalExp, 3))
        scores["on_goal"] = comb["on_goal"]?.doubleValue
        out["confidence"] = comb["confidence"]
        out["confidence_raw"] = comb["confidence_raw"]
        for (k, cap) in dict(comb["caps"]) ?? [:] {
            if let v = scores[k] ?? nil, let c = cap.doubleValue { scores[k] = min(v, c) }
        }
        out["on"] = comb["on"]
        out["off"] = comb["off"]
        out["check_tells"] = comb["tells"]
        out["check_off_tells"] = comb["off_tells"]
        out["check_p"] = comb["probs"]
        out["checks_answered"] = comb["answered"]
        for (k, _) in scoreLevels {
            out[k] = jnum((scores[k] ?? nil).map { pyRound($0, 3) })
        }
        let (tOn, tOff) = goalAnswers(answers, goalQuestions)
        out["tells_on"] = strings(tOn)
        out["tells_off"] = strings(tOff)
        out["milestones"] = strings(milestonesReached(answers, rubric))
        return out
    }

    static func doing(_ mode: String, _ screen: Dict) -> String {
        let app = cut(squash(pyStrOr(screen["app"])), 24)
        let title = cut(squash(pyStrOr(screen["title"])), 40)
        let verb = ["making": "working in", "studying": "reading in", "consuming": "browsing"][mode] ?? "in"
        var whereS = pyStrip(app + (title.isEmpty ? "" : " — " + title), [" ", "—"])
        if whereS.isEmpty { whereS = "an app" }
        return cut("\(verb) \(whereS)", 80)
    }

    /// One verdict as the row the block keeps, plus `judge: jev`.
    public static func verdictRow(_ v: Dict, screen: Dict, at: Double) -> Dict {
        let mode = pyStr(v["mode"])
        var top = ""
        if let act = dict(v["activity"]), !act.isEmpty {
            let keys = act.keys.sorted { l, r in
                let il = activityKeys.firstIndex(of: l) ?? Int.max, ir = activityKeys.firstIndex(of: r) ?? Int.max
                return il != ir ? il < ir : l < r
            }
            var best = keys[0]
            for k in keys.dropFirst() where num0(act[k]) > num0(act[best]) { best = k }
            top = "\(best) \(pyRoundInt(num0(act[best]) * 100))%"
        }
        let onGoal = v["on_goal"] ?? .null
        let working = present(v["working"]) ? v["working"]! : onGoal
        var r: Dict = [
            "on_goal": onGoal, "working": working,
            "quality": present(v["quality"]) ? v["quality"]! : (v["working"] ?? .null),
            "producing": v["producing"] ?? .null, "progress": v["progress"] ?? .null, "smart": v["smart"] ?? .null,
            "mode": .string(mode), "doing": .string(doing(mode, screen)), "note": .string(""),
            "actual_goal": .string(""), "serves_goal": .bool(num0(v["serves_goal"]) >= related),
            "step": .number(pyRound(truthy(v["step"]) ? num0(v["step"]) : 0, 3)),
            "automatable": .string(""),
            "evidence": .string(cut("jev: " + top + ", on goal \(pyStrFloat(onGoal))", 120)),
            "confidence": v["confidence"] ?? .null, "p_on_task": v["p_on_task"] ?? .null,
            "text_chars": .number(Double(truthy(screen["text_chars"]) ? pyInt(num0(screen["text_chars"])) : 0)),
            "image": .bool(truthy(screen["image"])),
            "judge": .string("jev"), "at": .number(at), "app": .string(cut(pyStrOr(screen["app"]), 60)),
            "url": .string(cut(pyStrOr(screen["url"]), 300)),
            "tells_on": .array(list(v["tells_on"]) ?? []), "tells_off": .array(list(v["tells_off"]) ?? []),
            "on": v["on"] ?? .null, "off": v["off"] ?? .null,
            "on_goal_raw": v["on_goal_raw"] ?? onGoal,
            "check_p": .object(dict(v["check_p"]) ?? [:]),
        ]
        if truthy(v["milestones"]) { r["milestones"] = .array(list(v["milestones"]) ?? []) }
        if truthy(v["check_tells"]) { r["tells"] = .array(list(v["check_tells"]) ?? []) }
        if truthy(v["check_off_tells"]) { r["off_tells"] = .array(list(v["check_off_tells"]) ?? []) }
        return r
    }

    /// The deterministic rules on top of Jev's verdict, in order: his ruling;
    /// a distraction site past DISTRACTION_S; the goal's own tells; serving
    /// the goal or a step toward it; away. Returns a new row.
    public static func settleRow(_ row: Dict, site: String = "", siteS: Double = 0, ruled: Bool = false,
                                 away: Bool = false) -> Dict {
        var r = row
        var on = num0(r["on_goal"])
        let tellsOn = strList(r["tells_on"])
        let tellsOff = strList(r["tells_off"])
        if ruled {
            r["serves_goal"] = .bool(true)
            r["ruled"] = .bool(true)
            r["on_goal"] = .number(pyRound(max(on, stepOnGoal), 3))
            return r
        }
        if !site.isEmpty {
            r["site"] = .string(site)
            r["site_s"] = .number(Double(pyInt(siteS)))
            if siteS >= distractionS && !truthy(r["serves_goal"]) && tellsOn.isEmpty {
                r["off_site"] = .bool(true)
                r["mode"] = .string("consuming")
                r["on_goal"] = .number(min(on, distractionOnGoal))
                r["working"] = .number(min(num0(r["working"]), distractionOnGoal))
                r["quality"] = .number(min(num0(r["quality"]), distractionOnGoal))
                r["confidence"] = .number(max(num0(r["confidence"]), 0.9))
                r["step"] = .number(0)
                return r
            }
        }
        let strTells = { (x: JSONValue?) in list(x) ?? [] }
        if !tellsOn.isEmpty {
            r["on_goal"] = .number(pyRound(max(on, stepOnGoal), 3))
            r["goal_tells"] = strings(tellsOn)
            r["tells"] = .array(tellsOn.map { .string($0) }
                                + strTells(r["tells"]).filter { t in !tellsOn.contains { .string($0) == t } })
            on = num0(r["on_goal"])
        } else if !tellsOff.isEmpty && !truthy(r["serves_goal"]) {
            r["on_goal"] = .number(pyRound(min(on, goalOffOnGoal), 3))
            r["goal_off_tells"] = strings(tellsOff)
            r["off_tells"] = .array(tellsOff.map { .string($0) }
                                    + strTells(r["off_tells"]).filter { t in !tellsOff.contains { .string($0) == t } })
            on = num0(r["on_goal"])
        }
        if truthy(r["serves_goal"]) {
            r["on_goal"] = .number(pyRound(max(on, stepOnGoal), 3))
        } else if num0(r["step"]) >= step && r["mode"] != .string("consuming") && site.isEmpty
                    && !truthy(r["goal_off_tells"]) {
            r["on_goal"] = .number(pyRound(max(on, stepOnGoal), 3))
            r["stepped"] = .bool(true)
        }
        if away {
            r["away"] = .bool(true)
            r["mode"] = .string("other")
            r["working"] = .number(min(num0(r["working"]), 0.1))
            r["producing"] = .number(min(num0(r["producing"]), 0.1))
        }
        return r
    }

    /// This second showed it was tied to the task: serving the goal, a step
    /// toward it, a goal tell, a second-opinion yes, or ruled for work by him.
    public static func rowRelated(_ r: Dict?) -> Bool {
        guard let r, !truthy(r["off_site"]) else { return false }
        if truthy(r["serves_goal"]) || truthy(r["ruled"]) || truthy(r["stepped"]) || truthy(r["goal_tells"])
            || r["second"] == .string("yes") {
            return true
        }
        if truthy(r["goal_off_tells"]) || r["second"] == .string("no") { return false }
        return num0(r["step"]) >= step && r["mode"] != .string("consuming") && !truthy(r["site"])
    }

    /// Confidently off task this second: a distraction site past its five
    /// seconds, or Jev sure it is unrelated — never reading, away or related.
    public static func rowOffTask(_ r: Dict?) -> Bool {
        guard let r, !rowRelated(r), !truthy(r["away"]) else { return false }
        if truthy(r["off_site"]) { return true }
        return num0(r["on_goal"]) < offTaskOnGoal && num0(r["confidence"]) >= offTaskConfidence
            && r["mode"] != .string("studying")
    }

    // MARK: Nudges

    /// Confidently off task CONTINUOUSLY for `needS` seconds ending now, no
    /// gap in the seconds longer than OFF_TASK_GAP_S.
    public static func offTaskRun(_ rows: [Dict], now: Double, needS: Double = offTaskS) -> Bool {
        let rs = rows.enumerated().compactMap { (i, r) -> (Int, Double, Dict)? in
            num(r["at"]).map { (i, $0, r) }
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard let last = rs.last, now - last.1 <= offTaskGapS else { return false }
        var prev: Double?
        for (_, at, r) in rs.reversed() {
            if let prev, prev - at > offTaskGapS { return false }
            if !rowOffTask(r) { return false }
            if now - at >= needS { return true }
            prev = at
        }
        return false
    }

    /// A nudge now: OFF_TASK_S of continuous confident off task, not in the
    /// block's first NUDGE_GRACE_S, and none in the last `gapS`.
    public static func nudgeDue(_ rows: [Dict], now: Double, blockStarted: Double, lastNudgeAt: Double,
                                gapS: Double) -> Bool {
        if blockStarted != 0 && now - blockStarted < nudgeGraceS { return false }
        if now - lastNudgeAt < gapS { return false }
        return offTaskRun(rows, now: now)
    }

    /// Ask Jev when something changed, else only every `heartbeatS`.
    public static func throttle(changed: Bool, lastCallAt: Double, now: Double, heartbeatS: Double = heartbeatS) -> Bool {
        changed || now - lastCallAt >= heartbeatS
    }

    // MARK: The minute frame

    /// A minute of second-verdicts folded into ONE frame row. nil with fewer than MINUTE_MIN_ROWS.
    public static func minuteFrame(_ rows: [Dict], screen: Dict, at: Double) -> Dict? {
        let rs = rows.filter { present($0["on_goal"]) }
        if rs.count < minuteMinRows { return nil }
        func mean(_ k: String) -> Double? {
            let vals = rs.compactMap { present($0[k]) ? pyFloat($0[k]) : nil }
            return vals.isEmpty ? nil : pyRound(vals.reduce(0, +) / Double(vals.count), 3)
        }
        func tally(_ keys: [String]) -> (top: String, counts: [String: Int]) {
            var order: [String] = [], counts: [String: Int] = [:]
            for k in keys {
                if counts[k] == nil { order.append(k) }
                counts[k, default: 0] += 1
            }
            var top = order[0]
            for k in order.dropFirst() where counts[k]! > counts[top]! { top = k }
            return (top, counts)
        }
        let modes = tally(rs.map { truthy($0["mode"]) ? pyStr($0["mode"]) : "other" })
        let mode = modes.top
        let prog = rs.compactMap { r -> Double? in
            guard present(r["progress"]), num0(r["confidence"]) >= progressConfidence else { return nil }
            return pyFloat(r["progress"])
        }
        let serves = Double(rs.filter { truthy($0["serves_goal"]) }.count) >= Double(rs.count) / 2
        let offSite = rs.filter { truthy($0["off_site"]) }.count
        let away = rs.filter { truthy($0["away"]) }.count
        let topApp = tally(rs.map { pyStrOr($0["app"]) }).top
        let urlRows = rs.filter { r in
            if let a = r["app"], case .string(let s) = a { return s == topApp }
            return false
        }
        let topURL = urlRows.isEmpty ? pyStrOr(screen["url"]) : tally(urlRows.map { pyStrOr($0["url"]) }).top
        var note = "\(rs.count) seconds judged, \(pyRoundInt(100 * Double(modes.counts[mode]!) / Double(rs.count)))% \(mode)"
        if offSite > 0 { note += ", \(offSite) s on a distraction site" }
        if away > 0 { note += ", \(away) s away" }
        let titleScreen: Dict = ["app": .string(topApp), "title": screen["title"] ?? .null]
        return ["on_goal": jnum(mean("on_goal")), "working": jnum(mean("working")), "quality": jnum(mean("quality")),
                "producing": jnum(mean("producing")), "smart": jnum(mean("smart")),
                "progress": jnum(prog.max().map { pyRound($0, 3) }),
                "mode": .string(mode), "doing": .string(doing(mode, titleScreen)),
                "note": .string(cut(note, 100)), "actual_goal": .string(""), "serves_goal": .bool(serves),
                "automatable": .string(""),
                "evidence": .string(cut("jev minute: on goal \(pyStrFloat(jnum(mean("on_goal")))), "
                                        + "working \(pyStrFloat(jnum(mean("working"))))", 120)),
                "confidence": jnum(mean("confidence")), "judge": .string("jev"), "seconds": .number(Double(rs.count)),
                "distraction_s": .number(Double(offSite)), "away_s": .number(Double(away)),
                "at": .number(at), "app": .string(cut(topApp, 60)), "url": .string(cut(topURL, 300))]
    }

    // MARK: The label file and the today line

    /// One line of the label file: what Jev saw and said at a nudge, and what
    /// he said back. Never the visible text: only its digest.
    public static func labelRow(at: Double, user: String, blockId: String, goal: String, specific: String,
                                screen: Dict, text: String, row: Dict?, label: String, source: String) -> Dict {
        let r = row ?? [:]
        let jevPart: Dict = [
            "on_goal": r["on_goal"] ?? .null, "working": r["working"] ?? .null, "mode": r["mode"] ?? .null,
            "serves_goal": .bool(truthy(r["serves_goal"])), "confidence": r["confidence"] ?? .null,
            "step": r["step"] ?? .null, "stepped": .bool(truthy(r["stepped"])),
            "related": .bool(rowRelated(r)), "off_site": .bool(truthy(r["off_site"])),
            "site": truthy(r["site"]) ? r["site"]! : .string(""),
            "tells": .array(truthy(r["tells"]) ? list(r["tells"]) ?? [] : []),
            "off_tells": .array(truthy(r["off_tells"]) ? list(r["off_tells"]) ?? [] : []),
            "second": truthy(r["second"]) ? r["second"]! : .string(""),
            "on": r["on"] ?? .null, "off": r["off"] ?? .null, "on_goal_raw": r["on_goal_raw"] ?? .null]
        return ["at": .number(at), "user": .string(user), "block_id": .string(blockId),
                "goal": .string(cut(goal, 200)), "specific_goal": .string(cut(specific, 240)),
                "app": .string(cut(pyStrOr(screen["app"]), 60)), "title": .string(cut(pyStrOr(screen["title"]), 200)),
                "url": .string(cut(pyStrOr(screen["url"]), 300)), "text_digest": .string(textDigest(text)),
                "jev": .object(jevPart), "image_used": .bool(truthy(r["image"])), "label": .string(label),
                "source": .string(source)]
    }

    /// 'Today's plan: X; Y. Next on the calendar: 14:00 team meeting; ...' (≤ TODAY_MAX_CHARS) or ''.
    public static func todayLine(_ planGoals: [String?], _ nextEvents: [(clock: String, title: String?)]) -> String {
        var parts: [String] = []
        let goals = planGoals.map { cut(squash($0 ?? ""), 70) }.filter { !$0.isEmpty }.prefix(5)
        if !goals.isEmpty { parts.append("Today's plan: " + goals.joined(separator: "; ") + ".") }
        let evs = nextEvents.prefix(2).map { pyStrip("\($0.clock) \(cut(squash($0.title ?? ""), 50))") }
            .filter { !$0.isEmpty }
        if !evs.isEmpty { parts.append("Next on the calendar: " + evs.joined(separator: "; ") + ".") }
        return cut(parts.joined(separator: " "), todayMaxChars)
    }

    // MARK: The state and the image

    /// The `assets` map for one screenshot (TypeSafe images: base64 JPEG, a unique reference in the state).
    public static func imageAsset(_ jpegB64: String, ref: String) -> Dict {
        [ref: .object(["type": .string("image"), "format": .string("jpg"), "data_base64": .string(jpegB64)])]
    }

    /// The same state with the screenshot taken out (the text-only fallback).
    public static func withoutImage(_ state: Dict) -> Dict {
        var out = state
        var screen = dict(out["screen_now"]) ?? [:]
        screen["screenshot"] = nil
        out["screen_now"] = .object(screen)
        return out
    }

    /// The labelled record Jev reads. `screen` = {app, title, url, text};
    /// `change` = {typed, scrolled, idle_s, text_changed_share, app_switched,
    /// seconds_on_this_screen}; `recent` = the last seconds' verdict rows,
    /// oldest first (each with `ago`); see brain/jev.py `build_state`.
    public static func buildState(goal: String, specific: String, understood: String, progressSoFar: Double,
                                  screen: Dict, change: Dict, recent: [Dict], story: String = "",
                                  related: JSONValue? = nil, rulings: [String]? = nil, imageRef: String = "",
                                  site: String = "", siteS: Double = 0, rules: [String]? = nil, profile: String = "",
                                  goalQuestions: JSONValue? = nil, today: String = "",
                                  milestones: JSONValue? = nil) -> Dict {
        let text = cut(squash(pyStrOr(screen["text"])), maxTextChars)
        let textLen = plen(text)
        var rows: [JSONValue] = []
        for r in recent.suffix(recentRows) {
            rows.append(.object(["seconds_ago": .number(Double(pyInt(num0(r["ago"])))), "activity": r["mode"] ?? .null,
                                 "on_goal": r["on_goal"] ?? .null, "working": r["working"] ?? .null,
                                 "tied_to_task": .bool(rowRelated(r))]))
        }
        let idle = num0(change["idle_s"])
        let studying = rows.last?["activity"] == .string("studying")
        let allowance = idleLimit(screen, textLen: textLen, studying: studying)
        let url = pyStrOr(screen["url"])
        var nowScreen: Dict = [
            "app": .string(pyStrOr(screen["app"])), "window_title": .string(pyStrOr(screen["title"])),
            "url": .string(url), "search_words": .string(searchWords(url)),
            "visible_text": .string(text), "text_is_thin": .bool(textLen < 80),
            "picture_app": .bool(pictureApp(pyStrOr(screen["app"]), url)),
            "reading_material": .bool(readingMaterial(screen, textLen: textLen))]
        if !imageRef.isEmpty { nowScreen["screenshot"] = .string(imageRef) }
        if !site.isEmpty {
            nowScreen["distraction_site"] = .object(["site": .string(site),
                                                     "seconds_in_front": .number(Double(pyInt(siteS)))])
        }
        var goalPart: Dict = ["named": .string(goal), "specific": .string(specific), "meaning": .string(understood),
                              "progress_so_far": .number(pyRound(clamp(progressSoFar), 2)),
                              "related": .object(relatedTerms(related))]
        let checks = goalQuestionsClean(goalQuestions)
        if !checks.isEmpty {
            goalPart["checks"] = .array(checks.map {
                .object(["id": .string(qid($0.id)), "question": .string($0.text),
                         "if_yes": .string($0.means == "on_task" ? "on task" : "off task")])
            })
        }
        let ms = (list(milestones) ?? []).compactMap { m -> Dict? in
            guard let d = dict(m), truthy(d["id"]), truthy(d["text"]) else { return nil }
            return d
        }
        if !ms.isEmpty {
            goalPart["milestones"] = .array(ms.map {
                .object(["id": .string(rubricPrefixMs + pyStr($0["id"])), "milestone": .string(pyStr($0["text"]))])
            })
        }
        var state: Dict = [
            "goal": .object(goalPart),
            "story_so_far": .string(cut(story, storyMaxChars)),
            "screen_now": .object(nowScreen),
            "since_last_second": .object([
                "typed": .bool(truthy(change["typed"])), "scrolled": .bool(truthy(change["scrolled"])),
                "seconds_since_any_input": .number(Double(pyInt(idle))), "idle_allowance_s": .number(Double(allowance)),
                "share_of_text_that_changed": .number(pyRound(clamp(change["text_changed_share"]), 2)),
                "app_switched": .bool(truthy(change["app_switched"])),
                "seconds_on_this_screen": .number(Double(pyInt(num0(change["seconds_on_this_screen"])))),
                "no_input_too_long": .bool(idle >= Double(allowance))]),
            "recent_verdicts_oldest_first": .array(rows),
            "his_rulings_this_block": strings((rulings ?? []).prefix(10).map { cut($0, 200) }),
            "standing_rules": strings(rules ?? standingRules),
        ]
        if !today.isEmpty { state["today"] = .string(cut(today, todayMaxChars)) }
        if !profile.isEmpty { state["about_him"] = .string(cut(profile, 1200)) }
        return state
    }
}
