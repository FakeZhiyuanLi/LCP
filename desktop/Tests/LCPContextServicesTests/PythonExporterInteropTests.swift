import XCTest
import LCPContextCore
import LCPContextServices

/// Exact fixture bytes produced by the Python exporter catch cross-language
/// identity, numeric and timestamp mismatches.
final class PythonExporterInteropTests: XCTestCase {
    @MainActor
    func testPythonProducedFeedAndCitationSurviveOfflineBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-python-interop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("profile"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PythonExport")
        let result = try FeedImporter(repository: repository).importGeneration(from: fixture)
        XCTAssertEqual(result.importedRecordings, 4)
        XCTAssertEqual(result.importedTranscripts, 1)
        XCTAssertTrue(repository.state.recordings.allSatisfy { $0.classID == nil })
        let term = AcademicTerm(name: "Fictional Export Interop")
        let course = ClassEnrollment(termID: term.id, courseCode: "CS TEST", title: "Binary Trees")
        let recording = try XCTUnwrap(repository.state.recordings.first { $0.filename.hasPrefix("SYNTHETIC Eligible_") })
        try repository.update {
            $0.terms.append(term)
            $0.classes.append(course)
            $0.recordings[$0.recordings.firstIndex { $0.id == recording.id }!].classID = course.id
        }
        let retrieval = RetrievalService(repository: repository)
        let passage = try XCTUnwrap(retrieval.search(ContextQuery(classIDs: [course.id], text: "binary trees")).results.first)
        XCTAssertEqual(passage.citation.sourceKind, "transcript")
        XCTAssertEqual(passage.citation.locator, .cues(start: 0, end: 0))
        let exact = try retrieval.resolve(passage.citation)
        XCTAssertTrue(exact.text.contains("Synthetic lecture on binary trees."))
        let pinned = try retrieval.pin(passage.citation)
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(try RetrievalService(repository: offline).resolve(pinned).text, exact.text)
        XCTAssertEqual(offline.state.recordings.first { $0.id == recording.id }?.acceptedJobID, "synthetic-eligible-job")
    }
}
