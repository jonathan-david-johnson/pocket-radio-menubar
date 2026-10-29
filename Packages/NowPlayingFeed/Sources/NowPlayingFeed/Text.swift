import Foundation

enum Text {
    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    /// HTML-unescape and trim. Empty becomes nil.
    static func clean(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let t = unescape(s).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let body = String(s[s.index(after: i)..<semi])
                var rep: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X"), let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                    rep = String(Character(u))
                } else if body.hasPrefix("#"), let v = UInt32(body.dropFirst()), let u = Unicode.Scalar(v) {
                    rep = String(Character(u))
                } else if let n = named[body] {
                    rep = n
                }
                if let rep = rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // Patterns are literals in this file; a failure is a programming error.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func firstMatch(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Range(r, in: s).map { String(s[$0]) }
        }
    }

    static func allMatches(_ re: NSRegularExpression, _ s: String) -> [[String?]] {
        re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : Range(r, in: s).map { String(s[$0]) }
            }
        }
    }
}
