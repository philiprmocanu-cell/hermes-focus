import Foundation

// MARK: - The three other Claude prompts the no-server brain needs, ported from app.py
//
// SecondOpinion — `_SECOND_SYSTEM` + `_second_opinion` (owner's "second opinion" over Jev, 6 s).
// BlockAdvice   — `_FOCUS_ADVICE_SYSTEM` + `_focus_advice_prompt` (the end-of-block work-smarter paragraph).
// GoalStep      — `_FOCUS_FRIEND_GOAL_SYSTEM` + the user text built in `_focus_goal` (what he typed → one specific
//                 goal, its `related` world and its questions). On the server this ran on Gemini; here it runs
//                 on Claude with the same prompt and the same reading of the answer.
// Each is: the prompt (pure), the `AnthropicCall`, and the parse of the JSON answer.

// MARK: Second opinion

public enum SecondOpinion {
    public static let system =
        "You double-check a fast screen judge for a focus timer. The user set a goal for this work block; " +
        "you see his screen right now (a screenshot when there is one, plus the front app, window title, " +
        "URL and visible text), what he was doing the last few minutes and the fast judge's last seconds. " +
        "Decide: is he on task for this goal right now? On task includes the work itself, reading or " +
        "researching what the goal needs, a quick lookup or search that serves it, messaging a person the " +
        "goal involves, and directing an AI chat on the goal's project. Off task is entertainment, feeds, " +
        "shopping or unrelated topics. Answer JSON only: " +
        "{\"on_task\": \"yes\" | \"no\", \"reason\": \"one short sentence\"}"
    public static let timeout: TimeInterval = 6
    public static let maxTokens = 300
    public static let textChars = 3000

    /// One of Jev's recent seconds.
    public struct Row: Equatable, Sendable {
        public var at: Double?
        public var app: String
        public var title: String
        public var mode: String
        public var onGoal: Double?
        public var confidence: Double?
        public init(at: Double?, app: String = "", title: String = "", mode: String = "", onGoal: Double? = nil,
                    confidence: Double? = nil) {
            self.at = at; self.app = app; self.title = title; self.mode = mode; self.onGoal = onGoal
            self.confidence = confidence
        }
    }

    public struct Context: Equatable, Sendable {
        public var goal: String
        public var specific: String
        /// The goal step's `related` object (cleaned here as brain/jev.related_terms does).
        public var related: JSONValue?
        /// brain/jev.story_line — the last ten minutes in one line.
        public var story: String
        public var rows: [Row]
        /// brain/jev.tells_text(row) for the torn second ("" for the nudge gate).
        public var tellsText: String
        public var app: String
        public var title: String
        public var url: String
        public var text: String
        public var now: Double
        public init(goal: String, specific: String = "", related: JSONValue? = nil, story: String = "",
                    rows: [Row] = [], tellsText: String = "", app: String = "", title: String = "", url: String = "",
                    text: String = "", now: Double) {
            self.goal = goal; self.specific = specific; self.related = related; self.story = story; self.rows = rows
            self.tellsText = tellsText; self.app = app; self.title = title; self.url = url; self.text = text
            self.now = now
        }
    }

    public struct Verdict: Equatable, Sendable {
        public var onTask: Bool
        public var reason: String
    }

    static func py(_ d: Double?) -> String { d.map(PortedText.pyFloat) ?? "None" }

    /// `_second_rows_text`: the last 12 seconds, oldest first.
    public static func rowsText(_ rows: [Row], now: Double) -> String {
        let lines = rows.suffix(12).map { r -> String in
            let at = (r.at ?? 0) == 0 ? now : r.at!
            let whereText = [PortedText.prefix(r.app, 30), PortedText.prefix(r.title, 50)].filter { !$0.isEmpty }
                .joined(separator: " — ")
            return "\(Int(max(0, now - at))) s ago: \(whereText.isEmpty ? "?" : whereText) " +
                "(\(r.mode.isEmpty ? "?" : r.mode), on goal \(py(r.onGoal)), sure \(py(r.confidence)))"
        }
        return lines.isEmpty ? "(none yet)" : lines.joined(separator: "\n")
    }

    public static func prompt(_ c: Context, hasImage: Bool) -> String {
        let rel = GoalStep.relatedTerms(c.related).map { "\($0.key): \($0.values.joined(separator: ", "))" }
            .joined(separator: "; ")
        let text = PortedText.line(c.text, textChars)
        func or(_ s: String, _ d: String) -> String { s.isEmpty ? d : s }
        return "Goal: " + or(c.goal, "(not given)") +
            "\nSpecific goal for this block: " + or(c.specific, "(none)") +
            "\nWhat the goal involves: " + or(rel, "(none)") +
            "\nThe last minutes: " + or(c.story, "(nothing yet)") +
            "\nThe fast judge's last seconds, oldest first:\n" + rowsText(c.rows, now: c.now) +
            (c.tellsText.isEmpty ? "" : "\nWhy the fast judge was torn on this second (its yes/no checks, " +
                "probability of yes): " + c.tellsText) +
            "\n\nScreen now — app: " + c.app +
            "\nWindow title: " + c.title +
            "\nURL: " + c.url +
            "\nVisible text: " + or(text, "(none)") +
            (hasImage ? "" : "\n(No screenshot this time.)") +
            "\n\nIs he on task for this goal right now? yes/no + one sentence."
    }

    public static func call(_ c: Context, jpegBase64: String = "", model: String = AnthropicAPI.defaultModel) -> AnthropicCall {
        let q = AnthropicCall.quickExtras(model: model)
        return AnthropicCall(system: system, user: prompt(c, hasImage: !jpegBase64.isEmpty), jpegBase64: jpegBase64,
                             model: model, maxTokens: maxTokens, timeout: timeout, extra: q.extra, betas: q.betas)
    }

    /// {"on_task": "yes"|"no", "reason"} → the verdict; nil for anything else.
    public static func parse(_ v: JSONValue?) -> Verdict? {
        let answer = PortedText.str(v?["on_task"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard answer == "yes" || answer == "no" else { return nil }
        return Verdict(onTask: answer == "yes", reason: PortedText.line(v?["reason"], 200))
    }
}

// MARK: End-of-block advice

public enum BlockAdvice {
    public static let system =
        "A 25-to-60-minute focus block of the user's has just ended. You get what he said the block was " +
        "for, every screenshot verdict the block collected in order, how his eyes, hands and app " +
        "switches went, and the LAST screenshot of the block itself. Answer JSON only:\n" +
        "{\"advice\": \"...\"}\n" +
        "advice: ONE paragraph, three sentences at most, in plain words a non-programmer reads once " +
        "and understands. Say (1) whether the process was repetitive — the same kind of step done " +
        "over and over by hand; (2) what an AI could have done for him instead, concretely, naming " +
        "the actual work on screen; (3) the single change that would make the NEXT block faster. " +
        "No lists, no headings, no jargon, no praise, no filler like 'stay focused'. Never tell him " +
        "to switch app, editor, IDE or tool. If nothing was repetitive, say so plainly in the first " +
        "sentence and spend the rest on the one change worth making.\n" +
        "Never transcribe private text from the screenshot; describe the work, do not quote it."
    /// app.py `_FOCUS_OPUS_TIMEOUT_S`; the advice is written off the request, so it may take its time.
    public static let timeout: TimeInterval = 30
    public static let maxTokens = AnthropicAPI.defaultMaxTokens
    public static let promptChars = 12000

    /// One screenshot verdict of the block.
    public struct Frame: Equatable, Sendable {
        public var doing = ""
        public var note = ""
        public var actualGoal = ""
        public var quality: Double?
        public var onGoal: Double?
        public var working: Double?
        public var smart: Double?
        public var mode = ""
        public var pending = false
        public var automatable = ""
        public init(doing: String = "", note: String = "", actualGoal: String = "", quality: Double? = nil,
                    onGoal: Double? = nil, working: Double? = nil, smart: Double? = nil, mode: String = "",
                    pending: Bool = false, automatable: String = "") {
            self.doing = doing; self.note = note; self.actualGoal = actualGoal; self.quality = quality
            self.onGoal = onGoal; self.working = working; self.smart = smart; self.mode = mode
            self.pending = pending; self.automatable = automatable
        }
    }

    /// `_focus_advice_stats`, in its key order.
    public struct Stats: Equatable, Sendable {
        public var minutes: Int
        public var switches: Double?
        public var activeS: Double?
        public var typingSeconds: Int?
        public var scrollingSeconds: Int?
        public var distractionS: Double?
        /// reading / blank / away, in that order, only the ones known.
        public var eyes: [(key: String, value: Double)]
        public var score: Int?
        public var focusScore: Int?
        public var outputScore: Int?
        public init(minutes: Int, switches: Double? = nil, activeS: Double? = nil, typingSeconds: Int? = nil,
                    scrollingSeconds: Int? = nil, distractionS: Double? = nil, eyes: [(key: String, value: Double)] = [],
                    score: Int? = nil, focusScore: Int? = nil, outputScore: Int? = nil) {
            self.minutes = minutes; self.switches = switches; self.activeS = activeS; self.typingSeconds = typingSeconds
            self.scrollingSeconds = scrollingSeconds; self.distractionS = distractionS; self.eyes = eyes
            self.score = score; self.focusScore = focusScore; self.outputScore = outputScore
        }
        public static func == (a: Stats, b: Stats) -> Bool { a.json == b.json }

        /// `json.dumps(stats)` as Python writes it.
        public var json: String {
            func f(_ d: Double?) -> String { d.map(PortedText.pyFloat) ?? "null" }
            func i(_ n: Int?) -> String { n.map(String.init) ?? "null" }
            let eyeText = "{" + eyes.map { "\"\($0.key)\": \(PortedText.pyFloat($0.value))" }.joined(separator: ", ") + "}"
            return "{\"minutes\": \(minutes), \"switches\": \(f(switches)), \"active_s\": \(f(activeS)), " +
                "\"typing_seconds\": \(i(typingSeconds)), \"scrolling_seconds\": \(i(scrollingSeconds)), " +
                "\"distraction_s\": \(f(distractionS)), \"eyes\": \(eyeText), \"score\": \(i(score)), " +
                "\"focus_score\": \(i(focusScore)), \"output_score\": \(i(outputScore))}"
        }
    }

    public struct Input: Equatable, Sendable {
        /// What he named the block.
        public var goal: String
        /// The specific goal it was judged against (focus_day.block_goal).
        public var judgedGoal: String
        /// The goal he started on, when the goal changed mid-block ("" = it didn't).
        public var originalGoal: String
        public var frames: [Frame]
        public var stats: Stats
        public init(goal: String, judgedGoal: String, originalGoal: String = "", frames: [Frame], stats: Stats) {
            self.goal = goal; self.judgedGoal = judgedGoal; self.originalGoal = originalGoal; self.frames = frames
            self.stats = stats
        }
    }

    static func frameLine(_ f: Frame) -> String {
        var bits = ["doing: " + (f.doing.isEmpty ? "?" : f.doing)]
        if !f.note.isEmpty { bits.append("note: " + f.note) }
        if !f.actualGoal.isEmpty { bits.append("actual_goal: " + f.actualGoal) }
        for (k, v) in [("quality", f.quality), ("on_goal", f.onGoal), ("working", f.working), ("smart", f.smart)] {
            if let v { bits.append("\(k) \(PortedText.pyFloat(v))") }
        }
        if !f.mode.isEmpty { bits.append(f.mode) }
        if f.pending { bits.append("pending — it was waiting to be explained") }
        if !f.automatable.isEmpty { bits.append("could be automated: " + f.automatable) }
        return "- " + bits.joined(separator: "; ")
    }

    /// `_focus_advice_prompt`.
    public static func prompt(_ input: Input) -> String {
        let lines = input.frames.map(frameLine).joined(separator: "\n")
        let p = "The goal he named: " + (input.goal.isEmpty ? "(none)" : input.goal) +
            "\nThe specific goal this block was judged against: " + (input.judgedGoal.isEmpty ? "(none)" : input.judgedGoal) +
            (input.originalGoal.isEmpty ? "" : "\nHe started this block on: " + input.originalGoal) +
            "\n\nThe screenshot verdicts, oldest first:\n" + (lines.isEmpty ? "(the screen was never read)" : lines) +
            "\n\nHow the block went (seconds unless said otherwise):\n" + input.stats.json +
            "\n\nThe last screenshot of the block is attached."
        return PortedText.prefix(p, promptChars)
    }

    /// `_focus_with_profile`: his own "how I work" profile goes under the system prompt when he has one.
    public static func systemPrompt(profile: String) -> String { profile.isEmpty ? system : system + "\n\n" + profile }

    public static func call(_ input: Input, jpegBase64: String = "", profile: String = "",
                            model: String = AnthropicAPI.defaultModel) -> AnthropicCall {
        AnthropicCall(system: systemPrompt(profile: profile), user: prompt(input), jpegBase64: jpegBase64,
                      model: model, maxTokens: maxTokens, timeout: timeout)
    }

    /// {"advice": "..."} → the paragraph (≤ 600 characters), nil when empty.
    public static func parse(_ v: JSONValue?) -> String? {
        let t = PortedText.line(v?["advice"], 600)
        return t.isEmpty ? nil : t
    }
}

// MARK: Goal step

public enum GoalStep {
    static let relatedRule =
        "related: what this block's work will plausibly touch, from the typed goal and the context " +
        "given, so a screen judge can tell a step toward the goal from a distraction. people: the people " +
        "it involves, each with a few words on who and where they are when the context says so (e.g. " +
        "'Reply to the client' -> ['the client (named in the context)']; a contract with a partner -> the " +
        "people named in the context, such as 'Robin (partner, in Berlin)'). projects: project, course or " +
        "company names. terms: words " +
        "likely to appear on screen or in a search (e.g. 'fisheye', 'de-warp', 'vesting'). sites: sites " +
        "or apps the work happens in (e.g. 'Gmail', 'Loom', 'zyBooks', 'Canvas'). At most 6 each, " +
        "short; [] when unknown. Never invent a person who is not in the goal or the context."
    static let questionsRule =
        "\nquestions: up to 8 yes/no questions a screen judge can answer from ONE look at the screen, " +
        "written for THIS goal. Concrete: name the apps, sites, people, document titles and topics that " +
        "would be on screen, e.g. 'Is the screen an email thread with the client about the " +
        "proposal?'. About half are on-task tells (means \"on_task\": a yes shows he is doing this " +
        "goal's work, including the lookups and messages it needs); add a few off-task tells (means " +
        "\"off_task\") only when the goal suggests a likely detour (e.g. for a reading block: 'Is he " +
        "watching a video unrelated to the reading?'). Under 25 words each; ids q1, q2, ...; [] when " +
        "status is clarify."

    /// `_FOCUS_FRIEND_GOAL_SYSTEM`: the goal step that knows only the user's own words and earlier blocks —
    /// the no-server app has no Canvas, calendar or notes behind it.
    public static let system =
        "Someone typed what they will work on for the next focus block. Work out EXACTLY what they " +
        "mean, so the block can be judged against it. You know only their own words and their own " +
        "earlier blocks today (below). Answer JSON only:\n" +
        "{\"status\": \"ok\" | \"clarify\", \"goal\": \"...\", \"understood\": \"...\", \"question\": \"...\", " +
        "\"specific_goal\": \"...\", \"specificity\": 0..1, \"specificity_hint\": \"...\", " +
        "\"related\": {\"people\": [...], \"projects\": [...], \"terms\": [...], \"sites\": [...]}, " +
        "\"questions\": [{\"id\": \"q1\", \"text\": \"...\", \"means\": \"on_task\" | \"off_task\"}]}\n" +
        "goal: a short label, 6 words or fewer.\n" +
        "understood: one plain sentence saying what they are doing, restating their words plainly. " +
        "Never invent a deadline, course or project you were not told about.\n" +
        "status clarify ONLY when the text is too vague or meaningless to judge work against " +
        "('stuff', 'work', 'asdf', 'idk'), or when it names a broad TOPIC instead of an outcome for " +
        "this block ('learn AI', 'business stuff'). Then question is ONE concrete question asking what " +
        "they will have at the end of the block, e.g. 'What will you have in 25 minutes — an outline, " +
        "or notes from one chapter?'. A specific goal is always ok. When they have already answered a " +
        "clarifying question, status MUST be ok with your best reading of both.\n" +
        "Otherwise question is \"\".\n" +
        "specific_goal: ONE plain sentence naming the concrete outcome they will have at the end of " +
        "THIS block — it must be achievable in the block length given below. Use what their earlier " +
        "blocks today already got done: continue from there, never repeat finished work. If what they " +
        "typed is too big for one block, scope it to the next concrete chunk that fits.\n" +
        "specificity: 0..1, how specific WHAT THEY TYPED was (1 = names the deliverable and when it is " +
        "done; 0.5 = names the project but not the outcome; 0.2 = only a topic). Feedback only.\n" +
        "specificity_hint: \"\" when specificity is 0.7 or more; else ONE short line (under 15 words) on " +
        "how to phrase it next time.\n" +
        "Write specific_goal so a screenshot can show how far along it is: name the thing that will " +
        "exist or be finished. When status is clarify, specific_goal is \"\".\n" +
        relatedRule + questionsRule

    /// app.py `_FOCUS_MODEL_TIMEOUT_S` (the goal step's limit on the server).
    public static let timeout: TimeInterval = 30
    public static let maxTokens = 1500
    public static let goalQuestionsMax = 8
    public static let goalQuestionsRubricMax = 26
    public static let goalQuestionChars = 160
    public static let defaultHint = "Next time, name what you'll have at the end, like \"draft the intro paragraph\"."

    public struct Input: Equatable, Sendable {
        /// What he typed.
        public var text: String
        /// His answer to a clarifying question ("" = none).
        public var clarifyAnswer: String
        /// focus.goal_vagueness: "" | "junk" | "unknown".
        public var vague: String
        /// "same" as the last block, whose specific goal was achieved: ask for the next chunk.
        public var sameAchieved: Bool
        public var previousGoal: String
        public var previousUnderstood: String
        public var previousSpecific: String
        public var blockMinutes: Int
        /// His earlier blocks today, one line each ("" = none).
        public var context: String
        public init(text: String, clarifyAnswer: String = "", vague: String = "", sameAchieved: Bool = false,
                    previousGoal: String = "", previousUnderstood: String = "", previousSpecific: String = "",
                    blockMinutes: Int = 25, context: String = "") {
            self.text = text; self.clarifyAnswer = clarifyAnswer; self.vague = vague; self.sameAchieved = sameAchieved
            self.previousGoal = previousGoal; self.previousUnderstood = previousUnderstood
            self.previousSpecific = previousSpecific; self.blockMinutes = blockMinutes; self.context = context
        }

        /// What the goal is "taken as typed" when the model has nothing better.
        public var typed: String {
            if sameAchieved { return text.isEmpty ? previousGoal : text }
            let t = [text, clarifyAnswer].filter { !$0.isEmpty }.joined(separator: " — ")
            return t.isEmpty ? previousGoal : t
        }
    }

    /// The user text `_focus_goal` sends.
    public static func prompt(_ i: Input) -> String {
        let typedForModel: String
        if i.sameAchieved {
            typedForModel = "same as the last block — \"\(i.previousUnderstood.isEmpty ? i.previousGoal : i.previousUnderstood)\". " +
                "Its specific goal (\"\(i.previousSpecific)\") was achieved: set the NEXT concrete chunk of the same goal"
        } else {
            typedForModel = i.text.isEmpty ? "(nothing)" : i.text
        }
        let answer = i.clarifyAnswer
        return "What he typed: " + typedForModel +
            (answer.isEmpty ? "" : "\nYou asked him to clarify; his answer: " + answer) +
            (i.vague == "junk" && answer.isEmpty
                ? "\nA quick check says this names no real work: it is too vague to judge by itself." : "") +
            (i.vague == "unknown" && answer.isEmpty
                ? "\nA quick check found none of these words in his context: ask, unless it clearly means something there." : "") +
            "\nThis block is \(i.blockMinutes) minutes long." +
            "\n\n" + (i.context.isEmpty ? "(no context available)" : i.context)
    }

    public static func systemPrompt(profile: String) -> String { profile.isEmpty ? system : system + "\n\n" + profile }

    public static func call(_ i: Input, profile: String = "", model: String = AnthropicAPI.defaultModel) -> AnthropicCall {
        let q = AnthropicCall.quickExtras(model: model)
        return AnthropicCall(system: systemPrompt(profile: profile), user: prompt(i), model: model,
                             maxTokens: maxTokens, timeout: timeout, extra: q.extra, betas: q.betas)
    }

    public struct Reply: Equatable, Sendable {
        /// The model asked for a clarifying question (`question` is it).
        public var wantsClarify: Bool
        public var question: String
        /// The model's short label, whitespace collapsed ("" = none: use `typed`). Run focus.goal_label on it.
        public var goal: String
        public var understood: String
        public var specificGoal: String
        /// 0…1, 2 dp; nil when the model gave none (use the local guess).
        public var specificity: Double?
        /// The model's own hint line, raw (feed it to `hint(specificity:said:)`).
        public var hintSaid: String
        /// `goal_related`: people / projects / terms / sites, cleaned, in that order.
        public var related: [(key: String, values: [String])]
        public var questions: [RubricWriter.GoalQuestion]

        public static func == (a: Reply, b: Reply) -> Bool {
            a.wantsClarify == b.wantsClarify && a.question == b.question && a.goal == b.goal
                && a.understood == b.understood && a.specificGoal == b.specificGoal && a.specificity == b.specificity
                && a.hintSaid == b.hintSaid && a.questions == b.questions
                && a.related.map(\.key) == b.related.map(\.key) && a.related.map(\.values) == b.related.map(\.values)
        }

        /// The `related` object as stored in the goal state.
        public var relatedJSON: JSONValue {
            .object(Dictionary(uniqueKeysWithValues: related.map { ($0.key, JSONValue.array($0.values.map { .string($0) })) }))
        }
    }

    /// The goal step's answer read the way `_focus_goal` reads it.
    public static func parse(_ v: JSONValue, input: Input) -> Reply {
        let typed = input.typed
        let spec = PortedText.number(v["specificity"]).map { PortedText.round2(min(1, max(0, $0))) }
        let understood = PortedText.line(v["understood"], 240)
        let u = understood.isEmpty ? typed : understood
        let specific = PortedText.line(v["specific_goal"], 240)
        return Reply(wantsClarify: PortedText.str(v["status"]).lowercased() == "clarify",
                     question: PortedText.line(v["question"], 240),
                     goal: PortedText.collapse(PortedText.str(v["goal"])),
                     understood: u, specificGoal: specific.isEmpty ? u : specific,
                     specificity: spec, hintSaid: PortedText.str(v["specificity_hint"]),
                     related: relatedTerms(v["related"]), questions: questionsClean(v["questions"]))
    }

    /// `_focus_goal_hint`: "" for a specific goal; else the model's first sentence (≤ 120), or a plain one.
    public static func hint(specificity: Double, said: String) -> String {
        if specificity >= 0.7 { return "" }
        let line = PortedText.collapse(said)
        var first = line
        if let r = line.range(of: "(?<=[.!?])\\s", options: .regularExpression) { first = String(line[..<r.lowerBound]) }
        first = PortedText.prefix(first, 120)
        return first.isEmpty ? defaultHint : first
    }

    /// brain/jev.related_terms: {people, projects, terms, sites} → short strings, ≤ 8 each, no duplicates.
    public static func relatedTerms(_ v: JSONValue?) -> [(key: String, values: [String])] {
        guard let v, case .object = v else { return [] }
        var out: [(key: String, values: [String])] = []
        for k in ["people", "projects", "terms", "sites"] {
            var vals: [JSONValue]
            if case .string? = v[k] { vals = [v[k]!] } else if let a = v[k]?.arrayValue { vals = a } else { continue }
            var clean: [String] = []
            for x in vals {
                let s = PortedText.line(x, 80)
                if !s.isEmpty && !clean.contains(where: { $0.lowercased() == s.lowercased() }) { clean.append(s) }
                if clean.count == 8 { break }
            }
            if !clean.isEmpty { out.append((k, clean)) }
        }
        return out
    }

    /// brain/jev.goal_questions_clean: [{id q1…, text, means on_task|off_task}], ≤ 8 (the rubric's
    /// rub_on_/rub_off_ ids kept, ≤ 26), no duplicates.
    public static func questionsClean(_ raw: JSONValue?) -> [RubricWriter.GoalQuestion] {
        var out: [RubricWriter.GoalQuestion] = []
        var seen = Set<String>()
        var plain = 0, rubric = 0
        for item in raw?.arrayValue ?? [] {
            guard case .object = item else { continue }
            let text = PortedText.line(item["text"], goalQuestionChars)
            let means = PortedText.str(item["means"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            guard !text.isEmpty, means == "on_task" || means == "off_task", !seen.contains(text.lowercased()) else { continue }
            let rid = PortedText.prefix(String(String.UnicodeScalarView(PortedText.str(item["id"]).lowercased().unicodeScalars
                .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })), 40)
            if rid.hasPrefix(RubricWriter.prefixOn) || rid.hasPrefix(RubricWriter.prefixOff) {
                if rubric == goalQuestionsRubricMax { continue }
                rubric += 1
                seen.insert(text.lowercased())
                out.append(.init(id: rid, text: text, means: means))
                continue
            }
            if plain == goalQuestionsMax { continue }
            plain += 1
            seen.insert(text.lowercased())
            out.append(.init(id: "q\(plain)", text: text, means: means))
        }
        return out
    }
}
