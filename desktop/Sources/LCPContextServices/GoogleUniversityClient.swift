import Foundation
import CoreFoundation

public enum GoogleUniversityKind: String, CaseIterable, Sendable { case drive, gmail, calendar }

public struct GoogleClassFolder: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Google Workspace imports and Drive class folders. The caller supplies the authorized account.
public struct GoogleUniversityClient: Sendable {
    private let http: UniversityHTTP
    private let token: String
    private let driveHost = "www.googleapis.com"
    private let mailHost = "gmail.googleapis.com"
    private let calendarHost = "www.googleapis.com"
    private let documentLimit = 32 * 1_024 * 1_024
    private typealias Query = [URLQueryItem]

    public init(token: String, http: UniversityHTTP = .init()) {
        self.token = token
        self.http = http
    }

    public func items(kind: GoogleUniversityKind, query: String, cursor: String? = nil) async throws -> UniversityPage {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf8.count <= 2_048, (cursor?.utf8.count ?? 0) <= 4_096 else {
            throw UniversityServiceError.message("Enter a search of up to 2,048 bytes.")
        }
        let paging: Query = cursor.map { [.init(name: "pageToken", value: $0)] } ?? []
        switch kind {
        case .drive: return try await driveItems(term: term, paging: paging)
        case .gmail: return try await mailItems(term: term, paging: paging)
        case .calendar: return try await calendarItems(term: term, paging: paging)
        }
    }

    public func document(kind: GoogleUniversityKind, item: UniversityItem) async throws -> UniversityDocument {
        try Self.checkID(item.id)
        switch kind {
        case .drive: return try await driveDocument(id: item.id)
        case .gmail:
            if item.metadata["gmailAttachmentID"] != nil {
                return try await mailAttachmentDocument(item: item)
            }
            return try await mailDocument(item: item)
        case .calendar: return try await calendarDocument(item: item)
        }
    }

    /// Lists downloadable file attachments on a selected Gmail message.
    /// The message body itself is not treated as an attachment, and metadata
    /// is bounded before the user is offered a download.
    public func gmailAttachments(for item: UniversityItem) async throws -> [UniversityItem] {
        let email = try await account()
        guard item.metadata["mailbox"] == email else {
            throw UniversityServiceError.message("The connected Gmail account changed. Search again to select a message from this account.")
        }
        let message = try await message(id: item.id, metadataOnly: false)
        return try Self.attachmentItems(from: message.payload, messageID: message.id, threadID: message.threadId,
                                        mailbox: email)
    }

    private func endpoint(_ host: String, path: String, query: Query) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        if !query.isEmpty {
            parts.queryItems = query
            // Google treats a literal '+' in a query parameter as a space.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw UniversityServiceError.message("Could not construct the Google request.") }
        return url
    }

    private func data(_ host: String, path: String, query: Query = [], limit: Int = 4_000_000, contentRedirects: Bool = false) async throws -> Data {
        let url = try endpoint(host, path: path, query: query)
        let hosts: Set<String> = contentRedirects ? [host, "*.googleusercontent.com", "drive.usercontent.google.com"] : [host]
        return try await http.get(url, bearer: token, allowedHosts: hosts, limit: limit).0
    }

    private static func checkID(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !id.isEmpty, id.utf8.count <= 1_024, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw UniversityServiceError.message("Google returned an invalid item identifier.")
        }
    }

    private struct DriveFile: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let modifiedTime: String?
        let size: String?
        let capabilities: Capabilities?
        let trashed: Bool?
        let parents: [String]?
        let driveId: String?
        struct Capabilities: Decodable { let canDownload: Bool? }
    }

    private struct DriveList: Decodable {
        let files: [DriveFile]?
        let nextPageToken: String?
        let incompleteSearch: Bool?
    }

    private static let folderType = "application/vnd.google-apps.folder"
    private static let folderFields = "id,name,mimeType,trashed,parents,driveId"

    private static func validateFolder(_ file: DriveFile) throws {
        try checkID(file.id)
        guard file.mimeType == folderType, file.trashed == false, !file.name.isEmpty else {
            throw UniversityServiceError.message("Google Drive did not return an active folder.")
        }
    }

    private func folderMetadata(id: String) async throws -> DriveFile {
        try Self.checkID(id)
        let parameters: Query = [.init(name: "fields", value: Self.folderFields),
                                 .init(name: "supportsAllDrives", value: "true")]
        let metadata = try await data(driveHost, path: "/drive/v3/files/\(id)", query: parameters, limit: 65_536)
        let folder = try JSONDecoder().decode(DriveFile.self, from: metadata)
        try Self.validateFolder(folder)
        guard folder.id == id || id == "root" else {
            throw UniversityServiceError.message("Google Drive returned a different folder. Try again.")
        }
        return folder
    }

    public func getClassFolder(id: String) async throws -> GoogleClassFolder {
        let folder = try await folderMetadata(id: id)
        return GoogleClassFolder(id: folder.id, name: folder.name)
    }

    /// Enumerate only immediate child folders, comparing names with the capture catalog's folding rules.
    public func findClassFolder(named name: String, under parentID: String) async throws -> GoogleClassFolder? {
        let parent = try await folderMetadata(id: parentID)
        let filter = "'\(parent.id)' in parents and trashed = false and mimeType = '\(Self.folderType)'"
        var query: Query = [.init(name: "q", value: filter), .init(name: "spaces", value: "drive"),
                            .init(name: "includeItemsFromAllDrives", value: "true"),
                            .init(name: "supportsAllDrives", value: "true"),
                            .init(name: "pageSize", value: "100"), .init(name: "fields", value:
                                "nextPageToken,incompleteSearch,files(\(Self.folderFields))")]
        if let driveID = parent.driveId {
            try Self.checkID(driveID)
            query.append(.init(name: "corpora", value: "drive"))
            query.append(.init(name: "driveId", value: driveID))
        } else {
            query.append(.init(name: "corpora", value: "user"))
        }
        var paging: Query = []
        var seenTokens = Set<String>()
        var match: GoogleClassFolder?
        while true {
            let bytes = try await data(driveHost, path: "/drive/v3/files", query: query + paging)
            let page = try JSONDecoder().decode(DriveList.self, from: bytes)
            guard page.incompleteSearch != true, let files = page.files else {
                throw UniversityServiceError.message("Google Drive returned an incomplete folder list. Try again.")
            }
            for file in files {
                try Self.validateFolder(file)
                guard file.parents?.contains(parent.id) == true else {
                    throw UniversityServiceError.message("Google Drive returned a folder outside the requested parent. Try again.")
                }
                guard file.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive],
                                        locale: Locale(identifier: "en_US_POSIX")) == .orderedSame else { continue }
                guard match == nil || match?.id == file.id else {
                    throw UniversityServiceError.message("Several Google Drive folders match “\(name)”. Give them distinct names in Drive, then retry.")
                }
                match = GoogleClassFolder(id: file.id, name: file.name)
            }
            guard let next = page.nextPageToken else { return match }
            guard !next.isEmpty, next.utf8.count <= 4_096, seenTokens.count < 1_000,
                  seenTokens.insert(next).inserted else {
                throw UniversityServiceError.message("Google Drive could not finish listing the folders. Try again.")
            }
            paging = [.init(name: "pageToken", value: next)]
        }
    }

    /// The caller persists this ID before its first create request, including across restarts.
    public func generateDriveFolderID() async throws -> String {
        struct GeneratedIDs: Decodable { let ids: [String] }
        let query: Query = [.init(name: "count", value: "1"), .init(name: "space", value: "drive"),
                            .init(name: "type", value: "files")]
        let bytes = try await data(driveHost, path: "/drive/v3/files/generateIds", query: query, limit: 16_384)
        let ids = try JSONDecoder().decode(GeneratedIDs.self, from: bytes).ids
        guard ids.count == 1, let id = ids.first, id != "root" else {
            throw UniversityServiceError.message("Google Drive could not reserve a folder identifier.")
        }
        try Self.checkID(id)
        return id
    }

    public func createClassFolder(named name: String, under parentID: String,
                                  reservedID: String) async throws -> GoogleClassFolder {
        try Self.checkID(reservedID)
        guard !name.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              reservedID != "root", reservedID != parentID else {
            throw UniversityServiceError.message("The Google Drive folder name or reserved identifier is invalid.")
        }
        let parent = try await folderMetadata(id: parentID)
        let url = try endpoint(driveHost, path: "/drive/v3/files", query: [
            .init(name: "supportsAllDrives", value: "true"), .init(name: "fields", value: Self.folderFields)
        ])
        let body = try JSONSerialization.data(withJSONObject: ["id": reservedID, "name": name,
                    "mimeType": Self.folderType, "parents": [parent.id]])
        let file: DriveFile
        do {
            let bytes = try await http.postJSON(url, body: body, bearer: token, host: driveHost)
            file = try JSONDecoder().decode(DriveFile.self, from: bytes)
        } catch UniversityServiceError.http(409) {
            // Drive already used this ID, possibly after a client timeout. Verify the actual object.
            file = try await folderMetadata(id: reservedID)
        }
        try Self.validateFolder(file)
        guard file.id == reservedID, file.name == name, file.parents?.contains(parent.id) == true else {
            throw UniversityServiceError.message("The Google Drive folder does not match this class and parent. Check the folder in Drive.")
        }
        return GoogleClassFolder(id: file.id, name: file.name)
    }

    private func driveItems(term: String, paging: Query) async throws -> UniversityPage {
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let filter = """
        trashed = false and mimeType != 'application/vnd.google-apps.folder' and mimeType != 'application/vnd.google-apps.shortcut' and (name contains '\(escaped)' or fullText contains '\(escaped)')
        """
        let query: Query = [
            .init(name: "q", value: filter), .init(name: "spaces", value: "drive"),
            // `includeItemsFromAllDrives` permits shared-drive results only when
            // the search corpus includes them. Keep the search read-only while
            // making course material stored in a UCI shared drive discoverable.
            .init(name: "corpora", value: "allDrives"),
            .init(name: "includeItemsFromAllDrives", value: "true"), .init(name: "supportsAllDrives", value: "true"),
            .init(name: "orderBy", value: "modifiedTime desc"), .init(name: "pageSize", value: "50"),
            .init(name: "fields", value: "nextPageToken,files(id,name,mimeType,modifiedTime)")
        ] + paging
        let list = try JSONDecoder().decode(DriveList.self, from: await data(driveHost, path: "/drive/v3/files", query: query))
        let items = try (list.files ?? []).map { file in
            try Self.checkID(file.id)
            return UniversityItem(id: file.id, title: file.name, detail: [file.mimeType, file.modifiedTime].compactMap { $0 }.joined(separator: " · "))
        }
        return UniversityPage(items: items, next: list.nextPageToken)
    }

    private func driveDocument(id: String) async throws -> UniversityDocument {
        let path = "/drive/v3/files/\(id)"
        let query: Query = [.init(name: "fields", value: "id,name,mimeType,size,capabilities(canDownload)"),
                            .init(name: "supportsAllDrives", value: "true")]
        let file = try JSONDecoder().decode(DriveFile.self, from: await data(driveHost, path: path, query: query))
        guard file.id == id, file.capabilities?.canDownload != false else {
            throw UniversityServiceError.message("Google Drive did not grant download access to this file.")
        }
        let name = Self.filename(file.name, fallback: "Drive file")
        let bytes: Data
        let filename: String
        var sourceURL = try endpoint("drive.google.com", path: "/file/d/\(id)/view", query: [])
        switch file.mimeType {
        case "application/vnd.google-apps.document", "application/vnd.google-apps.presentation", "application/vnd.google-apps.spreadsheet", "application/vnd.google-apps.drawing":
            // PDF includes slide pages and all printable sheets, and works with LCP's page citations.
            let editor = ["application/vnd.google-apps.document": "document", "application/vnd.google-apps.presentation": "presentation",
                          "application/vnd.google-apps.spreadsheet": "spreadsheets", "application/vnd.google-apps.drawing": "drawings"]
            if let editorPath = editor[file.mimeType] { sourceURL = try endpoint("docs.google.com", path: "/\(editorPath)/d/\(id)/edit", query: []) }
            bytes = try await data(driveHost, path: path + "/export", query: [.init(name: "mimeType", value: "application/pdf")], limit: documentLimit, contentRedirects: true)
            filename = name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
        case let type where type.hasPrefix("application/vnd.google-apps."):
            throw UniversityServiceError.message("This Google Workspace file type has no supported LCP export.")
        default:
            if let size = file.size.flatMap(Int64.init), size > Int64(documentLimit) {
                throw UniversityServiceError.message("This Drive file exceeds the 32 MiB material import limit.")
            }
            bytes = try await data(driveHost, path: path, query: [.init(name: "alt", value: "media"), .init(name: "supportsAllDrives", value: "true")], limit: documentLimit, contentRedirects: true)
            filename = name
        }
        return UniversityDocument(filename: filename, data: bytes, sourceURL: sourceURL)
    }

    private struct CalendarDate: Decodable {
        let date: String?
        let dateTime: String?
        let timeZone: String?
    }

    private struct CalendarEvent: Decodable {
        let id: String
        let summary: String?
        let description: String?
        let location: String?
        let htmlLink: String?
        let status: String?
        let updated: String?
        let start: CalendarDate?
        let end: CalendarDate?
    }

    private struct CalendarList: Decodable {
        let items: [CalendarEvent]?
        let nextPageToken: String?
    }

    private func calendarItems(term: String, paging: Query) async throws -> UniversityPage {
        let query: Query = [
            .init(name: "q", value: term),
            .init(name: "singleEvents", value: "true"),
            .init(name: "showDeleted", value: "false"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "50"),
            .init(name: "fields", value: "nextPageToken,items(id,summary,description,location,htmlLink,status,updated,start,end)")
        ] + paging
        let list = try JSONDecoder().decode(CalendarList.self, from: await data(calendarHost,
            path: "/calendar/v3/calendars/primary/events", query: query))
        let items = try (list.items ?? []).compactMap { event -> UniversityItem? in
            try Self.checkID(event.id)
            guard event.status?.lowercased() != "cancelled" else { return nil }
            let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            let date = Self.calendarDate(event.start) ?? "Unscheduled"
            var metadata = ["calendarID": "primary", "eventID": event.id]
            if let link = event.htmlLink { metadata["htmlLink"] = link }
            return UniversityItem(id: event.id, title: title, detail: date, metadata: metadata)
        }
        return UniversityPage(items: items, next: list.nextPageToken)
    }

    private func calendarDocument(item: UniversityItem) async throws -> UniversityDocument {
        try Self.checkID(item.id)
        guard item.metadata["calendarID"] == "primary" else {
            throw UniversityServiceError.message("Search your connected calendar again to identify this event.")
        }
        let eventData = try await data(calendarHost, path: "/calendar/v3/calendars/primary/events/\(item.id)", query: [
            .init(name: "fields", value: "id,summary,description,location,htmlLink,status,updated,start,end")
        ])
        let event = try JSONDecoder().decode(CalendarEvent.self, from: eventData)
        guard event.id == item.id, event.status?.lowercased() != "cancelled" else {
            throw UniversityServiceError.message("This calendar event was cancelled or changed. Refresh the list and select it again.")
        }
        let title = Self.filename(event.summary ?? item.title, fallback: "Calendar event")
        let lines = [
            "Google Calendar event",
            "Title: \(event.summary ?? item.title)",
            event.start.map { "Starts: \(Self.calendarDate($0) ?? "Unscheduled")" },
            event.end.map { "Ends: \(Self.calendarDate($0) ?? "Unscheduled")" },
            event.location.map { "Location: \($0)" },
            event.updated.map { "Updated: \($0)" },
            event.description.map { "\n\($0)" }
        ].compactMap { $0 }.joined(separator: "\n")
        let sourceURL = Self.calendarURL(event.htmlLink)
        return UniversityDocument(filename: title + ".txt", data: Data(lines.utf8), sourceURL: sourceURL,
                                  remoteID: "primary/\(event.id)")
    }

    private static func calendarDate(_ value: CalendarDate?) -> String? {
        guard let value else { return nil }
        if let dateTime = value.dateTime, !dateTime.isEmpty { return dateTime }
        if let date = value.date, !date.isEmpty { return date }
        return nil
    }

    private static func calendarURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "calendar.google.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else {
            return URL(string: "https://calendar.google.com/calendar/u/0/r")!
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(string: "https://calendar.google.com/calendar/u/0/r")!
        }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "calendar.google.com"
        canonical.percentEncodedPath = components.percentEncodedPath
        if let eid = components.queryItems?.first(where: { $0.name == "eid" }),
           let value = eid.value, !value.isEmpty {
            canonical.queryItems = [URLQueryItem(name: "eid", value: value)]
        }
        return canonical.url ?? URL(string: "https://calendar.google.com/calendar/u/0/r")!
    }

    private struct Profile: Decodable { let emailAddress: String }
    private struct MailList: Decodable {
        struct Entry: Decodable { let id: String }
        let messages: [Entry]?
        let nextPageToken: String?
    }
    private struct Header: Decodable { let name: String; let value: String }
    private struct MailPart: Decodable {
        struct Body: Decodable { let data: String?; let attachmentId: String?; let size: Int? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [MailPart]?

        func header(_ name: String) -> String? {
            headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var type: String { mimeType?.lowercased() ?? "" }
        var isAttachment: Bool {
            !(filename ?? "").isEmpty || header("Content-Disposition")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("attachment") == true
        }
    }
    private struct Message: Decodable {
        let id: String
        let threadId: String
        let payload: MailPart
    }
    private let mailRoot = "/gmail/v1/users/me"

    private func account() async throws -> String {
        let response = try await data(mailHost, path: mailRoot + "/profile", query: [.init(name: "fields", value: "emailAddress")])
        let email = try JSONDecoder().decode(Profile.self, from: response).emailAddress.lowercased()
        guard email.contains("@"), email.utf8.count <= 320, email.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw UniversityServiceError.message("Gmail returned an invalid account address.")
        }
        return email
    }

    private func mailItems(term: String, paging: Query) async throws -> UniversityPage {
        let query: Query = [.init(name: "q", value: term), .init(name: "maxResults", value: "12"),
                            .init(name: "fields", value: "nextPageToken,messages/id")] + paging
        let list = try JSONDecoder().decode(MailList.self, from: await data(mailHost, path: mailRoot + "/messages", query: query))
        let entries = list.messages ?? []
        guard !entries.isEmpty else { return UniversityPage(items: [], next: list.nextPageToken) }
        guard entries.count <= 12 else { throw UniversityServiceError.message("Gmail returned too many messages in one page.") }
        let email = try await account()
        let items = try await withThrowingTaskGroup(of: (Int, UniversityItem).self) { group in
            for (index, entry) in entries.enumerated() {
                try Self.checkID(entry.id)
                group.addTask {
                    let message = try await message(id: entry.id, metadataOnly: true)
                    let fields = ["From", "Date"].compactMap { message.payload.header($0) }
                    return (index, UniversityItem(id: entry.id, title: message.payload.header("Subject") ?? "(No subject)",
                        detail: fields.joined(separator: " · "), metadata: ["mailbox": email, "importID": email + "/" + entry.id]))
                }
            }
            var ordered: [(Int, UniversityItem)] = []
            for try await row in group { ordered.append(row) }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return UniversityPage(items: items, next: list.nextPageToken)
    }

    private func message(id: String, metadataOnly: Bool) async throws -> Message {
        var query: Query = [.init(name: "format", value: metadataOnly ? "metadata" : "full")]
        if metadataOnly {
            query += ["From","Date","Subject"].map { .init(name: "metadataHeaders", value: $0) }
            query.append(.init(name: "fields", value: "id,threadId,payload/headers"))
        } else {
            query.append(.init(name: "fields", value: "id,threadId,payload"))
        }
        let response = try await data(mailHost, path: mailRoot + "/messages/" + id, query: query, limit: metadataOnly ? 128_000 : documentLimit)
        let message = try JSONDecoder().decode(Message.self, from: response)
        guard message.id == id else { throw UniversityServiceError.message("Gmail returned a different message.") }
        try Self.checkID(message.threadId)
        return message
    }

    private func mailDocument(item: UniversityItem) async throws -> UniversityDocument {
        let email = try await account()
        guard item.metadata["mailbox"] == email else {
            throw UniversityServiceError.message("The connected Gmail account changed. Search again to select a message from this account.")
        }
        let message = try await message(id: item.id, metadataOnly: false)
        let payload = message.payload
        var budget = BodyBudget()
        guard let body = try await readableText(from: payload, messageID: item.id, depth: 0, budget: &budget), !body.isEmpty else {
            throw UniversityServiceError.message("This message has no readable text or HTML body.")
        }
        let title = payload.header("Subject") ?? "(No subject)"
        let headerLines = ["Subject", "From", "To", "Date", "Message-ID"].compactMap { name in
            payload.header(name).map { "\(name): \($0)" }
        }
        let content = (headerLines + ["Gmail message ID: \(item.id)", "", body]).joined(separator: "\n")
        let url = try Self.mailThreadURL(email: email, threadID: message.threadId)
        return UniversityDocument(filename: Self.filename(title, fallback: "Gmail message") + ".txt", data: Data(content.utf8), sourceURL: url)
    }

    private func mailAttachmentDocument(item: UniversityItem) async throws -> UniversityDocument {
        let email = try await account()
        guard item.metadata["mailbox"] == email,
              let messageID = item.metadata["gmailMessageID"],
              let attachmentID = item.metadata["gmailAttachmentID"],
              let partPath = item.metadata["gmailPartPath"],
              item.id == attachmentID else {
            throw UniversityServiceError.message("Search your connected mailbox again to identify this attachment.")
        }
        try Self.checkID(messageID)
        try Self.checkID(attachmentID)
        let message = try await message(id: messageID, metadataOnly: false)
        guard let path = Self.parsePartPath(partPath),
              let part = Self.findPart(in: message.payload, path: path),
              (part.body?.attachmentId == item.metadata["gmailBodyAttachmentID"] ||
               (part.body?.attachmentId == nil && attachmentID.hasPrefix("inline-"))),
              part.isAttachment else {
            throw UniversityServiceError.message("Gmail could not find this attachment. Refresh the message and try again.")
        }
        let filename = Self.filename(part.filename ?? "Attachment", fallback: "Attachment")
        let expectedSize = part.body?.size
        if let expectedSize, expectedSize > documentLimit {
            throw UniversityServiceError.message("This Gmail attachment exceeds the 32 MiB material import limit.")
        }
        guard let body = part.body else {
            throw UniversityServiceError.message("Gmail returned an attachment without content.")
        }
        let encoded: String
        if let inline = body.data, !inline.isEmpty {
            encoded = inline
        } else if let bodyAttachmentID = body.attachmentId {
            try Self.checkID(bodyAttachmentID)
            let path = mailRoot + "/messages/\(messageID)/attachments/\(bodyAttachmentID)"
            let attachment = try JSONDecoder().decode(MailPart.Body.self, from: await data(mailHost, path: path, limit: documentLimit))
            guard let content = attachment.data else { throw UniversityServiceError.message("Gmail omitted the attachment bytes.") }
            if let size = attachment.size, size > documentLimit {
                throw UniversityServiceError.message("This Gmail attachment exceeds the 32 MiB material import limit.")
            }
            encoded = content
        } else {
            throw UniversityServiceError.message("Gmail returned an attachment without downloadable bytes.")
        }
        let bytes = try Self.decodeBase64(encoded, expectedSize: expectedSize)
        guard bytes.count <= documentLimit else {
            throw UniversityServiceError.message("This Gmail attachment exceeds the 32 MiB material import limit.")
        }
        let url = try Self.mailThreadURL(email: email, threadID: message.threadId)
        return UniversityDocument(filename: filename, data: bytes, sourceURL: url,
                                  remoteID: email + "/" + messageID + "/" + attachmentID)
    }

    private struct BodyBudget {
        var bytesRemaining = 16 * 1_024 * 1_024
        var partsRemaining = 512
        var downloadsRemaining = 16
    }

    private static func attachmentItems(from part: MailPart, messageID: String, threadID: String,
                                        mailbox: String, path: [Int] = [0], depth: Int = 0) throws -> [UniversityItem] {
        guard depth < 32 else { throw UniversityServiceError.message("This message has too many nested MIME parts.") }
        var result: [UniversityItem] = []
        if part.isAttachment, part.body?.attachmentId != nil || (part.isAttachment && part.body?.data != nil) {
            let pathKey = path.map(String.init).joined(separator: "-")
            let attachmentID = part.body?.attachmentId ?? "inline-\(pathKey)"
            try checkID(attachmentID)
            let title = filename(part.filename ?? "Attachment", fallback: "Attachment")
            let size = part.body?.size
            let detail = [part.mimeType, size.map { "\($0) bytes" }].compactMap { $0 }.joined(separator: " · ")
            var metadata = ["mailbox": mailbox, "gmailMessageID": messageID,
                            "gmailAttachmentID": attachmentID, "gmailThreadID": threadID,
                            "gmailPartPath": path.map(String.init).joined(separator: "."),
                            "importID": mailbox + "/" + messageID + "/" + attachmentID]
            if let bodyAttachmentID = part.body?.attachmentId { metadata["gmailBodyAttachmentID"] = bodyAttachmentID }
            result.append(UniversityItem(id: attachmentID, title: title, detail: detail, metadata: metadata))
        }
        for (index, child) in (part.parts ?? []).enumerated() {
            result.append(contentsOf: try attachmentItems(from: child, messageID: messageID, threadID: threadID,
                                                          mailbox: mailbox, path: path + [index], depth: depth + 1))
            guard result.count <= 64 else { throw UniversityServiceError.message("This message has too many attachments.") }
        }
        return result
    }

    private static func parsePartPath(_ value: String) -> [Int]? {
        let components = value.split(separator: ".")
        guard !components.isEmpty, components.count <= 32 else { return nil }
        let result = components.compactMap { Int($0) }
        return result.count == components.count && result.allSatisfy { $0 >= 0 && $0 <= 512 } ? result : nil
    }

    private static func findPart(in root: MailPart, path: [Int]) -> MailPart? {
        guard path.first == 0 else { return nil }
        var part = root
        for index in path.dropFirst() {
            guard let child = part.parts, index < child.count else { return nil }
            part = child[index]
        }
        return part
    }

    private static func mailThreadURL(email: String, threadID: String) throws -> URL {
        try checkID(threadID)
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "mail.google.com"
        parts.path = "/mail/u/"
        parts.queryItems = [.init(name: "authuser", value: email)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        parts.fragment = "all/" + threadID
        guard let url = parts.url else { throw UniversityServiceError.message("Could not build this Gmail thread link.") }
        return url
    }

    private static func decodeBase64(_ encoded: String, expectedSize: Int?) throws -> Data {
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), expectedSize == nil || expectedSize == bytes.count else {
            throw UniversityServiceError.message("Gmail returned incomplete attachment bytes.")
        }
        return bytes
    }

    private func readableText(from part: MailPart, messageID: String, depth: Int, budget: inout BodyBudget) async throws -> String? {
        guard budget.partsRemaining > 0 else { throw UniversityServiceError.message("This message has too many MIME parts.") }
        budget.partsRemaining -= 1
        guard depth < 32 else { throw UniversityServiceError.message("This message has too many nested MIME parts.") }
        guard !part.isAttachment else { return nil }
        if part.type.hasPrefix("multipart/") {
            let children = part.parts ?? []
            if part.type == "multipart/alternative" {
                // Select one representation; importing both duplicates the message body.
                for child in children.filter({ $0.type == "text/plain" }) + children.filter({ $0.type != "text/plain" }) {
                    if let text = try await readableText(from: child, messageID: messageID, depth: depth + 1, budget: &budget) { return text }
                }
                return nil
            }
            var paragraphs: [String] = []
            for child in children {
                if let text = try await readableText(from: child, messageID: messageID, depth: depth + 1, budget: &budget) { paragraphs.append(text) }
            }
            return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
        }
        guard part.type == "text/plain" || part.type == "text/html", let body = part.body else { return nil }
        if let size = body.size, size > budget.bytesRemaining { throw UniversityServiceError.message("This message exceeds the 16 MiB text limit.") }
        let encoded: String
        if let inline = body.data, !inline.isEmpty {
            encoded = inline
        } else if let id = body.attachmentId {
            guard budget.downloadsRemaining > 0 else { throw UniversityServiceError.message("This message has too many separately stored text parts.") }
            budget.downloadsRemaining -= 1
            try Self.checkID(id)
            let path = mailRoot + "/messages/\(messageID)/attachments/\(id)"
            let attachment = try JSONDecoder().decode(MailPart.Body.self, from: await data(mailHost, path: path, limit: documentLimit))
            guard let content = attachment.data else { throw UniversityServiceError.message("Gmail omitted a message body part.") }
            encoded = content
        } else { return nil }
        let bytes = try Self.decodeBase64(encoded, expectedSize: body.size)
        guard bytes.count <= budget.bytesRemaining else { throw UniversityServiceError.message("This message exceeds the 16 MiB text limit.") }
        budget.bytesRemaining -= bytes.count
        let encoding = Self.charset(part.header("Content-Type"))
        guard let text = String(data: bytes, encoding: encoding) else { throw UniversityServiceError.message("The message character encoding could not be read.") }
        let value = (part.type == "text/html" ? try Self.visibleHTML(text) : text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func charset(_ contentType: String?) -> String.Encoding {
        for field in (contentType ?? "").split(separator: ";").dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, pair[0].lowercased() == "charset" else { continue }
            let name = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)) }
        }
        return .utf8
    }

    private static func visibleHTML(_ html: String) throws -> String {
        // Parse a local DOM only. Reading mail must never load remote images, styles, or frames.
        let document = try XMLDocument(data: Data(html.utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let omitted: Set<String> = ["head", "script", "style", "iframe", "object", "template", "noscript"]
        let blocks: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "blockquote"]
        var text = ""
        func append(_ node: XMLNode, depth: Int) {
            guard depth < 128 else { return }
            if node.kind == .text { text += node.stringValue ?? ""; return }
            guard let element = node as? XMLElement else { return }
            let tag = element.localName?.lowercased() ?? ""
            guard !omitted.contains(tag) else { return }
            if blocks.contains(tag), !text.hasSuffix("\n") { text += "\n" }
            for child in element.children ?? [] { append(child, depth: depth + 1) }
            if tag == "a", let href = element.attribute(forName: "href")?.stringValue,
               let url = URL(string: href), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
               element.stringValue != href { text += " (\(href))" }
            if blocks.contains(tag), !text.hasSuffix("\n") { text += "\n" }
        }
        if let root = document.rootElement() { append(root, depth: 0) }
        return text
    }

    private static func filename(_ title: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let clean = title.components(separatedBy: forbidden).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in clean {
            if result.utf8.count + String(character).utf8.count > 200 { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
    }
}
