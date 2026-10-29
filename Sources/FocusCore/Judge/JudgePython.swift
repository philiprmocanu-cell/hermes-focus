import Foundation

// MARK: - Python semantics the judge leans on
//
// brain/jev.py is written against Python's rules: `float(x)` accepts numbers,
// bools and numeric strings; truthiness; `round()` is half-even on the exact
// binary value; `str.split()` splits on Python's whitespace set; slicing and
// `len` count code points, not grapheme clusters. These helpers reproduce
// those rules so the port gives the same numbers and the same strings.

extension Judge {
    // MARK: Numbers

    /// Python `float(x)`: nil where Python would raise.
    static func pyFloat(_ x: JSONValue?) -> Double? {
        guard let x else { return nil }
        switch x {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let t = pyStrip(s).replacingOccurrences(of: "_", with: "")
            if t.isEmpty { return nil }
            switch t.lowercased() {
            case "nan", "+nan", "-nan": return .nan
            case "inf", "+inf", "infinity", "+infinity": return .infinity
            case "-inf", "-infinity": return -.infinity
            default: break
            }
            // Python rejects hex floats and a few forms strtod takes; keep to decimal.
            guard t.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
            return Double(t)
        default: return nil
        }
    }

    /// `_clamp(x, lo, hi)`: float(x) clamped, lo when it is not a number or NaN.
    static func clamp(_ x: JSONValue?, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        guard let v = pyFloat(x), !v.isNaN else { return lo }
        return max(lo, min(hi, v))
    }

    static func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        v.isNaN ? lo : max(lo, min(hi, v))
    }

    /// `_num(x)`: float(x) or nil (NaN is nil).
    static func num(_ x: JSONValue?) -> Double? {
        guard let v = pyFloat(x), !v.isNaN else { return nil }
        return v
    }

    /// `float(_num(x) or 0.0)`.
    static func num0(_ x: JSONValue?) -> Double { num(x) ?? 0 }

    /// Python `round(x, n)`: correctly rounded, ties to even on the exact binary value.
    public static func pyRound(_ x: Double, _ n: Int) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.\(n)f", x)) ?? x
    }

    /// Python `round(x)` → int (ties to even).
    static func pyRoundInt(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

    /// Python `int(x)` on a float: toward zero.
    static func pyInt(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        return Int(x.rounded(.towardZero))
    }

    /// Python `repr(float)` (what an f-string prints for a float).
    static func pyFloatRepr(_ x: Double) -> String {
        if x.isNaN { return "nan" }
        if x.isInfinite { return x > 0 ? "inf" : "-inf" }
        let a = abs(x)
        if a != 0, a < 1e16, a >= 1e-4 {
            // Swift switches to exponent notation earlier than Python does.
            var s = "\(x)"
            if s.contains("e") {
                s = String(format: "%.17g", x)
                // Shortest round-trip with plain digits.
                for p in 1...17 {
                    let t = String(format: "%.\(p)g", x)
                    if Double(t) == x { s = t; break }
                }
                if s.contains("e") { s = Decimal(x).description }
                if !s.contains(".") { s += ".0" }
            }
            return s
        }
        if x == 0 { return x.sign == .minus ? "-0.0" : "0.0" }
        return "\(x)"
    }

    /// Python `str(x)` for a JSON value. A whole number prints as an int ("7"),
    /// as it would after a JSON round trip; use `pyStrFloat` where Python holds a float.
    static func pyStr(_ x: JSONValue?) -> String {
        guard let x else { return "None" }
        switch x {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e18 { return String(Int64(n)) }
            return pyFloatRepr(n)
        case .string(let s): return s
        case .array, .object:
            let data = (try? JSONEncoder().encode(x)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// `str(x)` where Python holds a float (a rounded score): "1.0", "0.25", "None".
    static func pyStrFloat(_ x: JSONValue?) -> String {
        if case .number(let n)? = x { return pyFloatRepr(n) }
        return pyStr(x)
    }

    /// `str(x or "")`.
    static func pyStrOr(_ x: JSONValue?) -> String { truthy(x) ? pyStr(x) : "" }

    /// Python truthiness.
    static func truthy(_ x: JSONValue?) -> Bool {
        guard let x else { return false }
        switch x {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `r.get(k) is not None`.
    static func present(_ x: JSONValue?) -> Bool {
        if let x, x != .null { return true }
        return false
    }

    // MARK: Strings (code points, Python whitespace)

    private static let pySpace: Set<UInt32> = [9, 10, 11, 12, 13, 28, 29, 30, 31, 32, 0x85, 0xA0, 0x1680,
                                               0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
                                               0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    static func isPySpace(_ u: Unicode.Scalar) -> Bool { pySpace.contains(u.value) }

    /// `str.split()` with no separator.
    static func pySplit(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if isPySpace(u) {
                if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
            } else {
                cur.append(u)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    /// `" ".join(s.split())`.
    static func squash(_ s: String) -> String { pySplit(s).joined(separator: " ") }

    /// `s[:n]` (code points).
    static func cut(_ s: String, _ n: Int) -> String {
        let u = s.unicodeScalars
        if u.count <= n { return s }
        return String(String.UnicodeScalarView(u.prefix(max(0, n))))
    }

    /// `len(s)` (code points).
    static func plen(_ s: String) -> Int { s.unicodeScalars.count }

    /// `s.strip()` (Python whitespace), or `s.strip(chars)`.
    static func pyStrip(_ s: String, _ chars: Set<Unicode.Scalar>? = nil) -> String {
        let u = Array(s.unicodeScalars)
        let drop: (Unicode.Scalar) -> Bool = { u in chars.map { $0.contains(u) } ?? isPySpace(u) }
        var a = 0, b = u.count
        while a < b, drop(u[a]) { a += 1 }
        while b > a, drop(u[b - 1]) { b -= 1 }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: u[a..<b])
        return String(v)
    }

    /// `s.rstrip(chars)`.
    static func pyRstrip(_ s: String, _ chars: Set<Unicode.Scalar>) -> String {
        var u = Array(s.unicodeScalars)
        while let last = u.last, chars.contains(last) { u.removeLast() }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: u)
        return String(v)
    }

    /// `needle in hay` (exact code points; "" is in everything).
    static func pyIn(_ needle: String, _ hay: String) -> Bool {
        if needle.isEmpty { return true }
        return hay.range(of: needle, options: .literal) != nil
    }

    static func pyStarts(_ s: String, _ prefix: String) -> Bool {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    static func pyEnds(_ s: String, _ suffix: String) -> Bool {
        s.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }

    /// `str.lower()`.
    static func pyLower(_ s: String) -> String { s.lowercased() }

    // MARK: JSON access

    static func dict(_ x: JSONValue?) -> Dict? {
        if case .object(let o)? = x { return o }
        return nil
    }

    static func list(_ x: JSONValue?) -> [JSONValue]? {
        if case .array(let a)? = x { return a }
        return nil
    }

    /// `[str(t) for t in x or []]`.
    static func strList(_ x: JSONValue?) -> [String] {
        guard truthy(x) else { return [] }
        if let a = list(x) { return a.map { pyStr($0) } }
        if case .string(let s)? = x { return s.unicodeScalars.map { String($0) } }
        return []
    }

    static func jnum(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? .null }
}
