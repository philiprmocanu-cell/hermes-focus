import Foundation

// MARK: - The rubric writer (port of brain/rubric.py)
//
// When a goal is set, a strong model writes the block's RUBRIC: its kind, the balance between focus and output,
// 0–5 milestones that will show on screen, on-task and off-task yes/no tells for Jev, and what working smart looks
// like. This is the pure half of brain/rubric.py: the writer's prompt (`systemPrompt`, `prompt`), reading its
// answer (`parse`, falling back to half and half), the markdown he reads (`renderMarkdown`), the rubric as Jev
// questions (`questions`, ids rub_on_ / rub_off_ / ms_), his "I'm on task" rulings merged in (`mergeRulings`).
// The model call itself is `AnthropicClient.writeRubric`. Strings match the Python byte for byte (fixtures).

public enum RubricWriter {
    public typealias Kind = Rubric.Kind
    public typealias Item = Rubric.Item

    /// The balance rule, in the user's words and as numbers (focus, output).
    public static let balanceGuide: [Kind: (focus: Double, output: Double)] = [
        .reading: (0.9, 0.1), .study: (0.7, 0.3), .writing: (0.4, 0.6), .building: (0.35, 0.65),
        .outreach: (0.5, 0.5), .planning: (0.6, 0.4), .review: (0.6, 0.4), .mixed: (0.5, 0.5),
    ]
    /// No rubric (or the fallback): old blocks stay identical.
    public static let defaultBalance = Rubric.Balance(focus: 0.5, output: 0.5)
    public static let focusShareMin = 0.25
    public static let focusShareMax = 0.95

    public static let milestonesMax = 5
    public static let onTellsMin = 6
    public static let onTellsMax = 14
    public static let offTellsMin = 3
    public static let offTellsMax = 8
    public static let smartMax = 4
    public static let rulingsMax = 4
    public static let textMax = 160
    public static let smartTextMax = 180
    public static let noteMax = 300
    /// A milestone question answered this sure = reached.
    public static let milestoneYes = 0.7

    public static let prefixOn = "rub_on_"
    public static let prefixOff = "rub_off_"
    public static let prefixMilestone = "ms_"

    // MARK: Ids and items

    /// `_clean_id`: lowercase, runs of anything but a–z0–9 → "_", trimmed, ≤ 24; "<base[:21]>_2"… on a clash.
    static func cleanId(_ raw: String, fallback: String, taken: inout Set<String>) -> String {
        var base = ""
        var lastUnderscore = false
        for u in raw.lowercased().unicodeScalars {
            let ok = ("a"..."z").contains(u) || ("0"..."9").contains(u)
            if ok { base.unicodeScalars.append(u); lastUnderscore = false }
            else if !lastUnderscore { base.append("_"); lastUnderscore = true }
        }
        while base.hasPrefix("_") { base.removeFirst() }
        while base.hasSuffix("_") { base.removeLast() }
        base = PortedText.prefix(base, 24)
        if base.isEmpty { base = fallback }
        var out = base, n = 2
        while taken.contains(out) {
            out = PortedText.prefix(base, 21) + "_\(n)"
            n += 1
        }
        taken.insert(out)
        return out
    }

    /// `_items`: [{id, text}] from a list of objects or strings — short, no duplicates, at most `cap`.
    static func items(_ raw: JSONValue?, cap: Int, fallback: String) -> [Item] {
        var out: [Item] = []
        var seen = Set<String>(), taken = Set<String>()
        for item in raw?.arrayValue ?? [] {
            let textValue: JSONValue?, rid: JSONValue?
            if case .object = item {
                textValue = PortedText.truthy(item["text"]) ? item["text"] : item["question"]
                rid = item["id"]
            } else {
                textValue = item
                rid = nil
            }
            let text = PortedText.line(textValue, textMax)
            guard !text.isEmpty, !seen.contains(text.lowercased()) else { continue }
            seen.insert(text.lowercased())
            out.append(Item(id: cleanId(PortedText.str(rid), fallback: "\(fallback)\(out.count + 1)", taken: &taken),
                            text: text))
            if out.count == cap { break }
        }
        return out
    }

    // MARK: Balance

    /// `balance_for`: {focus, output} summing to 1 (2 dp) — the writer's numbers when they make sense, else
    /// the guide's for this kind; focus kept within 0.25…0.95.
    public static func balance(for kind: Kind, raw: JSONValue?) -> Rubric.Balance {
        var f: Double?, o: Double?
        if case .object = raw {
            f = PortedText.number(raw?["focus"]); o = PortedText.number(raw?["output"])
        } else if let a = raw?.arrayValue, a.count == 2 {
            f = PortedText.number(a[0]); o = PortedText.number(a[1])
        }
        if let fv = f, o == nil { o = 1.0 - fv }
        if let ov = o, f == nil { f = 1.0 - ov }
        var fv = f ?? -1, ov = o ?? -1
        if f == nil || o == nil || fv < 0 || ov < 0 || fv + ov <= 0 {
            let g = balanceGuide[kind] ?? balanceGuide[.mixed]!
            fv = g.focus; ov = g.output
        }
        let focus = PortedText.round2(min(focusShareMax, max(focusShareMin, fv / (fv + ov))))
        return Rubric.Balance(focus: focus, output: PortedText.round2(1.0 - focus))
    }

    // MARK: Parse

    /// The rubric when the writer failed: judged half and half, no milestones, no tells (Jev's general bank and
    /// the goal step's own questions still apply). Scores exactly like a block without a rubric.
    public static func fallback(note: String = "") -> Rubric {
        var r = Rubric(kind: .mixed, balance: defaultBalance, fallback: true,
                       note: note.isEmpty ? "" : PortedText.line(note, noteMax))
        r.md = renderMarkdown(r)
        return r
    }

    /// The writer's answer as text (strict JSON, possibly fenced or with prose around it).
    public static func parse(text: String?, note: String = "") -> Rubric {
        guard let text else { return fallback(note: note) }
        return parse(decodeObject(text), note: note)
    }

    /// `_focus_json_loads` / the string branch of `parse`: the `{…}` in the text, decoded; nil when unusable.
    public static func decodeObject(_ raw: String) -> JSONValue? {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}"))
        if text.hasPrefix("```") {
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            if let r = text.range(of: "```", options: .backwards) { text = String(text[..<r.lowerBound]) }
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(slice.utf8)), case .object = v else {
            return nil
        }
        return v
    }

    /// `parse`: the writer's answer (an object) as a Rubric. Anything unusable — not an object, no on-task tells
    /// and no milestones — is the fallback rubric.
    public static func parse(_ raw: JSONValue?, note: String = "") -> Rubric {
        guard let raw, case .object = raw else { return fallback(note: note) }
        let kind = Kind(rawValue: PortedText.line(raw["kind"], 20).lowercased()) ?? .mixed
        let milestones = items(raw["milestones"], cap: milestonesMax, fallback: "m")
        let onTells = items(raw["on_tells"], cap: onTellsMax, fallback: "t")
        let offTells = items(raw["off_tells"], cap: offTellsMax, fallback: "x")
        if onTells.isEmpty && milestones.isEmpty { return fallback(note: note) }
        var smart: [String] = []
        let smartRaw: [JSONValue?] = raw["smart"]?.arrayValue.map { $0.map(Optional.some) } ?? [raw["smart"]]
        for s in smartRaw {
            let t = PortedText.line(s, smartTextMax)
            if !t.isEmpty && !smart.contains(t) { smart.append(t) }
            if smart.count == smartMax { break }
        }
        var r = Rubric(kind: kind, balance: balance(for: kind, raw: raw["balance"]), milestones: milestones,
                       onTells: onTells, offTells: offTells, smart: smart, fallback: false,
                       note: note.isEmpty ? "" : PortedText.line(note, noteMax))
        r.md = renderMarkdown(r)
        return r
    }

    // MARK: Markdown

    /// "Judged 90% on focus, 10% on output".
    public static func balanceWords(_ b: Rubric.Balance?) -> String {
        let focus = (b?.focus).flatMap { $0 == 0 ? nil : $0 } ?? 0.5
        let f = PortedText.roundInt(100 * focus)
        return "Judged \(f)% on focus, \(100 - f)% on output"
    }

    public static func kindWords(_ k: Kind?) -> String {
        switch k ?? .mixed {
        case .reading: return "a reading block"
        case .study: return "a study block"
        case .writing: return "a writing block"
        case .building: return "a building block"
        case .outreach: return "an outreach block"
        case .planning: return "a planning block"
        case .review: return "a review block"
        case .mixed: return "a mixed block"
        }
    }

    /// `render_md`: the rubric as markdown — what he reads (and fixes) before he starts.
    public static func renderMarkdown(_ r: Rubric) -> String {
        let kind = (r.kind ?? .mixed).rawValue
        var lines = ["## Rubric — \(kind)", "", "**\(balanceWords(r.balance)): \(kindWords(r.kind ?? .mixed)).**"]
        if r.fallback {
            lines += ["", "_The rubric writer could not answer; this block is judged the usual way._"]
        }
        lines += ["", "### Milestones (output is judged against these)"]
        if r.milestones.isEmpty {
            lines.append("_None: output is judged on how far the screens show you get._")
        } else {
            lines += r.milestones.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        }
        for (title, list) in [("### On task looks like", r.onTells), ("### Off task looks like", r.offTells)]
        where !list.isEmpty {
            lines += ["", title] + list.map { "- \($0.text)" }
        }
        if !r.smart.isEmpty { lines += ["", "### Working smart here"] + r.smart.map { "- \($0)" } }
        lines += ["", "### What 1,000 takes",
                  "Every milestone reached, on task for at least 95% of the block and no distraction site."]
        if !r.note.isEmpty { lines += ["", "_Your fix: \(r.note)_"] }
        return lines.joined(separator: "\n")
    }

    // MARK: Questions

    public struct Question: Equatable, Sendable {
        public var id: String
        public var instructions: String
        public var type: String { "noul" }
        public var json: JSONValue { .object(["type": .string(type), "instructions": .string(instructions)]) }
    }

    /// `questions_for`: the rubric as Jev `noul` questions, in order: rub_on_<id>, rub_off_<id>, ms_<id>.
    public static func questions(_ r: Rubric?) -> [Question] {
        guard let r else { return [] }
        var qs: [Question] = []
        for t in r.onTells {
            qs.append(Question(id: prefixOn + t.id, instructions:
                "This goal's rubric, a sign of being ON task (`goal.checks`): " + t.text +
                " Yes only when the screen right now plainly shows it."))
        }
        for t in r.offTells {
            qs.append(Question(id: prefixOff + t.id, instructions:
                "This goal's rubric, a sign of being OFF task (`goal.checks`): " + t.text +
                " Yes only when the screen right now plainly shows it."))
        }
        for m in r.milestones {
            qs.append(Question(id: prefixMilestone + m.id, instructions:
                "Is milestone \"\(m.text)\" visibly reached on this screen or in the story so far? " +
                "Yes only when it is plainly done, not started or half done."))
        }
        return qs
    }

    /// The same as the `questions` object a TypeSafe call carries ({} without a rubric).
    public static func questionsJSON(_ r: Rubric?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for q in questions(r) { out[q.id] = q.json }
        return out
    }

    public struct GoalQuestion: Equatable, Sendable {
        public var id: String
        public var text: String
        public var means: String
        public init(id: String, text: String, means: String) { self.id = id; self.text = text; self.means = means }
        public var json: JSONValue { .object(["id": .string(id), "text": .string(text), "means": .string(means)]) }
    }

    /// `goal_questions`: the tells in the goal-question shape (ids rub_on_<id> / rub_off_<id>), [] without tells.
    public static func goalQuestions(_ r: Rubric?) -> [GoalQuestion] {
        guard let r else { return [] }
        return r.onTells.map { GoalQuestion(id: prefixOn + $0.id, text: $0.text, means: "on_task") }
            + r.offTells.map { GoalQuestion(id: prefixOff + $0.id, text: $0.text, means: "off_task") }
    }

    /// `milestones_reached`: milestone ids Jev answered yes to (0.7 or more).
    public static func milestonesReached(answers: JSONValue?, rubric r: Rubric?) -> [String] {
        guard let answers, case .object = answers, let r else { return [] }
        return r.milestones.compactMap { m in
            guard let a = answers[prefixMilestone + m.id], case .object = a,
                  let v = PortedText.number(a["noul"]), v >= milestoneYes else { return nil }
            return m.id
        }
    }

    // MARK: His rulings

    /// `merge_rulings`: his own "I'm on task" rulings for this goal (label rows `{at, label, app, title, url}`,
    /// newest first) as extra on-task tells, at most four, never a screen already covered. `md` re-rendered when
    /// any were added.
    public static func mergeRulings(_ r: Rubric, labels: [JSONValue]) -> Rubric {
        var out = r
        var tells = r.onTells
        var taken = Set(tells.map(\.id))
        var seen = Set(tells.map { $0.text.lowercased() })
        var added = 0
        let rows = labels.enumerated()
            .filter { if case .object = $0.element { return $0.element["label"]?.stringValue == "on_task" }; return false }
            .sorted { a, b in
                let x = PortedText.number(a.element["at"]).flatMap { $0 == 0 ? nil : $0 } ?? 0
                let y = PortedText.number(b.element["at"]).flatMap { $0 == 0 ? nil : $0 } ?? 0
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
        for row in rows {
            let app = PortedText.line(row["app"], 40)
            let title = PortedText.line(row["title"], 80)
            let url = PortedText.line(row["url"], 120)
            var whereText = [app, title].filter { !$0.isEmpty }.joined(separator: " — ")
            if whereText.isEmpty { whereText = url }
            guard !whereText.isEmpty else { continue }
            let text = PortedText.line("Is the screen \(whereText), which he marked as on task for this goal before?",
                                       textMax)
            guard !seen.contains(text.lowercased()) else { continue }
            seen.insert(text.lowercased())
            let id = cleanId("ruling\(added + 1)", fallback: "ruling\(added + 1)", taken: &taken)
            tells.append(Item(id: id, text: text, from: "ruling"))
            added += 1
            if added == rulingsMax { break }
        }
        guard added > 0 else { return out }
        out.onTells = tells
        out.md = renderMarkdown(out)
        return out
    }

    /// The lines the writer's prompt lists as "screens he marked as on task": "App — Title" per label row.
    public static func rulingLines(labels: [JSONValue]) -> [String] {
        labels.map { r in
            [PortedText.str(r["app"]), PortedText.str(r["title"])].filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }

    // MARK: The writer's prompt

    public static let writerSystem =
        "You write the RUBRIC for one focus block: how this block's work will be judged, second by second " +
        "from the screen and at the end as one score out of 1,000. 1,000 means hammering down everything, " +
        "hyper-focused: every milestone reached and on task the whole time. Answer strict JSON only, no prose:\n" +
        "{\"kind\": \"reading\" | \"study\" | \"writing\" | \"building\" | \"outreach\" | \"planning\" | \"review\" | \"mixed\", " +
        "\"balance\": {\"focus\": 0..1, \"output\": 0..1}, " +
        "\"milestones\": [{\"id\": \"m1\", \"text\": \"...\"}], " +
        "\"on_tells\": [{\"id\": \"t1\", \"text\": \"...\"}], " +
        "\"off_tells\": [{\"id\": \"x1\", \"text\": \"...\"}], " +
        "\"smart\": [\"...\"]}\n" +
        "kind: what this block mostly is.\n" +
        "balance: how much of the score comes from FOCUS (on the goal, on one thing) and how much from OUTPUT " +
        "(things made). The two sum to 1. It is NOT half and half by default: if he is reading there is no " +
        "output, he is only reading, so a reading block is judged almost all on focus. Use these as the anchor: " +
        "reading 0.9/0.1, study with exercises 0.7/0.3, writing 0.4/0.6, building or coding 0.35/0.65, " +
        "outreach 0.5/0.5, planning 0.6/0.4. Move from the anchor only when the goal clearly says so.\n" +
        "milestones: 0 to 5 named, concrete results for THIS block that would APPEAR ON SCREEN when reached " +
        "(\"the intro paragraph is written in the essay doc\", \"the reply to the client is sent in Gmail\", " +
        "\"the build runs in the simulator\"). Each must fit in the block's length. A pure reading block may " +
        "have none, or reading milestones like \"finished section 3\".\n" +
        "on_tells: 6 to 14 yes/no questions a screen judge can answer from ONE look at the screen, a yes " +
        "meaning he is doing this goal's work, including the lookups, messages and tools it needs. Concrete to " +
        "this goal: name the documents, people, topics and sites it involves. Do not name an app unless the " +
        "goal names it (people use different email, editors and AI tools). Under 25 words each.\n" +
        "off_tells: 3 to 8 yes/no questions, a yes meaning he drifted off this goal in a way this goal makes " +
        "likely (for reading: \"Is he watching a video unrelated to the reading?\").\n" +
        "smart: 1 to 4 short lines on what working SMART looks like for this goal (using AI and tools well, no " +
        "busywork, no retyping).\n" +
        "Never invent a person, deadline or project that is not in the goal or the context given."

    public static func systemPrompt() -> String { writerSystem }

    /// `prompt_for`: the writer's user message. `related` = the goal step's {people, projects, terms, sites} in
    /// order; `pastRubricMd` = the last rubric for the same goal label; `rulings` = screens he marked on task for
    /// this goal; `note` = his one typed fix, with `currentMd` the rubric he is fixing.
    public static func prompt(goal: String, specific: String, understood: String,
                              related: [(key: String, values: [String])] = [], pastRubricMd: String = "",
                              rulings: [String] = [], note: String = "", blockMinutes: Int = 25,
                              currentMd: String = "") -> String {
        let relLine = related.filter { !$0.values.isEmpty }
            .map { "\($0.key): \($0.values.joined(separator: ", "))" }.joined(separator: "; ")
        func orNone(_ s: String) -> String { s.isEmpty ? "(none)" : s }
        var parts = [
            "Goal he typed: " + orNone(PortedText.line(goal, 200)),
            "Specific goal for this block: " + orNone(PortedText.line(specific, 240)),
            "What it means: " + orNone(PortedText.line(understood, 240)),
            "What the work involves: " + orNone(relLine),
            "The block is \(max(1, blockMinutes)) minutes long.",
        ]
        let rl = rulings.map { PortedText.line($0, 160) }.filter { !$0.isEmpty }
        if !rl.isEmpty {
            parts.append("Screens he marked as on task for this goal before:\n"
                         + rl.prefix(8).map { "- " + $0 }.joined(separator: "\n"))
        }
        if !pastRubricMd.isEmpty {
            parts.append("The rubric written last time for this same goal (improve on it, keep what worked):\n"
                         + PortedText.prefix(pastRubricMd, 3000))
        }
        if !note.isEmpty {
            parts.append("The rubric he is looking at now:\n" + orNone(PortedText.prefix(currentMd, 3000)))
            parts.append("His fix, typed before starting — follow it exactly, it overrides the anchors: "
                         + PortedText.line(note, noteMax))
        }
        parts.append("Write the rubric as strict JSON.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: JSON (what is stored and compared)

    /// The full rubric as the brain stores it: {kind, balance, milestones, on_tells, off_tells, smart, fallback,
    /// note?, md}; a ruling tell carries "from": "ruling".
    public static func json(_ r: Rubric) -> JSONValue {
        func items(_ list: [Item]) -> JSONValue {
            .array(list.map { i in
                var o: [String: JSONValue] = ["id": .string(i.id), "text": .string(i.text)]
                if let f = i.from { o["from"] = .string(f) }
                return .object(o)
            })
        }
        let b = r.balance ?? defaultBalance
        var o: [String: JSONValue] = [
            "kind": .string((r.kind ?? .mixed).rawValue),
            "balance": .object(["focus": .number(b.focus), "output": .number(b.output)]),
            "milestones": items(r.milestones), "on_tells": items(r.onTells), "off_tells": items(r.offTells),
            "smart": .array(r.smart.map { .string($0) }), "fallback": .bool(r.fallback), "md": .string(r.md),
        ]
        if !r.note.isEmpty { o["note"] = .string(r.note) }
        return .object(o)
    }

    /// `public`: the fields the app shows — {kind, balance, milestones, on_tells, off_tells, smart, md}.
    public static func publicJSON(_ r: Rubric) -> JSONValue {
        guard case .object(var o) = json(r) else { return .null }
        o["fallback"] = nil; o["note"] = nil
        return .object(o)
    }
}
