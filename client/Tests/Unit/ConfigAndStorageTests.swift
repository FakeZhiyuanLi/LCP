import AVFoundation
import XCTest
@testable import LCPClient

final class AudioConfigTests: XCTestCase {
    func testRecorderSettingsMatchLectureFormat() {
        let settings = AudioConfig().recorderSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 32_000)
        XCTAssertEqual(settings[AVEncoderAudioQualityKey] as? Int, AVAudioQuality.medium.rawValue)
    }

    func testNativeAACEncoderWritesReadable16kHzMonoM4AWithoutMicrophone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("silence.m4a")
        try writeOneSecondOfSilence(to: output)

        let reader = try AVAudioFile(forReading: output)
        XCTAssertEqual(reader.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(reader.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(reader.length, 0)
        XCTAssertEqual(Double(reader.length) / reader.processingFormat.sampleRate, 1, accuracy: 0.1)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
    }

    private func writeOneSecondOfSilence(to output: URL) throws {
        // Scope the writer separately so its AAC container is finalized before reading.
        let writer = try AVAudioFile(forWriting: output, settings: AudioConfig().recorderSettings)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 16_000))
        pcm.frameLength = 16_000
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
        }
        try writer.write(from: pcm)
    }
}

final class IngestManagerTests: XCTestCase {
    func testDefaultDirectoryIsLecturesIncomingInCurrentUsersHome() throws {
        let home = try temporaryDirectory()
        let manager = try IngestManager(fileManager: TemporaryHomeFileManager(home: home))
        let expected = home.appendingPathComponent("Lectures", isDirectory: true)
            .appendingPathComponent("Incoming", isDirectory: true)
        XCTAssertEqual(manager.stagingDirectory, expected)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testInitializationCreatesMissingParentsAndPreservesExistingFiles() throws {
        let root = try temporaryDirectory()
        let incoming = root.appendingPathComponent("Lectures/Incoming", isDirectory: true)
        let manager = try IngestManager(stagingDirectory: incoming)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(manager.stagingDirectory, incoming)

        let existing = incoming.appendingPathComponent("existing.m4a")
        let original = Data("existing lecture".utf8)
        try original.write(to: existing)
        _ = try IngestManager(stagingDirectory: incoming)
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    func testInitializationRejectsFileInPlaceOfDirectory() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Incoming")
        try Data("not a directory".utf8).write(to: file)
        XCTAssertThrowsError(try IngestManager(stagingDirectory: file))
    }

    func testInitializationRejectsNonFileURL() {
        XCTAssertThrowsError(try IngestManager(stagingDirectory: URL(string: "https://example.com/incoming")!))
    }

    func testOutputNameUsesLocalGregorianTimeAndDoesNotCreateFile() throws {
        let manager = try IngestManager(stagingDirectory: temporaryDirectory())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"

        let before = formatter.string(from: Date())
        let output = manager.makeOutputFileURL(courseCode: "CS182")
        let after = formatter.string(from: Date())
        XCTAssertTrue([before, after].map { "CS182_\($0).m4a" }.contains(output.lastPathComponent))
        XCTAssertEqual(output.deletingLastPathComponent(), manager.stagingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testUnsafeCourseCodesStayInsideStagingDirectory() throws {
        let manager = try IngestManager(stagingDirectory: temporaryDirectory())
        for (input, prefix) in [("../../CS.182//", "CS-182_"), ("", "LECTURE_"), ("..//", "LECTURE_")] {
            let output = manager.makeOutputFileURL(courseCode: input)
            XCTAssertEqual(output.deletingLastPathComponent(), manager.stagingDirectory)
            XCTAssertTrue(output.lastPathComponent.hasPrefix(prefix))
            XCTAssertEqual(output.pathExtension, "m4a")
        }
        XCTAssertTrue(manager.makeOutputFileURL(courseCode: "CS_182-A").lastPathComponent.hasPrefix("CS_182-A_"))
        XCTAssertTrue(manager.makeOutputFileURL(courseCode: "ICS 46").lastPathComponent.hasPrefix("ICS 46_"))
    }

    func testCourseValidationRejectsEmptyWhitespaceAndPathSeparators() {
        for course in ["CS182", "CS_182-A"] {
            XCTAssertTrue(IngestManager.isValidCourseCode(course))
        }
        for course in ["", " ", "../CS182", "CS/182", "CS.182", "CS\n182", " CS182", "CS182 "] {
            XCTAssertFalse(IngestManager.isValidCourseCode(course))
        }
        XCTAssertTrue(IngestManager.isValidCourseCode("CS 182"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
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
