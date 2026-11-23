import Foundation
import LCPContextCore

/// Only user-selected bytes or files retained in this conversation enter a provider request.
public struct ChatFileInput: Sendable {
    let file: ChatAttachment
    let text: String?
    let bytes: Data?
    let destinations: Set<UUID>
    let isCurrent: Bool
    let missingContent: Bool

    static func nativePart(for file: ChatAttachment) -> String? {
        let type = file.original.mediaType
        if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(type) { return "input_image" }
        if ["pdf", "docx", "pptx", "xlsx"].contains((file.filename as NSString).pathExtension.lowercased()) { return "input_file" }
        return nil
    }

    func parts() throws -> [[String: Any]] {
        var metadata: [String: String] = ["attachment_id": file.id.uuidString, "filename": file.filename,
            "turn": isCurrent ? "current upload" : "earlier upload", "filing": file.savedMaterialID == nil ? "in chat" : "already in class materials"]
        metadata["allowed_class_ids"] = destinations.map { $0.uuidString }.sorted().joined(separator: ", ")
        if let text { metadata["extracted_text"] = text }
        else if bytes == nil {
            metadata["content_status"] = missingContent ? "Earlier content omitted from this request" : "Only the filename is available for this format"
        }
        let encoded = try JSONEncoder().encode(metadata)
        var result: [[String: Any]] = [["type": "input_text", "text": String(decoding: encoded, as: UTF8.self)]]
        if let bytes, let kind = Self.nativePart(for: file) {
            let dataURL = "data:\(file.original.mediaType);base64," + bytes.base64EncodedString()
            if kind == "input_image" { result.append(["type": kind, "image_url": dataURL]) }
            else { result.append(["type": kind, "filename": file.filename, "file_data": dataURL]) }
        }
        return result
    }

    @MainActor static func prepare(uploads: [ChatUpload], history: [ChatMessage], classIDs: [UUID], repository: ContextRepository) throws -> [Self] {
        var earlier: [Self] = []
        var remaining = 4 * 1024 * 1024
        let service = MaterialService(repository: repository)
        let scope = Set(classIDs)
        let files = history.suffix(24).filter { Set($0.contextClassIDs).isSubset(of: scope) }.flatMap { message in
            (message.attachments ?? []).map { ($0, Set(message.contextClassIDs).intersection(classIDs)) }
        }.suffix(8)
        for (file, destinations) in files.reversed() {
            var text: String?
            var bytes: Data?
            if let reference = file.text, reference.byteCount <= remaining,
               let document = try? service.extractedDocument(from: reference) {
                text = document.plainText
                remaining -= text?.utf8.count ?? 0
            } else if nativePart(for: file) != nil, file.original.byteCount <= remaining {
                bytes = try? repository.payloadData(file.original)
                remaining -= bytes?.count ?? 0
            }
            earlier.append(Self(file: file, text: text, bytes: bytes, destinations: destinations, isCurrent: false, missingContent: text == nil && bytes == nil))
        }
        return earlier.reversed() + uploads.map { upload in
            let sendBytes = Self.nativePart(for: upload.attachment) != nil
            return Self(file: upload.attachment, text: upload.plainText,
                        bytes: sendBytes ? upload.bytes : nil, destinations: Set(classIDs), isCurrent: true, missingContent: false)
        }
    }
}
