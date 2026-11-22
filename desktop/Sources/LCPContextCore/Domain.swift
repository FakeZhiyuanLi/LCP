import Foundation
import CryptoKit

/// All academic identity is local and stable. Folder names and opaque server job
/// identifiers are attributes, never primary keys for academic records.
public struct LocalDate: Codable, Equatable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
}

public enum AcademicDeadline: Codable, Equatable, Sendable {
    case dateOnly(LocalDate)
    case timed(instant: Date, timeZoneID: String)
}

public struct AcademicTerm: Codable, Equatable, Identifiable, Sendable {
    public static let defaultTimeZoneID = "America/Los_Angeles"
    public var id: UUID
    public var name: String
    public var startDate: LocalDate?
    public var endDate: LocalDate?
    public var timeZoneID: String
    public var archived: Bool
    public init(id: UUID = UUID(), name: String, startDate: LocalDate? = nil, endDate: LocalDate? = nil,
                timeZoneID: String = AcademicTerm.defaultTimeZoneID, archived: Bool = false) {
        self.id = id; self.name = name; self.startDate = startDate; self.endDate = endDate
        self.timeZoneID = timeZoneID; self.archived = archived
    }
}

public struct AcademicCourse: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var code: String
    public var title: String
    public init(id: UUID = UUID(), code: String, title: String) { self.id = id; self.code = code; self.title = title }
}

public struct RecordingDestination: Codable, Equatable, Sendable {
    public var driveFolderID: String
    public var exactCourseCode: String
    public init(driveFolderID: String, exactCourseCode: String) {
        self.driveFolderID = driveFolderID; self.exactCourseCode = exactCourseCode
    }
}

/// Saved with the class so a disconnected Mac can finish folder setup later.
public struct ClassDriveFolder: Codable, Equatable, Sendable {
    public let requestID: UUID
    public var name: String
    /// Prefer an existing exact class label before creating a catalog-compatible name.
    public let preferredExistingName: String?
    public var folderID: String?

    public init(for enrollment: ClassEnrollment) {
        requestID = UUID()
        let label = (enrollment.recordingDestination?.exactCourseCode ?? enrollment.shortLabel)
            .trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        let reserved = label.compare("LCP Test", options: [.caseInsensitive, .diacriticInsensitive],
                                     locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        if !label.isEmpty, label.rangeOfCharacter(from: allowed.inverted) == nil,
           label.utf8.count <= 180, !reserved {
            name = label
            preferredExistingName = nil
        } else {
            // Keep the server's folder catalog and recording filenames valid, and
            // distinguish labels such as C++ and C# after replacing punctuation.
            let filtered = label.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
                .joined(separator: "-").trimmingCharacters(in: .whitespaces)
            var stem = ""
            for character in filtered {
                guard stem.utf8.count + String(character).utf8.count <= 160 else { break }
                stem.append(character)
            }
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let digest = SHA256.hash(data: Data(key.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
            name = (stem.isEmpty ? "Class" : stem) + "-" + digest
            preferredExistingName = reserved || label.isEmpty ? nil : label
        }
    }
}

public struct DriveFolderReservation: Codable, Equatable, Sendable {
    let parentID: String
    let name: String
    let folderID: String
}

/// One student’s class, optionally associated with an academic term or recording destination.
public struct ClassEnrollment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var termID: UUID?
    public var courseID: UUID?
    /// The student's stable UCI Canvas course identifier, when automatic
    /// coursework refresh has linked this class to a Canvas course.
    public var canvasCourseID: String?
    public var courseCode: String
    public var title: String
    public var section: String
    public var instructor: String
    public var credits: Double?
    /// Student-entered meeting context; it does not imply a parsed recurring schedule.
    public var sessionDetails: String?
    public var location: String?
    public var archived: Bool
    public var recordingDestination: RecordingDestination?
    public var driveFolder: ClassDriveFolder?
    public var shortLabel: String {
        let code = courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? title : code
    }

    public var displayLabel: String {
        let label = shortLabel
        return label.caseInsensitiveCompare(title) == .orderedSame ? title : "\(label) · \(title)"
    }

    public init(id: UUID = UUID(), termID: UUID? = nil, courseID: UUID? = nil, canvasCourseID: String? = nil,
                courseCode: String = "", title: String,
                section: String = "", instructor: String = "", credits: Double? = nil,
                archived: Bool = false, recordingDestination: RecordingDestination? = nil,
                sessionDetails: String? = nil, location: String? = nil) {
        self.id = id; self.termID = termID; self.courseID = courseID; self.courseCode = courseCode
        self.canvasCourseID = canvasCourseID
        self.title = title; self.section = section; self.instructor = instructor; self.credits = credits
        self.sessionDetails = sessionDetails; self.location = location
        self.archived = archived; self.recordingDestination = recordingDestination
    }
}

/// A content-addressed file under the repository root. It never carries a caller-supplied path.
public struct PayloadReference: Codable, Equatable, Hashable, Sendable {
    public var sha256: String
    public var byteCount: UInt64
    public var mediaType: String
    public init(sha256: String, byteCount: UInt64, mediaType: String = "application/octet-stream") {
        self.sha256 = sha256; self.byteCount = byteCount; self.mediaType = mediaType
    }
}

public enum SourceLocator: Codable, Equatable, Hashable, Sendable {
    case page(Int)
    case text(startUTF8: Int, lengthUTF8: Int)
    case section(String)
    case cues(start: Int, end: Int)
    case whole
}

public struct SourceCitation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var classID: UUID
    /// material, activity, or transcript. These are deliberately portable strings.
    public var sourceKind: String
    public var sourceID: UUID
    public var revisionID: UUID
    public var payloadSHA256: String
    public var locator: SourceLocator
    public var label: String
    public init(id: UUID = UUID(), classID: UUID, sourceKind: String, sourceID: UUID,
                revisionID: UUID, payloadSHA256: String, locator: SourceLocator = .whole, label: String = "") {
        self.id = id; self.classID = classID; self.sourceKind = sourceKind; self.sourceID = sourceID
        self.revisionID = revisionID; self.payloadSHA256 = payloadSHA256; self.locator = locator; self.label = label
    }
}

public struct SourceMaterial: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var classID: UUID
    public var title: String
    public var kind: String
    public var origin: String
    public var createdAt: Date
    public var currentRevisionID: UUID?
    public init(id: UUID = UUID(), classID: UUID, title: String, kind: String = "document",
                origin: String = "imported", createdAt: Date = Date(), currentRevisionID: UUID? = nil) {
        self.id = id; self.classID = classID; self.title = title; self.kind = kind
        self.origin = origin; self.createdAt = createdAt; self.currentRevisionID = currentRevisionID
    }
}

public struct ImportedMaterialSource: Codable, Equatable, Sendable {
    public var provider: String
    public var title: String
    public var url: URL
    public var origin: String { "\(provider) · \(url.absoluteString)" }

    public init(provider: String, title: String, url: URL) {
        self.provider = provider
        self.title = title
        self.url = url
    }
}

public struct MaterialRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var materialID: UUID
    public var sequence: UInt64
    public var original: PayloadReference
    public var text: PayloadReference?
    public var extractorVersion: String
    public var createdAt: Date
    public var extractionState: String
    public var originalFilename: String
    public var importedSource: ImportedMaterialSource?
    /// Facts read from the source, not an automatic update to the student's coursework.
    public var courseworkContext: ImportedCourseworkContext?
    public init(id: UUID = UUID(), materialID: UUID, sequence: UInt64 = 1, original: PayloadReference,
                text: PayloadReference? = nil, extractorVersion: String = "", createdAt: Date = Date(),
                extractionState: String = "pending", originalFilename: String = "",
                importedSource: ImportedMaterialSource? = nil, courseworkContext: ImportedCourseworkContext? = nil) {
        self.id = id; self.materialID = materialID; self.sequence = sequence; self.original = original
        self.text = text; self.extractorVersion = extractorVersion; self.createdAt = createdAt
        self.extractionState = extractionState; self.originalFilename = originalFilename
        self.importedSource = importedSource
        self.courseworkContext = courseworkContext
    }
}

/// The source's exact deadline instant. A nil value means Canvas supplied no deadline;
/// it must never be replaced with an inferred end-of-day date.
public struct ImportedCourseworkContext: Codable, Equatable, Sendable {
    public let title: String
    public let kind: String
    public let dueAt: Date?
    public init(title: String, kind: String = "assignment", dueAt: Date? = nil) {
        self.title = title; self.kind = kind; self.dueAt = dueAt
    }
}

public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var classID: UUID
    public var kind: String
    public var title: String
    public var body: String
    public var eventAt: Date
    public var recordedAt: Date
    public var version: UInt64
    public var revisionID: UUID
    public var content: PayloadReference?
    public var citations: [SourceCitation]
    public var agentIdentity: String?
    /// nil: the agent's actual input context is unknown. []: explicitly reviewed with no LCP inputs.
    public var inputContextManifest: [SourceCitation]?
    public var supersedesID: UUID?
    public init(id: UUID = UUID(), classID: UUID, kind: String = "note", title: String, body: String = "",
                eventAt: Date = Date(), recordedAt: Date = Date(), version: UInt64 = 1,
                revisionID: UUID = UUID(), content: PayloadReference? = nil, citations: [SourceCitation] = [],
                agentIdentity: String? = nil, supersedesID: UUID? = nil,
                inputContextManifest: [SourceCitation]? = nil) {
        self.id = id; self.classID = classID; self.kind = kind; self.title = title; self.body = body
        self.eventAt = eventAt; self.recordedAt = recordedAt; self.version = version
        self.revisionID = revisionID; self.content = content; self.citations = citations
        self.agentIdentity = agentIdentity; self.supersedesID = supersedesID
        self.inputContextManifest = inputContextManifest
    }
}

/// Immutable correction history, including the exact payload used by activity citations.
public struct ActivityRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var activityID: UUID
    public var classID: UUID
    public var version: UInt64
    public var title: String
    public var body: String
    public var content: PayloadReference
    public var citations: [SourceCitation]
    public var recordedAt: Date
    public var agentIdentity: String?
    public var inputContextManifest: [SourceCitation]?
    public init(id: UUID, activityID: UUID, classID: UUID, version: UInt64, title: String, body: String,
                content: PayloadReference, citations: [SourceCitation] = [], recordedAt: Date = Date(),
                agentIdentity: String? = nil, inputContextManifest: [SourceCitation]? = nil) {
        self.id = id; self.activityID = activityID; self.classID = classID; self.version = version
        self.title = title; self.body = body; self.content = content; self.citations = citations; self.recordedAt = recordedAt
        self.agentIdentity = agentIdentity; self.inputContextManifest = inputContextManifest
    }
}

public struct CourseworkItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var classID: UUID
    public var title: String
    public var kind: String
    public var due: AcademicDeadline?
    public var status: String
    public var submissionURL: String?
    public var version: UInt64
    /// Exact reviewed Canvas assignment revision, separate from related readings or graded work.
    public var sourceCitation: SourceCitation?
    /// Optional for compatibility with earlier schema-v1 libraries and backups.
    public var relatedCitations: [SourceCitation]?
    public init(id: UUID = UUID(), classID: UUID, title: String, kind: String = "assignment",
                due: AcademicDeadline? = nil, status: String = "not_started", submissionURL: String? = nil,
                version: UInt64 = 1, sourceCitation: SourceCitation? = nil,
                relatedCitations: [SourceCitation]? = nil) {
        self.id = id; self.classID = classID; self.title = title; self.kind = kind
        self.due = due; self.status = status; self.submissionURL = submissionURL; self.version = version
        self.sourceCitation = sourceCitation; self.relatedCitations = relatedCitations
    }
}

/// Independent observations. An absent fact is unknown, never inferred from a later phase.
public struct LectureStatusFacts: Codable, Equatable, Sendable {
    public var finalizedLocally: String
    public var serverReceived: String
    public var processing: String
    public var quality: String
    public var transcriptAvailable: String
    public var drivePublication: String
    public var externalIngestion: String
    public var observedAt: Date?
    public init(finalizedLocally: String = "unknown", serverReceived: String = "unknown",
                processing: String = "unknown", quality: String = "unknown",
                transcriptAvailable: String = "unknown", drivePublication: String = "unknown",
                externalIngestion: String = "unknown", observedAt: Date? = nil) {
        self.finalizedLocally = finalizedLocally; self.serverReceived = serverReceived
        self.processing = processing; self.quality = quality; self.transcriptAvailable = transcriptAvailable
        self.drivePublication = drivePublication; self.externalIngestion = externalIngestion; self.observedAt = observedAt
    }
}

/// One reviewed academic-association change. Source audio and transcript
/// identity stay separate from the student's class organization.
public struct RecordingAssociationRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var fromClassID: UUID?
    public var toClassID: UUID?
    public var changedAt: Date
    /// Only exact citations saved before this move retain the former class's access.
    public var retainedCitations: [SourceCitation]
    public init(id: UUID = UUID(), fromClassID: UUID?, toClassID: UUID?, changedAt: Date = Date(),
                retainedCitations: [SourceCitation] = []) {
        self.id = id; self.fromClassID = fromClassID; self.toClassID = toClassID
        self.changedAt = changedAt; self.retainedCitations = retainedCitations
    }
}

public struct LectureRecording: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var classID: UUID?
    public var filename: String
    public var sizeBytes: UInt64
    public var sha256: String
    public var capturedAt: Date?
    public var timeZoneID: String?
    public var legacyLocalTimestamp: String?
    public var acceptedJobID: String?
    public var currentTranscriptRevisionID: UUID?
    public var status: LectureStatusFacts
    public var localAudioPath: String?
    public var retired: Bool
    /// nil preserves the pre-association-history schema-v1 representation.
    public var associationHistory: [RecordingAssociationRevision]?
    public init(id: UUID = UUID(), classID: UUID? = nil, filename: String, sizeBytes: UInt64, sha256: String,
                capturedAt: Date? = nil, timeZoneID: String? = nil, legacyLocalTimestamp: String? = nil,
                acceptedJobID: String? = nil, currentTranscriptRevisionID: UUID? = nil, status: LectureStatusFacts = LectureStatusFacts(),
                localAudioPath: String? = nil, retired: Bool = false,
                associationHistory: [RecordingAssociationRevision]? = nil) {
        self.id = id; self.classID = classID; self.filename = filename; self.sizeBytes = sizeBytes; self.sha256 = sha256
        self.capturedAt = capturedAt; self.timeZoneID = timeZoneID; self.legacyLocalTimestamp = legacyLocalTimestamp
        self.acceptedJobID = acceptedJobID; self.currentTranscriptRevisionID = currentTranscriptRevisionID
        self.status = status; self.localAudioPath = localAudioPath; self.retired = retired
        self.associationHistory = associationHistory
    }
}

public struct TranscriptCue: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker
    }
}

public struct TranscriptAudioEvent: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var type: String
    public init(start: Double, end: Double, text: String, type: String = "audio_event") {
        self.start = start; self.end = end; self.text = text; self.type = type
    }
}

public struct TranscriptRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var recordingID: UUID
    public var acceptedJobID: String
    public var content: PayloadReference
    public var cues: [TranscriptCue]
    public var audioEvents: [TranscriptAudioEvent]
    public var createdAt: Date
    public var duration: Double
    public init(id: UUID = UUID(), recordingID: UUID, acceptedJobID: String, content: PayloadReference,
                cues: [TranscriptCue], audioEvents: [TranscriptAudioEvent] = [], createdAt: Date = Date(), duration: Double = 0) {
        self.id = id; self.recordingID = recordingID; self.acceptedJobID = acceptedJobID; self.content = content
        self.cues = cues; self.audioEvents = audioEvents; self.createdAt = createdAt; self.duration = duration
    }
}

public struct FeedGeneration: Codable, Equatable, Sendable {
    public var id: String
    public var producer: String
    public var environment: String
    public var exportedAt: Date
    public var importedAt: Date
    public var indexSHA256: String
    public init(id: String, producer: String, environment: String, exportedAt: Date,
                importedAt: Date = Date(), indexSHA256: String) {
        self.id = id; self.producer = producer; self.environment = environment; self.exportedAt = exportedAt
        self.importedAt = importedAt; self.indexSHA256 = indexSHA256
    }
}

public struct AgentConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var clientVersion: String?
    /// snapshot, stdio, or unknown. Installation alone does not verify interoperability.
    public var mode: String
    public var capabilities: [String]
    public var verifiedAt: Date?
    public init(id: UUID = UUID(), name: String, clientVersion: String? = nil, mode: String = "unknown",
                capabilities: [String] = [], verifiedAt: Date? = nil) {
        self.id = id; self.name = name; self.clientVersion = clientVersion; self.mode = mode
        self.capabilities = capabilities; self.verifiedAt = verifiedAt
    }
}

public struct AgentGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var allowedClassIDs: [UUID]
    public var allowedMaterialIDs: [UUID]?
    public var eventFrom: Date?
    public var eventUntil: Date?
    public var createdAt: Date
    public var revokedAt: Date?
    public var isActive: Bool { revokedAt == nil }
    public init(id: UUID = UUID(), connectionID: UUID, allowedClassIDs: [UUID], allowedMaterialIDs: [UUID]? = nil,
                createdAt: Date = Date(), revokedAt: Date? = nil,
                eventFrom: Date? = nil, eventUntil: Date? = nil) {
        self.id = id; self.connectionID = connectionID; self.allowedClassIDs = allowedClassIDs
        self.allowedMaterialIDs = allowedMaterialIDs; self.createdAt = createdAt; self.revokedAt = revokedAt
        self.eventFrom = eventFrom; self.eventUntil = eventUntil
    }
}

public struct AgentProposal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var classID: UUID
    public var agentIdentity: String
    public var targetKind: String
    public var targetID: UUID?
    public var expectedVersion: UInt64?
    public var idempotencyKey: String
    public var title: String
    public var body: String
    public var citations: [SourceCitation]
    public var state: String
    public var createdAt: Date
    public var reviewedAt: Date?
    public var contextManifest: [SourceCitation]
    public init(id: UUID = UUID(), classID: UUID, agentIdentity: String, targetKind: String = "study_log",
                targetID: UUID? = nil, expectedVersion: UInt64? = nil, idempotencyKey: String,
                title: String, body: String, citations: [SourceCitation] = [], state: String = "pending",
                createdAt: Date = Date(), reviewedAt: Date? = nil, contextManifest: [SourceCitation] = []) {
        self.id = id; self.classID = classID; self.agentIdentity = agentIdentity; self.targetKind = targetKind
        self.targetID = targetID; self.expectedVersion = expectedVersion; self.idempotencyKey = idempotencyKey
        self.title = title; self.body = body; self.citations = citations; self.state = state
        self.createdAt = createdAt; self.reviewedAt = reviewedAt; self.contextManifest = contextManifest
    }
}

public struct ContextState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int = Self.currentSchemaVersion
    public var revision: UInt64 = 0
    public var terms: [AcademicTerm] = []
    public var courses: [AcademicCourse] = []
    public var classes: [ClassEnrollment] = []
    public var materials: [SourceMaterial] = []
    public var materialRevisions: [MaterialRevision] = []
    public var activities: [ActivityEntry] = []
    public var activityRevisions: [ActivityRevision] = []
    public var coursework: [CourseworkItem] = []
    public var recordings: [LectureRecording] = []
    public var transcriptRevisions: [TranscriptRevision] = []
    public var connections: [AgentConnection] = []
    public var grants: [AgentGrant] = []
    public var proposals: [AgentProposal] = []
    public var pinnedCitations: [SourceCitation] = []
    public var pinnedPayloads: [PayloadReference] = []
    public var feedGeneration: FeedGeneration?
    public var feedGenerations: [FeedGeneration] = []
    private var driveFolderReservations: [DriveFolderReservation]?
    public init() {}

    public func reservedDriveFolder(named name: String, under parentID: String) -> String? {
        driveFolderReservations?.first {
            $0.parentID == parentID && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive],
                                                       locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }?.folderID
    }

    /// Called under the repository write lock before any create request reaches Drive.
    public mutating func reserveDriveFolder(named name: String, under parentID: String, proposedID: String) -> String {
        if let saved = reservedDriveFolder(named: name, under: parentID) { return saved }
        if driveFolderReservations == nil { driveFolderReservations = [] }
        driveFolderReservations?.append(.init(parentID: parentID, name: name, folderID: proposedID))
        return proposedID
    }

    /// Resolve academic authorization for a transcript citation without
    /// granting a former class access to other cues or later revisions.
    /// The caller still verifies the exact revision, payload and locator.
    public func recordingForCitation(_ citation: SourceCitation) -> LectureRecording? {
        guard citation.sourceKind == "transcript",
              let recording = recordings.first(where: { $0.id == citation.sourceID }) else { return nil }
        if recording.classID == citation.classID { return recording }
        guard recording.associationHistory?.contains(where: {
            $0.fromClassID == citation.classID && $0.retainedCitations.contains(citation)
        }) == true else { return nil }
        return recording
    }
}
