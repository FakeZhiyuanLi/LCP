import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

@MainActor
final class UniversityMaterialImportTests: XCTestCase {
    @MainActor func testCalendarDocumentsReachTheSharedImporterWithSafeEventProvenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let term = AcademicTerm(name: "Synthetic Fall")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "SYN 46", title: "Synthetic algorithms")
        try repository.update { $0.terms.append(term); $0.classes.append(enrollment) }
        let service = MaterialService(repository: repository)
        let document = UniversityDocument(filename: "Review session.txt", data: Data("Review graphs at 10am.".utf8),
            sourceURL: URL(string: "https://calendar.google.com/calendar/event?eid=synthetic-event")!)
        let material = try service.importUniversityDocument(document, classID: enrollment.id,
            provider: "google-calendar", remoteID: "primary/synthetic-event", title: "Review session")
        XCTAssertTrue(MaterialService.isUniversityMaterial(material))
        XCTAssertEqual(repository.state.materialRevisions.first?.importedSource?.provider, "Google Calendar")
        let before = repository.state
        _ = try service.importUniversityDocument(document, classID: enrollment.id,
            provider: "google-calendar", remoteID: "primary/synthetic-event", title: "Review session")
        XCTAssertEqual(repository.state, before)
        let unsafe = UniversityDocument(filename: document.filename, data: document.data,
            sourceURL: URL(string: "https://calendar.google.com/calendar/event?access_token=synthetic-secret")!)
        XCTAssertThrowsError(try service.importUniversityDocument(unsafe, classID: enrollment.id,
            provider: "google-calendar", remoteID: "primary/unsafe", title: "Unsafe URL"))
        XCTAssertEqual(repository.state, before)
    }

    func testRepeatConcurrentReaderRevisionClassScopeAndOfflineRestore() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("original")
        let repo = try ContextRepository(rootURL: root)
        let term = AcademicTerm(name: "Fall")
        let first = ClassEnrollment(termID: term.id, courseCode: "DEMO 1", title: "One")
        let second = ClassEnrollment(termID: term.id, courseCode: "DEMO 2", title: "Two")
        try repo.update { $0.terms = [term]; $0.classes = [first, second] }
        let previouslyOpened = try ContextRepository(rootURL: root)
        let materials = MaterialService(repository: repo)
        let address = try XCTUnwrap(URL(string: "https://canvas.eee.uci.edu/courses/10/assignments/57"))
        let firstDoc = UniversityDocument(filename: "../weekly/reading.md", data: Data("Graph traversal evidence.".utf8), sourceURL: address)
        let id = "10/assignments/57"
        let firstMaterial = try materials.importUniversityDocument(firstDoc, classID: first.id, provider: "uci-canvas", remoteID: id, title: "Reading")
        let firstRevision = try XCTUnwrap(repo.state.materialRevisions.first)
        XCTAssertFalse(firstRevision.originalFilename.contains("/"))
        XCTAssertEqual(try repo.payloadData(firstRevision.original), firstDoc.data)
        let local = base.appendingPathComponent("local.md")
        try Data("Student authored replacement".utf8).write(to: local)
        XCTAssertThrowsError(try materials.reviseMaterial(materialID: firstMaterial.id, from: local))
        XCTAssertThrowsError(try materials.importMaterial(from: local, classID: first.id, kind: "uci-canvas"))
        let revisionNumber = repo.state.revision
        let repeated = try MaterialService(repository: previouslyOpened).importUniversityDocument(firstDoc, classID: first.id, provider: "uci-canvas", remoteID: id, title: "Reading")
        XCTAssertEqual(firstMaterial, repeated)
        XCTAssertTrue(previouslyOpened.state.materials.contains(firstMaterial))
        try repo.refresh()
        XCTAssertEqual(repo.state.revision, revisionNumber)
        let retrieval = RetrievalService(repository: repo)
        let citation = try XCTUnwrap(retrieval.search(ContextQuery(classIDs: [first.id], text: "traversal")).results.first?.citation)
        _ = try retrieval.pin(citation)
        let secondDoc = UniversityDocument(filename: "reading.md", data: Data("Amended matrix evidence.".utf8), sourceURL: address)
        let revised = try materials.importUniversityDocument(secondDoc, classID: first.id, provider: "uci-canvas", remoteID: id, title: "Corrected reading")
        XCTAssertEqual(revised.id, firstMaterial.id)
        XCTAssertNotEqual(revised.currentRevisionID, firstMaterial.currentRevisionID)
        XCTAssertEqual(repo.state.materialRevisions.map(\.sequence), [1, 2])
        XCTAssertEqual(try retrieval.resolve(citation).title, "Reading")
        XCTAssertTrue(try retrieval.resolve(citation).provenance.contains(address.absoluteString))
        XCTAssertTrue(try retrieval.search(ContextQuery(classIDs: [first.id], text: "traversal")).results.isEmpty)
        XCTAssertTrue(try retrieval.search(ContextQuery(classIDs: [second.id], text: "matrix")).results.isEmpty)
        let other = try materials.importUniversityDocument(firstDoc, classID: second.id, provider: "uci-canvas", remoteID: id, title: "Another class")
        XCTAssertNotEqual(other.id, firstMaterial.id)
        let backup = base.appendingPathComponent("backup")
        try repo.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: base.appendingPathComponent("restored"))
        try offline.restoreBackup(from: backup)
        let restored = try RetrievalService(repository: offline).resolve(citation)
        XCTAssertEqual(restored.title, "Reading")
        XCTAssertEqual(restored.text, "Graph traversal evidence.")
        XCTAssertEqual(offline.state.materialRevisions.first?.importedSource?.url, address)
        let restoredImport = try MaterialService(repository: offline).importUniversityDocument(secondDoc, classID: first.id, provider: "uci-canvas", remoteID: id, title: "Corrected reading")
        XCTAssertEqual(restoredImport, revised)
        XCTAssertEqual(offline.state.materialRevisions.count, 3)
    }

    func testSignedExternalAndWrongProviderSourceURLsNeverCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ContextRepository(rootURL: root)
        let term = AcademicTerm(name: "Fall")
        let cls = ClassEnrollment(termID: term.id, courseCode: "DEMO", title: "Demo")
        try repo.update { $0.terms = [term]; $0.classes = [cls] }
        let initial = repo.state
        let service = MaterialService(repository: repo)
        for address in ["https://cdn.example/resource", "https://canvas.eee.uci.edu/files/1?verifier=example",
                        "https://canvas.eee.uci.edu/files/1#access_token=example",
                        "https://username:password@canvas.eee.uci.edu/files/1", "file:///tmp/lecture"] {
            let doc = UniversityDocument(filename: "reading.txt", data: Data("text".utf8), sourceURL: try XCTUnwrap(URL(string: address)))
            XCTAssertThrowsError(try service.importUniversityDocument(doc, classID: cls.id, provider: "uci-canvas", remoteID: "1", title: "Resource"))
        }
        XCTAssertEqual(repo.state, initial)
    }

    func testUnsupportedFilePersistsActualBytesAndOnlyItsLabeledAttachmentDetails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ContextRepository(rootURL: root)
        let term = AcademicTerm(name: "Fall")
        let cls = ClassEnrollment(termID: term.id, courseCode: "DEMO", title: "Demo")
        try repo.update { $0.terms = [term]; $0.classes = [cls] }
        let url = try XCTUnwrap(URL(string: "https://drive.google.com/file/d/fake/view"))
        let bytes = Data([1, 2, 3])
        let doc = UniversityDocument(filename: "diagrams.pptx", data: bytes, sourceURL: url)
        let material = try MaterialService(repository: repo).importUniversityDocument(doc, classID: cls.id, provider: "google-drive", remoteID: "fake", title: "Seminar diagrams")
        let revision = try XCTUnwrap(repo.state.materialRevisions.first { $0.id == material.currentRevisionID })
        XCTAssertEqual(revision.extractionState, "unsupported_attachment_details_only")
        XCTAssertEqual(try repo.payloadData(revision.original), bytes)
        let retrieval = RetrievalService(repository: repo)
        let hit = try XCTUnwrap(retrieval.search(ContextQuery(classIDs: [cls.id], text: "Seminar diagrams")).results.first)
        let result = try retrieval.resolve(hit.citation)
        XCTAssertTrue(result.text.hasPrefix("Attachment details (no extracted body)"))
        XCTAssertEqual(result.provenance, revision.importedSource?.origin)
    }
}
