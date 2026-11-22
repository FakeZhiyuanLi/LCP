import Foundation
import XCTest
@testable import LCPClient

final class ClassManifestTests: XCTestCase {
    func testDefaultManifestPathIsUnderLecturesClasses() throws {
        let home = try temporaryDirectory()
        let store = ClassManifestStore(fileManager: TemporaryHomeFileManager(home: home))
        XCTAssertEqual(
            store.manifestURL,
            home.appendingPathComponent("Lectures/Classes/classes.json")
        )
    }

    func testLoadsDriveFolderNamesAndCourseCodes() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("classes.json")
        let json = #"""
        {
          "version": 1,
          "source": "google_drive",
          "generated_at": "2026-10-19T20:00:00Z",
          "root_folder_id": "school-lectures-root",
          "classes": [
            {"name": "ICS 46", "course_code": "ICS 46", "drive_folder_id": "ics-id"},
            {"name": "Philosophy 29", "courseCode": "Philosophy 29", "drive_folder_id": "philos-id"}
          ]
        }
        """#.data(using: .utf8)!
        try json.write(to: manifestURL)

        let classes = try ClassManifestStore(manifestURL: manifestURL)
            .loadClasses(now: ISO8601DateFormatter().date(from: "2026-10-19T20:30:00Z")!)
        XCTAssertEqual(classes, [
            try LectureClass(name: "ICS 46", courseCode: "ICS 46", driveFolderID: "ics-id"),
            try LectureClass(name: "Philosophy 29", courseCode: "Philosophy 29", driveFolderID: "philos-id")
        ])
    }

    func testLoadsRackCatalogFractionalISO8601Timestamp() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("classes.json")
        let json = #"{"version":1,"source":"google_drive","generated_at":"2026-10-19T20:00:00.654949Z","root_folder_id":"root","classes":[]}"#
        try Data(json.utf8).write(to: manifestURL)

        XCTAssertNoThrow(try ClassManifestStore(manifestURL: manifestURL).load(
            now: ISO8601DateFormatter().date(from: "2026-10-19T20:30:00Z")!
        ))
    }

    func testAClassWithNoSeparateCodeUsesItsSafeFolderName() throws {
        let entry = try LectureClass(name: "CS182")
        XCTAssertEqual(entry.name, "CS182")
        XCTAssertEqual(entry.courseCode, "CS182")
    }

    func testRejectsInvalidClassNamesAndCodes() {
        XCTAssertThrowsError(try LectureClass(name: "../escape", courseCode: "CS182")) { error in
            XCTAssertEqual(error as? ClassManifestError, .invalidClassName)
        }
        XCTAssertThrowsError(try LectureClass(name: "ICS 46", courseCode: "ICS/46")) { error in
            XCTAssertEqual(error as? ClassManifestError, .invalidCourseCode)
        }
        XCTAssertThrowsError(try LectureClass(name: "ICS 46", courseCode: "ICS 46", driveFolderID: "bad/id")) { error in
            XCTAssertEqual(error as? ClassManifestError, .invalidMetadata)
        }
    }

    func testRejectsDuplicateCourseCodesCaseInsensitively() throws {
        let first = try LectureClass(name: "CS182", courseCode: "CS182")
        let second = try LectureClass(name: "CS 182 (alternate)", courseCode: "cs182")
        XCTAssertThrowsError(try LectureClassManifest(
            generatedAt: Date(),
            rootFolderID: "root",
            classes: [first, second]
        )) { error in
            XCTAssertEqual(error as? ClassManifestError, .duplicateCourseCode)
        }
    }

    func testRejectsUnsupportedVersionAndMalformedJSON() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("classes.json")
        try Data(#"{"version": 2, "source": "google_drive", "generated_at": "2026-10-19T20:00:00Z", "root_folder_id": "root", "classes": []}"#.utf8).write(to: manifestURL)
        XCTAssertThrowsError(try ClassManifestStore(manifestURL: manifestURL).load(now: Date(timeIntervalSince1970: 0))) { error in
            XCTAssertEqual(error as? ClassManifestError, .unsupportedVersion)
        }

        try Data(#"{"version": 1, "source": "google_drive", "generated_at": "2026-10-19T20:00:00Z", "root_folder_id": "root", "classes": "not-an-array"}"#.utf8).write(to: manifestURL)
        XCTAssertThrowsError(try ClassManifestStore(manifestURL: manifestURL).load(now: Date(timeIntervalSince1970: 0))) { error in
            XCTAssertEqual(error as? ClassManifestError, .invalidManifestShape)
        }
    }

    func testRejectsStaleManifest() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("classes.json")
        let data = #"{"version": 1, "source": "google_drive", "generated_at": "2026-10-18T20:00:00Z", "root_folder_id": "root", "classes": []}"#.data(using: .utf8)!
        try data.write(to: manifestURL)

        XCTAssertThrowsError(try ClassManifestStore(manifestURL: manifestURL, maximumAge: 3600)
            .load(now: ISO8601DateFormatter().date(from: "2026-10-19T20:00:00Z")!)) { error in
            XCTAssertEqual(error as? ClassManifestError, .staleManifest)
        }
    }

    func testRejectsNonDriveCatalogSource() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("classes.json")
        let data = #"{"version": 1, "source": "manual", "generated_at": "2026-10-19T20:00:00Z", "root_folder_id": "root", "classes": []}"#.data(using: .utf8)!
        try data.write(to: manifestURL)

        XCTAssertThrowsError(try ClassManifestStore(manifestURL: manifestURL)
            .load(now: ISO8601DateFormatter().date(from: "2026-10-19T20:30:00Z")!)) { error in
            XCTAssertEqual(error as? ClassManifestError, .invalidMetadata)
        }
    }

    func testMissingManifestFailsClearly() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("missing.json")
        XCTAssertThrowsError(try ClassManifestStore(manifestURL: manifestURL).load()) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class TemporaryHomeFileManager: FileManager, @unchecked Sendable {
    private let temporaryHome: URL

    override var homeDirectoryForCurrentUser: URL { temporaryHome }

    init(home: URL) {
        temporaryHome = home
        super.init()
    }
}
