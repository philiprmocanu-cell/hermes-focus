import Foundation

// MARK: - Python string behaviour the ported brain code relies on
//
// brain/rubric.py and the app.py prompts lean on a handful of Python idioms: `" ".join(str(x or "").split())[:n]`
// (whitespace collapsed, cut at n CODE POINTS), `str(x)` of a JSON value, `round(x, 2)` and `int(round(x))`
// (round half to even). These helpers reproduce them so the Swift port gives the same strings byte for byte
// (the fixtures in Tests/Fixtures/rubric check it).

public enum PortedText {
    /// Python's `str.split()` whitespace (Unicode White_Space plus the 0x1C–0x1F separators).
    static func isPyWhitespace(_ u: Unicode.Scalar) -> Bool {
        u.properties.isWhitespace || (0x1C...0x1F).contains(u.value)
    }

    /// `" ".join(s.split())`.
    public static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            if isPyWhitespace(u) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(u)
            }
        }
        return String(out)
    }

    /// `s[:n]` — the first n code points.
    public static func prefix(_ s: String, _ n: Int) -> String {
        guard n > 0 else { return "" }
        let scalars = s.unicodeScalars
        guard scalars.count > n else { return s }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

    /// `" ".join(str(x or "").split())[:n]` for a string.
    public static func line(_ s: String, _ n: Int) -> String { prefix(collapse(s), n) }

    /// `" ".join(str(x or "").split())[:n]` for any JSON value.
    public static func line(_ v: JSONValue?, _ n: Int) -> String { line(str(v), n) }

    /// `str(x or "")`: "" for null / false / 0 / "" / [] / {}; Python's spelling otherwise.
    public static func str(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "True" : ""
        case .number(let d): return d == 0 ? "" : num(d)
        case .array(let a): return a.isEmpty ? "" : repr(v)
        case .object(let o): return o.isEmpty ? "" : repr(v)
        }
    }

    /// A number as Python prints it: whole numbers without a decimal point (JSON ints), others shortest repr.
    public static func num(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 { return String(Int64(d)) }
        return pyFloat(d)
    }

    /// Python's `repr(float)`: "1.0", "0.85", "1e-05", "inf".
    public static func pyFloat(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d > 0 ? "inf" : "-inf" }
        var s = "\(d)"
        // Swift: "1e-05" / "1e+16" match Python's; "5e-324" too. Plain integers come back "1.0" in both.
        if s.contains("e") { if !s.contains("e-") && !s.contains("e+") { s = s.replacingOccurrences(of: "e", with: "e+") } }
        return s
    }

    /// Python `repr` of a JSON-decoded list / dict (best effort: `{'a': 1}`), only for odd writer output.
    static func repr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .number(let d): return num(d)
        case .string(let s): return "'" + s.replacingOccurrences(of: "'", with: "\\'") + "'"
        case .array(let a): return "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "'\($0)': " + repr(o[$0]!) }.joined(separator: ", ") + "}"
        }
    }

    /// Python's truthiness of a JSON value.
    public static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `_num(x)`: a finite-or-infinite float, None for bools, None for anything float() refuses and for NaN.
    public static func number(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        switch v {
        case .number(let d): return d.isNaN ? nil : d
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "")
            let low = t.lowercased()
            let d: Double?
            switch low {
            case "inf", "+inf", "infinity", "+infinity": d = .infinity
            case "-inf", "-infinity": d = -.infinity
            default: d = Double(t)
            }
            guard let d, !d.isNaN else { return nil }
            return d
        default: return nil
        }
    }

    /// Python's `round(x, 2)`: correctly rounded, ties to even on the exact binary value.
    public static func round2(_ x: Double) -> Double {
        Double(String(format: "%.2f", x)) ?? x
    }

    /// Python's `int(round(x))`: ties to even.
    public static func roundInt(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }
}
