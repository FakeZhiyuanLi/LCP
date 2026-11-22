import Foundation

struct IngestManager {
    let stagingDirectory: URL

    private static let courseCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_ -"))

    init(
        stagingDirectory: URL? = nil,
        fileManager: FileManager = .default,
        createDirectory: Bool = true
    ) throws {
        let directory = stagingDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Lectures", isDirectory: true)
            .appendingPathComponent("Incoming", isDirectory: true)

        guard directory.isFileURL else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }

        self.stagingDirectory = directory
        if createDirectory { try prepareDirectory(using: fileManager) }
    }

    func prepareDirectory(using fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    static func isValidCourseCode(_ courseCode: String) -> Bool {
        guard !courseCode.isEmpty,
              courseCode == courseCode.trimmingCharacters(in: .whitespacesAndNewlines),
              courseCode.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        return courseCode.rangeOfCharacter(from: courseCharacters.inverted) == nil
    }

    private static func filenameStem(_ name: String) -> String {
        let stem = name.components(separatedBy: courseCharacters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return stem.isEmpty ? "LECTURE" : stem
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"

        return formatter.string(from: date)
    }

    /// The synced recorder's stable course and minute filename format.
    func makeOutputFileURL(courseCode: String) -> URL {
        let filename = "\(Self.filenameStem(courseCode))_\(Self.timestamp(Date())).m4a"
        return stagingDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    static func localRecordingURL(in directory: URL, excluding inbox: URL, academicClassID: UUID,
                                  session: CaptureSession) throws -> URL {
        guard directory.isFileURL else { throw CaptureError.invalidConfiguration }
        let root = directory.standardizedFileURL
        let folder = root.appendingPathComponent(academicClassID.uuidString, isDirectory: true)
        let inboxComponents = inbox.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for candidate in [root, folder] {
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let resolved = parent.pathComponents + [candidate.lastPathComponent]
            guard !resolved.starts(with: inboxComponents, by: { $0.caseInsensitiveCompare($1) == .orderedSame }) else {
                throw CaptureError.invalidConfiguration
            }
            // The library exists before capture. Create just the two owned folders,
            // rejecting a symlink in either location, including a dangling link.
            if mkdir(candidate.path, 0o700) != 0 && errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CaptureError.invalidConfiguration }
        }
        // Bound the filename in bytes even for multibyte class titles. The session
        // ID makes successive recordings in the same minute independently identifiable.
        let stem = filenameStem(session.destination.name.trimmingCharacters(in: .whitespacesAndNewlines))
        var prefix = ""
        for scalar in stem.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard prefix.utf8.count + scalar.utf8.count <= 100 else { break }
            prefix.unicodeScalars.append(scalar)
        }
        let filename = "\(prefix)_\(timestamp(session.startedAt))_\(session.id.uuidString).m4a"
        return folder.appendingPathComponent(filename)
    }
}
