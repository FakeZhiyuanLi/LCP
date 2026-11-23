import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

@MainActor
final class CitationReaderTests: XCTestCase {
    func testReadingShowsTheCitedRevisionAndPreservesExcerpts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let term = AcademicTerm(name: "Fictional fall", timeZoneID: "America/New_York")
        let course = ClassEnrollment(termID: term.id, courseCode: "CS 201", title: "Fictional seminar")
        try repository.update { $0.terms.append(term); $0.classes.append(course) }
        let url = try XCTUnwrap(URL(string: "https://canvas.eee.uci.edu/courses/11/assignments/7"))
        let service = MaterialService(repository: repository)
        func save(_ facts: ImportedCourseworkContext, text: String) throws -> SourceCitation {
            let document = UniversityDocument(filename: "worksheet.txt", data: Data(text.utf8), sourceURL: url,
                                              courseworkContext: facts)
            let material = try service.importUniversityDocument(document, classID: course.id, provider: "uci-canvas",
                                                               remoteID: "11/assignments/7", title: facts.title)
            let revision = try XCTUnwrap(repository.state.materialRevisions.first { $0.id == material.currentRevisionID })
            return SourceCitation(classID: course.id, sourceKind: "material", sourceID: material.id, revisionID: revision.id,
                                  payloadSHA256: try XCTUnwrap(revision.text).sha256)
        }
        let original = ImportedCourseworkContext(title: "Worksheet")
        let instructions = "Read the two passages.\n\nDue: discuss both sources in your response.\n"
        let originalText = "Worksheet\n\(url.absoluteString)\n\n\(instructions)"
        let oldCitation = try save(original, text: originalText)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T17:00:00Z"))
        let graded = ImportedCourseworkContext(title: "Midterm", dueAt: date, submissionState: .graded)
        let gradedText = "Midterm\nDue: 2026-11-05T17:00:00Z\nCanvas submission: graded\n\(url.absoluteString)\n\n"
        let newCitation = try save(graded, text: gradedText)

        let retrieval = RetrievalService(repository: repository)
        let historical = CitationReaderSource(oldCitation, in: repository.state)
        let current = CitationReaderSource(newCitation, in: repository.state)
        XCTAssertEqual(historical.revision?.sequence, 1)
        XCTAssertEqual(historical.coursework, original)
        XCTAssertEqual(historical.instructions(in: try retrieval.resolve(oldCitation)), instructions)
        XCTAssertEqual(current.revision?.sequence, 2)
        XCTAssertEqual(current.coursework, graded)
        XCTAssertEqual(current.timeZone.identifier, term.timeZoneID)
        XCTAssertEqual(current.serviceURL, url)
        XCTAssertEqual(current.instructions(in: try retrieval.resolve(newCitation)), "")
        XCTAssertEqual(try retrieval.resolve(newCitation).text, gradedText)

        var excerpt = oldCitation
        excerpt.locator = .text(startUTF8: 0, lengthUTF8: originalText.utf8.count - instructions.utf8.count)
        let partial = try retrieval.resolve(excerpt)
        XCTAssertNil(CitationReaderSource(excerpt, in: repository.state).instructions(in: partial))
        XCTAssertTrue(partial.text.hasPrefix("Worksheet\n"))
    }

    func testUnknownAndMismatchedHeadersRemainVerbatim() throws {
        let url = try XCTUnwrap(URL(string: "https://canvas.eee.uci.edu/courses/11/quizzes/12"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T17:00:00Z"))
        let quiz = ImportedCourseworkContext(title: "Review quiz", kind: "quiz", dueAt: date)
        let body = String(repeating: "A fictional reading with café and Ω.\n\n", count: 500)
        let header = "Review quiz\nDue: 2026-11-05T09:00:00.000-08:00\n\(url.absoluteString)"
        XCTAssertEqual(UciCanvasClient.courseworkInstructions(in: header + "\n\n" + body, facts: quiz, source: url), body)
        for changed in [header.replacingOccurrences(of: "09:00", with: "10:00"),
                        header.replacingOccurrences(of: "quizzes/12", with: "quizzes/13"),
                        header.replacingOccurrences(of: "Due: ", with: "Instructor note: "),
                        header.replacingOccurrences(of: "\nhttps", with: "\nCanvas submission: graded\nhttps"),
                        "Instructions\n\(header)"] {
            XCTAssertNil(UciCanvasClient.courseworkInstructions(in: changed + "\n\n" + body, facts: quiz, source: url))
        }
    }
}
