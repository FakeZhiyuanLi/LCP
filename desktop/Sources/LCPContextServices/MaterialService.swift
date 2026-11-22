import Foundation
import PDFKit
import AppKit
import CoreServices
import CryptoKit
import LCPContextCore

/// Rebuildable extraction data; the original remains the authority and is retained separately.
public struct ExtractionDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var extractorVersion: String
    public var plainText: String
    public var passages: [ExtractedPassage]
    public var warning: String?
    public var importedSource: ImportedMaterialSource?

    public init(schemaVersion: Int = 1, extractorVersion: String = MaterialService.extractorVersion,
                plainText: String, passages: [ExtractedPassage], warning: String? = nil) {
        self.schemaVersion = schemaVersion
        self.extractorVersion = extractorVersion
        self.plainText = plainText
        self.passages = passages
        self.warning = warning
    }
}

public struct ExtractedPassage: Codable, Equatable, Sendable {
    public var locator: SourceLocator
    public var text: String
    public init(locator: SourceLocator, text: String) {
        self.locator = locator
        self.text = text
    }
}

public enum ContextServiceError: LocalizedError {
    case missingClass, missingSource, missingRevision, unavailablePayload, unsupportedExtraction
    case invalidCitation, outOfScope, revokedGrant, invalidQuery, invalidBundleDestination
    case invalidFile, fileTooLarge, extractionTooLarge, invalidText, invalidBundle
    case invalidWebURL, invalidWebTitle, wrongMaterialKind, changedWebLink

    public var errorDescription: String? {
        switch self {
        case .missingClass: return "The selected class no longer exists."
        case .missingSource: return "The source is unavailable."
        case .missingRevision: return "This exact source revision is unavailable."
        case .unavailablePayload: return "The source payload is missing or damaged. Relink its original file or restore a verified backup."
        case .unsupportedExtraction: return "This file is retained, but its format does not support text extraction."
        case .invalidCitation: return "The citation does not identify a valid passage in this revision."
        case .outOfScope: return "This request is outside the connection's approved class or material scope."
        case .revokedGrant: return "The connection's access grant has been revoked or is unavailable."
        case .invalidQuery: return "Choose explicit classes and valid search limits."
        case .invalidBundleDestination: return "Choose a new folder outside the app's managed storage for the context bundle."
        case .invalidFile: return "Choose a readable regular file."
        case .fileTooLarge: return "The file exceeds the 32 MiB material import limit."
        case .extractionTooLarge: return "The extracted text exceeds the 16 MiB limit. The original file is retained."
        case .invalidText: return "No readable text could be extracted. The original file is retained."
        case .invalidBundle: return "The context bundle failed integrity validation."
        case .invalidWebURL: return "Enter a complete http or https address with a host and without a username or password."
        case .invalidWebTitle: return "Enter a single-line title for this web link, up to 1,024 UTF-8 bytes."
        case .wrongMaterialKind: return "Use Edit Web Link for saved links and Add Revised File for imported files."
        case .changedWebLink: return "This link changed after you opened it. Reopen it to review the current address."
        }
    }
}

@MainActor
public final class MaterialService {
    public nonisolated static let webLinkKind = "web_link"
    public nonisolated static let extractorVersion = "lcp-extract-1"
    public nonisolated static let maximumOriginalBytes = 32 * 1_024 * 1_024
    public nonisolated static let maximumExtractedBytes = 16 * 1_024 * 1_024
    public let repository: ContextRepository

    public init(repository: ContextRepository) { self.repository = repository }

    public nonisolated static func validatedWebURL(_ urlString: String) throws -> URL {
        let address = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard address.utf8.count <= 8_192, address.rangeOfCharacter(from: forbidden) == nil,
              !address.contains("\\"), let parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              host.rangeOfCharacter(from: forbidden.union(CharacterSet(charactersIn: "/\\@?#"))) == nil,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = parts.url, url.absoluteString.utf8.count <= 8_192 else {
            throw ContextServiceError.invalidWebURL
        }
        return url
    }

    @discardableResult
    public func addWebLink(classID: UUID, title: String, urlString: String) throws -> SourceMaterial {
        let link = try prepareWebLink(title: title, urlString: urlString)
        var material = SourceMaterial(classID: classID, title: link.title, kind: Self.webLinkKind,
                                      origin: "Saved web link")
        let revision = webLinkRevision(materialID: material.id, sequence: 1, payload: link.payload)
        material.currentRevisionID = revision.id
        try repository.update { state in
            guard state.classes.contains(where: { $0.id == classID }) else { throw ContextServiceError.missingClass }
            state.materials.append(material)
            state.materialRevisions.append(revision)
        }
        return material
    }

    @discardableResult
    public func reviseWebLink(materialID: UUID, title: String, urlString: String,
                              expectedRevisionID: UUID? = nil) throws -> MaterialRevision {
        let link = try prepareWebLink(title: title, urlString: urlString)
        var result: MaterialRevision?
        try repository.update { state in
            guard let index = state.materials.firstIndex(where: { $0.id == materialID }),
                  let current = state.materialRevisions.first(where: { $0.id == state.materials[index].currentRevisionID }) else {
                throw ContextServiceError.missingSource
            }
            guard state.materials[index].kind == Self.webLinkKind else { throw ContextServiceError.wrongMaterialKind }
            guard expectedRevisionID == nil || expectedRevisionID == current.id else { throw ContextServiceError.changedWebLink }
            if current.original == link.payload {
                result = current
                return
            }
            let previousSequence = state.materialRevisions.filter { $0.materialID == materialID }.map(\.sequence).max() ?? 0
            guard previousSequence < UInt64.max else { throw ContextServiceError.changedWebLink }
            let revision = webLinkRevision(materialID: materialID, sequence: previousSequence + 1, payload: link.payload)
            state.materials[index].title = link.title
            state.materials[index].currentRevisionID = revision.id
            state.materialRevisions.append(revision)
            result = revision
        }
        guard let result else { throw ContextServiceError.missingRevision }
        return result
    }

    /// The Open Website action uses the revalidated address in this exact saved revision.
    public func webURL(for revision: MaterialRevision) throws -> URL? {
        guard repository.state.materials.contains(where: { $0.id == revision.materialID && $0.kind == Self.webLinkKind }) else { return nil }
        guard repository.state.materialRevisions.contains(revision), revision.original == revision.text,
              revision.original.byteCount <= 100_000 else { throw ContextServiceError.invalidWebURL }
        return try Self.webLink(in: extractedDocument(for: revision)).url
    }

    static func webLink(in document: ExtractionDocument) throws -> (title: String, url: URL) {
        let lines = document.plainText.components(separatedBy: "\n")
        guard lines.count == 3, lines[0] == "Saved web link", !lines[1].isEmpty else { throw ContextServiceError.invalidWebURL }
        return (lines[1], try Self.validatedWebURL(lines[2]))
    }

    private func prepareWebLink(title: String, urlString: String) throws -> (title: String, payload: PayloadReference) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1_024,
              name.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil else {
            throw ContextServiceError.invalidWebTitle
        }
        let address = try Self.validatedWebURL(urlString)
        let text = "Saved web link\n\(name)\n\(address.absoluteString)"
        let document = ExtractionDocument(plainText: text, passages: Self.textPassages(text))
        return (name, try storeExtraction(document))
    }

    private func webLinkRevision(materialID: UUID, sequence: UInt64, payload: PayloadReference) -> MaterialRevision {
        // The saved reference is born locally. Its searchable representation is also the authoritative original.
        MaterialRevision(materialID: materialID, sequence: sequence, original: payload, text: payload,
                         extractorVersion: Self.extractorVersion, extractionState: "ready", originalFilename: "Web Link.json")
    }

    @discardableResult
    public func importUniversityDocument(_ document: UniversityDocument, classID: UUID, provider: String,
                                         remoteID: String, title: String) throws -> SourceMaterial {
        guard document.data.count <= Self.maximumOriginalBytes else { throw ContextServiceError.fileTooLarge }
        guard !remoteID.isEmpty, remoteID.utf8.count <= 8_192,
              remoteID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw UniversityServiceError.message("The service returned an invalid item identifier.")
        }
        let filename = Self.importFilename(document.filename)
        let name = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").nonEmpty ?? filename
        guard name.utf8.count <= 2_048, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw UniversityServiceError.message("The service returned an invalid material title.")
        }
        let source = try Self.importSource(provider: provider, title: name, url: document.sourceURL)
        let materialID = Self.importID(classID: classID, provider: provider, remoteID: remoteID)
        let prepared = try prepare(bytes: document.data, extension: (filename as NSString).pathExtension.lowercased(), importedSource: source)
        do {
            try repository.update { state in
                guard state.classes.contains(where: { $0.id == classID }) else { throw ContextServiceError.missingClass }
                let index = state.materials.firstIndex { $0.id == materialID }
                var material = SourceMaterial(id: materialID, classID: classID, title: name,
                                              kind: provider, origin: source.origin)
                var sequence: UInt64 = 1
                if let index {
                    material = state.materials[index]
                    guard material.classID == classID, material.kind == provider,
                          let current = state.materialRevisions.first(where: { $0.id == material.currentRevisionID }) else {
                        throw ContextServiceError.missingRevision
                    }
                    if current.original == prepared.original, current.text == prepared.text,
                       current.courseworkContext == document.courseworkContext,
                       current.extractorVersion == Self.extractorVersion, current.extractionState == prepared.state,
                       current.originalFilename == filename, material.title == name, material.origin == source.origin {
                        throw AlreadyImported(material: material)
                    }
                    let last = state.materialRevisions.lazy.filter { $0.materialID == materialID }.map(\.sequence).max() ?? 0
                    guard last < UInt64.max else { throw UniversityServiceError.message("Material revision limit reached.") }
                    sequence = last + 1
                }
                let revision = MaterialRevision(materialID: materialID, sequence: sequence, original: prepared.original,
                                                text: prepared.text, extractorVersion: Self.extractorVersion,
                                                extractionState: prepared.state, originalFilename: filename, importedSource: source,
                                                courseworkContext: document.courseworkContext)
                material.title = name
                material.origin = source.origin
                material.currentRevisionID = revision.id
                if let index { state.materials[index] = material } else { state.materials.append(material) }
                state.materialRevisions.append(revision)
            }
        } catch let existing as AlreadyImported {
            if !repository.state.materials.contains(existing.material) { try repository.refresh() }
            return existing.material
        }
        guard let saved = repository.state.materials.first(where: { $0.id == materialID }) else {
            throw ContextServiceError.missingSource
        }
        return saved
    }

    private struct AlreadyImported: Error {
        let material: SourceMaterial
    }

    private enum UniversityProvider: String {
        case canvas = "uci-canvas", drive = "google-drive", gmail, gradescope, registrar = "uci-registrar"
        case calendar = "google-calendar"
    }

    public nonisolated static func isUniversityMaterial(_ material: SourceMaterial) -> Bool {
        UniversityProvider(rawValue: material.kind) != nil
    }

    private static func importID(classID: UUID, provider: String, remoteID: String) -> UUID {
        // RFC 9562 version 8. All writers derive the same identity for this source in this class.
        let key = ["org.lcp.university-material.v1", classID.uuidString, provider, remoteID].joined(separator: "\0")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A byte-only library copy (including one from a backup) has no original
    /// quarantine metadata. Mark the new file before handing it to Launch Services.
    public func originalForOpening(_ revision: MaterialRevision) throws -> URL {
        let bytes = try repository.payloadData(revision.original)
        let title = repository.state.materials.first { $0.id == revision.materialID }?.title ?? "Material"
        let filename = Self.importFilename(revision.originalFilename.isEmpty ? title : revision.originalFilename)
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("LCP-ReadOnly-Preview-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var url = directory.appendingPathComponent(filename)
            try bytes.write(to: url, options: .withoutOverwriting)
            var metadata = URLResourceValues()
            metadata.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherAttachment as String]
            try url.setResourceValues(metadata)
            try files.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return url
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private static func importFilename(_ raw: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let name = raw.components(separatedBy: separators).joined(separator: "-").trimmingCharacters(in: trimmed)
        if name.isEmpty { return "Material" }
        if name.utf8.count <= 180 { return name }
        let ext = (name as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 24 ? "." + ext : ""
        var prefix = ""
        for character in (name as NSString).deletingPathExtension {
            guard prefix.utf8.count + character.utf8.count + suffix.utf8.count <= 180 else { break }
            prefix.append(character)
        }
        return (prefix.nonEmpty ?? "Material") + suffix
    }

    private static func importSource(provider: String, title: String, url: URL) throws -> ImportedMaterialSource {
        let invalid = UniversityServiceError.message("The service did not provide a permanent source address.")
        let verified = try validatedWebURL(url.absoluteString)
        guard let parts = URLComponents(url: verified, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased() else { throw invalid }
        let name: String
        let acceptedHosts: Set<String>
        var acceptedQueryKeys = Set<String>()
        guard let service = UniversityProvider(rawValue: provider) else { throw invalid }
        switch service {
        case .canvas:
            name = "UCI Canvas"; acceptedHosts = ["canvas.eee.uci.edu"]
        case .drive:
            name = "Google Drive"; acceptedHosts = ["drive.google.com", "docs.google.com"]
        case .gmail:
            name = "Gmail"; acceptedHosts = ["mail.google.com"]; acceptedQueryKeys = ["authuser"]
        case .calendar:
            name = "Google Calendar"; acceptedHosts = ["calendar.google.com"]; acceptedQueryKeys = ["eid"]
        case .gradescope:
            name = "Gradescope"; acceptedHosts = ["www.gradescope.com", "gradescope.com"]
        case .registrar:
            name = "UCI Registrar"; acceptedHosts = ["www.reg.uci.edu"]
            acceptedQueryKeys = ["YearTerm", "Dept", "CourseNum"]
        }
        guard acceptedHosts.contains(host),
              (parts.queryItems ?? []).allSatisfy({ acceptedQueryKeys.contains($0.name) }),
              parts.fragment == nil || (provider == "gmail" && parts.fragment?.hasPrefix("all/") == true) else {
            throw invalid
        }
        return ImportedMaterialSource(provider: name, title: title, url: verified)
    }

    @discardableResult
    public func importMaterial(from source: URL, classID: UUID, title: String? = nil,
                               kind: String = "document") throws -> SourceMaterial {
        guard kind != Self.webLinkKind else { throw ContextServiceError.wrongMaterialKind }
        guard UniversityProvider(rawValue: kind) == nil else {
            throw UniversityServiceError.message("Choose the item in University Services to import it with provider attribution.")
        }
        guard repository.state.classes.contains(where: { $0.id == classID }) else { throw ContextServiceError.missingClass }
        let prepared = try prepare(source: source)
        var material = SourceMaterial(classID: classID,
                                      title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? source.deletingPathExtension().lastPathComponent,
                                      kind: kind, origin: "Imported file: \(source.lastPathComponent)")
        let revision = MaterialRevision(materialID: material.id, sequence: 1, original: prepared.original,
                                        text: prepared.text, extractorVersion: Self.extractorVersion,
                                        extractionState: prepared.state, originalFilename: source.lastPathComponent)
        material.currentRevisionID = revision.id
        let committedMaterial = material
        try repository.update { state in
            state.materials.append(committedMaterial)
            state.materialRevisions.append(revision)
        }
        return committedMaterial
    }

    @discardableResult
    public func reviseMaterial(materialID: UUID, from source: URL) throws -> MaterialRevision {
        guard let material = repository.state.materials.first(where: { $0.id == materialID }) else { throw ContextServiceError.missingSource }
        guard material.kind != Self.webLinkKind else { throw ContextServiceError.wrongMaterialKind }
        guard !Self.isUniversityMaterial(material) else {
            throw UniversityServiceError.message("Import the item again in University Services to save an updated version.")
        }
        let prepared = try prepare(source: source)
        if let current = repository.state.materialRevisions.first(where: { $0.id == material.currentRevisionID }),
           current.original == prepared.original, current.extractorVersion == Self.extractorVersion,
           current.text == prepared.text, current.extractionState == prepared.state { return current }
        let sequence = (repository.state.materialRevisions.filter { $0.materialID == materialID }.map(\.sequence).max() ?? 0) + 1
        let revision = MaterialRevision(materialID: materialID, sequence: sequence, original: prepared.original,
                                        text: prepared.text, extractorVersion: Self.extractorVersion,
                                        extractionState: prepared.state, originalFilename: source.lastPathComponent)
        try repository.update { state in
            guard let index = state.materials.firstIndex(where: { $0.id == materialID }) else { throw ContextServiceError.missingSource }
            state.materialRevisions.append(revision)
            state.materials[index].currentRevisionID = revision.id
        }
        return revision
    }

    /// A relink restores the exact original bytes, never silently substitutes a new revision.
    public func relinkOriginal(revisionID: UUID, from source: URL) throws {
        guard let revision = repository.state.materialRevisions.first(where: { $0.id == revisionID }) else { throw ContextServiceError.missingRevision }
        let bytes = try boundedRead(source)
        guard UInt64(bytes.count) == revision.original.byteCount,
              Self.digest(bytes) == revision.original.sha256 else { throw ContextServiceError.invalidCitation }
        let stored = try repository.storePayload(bytes, mediaType: revision.original.mediaType)
        guard stored == revision.original else { throw ContextServiceError.invalidCitation }
    }

    public func extractedDocument(for revision: MaterialRevision) throws -> ExtractionDocument {
        guard let payload = revision.text else { throw ContextServiceError.unsupportedExtraction }
        let data = try repository.payloadData(payload)
        guard data.count <= 2 * Self.maximumExtractedBytes + 2 * 1_024 * 1_024 else { throw ContextServiceError.extractionTooLarge }
        let document = try JSONDecoder().decode(ExtractionDocument.self, from: data)
        guard document.schemaVersion == 1, document.plainText.utf8.count <= Self.maximumExtractedBytes,
              !document.passages.isEmpty, document.passages.count <= 100_000 else { throw ContextServiceError.invalidText }
        let plainBytes = Data(document.plainText.utf8)
        if case .text = document.passages[0].locator {
            var nextOffset = 0
            for passage in document.passages {
                guard case .text(let start, let length) = passage.locator,
                      start == nextOffset, length > 0, start <= plainBytes.count, length <= plainBytes.count - start,
                      String(data: plainBytes.subdata(in: start..<(start + length)), encoding: .utf8) == passage.text else { throw ContextServiceError.invalidText }
                nextOffset += length
            }
            guard nextOffset == plainBytes.count else { throw ContextServiceError.invalidText }
        } else {
            var lastPage = 0
            for passage in document.passages {
                guard case .page(let page) = passage.locator, page > lastPage, page <= 10_000, !passage.text.isEmpty else { throw ContextServiceError.invalidText }
                lastPage = page
            }
            guard document.passages.map(\.text).joined(separator: "\n\n") == document.plainText else { throw ContextServiceError.invalidText }
        }
        return document
    }

    private func prepare(source: URL) throws -> (original: PayloadReference, text: PayloadReference?, state: String) {
        try prepare(bytes: boundedRead(source), extension: source.pathExtension.lowercased())
    }

    private func prepare(bytes: Data, extension ext: String, importedSource: ImportedMaterialSource? = nil) throws -> (original: PayloadReference, text: PayloadReference?, state: String) {
        let original = try repository.storePayload(bytes, mediaType: Self.mediaType(for: ext))
        func withoutBody(_ state: String) throws -> (PayloadReference, PayloadReference?, String) {
            guard let source = importedSource else { return (original, nil, state) }
            // Older schema-v1 applications retain this immutable payload when they rewrite the store.
            let label = "Attachment details (no extracted body)\n\(source.title)\n\(source.origin)"
            var details = ExtractionDocument(plainText: label, passages: Self.textPassages(label))
            details.importedSource = source
            return (original, try storeExtraction(details), "\(state)_attachment_details_only")
        }
        guard ["txt", "md", "markdown", "pdf", "rtf"].contains(ext) else { return try withoutBody("unsupported") }
        do {
            var extraction = try extract(bytes, extension: ext)
            extraction.importedSource = importedSource
            let text = try storeExtraction(extraction)
            return (original, text, "ready")
        } catch {
            // Unsupported/malformed source files are still useful attachments. Preserve them explicitly.
            return try withoutBody("failed")
        }
    }

    private func storeExtraction(_ document: ExtractionDocument) throws -> PayloadReference {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try repository.storePayload(encoder.encode(document), mediaType: "application/vnd.lcp.extracted+json")
    }

    private func boundedRead(_ source: URL) throws -> Data {
        guard source.isFileURL else { throw ContextServiceError.invalidFile }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ContextServiceError.invalidFile }
        guard let size = values.fileSize, size <= Self.maximumOriginalBytes else { throw ContextServiceError.fileTooLarge }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: min(65_536, Self.maximumOriginalBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= Self.maximumOriginalBytes else { throw ContextServiceError.fileTooLarge }
        }
        return data
    }

    private func extract(_ bytes: Data, extension ext: String) throws -> ExtractionDocument {
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: bytes), pdf.pageCount <= 10_000 else { throw ContextServiceError.invalidText }
            var passages: [ExtractedPassage] = []
            var totalBytes = 0
            for page in 0..<pdf.pageCount {
                let text = pdf.page(at: page)?.string ?? ""
                totalBytes += text.utf8.count + 2
                guard totalBytes <= Self.maximumExtractedBytes else { throw ContextServiceError.extractionTooLarge }
                if !text.isEmpty { passages.append(ExtractedPassage(locator: .page(page + 1), text: text)) }
            }
            let text = passages.map(\.text).joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContextServiceError.invalidText }
            return ExtractionDocument(plainText: text, passages: passages,
                warning: passages.count < pdf.pageCount ? "Some pages have no extractable text. Scanned pages require OCR outside LCP." : nil)
        }
        let text: String
        if ext == "rtf" {
            text = try NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        } else if let utf8 = String(data: bytes, encoding: .utf8) {
            text = utf8
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
                  let utf16 = String(data: bytes, encoding: .utf16) {
            text = utf16
        } else { throw ContextServiceError.invalidText }
        guard text.utf8.count <= Self.maximumExtractedBytes else { throw ContextServiceError.extractionTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContextServiceError.invalidText }
        return ExtractionDocument(plainText: text, passages: Self.textPassages(text))
    }

    nonisolated static func textPassages(_ text: String) -> [ExtractedPassage] {
        var passages: [ExtractedPassage] = []
        var startByte = 0
        var chunk = ""
        var chunkByteCount = 0
        for scalar in text.unicodeScalars {
            if chunkByteCount + scalar.utf8.count > 4_096 && !chunk.isEmpty {
                passages.append(ExtractedPassage(locator: .text(startUTF8: startByte, lengthUTF8: chunk.utf8.count), text: chunk))
                startByte += chunk.utf8.count
                chunk = ""
                chunkByteCount = 0
            }
            chunk.unicodeScalars.append(scalar)
            chunkByteCount += scalar.utf8.count
        }
        if !chunk.isEmpty { passages.append(ExtractedPassage(locator: .text(startUTF8: startByte, lengthUTF8: chunk.utf8.count), text: chunk)) }
        return passages
    }

    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    nonisolated static func mediaType(for ext: String) -> String {
        switch ext {
        case "pdf": return "application/pdf"
        case "rtf": return "application/rtf"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
