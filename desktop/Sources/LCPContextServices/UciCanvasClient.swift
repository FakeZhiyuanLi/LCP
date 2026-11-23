import Foundation
import LCPContextCore

public enum CanvasItemKind: String, CaseIterable, Sendable {
    case assignments, quizzes, files, pages, syllabus, modules
    case discussionTopics = "discussion_topics"
    case announcements
    case calendarEvents = "calendar_events"

    public var displayName: String {
        switch self {
        case .assignments: "Assignments"
        case .quizzes: "Quizzes"
        case .files: "Files"
        case .pages: "Pages"
        case .syllabus: "Syllabus"
        case .modules: "Modules"
        case .discussionTopics: "Discussions"
        case .announcements: "Announcements"
        case .calendarEvents: "Calendar events"
        }
    }
}

/// Reads the student's UCI Canvas courses through the tenant's Canvas LMS REST API.
public struct UciCanvasClient: Sendable {
    private static let host = "canvas.eee.uci.edu"
    private static let origin = URL(string: "https://canvas.eee.uci.edu")!
    private static let fileHosts: Set<String> = [
        host, "*.instructure.com", "*.instructureusercontent.com", "*.amazonaws.com",
        "*.cloudfront.net", "storage.googleapis.com", "*.storage.googleapis.com",
    ]
    private let token: String
    private let http: UniversityHTTP

    public init(token: String, http: UniversityHTTP = .init()) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
    }

    public func courses(cursor: String? = nil) async throws -> UniversityPage {
        try await list("courses", cursor: cursor, query: [
            URLQueryItem(name: "enrollment_type", value: "student"),
            URLQueryItem(name: "enrollment_state", value: "active"),
        ]) { (course: Course) in
            guard let title = course.name, !title.isEmpty else { return nil }
            return UniversityItem(id: String(course.id), title: title, detail: course.course_code ?? "",
                                 metadata: ["courseCode": course.course_code ?? ""])
        }
    }

    /// Read all active student courses with a bounded pagination walk.
    public func allCourses(maximum: Int = 500) async throws -> [UniversityItem] {
        guard (1...1_000).contains(maximum) else {
            throw UniversityServiceError.message("The Canvas course limit is invalid.")
        }
        var result: [UniversityItem] = []
        var cursor: String?
        var seen: Set<String> = []
        while true {
            let page = try await courses(cursor: cursor)
            result.append(contentsOf: page.items.prefix(maximum - result.count))
            guard result.count < maximum, let next = page.next else { return result }
            guard seen.insert(next).inserted else {
                throw UniversityServiceError.message("Canvas returned too many or repeated course pages. Open University Services to retry manually.")
            }
            cursor = next
        }
    }

    public func items(courseID: String, kind: CanvasItemKind, cursor: String? = nil) async throws -> UniversityPage {
        let path = try collection(courseID, kind)
        switch kind {
        case .assignments:
            return try await list(path, cursor: cursor) { (a: Assignment) in
                UniversityItem(id: String(a.id), title: a.name, detail: a.due_at.map { "Due \($0)" } ?? "Assignment")
            }
        case .quizzes:
            return try await optionalList(path, cursor: cursor) { (quiz: Quiz) in
                guard quiz.published != false, quiz.locked_for_user != true else { return nil }
                return UniversityItem(id: String(quiz.id), title: quiz.title,
                                      detail: quiz.due_at.map { "Due \($0)" } ?? "Quiz")
            }
        case .files:
            return try await list(path, cursor: cursor) { (f: FileRecord) in
                guard f.locked_for_user != true, f.hidden_for_user != true else { return nil }
                let detail = f.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return UniversityItem(id: String(f.id), title: f.display_name ?? f.filename, detail: detail ?? "File")
            }
        case .pages:
            return try await optionalList(path, cursor: cursor) { (page: WikiPage) in
                guard let slug = Self.validPageSlug(page.url) else { return nil }
                return UniversityItem(id: String(page.page_id), title: page.title, detail: "Course page",
                                      metadata: ["pageSlug": slug])
            }
        case .syllabus:
            let course = try await syllabus(courseID: courseID)
            guard let body = course.syllabus_body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UniversityPage(items: [])
            }
            return UniversityPage(items: [UniversityItem(id: courseID, title: "\(course.name ?? "Course") syllabus",
                                                        detail: "Course syllabus")])
        case .modules:
            return try await optionalList(path, cursor: cursor) { (module: Module) in
                let detail = module.items_count.map { "\($0) module items" } ?? "Module"
                let locked = module.state == "locked"
                return UniversityItem(id: String(module.id), title: module.name, detail: locked ? "Locked in Canvas" : detail,
                                      metadata: locked ? ["locked": "true"] : [:])
            }
        case .discussionTopics:
            return try await list(path, cursor: cursor) { (topic: DiscussionTopic) in
                guard topic.locked_for_user != true else { return nil }
                let detail = topic.posted_at.map { "Posted \($0)" } ??
                    topic.due_at.map { "Due \($0)" } ?? "Discussion"
                return UniversityItem(id: String(topic.id), title: topic.title, detail: detail)
            }
        case .announcements:
            let discussionPath = try collection(courseID, .discussionTopics)
            return try await list(discussionPath, cursor: cursor,
                                  query: [URLQueryItem(name: "only_announcements", value: "true")]) { (topic: DiscussionTopic) in
                guard topic.locked_for_user != true else { return nil }
                let detail = topic.posted_at.map { "Posted \($0)" } ?? "Announcement"
                return UniversityItem(id: String(topic.id), title: topic.title, detail: detail)
            }
        case .calendarEvents:
            let calendarPath = "calendar_events"
            return try await optionalList(calendarPath, cursor: cursor,
                                  query: [URLQueryItem(name: "context_codes[]", value: "course_\(courseID)")]) { (event: CalendarEvent) in
                guard event.contextCode == "course_\(courseID)" || event.effectiveContextCode == "course_\(courseID)" else { return nil }
                let detail = [event.startAt.map { "Starts \($0)" }, event.endAt.map { "Ends \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                return UniversityItem(id: String(event.id), title: event.title, detail: detail.isEmpty ? "Calendar event" : detail)
            }
        }
    }

    /// Read all visible items in one course and collection with a hard bound.
    /// Automatic refresh uses this instead of exposing an unbounded pagination
    /// loop to the scheduler.
    public func allItems(courseID: String, kind: CanvasItemKind, maximum: Int = 500) async throws -> [UniversityItem] {
        guard (1...1_000).contains(maximum) else {
            throw UniversityServiceError.message("The Canvas item limit is invalid.")
        }
        var result: [UniversityItem] = []
        var cursor: String?
        var seen: Set<String> = []
        while true {
            let page = try await items(courseID: courseID, kind: kind, cursor: cursor)
            result.append(contentsOf: page.items.prefix(maximum - result.count))
            guard result.count < maximum, let next = page.next else { return result }
            guard seen.insert(next).inserted else {
                throw UniversityServiceError.message("Canvas returned too many or repeated \(kind.displayName.lowercased()) pages. Open University Services to retry manually.")
            }
            cursor = next
        }
    }

    public func moduleItems(courseID: String, moduleID: String, cursor: String? = nil) async throws -> UniversityPage {
        let path = try collection(courseID, .modules) + "/\(numericID(moduleID))/items"
        return try await list(path, cursor: cursor, query: Self.contentDetails) { (entry: ModuleItem) in
            guard String(entry.module_id) == moduleID else { return nil }
            return entry.row
        }
    }

    public func document(courseID: String, kind selection: CanvasItemKind, item: UniversityItem) async throws -> UniversityDocument {
        let selectedID = try numericID(item.id)
        var kind = selection
        var key = selection == .pages ? "page_id:\(selectedID)" : selectedID
        if selection == .modules {
            // Refresh this specific membership before importing; a module can be reordered, relinked or locked.
            guard let moduleID = item.metadata["moduleID"] else { throw Self.changed }
            let modulePath = try collection(courseID, .modules) + "/\(numericID(moduleID))/items/\(selectedID)"
            let url = Self.origin.appendingPathComponent("api/v1/\(modulePath)").appending(queryItems: Self.contentDetails)
            let refreshed: ModuleItem = try await record(url)
            guard String(refreshed.id) == selectedID, String(refreshed.module_id) == moduleID else { throw Self.changed }
            if let externalURL = refreshed.externalURL {
                guard item.metadata["canvasKind"] == "external_url",
                      item.metadata["sourceID"] == externalURL.absoluteString else { throw Self.changed }
                return try externalDocument(title: refreshed.title, source: externalURL,
                                            remoteID: "\(courseID)/modules/\(moduleID)/items/\(refreshed.id)")
            }
            guard let target = refreshed.target, item.metadata["canvasKind"] == target.kind.rawValue,
                  item.metadata["sourceID"] == target.key else { throw Self.changed }
            kind = target.kind
            key = target.key
        }
        let path: String
        switch kind {
        case .announcements:
            path = try collection(courseID, .discussionTopics)
        case .calendarEvents:
            path = "calendar_events"
        default:
            path = try collection(courseID, kind)
        }
        let resourceKey: String
        if kind == .pages {
            // Canvas addresses pages by their URL slug. The page ID from the
            // listing remains the stable identity we revalidate after fetch.
            let rawSlug = selection == .pages ? item.metadata["pageSlug"] : key
            guard let slug = Self.validPageSlug(rawSlug) else { throw Self.changed }
            resourceKey = slug
        } else {
            resourceKey = key
        }
        let apiURL = Self.origin.appendingPathComponent("api/v1/\(path)/\(resourceKey)")
        let web = Self.origin.appendingPathComponent(path)
        switch kind {
        case .assignments:
            let a: Assignment = try await record(apiURL.appending(queryItems: [URLQueryItem(name: "include[]", value: "submission")]))
            guard String(a.id) == key, (a.course_id.map(String.init) ?? courseID) == courseID else { throw Self.changed }
            guard a.locked_for_user != true else { throw Self.locked }
            let due = a.due_at.map { "Due: \($0)" }
            let status = a.submission?.state
            let subtitle = [due, status.map { "Canvas submission: " + $0.rawValue }].compactMap { $0 }.joined(separator: "\n")
            return try textDocument(title: a.name, subtitle: subtitle.isEmpty ? nil : subtitle, html: a.description, source: web.appendingPathComponent(key),
                                    remoteID: "\(courseID)/assignments/\(a.id)",
                                    courseworkContext: ImportedCourseworkContext(title: a.name, dueAt: try Self.deadline(a.due_at), submissionState: status))
        case .quizzes:
            let quiz: Quiz = try await record(apiURL)
            guard String(quiz.id) == key, (quiz.course_id.map(String.init) ?? courseID) == courseID else { throw Self.changed }
            guard quiz.published != false, quiz.locked_for_user != true else { throw Self.locked }
            let due = quiz.due_at.map { "Due: \($0)" }
            return try textDocument(title: quiz.title, subtitle: due, html: quiz.description,
                                    source: web.appendingPathComponent(key),
                                    remoteID: "\(courseID)/quizzes/\(quiz.id)",
                                    courseworkContext: ImportedCourseworkContext(title: quiz.title, kind: "quiz", dueAt: try Self.deadline(quiz.due_at),
                                                                                 assignmentID: quiz.assignment_id))
        case .pages:
            let page: WikiPage = try await record(apiURL)
            guard let slug = Self.validPageSlug(page.url), slug == resourceKey else { throw Self.changed }
            if selection == .pages {
                guard String(page.page_id) == selectedID else { throw Self.changed }
            }
            guard page.locked_for_user != true else { throw Self.locked }
            return try textDocument(title: page.title, subtitle: nil, html: page.body, source: web.appendingPathComponent(slug),
                                    remoteID: "\(courseID)/pages/\(page.page_id)")
        case .files:
            let f: FileRecord = try await record(apiURL)
            guard String(f.id) == key else { throw Self.changed }
            guard f.locked_for_user != true, f.hidden_for_user != true else { throw Self.locked }
            guard let raw = f.url, let url = URL(string: raw), url.scheme == "https" else {
                throw UniversityServiceError.message("Canvas did not provide a download address for this file.")
            }
            let maximum = MaterialService.maximumOriginalBytes
            if let size = f.size, size > maximum {
                throw UniversityServiceError.message("This Canvas file exceeds the 32 MiB material import limit.")
            }
            let (bytes, response) = try await http.get(url, bearer: url.host?.lowercased() == Self.host ? token : nil,
                                                       allowedHosts: Self.fileHosts, limit: maximum)
            if let size = f.size, size != bytes.count {
                throw UniversityServiceError.message("The download size differs from Canvas’s file record. Refresh the file list and try again.")
            }
            if response.mimeType == "text/html", f.contentType?.lowercased().hasPrefix("text/html") != true,
               !["html", "htm"].contains((f.filename as NSString).pathExtension.lowercased()) {
                throw UniversityServiceError.message("Canvas returned a web page instead of the requested file.")
            }
            return UniversityDocument(filename: filename(f.filename, fallback: "Canvas file"), data: bytes,
                                      sourceURL: web.appendingPathComponent(key), remoteID: "\(courseID)/files/\(f.id)")
        case .syllabus:
            guard key == courseID else { throw Self.changed }
            let course = try await syllabus(courseID: courseID)
            guard let body = course.syllabus_body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UniversityServiceError.message("This course no longer has a published syllabus.")
            }
            return try textDocument(title: "\(course.name ?? "Course") syllabus", subtitle: nil, html: body,
                                    source: Self.origin.appendingPathComponent("courses/\(courseID)/assignments/syllabus"),
                                    remoteID: "\(courseID)/syllabus/\(courseID)")
        case .modules:
            throw UniversityServiceError.message("Select a file, page, or assignment within the module.")
        case .discussionTopics:
            let topic: DiscussionTopic = try await record(apiURL)
            guard String(topic.id) == key,
                  (topic.course_id.map(String.init) ?? courseID) == courseID else { throw Self.changed }
            guard topic.locked_for_user != true else { throw Self.locked }
            return try textDocument(title: topic.title,
                                    subtitle: topic.posted_at.map { "Posted: \($0)" },
                                    html: topic.message,
                                    source: web.appendingPathComponent(key),
                                    remoteID: "\(courseID)/discussion_topics/\(topic.id)")
        case .announcements:
            let topic: DiscussionTopic = try await record(apiURL)
            guard String(topic.id) == key,
                  (topic.course_id.map(String.init) ?? courseID) == courseID else { throw Self.changed }
            guard topic.locked_for_user != true else { throw Self.locked }
            return try textDocument(title: topic.title,
                                    subtitle: topic.posted_at.map { "Posted: \($0)" },
                                    html: topic.message,
                                    source: web.appendingPathComponent(key),
                                    remoteID: "\(courseID)/announcements/\(topic.id)")
        case .calendarEvents:
            let event: CalendarEvent = try await record(apiURL)
            guard String(event.id) == key,
                  event.contextCode == "course_\(courseID)" || event.effectiveContextCode == "course_\(courseID)" else {
                throw Self.changed
            }
            let subtitle = [event.startAt.map { "Starts: \($0)" }, event.endAt.map { "Ends: \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            let body = [event.description, event.locationName.map { "Location: \($0)" },
                        event.locationAddress.map { "Address: \($0)" }].compactMap { $0 }.joined(separator: "\n")
            let source = event.htmlURL.flatMap(URL.init(string:)) ?? Self.origin.appendingPathComponent("calendar")
            return try textDocument(title: event.title, subtitle: subtitle.isEmpty ? nil : subtitle,
                                    html: body, source: source,
                                    remoteID: "\(courseID)/calendar_events/\(event.id)")
        }
    }

    private static var changed: UniversityServiceError { .message("Canvas returned a different item. Refresh the course list and select it again.") }
    private static var locked: UniversityServiceError { .message("This material is currently locked in Canvas.") }
    private static var contentDetails: [URLQueryItem] { [URLQueryItem(name: "include[]", value: "content_details")] }

    private static func validPageSlug(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 2_048,
              raw != ".", raw != "..", raw.rangeOfCharacter(from: .controlCharacters) == nil,
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              raw.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#%")) == nil else { return nil }
        return raw
    }

    private func numericID(_ value: String) throws -> String {
        guard let number = Int64(value), number > 0, String(number) == value else {
            throw UniversityServiceError.message("Canvas returned an invalid course or item identifier.")
        }
        return value
    }

    private func collection(_ courseID: String, _ kind: CanvasItemKind) throws -> String {
        "courses/\(try numericID(courseID))/\(kind.rawValue)"
    }

    private func syllabus(courseID: String) async throws -> Course {
        let url = Self.origin.appendingPathComponent("api/v1/courses/\(try numericID(courseID))")
            .appending(queryItems: [URLQueryItem(name: "include[]", value: "syllabus_body")])
        let result: Course = try await record(url)
        guard String(result.id) == courseID else { throw Self.changed }
        return result
    }

    private func api(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        guard !token.isEmpty else { throw UniversityServiceError.message("Enter your UCI Canvas access token to connect.") }
        return try await http.get(url, bearer: token, allowedHosts: [Self.host])
    }

    private func record<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await api(url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func list<Row: Decodable>(_ path: String, cursor: String?, query: [URLQueryItem] = [],
                                      item: (Row) -> UniversityItem?) async throws -> UniversityPage {
        let base = Self.origin.appendingPathComponent("api/v1/\(path)")
        var initial = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        initial.queryItems = query + [URLQueryItem(name: "per_page", value: "50")]
        let url = try cursor.map { try pageURL($0, base: base) } ?? initial.url!
        let (data, response) = try await api(url)
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let next = try nextLink(response.value(forHTTPHeaderField: "Link"), base: base)
        return UniversityPage(items: rows.compactMap(item), next: next)
    }

    private func optionalList<Row: Decodable>(_ path: String, cursor: String?, query: [URLQueryItem] = [],
                                              item: @escaping (Row) -> UniversityItem?) async throws -> UniversityPage {
        do {
            return try await list(path, cursor: cursor, query: query, item: item)
        } catch let error as UniversityServiceError {
            // Canvas returns 404 when an optional course feature is disabled.
            // An empty collection keeps the course browser usable while 401,
            // 403, rate-limit, and transport failures remain visible.
            if case .http(404) = error { return UniversityPage(items: []) }
            throw error
        }
    }

    // Canvas supplies an opaque absolute URL. Bind it to its originating collection before sending the token.
    private func pageURL(_ raw: String, base: URL) throws -> URL {
        guard raw.utf8.count <= 16_384, let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == Self.host,
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.percentEncodedPath == base.path,
              !(parts.queryItems ?? []).contains(where: { $0.name.lowercased() == "access_token" }),
              let url = parts.url else {
            throw UniversityServiceError.message("Canvas returned an unexpected pagination address. Refresh the current course or list.")
        }
        return url
    }

    private func nextLink(_ header: String?, base: URL) throws -> String? {
        guard let header else { return nil }
        // Link targets are enclosed in angle brackets. An opaque URL can itself contain commas.
        let pattern = #"<([^>]+)>\s*((?:;\s*[^,<]+)*)"#
        let matches = try NSRegularExpression(pattern: pattern).matches(in: header, range: NSRange(header.startIndex..., in: header))
        for match in matches {
            guard let parameters = Range(match.range(at: 2), in: header),
                  header[parameters].range(of: #";\s*rel\s*=\s*(?:"next"|next)(?:\s*;|\s*$)"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil,
                  let target = Range(match.range(at: 1), in: header) else { continue }
            return try pageURL(String(header[target]), base: base).absoluteString
        }
        return nil
    }

    private func filename(_ source: String, fallback: String) -> String {
        let illegal = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let clean = source.components(separatedBy: illegal).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? fallback : clean
    }

    private static func deadline(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        // Canvas deadlines are instants, including an explicit timezone. Never use
        // the Mac's current zone or turn a malformed source date into "no deadline".
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: value) else {
            throw UniversityServiceError.message("Canvas returned an invalid deadline. Open the assignment in Canvas before saving coursework.")
        }
        return date
    }

    private func textDocument(title: String, subtitle: String?, html: String?, source: URL, remoteID: String,
                              courseworkContext: ImportedCourseworkContext? = nil) throws -> UniversityDocument {
        let body = try Self.visibleText(html ?? "", source: source)
        let text = [title, subtitle, source.absoluteString, "", body].compactMap { $0 }.joined(separator: "\n")
        return UniversityDocument(filename: filename(title, fallback: "Canvas material") + ".txt",
                                  data: Data(text.utf8), sourceURL: source, remoteID: remoteID, courseworkContext: courseworkContext)
    }

    private func externalDocument(title: String, source: URL, remoteID: String) throws -> UniversityDocument {
        let text = [title, "Canvas external link", source.absoluteString].joined(separator: "\n")
        return UniversityDocument(filename: filename(title, fallback: "Canvas external link") + ".txt",
                                  data: Data(text.utf8), sourceURL: source, remoteID: remoteID)
    }

    /// Parse Canvas rich text as an inert document. Rendering it in a web view could fetch embedded resources.
    private static func visibleText(_ html: String, source: URL) throws -> String {
        guard !html.isEmpty else { return "" }
        let document = try XMLDocument(xmlString: "<html><body>\(html)</body></html>",
                                       options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let blocks: Set<String> = ["p", "li", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6",
                                   "tr", "ul", "ol", "table", "blockquote", "pre"]
        var text = ""
        func append(_ node: XMLNode) {
            if node.kind == .text { text += node.stringValue ?? ""; return }
            guard let element = node as? XMLElement else { return }
            let tag = element.name?.lowercased() ?? ""
            guard !["script", "style", "head", "iframe", "object"].contains(tag) else { return }
            let block = blocks.contains(tag)
            if block || tag == "br" { text += "\n" }
            if tag == "img", let alt = element.attribute(forName: "alt")?.stringValue { text += alt }
            for child in element.children ?? [] { append(child) }
            if tag == "a", let href = element.attribute(forName: "href")?.stringValue,
               let target = publicLink(href, source: source), element.stringValue != target { text += " (\(target))" }
            if tag == "td" || tag == "th" { text += "\t" }
            if block { text += "\n" }
        }
        if let root = document.rootElement() { append(root) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func publicLink(_ href: String, source: URL) -> String? {
        guard !href.isEmpty, let url = URL(string: href, relativeTo: source)?.absoluteURL,
              var link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
              link.host != nil, link.user == nil, link.password == nil else { return nil }
        // Canvas attachment links can carry a temporary verifier. Keep the ordinary
        // sign-in URL instead, and omit externally signed download links.
        let params = link.queryItems ?? []
        let sensitive = { (name: String) in
            ["verifier", "access_token", "signature", "sig", "token"].contains(name.lowercased()) ||
                name.lowercased().hasPrefix("x-amz-") || name.lowercased().hasPrefix("x-goog-")
        }
        if params.contains(where: { sensitive($0.name) }) {
            guard link.host?.lowercased() == host else { return nil }
            let retained = params.filter { !sensitive($0.name) }
            link.queryItems = retained.isEmpty ? nil : retained
        }
        return link.url?.absoluteString
    }

    private struct Course: Decodable {
        let id: Int64
        let name, course_code, syllabus_body: String?
    }
    private struct Assignment: Decodable {
        let id: Int64
        let course_id: Int64?
        let name: String
        let description, due_at: String?
        let locked_for_user: Bool?
        let submission: Submission?
    }
    private struct Submission: Decodable {
        let workflow_state: String?
        let excused, missing: Bool?

        var state: CanvasSubmissionState? {
            if excused == true { return .excused }
            if workflow_state == "pending_review" || workflow_state == "submitted" { return .submitted }
            // A recorded zero can be both graded and explicitly marked missing.
            if missing == true { return .missing }
            return workflow_state.flatMap(CanvasSubmissionState.init(rawValue:))
        }
    }
    private struct Quiz: Decodable {
        let id: Int64
        let assignment_id: Int64?
        let course_id: Int64?
        let title: String
        let description, due_at: String?
        let published, locked_for_user: Bool?
    }
    private struct WikiPage: Decodable {
        let page_id: Int64
        let title: String
        let url, body: String?
        let locked_for_user: Bool?
    }
    private struct Module: Decodable {
        let id: Int64
        let name: String
        let items_count: Int?
        let state: String?
    }
    private struct ModuleItem: Decodable {
        struct Details: Decodable { let locked_for_user: Bool? }
        let id, module_id: Int64
        let title, type: String
        let content_id: Int64?
        let page_url: String?
        let external_url: String?
        let published: Bool?
        let content_details: Details?

        var locked: Bool { published == false || content_details?.locked_for_user == true }
        var externalURL: URL? {
            guard !locked, type.lowercased() == "externalurl", let external_url,
                  external_url.utf8.count <= 8_192,
                  let parts = URLComponents(string: external_url),
                  parts.scheme?.lowercased() == "https", parts.host != nil,
                  parts.user == nil, parts.password == nil, parts.fragment == nil,
                  let url = Self.sanitizedExternalURL(parts) else { return nil }
            return url
        }

        private static func sanitizedExternalURL(_ parts: URLComponents) -> URL? {
            let sensitive = { (name: String) in
                ["access_token", "auth", "password", "secret", "signature", "sig", "token"].contains(name.lowercased()) ||
                    name.lowercased().hasPrefix("x-amz-") || name.lowercased().hasPrefix("x-goog-")
            }
            guard !(parts.queryItems ?? []).contains(where: { sensitive($0.name) }) else { return nil }
            return parts.url
        }

        var target: (kind: CanvasItemKind, key: String)? {
            guard !locked else { return nil }
            if type == "Page", let slug = UciCanvasClient.validPageSlug(page_url) { return (.pages, slug) }
            guard let id = content_id, id > 0 else { return nil }
            switch type {
            case "File": return (.files, String(id))
            case "Assignment": return (.assignments, String(id))
            case "Quiz": return (.quizzes, String(id))
            case "Discussion": return (.discussionTopics, String(id))
            case "Page": return (.pages, "page_id:\(id)")
            default: return nil
            }
        }

        var row: UniversityItem {
            var metadata = ["moduleID": String(module_id)]
            let detail: String
            if let target {
                detail = type
                metadata["canvasKind"] = target.kind.rawValue
                metadata["sourceID"] = target.key
            } else if let externalURL {
                detail = "External link"
                metadata["canvasKind"] = "external_url"
                metadata["sourceID"] = externalURL.absoluteString
            } else {
                detail = locked ? "Locked in Canvas" : (type == "SubHeader" ? "Module heading" : "\(type) · View in Canvas")
            }
            return UniversityItem(id: String(id), title: title, detail: detail, metadata: metadata)
        }
    }
    private struct DiscussionTopic: Decodable {
        let id: Int64
        let course_id: Int64?
        let title: String
        let message, posted_at, due_at: String?
        let locked_for_user: Bool?
    }
    private struct CalendarEvent: Decodable {
        let id: Int64
        let title: String
        let description, startAt, endAt: String?
        let contextCode, effectiveContextCode: String?
        let locationName, locationAddress, htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case id, title, description
            case startAt = "start_at"
            case endAt = "end_at"
            case contextCode = "context_code"
            case effectiveContextCode = "effective_context_code"
            case locationName = "location_name"
            case locationAddress = "location_address"
            case htmlURL = "html_url"
        }
    }
    private struct FileRecord: Decodable {
        let id: Int64
        let filename: String
        let display_name, url, contentType: String?
        let size: Int64?
        let locked_for_user, hidden_for_user: Bool?
        enum CodingKeys: String, CodingKey {
            case id, filename, display_name, url, size, locked_for_user, hidden_for_user
            case contentType = "content-type"
        }
    }
}
