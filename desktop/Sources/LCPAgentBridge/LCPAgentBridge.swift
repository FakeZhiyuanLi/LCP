import Foundation
import Darwin
import LCPContextCore

@main
struct LCPAgentBridge {
    static func main() async {
        await MainActor.run { run() }
    }

    @MainActor
    private static func run() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("LCPAgentBridge --root /absolute/context/root --grant UUID\nLocal scoped MCP over stdio. No network listener. Create/revoke grants in LCP Desktop.")
            return
        }
        if arguments == ["--version"] { print("LCPAgentBridge 1.1.0"); return }
        guard arguments.count == 4, arguments[0] == "--root", arguments[2] == "--grant",
              arguments[1].hasPrefix("/"), let grant = UUID(uuidString: arguments[3]) else {
            FileHandle.standardError.write(Data("Usage: LCPAgentBridge --root /absolute/context/root --grant UUID\n".utf8))
            exit(64)
        }
        do {
            // Opening a mistaken path must not create a fresh empty class database.
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                throw BridgeFailure("Context root is unavailable.")
            }
            let rootInfo = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
            let store = root.appendingPathComponent("Library.store")
            let storeInfo = try store.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard rootInfo.isSymbolicLink != true, storeInfo.isRegularFile == true,
                  storeInfo.isSymbolicLink != true else { throw BridgeFailure("Context library is unavailable.") }
            let repository = try ContextRepository(rootURL: root)
            let server = BridgeServer(repository: repository, grantID: grant)
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                // POSIX read returns the available pipe bytes. Foundation's
                // read(upToCount:) may wait for its full length and deadlock a
                // request/response stdio client on a short JSON-RPC message.
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw BridgeFailure("Input is unavailable.")
                }
                pending.append(contentsOf: buffer.prefix(count))
                while let end = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    if line.isEmpty { continue }
                    guard line.count <= 1_048_576 else { throw BridgeFailure("Request limit exceeded.") }
                    let response: JSONValue?
                    do { response = server.handle(try JSONDecoder().decode(JSONValue.self, from: line)) }
                    catch {
                        response = .object(["jsonrpc":.string("2.0"),"id":.null,
                                            "error":.object(["code":.number(-32700),"message":.string("Invalid JSON.")])])
                    }
                    if let response {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                        var encoded = try encoder.encode(response)
                        encoded.append(0x0A)
                        FileHandle.standardOutput.write(encoded)
                    }
                }
                guard pending.count <= 1_048_576 else { throw BridgeFailure("Request limit exceeded.") }
            }
            // A final unterminated message is malformed, never executed.
        } catch {
            FileHandle.standardError.write(Data("LCP context connection stopped: unavailable root, grant, or invalid input.\n".utf8))
            exit(1)
        }
    }
}
