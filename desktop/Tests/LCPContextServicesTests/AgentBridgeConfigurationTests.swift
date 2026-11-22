import XCTest
import Foundation
@testable import LCPContextServices

final class AgentBridgeConfigurationTests: XCTestCase {
    func testEncodesScopedCredentialFreeStdioConfiguration() throws {
        let grantID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let configuration = try AgentBridgeConfiguration(serverName: "Claude Duet / LCP",
                                                         command: "/Applications/LCP Desktop.app/Contents/Helpers/LCPAgentBridge",
                                                         root: "/Users/student/Library/Application Support/LCP Desktop",
                                                         grantID: grantID)
        let value = try JSONDecoder().decode(AgentBridgeConfiguration.self, from: configuration.encoded())
        let server = try XCTUnwrap(value.mcpServers["Claude Duet / LCP"])
        XCTAssertEqual(server.command, "/Applications/LCP Desktop.app/Contents/Helpers/LCPAgentBridge")
        XCTAssertEqual(server.args, ["--root", "/Users/student/Library/Application Support/LCP Desktop", "--grant", grantID.uuidString])
    }

    func testRejectsNonAbsolutePathsAndOversizedNames() {
        XCTAssertThrowsError(try AgentBridgeConfiguration(serverName: "LCP", command: "bridge", root: "/tmp/library", grantID: UUID()))
        XCTAssertThrowsError(try AgentBridgeConfiguration(serverName: "LCP", command: "/tmp/bridge", root: "library", grantID: UUID()))
        XCTAssertThrowsError(try AgentBridgeConfiguration(serverName: String(repeating: "x", count: 129), command: "/tmp/bridge", root: "/tmp/library", grantID: UUID()))
    }
}
