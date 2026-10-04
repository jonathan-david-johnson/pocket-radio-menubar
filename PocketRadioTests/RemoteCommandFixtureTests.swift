import XCTest
@testable import PocketRadio

final class RemoteCommandFixtureTests: XCTestCase {

    private static let knownVerbs: Set<String> = ["play", "pause", "stop", "load_station"]
    private static let knownStates: Set<String> = ["playing", "paused", "idle"]

    // MARK: - Command fixtures

    func testCommandPlay() throws {
        try assertCommandFixture("command_play")
    }

    func testCommandPause() throws {
        try assertCommandFixture("command_pause")
    }

    func testCommandStop() throws {
        try assertCommandFixture("command_stop")
    }

    func testCommandLoadStation() throws {
        let cmd = try loadCommand("command_load_station")
        XCTAssertEqual(cmd.command, .loadStation)
        let payload = try XCTUnwrap(cmd.payload)
        XCTAssertEqual(payload.stationId, "kcrw")
        XCTAssertEqual(payload.stationName, "KCRW")
        XCTAssertFalse((payload.stationUrl ?? "").isEmpty)
        try assertCommandRoundTrip("command_load_station")
    }

    // MARK: - Presence fixtures

    func testPresenceIOS() throws {
        try assertPresenceFixture("presence_ios", expectedRole: "sender", expectedDeviceType: "ios")
    }

    func testPresenceMacOS() throws {
        try assertPresenceFixture("presence_macos", expectedRole: "receiver", expectedDeviceType: "macos")
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        // XCTest hosts must not open protected Documents paths at runtime.
        // Xcode copies the unchanged shared contracts into this test bundle.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func loadCommand(_ name: String) throws -> RemoteCommand {
        let data = try fixtureData(name)
        return try JSONDecoder().decode(RemoteCommand.self, from: data)
    }

    private func assertCommandFixture(_ name: String) throws {
        let cmd = try loadCommand(name)
        XCTAssertFalse(cmd.commandId.isEmpty)
        XCTAssertFalse(cmd.fromDeviceId.isEmpty)
        XCTAssertFalse(cmd.targetDeviceId.isEmpty)
        XCTAssertFalse(cmd.sentAt.isEmpty)
        XCTAssertTrue(Self.knownVerbs.contains(cmd.command.rawValue), "Unknown verb: \(cmd.command.rawValue)")
        try assertCommandRoundTrip(name)
    }

    private func assertCommandRoundTrip(_ name: String) throws {
        let original = try fixtureData(name)
        let cmd = try JSONDecoder().decode(RemoteCommand.self, from: original)
        let reencoded = try JSONEncoder().encode(cmd)
        let originalDict = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let reencodedDict = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? NSDictionary)
        XCTAssertEqual(originalDict, reencodedDict, "Key mismatch for \(name)")
    }

    private func assertPresenceFixture(_ name: String, expectedRole: String, expectedDeviceType: String) throws {
        let data = try fixtureData(name)
        let presence = try JSONDecoder().decode(RemotePresence.self, from: data)
        XCTAssertFalse(presence.deviceId.isEmpty)
        XCTAssertEqual(presence.deviceType, expectedDeviceType)
        XCTAssertEqual(presence.role, expectedRole)
        XCTAssertTrue(Self.knownStates.contains(presence.playback.state.rawValue),
                      "Unknown state: \(presence.playback.state.rawValue)")
        let reencoded = try JSONEncoder().encode(presence)
        let originalDict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let reencodedDict = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? NSDictionary)
        XCTAssertEqual(originalDict, reencodedDict, "Key mismatch for \(name)")
    }
}
