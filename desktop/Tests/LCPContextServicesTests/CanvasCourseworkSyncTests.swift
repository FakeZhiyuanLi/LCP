import XCTest
import LCPContextCore
@testable import LCPContextServices

final class CanvasCourseworkSyncTests: XCTestCase {
    func testOnlyExplicitlyLinkedClassesAreMatched() {
        let saved = ClassEnrollment(canvasCourseID: "46", courseCode: "", title: "Saved class")
        let unlinkedByCode = ClassEnrollment(courseCode: "ICS 46", title: "Algorithms")
        let unlinkedByTitle = ClassEnrollment(courseCode: "", title: "Discrete Structures")
        let archived = ClassEnrollment(canvasCourseID: "49", courseCode: "PHIL 4", title: "Archived", archived: true)
        let courses = [
            UniversityItem(id: "46", title: "Data Structures", detail: "SAVED 46"),
            UniversityItem(id: "47", title: "Algorithms", detail: "I&C SCI 46"),
            UniversityItem(id: "48", title: "Discrete Structures", detail: "OTHER 48"),
            UniversityItem(id: "49", title: "Archived", detail: "PHIL 4"),
        ]

        let result = CanvasCourseworkSyncService.match(classes: [saved, unlinkedByCode, unlinkedByTitle, archived], courses: courses)

        XCTAssertEqual(result.matches.map(\.canvasCourseID), ["46"])
        XCTAssertEqual(result.matches.map(\.basis), ["saved Canvas course"])
        XCTAssertTrue(result.unmatched.isEmpty)
    }

    func testReportsInvalidAndDuplicateExplicitLinks() {
        let first = ClassEnrollment(canvasCourseID: "50", title: "One")
        let duplicate = ClassEnrollment(canvasCourseID: "50", title: "Two")
        let invalidSaved = ClassEnrollment(canvasCourseID: "0", courseCode: "OTHER", title: "Invalid link")
        let courses = [
            UniversityItem(id: "50", title: "Canvas course", detail: "TEST 46"),
        ]

        let result = CanvasCourseworkSyncService.match(classes: [first, duplicate, invalidSaved], courses: courses)

        XCTAssertEqual(result.matches.map(\.canvasCourseID), ["50"])
        XCTAssertEqual(result.unmatched.count, 2)
        XCTAssertTrue(result.unmatched.contains { $0.contains("already linked to another class") })
        XCTAssertTrue(result.unmatched.contains { $0.contains("invalid Canvas course link") })
    }
}
