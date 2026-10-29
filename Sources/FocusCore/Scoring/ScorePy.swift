import Foundation

// The Python semantics the scoring port leans on (brain/focus.py, brain/focus_day.py), kept in one
// place so the Swift reads like the Python it mirrors: truthiness, float(), round() (half to even,
// and round(x, n) on the exact binary value), str() of a JSON value, " ".join(s.split()), slicing
// by code point, the `or` default, first-wins max/min and insertion-ordered dictionaries.
// Internal to FocusCore; `Scoring` and `FocusDay` are the public face.

typealias ScoreObj = [String: JSONValue]

enum ScorePy {
    // ------------------------------------------------------------ values

    /// Python truthiness of a JSON value (`None`, False, 0, "", [], {} are false).
    static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `_num`: float(x), or nil when it is not a number (or NaN).
    static func num(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        let d: Double?
        switch v {
        case .number(let n): d = n
        case .bool(let b): d = b ? 1 : 0
        case .string(let s): d = parseFloat(s)
        default: d = nil
        }
        guard let x = d, !x.isNaN else { return nil }
        return x
    }

    static func parseFloat(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        if ["inf", "+inf", "infinity", "+infinity"].contains(l) { return .infinity }
        if ["-inf", "-infinity"].contains(l) { return -.infinity }
        if ["nan", "+nan", "-nan"].contains(l) { return .nan }
        if t.isEmpty || l.contains("x") { return nil }
        return Double(t)
    }

    /// `x or d` for a number: nil and 0 both fall back.
    static func nz(_ x: Double?, _ d: Double) -> Double {
        if let x, x != 0 { return x }
        return d
    }

    /// `_clamp`.
    static func clamp(_ x: Double?, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        guard let x, !x.isNaN else { return lo }
        return max(lo, min(hi, x))
    }

    /// `row[i]` of a JSON array, nil out of range.
    static func at(_ v: JSONValue?, _ i: Int) -> JSONValue? {
        if case .array(let a) = v, a.indices.contains(i) { return a[i] }
        return nil
    }

    static func isDict(_ v: JSONValue?) -> Bool {
        if case .object = v { return true }
        return false
    }

    static func obj(_ v: JSONValue?) -> ScoreObj? {
        if case .object(let o) = v { return o }
        return nil
    }

    /// `x or []` iterated, for a list.
    static func list(_ v: JSONValue?) -> [JSONValue] {
        if case .array(let a) = v { return a }
        return []
    }

    /// Only the dicts of a list (`[f for f in xs or [] if isinstance(f, dict)]`).
    static func dicts(_ v: JSONValue?) -> [ScoreObj] {
        list(v).compactMap { obj($0) }
    }

    /// An exact `True` (`x is True`).
    static func isTrue(_ v: JSONValue?) -> Bool {
        if case .bool(true) = v { return true }
        return false
    }

    /// `isinstance(x, int)` for a value that came through JSON: an integral number.
    static func intValue(_ v: JSONValue?) -> Int? {
        if case .number(let n) = v, n.isFinite, n == n.rounded(), abs(n) < 1e15 { return Int(n) }
        return nil
    }

    // ------------------------------------------------------------ strings

    /// `str(x or "")`.
    static func str(_ v: JSONValue?) -> String {
        guard truthy(v) else { return "" }
        return strRaw(v)
    }

    /// `str(x)` (None is "None").
    static func strRaw(_ v: JSONValue?) -> String {
        guard let v else { return "None" }
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .number(let n): return numStr(n)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// A JSON number as Python prints it: integral numbers came from ints.
    static func numStr(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e16 { return String(Int(n)) }
        return repr(n)
    }

    /// `repr(float)`.
    static func repr(_ x: Double) -> String {
        if x.isNaN { return "nan" }
        if x.isInfinite { return x > 0 ? "inf" : "-inf" }
        return "\(x)"
    }

    /// `" ".join(s.split())`.
    static func ws(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `s[:n]` by code point.
    static func cut(_ s: String, _ n: Int) -> String {
        if n <= 0 { return "" }
        var out = String.UnicodeScalarView()
        var i = 0
        for c in s.unicodeScalars {
            if i >= n { break }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// `s[n:]` by code point.
    static func drop(_ s: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.dropFirst(max(0, n))))
    }

    /// `len(s)`.
    static func len(_ s: String) -> Int { s.unicodeScalars.count }

    static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `s.strip(chars)`.
    static func strip(_ s: String, _ chars: String) -> String {
        rstrip(lstrip(s, chars), chars)
    }

    static func lstrip(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        var sc = Substring.UnicodeScalarView(s.unicodeScalars)
        while let f = sc.first, set.contains(f) { sc.removeFirst() }
        return String(String.UnicodeScalarView(sc))
    }

    /// `s.rstrip(chars)`; with no chars, whitespace.
    static func rstrip(_ s: String, _ chars: String? = nil) -> String {
        var sc = Substring.UnicodeScalarView(s.unicodeScalars)
        if let chars {
            let set = Set(chars.unicodeScalars)
            while let l = sc.last, set.contains(l) { sc.removeLast() }
        } else {
            while let l = sc.last, l.properties.isWhitespace { sc.removeLast() }
        }
        return String(String.UnicodeScalarView(sc))
    }

    /// `s[:1].upper() + s[1:]`.
    static func capFirst(_ s: String) -> String {
        guard let f = s.unicodeScalars.first else { return "" }
        return String(f).uppercased() + drop(s, 1)
    }

    /// `s[0].lower() + s[1:]`.
    static func lowerFirst(_ s: String) -> String {
        guard let f = s.unicodeScalars.first else { return "" }
        return String(f).lowercased() + drop(s, 1)
    }

    static func lastScalar(_ s: String) -> Character? {
        s.unicodeScalars.last.map { Character($0) }
    }

    /// `str.title()`.
    static func title(_ s: String) -> String {
        var out = ""
        var prevCased = false
        for sc in s.unicodeScalars {
            let ch = String(sc)
            let cased = sc.properties.isCased
            if cased {
                out += prevCased ? ch.lowercased() : ch.uppercased()
            } else {
                out += ch
            }
            prevCased = cased
        }
        return out
    }

    /// The first sentence: `re.split(r"(?<=[.!?])\s", s)[0]`.
    static func firstSentence(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var prev: Unicode.Scalar?
        for c in s.unicodeScalars {
            if c.properties.isWhitespace, let p = prev, ".!?".unicodeScalars.contains(p) { break }
            out.append(c)
            prev = c
        }
        return String(out)
    }

    /// `[a-z0-9]+` found in the (already lowercased) text.
    static func asciiWords(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                cur.append(c)
            } else if !cur.isEmpty {
                out.append(String(cur))
                cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
        if c == "_" { return true }
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    // ------------------------------------------------------------ numbers

    /// `round(x)` to an int: half to even.
    static func iround(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        return Int(x.rounded(.toNearestOrEven))
    }

    /// `round(x, n)`: correctly rounded on the exact binary value, as Python does.
    static func round(_ x: Double, _ n: Int) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.\(n)f", x)) ?? x
    }

    static func fmt(_ x: Double, _ spec: String) -> String { String(format: spec, x) }

    // ------------------------------------------------------------ regex

    static func regex(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: opts)
    }

    static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: s) else { return "" }
        return String(s[rr])
    }

    // ------------------------------------------------------------ JSON builders

    static func n(_ x: Double) -> JSONValue { .number(x) }
    static func n(_ x: Int) -> JSONValue { .number(Double(x)) }
    static func n(_ x: Double?) -> JSONValue { x.map { .number($0) } ?? .null }
    static func n(_ x: Int?) -> JSONValue { x.map { .number(Double($0)) } ?? .null }
    static func s(_ x: String) -> JSONValue { .string(x) }
    static func pair(_ k: String, _ v: Double) -> JSONValue { .array([.string(k), .number(v)]) }
}

/// A dict that remembers insertion order, for Python's `by.get(k, 0) + v` tallies and the
/// first-wins `max(by, key=by.get)`.
struct OrderedTally {
    private(set) var keys: [String] = []
    private(set) var values: [String: Double] = [:]

    mutating func add(_ k: String, _ v: Double) {
        if values[k] == nil { keys.append(k); values[k] = 0 }
        values[k]! += v
    }

    subscript(k: String) -> Double? { values[k] }

    var isEmpty: Bool { keys.isEmpty }

    /// The first key with the largest value.
    func argmax() -> String? {
        var best: String?
        for k in keys where best == nil || values[k]! > values[best!]! { best = k }
        return best
    }

    /// (key, value) in insertion order.
    var items: [(String, Double)] { keys.map { ($0, values[$0]!) } }

    /// Biggest first; ties keep insertion order (Python's stable sort on -value).
    func sortedDesc() -> [(String, Double)] {
        items.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map { $0.element }
    }
}
