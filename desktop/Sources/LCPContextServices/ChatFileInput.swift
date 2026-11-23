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

    func parts(includeOriginal: Bool = true) throws -> [[String: Any]] {
        var metadata: [String: String] = ["attachment_id": file.id.uuidString, "filename": file.filename,
            "turn": isCurrent ? "current upload" : "earlier upload", "filing": file.savedMaterialID == nil ? "in chat" : "already in class materials"]
        metadata["allowed_class_ids"] = destinations.map { $0.uuidString }.sorted().joined(separator: ", ")
        if let text { metadata["extracted_text"] = text }
        else if bytes == nil || !includeOriginal {
            metadata["content_status"] = missingContent || !includeOriginal ? "Original content omitted from this request" : "Only the filename is available for this format"
        }
        let encoded = try JSONEncoder().encode(metadata)
        var result: [[String: Any]] = [["type": "input_text", "text": String(decoding: encoded, as: UTF8.self)]]
        if includeOriginal, let bytes, let kind = Self.nativePart(for: file) {
            let dataURL = "data:\(file.original.mediaType);base64," + bytes.base64EncodedString()
            if kind == "input_image" { result.append(["type": kind, "image_url": dataURL]) }
            else { result.append(["type": kind, "filename": file.filename, "file_data": dataURL]) }
        }
        return result
    }

    @MainActor static func prepare(uploads: [ChatUpload], history: [ChatMessage], classIDs: [UUID],
                                   message: String, terms: [String], included: [SourceCitation], repository: ContextRepository) throws -> [Self] {
        let service = MaterialService(repository: repository)
        let scope = Set(classIDs)
        let currentBudget = 16_384 / max(1, uploads.count)
        let current = uploads.map { upload in
            let text = upload.document.flatMap { excerpts($0, terms: terms, budget: currentBudget, overview: true) }
            let sendBytes = upload.document == nil && nativePart(for: upload.attachment) != nil
            return Self(file: upload.attachment, text: text, bytes: sendBytes ? upload.bytes : nil,
                        destinations: scope, isCurrent: true, missingContent: false)
        }
        var earlier: [Self] = []
        var remaining = 8_192
        let files = history.suffix(24).filter { Set($0.contextClassIDs).isSubset(of: scope) }.flatMap { message in
            (message.attachments ?? []).map { ($0, Set(message.contextClassIDs).intersection(classIDs)) }
        }.suffix(8)
        let nouns = ["file", "document", "textbook", "attachment", "scan", "image", "photo", "picture", "handout", "pdf"]
        let refersToFile = nouns.filter(terms.contains).contains { noun in
            ["this", "that", "the", "attached", "uploaded", "previous"].contains { message.localizedStandardContains($0 + " " + noun) }
        }
        let named = Set(files.compactMap { file, _ in message.localizedStandardContains(file.filename) ? file.id : nil })
        var nativeBudget = ChatAttachment.maximumBytes - uploads.reduce(0) { $0 + $1.bytes.count }
        for (file, destinations) in files.reversed() {
            if included.contains(where: { $0.sourceID == file.savedMaterialID && $0.payloadSHA256 == file.text?.sha256 }) { continue }
            let referenced = named.contains(file.id) || (named.isEmpty && uploads.isEmpty && refersToFile && file.id == files.last?.0.id)
            var text: String?
            var bytes: Data?
            if let reference = file.text, remaining >= 256, let document = try? service.extractedDocument(from: reference) {
                text = excerpts(document, terms: terms, budget: min(4_096, remaining), overview: referenced)
                remaining -= text?.utf8.count ?? 0
            } else if named.contains(file.id), file.text == nil, nativePart(for: file) != nil, file.original.byteCount <= nativeBudget {
                bytes = try? repository.payloadData(file.original)
                nativeBudget -= bytes?.count ?? 0
            }
            guard text != nil || bytes != nil || referenced else { continue }
            earlier.append(Self(file: file, text: text, bytes: bytes, destinations: destinations, isCurrent: false, missingContent: text == nil && bytes == nil))
        }
        return earlier.reversed() + current
    }

    /// Anchors excerpts at matching words, even when the answer is near the end of a large page.
    @MainActor private static func excerpts(_ document: ExtractionDocument, terms: [String], budget: Int, overview: Bool) -> String? {
        if document.plainText.utf8.count <= budget {
            return overview || !ChatEvidence.matches(terms, in: document.plainText).isEmpty ? document.plainText : nil
        }
        let matches = document.passages.indices.compactMap { index -> (Int, [String])? in
            let words = ChatEvidence.matches(terms, in: document.passages[index].text)
            return words.isEmpty ? nil : (index, words)
        }.sorted { $0.1.count == $1.1.count ? $0.0 < $1.0 : $0.1.count > $1.1.count }
        var candidates = matches
        if candidates.isEmpty, overview {
            let count = min(document.passages.count, max(1, budget / 2_048))
            candidates = (0..<count).map { ($0 * (document.passages.count - 1) / max(1, count - 1), []) }
        }
        var text = ""
        for (index, words) in candidates {
            let passage = document.passages[index]
            let label: String
            if case .page(let page) = passage.locator { label = "[Page \(page)]\n" } else { label = "" }
            let separator = text.isEmpty ? "" : "\n…\n"
            let available = budget - text.utf8.count - label.utf8.count - separator.utf8.count
            guard available >= 128 else { break }
            text += separator + label + RetrievalService.excerpt(passage.text, queryTokens: words, limit: min(2_048, available))
        }
        return text.isEmpty ? nil : text
    }
}
