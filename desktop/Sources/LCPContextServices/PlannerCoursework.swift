import Foundation
import LCPContextCore

/// One named piece of evidence in this request. The provider refers to its
/// position; LCP owns the displayed class, dates, and exact source link.
public struct PlannerSource: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let classLabel: String
    public let title: String
    public let kind: String
    public let timing: String?
    public let progress: String?
    public let citation: SourceCitation?
    public var excerpt: String

    public var isCoursework: Bool { timing != nil }

    func relevance(to terms: [String]) -> Int {
        let titleMatches = ChatEvidence.matches(terms, in: classLabel + " " + title).count
        return 2 * titleMatches + ChatEvidence.matches(terms, in: excerpt).count
    }
}

struct PlannerCoursework {
    let id: UUID
    let course: ClassEnrollment
    let title: String
    let kind: String
    let zone: TimeZone
    let due: AcademicDeadline?
    let canvas: CanvasSubmissionState?
    let personal: [String]
    let citation: SourceCitation?
    let sourceURL: URL?

    private var optional: Bool {
        title.lowercased().split(whereSeparator: { !$0.isLetter }).contains("optional")
    }

    private var explicitlyOpen: Bool {
        canvas == .unsubmitted || canvas == .missing || personal.contains("in_progress") || personal.contains("not_started")
    }

    private var finished: Bool {
        [.submitted, .graded, .excused].contains(canvas) || !Set(personal).isDisjoint(with: ["submitted", "graded", "completed"])
    }

    func deadline(at now: Date) -> (date: Date?, past: Bool, label: String) {
        switch due {
        case nil:
            return (nil, false, "No due date listed")
        case let .timed(instant, timeZoneID):
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeZone = TimeZone(identifier: timeZoneID) ?? zone
            formatter.setLocalizedDateFormatFromTemplate("EEE MMM d yyyy jmm z")
            return (instant, instant < now, (instant < now ? "Due date passed · " : "Due ") + formatter.string(from: instant))
        case .dateOnly(let day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
            let past = date.map { calendar.compare($0, to: now, toGranularity: .day) == .orderedAscending } ?? false
            let label = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
            return (date, past, (past ? "Due date passed · " : "Due ") + label + " · date only")
        }
    }

    var statusLabel: String {
        var labels: [String] = []
        if let canvas { labels.append("Canvas: " + canvas.rawValue) }
        if !personal.isEmpty { labels.append("LCP: " + personal.joined(separator: ", ").replacingOccurrences(of: "_", with: " ")) }
        return labels.isEmpty ? "Submission status unknown" : labels.joined(separator: " · ")
    }

    func source(at now: Date, excerpt: String = "") -> PlannerSource {
        PlannerSource(id: id, classLabel: course.shortLabel, title: title, kind: kind, timing: deadline(at: now).label,
                      progress: statusLabel, citation: citation, excerpt: excerpt)
    }

    /// Unknown completion after a past deadline is not evidence of outstanding work.
    static func ranked(state: ContextState, classes: [ClassEnrollment], terms: [String], now: Date) -> [Self] {
        let byClass = Dictionary(uniqueKeysWithValues: classes.map { ($0.id, $0) })
        let zones = Dictionary(uniqueKeysWithValues: state.terms.map { ($0.id, $0.timeZoneID) })
        func zone(for course: ClassEnrollment) -> TimeZone {
            TimeZone(identifier: course.termID.flatMap { zones[$0] } ?? AcademicTerm.defaultTimeZoneID) ?? .current
        }
        let local = state.coursework.filter { byClass[$0.classID] != nil }
        let linked = Dictionary(grouping: local.compactMap { item in item.sourceCitation.map { ($0.sourceID, item) } }, by: \.0)
        let revisions = Dictionary(uniqueKeysWithValues: state.materialRevisions.map { ($0.id, $0) })
        let snapshots = state.materials.compactMap { material -> CanvasListing? in
            guard let course = byClass[material.classID], material.kind == "uci-canvas",
                  let revision = material.currentRevisionID.flatMap({ revisions[$0] }),
                  let facts = revision.courseworkContext, let source = revision.importedSource else { return nil }
            return CanvasListing(course: course, material: material, revision: revision, facts: facts, url: source.url)
        }

        var rows: [Self] = []
        var consumed = Set<UUID>()
        for listings in CanvasListing.grouped(snapshots) {
            let first = listings[0]
            let saved = listings.flatMap { linked[$0.material.id, default: []].map(\.1) }
            consumed.formUnion(saved.map(\.id))
            let zone = zone(for: first.course)
            let revision = first.revision
            let citation = SourceCitation(id: revision.id, classID: first.course.id, sourceKind: "material",
                sourceID: first.material.id, revisionID: revision.id, payloadSHA256: revision.text?.sha256 ?? revision.original.sha256,
                label: "\(first.facts.title) · Canvas revision \(revision.sequence)")
            rows.append(Self(id: first.material.id, course: first.course, title: first.facts.title,
                kind: listings.contains(where: { $0.facts.kind == "quiz" }) ? "quiz" : first.facts.kind, zone: zone,
                due: first.facts.dueAt.map { .timed(instant: $0, timeZoneID: zone.identifier) },
                canvas: first.facts.submissionState, personal: Array(Set(saved.map(\.status))).sorted(),
                citation: citation, sourceURL: first.url))
        }
        for item in local where !consumed.contains(item.id) {
            guard let course = byClass[item.classID] else { continue }
            rows.append(Self(id: item.id, course: course, title: item.title, kind: item.kind, zone: zone(for: course),
                due: item.due, canvas: nil, personal: [item.status], citation: item.sourceCitation, sourceURL: nil))
        }

        let week = now.addingTimeInterval(7 * 86_400)
        let ranked = rows.compactMap { row -> (row: Self, topic: Int, group: Int, order: Double)? in
            guard !row.finished else { return nil }
            let timing = row.deadline(at: now)
            guard !timing.past || row.explicitlyOpen else { return nil }
            let group: Int
            if row.optional { group = 4 }
            else if timing.past { group = 1 }
            else if let date = timing.date { group = date <= week ? 0 : 2 }
            else { group = 3 }
            let seconds = timing.date?.timeIntervalSinceReferenceDate ?? .greatestFiniteMagnitude
            let matches = ChatEvidence.matches(terms, in: "\(row.course.displayLabel) \(row.title)").count
            return (row, matches, group, timing.past ? -seconds : seconds)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.topic != rhs.topic { return lhs.topic > rhs.topic }
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return (lhs.row.title, lhs.row.id.uuidString) < (rhs.row.title, rhs.row.id.uuidString)
        }.map(\.row)
    }
}

private struct CanvasListing {
    let course: ClassEnrollment
    let material: SourceMaterial
    let revision: MaterialRevision
    let facts: ImportedCourseworkContext
    let url: URL

    private struct LegacyKey: Hashable {
        let course: UUID
        let canvasCourse: URL
        let title: String
        let due: Date?
    }

    static func grouped(_ listings: [Self]) -> [[Self]] {
        let assignments = listings.filter { $0.facts.kind == "assignment" }
        let quizzes = listings.filter { $0.facts.kind == "quiz" }
        func key(_ item: Self) -> LegacyKey {
            LegacyKey(course: item.course.id, canvasCourse: item.url.deletingLastPathComponent().deletingLastPathComponent(),
                      title: item.facts.title, due: item.facts.dueAt)
        }
        let byLegacyKey = Dictionary(grouping: assignments, by: key)
        let quizCounts = Dictionary(grouping: quizzes, by: key)
        var groups = Dictionary(uniqueKeysWithValues: assignments.map { ($0.material.id, [$0]) })
        for quiz in quizzes {
            let match: Self?
            if let parentID = quiz.facts.assignmentID {
                let parentURL = key(quiz).canvasCourse.appendingPathComponent("assignments").appendingPathComponent(String(parentID))
                match = assignments.first { $0.course.id == quiz.course.id && $0.url == parentURL }
            } else {
                // Older snapshots lack Canvas's parent ID. Pair only an unambiguous
                // assignment/quiz with the same course, title and exact non-nil deadline.
                let legacy = key(quiz)
                let candidates = byLegacyKey[legacy] ?? []
                match = legacy.due != nil && candidates.count == 1 && quizCounts[legacy]?.count == 1 ? candidates.first : nil
            }
            groups[match?.material.id ?? quiz.material.id, default: []].append(quiz)
        }
        return Array(groups.values)
    }
}
