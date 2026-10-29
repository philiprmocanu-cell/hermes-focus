import Foundation

// MARK: - goal: what he typed → one specific goal, its world and its rubric (app.py `_focus_goal`)

extension LocalBrainCore {
    /// `_focus_goal_block_s`: the coming block's length in real-mode seconds.
    func goalBlockS(_ data: D) -> Double {
        var planned = LocalJSON.num(data["planned_s"]) ?? LocalJSON.num(data["block_s"])
        if planned == nil || planned == 0 { planned = blocksToday().last.flatMap { LocalJSON.num($0["planned_s"]) } }
        let p = (planned ?? 0) > 0 ? planned! : 1500
        return p / Scoring.lengthScale(p)
    }

    /// `specificity_guess` (brain/focus.py): how specific what he typed was, when no model could say.
    static func specificityGuess(_ text: String, context: String = "") -> Double {
        let v = Scoring.goalVagueness(text, context: context)
        if v == "junk" { return 0.1 }
        if v == "unknown" { return 0.25 }
        let words = Scoring.norm(text).replacingOccurrences(of: "'", with: "").split(separator: " ").map(String.init)
            .filter { !Scoring.goalStop.contains($0) && !Scoring.junkWords.contains($0) }
        return PortedText.round2(min(0.8, 0.2 + 0.12 * Double(words.count)))
    }

    /// `_focus_goal_earlier_line`.
    static func earlierLine(_ b: D) -> String {
        let goal = Judge.pyStrOr(b["goal"])
        let spec = Judge.pyStrOr(b["specific_goal"]), und = Judge.pyStrOr(b["understood"])
        var line = "- \(goal)" + (!spec.isEmpty || !und.isEmpty ? " (\(spec.isEmpty ? und : spec))" : "")
        if let got = LocalJSON.num(b["goal_achieved"]) { line += "; got \(Judge.pyRoundInt(got * 100))% of the way there" }
        let done = FocusDay.blockBullets(.object(b))
        if !done.isEmpty { line += "; done: " + done.joined(separator: "; ") }
        return Judge.cut(line, 400)
    }

    /// `_focus_friend_goal_context`: his own earlier blocks today, nothing else.
    func goalContext() -> (context: String, options: [String]) {
        let earlier = blocksToday().filter { Judge.truthy($0["goal"]) }.suffix(5)
        guard let last = earlier.last else { return ("", []) }
        return ("Their focus blocks earlier today (what got done, what was left):\n"
                + earlier.map(Self.earlierLine).joined(separator: "\n"), [Judge.pyStrOr(last["goal"])])
    }

    /// `clarify_question` (brain/focus.py) for when the model offered no question of its own.
    static func clarifyQuestion(_ options: [String]) -> String {
        var opts: [String] = []
        for o in options {
            let t = Judge.cut(Judge.squash(o), 90)
            if !t.isEmpty && !opts.contains(where: { $0.lowercased() == t.lowercased() }) { opts.append(t) }
            if opts.count == 3 { break }
        }
        if opts.isEmpty { return "What exactly will you have done at the end of this block?" }
        if opts.count == 1 { return "Is this \(opts[0]), or something else? Say exactly what you'll work on." }
        return "Is this " + opts.dropLast().joined(separator: ", ") + ", or \(opts.last!)?"
    }

    func goal(_ data: D) async -> (Int, JSONValue) {
        let k = keys
        guard !k.typesafe.isEmpty else { return (402, Self.typesafeMissing) }
        let note = LocalJSON.s(data["rubric_note"], 300)
        if !note.isEmpty { return await rubricNote(note) }
        let text = LocalJSON.s(data["text"], 300)
        let answer = LocalJSON.s(data["clarify_answer"], 300)
        let sentPrev = LocalJSON.s(data["previous_goal"], 200)
        let prevGoal = sentPrev.isEmpty ? str("goal_label") : sentPrev
        let sentUnd = LocalJSON.s(data["previous_understood"], 240)
        let prevUnderstood = sentUnd.isEmpty ? str("understood") : sentUnd
        let mine = sentPrev.isEmpty || Scoring.norm(sentPrev) == Scoring.norm(str("goal_label"))
            || Scoring.norm(sentPrev) == Scoring.norm(str("goal_text"))
        let prevSpecific = mine ? str("specific_goal") : ""
        let prevSpec: Double? = mine ? LocalJSON.num(st["specificity"]) : nil
        var prevGot = mine ? dbl("goal_progress") : 0
        if !prevSpecific.isEmpty {
            for b in blocksToday().reversed() where Judge.pyStrOr(b["specific_goal"]) == prevSpecific {
                if let g = LocalJSON.num(b["goal_achieved"]) { prevGot = max(prevGot, g); break }
            }
        }
        let blockMin = max(1, Judge.pyRoundInt(goalBlockS(data) / 60))
        let same = answer.isEmpty && !prevGoal.isEmpty && Scoring.isSameGoal(text, previousGoal: prevGoal)
        let achieved = prevGot >= Self.goalDone
        func sameOut(_ guess: Double?) -> D {
            ["status": .string("ok"), "goal": .string(Scoring.goalLabel(prevGoal)),
             "understood": .string(prevUnderstood.isEmpty ? prevGoal : prevUnderstood), "question": .string(""),
             "specific_goal": .string(!prevSpecific.isEmpty ? prevSpecific : !prevUnderstood.isEmpty ? prevUnderstood : prevGoal),
             "criteria": .array([]),
             "specificity": LocalJSON.n(prevSpec ?? guess ?? Self.specificityGuess(prevGoal)),
             "specificity_hint": .string("")]
        }
        if same && !achieved {
            return (200, goalKeep(sameOut(nil), typed: text.isEmpty ? prevGoal : text, data: data))
        }
        let (context, options) = goalContext()
        let vague = same ? "" : Scoring.goalVagueness(text, context: context)
        let typed = same ? (text.isEmpty ? prevGoal : text)
            : ([text, answer].filter { !$0.isEmpty }.joined(separator: " — ").localNonEmpty ?? prevGoal)
        let guess = Self.specificityGuess([text, answer].joined(separator: " "), context: context)
        var reply: GoalStep.Reply?
        if !k.anthropic.isEmpty {
            let input = GoalStep.Input(text: text, clarifyAnswer: answer, vague: vague, sameAchieved: same,
                                       previousGoal: prevGoal, previousUnderstood: prevUnderstood,
                                       previousSpecific: prevSpecific, blockMinutes: blockMin, context: context)
            let client = AnthropicClient(key: k.anthropic, transport: transport)
            let res = await client.goalStep(input, model: k.model)
            if case .success(let r) = res { reply = r }
            counters.claudeCall(ok: reply != nil)
        }
        guard let reply else {
            // The model is unavailable (or there is no Anthropic key): taken as typed.
            if same { return (200, goalKeep(sameOut(guess), typed: typed, data: data)) }
            let label = Scoring.goalLabel(typed)
            var out: D = ["status": .string("ok"), "goal": .string(label), "understood": .string(typed),
                          "question": .string(""), "specific_goal": .string(typed), "criteria": .array([]),
                          "specificity": .number(guess),
                          "specificity_hint": .string(GoalStep.hint(specificity: guess, said: "")),
                          "related": .object([:])]
            out["rubric_full"] = await rubricWrite(label: label, specific: typed, understood: typed,
                                                   related: [:], blockMin: blockMin)
            return (200, goalKeep(out, typed: typed, data: data))
        }
        let spec = reply.specificity ?? guess
        let hint = GoalStep.hint(specificity: spec, said: reply.hintSaid)
        if !same && answer.isEmpty && (vague == "junk" || reply.wantsClarify) {
            let q = Judge.cut(Judge.squash(reply.question), 240)
            return (200, .object(["status": .string("clarify"), "goal": .string(""), "understood": .string(""),
                                  "question": .string(q.isEmpty ? Self.clarifyQuestion(options) : q),
                                  "specific_goal": .string(""), "criteria": .array([]), "specificity": .number(spec),
                                  "specificity_hint": .string(hint)]))
        }
        let label0 = Scoring.goalLabel(reply.goal.isEmpty ? typed : reply.goal)
        let label = label0.isEmpty ? Scoring.goalLabel(typed) : label0
        let related = Judge.relatedTerms(reply.relatedJSON)
        let goalQs = Judge.goalQuestionsClean(.array(reply.questions.map(\.json)))
        let understood = reply.understood.isEmpty ? typed : reply.understood
        let specific = reply.specificGoal.isEmpty ? understood : reply.specificGoal
        var out: D = ["status": .string("ok"), "goal": .string(label), "understood": .string(understood),
                      "question": .string(""), "specific_goal": .string(specific), "criteria": .array([]),
                      "specificity": .number(same ? (prevSpec ?? spec) : spec),
                      "specificity_hint": .string(same ? "" : hint), "related": .object(related),
                      "questions": .array(goalQs.map(\.json))]
        out["rubric_full"] = await rubricWrite(label: label, specific: specific, understood: understood,
                                               related: related, blockMin: blockMin)
        return (200, goalKeep(out, typed: typed, data: data))
    }

    /// `_focus_goal_keep`: remember the goal for this session; progress starts again at 0.
    func goalKeep(_ outIn: D, typed: String, data: D) -> JSONValue {
        var out = outIn
        let rubric = out.removeValue(forKey: "rubric_full")
        st["goal_label"] = out["goal"] ?? .string("")
        st["goal_text"] = .string(LocalJSON.s(.string(typed), 200))
        st["understood"] = out["understood"] ?? .string("")
        st["goal_at"] = .number(nowTs)
        st["specific_goal"] = .string(Judge.pyStrOr(out["specific_goal"]))
        st["specificity"] = out["specificity"] ?? .null
        st["specificity_hint"] = .string(Judge.pyStrOr(out["specificity_hint"]))
        st["goal_progress"] = .number(0); st["progress_block"] = .string(""); st["tip"] = .string("")
        st["milestones_reached"] = .array([]); st["milestones_block"] = .string("")
        // A new goal brings its own world; "same" keeps the last one's.
        if let related = out["related"] {
            st["goal_related"] = related
            st["goal_questions"] = .array(Judge.goalQuestionsClean(out["questions"]).map(\.json))
            // The rubric's tells replace the goal step's questions; a fallback rubric leaves those in place.
            if let r = rubric, case .object = r { st["rubric"] = r } else { st["rubric"] = .null }
            let rubQs = Judge.goalQuestionsClean(Self.rubricGoalQuestions(rubricLive()))
            if !rubQs.isEmpty {
                st["goal_questions"] = .array(rubQs.map(\.json))
                out["questions"] = .array(rubQs.map(\.json))
            }
        }
        if let r = st["rubric"], case .object = r { out["rubric"] = Self.rubricPublic(r) }
        save()
        return .object(out)
    }

    /// brain/rubric.py `goal_questions`: the tells as [{id rub_on_/rub_off_, text, means}].
    static func rubricGoalQuestions(_ r: JSONValue?) -> JSONValue {
        guard let r, case .object = r else { return .array([]) }
        var out: [JSONValue] = []
        for (key, prefix, means) in [("on_tells", RubricWriter.prefixOn, "on_task"),
                                     ("off_tells", RubricWriter.prefixOff, "off_task")] {
            for t in LocalJSON.dicts(r[key]) {
                out.append(.object(["id": .string(prefix + Judge.pyStr(t["id"])), "text": t["text"] ?? .string(""),
                                    "means": .string(means)]))
            }
        }
        return .array(out)
    }

    /// brain/rubric.py `public`: {kind, balance, milestones, on_tells, off_tells, smart, md}.
    static func rubricPublic(_ r: JSONValue) -> JSONValue {
        var o: D = [:]
        for k in ["kind", "balance", "milestones", "on_tells", "off_tells", "smart", "md"] { o[k] = r[k] ?? .null }
        return .object(o)
    }

    /// The related object in the writer's order (people, projects, terms, sites).
    static func relatedPairs(_ related: D) -> [(key: String, values: [String])] {
        ["people", "projects", "terms", "sites"].compactMap { k in
            let vals = Judge.strList(related[k])
            return vals.isEmpty ? nil : (k, vals)
        }
    }

    /// `_focus_rubric_labels`: his "I'm on task" label rows for the same goal label.
    func rubricLabels(_ label: String) -> [JSONValue] {
        let want = LocalStore.slug(label)
        return store.loadLabels().suffix(2000).filter { r in
            r["label"]?.stringValue == "on_task"
                && LocalStore.slug(Scoring.goalLabel(Judge.pyStrOr(r["goal"]))) == want
        }
    }

    /// `_focus_rubric_write`: ask the writer for this goal's rubric. Never fails: no Anthropic key, a slow or
    /// unreadable answer → the fallback rubric (half and half, no milestones, no tells).
    func rubricWrite(label: String, specific: String, understood: String, related: D, blockMin: Int,
                     note: String = "", current: JSONValue? = nil) async -> JSONValue {
        let k = keys
        guard !k.anthropic.isEmpty else { return RubricWriter.json(RubricWriter.fallback(note: note)) }
        let past = store.rubricPast(label)
        let labels = rubricLabels(label)
        let prompt = RubricWriter.prompt(goal: label, specific: specific, understood: understood,
                                         related: Self.relatedPairs(related),
                                         pastRubricMd: Judge.pyStrOr(past?["md"]),
                                         rulings: RubricWriter.rulingLines(labels: labels), note: note,
                                         blockMinutes: blockMin, currentMd: Judge.pyStrOr(current?["md"]))
        let client = AnthropicClient(key: k.anthropic, transport: transport)
        let written = await client.writeRubric(prompt: prompt, note: note, model: k.model)
        counters.claudeCall(ok: !written.fallback)
        if written.fallback { return RubricWriter.json(written) }
        let merged = RubricWriter.mergeRulings(written, labels: labels)
        guard case .object(var o) = RubricWriter.json(merged) else { return .null }
        o["by"] = .string(k.model)
        let r: JSONValue = .object(o)
        store.storeRubric(label, rubric: r, note: note, at: nowTs)
        return r
    }

    /// `_focus_rubric_note`: his one typed fix. The writer runs again with the note and the current rubric;
    /// the goal never changes. If the writer fails the rubric he had stays (`rubric_note_applied: false`).
    func rubricNote(_ note: String) async -> (Int, JSONValue) {
        let label = str("goal_label")
        guard !label.isEmpty else { return (400, .object(["error": .string("set a goal before fixing its rubric")])) }
        let specific = str("specific_goal"), understood = str("understood")
        let related = LocalJSON.dict(st["goal_related"]) ?? [:]
        let current: JSONValue? = { if let r = st["rubric"], case .object = r { return r }; return nil }()
        var out: D = ["status": .string("ok"), "goal": .string(label), "understood": .string(understood),
                      "question": .string(""), "specific_goal": .string(specific), "criteria": .array([]),
                      "specificity": st["specificity"] ?? .null, "specificity_hint": .string(""),
                      "related": .object(related)]
        let blockMin = max(1, Judge.pyRoundInt(goalBlockS([:]) / 60))
        let new = await rubricWrite(label: label, specific: specific, understood: understood, related: related,
                                    blockMin: blockMin, note: note, current: current)
        let applied = !Judge.truthy(new["fallback"])
        if applied {
            st["rubric"] = new
            let qs = Judge.goalQuestionsClean(Self.rubricGoalQuestions(new))
            if !qs.isEmpty { st["goal_questions"] = .array(qs.map(\.json)) }
            save()
        }
        let keep: JSONValue = { if let r = st["rubric"], case .object = r { return r }; return new }()
        out["questions"] = .array(LocalJSON.list(st["goal_questions"]))
        out["rubric"] = Self.rubricPublic(keep)
        out["rubric_note_applied"] = .bool(applied)
        return (200, .object(out))
    }
}

extension String {
    /// nil for "" (the local brain's `x or default`).
    var localNonEmpty: String? { isEmpty ? nil : self }
}
