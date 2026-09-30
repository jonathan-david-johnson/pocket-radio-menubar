import Foundation

public enum TracePrivacy {
    public static func url(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else { return "<invalid-url>" }
        if scheme == "file" { return "file:///<local-audio>" }
        guard ["http", "https"].contains(scheme), components.host != nil else { return "<invalid-url>" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid-url>"
    }

    /// Station text can contain framed ICY StreamUrl values. Bound text, strip
    /// credentials/query strings from embedded HTTP URLs, and hide local file paths.
    public static func metadata(_ raw: String) -> String {
        var text = String(raw.prefix(2048))
        let pattern = #"(?:https?|file)://[^\s'";<>]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return "<redacted>" }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            text.replaceSubrange(range, with: url(String(text[range])))
        }
        return text
    }
}
