import Foundation
import XCTest
@testable import LCPContextCore

final class ClassDriveFolderTests: XCTestCase {
    func testLegacyEnrollmentKeepsRecordingDestinationWithoutRequestingAFolder() throws {
        let legacy = Data("""
        {
            "id": "9F69994D-F571-4D1E-8F6C-C68F3799A5CC",
            "courseCode": "SYN 101", "title": "Fictional Physics",
            "section": "", "instructor": "", "archived": false,
            "recordingDestination": { "driveFolderID": "legacy-folder", "exactCourseCode": "SYN 101" }
        }
        """.utf8)
        let enrollment = try JSONDecoder().decode(ClassEnrollment.self, from: legacy)
        XCTAssertNil(enrollment.driveFolder)
        XCTAssertEqual(enrollment.recordingDestination,
                       RecordingDestination(driveFolderID: "legacy-folder", exactCourseCode: "SYN 101"))
    }

    func testFolderNameUsesOptionalCodeOrClassNameAndHandlesUnsupportedCharacters() {
        XCTAssertEqual(ClassDriveFolder(for: ClassEnrollment(courseCode: "SYN 101", title: "Worlds")).name, "SYN 101")
        XCTAssertEqual(ClassDriveFolder(for: ClassEnrollment(title: "Worlds")).name, "Worlds")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        for title in ["Art/Design: Words & Images", "⚙️", "lCp TeSt"] {
            let enrollment = ClassEnrollment(title: title)
            let name = ClassDriveFolder(for: enrollment).name
            XCTAssertFalse(name.isEmpty)
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertNil(name.rangeOfCharacter(from: allowed.inverted))
            XCTAssertNotEqual(name.caseInsensitiveCompare("LCP Test"), .orderedSame)
            XCTAssertEqual(ClassDriveFolder(for: ClassEnrollment(title: title)).name, name)
        }
        let cPlus = ClassDriveFolder(for: ClassEnrollment(title: "C++"))
        let cSharp = ClassDriveFolder(for: ClassEnrollment(title: "C#"))
        XCTAssertNotEqual(cPlus.name, cSharp.name)
        let existingName = "Art/Design: Words & Images"
        XCTAssertEqual(ClassDriveFolder(for: ClassEnrollment(title: existingName)).preferredExistingName, existingName)
        XCTAssertNil(ClassDriveFolder(for: ClassEnrollment(title: "lCp TeSt")).preferredExistingName)
    }

    @MainActor func testCompetingRequestsAndReopenedLibraryUseOneReservationPerParentAndName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-folder-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProcess = try ContextRepository(rootURL: root)
        let secondProcess = try ContextRepository(rootURL: root)
        var first = ClassEnrollment(title: "Café 101")
        var second = ClassEnrollment(title: "CAFE 101")
        first.driveFolder = ClassDriveFolder(for: first)
        second.driveFolder = ClassDriveFolder(for: second)
        let firstName = try XCTUnwrap(first.driveFolder?.name)
        let secondName = try XCTUnwrap(second.driveFolder?.name)

        try firstProcess.update { state in
            state.classes.append(first)
            XCTAssertEqual(state.reserveDriveFolder(named: firstName, under: "school-root", proposedID: "first-id"), "first-id")
        }
        try secondProcess.update { state in
            state.classes.append(second)
            XCTAssertEqual(state.reserveDriveFolder(named: secondName, under: "school-root", proposedID: "second-id"), "first-id")
        }
        let reopened = try ContextRepository(rootURL: root)
        XCTAssertEqual(reopened.state.classes, [first, second])
        try reopened.update { state in
            XCTAssertEqual(state.reserveDriveFolder(named: firstName, under: "school-root", proposedID: "retry-id"), "first-id")
            XCTAssertEqual(state.reserveDriveFolder(named: firstName, under: "other-root", proposedID: "third-id"), "third-id")
            XCTAssertEqual(state.reserveDriveFolder(named: "Café 102", under: "school-root", proposedID: "fourth-id"), "fourth-id")
        }
    }
}
