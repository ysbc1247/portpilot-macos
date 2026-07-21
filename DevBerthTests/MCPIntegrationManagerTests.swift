import XCTest
@testable import DevBerth

final class MCPIntegrationManagerTests: XCTestCase {
    func testCodexEditorPreservesUnrelatedTablesAndBecomesIdempotent() throws {
        let existing = """
        model = "gpt-5"

        [mcp_servers.other]
        command = "/usr/bin/other"

        [mcp_servers.devberth]
        command = "/old/helper"
        args = ["serve", "--stdio"]

        [features]
        multi_agent = true
        """
        let replacement = """
        [mcp_servers.devberth]
        command = "/Users/test/Library/Application Support/DevBerth/bin/devberth-mcp"
        args = ["serve", "--stdio"]
        startup_timeout_sec = 10
        tool_timeout_sec = 120
        """

        let updated = try CodexTOMLEditor.replacingDevBerthSection(in: existing, with: replacement)

        XCTAssertTrue(updated.contains(#"[mcp_servers.other]"#))
        XCTAssertTrue(updated.contains(#"[features]"#))
        XCTAssertFalse(updated.contains(#"/old/helper"#))
        XCTAssertEqual(try CodexTOMLEditor.devBerthSection(in: updated), replacement)
        XCTAssertEqual(try CodexTOMLEditor.replacingDevBerthSection(in: updated, with: replacement), updated)
    }

    func testCodexEditorRejectsDuplicateDevBerthTables() {
        let duplicate = """
        [mcp_servers.devberth]
        command = "/first"

        [mcp_servers.devberth]
        command = "/second"
        """

        XCTAssertThrowsError(try CodexTOMLEditor.replacingDevBerthSection(
            in: duplicate,
            with: "[mcp_servers.devberth]\ncommand = \"/replacement\""
        ))
    }
}
