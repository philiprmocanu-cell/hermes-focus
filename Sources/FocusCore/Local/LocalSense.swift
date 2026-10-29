import Foundation

// MARK: - sense: Jev once a second (app.py `_focus_sense`, `_focus_sense_finish`, `_focus_second_gate`)

extension LocalBrainCore {
    /// `_focus_jpeg_check`: "" when `b64` is a base64 JPEG within the size limit, else why not.
    static func jpegCheck(_ b64: String) -> String {
        if b64.isEmpty { return "no image" }
        if b64.utf8.count > maxImageBytes * 4 / 3 + 8 { return "image too large (max 2 MB)" }
        guard let raw = Data(base64Encoded: b64) else { return "image is not valid base64" }
        if raw.count > maxImageBytes { return "image too large (max 2 MB)" }
        if raw.count < 2 || raw[raw.startIndex] != 0xFF || raw[raw.startIndex + 1] != 0xD8 { return "image is not a JPEG" }
        return ""
    }

    /// `_focus_sense_specific`: the specific goal this second is judged against.
    func senseSpecific(goal: String, sent: String) -> String {
        let g = Scoring.norm(goal)
        let known: Set<String> = [Scoring.norm(str("goal_label")), Scoring.norm(str("goal_text")), ""]
        if !g.isEmpty && !known.contains(g) {
            var s = sent
            if !Scoring.norm(s).isEmpty && Scoring.norm(s) == Scoring.norm(str("specific_goal")) { s = "" }
            st["specific_goal"] = .string(s.isEmpty ? goal : s)
            return str("specific_goal")
        }
        if !sent.isEmpty { st["specific_goal"] = .string(sent) }
        return str("specific_goal")
    }

    /// `_focus_sense_minute`: fold the minute's seconds into one frame when the minute is up.
    func senseMinute(screen: D, now: Double, at: Double) -> D? {
        if now - sense.minuteAt < Judge.minuteS { return nil }
        let rows = sense.rows.filter { LocalJSON.num0($0["at"]) > sense.minuteAt }
        sense.minuteAt = now
        return Judge.minuteFrame(rows, screen: screen, at: at)
    }

    /// `_focus_sense_fresh_image`.
    func freshImage(_ now: Double) -> String {
        guard let img = sense.image, img.key == sense.screenKey, now - img.at <= Judge.imageFreshS else { return "" }
        return img.b64
    }

    /// `_focus_label_unanswered`: the nudge he let stand for a minute, taken (labelled once).
    func labelUnanswered(_ now: Double) -> D? {
        guard var n = sense.nudge, !Judge.truthy(n["labelled"]),
              now - (LocalJSON.num(n["at"]) ?? now) >= Self.labelNoClickS else { return nil }
        n["labelled"] = .bool(true)
        sense.nudge = n
        return n
    }

    /// `_focus_label_from_nudge`: a label row from the snapshot kept when the nudge went out.
    func labelFromNudge(_ n: D, label: String, source: String) -> JSONValue {
        let screen: D = ["app": n["app"] ?? .null, "title": n["title"] ?? .null, "url": n["url"] ?? .null]
        var row = Judge.labelRow(at: LocalJSON.num(n["at"]) ?? nowTs, user: Self.user,
                                 blockId: Judge.pyStrOr(n["block_id"]), goal: Judge.pyStrOr(n["goal"]),
                                 specific: Judge.pyStrOr(n["specific"]), screen: screen, text: "",
                                 row: LocalJSON.dict(n["row"]), label: label, source: source)
        row["text_digest"] = .string(Judge.pyStrOr(n["digest"]))
        row["nudge_id"] = .string(Judge.pyStrOr(n["id"]))
        return .object(row)
    }

    func senseRoute(_ data: D) async -> (Int, JSONValue) {
        let k = keys
        guard !k.typesafe.isEmpty else { return (402, Self.typesafeMissing) }
        let blockId = LocalJSON.s(data["block_id"], 80)
        guard !blockId.isEmpty else { return (400, .object(["error": .string("block_id is required")])) }
        let goal = LocalJSON.s(data["goal"], 200)
        let now = nowTs
        let atSent = LocalJSON.toTs(data["at"])
        let at = atSent != 0 ? atSent : now
        let screen: D = ["app": .string(LocalJSON.s(data["app"], 60)), "title": .string(LocalJSON.s(data["title"], 200)),
                         "url": .string(LocalJSON.s(data["url"], 300))]
        let app = Judge.pyStr(screen["app"]), title = Judge.pyStr(screen["title"]), url = Judge.pyStr(screen["url"])
        let sentText = data["text"]?.stringValue
        let sentImage = data["image_jpeg_b64"]?.stringValue ?? ""
        let imageOk = !sentImage.isEmpty && Self.jpegCheck(sentImage).isEmpty

        let switching = blockId != str("block_id")
        switchBlock(blockId, goal: goal)
        let specific = senseSpecific(goal: goal, sent: LocalJSON.s(data["specific_goal"], 240))
        st["active"] = .bool(true); st["phase"] = .string("work"); st["last_seen"] = .number(now)
        let sentUnd = LocalJSON.s(data["understood"], 240)
        let understood = sentUnd.isEmpty ? understoodFor(goal) : sentUnd
        let soFar = dbl("goal_progress")
        let nudgedAt = dbl("nudged_at")
        let related = st["goal_related"] ?? .object([:])
        let goalQs = st["goal_questions"] ?? .array([])
        let rub = rubricLive()
        let rules = rulings(blockId)
        let goalNow = goal.isEmpty ? str("goal") : goal
        if switching { save() }
        let about = [goalNow, specific, understood].joined(separator: " ")
        let siteNow = Judge.distractionSite(url, app: app, goal: about)

        var staleLabel: D?
        if sense.blockId != blockId {
            // A nudge from the last block he let stand past its minute.
            staleLabel = labelUnanswered(now)
            sense = LocalSenseMemory(blockId: blockId, minuteAt: now, screenSince: now, started: now)
        }
        if let t = sentText {
            sense.text = Judge.cut(Judge.squash(t), Judge.maxTextChars)
            sense.digest = Judge.textDigest(sense.text)
        }
        let text = sense.text
        let key = app + "|" + title + "|" + url
        if key != sense.screenKey { sense.screenKey = key; sense.screenSince = now }
        if imageOk { sense.image = (sentImage, key, now) }
        var imageB64 = ""
        if let img = sense.image, img.key == key, now - img.at <= Judge.imageFreshS { imageB64 = img.b64 }
        if siteNow != sense.site { sense.site = siteNow; sense.siteSince = siteNow.isEmpty ? 0 : now }
        let siteS = siteNow.isEmpty ? 0 : now - (sense.siteSince == 0 ? now : sense.siteSince)
        let lastSiteS = LocalJSON.num0(sense.last?["site_s"])
        let changed = sentText != nil || imageOk || Judge.truthy(data["typed"]) || Judge.truthy(data["scrolled"])
            || Judge.truthy(data["app_switched"]) || sense.last == nil
            || (!siteNow.isEmpty && siteS >= Judge.distractionS && !(lastSiteS >= Judge.distractionS))
        if let staleLabel { store.appendLabel(labelFromNudge(staleLabel, label: "off_task", source: "no_click")) }

        if !Judge.throttle(changed: changed, lastCallAt: sense.lastCallAt, now: now), var last = sense.last {
            // Nothing changed: this second is the last verdict again, kept as a second of its own.
            last["at"] = .number(at); last["cached"] = .bool(true)
            sense.rows = Array((sense.rows + [last]).suffix(Self.senseRows))
            sense.trail = Judge.trailAdd(sense.trail, screen: screen, mode: Judge.pyStrOr(last["mode"]), now: now)
            let minute = senseMinute(screen: screen, now: now, at: at)
            let off = Judge.nudgeDue(sense.rows, now: now, blockStarted: sense.started, lastNudgeAt: nudgedAt,
                                     gapS: Scoring.nudgeGapS)
            var verdict: D = [:]
            for f in ["on_goal", "working", "mode", "confidence", "serves_goal"] { verdict[f] = last[f] ?? .null }
            verdict["related"] = .bool(Judge.rowRelated(last))
            let reply: D = ["verdict": .object(verdict), "nudge": .string(""), "nudge_id": .string(""),
                            "look": .bool(false), "goal_progress": .number(LocalJSON.r3(soFar)), "cached": .bool(true)]
            return await senseFinish(blockId: blockId, goal: goalNow, reply: reply, row: last, minute: minute, off: off,
                                     now: now)
        }

        var rows = sense.rows.filter { !Judge.truthy($0["cached"]) }
        for i in rows.indices { rows[i]["ago"] = .number(Double(Int(now - (LocalJSON.num(rows[i]["at"]) ?? now)))) }
        let secondsOn = now - (sense.screenSince == 0 ? now : sense.screenSince)
        let story = Judge.storyLine(sense.trail, now: now)
        let idle = LocalJSON.num(data["idle_s"]) ?? 0
        let change: D = ["typed": .bool(Judge.truthy(data["typed"])), "scrolled": .bool(Judge.truthy(data["scrolled"])),
                         "idle_s": .number(idle), "text_changed_share": .number(LocalJSON.num(data["text_changed_share"]) ?? 0),
                         "app_switched": .bool(Judge.truthy(data["app_switched"])),
                         "seconds_on_this_screen": .number(secondsOn)]
        let ref = imageB64.isEmpty ? "" : "shot-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var screenText = screen
        screenText["text"] = .string(text)
        let state = Judge.buildState(goal: goalNow, specific: specific, understood: understood, progressSoFar: soFar,
                                     screen: screenText, change: change, recent: rows, story: story, related: related,
                                     rulings: rules.map { Judge.pyStrOr($0["rule"]) }, imageRef: ref, site: siteNow,
                                     siteS: siteS, goalQuestions: goalQs, milestones: rub?["milestones"])
        let questions = Judge.questionsFor(goalQs, rubric: rub)
        let client = TypeSafeClient(key: k.typesafe, transport: transport)
        let began = Date()
        let (out, usedImage) = await client.judge(state: .object(state), questions: .object(questions),
                                                  jpegBase64: imageB64, ref: ref)
        counters.jevCall(ms: Int(Date().timeIntervalSince(began) * 1000), reply: out, imageSent: !imageB64.isEmpty,
                         usedImage: usedImage)
        let shot = imageB64
        guard let out, let v = Judge.parseAnswers(.object(out.answers), goalQuestions: goalQs, rubric: rub) else {
            return (503, .object(["error": .string("could not judge the screen right now")]))
        }
        var vScreen = screen
        vScreen["text_chars"] = .number(Double(Judge.plen(text))); vScreen["image"] = .bool(usedImage)
        var row = Judge.verdictRow(v, screen: vScreen, at: at)
        let studying = v["mode"] == .string("studying")
        row = Judge.settleRow(row, site: siteNow, siteS: siteS,
                              ruled: rules.contains { Judge.exceptionMatches(.object($0), screen) },
                              away: Judge.isAway(idle, screen, textLen: Judge.plen(text), studying: studying))
        row["title"] = .string(Judge.cut(title, 80))
        row["ax"] = .bool(Judge.truthy(data["ax_trusted"]))
        // Jev torn, a fresh screenshot in hand: the stronger model decides this second (once every 15 s).
        if !k.anthropic.isEmpty && !shot.isEmpty && Judge.escalate(row) && sense.blockId == blockId
            && now - sense.secondAt > Self.secondUnsureGapS {
            sense.secondAt = now
            let ctx = secondContext(goal: goalNow, specific: specific, related: related, story: story, rows: rows,
                                    row: row, screen: screen, text: text, now: now)
            if let second = await secondOpinion(trigger: "unsure", ctx: ctx, shot: shot, screen: screen) {
                row = Self.secondApply(row, second)
            }
        }
        var verdict: D = [:]
        for f in ["on_goal", "working", "producing", "quality", "mode", "serves_goal", "confidence"] {
            verdict[f] = row[f] ?? .null
        }
        verdict["related"] = .bool(Judge.rowRelated(row))
        let reply: D = ["verdict": .object(verdict), "nudge": .string(""), "nudge_id": .string(""), "look": .bool(false)]
        guard sense.blockId == blockId else {
            var r = reply
            r["goal_progress"] = .number(LocalJSON.r3(soFar))
            return (200, .object(r))
        }
        sense.rows = Array((sense.rows + [row]).suffix(Self.senseRows))
        sense.last = row
        sense.lastCallAt = now
        sense.trail = Judge.trailAdd(sense.trail, screen: screen, mode: Judge.pyStrOr(row["mode"]), now: now)
        let minute = senseMinute(screen: screen, now: now, at: at)
        let off = Judge.nudgeDue(sense.rows, now: now, blockStarted: sense.started, lastNudgeAt: dbl("nudged_at"),
                                 gapS: Scoring.nudgeGapS)
        // The last screenshot of the block, in memory only, for the one advice call at its end.
        if imageOk { lastFrame = (blockId, sentImage) }
        return await senseFinish(blockId: blockId, goal: goalNow, reply: reply, row: row, minute: minute, off: off,
                                 now: now)
    }

    /// `_focus_sense_finish`: the nudge (checked first by the second opinion), progress, the minute frame and
    /// the label for a nudge he let stand for a minute.
    func senseFinish(blockId: String, goal: String, reply replyIn: D, row rowIn: D, minute: D?, off offIn: Bool,
                     now: Double) async -> (Int, JSONValue) {
        var reply = replyIn, row = rowIn, off = offIn
        if let unanswered = labelUnanswered(now) {
            store.appendLabel(labelFromNudge(unanswered, label: "off_task", source: "no_click"))
        }
        let gapOk = now - dbl("nudged_at") >= Scoring.nudgeGapS
        if off && gapOk && !keys.anthropic.isEmpty {
            if await secondGate(blockId: blockId, goal: goal, row: &row, now: now) {
                off = false
                var v = LocalJSON.dict(reply["verdict"]) ?? [:]
                v["related"] = .bool(true); v["on_goal"] = row["on_goal"] ?? .null
                reply["verdict"] = .object(v)
            }
        }
        var nudge = ""
        if off && now - dbl("nudged_at") >= Scoring.nudgeGapS {
            let site = Judge.pyStrOr(row["site"])
            if !site.isEmpty {
                let g = Judge.cut(Judge.squash(goal), 60)
                let s = site.prefix(1).uppercased() + site.dropFirst()
                nudge = g.isEmpty ? "\(s) isn't the plan — back to it." : "\(s) isn't \(g) — back to it."
            } else {
                nudge = Scoring.nudgeText("", goal: goal, frame: .object(row))
            }
            st["nudged_at"] = .number(now)
            counters.nudge()
        }
        // Cumulative within the block: how far he got never goes back down. With rubric milestones, how far he
        // got IS the share of them reached, and a milestone once reached stays reached.
        let msTotal = milestonesNote(blockId: blockId, row: row)
        if msTotal > 0 {
            if str("progress_block") == blockId {
                st["goal_progress"] = .number(max(dbl("goal_progress"),
                                                  Double(LocalJSON.list(st["milestones_reached"]).count) / Double(msTotal)))
            }
        } else if !Judge.truthy(row["cached"]), let p = LocalJSON.num(row["progress"]), str("progress_block") == blockId,
                  LocalJSON.num0(row["confidence"]) >= Judge.progressConfidence {
            st["goal_progress"] = .number(max(dbl("goal_progress"), p))
        }
        if let minute {
            var frames = LocalJSON.list(st["frames"])
            _ = Scoring.retroCredit(&frames, row: .object(minute))
            frames = Array((frames + [.object(minute)]).suffix(Self.framesPerBlock))
            _ = Scoring.markDetours(&frames)
            st["frames"] = .array(frames)
        }
        let progress = LocalJSON.r3(dbl("goal_progress"))
        if minute != nil || !nudge.isEmpty || msTotal > 0 { save() }
        var nudgeId = ""
        if !nudge.isEmpty {
            nudgeId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
            var unanswered: D?
            // The nudge it replaces, never answered, is an off-task label too.
            if var earlier = sense.nudge, !Judge.truthy(earlier["labelled"]) {
                earlier["labelled"] = .bool(true)
                unanswered = earlier
            }
            var keep: D = [:]
            for f in ["on_goal", "working", "mode", "serves_goal", "confidence", "step", "stepped", "site", "off_site",
                      "tells", "off_tells", "second", "image"] { keep[f] = row[f] ?? .null }
            // What Jev saw and said, kept for the label: the text only as its digest.
            sense.nudge = ["id": .string(nudgeId), "at": .number(now), "app": row["app"] ?? .null,
                           "title": row["title"] ?? .null, "url": row["url"] ?? .null, "block_id": .string(blockId),
                           "goal": .string(goal), "specific": .string(str("specific_goal")),
                           "digest": .string(Judge.textDigest(sense.text)), "row": .object(keep),
                           "labelled": .bool(false)]
            if let unanswered { store.appendLabel(labelFromNudge(unanswered, label: "off_task", source: "no_click")) }
        }
        reply["nudge"] = .string(nudge)
        reply["nudge_id"] = .string(nudgeId)
        reply["goal_progress"] = .number(progress)
        if let minute { reply["frame"] = .object(minute) }
        if msTotal > 0 { reply["milestones_reached"] = .array(LocalJSON.list(st["milestones_reached"])) }
        return (200, .object(reply))
    }

    /// `_focus_milestones_note`: add this second's reached milestones to the block's set. Returns how many
    /// milestones the rubric has (0 = none: progress stays Jev's).
    func milestonesNote(blockId: String, row: D) -> Int {
        let ms = LocalJSON.dicts(rubricLive()?["milestones"]).filter { Judge.truthy($0["id"]) }
        guard !ms.isEmpty else { return 0 }
        if str("milestones_block") != blockId {
            st["milestones_block"] = .string(blockId); st["milestones_reached"] = .array([])
        }
        let ids = Set(ms.map { Judge.pyStr($0["id"]) })
        var have = Judge.strList(st["milestones_reached"]).filter { ids.contains($0) }
        for x in Judge.strList(row["milestones"]) where ids.contains(x) && !have.contains(x) { have.append(x) }
        st["milestones_reached"] = .array(have.map { .string($0) })
        return ms.count
    }

    // MARK: The second opinion

    func secondContext(goal: String, specific: String, related: JSONValue, story: String, rows: [D], row: D,
                       screen: D, text: String, now: Double) -> SecondOpinion.Context {
        let srows = rows.suffix(12).map {
            SecondOpinion.Row(at: LocalJSON.num($0["at"]), app: Judge.pyStrOr($0["app"]),
                              title: Judge.pyStrOr($0["title"]), mode: Judge.pyStrOr($0["mode"]),
                              onGoal: LocalJSON.num($0["on_goal"]), confidence: LocalJSON.num($0["confidence"]))
        }
        return SecondOpinion.Context(goal: goal, specific: specific, related: related, story: story, rows: Array(srows),
                                     tellsText: Judge.tellsText(row), app: Judge.pyStrOr(screen["app"]),
                                     title: Judge.pyStrOr(screen["title"]), url: Judge.pyStrOr(screen["url"]),
                                     text: text, now: now)
    }

    /// `_second_opinion`: {on_task, reason} from the stronger model, or nil (no key, slow, refused, unreadable).
    func secondOpinion(trigger: String, ctx: SecondOpinion.Context, shot: String, screen: D) async -> SecondOpinion.Verdict? {
        let k = keys
        guard !k.anthropic.isEmpty else { return nil }
        let client = AnthropicClient(key: k.anthropic, transport: transport)
        let began = Date()
        let res = await client.send(SecondOpinion.call(ctx, jpegBase64: shot, model: k.model))
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        var verdict: SecondOpinion.Verdict?
        var tin = 0, tout = 0
        if case .success(let r) = res {
            tin = r.inputTokens; tout = r.outputTokens
            verdict = SecondOpinion.parse(RubricWriter.decodeObject(r.text))
        }
        let last: JSONValue = verdict.map { v in
            .object(["at": .number(nowTs), "trigger": .string(trigger), "answer": .string(v.onTask ? "yes" : "no"),
                     "reason": .string(v.reason), "app": .string(Judge.cut(Judge.pyStrOr(screen["app"]), 60)),
                     "title": .string(Judge.cut(Judge.pyStrOr(screen["title"]), 80)), "image": .bool(!shot.isEmpty)])
        } ?? .null
        counters.secondCall(trigger: trigger, model: k.model, ms: ms, inputTokens: tin, outputTokens: tout,
                            verdict: verdict, last: last)
        return verdict
    }

    /// `_focus_second_apply`: yes lifts the second to a step's on goal, no caps it at 0.2; sure either way.
    static func secondApply(_ rowIn: D, _ second: SecondOpinion.Verdict) -> D {
        var r = rowIn
        let on = LocalJSON.num0(r["on_goal"]), conf = LocalJSON.num0(r["confidence"])
        if second.onTask {
            r["on_goal"] = .number(LocalJSON.r3(max(on, Judge.stepOnGoal))); r["second"] = .string("yes")
        } else {
            r["on_goal"] = .number(LocalJSON.r3(min(on, 0.2))); r["second"] = .string("no")
        }
        r["confidence"] = .number(LocalJSON.r3(max(conf, Judge.offTaskConfidence)))
        r["second_reason"] = .string(Judge.cut(second.reason, 200))
        return r
    }

    /// `_focus_second_gate`: a nudge is due — ask the stronger model first. True = he is on task after all:
    /// no nudge, the recent off seconds are settled as related and the screen is ruled on task for the block.
    func secondGate(blockId: String, goal: String, row: inout D, now: Double) async -> Bool {
        guard sense.blockId == blockId else { return false }
        let specific = str("specific_goal")
        let related = st["goal_related"] ?? .object([:])
        let shot = freshImage(now)
        let rows = Array(sense.rows.filter { !Judge.truthy($0["cached"]) }.suffix(12))
        let story = Judge.storyLine(sense.trail, now: now)
        let text = sense.text
        sense.secondAt = now
        let screen: D = ["app": .string(Judge.pyStrOr(row["app"])), "title": .string(Judge.pyStrOr(row["title"])),
                         "url": .string(Judge.pyStrOr(row["url"]))]
        let ctx = secondContext(goal: goal, specific: specific, related: related, story: story, rows: rows, row: row,
                                screen: screen, text: text, now: now)
        guard let second = await secondOpinion(trigger: "gate", ctx: ctx, shot: shot, screen: screen),
              second.onTask else { return false }
        let reason = Judge.cut(second.reason, 200)
        func lift(_ r: inout D) {
            r["on_goal"] = .number(LocalJSON.r3(max(LocalJSON.num0(r["on_goal"]), Judge.stepOnGoal)))
            r["stepped"] = .bool(true); r["second"] = .string("yes"); r["second_reason"] = .string(reason)
        }
        if sense.blockId == blockId {
            for i in sense.rows.indices {
                if now - LocalJSON.num0(sense.rows[i]["at"]) <= Judge.offTaskS + Judge.offTaskGapS
                    && Judge.rowOffTask(sense.rows[i]) {
                    lift(&sense.rows[i])
                }
            }
            if var last = sense.last { lift(&last); sense.last = last }
        }
        lift(&row)
        if !Judge.pyStrOr(screen["app"]).isEmpty || !Judge.pyStrOr(screen["url"]).isEmpty {
            addRuling(blockId, Judge.exceptionFrom(screen, at: now, by: "second"))
            save()
        }
        return true
    }

    // MARK: exception: "I'm on task" (app.py `_focus_exception`)

    func exception(_ data: D) -> (Int, JSONValue) {
        let blockId = LocalJSON.s(data["block_id"], 80)
        guard !blockId.isEmpty else { return (400, .object(["error": .string("block_id is required")])) }
        let now = nowTs
        var screen: D = ["app": .string(LocalJSON.s(data["app"], 60)), "title": .string(LocalJSON.s(data["title"], 200)),
                         "url": .string(LocalJSON.s(data["url"], 300))]
        var label: D?
        if sense.blockId == blockId, var shown = sense.nudge {
            let nid = LocalJSON.s(data["nudge_id"], 40)
            // The screen the nudge was about wins over where he is now.
            if (nid.isEmpty || .string(nid) == shown["id"])
                && (Judge.truthy(shown["app"]) || Judge.truthy(shown["url"])) {
                screen = ["app": .string(Judge.pyStrOr(shown["app"])), "title": .string(Judge.pyStrOr(shown["title"])),
                          "url": .string(Judge.pyStrOr(shown["url"]))]
                // A label for the test set, once per nudge (a press after the minute corrects the no-click one).
                if !Judge.truthy(shown["labelled_on"]) {
                    shown["labelled"] = .bool(true); shown["labelled_on"] = .bool(true)
                    sense.nudge = shown
                    label = shown
                }
            }
        }
        guard Judge.truthy(screen["app"]) || Judge.truthy(screen["url"]) else {
            return (400, .object(["error": .string("which screen? app or url is required")]))
        }
        if let label { store.appendLabel(labelFromNudge(label, label: "on_task", source: "button")) }
        let rule = Judge.exceptionFrom(screen, at: now)
        addRuling(blockId, rule)
        // The nudge was wrong: the next one may come as soon as he drifts.
        st["nudged_at"] = .number(0)
        save()
        if sense.blockId == blockId {
            for i in sense.rows.indices where Judge.exceptionMatches(.object(rule), sense.rows[i]) {
                sense.rows[i] = Judge.settleRow(sense.rows[i], ruled: true)
            }
            if let last = sense.last, Judge.exceptionMatches(.object(rule), last) {
                sense.last = Judge.settleRow(last, ruled: true)
            }
        }
        return (200, .object(["ok": .bool(true), "rule": rule["rule"] ?? .string("")]))
    }

    // MARK: GET sense: the running block's seconds (no screen text)

    func senseGet() -> (Int, JSONValue) {
        let now = nowTs
        let keep = ["at", "app", "title", "url", "mode", "on_goal", "p_on_task", "confidence", "working", "producing",
                    "quality", "progress", "serves_goal", "step", "stepped", "site", "off_site", "away", "ruled", "image",
                    "text_chars", "ax", "doing", "tells", "off_tells", "second", "second_reason", "on", "off",
                    "on_goal_raw", "check_p", "milestones"]
        let seconds: [JSONValue] = sense.rows.filter { !Judge.truthy($0["cached"]) }.map { r in
            var o: D = [:]
            for k in keep { o[k] = r[k] ?? .null }
            return .object(o)
        }
        return (200, .object(["block_id": .string(sense.blockId), "seconds": .array(seconds),
                              "story": .string(Judge.storyLine(sense.trail, now: now)),
                              "goal_questions": st["goal_questions"] ?? .array([]),
                              "checks": .array(Judge.checksListing()), "rubric": rubricView()]))
    }

    // MARK: frame: the screenshot fallback (app.py `_focus_frame` + `_focus_frame_jev`)
    //
    // The app posts a screenshot only while the sense route is not answering. In-process the screenshot is
    // judged by Jev exactly as the server did (image + the goal's questions, the text alone if the image call
    // fails) and the verdict joins the block's frames.

    func frame(_ data: D) async -> (Int, JSONValue) {
        let k = keys
        guard !k.typesafe.isEmpty else { return (402, Self.typesafeMissing) }
        let b64 = data["image_jpeg_b64"]?.stringValue ?? ""
        if b64.isEmpty { return (400, .object(["error": .string("image_jpeg_b64 is required")])) }
        let why = Self.jpegCheck(b64)
        if !why.isEmpty { return (why.contains("too large") ? 413 : 400, .object(["error": .string(why)])) }
        let blockId = LocalJSON.s(data["block_id"], 80)
        let goal = LocalJSON.s(data["goal"], 200)
        let now = nowTs
        switchBlock(blockId, goal: goal)
        let sentSpecific = LocalJSON.s(data["specific_goal"], 240)
        if !sentSpecific.isEmpty { st["specific_goal"] = .string(sentSpecific) }
        let sentUnd = LocalJSON.s(data["understood"], 240)
        let understood = sentUnd.isEmpty ? understoodFor(goal) : sentUnd
        let specific = str("specific_goal")
        let soFar = dbl("goal_progress")
        let goalNow = goal.isEmpty ? str("goal") : goal
        let screen: D = ["app": .string(LocalJSON.s(data["app"], 60)), "title": .string(LocalJSON.s(data["title"], 200)),
                         "url": .string(LocalJSON.s(data["url"], 300))]
        let related = st["goal_related"] ?? .object([:])
        let goalQs = st["goal_questions"] ?? .array([])
        let rub = rubricLive()
        let rules = rulings(blockId)
        let story = sense.blockId == blockId ? Judge.storyLine(sense.trail, now: now) : ""
        let site = Judge.distractionSite(Judge.pyStr(screen["url"]), app: Judge.pyStr(screen["app"]),
                                         goal: [goalNow, specific, understood].joined(separator: " "))
        let ref = "shot-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var screenText = screen
        screenText["text"] = .string("")
        let state = Judge.buildState(goal: goalNow, specific: specific, understood: understood, progressSoFar: soFar,
                                     screen: screenText, change: [:], recent: [], story: story, related: related,
                                     rulings: rules.map { Judge.pyStrOr($0["rule"]) }, imageRef: ref, site: site,
                                     siteS: site.isEmpty ? 0 : 60, goalQuestions: goalQs, milestones: rub?["milestones"])
        let client = TypeSafeClient(key: k.typesafe, transport: transport)
        let began = Date()
        let (out, used) = await client.judge(state: .object(state), questions: .object(Judge.questionsFor(goalQs, rubric: rub)),
                                             jpegBase64: b64, ref: ref)
        counters.jevCall(ms: Int(Date().timeIntervalSince(began) * 1000), reply: out, imageSent: true, usedImage: used)
        lastFrame = (blockId.isEmpty ? str("block_id") : blockId, b64)
        guard let out, let v = Judge.parseAnswers(.object(out.answers), goalQuestions: goalQs, rubric: rub) else {
            return (503, .object(["error": .string("could not judge the screenshot right now")]))
        }
        var vScreen = screen
        vScreen["image"] = .bool(used)
        var row = Judge.verdictRow(v, screen: vScreen, at: now)
        row = Judge.settleRow(row, site: site, siteS: site.isEmpty ? 0 : 60,
                              ruled: rules.contains { Judge.exceptionMatches(.object($0), screen) })
        func c3(_ x: JSONValue?) -> Double { LocalJSON.r3(Judge.clamp(x)) }
        var verdict: D = [
            "on_goal": .number(c3(row["on_goal"])), "working": .number(c3(row["working"])),
            "quality": .number(c3(LocalJSON.num(row["quality"]) == nil ? row["working"] : row["quality"])),
            "mode": .string(Judge.pyStrOr(row["mode"])), "doing": .string(LocalJSON.s(row["doing"], 80)),
            "note": .string(""), "actual_goal": .string(""), "serves_goal": .bool(Judge.truthy(row["serves_goal"])),
            "automatable": .string(""), "evidence": .string(LocalJSON.s(row["evidence"], 120))]
        for f in ["producing", "progress", "smart"] {
            verdict[f] = LocalJSON.num(row[f]).map { .number(c3(.number($0))) } ?? .null
        }
        let atSent = LocalJSON.toTs(data["at"])
        var frameRow = verdict
        frameRow["at"] = .number(atSent != 0 ? atSent : now)
        frameRow["app"] = screen["app"]; frameRow["url"] = screen["url"]
        var frameValue: JSONValue = .object(frameRow)
        if Scoring.framePending(frameValue) {
            frameValue = Scoring.provisional(frameValue)
        }
        var frames = LocalJSON.list(st["frames"])
        var nudge = ""
        if !Judge.truthy(verdict["serves_goal"]),
           Scoring.nudgeAllowed(frameValue, previous: frames.last, lastNudgeAt: dbl("nudged_at"), now: now) {
            nudge = Scoring.nudgeText("", goal: goalNow, frame: frameValue)
            st["nudged_at"] = .number(now)
        }
        _ = Scoring.retroCredit(&frames, row: frameValue)
        frames = Array((frames + [frameValue]).suffix(Self.framesPerBlock))
        _ = Scoring.markDetours(&frames)
        st["frames"] = .array(frames)
        if let p = LocalJSON.num(frameValue["progress"]),
           str("progress_block") == (blockId.isEmpty ? str("block_id") : blockId) {
            st["goal_progress"] = .number(max(dbl("goal_progress"), p))
        }
        save()
        for f in ["on_goal", "working", "quality"] { verdict[f] = frameValue[f] ?? verdict[f] }
        verdict["pending"] = .bool(Judge.truthy(frameValue["pending"]))
        verdict["nudge"] = .string(nudge)
        verdict["goal_progress"] = .number(LocalJSON.r3(dbl("goal_progress")))
        verdict["tip"] = .string("")
        return (200, .object(verdict))
    }

    // MARK: labels (GET)

    func labelsGet(days rawDays: Int) -> (Int, JSONValue) {
        let days = max(1, min(365, rawDays))
        let since = nowTs - Double(days) * 86400
        var rows = store.loadLabels().filter { LocalJSON.num0($0["at"]) >= since }
        rows = rows.enumerated().sorted { a, b in
            let x = LocalJSON.num0(a.element["at"]), y = LocalJSON.num0(b.element["at"])
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        var counts: [String: JSONValue] = [:]
        for r in rows {
            let l = Judge.pyStrOr(r["label"])
            counts[l] = .number((counts[l]?.doubleValue ?? 0) + 1)
        }
        return (200, .object(["days": .number(Double(days)), "count": .number(Double(rows.count)),
                              "by_label": .object(counts), "rows": .array(rows)]))
    }
}
