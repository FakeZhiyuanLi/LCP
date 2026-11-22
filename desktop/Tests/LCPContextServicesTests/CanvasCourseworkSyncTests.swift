import XCTest
import LCPContextCore
@testable import LCPContextServices

final class CanvasCourseworkSyncTests: XCTestCase {
    func testMatchesSavedIDsThenExactUciCodesAndTitles() {
        let saved = ClassEnrollment(canvasCourseID: "46", courseCode: "", title: "Saved class")
        let code = ClassEnrollment(courseCode: "ICS 46", title: "Algorithms")
        let title = ClassEnrollment(courseCode: "", title: "Discrete Structures")
        let archived = ClassEnrollment(courseCode: "PHIL 4", title: "Archived", archived: true)
        let courses = [
            UniversityItem(id: "46", title: "Data Structures", detail: "SAVED 46"),
            UniversityItem(id: "47", title: "Algorithms", detail: "I&C SCI 46"),
            UniversityItem(id: "48", title: "Discrete Structures", detail: "OTHER 48"),
            UniversityItem(id: "49", title: "Archived", detail: "PHIL 4"),
        ]

        let codeOnly = CanvasCourseworkSyncService.match(classes: [code], courses: [courses[1]])
        XCTAssertEqual(codeOnly.matches.first?.basis, "course code")

        let result = CanvasCourseworkSyncService.match(classes: [saved, code, title, archived], courses: courses)

        XCTAssertEqual(result.matches.map(\.canvasCourseID), ["46", "47", "48"])
        XCTAssertEqual(result.matches.map(\.basis), ["saved Canvas course", "course code", "class name"])
        XCTAssertTrue(result.unmatched.isEmpty)
    }

    func testRejectsAmbiguousAndDuplicateMatchesAndIgnoresInvalidIDs() {
        let duplicateCode = ClassEnrollment(courseCode: "TEST 46", title: "One")
        let sameCode = ClassEnrollment(courseCode: "TEST 46", title: "Two")
        let invalidSaved = ClassEnrollment(canvasCourseID: "0", courseCode: "OTHER", title: "Invalid link")
        let courses = [
            UniversityItem(id: "50", title: "One", detail: "TEST 46"),
            UniversityItem(id: "51", title: "Two", detail: "TEST 46"),
            UniversityItem(id: "not-a-number", title: "Invalid", detail: "OTHER"),
        ]

        let result = CanvasCourseworkSyncService.match(classes: [duplicateCode, sameCode, invalidSaved], courses: courses)

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.unmatched.count, 3)
        XCTAssertTrue(result.unmatched.allSatisfy { $0.contains("no unique Canvas course match") || $0.contains("no longer active") })
    }
}
