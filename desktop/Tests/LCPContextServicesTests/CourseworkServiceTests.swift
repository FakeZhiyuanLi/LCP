import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

final class CourseworkServiceTests: XCTestCase {
    @MainActor private func fixture() throws -> (ContextRepository, ClassEnrollment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-coursework-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let term = AcademicTerm(name: "Fictional Fall 2026", timeZoneID: "America/Los_Angeles")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "SYN 46", title: "Synthetic algorithms")
        try repository.update { $0.terms.append(term); $0.classes.append(enrollment) }
        return (repository, enrollment, root)
    }

    @MainActor private func assignment(_ repository: ContextRepository, _ classID: UUID,
                                      due: Date? = Date(timeIntervalSince1970: 1_795_420_800),
                                      body: String = "Original graph assignment", remoteID: String = "46/assignments/11") throws -> SourceMaterial {
        let document = UniversityDocument(filename: "Assignment.txt", data: Data(body.utf8),
            sourceURL: URL(string: "https://canvas.eee.uci.edu/courses/\(remoteID)")!, remoteID: remoteID,
            courseworkContext: .init(title: "Graph assignment", dueAt: due))
        return try MaterialService(repository: repository).importUniversityDocument(document, classID: classID,
            provider: "uci-canvas", remoteID: remoteID, title: "Graph assignment")
    }

    @MainActor func testReviewIsLocalAndOnlyExplicitIdempotentAcceptanceCreatesCoursework() async throws {
        let (repository, enrollment, _) = try fixture()
        let material = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        let before = repository.state
        let review = try service.reviewCanvasMaterial(material.id)
        XCTAssertEqual(repository.state, before, "Review must not write coursework or a new library revision")
        XCTAssertTrue(repository.state.coursework.isEmpty)
        XCTAssertEqual(review.proposed.due, .timed(instant: Date(timeIntervalSince1970: 1_795_420_800), timeZoneID: "America/Los_Angeles"))
        let saved = try service.accept(review)
        let committed = repository.state
        XCTAssertEqual(saved.sourceCitation?.revisionID, material.currentRevisionID)
        XCTAssertTrue(repository.state.pinnedPayloads.contains { $0.sha256 == review.source.payloadSHA256 })
        XCTAssertEqual(try service.accept(review), saved)
        XCTAssertEqual(repository.state, committed, "Retrying an acceptance must not increment a version or create duplicates")
        let repeated = try service.reviewCanvasMaterial(material.id)
        XCTAssertEqual(try service.accept(repeated), saved)
        XCTAssertEqual(repository.state, committed)
    }

    @MainActor func testSourceRefreshRequiresReviewAndPreservesPersonalWorkAndExactOldEvidence() async throws {
        let (repository, enrollment, _) = try fixture()
        let material = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        let review = try service.reviewCanvasMaterial(material.id)
        var item = try service.accept(review)
        item.status = "submitted"
        item.submissionURL = "https://www.gradescope.com/courses/46/assignments/11"
        item = try service.save(item, expectedVersion: item.version)
        let oldCitation = try XCTUnwrap(item.sourceCitation)
        let oldVersion = item.version
        let newDate = Date(timeIntervalSince1970: 1_795_507_200)
        _ = try assignment(repository, enrollment.id, due: newDate, body: "Revised graph assignment")
        XCTAssertEqual(repository.state.coursework.first, item, "Reimporting source material cannot change an official deadline")
        XCTAssertEqual(try RetrievalService(repository: repository).resolve(oldCitation).text, "Original graph assignment")
        let refreshed = try service.reviewCanvasMaterial(material.id)
        let updated = try service.accept(refreshed)
        XCTAssertEqual(updated.id, item.id)
        XCTAssertEqual(updated.version, oldVersion + 1)
        XCTAssertEqual(updated.status, "submitted")
        XCTAssertEqual(updated.submissionURL, item.submissionURL)
        XCTAssertEqual(updated.due, .timed(instant: newDate, timeZoneID: "America/Los_Angeles"))
        XCTAssertNotEqual(updated.sourceCitation?.revisionID, oldCitation.revisionID)
        XCTAssertEqual(repository.state.materialRevisions.count, 2)
    }

    @MainActor func testStaleSourceReviewDoesNotCommit() async throws {
        let (repository, enrollment, _) = try fixture()
        let material = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        let review = try service.reviewCanvasMaterial(material.id)
        _ = try assignment(repository, enrollment.id, body: "A newer imported revision")
        let before = repository.state
        XCTAssertThrowsError(try service.accept(review))
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testUpdatedSourceMetadataGetsANewRevisionAndClearsDeadlineOnlyAfterReview() async throws {
        let (repository, enrollment, _) = try fixture()
        let material = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        var original = try service.accept(service.reviewCanvasMaterial(material.id))
        original.submissionURL = nil
        original = try service.save(original, expectedVersion: original.version)
        let revised = try assignment(repository, enrollment.id, due: nil)
        XCTAssertNotEqual(material.currentRevisionID, revised.currentRevisionID)
        XCTAssertEqual(repository.state.coursework.first, original)
        let review = try service.reviewCanvasMaterial(material.id)
        XCTAssertNil(review.proposed.due)
        XCTAssertEqual(review.previous?.due, original.due)
        let updated = try service.accept(review)
        XCTAssertNil(updated.due)
        XCTAssertNil(updated.submissionURL, "An explicitly cleared submission link must stay cleared")
        let before = repository.state
        _ = try assignment(repository, enrollment.id, due: nil)
        XCTAssertEqual(repository.state, before, "Repeating the same fact and source bytes is an idempotent material import")
    }

    @MainActor func testConcurrentProgressEditAndTermTimezoneChangeRequireAnotherReview() async throws {
        let (repository, enrollment, _) = try fixture()
        let material = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        var item = try service.accept(service.reviewCanvasMaterial(material.id))
        _ = try assignment(repository, enrollment.id, body: "Updated instructions")
        let review = try service.reviewCanvasMaterial(material.id)
        let second = try ContextRepository(rootURL: repository.rootURL)
        try second.update { $0.coursework[0].status = "in_progress"; $0.coursework[0].version += 1 }
        XCTAssertThrowsError(try service.accept(review))
        XCTAssertThrowsError(try service.save(item, expectedVersion: item.version))
        try repository.refresh()
        XCTAssertEqual(repository.state.coursework[0].status, "in_progress")
        let termReview = try service.reviewCanvasMaterial(material.id)
        try second.update { $0.terms[0].timeZoneID = "Asia/Tokyo" }
        XCTAssertThrowsError(try service.accept(termReview))
        item = try CourseworkService(repository: second).accept(CourseworkService(repository: second).reviewCanvasMaterial(material.id))
        XCTAssertEqual(item.status, "in_progress")
        if case .timed(_, let zone) = item.due { XCTAssertEqual(zone, "Asia/Tokyo") }
        else { XCTFail("Expected a timed source deadline") }
    }

    @MainActor func testNameOnlyCanvasClassDueDateAndTermAssignmentDuringReview() async throws {
        let (repository, _, root) = try fixture()
        let seminar = ClassEnrollment(title: "Film seminar")
        try repository.update { $0.classes.append(seminar) }
        let material = try assignment(repository, seminar.id)
        let service = CourseworkService(repository: repository)
        let review = try service.reviewCanvasMaterial(material.id)
        XCTAssertEqual(review.proposed.due, .timed(instant: Date(timeIntervalSince1970: 1_795_420_800),
                                                   timeZoneID: AcademicTerm.defaultTimeZoneID))
        XCTAssertEqual(try service.accept(review), review.proposed)
        let retrieval = RetrievalService(repository: repository)
        let destination = root.appendingPathComponent("snapshot")
        let manifest = try retrieval.buildContextBundle(classIDs: [seminar.id], to: destination)
        XCTAssertEqual(manifest.classes.map(\.id), [seminar.id])
        XCTAssertNil(manifest.classes.first?.termID)
        let markdown = try String(contentsOf: destination.appendingPathComponent("context.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("- Film seminar (class \(seminar.id.uuidString))"))
        try repository.update { state in
            let index = try XCTUnwrap(state.classes.firstIndex { $0.id == seminar.id })
            state.classes[index].termID = state.terms[0].id
        }
        XCTAssertThrowsError(try service.accept(review))
    }

    @MainActor func testMissingDeadlineStaysUnknownAndCourseIdentityIsLocalToEachEnrollment() async throws {
        let (repository, enrollment, _) = try fixture()
        let second = ClassEnrollment(termID: enrollment.termID, courseCode: "SYN 46", title: "Another section")
        try repository.update { $0.classes.append(second) }
        let firstSource = try assignment(repository, enrollment.id, due: nil)
        let otherSource = try assignment(repository, second.id, due: nil)
        XCTAssertNotEqual(firstSource.id, otherSource.id)
        let service = CourseworkService(repository: repository)
        let first = try service.accept(service.reviewCanvasMaterial(firstSource.id))
        let other = try service.accept(service.reviewCanvasMaterial(otherSource.id))
        XCTAssertNil(first.due)
        XCTAssertNil(other.due)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertEqual(first.classID, enrollment.id)
        XCTAssertEqual(other.classID, second.id)
        XCTAssertThrowsError(try service.evidence(materialIDs: [otherSource.id], classID: enrollment.id))
    }

    @MainActor func testDriveGmailGradescopeAndUciEvidenceSurvivesRevisionsReopenAndBackupRestore() async throws {
        let (repository, enrollment, root) = try fixture()
        let source = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        var item = try service.accept(service.reviewCanvasMaterial(source.id))
        let fixtures = [
            ("google-drive", "https://drive.google.com/file/d/fixture/view", "Drive reading"),
            ("gmail", "https://mail.google.com/mail/u/0/#all/fixture", "Gmail clarification"),
            ("gradescope", "https://www.gradescope.com/courses/46/assignments/11", "Gradescope feedback"),
            ("uci-registrar", "https://www.reg.uci.edu/perl/WebSoc?YearTerm=202692&Dept=I%26C+SCI&CourseNum=46", "UCI schedule"),
        ]
        var materials: [SourceMaterial] = []
        for (provider, address, text) in fixtures {
            let doc = UniversityDocument(filename: "Evidence.txt", data: Data(text.utf8), sourceURL: URL(string: address)!)
            materials.append(try MaterialService(repository: repository).importUniversityDocument(doc, classID: enrollment.id,
                provider: provider, remoteID: "fixture", title: text))
        }
        item.relatedCitations = try service.evidence(materialIDs: Set(materials.map(\.id)), classID: enrollment.id)
        item = try service.save(item, expectedVersion: item.version)
        // A new Drive revision must not silently move the saved coursework citation.
        let changed = UniversityDocument(filename: "Evidence.txt", data: Data("Later Drive revision".utf8),
            sourceURL: URL(string: fixtures[0].1)!)
        _ = try MaterialService(repository: repository).importUniversityDocument(changed, classID: enrollment.id,
            provider: "google-drive", remoteID: "fixture", title: fixtures[0].2)
        let preserved = try service.evidence(materialIDs: Set(materials.map(\.id)), classID: enrollment.id,
            preserving: item.relatedCitations ?? [])
        XCTAssertEqual(preserved, item.relatedCitations)
        let reopened = try ContextRepository(rootURL: repository.rootURL)
        XCTAssertEqual(reopened.state.coursework.first, item)
        let backup = root.appendingPathComponent("backup")
        try reopened.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("restored"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.coursework.first, item)
        let retrieval = RetrievalService(repository: offline)
        for (provider, _, text) in fixtures {
            let citation = try XCTUnwrap(item.relatedCitations?.first { citation in
                offline.state.materials.contains { $0.id == citation.sourceID && $0.kind == provider }
            })
            XCTAssertEqual(try retrieval.resolve(citation).text, text)
            XCTAssertTrue(offline.state.pinnedPayloads.contains { $0.sha256 == citation.payloadSHA256 })
        }
        XCTAssertEqual(try retrieval.resolve(XCTUnwrap(item.sourceCitation)).text, "Original graph assignment")
    }

    @MainActor func testTamperedOrCrossClassCourseworkCitationNeverCommits() async throws {
        let (repository, enrollment, _) = try fixture()
        let source = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        let item = try service.accept(service.reviewCanvasMaterial(source.id))
        let before = repository.state
        var damaged = item
        damaged.sourceCitation?.payloadSHA256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try service.save(damaged, expectedVersion: item.version))
        XCTAssertEqual(repository.state, before)
        damaged = item
        damaged.sourceCitation?.classID = UUID()
        XCTAssertThrowsError(try service.save(damaged, expectedVersion: item.version))
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testLegacyV1RecordsDecodeWithoutInventingCourseworkProvenance() async throws {
        let (repository, enrollment, _) = try fixture()
        let source = try assignment(repository, enrollment.id)
        let service = CourseworkService(repository: repository)
        _ = try service.accept(service.reviewCanvasMaterial(source.id))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(repository.state)) as? [String: Any])
        object["materialRevisions"] = try XCTUnwrap(object["materialRevisions"] as? [[String: Any]]).map { row in
            var row = row; row.removeValue(forKey: "courseworkContext"); return row
        }
        object["coursework"] = try XCTUnwrap(object["coursework"] as? [[String: Any]]).map { row in
            var row = row; row.removeValue(forKey: "sourceCitation"); row.removeValue(forKey: "relatedCitations"); return row
        }
        let legacy = try JSONDecoder().decode(ContextState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.materialRevisions[0].courseworkContext)
        XCTAssertNil(legacy.coursework[0].sourceCitation)
        XCTAssertNil(legacy.coursework[0].relatedCitations)
        XCTAssertEqual(legacy.coursework[0].due, repository.state.coursework[0].due)
    }
}
