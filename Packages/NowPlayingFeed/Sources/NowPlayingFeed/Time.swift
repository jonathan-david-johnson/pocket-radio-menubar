import Foundation

/// The time formats the contract's sources use. Every function returns epoch seconds (UTC) or nil.
public enum FeedTime {
    private static let isoRE = Text.regex(
        #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"#)

    /// ISO 8601 with or without a colon in the offset, optional fractional seconds.
    /// A string with no offset is read in `zone` (UTC when nil).
    public static func iso(_ s: String, zone: TimeZone? = nil) -> Double? {
        guard let m = Text.firstMatch(isoRE, s.trimmingCharacters(in: .whitespaces)) else { return nil }
        var tz = zone ?? TimeZone(secondsFromGMT: 0)!
        if let off = m[8] {
            if off == "Z" { tz = TimeZone(secondsFromGMT: 0)! }
            else {
                let sign = off.hasPrefix("-") ? -1 : 1
                let digits = off.dropFirst().replacingOccurrences(of: ":", with: "")
                let h = Int(digits.prefix(2)) ?? 0
                let mi = digits.count >= 4 ? Int(digits.suffix(2)) ?? 0 : 0
                tz = TimeZone(secondsFromGMT: sign * (h * 3600 + mi * 60))!
            }
        }
        guard let date = date(y: m[1], mo: m[2], d: m[3], h: m[4], mi: m[5], s: m[6], tz: tz) else { return nil }
        var frac = 0.0
        if let f = m[7], let v = Double("0." + f) { frac = v }
        return date + frac
    }

    /// `MM-DD-YYYY HH:MM:SS` in `zone` (NPR Composer).
    public static func monthDayYear(_ s: String, zone: TimeZone) -> Double? {
        guard let m = Text.firstMatch(Text.regex(#"^(\d{2})-(\d{2})-(\d{4}) (\d{2}):(\d{2}):(\d{2})$"#), s) else { return nil }
        return date(y: m[3], mo: m[1], d: m[2], h: m[4], mi: m[5], s: m[6], tz: zone)
    }

    /// `/Date(1793270805000)/` (milliseconds).
    public static func dotNet(_ s: String) -> Double? {
        guard let m = Text.firstMatch(Text.regex(#"(-?\d+)"#), s), let v = m[1], let ms = Double(v) else { return nil }
        return ms / 1000
    }

    /// `YYYY-MM-DDTHH:MM:SSZ`, the contract's output format. Fractions are dropped.
    public static func format(_ epoch: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: epoch.rounded(.down)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private static func date(y: String?, mo: String?, d: String?, h: String?, mi: String?, s: String?, tz: TimeZone) -> Double? {
        guard let y = y.flatMap(Int.init), let mo = mo.flatMap(Int.init), let d = d.flatMap(Int.init),
              let h = h.flatMap(Int.init), let mi = mi.flatMap(Int.init), let s = s.flatMap(Int.init) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return cal.date(from: c)?.timeIntervalSince1970
    }
}
