import Foundation

// MARK: - tick, event, block, now, history, settings (app.py `_focus_tick` … `_focus_settings*`)

extension LocalBrainCore {
    static let historyDaysDefault = 30
    static let historyDaysMax = 90

    // MARK: tick

    /// One minute of the running block. Fields are the last minute's values.
    func tick(_ data: D) -> (Int, JSONValue) {
        let blockId = LocalJSON.s(data["block_id"], 80)
        let phase = data["phase"]?.stringValue == "break" ? "break" : "work"
        let now = nowTs
        let at = LocalJSON.toTs(data["at"])
        let tick: D = ["at": .number(at != 0 ? at : now), "phase": .string(phase),
                       "active_s": LocalJSON.n(LocalJSON.num(data["active_s"])),
                       "idle_s": LocalJSON.n(LocalJSON.num(data["idle_s"])),
                       "switches": LocalJSON.n(LocalJSON.num(data["switches"])),
                       "scroll_s": LocalJSON.n(LocalJSON.num(data["scroll_s"])),
                       "keys_s": LocalJSON.n(LocalJSON.num(data["keys_s"])),
                       "distraction_s": LocalJSON.n(LocalJSON.num(data["distraction_s"])),
                       "app": .string(LocalJSON.s(data["app"], 60)), "title": .string(LocalJSON.s(data["title"], 120)),
                       "url": .string(LocalJSON.s(data["url"], 300))]
        switchBlock(blockId, goal: LocalJSON.s(data["goal"], 200), plannedS: data["planned_s"])
        st["active"] = .bool(true); st["phase"] = .string(phase); st["last_seen"] = .number(now)
        st["last_tick_at"] = .number(now)
        st["ticks"] = .array(Array((LocalJSON.list(st["ticks"]) + [.object(tick)]).suffix(Self.ticksKept)))
        save()
        return (200, .object(["ok": .bool(true)]))
    }

    // MARK: event

    func event(_ data: D) -> (Int, JSONValue) {
        let kind = Judge.pyStrOr(data["kind"])
        guard ["session_started", "session_stopped", "break_skipped", "block_started"].contains(kind) else {
            return (400, .object(["error": .string("unknown kind")]))
        }
        let now = nowTs
        let atSent = LocalJSON.toTs(data["at"])
        let at = atSent != 0 ? atSent : now
        let row: D = ["kind": .string(kind), "block_id": .string(LocalJSON.s(data["block_id"], 80)),
                      "goal": .string(LocalJSON.s(data["goal"], 200)), "at": .number(at)]
        var events = LocalJSON.dicts(st["events"])
        if !events.contains(where: { $0["kind"] == row["kind"] && $0["block_id"] == row["block_id"]
                                    && abs(LocalJSON.num0($0["at"]) - at) < 1 }) {
            events.append(row)
            st["events"] = .array(events.suffix(Self.eventsKept).map { .object($0) })
        }
        if kind == "session_stopped" {
            st["active"] = .bool(false); st["phase"] = .string("")
        } else {
            st["active"] = .bool(true); st["last_seen"] = .number(now)
            if kind == "block_started" {
                let blockId = Judge.pyStr(row["block_id"])
                switchBlock(blockId, goal: Judge.pyStr(row["goal"]), plannedS: data["planned_s"])
                if !blockId.isEmpty { st["block_started_at"] = .number(at) }
                st["phase"] = .string("work")
            } else if kind == "break_skipped" {
                st["phase"] = .string("work")
            }
        }
        save()
        return (200, .object(["ok": .bool(true)]))
    }

    func events(day: String) -> [D] {
        LocalJSON.dicts(st["events"]).filter { LocalJSON.dayOf(LocalJSON.num0($0["at"])) == day }
    }

    /// `_focus_started_ids`.
    func startedIds(day: String) -> [JSONValue] {
        events(day: day).filter { $0["kind"] == .string("block_started") && Judge.truthy($0["block_id"]) }
            .map { $0["block_id"]! }
    }

    // MARK: block

    /// Score a finished work block and keep it. Idempotent by block_id: a retried post gets back exactly what
    /// was stored the first time.
    func block(_ data: D) -> (Int, JSONValue) {
        let blockId = LocalJSON.s(data["block_id"], 80)
        guard !blockId.isEmpty else { return (400, .object(["error": .string("block_id is required")])) }
        if let stored = storedBlock(blockId) { return (200, Self.blockReply(stored)) }
        let started = LocalJSON.toTs(data["started_at"])
        let endedSent = LocalJSON.toTs(data["ended_at"])
        let ended = endedSent != 0 ? endedSent : nowTs
        let day = LocalJSON.dayOf(started != 0 ? started : ended)
        let apps: [JSONValue] = LocalJSON.list(data["apps"]).prefix(40).compactMap { a in
            guard let a = LocalJSON.dict(a) else { return nil }
            return .object(["app": .string(LocalJSON.s(a["app"], 60)), "title": .string(LocalJSON.s(a["title"], 160)),
                            "url": .string(LocalJSON.s(a["url"], 300)), "seconds": .number(LocalJSON.num(a["seconds"]) ?? 0)])
        }
        let sentFrames: [D] = LocalJSON.dicts(data["frames"]).prefix(Self.framesPerBlock * 2).map(Self.cleanFrame)
        let sameBlock = str("block_id") == blockId
        let liveTicks = sameBlock ? LocalJSON.dicts(st["ticks"]) : []
        let liveFrames = sameBlock ? LocalJSON.dicts(st["frames"]) : []
        let sentUnd = LocalJSON.s(data["understood"], 240)
        let understood = sentUnd.isEmpty ? understoodFor(LocalJSON.s(data["goal"], 200)) : sentUnd
        let goalBits = blockGoal(blockId, data: data, liveFrames: liveFrames)
        let frames = Self.enrichFrames(sentFrames, live: liveFrames)
        let sentTicks = LocalJSON.dicts(data["ticks"]).prefix(Self.ticksKept + 20)
        let ticks = sentTicks.isEmpty ? liveTicks : Array(sentTicks)
        let ticksJSON: JSONValue = .array(ticks.map { .object($0) })
        var block: D = ["block_id": .string(blockId), "goal": .string(LocalJSON.s(data["goal"], 200)),
                        "understood": .string(understood), "started_at": .number(started), "ended_at": .number(ended),
                        "planned_s": .number(LocalJSON.num(data["planned_s"]).flatMap { $0 == 0 ? nil : $0 } ?? 1500),
                        "completed": .bool(Judge.truthy(data["completed"])),
                        "active_s": .number(LocalJSON.num(data["active_s"]) ?? 0),
                        "switches": .number(LocalJSON.num(data["switches"]) ?? 0),
                        "apps": .array(apps), "frames": .array(frames.map { .object($0) }),
                        "distraction_s": .number(LocalJSON.num(data["distraction_s"]).flatMap { $0 == 0 ? nil : $0 }
                                                 ?? ticks.filter { Judge.pyStrOr($0["phase"]).localNonEmpty ?? "work" == "work" }
                                                    .reduce(0) { $0 + LocalJSON.num0($1["distraction_s"]) }),
                        "input_minutes": LocalJSON.n(Scoring.inputMinutes(ticksJSON))]
        block.merge(goalBits) { $1 }
        if let r = LocalJSON.dict(block["rubric"]), !LocalJSON.list(r["milestones"]).isEmpty {
            // With milestones, how far he got is the share of them reached.
            block["goal_achieved"] = .number(LocalJSON.r3(Double(LocalJSON.list(block["milestones_reached"]).count)
                                                          / Double(LocalJSON.list(r["milestones"]).count)))
        }
        let result = LocalJSON.dict(Scoring.scoreBlock(.object(block), rubric: block["rubric"])) ?? [:]
        // A skipped break is his call and costs nothing; it is only noted.
        let skipped = started != 0 && events(day: day).contains {
            $0["kind"] == .string("break_skipped") && started - 15 * 60 <= LocalJSON.num0($0["at"])
                && LocalJSON.num0($0["at"]) <= started + 60
        }
        var record = block.merging(result) { $1 }
        record["after_skipped_break"] = .bool(skipped)
        record["stored_at"] = .number(nowTs)
        record.merge(nextLength(block: block, ticks: ticks, liveFrames: liveFrames, earlier: blocksOf(day: day))) { $1 }
        history.append(.object(record))
        store.saveHistory(history)
        writeReport(day: day)
        // The work-smarter paragraph is one Claude call over the block that just ended; it runs in the
        // background and rewrites the day's report itself when it lands, so the reply never waits for it.
        let k = keys
        if !k.anthropic.isEmpty {
            let shot = lastFrame.flatMap { $0.blockId == blockId ? $0.b64 : nil } ?? ""
            lastFrame = nil
            background.append(Task { await self.adviceRun(day: day, blockId: blockId, record: record, ticks: ticks,
                                                          jpegBase64: shot) })
        } else {
            lastFrame = nil
        }
        return (200, Self.blockReply(record))
    }

    static func cleanFrame(_ f: D) -> D {
        func n(_ k: String) -> JSONValue { LocalJSON.n(LocalJSON.num(f[k])) }
        let mode = Judge.pyStrOr(f["mode"]).trimmingCharacters(in: .whitespaces).lowercased()
        return ["on_goal": n("on_goal"), "working": n("working"), "quality": n("quality"), "progress": n("progress"),
                "smart": n("smart"), "mode": .string(Scoring.frameModes.contains(mode) ? mode : ""),
                "doing": .string(LocalJSON.s(f["doing"], 80)), "note": .string(LocalJSON.s(f["note"], 100)),
                "actual_goal": .string(LocalJSON.s(f["actual_goal"], 80)), "pending": .bool(Judge.truthy(f["pending"])),
                "serves_goal": .bool(Judge.truthy(f["serves_goal"])), "detour": .bool(Judge.truthy(f["detour"])),
                "evidence": .string(LocalJSON.s(f["evidence"], 120)),
                "automatable": .string(LocalJSON.s(f["automatable"], 160)),
                "at": .number(LocalJSON.toTs(f["at"])), "app": .string(LocalJSON.s(f["app"], 60)),
                "url": .string(LocalJSON.s(f["url"], 300))]
    }

    /// `_focus_enrich_frames`: fill what the app's copy lacks from what was judged live, matched by time; no
    /// frames sent at all → the live ones.
    static func enrichFrames(_ sent: [D], live: [D]) -> [D] {
        if sent.isEmpty { return live }
        return sent.map { f in
            var g = f
            let at = LocalJSON.num0(g["at"])
            guard at != 0, let match = live.first(where: { abs(LocalJSON.num0($0["at"]) - at) <= 5 }) else { return g }
            func empty(_ v: JSONValue?) -> Bool { v == nil || v == .null || v == .string("") }
            for k in ["mode", "note", "doing", "actual_goal", "progress", "smart", "evidence"]
            where empty(g[k]) && !empty(match[k]) { g[k] = match[k] }
            for k in ["serves_goal", "detour"] where Judge.truthy(match[k]) { g[k] = .bool(true) }
            if Judge.truthy(match["retro"]) || Judge.truthy(match["rescored"]) || Judge.truthy(match["pending"]) {
                for k in ["on_goal", "working", "quality", "pending"] where match[k] != nil { g[k] = match[k] }
                for k in ["retro", "rescored"] where Judge.truthy(match[k]) { g[k] = .bool(true) }
            }
            return g
        }
    }

    /// `_focus_block_goal` (+ `_focus_block_rubric`).
    func blockGoal(_ blockId: String, data: D, liveFrames: [D]) -> D {
        let live = !blockId.isEmpty && str("progress_block") == blockId
        var got: [Double] = [LocalJSON.num(data["goal_progress"]), LocalJSON.num(data["goal_achieved"])].compactMap { $0 }
        if live, let p = LocalJSON.num(st["goal_progress"]) { got.append(p) }
        got += liveFrames.compactMap { LocalJSON.num($0["progress"]) }
        got = got.map { Judge.clamp($0) }
        var spec = LocalJSON.num(data["specificity"])
        if spec == nil && live { spec = LocalJSON.num(st["specificity"]) }
        let sentSpec = LocalJSON.s(data["specific_goal"], 240)
        let sentOrig = LocalJSON.s(data["original_goal"], 240)
        let sentInf = LocalJSON.s(data["inferred_goal"], 80)
        var out: D = ["specific_goal": .string(sentSpec.isEmpty ? (live ? str("specific_goal") : "") : sentSpec),
                      "original_goal": .string(sentOrig),
                      "specificity": spec.map { .number(PortedText.round2(Judge.clamp($0))) } ?? .null,
                      "goal_achieved": got.max().map { .number(LocalJSON.r3($0)) } ?? .null,
                      "inferred_goal": .string(sentInf.isEmpty ? (live ? str("inferred_goal") : "") : sentInf)]
        if live, let r = rubricLive() {
            let mb = str("milestones_block")
            out["rubric"] = .object(["kind": r["kind"] ?? .null, "balance": r["balance"] ?? .null,
                                     "milestones": .array(LocalJSON.list(r["milestones"]))])
            out["milestones_reached"] = mb == blockId ? .array(LocalJSON.list(st["milestones_reached"])) : .array([])
        }
        return out
    }

    /// `_focus_next_length`: where his focus broke in this block, and how long the next one is.
    func nextLength(block: D, ticks: [D], liveFrames: [D], earlier earlierIn: [D]) -> D {
        let sent = LocalJSON.dicts(block["frames"]).filter { Judge.truthy($0["at"]) }
        let frames = liveFrames.count >= sent.count ? liveFrames : sent
        let brk = Scoring.breakPointS(ticks: .array(ticks.map { .object($0) }), frames: .array(frames.map { .object($0) }),
                                      startedAt: block["started_at"], endedAt: block["ended_at"])
        let earlier = earlierIn.sorted { LocalJSON.num0($0["ended_at"]) < LocalJSON.num0($1["ended_at"]) }
        let planned = LocalJSON.num0(block["planned_s"])
        var scale = 1.0
        func lenScale(_ b: D) -> Double { LocalJSON.num(b["len_scale"]).flatMap { $0 == 0 ? nil : $0 } ?? 1.0 }
        if planned < Scoring.testModeBelowS {
            scale = earlier.map(lenScale).first { $0 < 1.0 } ?? Scoring.lengthScale(planned)
        }
        let sameMode = earlier.filter { (lenScale($0) < 1.0) == (scale < 1.0) }
        let breaks = sameMode.compactMap { b in LocalJSON.num(b["break_s"]).map { $0 / lenScale(b) } }
        let out = Scoring.nextBlockLength(breakS: brk, todayBreaksScaled: breaks, currentS: planned, capS: nil,
                                          scale: scale)
        return ["break_s": brk.map { .number(Judge.pyRound($0, 1)) } ?? .null, "len_scale": .number(scale),
                "next_work_s": .number(Double(out.nextWorkS)), "next_reason": .string(out.nextReason)]
    }

    /// `_focus_block_reply`.
    static func blockReply(_ record: D) -> JSONValue {
        var out: D = ["score": record["score"] ?? .null, "parts": record["parts"] ?? .null,
                      "advice": record["advice"] ?? .string(""), "why": record["why"] ?? .string("")]
        for k in ["focus_score", "output_score"] where ScorePy.intValue(record[k]) != nil { out[k] = record[k] }
        if let g = record["goal_achieved"], g != .null { out["goal_achieved"] = g }
        for k in ["balance", "balance_line", "kind", "milestones", "on_task_share"] {
            if let v = record[k], v != .null { out[k] = v }
        }
        if Judge.truthy(record["next_work_s"]) {
            out["next_work_s"] = .number(Double(Int(LocalJSON.num0(record["next_work_s"]))))
            out["next_reason"] = record["next_reason"] ?? .string("")
        }
        return .object(out)
    }

    // MARK: The advice paragraph (background)

    /// `_focus_advice_stats` + `_focus_advice_prompt` inputs.
    static func adviceInput(_ block: D, ticks: [D]) -> BlockAdvice.Input {
        let rows = ticks.filter { Judge.pyStrOr($0["phase"]) != "break" }
        func total(_ k: String) -> Int? {
            let vals = rows.compactMap { LocalJSON.num($0[k]) }
            return vals.isEmpty ? nil : Judge.pyRoundInt(vals.reduce(0, +))
        }
        let planned = LocalJSON.num(block["planned_s"]).flatMap { $0 == 0 ? nil : $0 } ?? 1500
        let completion = LocalJSON.num(block["completion"]).flatMap { $0 == 0 ? nil : $0 } ?? 1.0
        let stats = BlockAdvice.Stats(minutes: Judge.pyRoundInt(planned * completion / 60),
                                      switches: LocalJSON.num(block["switches"]), activeS: LocalJSON.num(block["active_s"]),
                                      typingSeconds: total("keys_s"), scrollingSeconds: total("scroll_s"),
                                      distractionS: LocalJSON.num(block["distraction_s"]),
                                      score: ScorePy.intValue(block["score"]), focusScore: ScorePy.intValue(block["focus_score"]),
                                      outputScore: ScorePy.intValue(block["output_score"]))
        let frames = LocalJSON.dicts(block["frames"]).map { f in
            BlockAdvice.Frame(doing: Judge.pyStrOr(f["doing"]), note: Judge.pyStrOr(f["note"]),
                              actualGoal: Judge.pyStrOr(f["actual_goal"]), quality: LocalJSON.num(f["quality"]),
                              onGoal: LocalJSON.num(f["on_goal"]), working: LocalJSON.num(f["working"]),
                              smart: LocalJSON.num(f["smart"]), mode: Judge.pyStrOr(f["mode"]),
                              pending: Judge.truthy(f["pending"]), automatable: Judge.pyStrOr(f["automatable"]))
        }
        return BlockAdvice.Input(goal: Judge.pyStrOr(block["goal"]), judgedGoal: FocusDay.blockGoal(.object(block)).goal,
                                 originalGoal: Judge.pyStrOr(block["original_goal"]), frames: frames, stats: stats)
    }

    /// `_focus_advice_run`: the paragraph onto the stored block, into the tip slot for the next block, and the
    /// day's report rewritten.
    func adviceRun(day: String, blockId: String, record: D, ticks: [D], jpegBase64: String) async {
        let k = keys
        guard !k.anthropic.isEmpty else { return }
        let client = AnthropicClient(key: k.anthropic, transport: transport)
        let text = await client.blockAdvice(Self.adviceInput(record, ticks: ticks), jpegBase64: jpegBase64, model: k.model)
        counters.claudeCall(ok: text != nil)
        guard let text else { return }
        if let i = history.lastIndex(where: { $0["block_id"] == .string(blockId) }), case .object(var row) = history[i] {
            row["advice"] = .string(text); row["advice_from"] = .string("claude")
            history[i] = .object(row)
            store.saveHistory(history)
        }
        // The control window shows it when the next block starts.
        if str("block_id") == blockId { st["next_tip"] = .string(text) } else { st["tip"] = .string(text) }
        save()
        writeReport(day: day)
    }

    // MARK: The day's report

    func dayScores() -> JSONValue {
        var out: D = [:]
        let days = Set(LocalJSON.dicts(.array(history)).map { b -> String in
            let s = LocalJSON.toTs(b["started_at"])
            return LocalJSON.dayOf(s != 0 ? s : LocalJSON.toTs(b["ended_at"]))
        })
        for day in days {
            let blocks = blocksOf(day: day).filter { ScorePy.intValue($0["score"]) != nil }
            guard !blocks.isEmpty else { continue }
            let bj: JSONValue = .array(blocks.map { .object($0) })
            let totals = FocusDay.dayTotals(bj, startedIds: startedIds(day: day))
            out[day] = .number(Double(FocusDay.dayScore(FocusDay.dayParts(totals, substance: FocusDay.fallbackSubstance(bj)))))
        }
        return .object(out)
    }

    /// reports/<day>.md: the day's report (FocusDay) rendered as markdown — the server's Google Doc, on disk.
    func writeReport(day: String) {
        let blocks = blocksOf(day: day)
        guard !blocks.isEmpty else { return }
        var scores = LocalJSON.dict(dayScores()) ?? [:]
        scores[day] = nil
        let report = FocusDay.report(day: day, blocks: .array(blocks.map { .object($0) }), startedIds: startedIds(day: day),
                                     history: .object(scores), final: day < LocalJSON.dayOf(nowTs),
                                     goalHours: .number(settings()["daily_hours_goal"]?.doubleValue ?? Self.hoursDefault))
        let md = FocusDay.markdown(FocusDay.docParagraphs(report, tz: .current, updatedAt: nowTs))
        store.writeReport(day: day, markdown: md)
    }

    // MARK: now

    /// `_focus_today`.
    func today() -> JSONValue {
        let blocks = blocksToday().filter { ScorePy.intValue($0["score"]) != nil }
        let goal = settings()["daily_hours_goal"]?.doubleValue ?? Self.hoursDefault
        let focusS = Judge.pyRoundInt(blocks.reduce(0) { $0 + FocusDay.workedS(.object($1)) })
        let stats = Scoring.dayStats(.array(blocks.map { .object($0) }))
        return .object(["focus_s": .number(Double(focusS)), "blocks": .number(Double(blocks.count)),
                        "avg_score": stats["avg"] ?? .null, "goal_hours": .number(goal),
                        "progress": .number(LocalJSON.r3(min(1, Double(focusS) / (goal * 3600))))])
    }

    /// `_focus_now`: what the control window shows. Never a model call.
    func now() -> (Int, JSONValue) {
        let now = nowTs
        let active = sessionActive(now)
        var phase = active ? (str("phase").localNonEmpty ?? "work") : "idle"
        if phase != "work" && phase != "break" { phase = "idle" }
        var ends: JSONValue = .null
        let started = dbl("block_started_at")
        if active && phase == "work" && started != 0 {
            var planned = dbl("block_planned_s")
            if planned == 0 { planned = blocksToday().last.flatMap { LocalJSON.num($0["planned_s"]) } ?? 1500 }
            ends = .number(Double(Judge.pyRoundInt(started + planned)))
        }
        let here = !str("block_id").isEmpty && str("progress_block") == str("block_id")
        let goal = str("goal_label").localNonEmpty ?? str("goal")
        return (200, .object(["active": .bool(active), "phase": .string(phase), "goal": .string(goal),
                              "specific_goal": .string(str("specific_goal")), "criteria": .array([]),
                              "goal_progress": .number(here ? LocalJSON.r3(dbl("goal_progress")) : 0),
                              "tip": .string(active ? str("tip") : ""), "block_ends_at": ends, "today": today(),
                              "typesafe": .string(keys.typesafe.isEmpty ? "missing" : "ok"),
                              "rubric": rubricView()]))
    }

    // MARK: history

    /// `_focus_history`: one row per day he worked, newest first.
    func historyRows(days rawDays: Int) -> [JSONValue] {
        let days = max(1, min(Self.historyDaysMax, rawDays))
        let scores = dayScores()
        let all = Set(LocalJSON.dicts(.array(history)).map { b -> String in
            let s = LocalJSON.toTs(b["started_at"])
            return LocalJSON.dayOf(s != 0 ? s : LocalJSON.toTs(b["ended_at"]))
        }).sorted(by: >)
        var out: [JSONValue] = []
        for day in all {
            if out.count >= days { break }
            let blocks = blocksOf(day: day).filter { ScorePy.intValue($0["score"]) != nil }
            guard !blocks.isEmpty else { continue }
            let bj: JSONValue = .array(blocks.map { .object($0) })
            let totals = FocusDay.dayTotals(bj, startedIds: startedIds(day: day))
            let score = FocusDay.dayScore(FocusDay.dayParts(totals, substance: FocusDay.fallbackSubstance(bj)))
            var others = LocalJSON.dict(scores) ?? [:]
            others[day] = nil
            let verdict = FocusDay.verdictFor(score, rank: FocusDay.rankAmong(score, day: day, history: .object(others)))
            let focusS = Judge.pyRoundInt(blocks.reduce(0) { $0 + FocusDay.workedS(.object($1)) })
            out.append(.object(["day": .string(day), "weekday": .string(LocalJSON.weekday(day)),
                                "focus_s": .number(Double(focusS)), "blocks": .number(Double(blocks.count)),
                                "avg_score": Scoring.dayStats(bj)["avg"] ?? .null, "verdict": .string(verdict),
                                "day_score": .number(Double(score))]))
        }
        return out
    }

    // MARK: settings

    static let hoursDefault = 10.0
    static let hoursRange = (0.5, 16.0)
    static let blockDefaults: [(String, Int)] = [("block_min_minutes", 25), ("block_max_minutes", 60), ("break_minutes", 5)]
    static let blockRanges: [String: (Double, Double)] = ["block_min_minutes": (15, 60), "block_max_minutes": (25, 120),
                                                          "break_minutes": (0, 30)]
    static let planningDefault = "10:00"

    /// 'HH:MM' (24h) or 'morning'; '' when it is neither.
    static func planningValue(_ raw: JSONValue?) -> String {
        let t = Judge.squash(Judge.pyStrOr(raw).lowercased())
        if ["morning", "the morning", "first thing", "after i wake up", "after wake up"].contains(t) { return "morning" }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m)
        else { return "" }
        return String(format: "%02d:%02d", h, m)
    }

    /// `_focus_settings`: the saved settings with defaults.
    func settings() -> D {
        let saved = LocalJSON.dict(st["settings"]) ?? [:]
        var out: D = [:]
        let g = LocalJSON.num(saved["daily_hours_goal"])
        out["daily_hours_goal"] = .number(g.flatMap { (Self.hoursRange.0...Self.hoursRange.1).contains($0) ? $0 : nil }
                                          ?? Self.hoursDefault)
        for (key, def) in Self.blockDefaults {
            let (lo, hi) = Self.blockRanges[key]!
            let v = LocalJSON.num(saved[key])
            out[key] = .number(Double(v.flatMap { (lo...hi).contains($0) ? Int($0) : nil } ?? def))
        }
        if LocalJSON.num0(out["block_max_minutes"]) < LocalJSON.num0(out["block_min_minutes"]) {
            out["block_max_minutes"] = out["block_min_minutes"]
        }
        out["planning_call"] = .string(Self.planningValue(saved["planning_call"]).localNonEmpty ?? Self.planningDefault)
        return out
    }

    func settingsGet() -> (Int, JSONValue) {
        var out = settings()
        out["typesafe"] = .string(keys.typesafe.isEmpty ? "missing" : "ok")
        return (200, .object(out))
    }

    /// `_focus_settings_post`. Keys are not kept here (they live in the app's Keychain and arrive through
    /// `keys()`): a `typesafe_key` is only checked with one tiny Jev call → "typesafe": ok | invalid | missing.
    func settingsPost(_ dataIn: D) async -> (Int, JSONValue) {
        var data = dataIn
        data["anthropic_key"] = nil; data["model"] = nil
        var typesafe: String?
        if let raw = data["typesafe_key"] {
            let key = Judge.pyStrOr(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                typesafe = "missing"
            } else {
                typesafe = await TypeSafeClient.verifyKey(key, transport: transport) ? "ok" : "invalid"
            }
            data["typesafe_key"] = nil
            let others = ["daily_hours_goal", "planning_call"] + Self.blockRanges.keys
            if !others.contains(where: { data[$0] != nil }) {
                return (200, .object(["ok": .bool(typesafe == "ok"), "typesafe": .string(typesafe!)]))
            }
        }
        var new = settings()
        var touched: [String] = []
        if let raw = data["daily_hours_goal"] {
            let g: Double? = { if case .bool = raw { return nil }; return LocalJSON.num(raw) }()
            guard let g, (Self.hoursRange.0...Self.hoursRange.1).contains(g) else {
                return (400, .object(["error": .string("daily_hours_goal must be a number of hours from 0.5 to 16")]))
            }
            new["daily_hours_goal"] = .number(PortedText.round2(g))
            touched.append("daily_hours_goal")
        }
        for (key, _) in Self.blockDefaults {
            guard let raw = data[key] else { continue }
            let (lo, hi) = Self.blockRanges[key]!
            let v: Double? = { if case .bool = raw { return nil }; return LocalJSON.num(raw) }()
            guard let v, (lo...hi).contains(v) else {
                return (400, .object(["error": .string("\(key) must be a number of minutes from \(Int(lo)) to \(Int(hi))")]))
            }
            new[key] = .number(Double(Int(v)))
            touched.append(key)
        }
        if let raw = data["planning_call"] {
            let pc = Self.planningValue(raw)
            guard !pc.isEmpty else {
                return (400, .object(["error": .string("planning_call must be a time like 10:00 or 'morning'")]))
            }
            new["planning_call"] = .string(pc)
            touched.append("planning_call")
        }
        guard !touched.isEmpty else {
            return (400, .object(["error": .string("nothing to change: send daily_hours_goal, block_min_minutes, "
                                                   + "block_max_minutes, break_minutes or planning_call")]))
        }
        if LocalJSON.num0(new["block_max_minutes"]) < LocalJSON.num0(new["block_min_minutes"]) {
            return (400, .object(["error": .string("the longest block can't be shorter than the shortest")]))
        }
        st["settings"] = .object(new)
        save()
        var out: D = ["ok": .bool(true)]
        for k in touched { out[k] = new[k] }
        out["typesafe"] = .string(typesafe ?? (keys.typesafe.isEmpty ? "missing" : "ok"))
        return (200, .object(out))
    }
}
