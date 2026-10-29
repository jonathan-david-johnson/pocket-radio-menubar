import Foundation

/// What every surface shows for a station. Mirrors `contracts/now_playing_feed/schema.json`.
public struct NowPlayingRecord: Codable, Equatable {
    public enum Status: String, Codable { case playing, between, stale, unsupported, unavailable }
    public enum ItemKind: String, Codable { case song, show }
    public enum Channel: String, Codable { case api, icy, hlsID3 = "hls-id3" }
    public enum Timing: String, Codable { case stamped, observed, none }
    public enum Suppressed: String, Codable { case ad, stationId = "station_id", placeholder, unknown, ended, stale }

    public struct Item: Codable, Equatable {
        public var kind: ItemKind
        public var title: String
        public var artist: String?
        public var album: String?
        public var artworkUrl: String?
        public var startedAt: String?
        public var durationSec: Int?
        public var endsAt: String?

        public init(kind: ItemKind, title: String, artist: String?, album: String?, artworkUrl: String?,
                    startedAt: String?, durationSec: Int?, endsAt: String?) {
            self.kind = kind; self.title = title; self.artist = artist; self.album = album
            self.artworkUrl = artworkUrl; self.startedAt = startedAt; self.durationSec = durationSec; self.endsAt = endsAt
        }

        // The contract writes every field, using null for a missing value.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(artist, forKey: .artist)
            try c.encode(album, forKey: .album)
            try c.encode(artworkUrl, forKey: .artworkUrl)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(durationSec, forKey: .durationSec)
            try c.encode(endsAt, forKey: .endsAt)
        }
    }

    public struct Show: Codable, Equatable {
        public var title: String
        public init(title: String) { self.title = title }
    }

    public struct Provenance: Codable, Equatable {
        public var adapter: String?
        public var channel: Channel
        public var observedAt: String
        public var timing: Timing
        public var suppressed: Suppressed?

        public init(adapter: String?, channel: Channel, observedAt: String, timing: Timing, suppressed: Suppressed? = nil) {
            self.adapter = adapter; self.channel = channel; self.observedAt = observedAt
            self.timing = timing; self.suppressed = suppressed
        }
    }

    public var stationId: String
    public var status: Status
    public var item: Item?
    public var show: Show?
    public var provenance: Provenance
    public var pollAfterSec: Int

    public init(stationId: String, status: Status, item: Item?, show: Show?, provenance: Provenance, pollAfterSec: Int) {
        self.stationId = stationId; self.status = status; self.item = item; self.show = show
        self.provenance = provenance; self.pollAfterSec = pollAfterSec
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stationId, forKey: .stationId)
        try c.encode(status, forKey: .status)
        try c.encode(item, forKey: .item)
        try c.encode(show, forKey: .show)
        try c.encode(provenance, forKey: .provenance)
        try c.encode(pollAfterSec, forKey: .pollAfterSec)
    }
}

/// What an adapter reads out of one response, before the shared rules run.
public struct Candidate: Equatable {
    public enum Kind: String { case song, show, ad, stationId = "station_id", placeholder, unknown }
    public var kind: Kind
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artwork: String?
    public var startedAt: Double?   // epoch seconds, UTC
    public var duration: Double?    // seconds
    public var show: String?
    /// The source gave one `Artist - Title` string.
    public var combined: Bool

    public init(kind: Kind? = nil, title: String?, artist: String? = nil, album: String? = nil, artwork: String? = nil,
                startedAt: Double? = nil, duration: Double? = nil, show: String? = nil, combined: Bool = false) {
        let t = Text.clean(title), a = Text.clean(artist)
        self.title = t; self.artist = a
        self.album = Text.nonEmpty(album)
        self.artwork = Text.nonEmpty(artwork)
        self.startedAt = startedAt; self.duration = duration; self.show = show; self.combined = combined
        self.kind = kind ?? Rules.classify(title: t, artist: a)
    }
}
