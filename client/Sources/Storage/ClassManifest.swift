import Foundation

/// A class folder published by the server from the user's Google Drive tree.
///
/// The macOS client deliberately does not contact Google Drive.  The server
/// (or a separate sync job) writes `classes.json` into this location, and the
/// normal local file/sync mechanisms make that snapshot available to the
/// client.  `courseCode` is the exact value that will be placed in the local
/// recording filename; `name` is what the menu displays.
struct LectureClass: Codable, Equatable, Identifiable {
    let name: String
    let courseCode: String
    let driveFolderID: String?

    var id: String { courseCode }

    init(name: String, courseCode: String? = nil, driveFolderID: String? = nil) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              trimmedName.rangeOfCharacter(from: .newlines) == nil,
              trimmedName.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ClassManifestError.invalidClassName
        }

        let trimmedCode = (courseCode ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard IngestManager.isValidCourseCode(trimmedCode) else {
            throw ClassManifestError.invalidCourseCode
        }
        if let driveFolderID {
            let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            guard !driveFolderID.isEmpty,
                  driveFolderID.rangeOfCharacter(from: idCharacters.inverted) == nil else {
                throw ClassManifestError.invalidMetadata
            }
        }

        self.name = trimmedName
        self.courseCode = trimmedCode
        self.driveFolderID = driveFolderID
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case courseCode
        case snakeCaseCourseCode = "course_code"
        case driveFolderID = "drive_folder_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .name)
        let courseCode = try values.decodeIfPresent(String.self, forKey: .courseCode)
            ?? values.decodeIfPresent(String.self, forKey: .snakeCaseCourseCode)
        let driveFolderID = try values.decodeIfPresent(String.self, forKey: .driveFolderID)
        try self.init(name: name, courseCode: courseCode, driveFolderID: driveFolderID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(courseCode, forKey: .courseCode)
        try values.encodeIfPresent(driveFolderID, forKey: .driveFolderID)
    }
}

/// Versioned local snapshot of the class folders visible in Google Drive.
struct LectureClassManifest: Codable, Equatable {
    static let currentVersion = 1
    static let googleDriveSource = "google_drive"

    let version: Int
    let source: String
    let generatedAt: Date
    let rootFolderID: String
    let classes: [LectureClass]

    init(
        version: Int = Self.currentVersion,
        source: String = Self.googleDriveSource,
        generatedAt: Date,
        rootFolderID: String,
        classes: [LectureClass]
    ) throws {
        guard version == Self.currentVersion else {
            throw ClassManifestError.unsupportedVersion
        }
        guard source == Self.googleDriveSource,
              !rootFolderID.isEmpty,
              rootFolderID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ClassManifestError.invalidMetadata
        }

        // A duplicate code would make Picker tags ambiguous. Keep the input
        // order (which can be the Drive folder order) while rejecting this
        // ambiguous snapshot rather than silently choosing one class.
        var seen = Set<String>()
        for entry in classes {
            let key = entry.courseCode.caseFolded
            guard seen.insert(key).inserted else {
                throw ClassManifestError.duplicateCourseCode
            }
        }

        self.version = version
        self.source = source
        self.generatedAt = generatedAt
        self.rootFolderID = rootFolderID
        self.classes = classes
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case source
        case generatedAt = "generated_at"
        case rootFolderID = "root_folder_id"
        case classes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let source = try values.decode(String.self, forKey: .source)
        let generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        let rootFolderID = try values.decode(String.self, forKey: .rootFolderID)
        let classes = try values.decode([LectureClass].self, forKey: .classes)
        try self.init(
            version: version,
            source: source,
            generatedAt: generatedAt,
            rootFolderID: rootFolderID,
            classes: classes
        )
    }
}

enum ClassManifestError: LocalizedError, Equatable {
    case unsupportedVersion
    case invalidClassName
    case invalidCourseCode
    case duplicateCourseCode
    case invalidMetadata
    case staleManifest
    case invalidManifestShape

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "The class list uses an unsupported version."
        case .invalidClassName:
            return "The class list contains an invalid folder name."
        case .invalidCourseCode:
            return "The class list contains an invalid course code."
        case .duplicateCourseCode:
            return "The class list contains duplicate course codes."
        case .invalidMetadata:
            return "The class list is missing valid Drive metadata."
        case .staleManifest:
            return "The synced Google Drive class list is stale."
        case .invalidManifestShape:
            return "The class list has an invalid format."
        }
    }
}

/// Reads the server-published Drive-folder snapshot from local storage.
///
/// This type performs no network access.  The default path is
/// `~/Lectures/Classes/classes.json`; callers can inject a URL and file
/// manager for tests or for an alternate sync layout.
struct ClassManifestStore {
    static let defaultDirectoryName = "Classes"
    static let defaultFilename = "classes.json"
    static let defaultMaximumAge: TimeInterval = 24 * 60 * 60

    let manifestURL: URL
    let maximumAge: TimeInterval
    private let fileManager: FileManager

    init(
        manifestURL: URL? = nil,
        maximumAge: TimeInterval = Self.defaultMaximumAge,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.manifestURL = manifestURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Lectures", isDirectory: true)
            .appendingPathComponent(Self.defaultDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.defaultFilename, isDirectory: false)
        self.maximumAge = max(0, maximumAge)
    }

    /// Loads and validates the most recent local class snapshot.
    func load(now: Date = Date()) throws -> LectureClassManifest {
        guard manifestURL.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: value) {
                    return date
                }
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                guard let date = standard.date(from: value) else {
                    throw DecodingError.dataCorruptedError(
                        in: try decoder.singleValueContainer(),
                        debugDescription: "generated_at must be an ISO-8601 timestamp"
                    )
                }
                return date
            }
            let manifest = try decoder.decode(LectureClassManifest.self, from: data)
            let age = now.timeIntervalSince(manifest.generatedAt)
            guard age >= 0, age <= maximumAge else {
                throw ClassManifestError.staleManifest
            }
            return manifest
        } catch let error as ClassManifestError {
            throw error
        } catch {
            throw ClassManifestError.invalidManifestShape
        }
    }

    /// Convenience accessor for picker views that only need the entries.
    func loadClasses(now: Date = Date()) throws -> [LectureClass] {
        try load(now: now).classes
    }
}

private extension String {
    var caseFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
