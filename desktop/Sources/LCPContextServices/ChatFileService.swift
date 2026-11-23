import Foundation
import UniformTypeIdentifiers
import LCPContextCore

/// A selected file stays in memory until the chat turn is saved.
public struct ChatUpload: Equatable, Identifiable, Sendable {
    public var id: UUID { attachment.id }
    public let attachment: ChatAttachment
    let bytes: Data
    let extraction: Data?
    let plainText: String?

    public var contentDescription: String {
        if ChatFileInput.nativePart(for: attachment) != nil { return "The attached file will be sent to your provider." }
        return plainText == nil ? "Available for filing. Only the filename is sent for this format." : "The file’s extracted text will be sent to your provider."
    }

    public static func read(_ url: URL, remainingBytes: Int = ChatAttachment.maximumBytes) throws -> Self {
        let name = url.lastPathComponent
        guard ChatAttachment.validFilename(name), remainingBytes >= 0 else { throw ContextServiceError.invalidFile }
        let bytes = try MaterialService.boundedRead(url, maximumBytes: min(remainingBytes, ChatAttachment.maximumBytes))
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        var document: ExtractionDocument?
        if ["txt", "md", "markdown", "csv", "json", "rtf", "pdf"].contains(ext) || type?.conforms(to: .text) == true {
            document = try? MaterialService.extract(bytes, extension: ext)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let extraction = try document.map(encoder.encode)
        func reference(_ data: Data, _ mediaType: String) -> PayloadReference {
            .init(sha256: MaterialService.digest(data), byteCount: UInt64(data.count), mediaType: mediaType)
        }
        let file = ChatAttachment(filename: name, original: reference(bytes, mime),
                                  text: extraction.map { reference($0, "application/vnd.lcp.extracted+json") })
        return Self(attachment: file, bytes: bytes, extraction: extraction, plainText: document?.plainText)
    }

    @MainActor public func retain(in repository: ContextRepository) throws {
        guard try repository.storePayload(bytes, mediaType: attachment.original.mediaType) == attachment.original else {
            throw ContextRepositoryError.invalidPayload
        }
        if let extraction, let reference = attachment.text {
            guard try repository.storePayload(extraction, mediaType: reference.mediaType) == reference else {
                throw ContextRepositoryError.invalidPayload
            }
        }
    }
}

public enum ChatFilingTool {
    static let reply = "I reviewed the attached file for your class materials."
    public static let name = "propose_save_attachment"
    public static let guidance = "Suggest saving an attached syllabus, handout, reading, or other reusable source to its matching class. Use only supplied attachment and class IDs. Give a short title and reason. Leave one-off files in chat. The student can accept the suggestion in LCP."
    public static var schema: [String: Any] {
        let uuid = ["type": "string", "format": "uuid"]
        let fields: [String: Any] = ["attachment_id": uuid, "class_id": uuid,
            "title": ["type": "string", "minLength": 1, "maxLength": 512] as [String: Any],
            "reason": ["type": "string", "minLength": 1, "maxLength": 1024] as [String: Any]]
        return ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
    }

    public static func suggestion(arguments: Data) throws -> ChatFilingSuggestion {
        guard arguments.count <= 8192, let fields = try JSONSerialization.jsonObject(with: arguments) as? [String: String],
              Set(fields.keys) == ["attachment_id", "class_id", "title", "reason"],
              let id = fields["attachment_id"].flatMap(UUID.init(uuidString:)),
              let classID = fields["class_id"].flatMap(UUID.init(uuidString:)),
              let title = fields["title"], let reason = fields["reason"] else { throw ContextServiceError.invalidQuery }
        let result = ChatFilingSuggestion(attachmentID: id, classID: classID, title: title, reason: reason)
        guard result.isValid else { throw ContextServiceError.invalidQuery }
        return result
    }

    /// Call under the repository's write lock. The chat and the source message both constrain the destination.
    @discardableResult
    public static func suggest(_ suggestion: ChatFilingSuggestion, in thread: inout ChatThread) -> Bool {
        guard suggestion.isValid, thread.classID.map({ $0 == suggestion.classID }) ?? true else { return false }
        for i in thread.messages.indices where thread.messages[i].contextClassIDs.contains(suggestion.classID) {
            guard let j = thread.messages[i].attachments?.firstIndex(where: { $0.id == suggestion.attachmentID }),
                  thread.messages[i].attachments?[j].savedMaterialID == nil else { continue }
            thread.messages[i].attachments?[j].suggestion = suggestion
            return true
        }
        return false
    }

    @MainActor public static func file(_ id: UUID, from threadID: UUID, to classID: UUID,
                                       in repository: ContextRepository) throws {
        try repository.update { state in try file(id, from: threadID, to: classID, in: &state) }
    }

    public static func file(_ id: UUID, from threadID: UUID, to classID: UUID, in state: inout ContextState) throws {
        guard let t = state.chatThreads?.firstIndex(where: { $0.id == threadID }),
              let thread = state.chatThreads?[t], thread.classID.map({ $0 == classID }) ?? true,
              state.classes.contains(where: { $0.id == classID }),
              let m = thread.messages.firstIndex(where: { ($0.attachments ?? []).contains { $0.id == id } }),
              let files = thread.messages[m].attachments, let a = files.firstIndex(where: { $0.id == id }) else {
            throw ContextServiceError.outOfScope
        }
        let file = files[a]
        if file.savedMaterialID != nil { return }
        let title = file.suggestion.flatMap { $0.classID == classID ? $0.title : nil } ?? file.filename
        let classRevisions = Set(state.materials.lazy.filter { $0.classID == classID }.compactMap(\.currentRevisionID))
        let existing = state.materialRevisions.first { classRevisions.contains($0.id) && $0.original.sha256 == file.original.sha256 }
        let materialID: UUID
        if let existing { materialID = existing.materialID }
        else {
            var material = SourceMaterial(classID: classID, title: title, origin: "Chat attachment")
            let revision = MaterialRevision(materialID: material.id, original: file.original, text: file.text,
                extractorVersion: MaterialService.extractorVersion, extractionState: file.text == nil ? "unsupported" : "ready",
                originalFilename: file.filename)
            material.currentRevisionID = revision.id
            state.materials.append(material)
            state.materialRevisions.append(revision)
            materialID = material.id
        }
        state.chatThreads?[t].messages[m].attachments?[a].savedMaterialID = materialID
    }
}
