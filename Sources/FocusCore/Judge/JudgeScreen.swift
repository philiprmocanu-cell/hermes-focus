import CryptoKit
import Foundation

// MARK: - The screen: URLs, distraction sites, searches, reading, idle, the story, rulings

extension Judge {
    // MARK: URLs (Python 3.9 urllib.parse.urlsplit / parse_qs, as `_split` uses them)

    struct SplitURL: Equatable {
        var host = ""
        var path = ""
        var query: [String: [String]] = [:]
    }

    private static let schemeChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.".unicodeScalars)
    private static let letters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)

    /// `^[a-z][a-z0-9+.-]*://` (case-insensitive).
    private static func hasScheme(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard let first = u.first, letters.contains(first) else { return false }
        var i = 1
        while i < u.count, schemeChars.contains(u[i]) { i += 1 }
        return i + 3 <= u.count && u[i] == ":" && u[i + 1] == "/" && u[i + 2] == "/"
    }

    /// (host without www., path lowercased without trailing slash, query dict).
    static func split(_ url: String) -> SplitURL {
        var raw = pyStrip(url)
        if raw.isEmpty { return SplitURL() }
        if !hasScheme(raw) { raw = "https://" + raw }
        // urlsplit drops tab, CR and LF anywhere (bpo-43882).
        raw = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }))
        var u = Array(raw.unicodeScalars)
        if let colon = u.firstIndex(of: ":"), colon > 0, u[..<colon].allSatisfy({ schemeChars.contains($0) }) {
            u = Array(u[(colon + 1)...])
        }
        var netloc: [Unicode.Scalar] = []
        if u.count >= 2, u[0] == "/", u[1] == "/" {
            var end = u.count
            for d in ["/", "?", "#"] as [Unicode.Scalar] {
                if let i = u[2...].firstIndex(of: d), i < end { end = i }
            }
            netloc = Array(u[2..<end])
            u = Array(u[end...])
            let open = netloc.contains("["), close = netloc.contains("]")
            if open != close { return SplitURL() }      // "Invalid IPv6 URL"
        }
        if let h = u.firstIndex(of: "#") { u = Array(u[..<h]) }
        var query: [Unicode.Scalar] = []
        if let q = u.firstIndex(of: "?") {
            query = Array(u[(q + 1)...])
            u = Array(u[..<q])
        }
        // .hostname
        var hostinfo = netloc
        if let at = hostinfo.lastIndex(of: "@") { hostinfo = Array(hostinfo[(at + 1)...]) }
        var hostname: [Unicode.Scalar]
        if let ob = hostinfo.firstIndex(of: "[") {
            let rest = hostinfo[(ob + 1)...]
            hostname = Array(rest.prefix { $0 != "]" })
        } else {
            hostname = Array(hostinfo.prefix { $0 != ":" })
        }
        var host = ""
        if !hostname.isEmpty {
            var zone: [Unicode.Scalar] = []
            if let pct = hostname.firstIndex(of: "%") {
                zone = Array(hostname[pct...])
                hostname = Array(hostname[..<pct])
            }
            host = str(hostname).lowercased() + str(zone)
        }
        if pyStarts(host, "www.") { host = String(String.UnicodeScalarView(host.unicodeScalars.dropFirst(4))) }
        let path = pyRstrip(str(u).lowercased(), ["/"])
        return SplitURL(host: host, path: path, query: parseQS(str(query)))
    }

    private static func str(_ u: [Unicode.Scalar]) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: u)
        return String(v)
    }

    /// `urllib.parse.parse_qs` (blank values dropped, '&' only).
    static func parseQS(_ qs: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var order: [String] = []
        for part in qs.components(separatedBy: "&") where !part.isEmpty {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = String(part[..<eq]), value = String(part[part.index(after: eq)...])
            if value.isEmpty { continue }
            let n = unquote(name.replacingOccurrences(of: "+", with: " "))
            let v = unquote(value.replacingOccurrences(of: "+", with: " "))
            if out[n] == nil { order.append(n) }
            out[n, default: []].append(v)
        }
        return out
    }

    private static func hexVal(_ u: Unicode.Scalar) -> UInt8? {
        switch u.value {
        case 48...57: return UInt8(u.value - 48)
        case 65...70: return UInt8(u.value - 55)
        case 97...102: return UInt8(u.value - 87)
        default: return nil
        }
    }

    /// `urllib.parse.unquote(s, 'utf-8', 'replace')`.
    static func unquote(_ s: String) -> String {
        if !s.unicodeScalars.contains("%") { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var bytes: [UInt8] = []
        func flush() {
            if !bytes.isEmpty {
                out.append(contentsOf: String(decoding: bytes, as: UTF8.self).unicodeScalars)
                bytes.removeAll()
            }
        }
        var i = 0
        while i < u.count {
            let c = u[i]
            if c.value > 0x7F {
                flush()
                out.append(c)
                i += 1
                continue
            }
            if c == "%", i + 2 < u.count,
               let hi = hexVal(u[i + 1]), let lo = hexVal(u[i + 2]) {
                bytes.append(hi << 4 | lo)
                i += 3
                continue
            }
            bytes.append(UInt8(c.value))
            i += 1
        }
        flush()
        return String(out)
    }

    static func hostIs(_ host: String, _ domain: String) -> Bool {
        host == domain || pyEnds(host, "." + domain)
    }

    // MARK: Picture apps, distraction sites, searches

    public static func pictureApp(_ app: String, _ url: String) -> Bool {
        let a = app.lowercased()
        let host = split(url).host
        return pictureApps.contains { pyIn($0, a) } || pictureHosts.contains { hostIs(host, $0) }
    }

    private struct Site {
        let label: String
        let domains: [String]
        let test: (@Sendable (String) -> Bool)?
        let words: [String]
    }

    private static let feedPaths: Set<String> = ["", "/", "/home", "/explore"]
    private static let shopHosts = ["ebay.com", "etsy.com", "walmart.com", "target.com", "bestbuy.com", "aliexpress.com",
                                    "temu.com", "shein.com", "wayfair.com", "zara.com", "hm.com", "asos.com", "costco.com",
                                    "newegg.com", "wish.com", "shop.app"]
    private static let amazonTLDs: Set<String> = ["com", "co.uk", "ca", "de", "fr", "es", "it", "co.jp", "in",
                                                  "com.au", "com.mx"]
    private static let socialWords = ["social media", "socials"]
    private static let shopWords = ["buy", "shop", "shopping", "order", "purchase", "amazon", "gift"]
    private static let sites: [Site] = [
        Site(label: "Instagram", domains: ["instagram.com"], test: nil, words: ["instagram", "reels", "insta"]),
        Site(label: "TikTok", domains: ["tiktok.com"], test: nil, words: ["tiktok", "tik tok"]),
        Site(label: "Facebook", domains: ["facebook.com", "fb.com"], test: nil, words: ["facebook"]),
        Site(label: "Snapchat", domains: ["snapchat.com"], test: nil, words: ["snapchat"]),
        Site(label: "Netflix", domains: ["netflix.com"], test: nil, words: ["netflix"]),
        Site(label: "Twitch", domains: ["twitch.tv"], test: nil, words: ["twitch", "livestream"]),
        Site(label: "YouTube Shorts", domains: ["youtube.com"], test: { Judge.pyStarts($0, "/shorts") },
             words: ["shorts"]),
        Site(label: "YouTube home", domains: ["youtube.com"],
             test: { Judge.feedPaths.contains($0) || Judge.pyStarts($0, "/feed") }, words: ["youtube"]),
        Site(label: "the Reddit front page", domains: ["reddit.com"],
             test: { Judge.feedPaths.contains($0)
                 || ["/best", "/hot", "/new", "/top", "/rising", "/r/popular", "/r/all"].contains($0) },
             words: ["reddit", "subreddit"]),
        Site(label: "the X feed", domains: ["x.com", "twitter.com"],
             test: { Judge.feedPaths.contains($0) || Judge.pyStarts($0, "/i/trending") },
             words: ["twitter", "tweet", "x.com", "x post", "x thread"]),
        Site(label: "the LinkedIn feed", domains: ["linkedin.com"],
             test: { Judge.pyStarts($0, "/feed") && !Judge.pyStarts($0, "/feed/update") }, words: ["linkedin"]),
    ]
    private static let native: [String: String] = [
        "instagram": "Instagram", "tiktok": "TikTok", "facebook": "Facebook", "snapchat": "Snapchat",
        "netflix": "Netflix", "twitch": "Twitch"]

    /// `^(?:www\.|smile\.)?amazon\.(?:com|co\.uk|...)$` on a host already without "www.".
    private static func isAmazon(_ host: String) -> Bool {
        var h = host
        if pyStarts(h, "www.") { h = String(String.UnicodeScalarView(h.unicodeScalars.dropFirst(4))) }
        else if pyStarts(h, "smile.") { h = String(String.UnicodeScalarView(h.unicodeScalars.dropFirst(6))) }
        guard pyStarts(h, "amazon.") else { return false }
        return amazonTLDs.contains(String(String.UnicodeScalarView(h.unicodeScalars.dropFirst(7))))
    }

    /// The obvious distraction in front ('Instagram', 'the LinkedIn feed',
    /// 'a shopping site'), or '' — never one the goal itself names.
    public static func distractionSite(_ url: String, app: String = "", goal: String = "") -> String {
        let g = " " + squash(goal.lowercased()) + " "
        func exempt(_ words: [String], social: Bool = true) -> Bool {
            (social && socialWords.contains { pyIn($0, g) }) || words.contains { pyIn($0, g) }
        }
        if let nat = native[squash(app.lowercased())] {
            let words = sites.first { $0.label == nat }?.words ?? [nat.lowercased()]
            return exempt(words) ? "" : nat
        }
        let s = split(url)
        if s.host.isEmpty { return "" }
        for site in sites where site.domains.contains(where: { hostIs(s.host, $0) }) && (site.test?(s.path) ?? true) {
            return exempt(site.words) ? "" : site.label
        }
        if isAmazon(s.host) || shopHosts.contains(where: { hostIs(s.host, $0) }) {
            return exempt(shopWords, social: false) ? "" : "a shopping site"
        }
        return ""
    }

    private static let searchHosts: [(host: String, key: String)] = [
        ("google.", "q"), ("bing.com", "q"), ("duckduckgo.com", "q"), ("search.yahoo.com", "p"),
        ("youtube.com", "search_query"), ("perplexity.ai", "q"), ("search.brave.com", "q"),
        ("ecosia.org", "q"), ("kagi.com", "q")]

    /// The words he searched for, when the page is a search ('' otherwise).
    public static func searchWords(_ url: String) -> String {
        let s = split(url)
        for (h, key) in searchHosts {
            if pyStarts(s.host, h) || pyIn(h, s.host), let vals = s.query[key], let first = vals.first {
                if h == "youtube.com" && !pyStarts(s.path, "/results") { continue }
                return cut(squash(first), 160)
            }
        }
        return ""
    }

    // MARK: Reading and idle

    /// A PDF, an ebook, a course page, docs, a long article or a long AI
    /// reply: no input for a while here is reading, not being away.
    public static func readingMaterial(_ screen: Dict, textLen: Int = 0) -> Bool {
        let url = pyStrOr(screen["url"]).lowercased()
        let app = squash(pyStrOr(screen["app"]).lowercased())
        let s = split(url)
        if pyEnds(s.path, ".pdf") || readingApps.contains(where: { $0 == app || pyIn($0, app) }) { return true }
        if !s.host.isEmpty && readingHosts.contains(where: { pyIn($0, s.host) || pyIn($0, url) }) { return true }
        return textLen >= longText
    }

    /// Seconds of no keyboard, mouse or scroll before he counts as away.
    public static func idleLimit(_ screen: Dict, textLen: Int = 0, studying: Bool = false) -> Int {
        studying || readingMaterial(screen, textLen: textLen) ? readingIdleS : idleS
    }

    public static func isAway(_ idleS: JSONValue?, _ screen: Dict, textLen: Int = 0, studying: Bool = false) -> Bool {
        num0(idleS) >= Double(idleLimit(screen, textLen: textLen, studying: studying))
    }

    public static func isAway(_ idleS: Double, _ screen: Dict, textLen: Int = 0, studying: Bool = false) -> Bool {
        isAway(JSONValue.number(idleS), screen, textLen: textLen, studying: studying)
    }

    // MARK: The story so far

    private static func screenKey(_ screen: Dict) -> String {
        let host = split(pyStrOr(screen["url"])).host
        let title = cut(squash(pyStrOr(screen["title"])), 60)
        return (host.isEmpty ? cut(squash(pyStrOr(screen["app"])), 30) : host) + "|" + title
    }

    /// The trail of screens with this second added (a new segment when the
    /// screen changed, else the last one stretched). Older than the window is
    /// dropped. Returns a new list.
    public static func trailAdd(_ trail: [Dict], screen: Dict, mode: String, now: Double,
                                windowS: Double = storyWindowS) -> [Dict] {
        var out = trail.filter { num0($0["to"]) >= now - windowS }
        let key = screenKey(screen)
        if var last = out.last, last["key"] == .string(key), now - num0(last["to"]) <= 30 {
            last["to"] = .number(now)
            if !mode.isEmpty { last["mode"] = .string(mode) }
            out[out.count - 1] = last
            return out
        }
        let url = pyStrOr(screen["url"])
        out.append(["key": .string(key), "app": .string(cut(squash(pyStrOr(screen["app"])), 30)),
                    "host": .string(split(url).host),
                    "title": .string(cut(squash(pyStrOr(screen["title"])), 60)),
                    "search": .string(cut(searchWords(url), 60)), "mode": .string(mode),
                    "from": .number(now), "to": .number(now)])
        return Array(out.suffix(40))
    }

    static func span(_ seconds: Double) -> String {
        let s = pyRoundInt(seconds)
        return s < 60 ? "\(s) s" : "\(pyRoundInt(Double(s) / 60)) min"
    }

    /// 'Last 10 min, oldest first: Gmail — Re: equity (studying, 3 min) ->
    /// searched "time in japan now" (20 s) -> ...' or '' with nothing yet.
    public static func storyLine(_ trail: [Dict], now: Double) -> String {
        var parts: [String] = []
        for (i, t) in trail.enumerated() {
            let dur = max(0, num0(t["to"]) - num0(t["from"])) + 1
            if dur < storyMinS && i != trail.count - 1 { continue }
            var what: String
            if truthy(t["search"]) {
                what = "searched \"\(pyStr(t["search"]))\""
            } else {
                let host = t["host"], app = t["app"]
                what = truthy(host) ? pyStr(host) : truthy(app) ? pyStr(app) : "?"
                if truthy(t["title"]), t["title"] != (t["app"] ?? .null) {
                    what += " — " + cut(pyStr(t["title"]), 40)
                }
            }
            let mode = t["mode"]
            var bits: [String] = []
            if truthy(mode), mode != .string("other") { bits.append(pyStr(mode)) }
            bits.append(span(dur))
            parts.append("\(what) (\(bits.joined(separator: ", ")))")
        }
        if parts.isEmpty { return "" }
        let head = "Last 10 min, oldest first: "
        var line = head + parts.joined(separator: " -> ")
        while plen(line) > storyMaxChars && parts.count > 1 {
            parts.removeFirst()
            line = head + "... -> " + parts.joined(separator: " -> ")
        }
        return cut(line, storyMaxChars)
    }

    // MARK: The goal's world

    /// The goal step's {people, projects, terms, sites}, cleaned: lists of
    /// short strings, at most 8 each. {} when there is nothing.
    public static func relatedTerms(_ related: JSONValue?) -> Dict {
        var out: Dict = [:]
        guard let rel = dict(related) else { return out }
        for k in ["people", "projects", "terms", "sites"] {
            var vals = rel[k]
            if case .string? = vals { vals = .array([vals!]) }
            guard let items = list(vals) else { continue }
            var clean: [String] = []
            for v in items {
                let s = cut(squash(pyStrOr(v)), 80)
                if !s.isEmpty && !clean.contains(where: { $0.lowercased() == s.lowercased() }) { clean.append(s) }
                if clean.count == 8 { break }
            }
            if !clean.isEmpty { out[k] = strings(clean) }
        }
        return out
    }

    // MARK: "That was for work"

    /// The user pressed "I'm on task" on a nudge: the screen it was about, as a
    /// rule for the rest of the block. by="second" is the second-opinion judge.
    public static func exceptionFrom(_ screen: Dict, at: Double, by: String = "him") -> Dict {
        let host = split(pyStrOr(screen["url"])).host
        let app = cut(squash(pyStrOr(screen["app"])), 60)
        let title = cut(squash(pyStrOr(screen["title"])), 80)
        let whereS = !host.isEmpty ? host : !app.isEmpty ? app : "this screen"
        let shown = whereS + (!title.isEmpty && title != app ? " (\(title))" : "")
        let site = host.isEmpty ? app.lowercased() : host
        if by == "second" {
            return ["site": .string(site), "title": .string(title), "at": .number(at), "by": .string("second"),
                    "rule": .string("A closer look found \(shown) on task for this block: treat it as on task.")]
        }
        return ["site": .string(site), "title": .string(title), "at": .number(at),
                "rule": .string("He said \(shown) was for work during this block: treat it as on task.")]
    }

    private static func normTitle(_ t: JSONValue?) -> String {
        var words: [String] = []
        var cur = ""
        for u in pyStrOr(t).lowercased().unicodeScalars {
            if (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty { words.append(cur); cur = "" }
        }
        if !cur.isEmpty { words.append(cur) }
        return cut(words.joined(separator: " "), 40)
    }

    /// The same site (or app) as a ruling, and the same page when the ruling
    /// named one. A ruling on the Claude app covers the whole app.
    public static func exceptionMatches(_ exc: JSONValue?, _ screen: Dict) -> Bool {
        guard let e = dict(exc), truthy(e["site"]) else { return false }
        let host = split(pyStrOr(screen["url"])).host
        let app = squash(pyStrOr(screen["app"])).lowercased()
        guard e["site"] == .string(host) || e["site"] == .string(app) else { return false }
        let title = normTitle(e["title"])
        if title.isEmpty || title == normTitle(screen["app"]) { return true }
        return title == normTitle(screen["title"])
    }

    // MARK: Digest

    public static func textDigest(_ text: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(squash(text).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
