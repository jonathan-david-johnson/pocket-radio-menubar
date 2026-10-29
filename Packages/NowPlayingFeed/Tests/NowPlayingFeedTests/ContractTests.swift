import XCTest
@testable import NowPlayingFeed

/// Runs the shell's golden fixtures: `contracts/now_playing_feed/`.
/// This worktree is a sibling of the shell checkout's other repos, so the contract is at `../contracts`.
final class ContractTests: XCTestCase {
    static let contractDir: URL = {
        // <worktree>/Packages/NowPlayingFeed/Tests/NowPlayingFeedTests/ContractTests.swift
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.deletingLastPathComponent().appendingPathComponent("contracts/now_playing_feed")
    }()

    struct Case {
        let id: String, adapter: String, params: [String: Any], now: Double, raw: [String: String]
        let expected: NowPlayingRecord
    }

    static func loadCases() throws -> [Case] {
        let dir = contractDir.appendingPathComponent("cases")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { f in
            let o = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
            let exp = try JSONSerialization.data(withJSONObject: o["expected"]!)
            return Case(id: o["id"] as! String, adapter: o["adapter"] as! String, params: o["params"] as? [String: Any] ?? [:],
                        now: (o["now"] as! NSNumber).doubleValue, raw: o["raw"] as! [String: String],
                        expected: try JSONDecoder().decode(NowPlayingRecord.self, from: exp))
        }
    }

    private func run(_ adapters: Set<String>, file: StaticString = #filePath, line: UInt = #line) throws {
        let cases = try Self.loadCases().filter { adapters.contains($0.adapter) }
        XCTAssertFalse(cases.isEmpty, "no cases for \(adapters)", file: file, line: line)
        for c in cases {
            // The contract serves one raw body per case; adapters with several URLs would need a selector.
            let body = c.raw.values.first ?? ""
            do {
                let got = try NowPlayingFeed.record(adapter: c.adapter, body: body, params: c.params, now: c.now, stationId: c.expected.stationId)
                XCTAssertEqual(got, c.expected, "case \(c.id)", file: file, line: line)
            } catch {
                XCTFail("case \(c.id) threw \(error)", file: file, line: line)
            }
        }
    }

    func testAllFixtureFilesAreCoveredByAKnownAdapter() throws {
        let cases = try Self.loadCases()
        XCTAssertEqual(cases.count, 41)
        for c in cases { XCTAssertTrue(Adapters.names.contains(c.adapter), "\(c.id): adapter \(c.adapter) not ported") }
    }

    func testStationAPIs() throws { try run(["kexp", "kcrw"]) }
    func testHostingPlatforms() throws { try run(["azuracast", "laut", "radioco", "triton", "live365", "radiojar", "iheart", "radioking", "airtime", "zeno"]) }
    func testBroadcasterNetworks() throws { try run(["sr", "abc", "radiofrance", "npo", "npr_composer"]) }
    func testServerStatusPages() throws { try run(["icecast", "shoutcast"]) }
    func testInBandICY() throws { try run(["icy"]) }

    // Behavior 3: every expected record is valid under the schema's enums, and artwork is https.
    func testExpectedRecordsFollowTheSchema() throws {
        for c in try Self.loadCases() {
            let e = c.expected
            if let a = e.item?.artworkUrl { XCTAssertTrue(a.hasPrefix("https://"), "\(c.id): artwork not https") }
            if e.item == nil { XCTAssertNotNil(e.provenance.suppressed ?? (e.status == .between ? .unknown : nil), "\(c.id)") }
            if e.item != nil { XCTAssertNil(e.provenance.suppressed, "\(c.id): suppressed with an item") }
            XCTAssertEqual(e.provenance.observedAt, FeedTime.format(c.now), c.id)
            XCTAssertGreaterThanOrEqual(e.pollAfterSec, 1)
        }
    }

    // Behavior 2.
    func testJunkFilter() throws {
        let data = try Data(contentsOf: Self.contractDir.appendingPathComponent("junk_filter.json"))
        let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cases = o["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 28)
        for c in cases {
            let got = Rules.classify(title: c["title"] as? String, artist: c["artist"] as? String)
            XCTAssertEqual(got.rawValue, c["expected_kind"] as? String, "\(c["title"] ?? "") / \(c["artist"] ?? "")")
        }
    }
}
