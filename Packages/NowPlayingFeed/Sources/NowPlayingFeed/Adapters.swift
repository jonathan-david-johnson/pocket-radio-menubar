import Foundation

public enum FeedError: Error, Equatable {
    case unknownAdapter(String)
    case malformed(String)
}

/// One parser per source. Each takes the response body and returns what it found, or nil when the
/// source had nothing current. No parser makes a network call.
public enum Adapters {
    public static let names: Set<String> = [
        "kexp", "kcrw", "azuracast", "laut", "radioco", "triton", "live365", "radiojar", "iheart", "radioking",
        "airtime", "sr", "abc", "radiofrance", "npo", "npr_composer", "icecast", "shoutcast", "zeno", "icy",
    ]

    /// - Parameters:
    ///   - params: the adapter's request parameters from the case (`tz`, `path`, `shortcode`, `block`, ...).
    ///   - now: the clock, epoch seconds.
    public static func parse(_ adapter: String, body: String, params: [String: Any], now: Double) throws -> Candidate? {
        switch adapter {
        case "kexp": return try kexp(json(body))
        case "kcrw": return try kcrw(json(body))
        case "azuracast": return try azuracast(json(body), shortcode: params["shortcode"] as? String)
        case "laut": return try laut(json(body))
        case "radioco": return try radioco(json(body))
        case "triton": return triton(body)
        case "live365": return try live365(json(body))
        case "radiojar": return try radiojar(json(body))
        case "iheart": return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try iheart(json(body))
        case "radioking": return try radioking(json(body))
        case "airtime": return try airtime(json(body))
        case "sr": return try sr(json(body))
        case "abc": return try abc(json(body))
        case "radiofrance": return try radiofrance(json(body), now: now)
        case "npo": return try npo(json(body), now: now)
        case "npr_composer": return try nprComposer(json(body), zone: params["tz"] as? String)
        case "icecast": return try icecast(json(body), path: params["path"] as? String)
        case "shoutcast": return shoutcast(body)
        case "zeno": return try zeno(params["block"] as? String ?? body)
        case "icy": return icy(params["block"] as? String ?? body, stationName: params["station_name"] as? String)
        default: throw FeedError.unknownAdapter(adapter)
        }
    }

    // MARK: JSON helpers

    typealias Obj = [String: Any]

    static func json(_ s: String) throws -> Any {
        guard let d = s.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
            throw FeedError.malformed("not JSON")
        }
        return v
    }

    static func obj(_ v: Any?) -> Obj? { v as? Obj }
    static func arr(_ v: Any?) -> [Any]? { v as? [Any] }
    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: Station APIs

    static func kexp(_ j: Any) throws -> Candidate? {
        guard let r = obj(arr(obj(j)?["results"])?.first) else { throw FeedError.malformed("kexp results") }
        let start = str(r["airdate"]).flatMap { FeedTime.iso($0) }
        if str(r["play_type"]) != "trackplay" { return Candidate(kind: .stationId, title: nil, startedAt: start) }
        return Candidate(title: str(r["song"]), artist: str(r["artist"]), album: str(r["album"]), artwork: str(r["image_uri"]), startedAt: start)
    }

    static func kcrw(_ j: Any) throws -> Candidate? {
        guard let r = obj(arr(j)?.first) else { throw FeedError.malformed("kcrw list") }
        return Candidate(title: str(r["title"]), artist: str(r["artist"]), album: str(r["album"]), artwork: str(r["albumImage"]),
                         startedAt: str(r["datetime"]).flatMap { FeedTime.iso($0) }, show: str(r["program_title"]))
    }

    // MARK: Hosting platforms

    static func azuracast(_ j: Any, shortcode: String?) throws -> Candidate? {
        var root = obj(j)
        if let list = arr(j) {
            root = list.compactMap(obj).first { obj($0["station"])?["shortcode"] as? String == shortcode } ?? obj(list.first)
        }
        guard let np = obj(root?["now_playing"]), let song = obj(np["song"]) else { throw FeedError.malformed("azuracast now_playing") }
        return Candidate(title: Text.nonEmpty(str(song["title"])) ?? str(song["text"]), artist: str(song["artist"]), album: str(song["album"]),
                         artwork: str(song["art"]), startedAt: num(np["played_at"]), duration: num(np["duration"]))
    }

    static func laut(_ j: Any) throws -> Candidate? {
        guard let o = obj(j) else { throw FeedError.malformed("laut") }
        return Candidate(title: str(o["title"]), artist: str(obj(o["artist"])?["name"]), album: str(o["album"]),
                         startedAt: str(o["started_at"]).flatMap { FeedTime.iso($0) }, duration: num(o["length"]))
    }

    static func radioco(_ j: Any) throws -> Candidate? {
        guard let t = obj(obj(j)?["current_track"]) else { throw FeedError.malformed("radio.co") }
        return Candidate(title: str(t["title"]), artwork: str(t["artwork_url_large"]),
                         startedAt: str(t["start_time"]).flatMap { FeedTime.iso($0) }, combined: true)
    }

    static func triton(_ body: String) -> Candidate? {
        var props: [String: String] = [:]
        for m in Text.allMatches(Text.regex(#"<property name="(\w+)"><!\[CDATA\[(.*?)\]\]>"#, [.dotMatchesLineSeparators]), body) {
            if let k = m[1], let v = m[2] { props[k] = v }
        }
        if props.isEmpty { return nil }
        func ms(_ k: String) -> Double? { props[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { $0 / 1000 } }
        return Candidate(title: props["cue_title"], artist: props["track_artist_name"], album: props["track_album_name"],
                         startedAt: ms("cue_time_start"), duration: ms("cue_time_duration"))
    }

    static func live365(_ j: Any) throws -> Candidate? {
        guard let t = obj(obj(j)?["current-track"]) else { throw FeedError.malformed("live365") }
        return Candidate(title: str(t["title"]), artist: str(t["artist"]), artwork: str(t["art"]),
                         startedAt: str(t["start"]).flatMap { FeedTime.iso($0) }, duration: num(t["duration"]))
    }

    static func radiojar(_ j: Any) throws -> Candidate? {
        guard let o = obj(j) else { throw FeedError.malformed("radiojar") }
        return Candidate(title: str(o["title"]), artist: str(o["artist"]), album: str(o["album"]), artwork: str(o["thumb"]),
                         duration: num(o["duration"]))
    }

    static func iheart(_ j: Any) throws -> Candidate? {
        guard let o = obj(j) else { throw FeedError.malformed("iheart") }
        return Candidate(title: str(o["title"]), artist: str(o["artist"]), album: str(o["album"]), artwork: str(o["imagePath"]),
                         startedAt: num(o["startTime"]).map { $0 / 1000 }, duration: num(o["trackDuration"]))
    }

    static func radioking(_ j: Any) throws -> Candidate? {
        guard let o = obj(j) else { throw FeedError.malformed("radioking") }
        return Candidate(title: str(o["title"]), artist: str(o["artist"]), album: str(o["album"]), artwork: str(o["cover"]),
                         startedAt: str(o["started_at"]).flatMap { FeedTime.iso($0) }, duration: num(o["duration"]))
    }

    static func airtime(_ j: Any) throws -> Candidate? {
        guard let o = obj(j), let tzName = str(obj(o["station"])?["timezone"]), let tz = TimeZone(identifier: tzName) else {
            throw FeedError.malformed("airtime station.timezone")
        }
        guard let cur = obj(obj(o["tracks"])?["current"]) else { return nil }
        let md = obj(cur["metadata"]) ?? [:]
        let a = str(cur["starts"]).flatMap { FeedTime.iso($0, zone: tz) }
        let b = str(cur["ends"]).flatMap { FeedTime.iso($0, zone: tz) }
        let title = Text.nonEmpty(str(md["track_title"])) ?? str(cur["name"])
        return Candidate(title: title, artist: str(md["artist_name"]), album: str(md["album_title"]), startedAt: a,
                         duration: (a != nil && b != nil) ? b! - a! : nil)
    }

    // MARK: Broadcaster networks

    static func sr(_ j: Any) throws -> Candidate? {
        guard let pl = obj(obj(j)?["playlist"]) else { throw FeedError.malformed("sr playlist") }
        guard let s = obj(pl["song"]) else { return nil }
        let a = str(s["starttimeutc"]).flatMap(FeedTime.dotNet), b = str(s["stoptimeutc"]).flatMap(FeedTime.dotNet)
        return Candidate(title: str(s["title"]), artist: str(s["artist"]), album: str(s["albumname"]), startedAt: a,
                         duration: (a != nil && b != nil) ? b! - a! : nil)
    }

    static func abc(_ j: Any) throws -> Candidate? {
        guard let i = obj(arr(obj(j)?["items"])?.first), let rec = obj(i["recording"]) else { throw FeedError.malformed("abc items") }
        let artists = (arr(rec["artists"]) ?? []).compactMap { str(obj($0)?["name"]) }.joined(separator: ", ")
        let rel = obj(arr(rec["releases"])?.first)
        let art = str(obj(arr(rel?["artwork"])?.first)?["url"])
        return Candidate(title: str(rec["title"]), artist: artists, album: str(rel?["title"]), artwork: art,
                         startedAt: str(i["played_time"]).flatMap { FeedTime.iso($0) }, duration: num(rec["duration"]))
    }

    /// A tree of steps. Picks the song step that spans `now`; with several, the one that started last.
    static func radiofrance(_ j: Any, now: Double) throws -> Candidate? {
        guard let steps = obj(obj(j)?["steps"]) else { throw FeedError.malformed("radiofrance steps") }
        let current = steps.values.compactMap(obj).filter {
            (num($0["start"]) ?? .infinity) <= now && now < (num($0["end"]) ?? -.infinity) && str($0["embedType"]) == "song"
        }
        guard let s = current.max(by: { (num($0["start"]) ?? 0) < (num($1["start"]) ?? 0) }),
              let a = num(s["start"]), let b = num(s["end"]) else { return nil }
        let artist = Text.nonEmpty(str(s["authors"])) ?? str(s["performers"])
        return Candidate(title: str(s["title"]), artist: artist, album: str(s["titreAlbum"]), artwork: str(s["visual"]),
                         startedAt: a, duration: b - a)
    }

    static func npo(_ j: Any, now: Double) throws -> Candidate? {
        guard let data = arr(obj(j)?["data"]) else { throw FeedError.malformed("npo data") }
        let tz = TimeZone(identifier: "Europe/Amsterdam")!
        for case let t as Obj in data {
            guard let a = str(t["startdatetime"]).flatMap({ FeedTime.iso($0, zone: tz) }),
                  let b = str(t["enddatetime"]).flatMap({ FeedTime.iso($0, zone: tz) }) else { continue }
            if a <= now && now < b {
                let title = (str(t["title"]) ?? "").replacingOccurrences(of: #"^#\d+:\s*"#, with: "", options: .regularExpression)
                return Candidate(title: title, artist: str(t["artist"]), artwork: str(t["image_url_400x400"]), startedAt: a, duration: b - a)
            }
        }
        return nil
    }

    static func nprComposer(_ j: Any, zone: String?) throws -> Candidate? {
        guard let on = obj(obj(j)?["onNow"]) else { throw FeedError.malformed("composer onNow") }
        let program = str(obj(on["program"])?["name"])
        if let s = obj(on["song"]) {
            let tz = TimeZone(identifier: zone ?? "America/Chicago") ?? TimeZone(secondsFromGMT: 0)!
            let d = num(s["_duration"]).map { $0 / 1000 }
            return Candidate(title: str(s["trackName"]), artist: str(s["artistName"]), album: str(s["collectionName"]),
                             startedAt: str(s["_start_time"]).flatMap { FeedTime.monthDayYear($0, zone: tz) },
                             duration: (d ?? 0) > 0 ? d : nil, show: program)
        }
        let a = str(on["start_utc"]).flatMap { FeedTime.iso($0) }, b = str(on["end_utc"]).flatMap { FeedTime.iso($0) }
        return Candidate(kind: .show, title: program, startedAt: a, duration: (a != nil && b != nil) ? b! - a! : nil, show: program)
    }

    // MARK: Server status pages

    static func icecast(_ j: Any, path: String?) throws -> Candidate? {
        guard let stats = obj(obj(j)?["icestats"]) else { throw FeedError.malformed("icestats") }
        var sources: [Obj] = []
        if let one = obj(stats["source"]) { sources = [one] } else if let many = arr(stats["source"]) { sources = many.compactMap(obj) }
        let m = sources.first { path != nil && (str($0["listenurl"]) ?? "").contains(path!) } ?? sources.first
        guard let src = m else { return nil }
        let title = Text.nonEmpty(str(src["title"])) ?? str(src["yp_currently_playing"])
        let artist = str(src["artist"])
        return Candidate(title: title, artist: artist, combined: (title ?? "").contains(" - ") && (artist ?? "").isEmpty)
    }

    static func shoutcast(_ body: String) -> Candidate? {
        guard let m = Text.firstMatch(Text.regex(#"<body>(.*?)</body>"#, [.dotMatchesLineSeparators]), body), let inner = m[1] else { return nil }
        let parts = inner.split(separator: ",", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        return Candidate(title: parts.count > 6 ? parts[6] : nil, combined: true)
    }

    static func zeno(_ block: String) throws -> Candidate? {
        guard let m = Text.firstMatch(Text.regex(#"^data:(.*)$"#, [.anchorsMatchLines]), block), let raw = m[1],
              let o = obj(try json(raw)) else { throw FeedError.malformed("zeno data line") }
        let title = str(o["streamTitle"]) ?? ""
        if title.trimmingCharacters(in: CharacterSet(charactersIn: " -")).isEmpty { return nil }
        return Candidate(title: title, combined: true)
    }

    // MARK: In-band ICY

    /// Automation attributes: `Artist - text="Title" song_spot="M" ... amgArtworkURL="..." length="00:03:23"`.
    static func icy(_ block: String, stationName: String?) -> Candidate? {
        let titleRE = Text.regex(#"StreamTitle='(.*?)';(?:\s*StreamUrl=|$|\s*\w+=)"#, [.dotMatchesLineSeparators])
        let looseRE = Text.regex(#"StreamTitle='(.*)'"#, [.dotMatchesLineSeparators])
        let t = Text.firstMatch(titleRE, block)?[1] ?? Text.firstMatch(looseRE, block)?[1] ?? ""
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if let a = Text.firstMatch(Text.regex(#"^(.*?)\s+-\s+text="([^"]*)"(.*)$"#, [.dotMatchesLineSeparators]), t),
           let text = a[2], let rest = a[3] {
            var attrs: [String: String] = [:]
            for m in Text.allMatches(Text.regex(#"(\w+)="([^"]*)""#, []), rest) { if let k = m[1], let v = m[2] { attrs[k] = v } }
            let artist = (a[1] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            var dur: Double?
            if let l = attrs["length"], let lm = Text.firstMatch(Text.regex(#"^(\d\d):(\d\d):(\d\d)$"#, []), l),
               let h = Double(lm[1] ?? ""), let mi = Double(lm[2] ?? ""), let s = Double(lm[3] ?? "") {
                let total = h * 3600 + mi * 60 + s
                dur = total > 0 ? total : nil
            }
            var kind: Candidate.Kind
            if Text.matches(Text.regex(#"spot block|text="spot|adContext|adw_ad|\badvert(isement)?\b|\bad break\b"#), text) { kind = .ad }
            else if attrs["song_spot"] == "M" { kind = Rules.classify(title: text, artist: artist.isEmpty ? nil : artist) }
            else { kind = .stationId }
            return Candidate(kind: kind, title: text, artist: artist.isEmpty ? nil : artist,
                             artwork: Text.nonEmpty(attrs["amgArtworkURL"]), duration: dur)
        }
        if let name = stationName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty {
            let low = t.trimmingCharacters(in: .whitespaces).lowercased()
            if low == name || name.contains(low) { return Candidate(kind: .stationId, title: t, combined: true) }
        }
        return Candidate(title: t, combined: true)
    }
}

public enum NowPlayingFeed {
    /// Parse one response and apply the shared rules.
    public static func record(adapter: String, body: String, params: [String: Any] = [:], now: Double,
                              stationId: String) throws -> NowPlayingRecord {
        let cand = try Adapters.parse(adapter, body: body, params: params, now: now)
        let channel: NowPlayingRecord.Channel = adapter == "icy" ? .icy : .api
        return Rules.record(cand, now: now, stationId: stationId, channel: channel, adapter: adapter)
    }
}
