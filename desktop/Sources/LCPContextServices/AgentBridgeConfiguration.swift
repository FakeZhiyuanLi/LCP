import Foundation

/// A credential-free configuration snippet for a local LCP stdio bridge.
///
/// The same shape is accepted by common MCP clients that expose an
/// `mcpServers` configuration. The grant UUID keeps the client's access bound
/// to one persisted scope, while the bridge executable and repository paths
/// remain local to this Mac.
public struct AgentBridgeConfiguration: Codable, Equatable, Sendable {
    public struct Server: Codable, Equatable, Sendable {
        public let command: String
        public let args: [String]

        public init(command: String, args: [String]) {
            self.command = command
            self.args = args
        }
    }

    public let mcpServers: [String: Server]

    public init(serverName: String, command: String, root: String, grantID: UUID) throws {
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128,
              !executable.isEmpty, executable.utf8.count <= 4_096,
              !repository.isEmpty, repository.utf8.count <= 4_096,
              executable.hasPrefix("/"), repository.hasPrefix("/") else {
            throw AgentBridgeConfigurationError.invalid
        }
        let server = Server(command: executable,
                            args: ["--root", repository, "--grant", grantID.uuidString])
        self.mcpServers = [name: server]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum AgentBridgeConfigurationError: LocalizedError, Equatable, Sendable {
    case invalid

    public var errorDescription: String? {
        "The local MCP configuration needs a non-empty absolute executable and library path."
    }
}
