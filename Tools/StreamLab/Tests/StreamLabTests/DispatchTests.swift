import XCTest
import StreamDiagnostics
@testable import StreamLab

/// Command-line dispatch only. These tests never open a stream, contact a feed,
/// or construct a `CaptureSession`; parsing is separated from running for that reason.
final class DispatchTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> LabCommand {
        try LabDispatch.parse(arguments)
    }

    private func captureOptions(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws -> CaptureOptions {
        guard case .capture(let options) = try parse(arguments) else {
            XCTFail("Expected a capture command", file: file, line: line)
            throw UsageError("not a capture command")
        }
        return options
    }

    func testNoArgumentsIsAUsageError() {
        XCTAssertThrowsError(try parse([])) { XCTAssertTrue($0 is UsageError, "Expected UsageError, got \($0)") }
    }

    func testUnknownCommandIsAUsageError() {
        XCTAssertThrowsError(try parse(["observe", "--station", "kcrw"])) { XCTAssertTrue($0 is UsageError) }
    }

    func testHelpIsNotAnError() throws {
        for argument in ["--help", "-h", "help"] {
            guard case .help = try parse([argument]) else { return XCTFail("Expected help for \(argument)") }
        }
    }

    func testUsageNamesCommandsAndRequiredOptions() {
        let usage = LabDispatch.usage
        for expected in ["capture", "replay", "select", "compare", "--annotations", "--station", "--stream-url", "--output"] {
            XCTAssertTrue(usage.contains(expected), "Usage should mention \(expected)")
        }
    }

    func testCaptureParsesRequiredAndDefaultedOptions() throws {
        let options = try captureOptions(["capture", "--station", "kcrw",
                                          "--stream-url", "https://example.invalid/explicit-stream",
                                          "--output", "/tmp/does-not-exist-yet.jsonl"])
        XCTAssertEqual(options.station, .kcrw)
        XCTAssertEqual(options.streamURL.absoluteString, "https://example.invalid/explicit-stream")
        XCTAssertEqual(options.outputURL.path, "/tmp/does-not-exist-yet.jsonl")
        XCTAssertEqual(options.duration, 300)
        XCTAssertEqual(options.feedInterval, 30)
        XCTAssertFalse(options.muted)
        XCTAssertEqual(options.feedURL, LabStation.kcrw.feedURL, "Feed should default to the station endpoint")
    }

    func testCaptureParsesExplicitOptionsAndFlags() throws {
        let options = try captureOptions(["capture", "--station", "kexp",
                                          "--stream-url", "file:///tmp/fixture.mp3",
                                          "--output", "/tmp/fixture-trace.jsonl",
                                          "--duration", "45", "--feed-interval", "10", "--no-feed", "--muted"])
        XCTAssertEqual(options.station, .kexp)
        XCTAssertEqual(options.duration, 45)
        XCTAssertEqual(options.feedInterval, 10)
        XCTAssertTrue(options.muted)
        XCTAssertNil(options.feedURL, "--no-feed must disable feed polling")
    }

    func testCaptureRejectsMissingAndInvalidOptions() {
        let cases: [[String]] = [
            ["capture"],
            ["capture", "--station", "kcrw", "--output", "/tmp/a.jsonl"],
            ["capture", "--station", "wxyz", "--stream-url", "https://example.invalid/s", "--output", "/tmp/a.jsonl"],
            ["capture", "--station", "kcrw", "--stream-url", "not-a-url", "--output", "/tmp/a.jsonl"],
            ["capture", "--station", "kcrw", "--stream-url", "https://example.invalid/s", "--output", "/tmp/a.jsonl", "--duration", "0"],
            ["capture", "--station", "kcrw", "--stream-url", "https://example.invalid/s", "--output", "/tmp/a.jsonl", "--feed-interval", "1"],
            ["capture", "--station", "kcrw", "--stream-url", "https://example.invalid/s", "--output", "/tmp/a.jsonl",
             "--no-feed", "--feed-url", "https://example.invalid/feed"],
            ["capture", "--station", "kcrw", "--stream-url", "https://example.invalid/s", "--output", "/tmp/a.jsonl", "--unknown", "x"],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try parse(arguments), "Expected \(arguments) to be rejected") {
                XCTAssertTrue($0 is UsageError, "Expected UsageError for \(arguments), got \($0)")
            }
        }
    }

    func testReplayParsesExactlyOneTracePath() throws {
        guard case .replay(let url) = try parse(["replay", "/tmp/trace.jsonl"]) else {
            return XCTFail("Expected a replay command")
        }
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/tmp/trace.jsonl")
    }

    func testReplayRejectsMissingEmptyOrExtraPaths() {
        for arguments in [["replay"], ["replay", ""], ["replay", "/tmp/a.jsonl", "/tmp/b.jsonl"]] {
            XCTAssertThrowsError(try parse(arguments), "Expected \(arguments) to be rejected") {
                XCTAssertTrue($0 is UsageError, "Expected UsageError for \(arguments), got \($0)")
            }
        }
    }

    func testSelectParsesTraceAnnotationsAndOffset() throws {
        guard case .select(let options) = try parse(["select", "/tmp/trace.jsonl",
                                                     "--annotations", "/tmp/annotations.json",
                                                     "--offset", "159.75"]) else {
            return XCTFail("Expected select command")
        }
        XCTAssertEqual(options.traceURL.path, "/tmp/trace.jsonl")
        XCTAssertEqual(options.annotationsURL.path, "/tmp/annotations.json")
        XCTAssertEqual(options.offsetSeconds, 159.75)
    }

    func testSelectDefaultsOffsetAndRejectsInvalidArguments() throws {
        guard case .select(let options) = try parse(["select", "/tmp/trace.jsonl",
                                                     "--annotations", "/tmp/annotations.json"]) else {
            return XCTFail("Expected select command")
        }
        XCTAssertEqual(options.offsetSeconds, 160)

        let invalid: [[String]] = [
            ["select"],
            ["select", "/tmp/trace.jsonl"],
            ["select", "/tmp/trace.jsonl", "--annotations"],
            ["select", "/tmp/trace.jsonl", "--annotations", "/tmp/a.json", "--offset", "nan"],
            ["select", "/tmp/trace.jsonl", "--annotations", "/tmp/a.json", "--offset", "9999"],
            ["select", "/tmp/trace.jsonl", "--annotations", "/tmp/a.json", "--unknown", "x"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try parse(arguments), "Expected \(arguments) to be rejected") {
                XCTAssertTrue($0 is UsageError, "Expected UsageError for \(arguments), got \($0)")
            }
        }
    }

    func testCompareParsesTwoOrMorePairsAndFinalOffset() throws {
        guard case .compare(let options) = try parse([
            "compare", "/tmp/s1.jsonl", "/tmp/s1.json", "/tmp/s2.jsonl", "/tmp/s2.json",
            "--offset", "160.5",
        ]) else { return XCTFail("Expected compare command") }
        XCTAssertEqual(options.pairs.count, 2)
        XCTAssertEqual(options.pairs[1].traceURL.path, "/tmp/s2.jsonl")
        XCTAssertEqual(options.offsetSeconds, 160.5)

        for arguments in [
            ["compare"],
            ["compare", "/tmp/s1", "/tmp/a1"],
            ["compare", "/tmp/s1", "/tmp/a1", "/tmp/s2"],
            ["compare", "/tmp/s1", "/tmp/a1", "/tmp/s2", "/tmp/a2", "--offset"],
        ] {
            XCTAssertThrowsError(try parse(arguments)) { XCTAssertTrue($0 is UsageError) }
        }
    }
}

/// Operator-facing failure text. A trace path can be a local path the operator typed,
/// so failures stay one short line and never dump a bridged error dictionary.
final class FailureTextTests: XCTestCase {
    func testTraceFailuresReportTheTraceReason() {
        let text = LabFailure.describe(TraceError.invalid("missing final newline; possibly truncated"))
        XCTAssertTrue(text.contains("missing final newline"), text)
        XCTAssertFalse(text.contains("TraceError"), "Operators should not see a type name: \(text)")
    }

    func testUsageFailuresReportTheUsageReason() {
        XCTAssertEqual(LabFailure.describe(UsageError("No command given")), "No command given")
    }

    func testFileFailuresAreOneReadableLine() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stream-lab-absent-\(UUID().uuidString).jsonl")
        var captured: Error?
        XCTAssertThrowsError(try TraceReader.read(url: missing)) { captured = $0 }
        let text = try XCTUnwrap(captured.map(LabFailure.describe))
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("\n"), "Failure text must stay on one line: \(text)")
        XCTAssertFalse(text.contains("UserInfo="), "Failure text must not dump the bridged error: \(text)")
    }
}
