import Foundation
import LCPContextCore

public struct CanvasCourseMatch: Equatable, Identifiable, Sendable {
    public let classID: UUID
    public let canvasCourseID: String
    public let title: String
    public let courseCode: String
    public let basis: String

    public var id: UUID { classID }

    public init(classID: UUID, canvasCourseID: String, title: String, courseCode: String, basis: String) {
        self.classID = classID
        self.canvasCourseID = canvasCourseID
        self.title = title
        self.courseCode = courseCode
        self.basis = basis
    }
}

public struct CanvasCourseMatchingResult: Sendable {
    public let matches: [CanvasCourseMatch]
    public let unmatched: [String]

    public init(matches: [CanvasCourseMatch], unmatched: [String]) {
        self.matches = matches
        self.unmatched = unmatched
    }
}

public struct CanvasCourseworkSource: Sendable {
    public let match: CanvasCourseMatch
    public let kind: CanvasItemKind
    public let item: UniversityItem
    public let document: UniversityDocument

    public init(match: CanvasCourseMatch, kind: CanvasItemKind, item: UniversityItem, document: UniversityDocument) {
        self.match = match
        self.kind = kind
        self.item = item
        self.document = document
    }
}

public struct CanvasCourseworkSyncBatch: Sendable {
    public let sources: [CanvasCourseworkSource]
    public let skipped: [String]

    public init(sources: [CanvasCourseworkSource], skipped: [String]) {
        self.sources = sources
        self.skipped = skipped
    }
}

/// Matches local classes to active Canvas courses and fetches bounded, visible
/// course context for automatic refresh. It never writes to Canvas.
public struct CanvasCourseworkSyncService: Sendable {
    public static let automaticKinds: [CanvasItemKind] = [.assignments, .quizzes, .announcements, .calendarEvents]

    public init() {}

    public static func match(classes: [ClassEnrollment], courses: [UniversityItem]) -> CanvasCourseMatchingResult {
        let usableCourses = courses.filter { Int64($0.id).map { $0 > 0 } ?? false }
        var claimedCourseIDs: Set<String> = []
        var matches: [CanvasCourseMatch] = []
        var unmatched: [String] = []

        for enrollment in classes where !enrollment.archived {
            let label = enrollment.displayLabel
            let explicit = enrollment.canvasCourseID.flatMap { id in usableCourses.first { $0.id == id } }
            if enrollment.canvasCourseID != nil {
                guard let course = explicit else {
                    unmatched.append("\(label) is linked to a Canvas course that is no longer active")
                    continue
                }
                if claimedCourseIDs.insert(course.id).inserted {
                    matches.append(CanvasCourseMatch(classID: enrollment.id, canvasCourseID: course.id,
                                                     title: course.title, courseCode: course.detail,
                                                     basis: "saved Canvas course"))
                } else {
                    unmatched.append("\(label) has a Canvas course already linked to another class")
                }
                continue
            }

            let code = normalizedCourseCode(enrollment.courseCode)
            let codeMatches = code.isEmpty ? [] : usableCourses.filter { normalizedCourseCode($0.detail) == code }
            let title = normalized(enrollment.title)
            let titleMatches = title.isEmpty ? [] : usableCourses.filter { normalized($0.title) == title }
            let candidates: ([UniversityItem], String)
            if codeMatches.count == 1 {
                candidates = (codeMatches, "course code")
            } else if codeMatches.count > 1 {
                candidates = (codeMatches, "course code")
            } else if titleMatches.count == 1 {
                candidates = (titleMatches, "class name")
            } else {
                candidates = (titleMatches, "class name")
            }

            guard candidates.0.count == 1, let course = candidates.0.first,
                  claimedCourseIDs.insert(course.id).inserted else {
                unmatched.append("\(label) has no unique Canvas course match")
                continue
            }
            matches.append(CanvasCourseMatch(classID: enrollment.id, canvasCourseID: course.id,
                                             title: course.title, courseCode: course.detail,
                                             basis: candidates.1))
        }
        return CanvasCourseMatchingResult(matches: matches, unmatched: unmatched)
    }

    public func fetch(client: UciCanvasClient, matches: [CanvasCourseMatch], maximumItemsPerKind: Int = 250) async throws -> CanvasCourseworkSyncBatch {
        var sources: [CanvasCourseworkSource] = []
        var skipped: [String] = []
        for match in matches {
            for kind in Self.automaticKinds {
                try Task.checkCancellation()
                let items: [UniversityItem]
                do {
                    items = try await client.allItems(courseID: match.canvasCourseID, kind: kind, maximum: maximumItemsPerKind)
                } catch let error as UniversityServiceError {
                    if Self.shouldAbort(error) { throw error }
                    skipped.append("\(match.title) · \(kind.displayName): \(error.localizedDescription)")
                    continue
                }
                for item in items {
                    try Task.checkCancellation()
                    do {
                        let document = try await client.document(courseID: match.canvasCourseID, kind: kind, item: item)
                        sources.append(CanvasCourseworkSource(match: match, kind: kind, item: item, document: document))
                    } catch let error as UniversityServiceError {
                        if Self.shouldAbort(error) { throw error }
                        skipped.append("\(match.title) · \(item.title): \(error.localizedDescription)")
                    }
                }
            }
        }
        return CanvasCourseworkSyncBatch(sources: sources, skipped: skipped)
    }

    private static func shouldAbort(_ error: UniversityServiceError) -> Bool {
        guard case .http(let status) = error else { return false }
        return [401, 403, 429].contains(status)
    }

    private static func normalized(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    /// UCI commonly exposes Information & Computer Science as `I&C SCI` in
    /// Canvas while the local class catalog uses `ICS`. Treat that registrar
    /// spelling as the same exact course-code identity after normalization.
    private static func normalizedCourseCode(_ raw: String) -> String {
        let value = normalized(raw)
        if value.hasPrefix("icsci") { return "ics" + String(value.dropFirst(5)) }
        return value
    }
}
