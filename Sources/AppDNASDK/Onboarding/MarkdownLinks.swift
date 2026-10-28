import Foundation

/// Where markdown text can link, judged on a TEMPLATE before its tokens are substituted.
///
/// `rich_text` and an agreement's copy are drawn through Foundation's markdown parser, which follows
/// every one of these link forms (and Android draws the same set, `MarkdownLinks.kt`):
///
/// - an inline link `[label](destination)`, its destination bare (balanced parentheses and backslash
///   escapes allowed, an optional title after it) or in angle brackets (`<…>`, spaces allowed);
/// - an autolink in angle brackets: `<scheme:…>` or `<user@host>`;
/// - a bare URL: `http://`, `https://` or `ftp://` (any case), or `www.`; and a bare email address
///   (`mailto:` and `xmpp:` prefixes included).
///
/// A token substituted into any of those spans is part of a URL a tap opens, so its value leaves the
/// device. `destinations(inTemplate:)` returns every span a substituted value could reach inside a
/// link destination; a `{{…}}` token stands for any text without whitespace, and the spans are
/// generous — a token covered there resolves to what the user typed, which is never Google's content.
/// The Kotlin twin is `MarkdownLinks.destinationsInTemplate`.
enum MarkdownLinks {

    /// One line of rich text as `rich_text` and an agreement's copy parse it: Foundation's markdown,
    /// inline syntax only, whitespace kept. The links a tap opens are the runs carrying `.link`.
    @available(iOS 15.0, *)
    static func parseLine(_ line: String) -> AttributedString? {
        try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

    private static let space: Set<UInt16> = [32, 9, 10, 13]
    private static let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let rbracket = UInt16(UInt8(ascii: "]")), lparen = UInt16(UInt8(ascii: "(")), rparen = UInt16(UInt8(ascii: ")"))
    private static let lt = UInt16(UInt8(ascii: "<")), gt = UInt16(UInt8(ascii: ">"))
    private static let quote = UInt16(UInt8(ascii: "\"")), apostrophe = UInt16(UInt8(ascii: "'"))
    private static let colon = UInt16(UInt8(ascii: ":")), at = UInt16(UInt8(ascii: "@")), newline = UInt16(10)
    /// What a token stands for in a word: any text without whitespace (a private-use placeholder).
    private static let tokenUnit: UInt16 = 0xE000

    /// A scheme (or a token standing for one) followed by `://`, at a word's start or after punctuation.
    // swiftlint:disable:next force_try
    private static let bareURLInWord = try? NSRegularExpression(pattern: "(^|[^A-Za-z0-9])([A-Za-z][A-Za-z0-9+.\\-]*|\u{E000})://")

    private static func isEmailUnit(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 46 || c == 43 || c == 45 || c == 95
    }

    /// Every span of the template `text` a substituted value could reach inside a link destination, as
    /// UTF-16 ranges: an inline link's destination (and its title), an angle-bracket autolink, and any
    /// whitespace-delimited word that is or holds a bare URL or email address.
    static func destinations(inTemplate text: String) -> [NSRange] {
        guard text.contains("{{") else { return [] }
        let u = Array(text.utf16)
        let n = u.count
        var out: [NSRange] = []

        func tokenEnd(_ i: Int) -> Int? {
            guard i + 1 < n, u[i] == open, u[i + 1] == open else { return nil }
            var k = i + 2
            while k + 1 < n {
                if u[k] == close && u[k + 1] == close { return k + 2 }
                k += 1
            }
            return nil
        }
        func isBlank(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        // After a destination: optional spaces, an optional title, optional spaces, then `)`.
        func closeParen(_ from: Int) -> Int? {
            var j = from
            while j < n && isBlank(u[j]) { j += 1 }
            if j < n && (u[j] == quote || u[j] == apostrophe || u[j] == lparen) {
                let closer = u[j] == lparen ? rparen : u[j]
                j += 1
                while j < n && u[j] != closer {
                    if let e = tokenEnd(j) { j = e; continue }
                    if u[j] == backslash { j += 1 }
                    j += 1
                }
                guard j < n else { return nil }
                j += 1
                while j < n && isBlank(u[j]) { j += 1 }
            }
            return j < n && u[j] == rparen ? j : nil
        }

        var i = 0
        scan: while i < n {
            if let e = tokenEnd(i) { i = e; continue }
            let c = u[i]
            if c == backslash { i += 2; continue }
            if c == rbracket, i + 1 < n, u[i + 1] == lparen {
                var j = i + 2
                while j < n && isBlank(u[j]) { j += 1 }
                if j < n && u[j] == lt {
                    var k = j + 1
                    var ok = false
                    while k < n {
                        if let e = tokenEnd(k) { k = e; continue }
                        let d = u[k]
                        if d == backslash { k += 2; continue }
                        if d == gt { ok = true; break }
                        if d == lt || d == newline { break }
                        k += 1
                    }
                    if ok, let end = closeParen(k + 1) {
                        out.append(NSRange(location: j, length: end - j))
                        i = end + 1
                        continue scan
                    }
                } else {
                    var k = j
                    var parens = 0
                    while k < n {
                        if let e = tokenEnd(k) { k = e; continue }
                        let d = u[k]
                        if d == backslash { k += 2; continue }
                        if d == lparen { parens += 1 }
                        if d == rparen { if parens == 0 { break }; parens -= 1 }
                        if space.contains(d) || d < 0x20 { break }
                        k += 1
                    }
                    if parens == 0, let end = closeParen(min(k, n)) {
                        out.append(NSRange(location: j, length: end - j))
                        i = end + 1
                        continue scan
                    }
                }
            }
            if c == lt {
                var k = i + 1
                var token = false, marker = false, ok = false
                while k < n {
                    if let e = tokenEnd(k) { token = true; k = e; continue }
                    let d = u[k]
                    if d == gt { ok = true; break }
                    if space.contains(d) || d == lt || d < 0x20 { break }
                    if d == colon || d == at { marker = true }
                    k += 1
                }
                if ok && k > i + 1 && (token || marker) {
                    out.append(NSRange(location: i + 1, length: k - i - 1))
                    i = k + 1
                    continue
                }
            }
            i += 1
        }

        // Words that are, or hold, a bare URL or email address: from where the link can begin (its
        // scheme, `www.`, the email's local part) to where it can end (the word's end).
        var w = 0
        while w < n {
            if space.contains(u[w]) || u[w] == lt { w += 1; continue }
            var plain: [UInt16] = []
            var at: [Int] = [] // the template index of each plain unit
            var token = false
            while w < n {
                if let e = tokenEnd(w) { token = true; plain.append(tokenUnit); at.append(w); w = e; continue }
                if space.contains(u[w]) || u[w] == lt { break }
                plain.append(u[w]); at.append(w)
                w += 1
            }
            guard token else { continue }
            let p = String(utf16CodeUnits: plain, count: plain.count)
            let lower = p.lowercased()
            let lowerUnits = Array(lower.utf16)
            var starts: [Int] = []
            if let re = bareURLInWord,
               let m = re.firstMatch(in: lower, range: NSRange(location: 0, length: lowerUnits.count)) {
                starts.append(m.range(at: 2).location)
            }
            for marker in ["www.", "mailto:", "xmpp:"] {
                if let r = lower.range(of: marker) { starts.append(lower.utf16.distance(from: lower.startIndex, to: r.lowerBound)) }
            }
            if let a = plain.firstIndex(of: self.at), a > 0, a < plain.count - 1 {
                let domain = plain[(a + 1)...]
                if domain.contains(UInt16(UInt8(ascii: "."))) || domain.contains(tokenUnit) {
                    var s = a
                    while s > 0 && (isEmailUnit(plain[s - 1]) || plain[s - 1] == tokenUnit) { s -= 1 }
                    if s < a { starts.append(s) }
                }
            }
            guard let start = starts.min() else { continue }
            out.append(NSRange(location: at[start], length: w - at[start]))
        }
        return out
    }
}
