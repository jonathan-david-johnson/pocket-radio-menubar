import Foundation

/// The shared rules in `contracts/now_playing_feed/README.md`.
public enum Rules {
    private static let ad = Text.regex(#"spot block|text="spot|adContext|adw_ad|\badvert(isement)?\b|\bad break\b"#)
    private static let htmlLeak = Text.regex(#"<!doctype|<html|<head|</?body"#)
    private static let structural = Text.regex(
        #"\{[a-z_]+\}|\.(mp3|wav|flac|m4a|aac)\s*$|(^|[\s_-])XYZ_ID\d*|_ID\d+\b|^\s*-*\s*$"#)
    private static let phrase = Text.regex(
        #"probl[eè]me technique|technical difficult|this station will continue|^searching\W*$|^unknown( artist| title)?$|^live$|^on air$|^station id\b|station identification|^jingle[\s_-]*\d*$"#)
    private static let phraseArtist = Text.regex(#"probl[eè]me technique|technical difficult|this station will continue"#)
    private static let starFormat = Text.regex(#"^Song\*(?<title>[^*]+)\*(?<artist>[^*]*)\*"#, [])

    /// Kinds returned: song, placeholder, ad, unknown.
    public static func classify(title: String?, artist: String?) -> Candidate.Kind {
        let tt = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aa = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if tt.isEmpty { return .unknown }
        let both = "\(aa) - \(tt)"
        if Text.matches(ad, both) { return .ad }
        if Text.matches(htmlLeak, both) { return .placeholder }
        if aa.lowercased() == "unknown artist" || Text.matches(structural, tt) || (!aa.isEmpty && Text.matches(structural, aa)) {
            return .placeholder
        }
        // Bare status words count only for a title with no artist; slate phrases may also be the artist.
        if (aa.isEmpty && Text.matches(phrase, tt)) || (!aa.isEmpty && Text.matches(phraseArtist, aa)) { return .placeholder }
        return .song
    }

    /// `Artist - Title` splits at the first ` - `. An adapter's explicit kind (station_id, show) is kept.
    static func splitCombined(_ c: Candidate) -> Candidate {
        var c = c
        guard c.combined, c.artist == nil, let t = c.title, let r = t.range(of: " - ") else { return c }
        if c.kind == .stationId || c.kind == .show { return c }
        c.artist = trimmed(String(t[..<r.lowerBound]))
        c.title = trimmed(String(t[r.upperBound...]))
        c.kind = classify(title: c.title, artist: c.artist)
        return c
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `Song*TITLE*ARTIST*YEAR*ID`.
    static func splitStar(_ c: Candidate) -> Candidate {
        var c = c
        guard let t = c.title, let m = Text.firstMatch(starFormat, t), let title = m[1] else { return c }
        c.title = trimmed(title)
        c.artist = trimmed(m[2] ?? "")
        c.kind = classify(title: c.title, artist: c.artist)
        return c
    }

    /// Candidate (or nil: the source had nothing) -> contract record.
    public static func record(_ candidate: Candidate?, now: Double, stationId: String, channel: NowPlayingRecord.Channel, adapter: String?) -> NowPlayingRecord {
        var prov = NowPlayingRecord.Provenance(adapter: adapter, channel: channel, observedAt: FeedTime.format(now), timing: .none)
        guard let raw = candidate else {
            return NowPlayingRecord(stationId: stationId, status: .between, item: nil, show: nil, provenance: prov, pollAfterSec: 10)
        }
        let c = splitStar(splitCombined(raw))
        let started = (c.startedAt ?? 0) != 0 ? c.startedAt : nil
        let duration = (c.duration ?? 0) > 0 ? c.duration : nil
        prov.timing = started != nil ? .stamped : .observed
        let show = c.show.map { NowPlayingRecord.Show(title: $0) }
        switch c.kind {
        case .ad, .stationId, .placeholder, .unknown:
            prov.suppressed = NowPlayingRecord.Suppressed(rawValue: c.kind.rawValue)
            return NowPlayingRecord(stationId: stationId, status: .between, item: nil, show: show, provenance: prov, pollAfterSec: 10)
        case .song, .show:
            break
        }
        let ends: Double? = (started != nil && duration != nil) ? started! + duration! : nil
        var artwork = c.artwork
        if let a = artwork, a.hasPrefix("http://") { artwork = "https://" + a.dropFirst(7) }
        let item = NowPlayingRecord.Item(
            kind: c.kind == .show ? .show : .song,
            title: c.title ?? "",
            artist: c.kind == .show ? nil : c.artist,
            album: c.album,
            artworkUrl: artwork,
            startedAt: started.map(FeedTime.format),
            durationSec: duration.map { Int($0.rounded(.toNearestOrEven)) },
            endsAt: ends.map(FeedTime.format))
        var status = NowPlayingRecord.Status.playing
        if let e = ends, now > e + 60 {
            status = now <= e + 900 ? .between : .stale
        } else if ends == nil, c.kind != .show, let s = started, now > s + 900 {
            status = .stale
        }
        if status == .playing {
            return NowPlayingRecord(stationId: stationId, status: .playing, item: item, show: show, provenance: prov, pollAfterSec: 10)
        }
        prov.suppressed = status == .between ? .ended : .stale
        return NowPlayingRecord(stationId: stationId, status: status, item: nil, show: show, provenance: prov,
                                pollAfterSec: status == .between ? 10 : 30)
    }
}
