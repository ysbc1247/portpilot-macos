import XCTest
@testable import DevBerth

final class SecurityAndLoggingTests: XCTestCase {
    func testShellEscapingTreatsEachArgumentAsData() {
        let command = ShellEscaper.command(executable: "npm", arguments: ["run", "dev; rm -rf /", "it's-safe"])
        XCTAssertEqual(command, "'npm' 'run' 'dev; rm -rf /' 'it'\"'\"'s-safe'")
    }

    func testSecretReferencesEncodeWithoutSecretValues() throws {
        let reference = UUID()
        let profile = ManagedServiceConfiguration(
            name: "API", command: "api", workingDirectory: "/tmp",
            environment: ["MODE": "development"],
            secretReferences: ["API_TOKEN": reference]
        )
        let encoded = try JSONEncoder().encode(profile)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(reference.uuidString))
        XCTAssertTrue(text.contains("API_TOKEN"))
        XCTAssertFalse(text.contains("actual-secret-value"))
    }

    func testLogBufferRedactsSecretsAndBoundsGrowth() async {
        let profileID = UUID()
        let buffer = ServiceLogBuffer(maximumEntries: 100, persistsToDisk: false)
        await buffer.setSecrets(["top-secret"], for: profileID)
        for index in 0..<140 {
            await buffer.append(profileID: profileID, stream: .standardOutput, data: Data("line \(index) top-secret\n".utf8))
        }
        let entries = await buffer.entries(for: profileID)
        XCTAssertEqual(entries.count, 100)
        XCTAssertFalse(entries.contains { $0.message.contains("top-secret") })
        XCTAssertTrue(entries.allSatisfy { $0.message.contains("••••") })
    }

    func testLogBufferRedactsSecretSplitAcrossArbitraryChunks() async {
        let profileID = UUID()
        let buffer = ServiceLogBuffer(maximumEntries: 100, persistsToDisk: false)
        await buffer.setSecrets(["top-secret"], for: profileID)

        await buffer.append(profileID: profileID, stream: .standardOutput, data: Data("value=top-".utf8))
        await buffer.append(profileID: profileID, stream: .standardOutput, data: Data("secret\nready\n".utf8))

        let entries = await buffer.entries(for: profileID)
        XCTAssertEqual(entries.map(\.message), ["value=••••", "ready"])
        XCTAssertFalse(entries.contains { $0.message.contains("top-secret") })
    }
}
