import Foundation
import LCPContextCore

/// A local, explicit review. Preparing it never mutates coursework or contacts a service.
public struct CourseworkImportReview: Identifiable, Sendable {
    public let id: UUID
    public let proposed: CourseworkItem
    public let previous: CourseworkItem?
    public let source: SourceCitation
    public let sourceURL: URL
    public let sourceSequence: UInt64
    fileprivate let termID: UUID?
    fileprivate let timeZoneID: String
}

@MainActor
public struct CourseworkService {
    public let repository: ContextRepository
    public init(repository: ContextRepository) { self.repository = repository }

    public func reviewCanvasMaterial(_ materialID: UUID) throws -> CourseworkImportReview {
        try repository.refresh()
        let state = repository.state
        guard let material = state.materials.first(where: { $0.id == materialID && $0.kind == "uci-canvas" }),
              let revision = state.materialRevisions.first(where: { $0.id == material.currentRevisionID }),
              let context = revision.courseworkContext, let source = revision.importedSource,
              let enrollment = state.classes.first(where: { $0.id == material.classID }) else {
            throw UniversityServiceError.message("Import this Canvas assignment or quiz again to review its coursework facts.")
        }
        let timeZoneID = Self.timeZoneID(for: enrollment, in: state)
        let matches = state.coursework.filter {
            $0.classID == material.classID && $0.sourceCitation?.sourceID == materialID
        }
        guard matches.count <= 1 else { throw Self.changed }
        let previous = matches.first
        let citation = SourceCitation(classID: material.classID, sourceKind: "material", sourceID: material.id,
            revisionID: revision.id, payloadSHA256: revision.text?.sha256 ?? revision.original.sha256,
            label: "\(source.title) · Canvas revision \(revision.sequence)")
        // Resolve verified bytes now, then check the exact source again at commit.
        _ = try RetrievalService(repository: repository).resolve(citation)
        var proposed = previous ?? CourseworkItem(classID: material.classID, title: context.title)
        proposed.title = context.title
        proposed.kind = context.kind
        proposed.due = context.dueAt.map { .timed(instant: $0, timeZoneID: timeZoneID) }
        if previous == nil { proposed.submissionURL = source.url.absoluteString }
        if previous?.sourceCitation?.revisionID != revision.id {
            proposed.sourceCitation = citation
        }
        // Reimporting an unchanged assignment does not reset personal progress,
        // related files, a chosen Gradescope submission link or the item version.
        if let previous, proposed != previous {
            guard previous.version < UInt64.max else { throw Self.changed }
            proposed.version = previous.version + 1
        }
        return CourseworkImportReview(id: UUID(), proposed: proposed, previous: previous,
            source: proposed.sourceCitation ?? citation, sourceURL: source.url, sourceSequence: revision.sequence,
            termID: enrollment.termID, timeZoneID: timeZoneID)
    }

    @discardableResult
    public func accept(_ review: CourseworkImportReview) throws -> CourseworkItem {
        do {
            try repository.update { state in
                guard let material = state.materials.first(where: { $0.id == review.source.sourceID }),
                      material.classID == review.proposed.classID,
                      material.currentRevisionID == review.source.revisionID,
                      let enrollment = state.classes.first(where: { $0.id == material.classID }),
                      enrollment.termID == review.termID,
                      Self.timeZoneID(for: enrollment, in: state) == review.timeZoneID else {
                    throw Self.changed
                }
                let index = state.coursework.firstIndex { $0.id == review.proposed.id }
                if let index, state.coursework[index] == review.proposed { throw AlreadyApplied() }
                guard index.map({ state.coursework[$0] }) == review.previous,
                      !state.coursework.contains(where: {
                          $0.id != review.proposed.id && $0.sourceCitation?.sourceID == material.id
                      }) else { throw Self.changed }
                if let index { state.coursework[index] = review.proposed }
                else { state.coursework.append(review.proposed) }
            }
        } catch is AlreadyApplied {
            try repository.refresh()
        }
        return review.proposed
    }

    /// A material selection stores exact revisions, including unsupported originals.
    /// Existing selections keep their earlier revisions until deliberately removed.
    public func evidence(materialIDs: Set<UUID>, classID: UUID,
                         preserving existing: [SourceCitation] = []) throws -> [SourceCitation] {
        try repository.refresh()
        guard materialIDs.count <= 64 else { throw Self.changed }
        return try materialIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            guard let material = repository.state.materials.first(where: { $0.id == id && $0.classID == classID }) else {
                throw ContextServiceError.outOfScope
            }
            if let saved = existing.first(where: { $0.sourceID == id && $0.classID == classID && $0.sourceKind == "material" }) {
                _ = try RetrievalService(repository: repository).resolve(saved)
                return saved
            }
            guard let revision = repository.state.materialRevisions.first(where: { $0.id == material.currentRevisionID }) else {
                throw ContextServiceError.missingRevision
            }
            let citation = SourceCitation(classID: classID, sourceKind: "material", sourceID: id,
                revisionID: revision.id, payloadSHA256: revision.text?.sha256 ?? revision.original.sha256,
                label: "\(material.title) · revision \(revision.sequence)")
            _ = try RetrievalService(repository: repository).resolve(citation)
            return citation
        }
    }

    @discardableResult
    public func save(_ draft: CourseworkItem, expectedVersion: UInt64?) throws -> CourseworkItem {
        var result = draft
        try repository.update { state in
            if let index = state.coursework.firstIndex(where: { $0.id == draft.id }) {
                let current = state.coursework[index]
                guard current.classID == draft.classID, current.version == expectedVersion,
                      current.version < UInt64.max else { throw Self.changed }
                result.version = current.version + 1
                state.coursework[index] = result
            } else {
                guard expectedVersion == nil else { throw Self.changed }
                result.version = 1
                state.coursework.append(result)
            }
        }
        return result
    }

    private static func timeZoneID(for enrollment: ClassEnrollment, in state: ContextState) -> String {
        state.terms.first { $0.id == enrollment.termID }?.timeZoneID ?? AcademicTerm.defaultTimeZoneID
    }

    private struct AlreadyApplied: Error {}
    private static var changed: UniversityServiceError {
        .message("The coursework, class, or source changed. Reopen it to review the current version before saving.")
    }
}
