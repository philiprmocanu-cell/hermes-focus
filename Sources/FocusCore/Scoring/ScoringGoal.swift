import Foundation

// The goal-text checks around the score (brain/focus.py): "same", junk goals, the short label,
// the goal-change rule and the re-judging of earlier frames, and the work-style tip filter.

extension Scoring {
    static let samePhrases: Set<String> = ["same", "same thing", "same again", "same as before", "same as last time",
                                           "same goal", "same task", "again", "continue", "continuing", "keep going",
                                           "carry on", "ditto", "still the same", "more of the same", "as before"]
    static let junkWords: Set<String> = ["stuff", "work", "things", "thing", "idk", "dunno", "asdf", "something",
                                         "whatever", "misc", "random", "nothing", "idc", "hmm", "blah", "test",
                                         "productive", "focus", "grind", "grinding", "tasks", "task", "busy", "yes",
                                         "no", "ok", "okay", "lol", "none", "na", "n/a", "todo", "todos", "working",
                                         "doing", "shit", "crap", "sth", "smth", "etc", "general", "various", "be"]
    static let mash = ["asdf", "qwer", "zxcv", "hjkl", "jkl;", "sdfg", "fdsa", "wasd"]
    static let goalStop: Set<String> = stopWords.union(["i", "im", "i'm", "am", "will", "gonna", "going", "want",
                                                        "need", "just", "is", "it", "be", "on", "some", "stuff",
                                                        "things"])
    public static let labelWords = 6

    /// `_norm`: lowercased, punctuation (but not apostrophes) to spaces, whitespace collapsed.
    static func norm(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for c in text.lowercased().unicodeScalars {
            if ScorePy.isWordScalar(c) || c.properties.isWhitespace || c == "'" {
                out.append(c)
            } else {
                out.append(" ")
            }
        }
        return ScorePy.ws(String(out))
    }

    static func norm(_ v: JSONValue?) -> String { norm(ScorePy.str(v)) }

    /// He wants the last block's goal again.
    public static func isSameGoal(_ text: String, previousGoal: String = "") -> Bool {
        let t = norm(text)
        if t.isEmpty { return true }
        if samePhrases.contains(t) || samePhrases.contains(ScorePy.rstrip(t, "s")) { return true }
        return !previousGoal.isEmpty && t == norm(previousGoal)
    }

    static func stem(_ w: String) -> String {
        ScorePy.len(w) > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? ScorePy.cut(w, ScorePy.len(w) - 1) : w
    }

    static func isMash(_ w: String) -> Bool {
        if mash.contains(where: { w.contains($0) }) { return true }
        return ScorePy.len(w) >= 4 && !w.unicodeScalars.contains(where: { "aeiouy".unicodeScalars.contains($0) })
    }

    /// '' when the goal names real work; 'junk' when it names nothing; 'unknown' for one unknown word.
    public static func goalVagueness(_ text: String, context: String = "") -> String {
        let words = norm(text).replacingOccurrences(of: "'", with: "").split(separator: " ").map(String.init)
        if words.isEmpty { return "junk" }
        let content = words.filter { !goalStop.contains($0) }
        if content.isEmpty { return "junk" }
        if content.allSatisfy({ junkWords.contains($0) || isMash($0) || ScorePy.len($0) < 2 }) { return "junk" }
        let real = content.filter { !junkWords.contains($0) && !isMash($0) }
        if real.count == 1 {
            let have = Set(ScorePy.asciiWords(context.lowercased()).map(stem))
            if !have.contains(stem(real[0])) { return "unknown" }
        }
        return ""
    }

    /// A short label: at most n words, no trailing punctuation.
    public static func goalLabel(_ text: String, _ n: Int = labelWords) -> String {
        let words = ScorePy.ws(text).components(separatedBy: " ")
        if words == [""] { return "" }
        return ScorePy.strip(words.prefix(n).joined(separator: " "), " .,;:-—")
    }

    /// The block's goal names no real work: the judge should infer it from the screen.
    public static func needsInferredGoal(_ goal: String, specificGoal: JSONValue? = nil) -> Bool {
        if !ScorePy.ws(ScorePy.str(specificGoal)).isEmpty {
            return goalVagueness(ScorePy.str(specificGoal)) == "junk"
        }
        let g = ScorePy.ws(goal)
        return g.isEmpty || goalVagueness(g) == "junk" || isSameGoal(g)
    }

    public static func needsInferredGoal(_ goal: JSONValue?) -> Bool { needsInferredGoal(ScorePy.str(goal)) }

    // ------------------------------------------------------------ the goal changed

    public static let goalChangeFrames = 3
    public static let goalChangeOffGoal = 0.4
    public static let goalChangeProducing = 0.6
    public static let goalChangeQuality = 0.5

    /// This screenshot shows actual work, whatever it is work ON.
    public static func frameRealWork(_ row: JSONValue?) -> Bool {
        guard let r = ScorePy.obj(row), !ScorePy.truthy(r["pending"]), !isDistraction(r) else { return false }
        let mode = ScorePy.str(r["mode"])
        if mode == "consuming" { return false }
        let quality = ScorePy.num(r["quality"])
        guard let producing = ScorePy.num(r["producing"]) else {
            return quality != nil && quality! >= goalChangeQuality && (mode == "making" || mode == "studying")
        }
        return producing >= goalChangeProducing
    }

    /// The other thing he has plainly moved on to, or nil (the last `n` frames off the goal, real work,
    /// and naming the same other thing).
    public static func goalChange(_ frames: JSONValue?, n: Int = goalChangeFrames) -> String? {
        let all = ScorePy.dicts(frames)
        let rows = Array(all.suffix(max(1, n)))
        if rows.count < n { return nil }
        var named: [String] = []
        for f in rows {
            guard let on = ScorePy.num(f["on_goal"]), on < goalChangeOffGoal, frameRealWork(.object(f)) else { return nil }
            let thing = ScorePy.cut(ScorePy.ws(ScorePy.str(f["actual_goal"])), 80)
            if thing.isEmpty { return nil }
            named.append(thing)
        }
        let newest = goalWords(named.last!)
        if newest.isEmpty { return nil }
        if named.dropLast().contains(where: { goalWords($0).isDisjoint(with: newest) }) { return nil }
        var best = named[0]
        for t in named where ScorePy.len(t) > ScorePy.len(best) { best = t }
        return best
    }

    /// (short label, one-sentence specific goal) for the goal he has moved to.
    public static func nameNewGoal(_ actualGoal: String, recent: JSONValue? = nil) -> (label: String, specific: String) {
        let thing = ScorePy.cut(ScorePy.ws(actualGoal), 240)
        let words = goalWords(thing)
        var best: (String, String)?
        var score = 0
        for r in ScorePy.dicts(recent) {
            let label = ScorePy.ws(ScorePy.str(r["goal"]))
            let spec = ScorePy.truthy(r["specific_goal"]) ? r["specific_goal"] : r["understood"]
            let specific = ScorePy.ws(ScorePy.str(spec))
            let hits = words.intersection(goalWords([label, specific].joined(separator: " "))).count
            if !label.isEmpty && hits > score {
                let s = ScorePy.cut(specific, 240)
                best = (ScorePy.cut(label, 80), s.isEmpty ? ScorePy.cut(label, 240) : s)
                score = hits
            }
        }
        if let best { return best }
        let label = goalLabel(thing)
        return (label.isEmpty ? ScorePy.cut(thing, 80) : label, thing)
    }

    /// The goal changed mid-block: re-judge the stored frames against the new goal from the words they
    /// kept. Credit only ever rises. Returns how many frames changed; mutates them.
    @discardableResult
    public static func rescoreOnGoal(_ newGoal: String, frames: inout [JSONValue]) -> Int {
        let words = goalWords(newGoal)
        if words.isEmpty { return 0 }
        var changed = 0
        for i in frames.indices {
            guard var f = ScorePy.obj(frames[i]), !isDistraction(f), ScorePy.str(f["mode"]) != "consuming" else { continue }
            let text = ["actual_goal", "doing", "note"].map { ScorePy.str(f[$0]) }.joined(separator: " ")
            let have = Set(ScorePy.asciiWords(text.lowercased()).filter { $0.count > 2 && !stopWords.contains($0) })
            let hits = words.intersection(have)
            if hits.isEmpty { continue }
            let value = ScorePy.round(ScorePy.clamp(0.5 + 0.5 * Double(hits.count) / Double(words.count)), 3)
            if let old = ScorePy.num(f["on_goal"]), old >= value { continue }
            f["on_goal"] = .number(value)
            f["rescored"] = .bool(true)
            frames[i] = .object(f)
            changed += 1
        }
        return changed
    }

    // ------------------------------------------------------------ the tip

    static let genericTips = ["stay focused", "keep going", "keep it up", "keep up the good work", "avoid distractions",
                              "take a break", "take breaks", "stay on task", "you got this", "you've got this",
                              "great job", "good job", "keep working", "minimize distractions", "stay productive",
                              "focus on your goal", "focus on the task", "stay on track", "keep focusing",
                              "stay motivated", "work hard"]
    static let toolNames = ["vs code", "vscode", "visual studio code", "cursor", "xcode", "sublime",
                            "vim", "neovim", "emacs", "pycharm", "jetbrains", "intellij", "zed",
                            "atom", "textedit", "notepad", "notion", "obsidian", "google docs",
                            "word", "pages", "terminal", "iterm", "warp", "claude", "chatgpt",
                            "copilot", "an ide", "the ide", "an editor", "a code editor",
                            "a text editor", "a proper editor", "a real editor", "another app",
                            "a different app", "another tool", "a different tool"]
    static let editorNames = ["vs code", "vscode", "visual studio code", "cursor", "xcode", "sublime",
                              "vim", "neovim", "emacs", "pycharm", "jetbrains", "intellij", "zed",
                              "atom", "textedit", "notepad", "an ide", "the ide", "an editor",
                              "a code editor", "a text editor", "a proper editor", "a real editor",
                              "another app", "a different app", "another tool", "a different tool"]
    static let switchRe = ScorePy.regex(#"\b(switch|swap|move|shift|migrate)\b[^.]{0,40}?\b(to|into|over to|in)\b[^.]{0,40}"#,
                                        .caseInsensitive)
    static let insteadRe = ScorePy.regex(#"\b(use|open|try|do it in|write it in|do this in)\b[^.]{0,40}?\binstead\b"#,
                                         .caseInsensitive)

    /// The line tells him to take the work into a different app or editor.
    public static func switchesTool(_ text: String) -> Bool {
        let t = ScorePy.ws(text).lowercased()
        if t.isEmpty { return false }
        for (re, names) in [(switchRe, toolNames), (insteadRe, editorNames)] {
            for m in ScorePy.matches(re, t) {
                let s = ScorePy.group(m, 0, in: t)
                if names.contains(where: { s.contains($0) }) { return true }
            }
        }
        return false
    }

    /// The model's one-line tip, or '' when it is empty, generic filler, or says to switch apps.
    public static func tipText(_ raw: String) -> String {
        var t = ScorePy.ws(raw)
        if t.isEmpty { return "" }
        t = ScorePy.strip(ScorePy.cut(ScorePy.firstSentence(t), 140))
        if switchesTool(t) { return "" }
        let bare = norm(t).replacingOccurrences(of: "'", with: "")
        let bareWords = bare.split(separator: " ")
        if bareWords.count < 3 { return "" }
        for g in genericTips {
            let g2 = norm(g).replacingOccurrences(of: "'", with: "")
            if bare == g2 || (bare.hasPrefix(g2) && bareWords.count <= g2.split(separator: " ").count + 3) { return "" }
        }
        return t
    }
}
