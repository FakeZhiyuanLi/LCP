import Foundation

public struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    public static let maximumCount = 8
    public static let maximumBytes = 32 * 1024 * 1024
    public let id: UUID
    public let filename: String
    public let original: PayloadReference
    public let text: PayloadReference?
    public var suggestion: ChatFilingSuggestion?
    public var savedMaterialID: UUID?

    public init(id: UUID = UUID(), filename: String, original: PayloadReference, text: PayloadReference? = nil) {
        self.id = id
        self.filename = filename
        self.original = original
        self.text = text
    }

    public static func validFilename(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1024 &&
            name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
            name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public struct ChatFilingSuggestion: Codable, Equatable, Sendable {
    public let attachmentID: UUID
    public let classID: UUID
    public let title: String
    public let reason: String

    public init(attachmentID: UUID, classID: UUID, title: String, reason: String) {
        self.attachmentID = attachmentID
        self.classID = classID
        self.title = title
        self.reason = reason
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 512 &&
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reason.utf8.count <= 1024 &&
            [title, reason].allSatisfy { $0.rangeOfCharacter(from: .controlCharacters) == nil }
    }
}
