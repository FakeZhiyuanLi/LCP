import Foundation
import Darwin

/// Bounded local metadata only. No query, excerpt, answer, source text, path or
/// caller-controlled request identifier is recorded or exported in backups.
struct BridgeAudit {
    struct Event: Codable {
        var at: Date
        var grant: UUID
        var tool: String
        var outcome: String
    }
    static func record(root: URL, grant: UUID, tool: String, outcome: String) throws {
        let known = ["list_classes", "list_materials", "search_class_context", "get_source_passage", "resolve_citation", "build_context_bundle", "propose_note", "propose_study_log", "resources/list", "resources/read"]
        let lock = root.appendingPathComponent(".agent-audit.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BridgeFailure("The local access audit is unavailable.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw BridgeFailure("The local access audit is unavailable.") }
        let file = root.appendingPathComponent("agent-access.json")
        var events: [Event] = []
        if FileManager.default.fileExists(atPath: file.path) {
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true,
                  (info.fileSize ?? Int.max) <= 524_288 else { throw BridgeFailure("The local access audit is invalid.") }
            events = try JSONDecoder().decode([Event].self, from: Data(contentsOf: file))
        }
        events.append(Event(at: Date(), grant: grant, tool: known.contains(tool) ? tool : "unknown", outcome: outcome))
        // Keep the latest 2,048 access facts. This is operational retention,
        // separate from permanent reviewed class/activity history.
        events = Array(events.suffix(2_048))
        let data = try JSONEncoder().encode(events)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
