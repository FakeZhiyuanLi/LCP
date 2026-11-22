import SwiftUI
import AppKit
import Combine
import Darwin
import LCPClient
import LCPContextCore
import LCPContextServices

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var state = ContextState()
    @Published var selection: WorkspaceRoute? = .welcome {
        didSet {
            if selection != oldValue {
                if selection == .capture, case .classDetail(let id) = oldValue, !captureInProgress {
                    captureClassID = id
                }
                searchResults = []; searchOmissions = []; searchHasRun = false
                searchOffset = 0; searchNextOffset = nil; searchTotal = 0
                searchSelectedMaterialIDs = []; searchMaterialsOnly = false; searchTimeLimited = false
            }
            persistPresentation()
        }
    }
    @Published var editingTermID: UUID?
    @Published var presentedEditor: WorkspaceEditor?
    @Published var presentedCitation: SourceCitation?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var showArchived = false
    @Published var searchText = ""
    @Published var searchMaterialsOnly = false
    @Published var searchSelectedMaterialIDs: Set<UUID> = []
    @Published var searchTimeLimited = false
    @Published var searchEventFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var searchEventUntil = Date()
    @Published var presentedContextExportClassID: UUID?
    @Published var searchResults: [ContextSearchResult] = []
    @Published var searchHasRun = false
    @Published var searchOmissions: [String] = []
    @Published var searchOffset = 0
    @Published var searchNextOffset: Int?
    @Published var searchTotal = 0
    @Published var isReady = false
    @Published var missingPayloadCount = 0
    @Published var restoreURL: URL?
    @Published private(set) var libraryTransfer: LibraryTransfer?
    private var transferTask: Task<Void, Never>?
    private var quittingDuringTransfer = false
    @Published var captureIsRecording = false
    @Published var captureClassID: UUID?
    var driveFolderTask: Task<Void, Never>?
    var driveFolderRetryTask: Task<Void, Never>?
    @Published var driveFolderFeedback: [UUID: String] = [:]
    var driveFolderRetryAfter: [UUID: Date] = [:]
    @Published var capture: CaptureCoordinator?
    var captureInProgress: Bool { captureIsRecording || capture?.state == .requestingPermission }
    @Published var canvasSyncInterval: CanvasSyncInterval = .hourly
    @Published private(set) var canvasSyncStatus = "Canvas coursework refresh is waiting for setup."
    @Published private(set) var canvasSyncLastRun: Date?
    @Published private(set) var canvasSyncPendingReviews: [CourseworkImportReview] = []
    @Published private(set) var canvasSyncInProgress = false
    @Published var presentedCanvasCourseworkReview: CourseworkImportReview?
    private var canvasSyncTask: Task<Void, Never>?
    private var canvasSyncLastAttempt: Date?
    private var captureSubscriptions = Set<AnyCancellable>()
    @Published var rootURL: URL
    private let usesPersistentProfilePreference: Bool
    private var lastImportedFeedIndex: Data?
    private var lastAttemptedFeedIndex: Data?
    private var lastFeedError: String?
    private var automaticFeedSuspendedIndex: Data?
    private var queuedWorkspaceAction: String?
    private var runningWorkspaceAction: String?
    var repository: ContextRepository?

    var selectedClassID: UUID? {
        if case .classDetail(let id) = selection { return id }
        return nil
    }
    var selectedClass: ClassEnrollment? { state.classes.first { $0.id == selectedClassID } }
    var visibleClasses: [ClassEnrollment] {
        state.classes.filter { showArchived || !$0.archived }.sorted {
            let order = $0.shortLabel.localizedStandardCompare($1.shortLabel)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var visibleClassGroups: [WorkspaceClassGroup] {
        let classesByTerm = Dictionary(grouping: visibleClasses, by: \.termID)
        var groups = state.terms.filter { showArchived || !$0.archived }.map { term in
            WorkspaceClassGroup(term: term, classes: classesByTerm[term.id] ?? [])
        }
        if let ungrouped = classesByTerm[nil] {
            groups.append(WorkspaceClassGroup(term: nil, classes: ungrouped))
        }
        return groups
    }

    private static let canvasSyncIntervalKey = "LCPDesktop.canvasSyncInterval"
    private static func canvasSyncLastRunKey(for root: URL) -> String {
        "LCPDesktop.canvasSyncLastRun.\(root.standardizedFileURL.path)"
    }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        usesPersistentProfilePreference = !arguments.contains("--profile-root") && !arguments.contains("--demo") && ProcessInfo.processInfo.environment["LCP_DESKTOP_ROOT"] == nil
        if let index = arguments.firstIndex(of: "--profile-root"), arguments.indices.contains(index + 1) {
            rootURL = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else if let customRoot = ProcessInfo.processInfo.environment["LCP_DESKTOP_ROOT"], !customRoot.isEmpty {
            rootURL = URL(fileURLWithPath: customRoot, isDirectory: true)
        } else if arguments.contains("--demo") {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-Desktop-Demo", isDirectory: true)
        } else if let preferred = UserDefaults.standard.string(forKey: "LCPDesktopLibraryRoot"), !preferred.isEmpty {
            rootURL = URL(fileURLWithPath: preferred, isDirectory: true)
        } else {
            rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LCP Desktop", isDirectory: true)
        }
        if let raw = UserDefaults.standard.object(forKey: Self.canvasSyncIntervalKey) as? Int,
           let saved = CanvasSyncInterval(rawValue: raw) {
            canvasSyncInterval = saved
        }
        canvasSyncLastRun = UserDefaults.standard.object(forKey: Self.canvasSyncLastRunKey(for: rootURL)) as? Date
        do {
            repository = try ContextRepository(rootURL: rootURL)
            refresh()
            if arguments.contains("--demo") && state.classes.isEmpty { try seedDemo() }
            else { restorePresentation() }
            isReady = true
            canvasSyncStatus = canvasSyncInterval == .manual
                ? "Canvas coursework refresh is manual."
                : "Canvas coursework refresh is scheduled (\(canvasSyncInterval.label.lowercased()))."
            processPendingDriveFolders()
            refreshCanvasReviewQueue()
            if allowsSyntheticDiagnostics, arguments.contains("--render-preview"), arguments.contains("--preview-overview") {
                selection = .welcome
            }
            if allowsSyntheticDiagnostics, arguments.contains("--review-context-share"), let classID = selectedClassID {
                presentedContextExportClassID = classID
            }
        } catch { errorMessage = "The library could not be opened. Your files have been preserved. \(error.localizedDescription)" }
    }

    func refresh() {
        guard let repository else { return }
        do {
            try repository.refresh()
            if state != repository.state { state = repository.state }
            missingPayloadCount = repository.unavailablePayloads.count
        } catch { errorMessage = "The library could not be refreshed. Current context is preserved. \(error.localizedDescription)" }
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation(); refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    func mutate(_ operation: (inout ContextState) throws -> Void) {
        guard let repository else { return }
        perform { try repository.update(operation) }
    }

    func setCanvasSyncInterval(_ interval: CanvasSyncInterval) {
        canvasSyncInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: Self.canvasSyncIntervalKey)
        canvasSyncLastAttempt = nil
        if interval == .manual {
            canvasSyncTask?.cancel()
            canvasSyncTask = nil
            canvasSyncStatus = "Canvas coursework refresh is manual."
        } else {
            canvasSyncStatus = "Canvas coursework refresh is scheduled (\(interval.label.lowercased()))."
            maybeSyncCanvas()
        }
    }

    func syncCanvasNow() {
        startCanvasSync(force: true)
    }

    func maybeSyncCanvas() {
        guard canvasSyncInterval != .manual,
              let lastAttempt = canvasSyncLastAttempt else {
            if canvasSyncInterval != .manual { startCanvasSync(force: false) }
            return
        }
        guard Date.now.timeIntervalSince(lastAttempt) >= canvasSyncInterval.seconds else { return }
        startCanvasSync(force: false)
    }

    func linkCanvasCourse(classID: UUID, courseID: String) {
        guard Int64(courseID).map({ $0 > 0 }) == true, let repository else { return }
        do {
            try repository.update { state in
                guard let index = state.classes.firstIndex(where: { $0.id == classID }) else {
                    throw DesktopUIError.message("This class is no longer in the library.")
                }
                state.classes[index].canvasCourseID = courseID
                state.classes[index].canvasAutoImportEnabled = true
            }
            refresh()
            notice = "Canvas course linked. Automatic refresh is now enabled for this class."
            syncCanvasNow()
        } catch { errorMessage = error.localizedDescription }
    }

    func setCanvasAutoImport(classID: UUID, enabled: Bool) {
        guard let repository else { return }
        var hasLinkedCourse = false
        do {
            try repository.update { state in
                guard let index = state.classes.firstIndex(where: { $0.id == classID }) else {
                    throw DesktopUIError.message("This class is no longer in the library.")
                }
                state.classes[index].canvasAutoImportEnabled = enabled
                hasLinkedCourse = state.classes[index].canvasCourseID != nil
            }
            refresh()
            notice = enabled
                ? "Automatic Canvas import is enabled for this class."
                : "Automatic Canvas import is paused for this class."
            if enabled && hasLinkedCourse { syncCanvasNow() }
        } catch { errorMessage = error.localizedDescription }
    }

    func unlinkCanvasCourse(classID: UUID) {
        guard let repository else { return }
        do {
            try repository.update { state in
                guard let index = state.classes.firstIndex(where: { $0.id == classID }) else {
                    throw DesktopUIError.message("This class is no longer in the library.")
                }
                state.classes[index].canvasCourseID = nil
                state.classes[index].canvasAutoImportEnabled = nil
            }
            refresh()
            notice = "Automatic Canvas refresh is disabled for this class."
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshCanvasReviewQueue() {
        guard let repository else {
            canvasSyncPendingReviews = []
            return
        }
        var reviews: [CourseworkImportReview] = []
        for material in state.materials where material.kind == "uci-canvas" {
            do {
                let review = try CourseworkService(repository: repository).reviewCanvasMaterial(material.id)
                if review.previous == nil || review.proposed != review.previous {
                    reviews.append(review)
                }
            } catch { continue }
        }
        canvasSyncPendingReviews = reviews.sorted { $0.proposed.title.localizedStandardCompare($1.proposed.title) == .orderedAscending }
    }

    func presentNextCanvasReview() {
        refreshCanvasReviewQueue()
        presentedCanvasCourseworkReview = canvasSyncPendingReviews.first
    }

    private func startCanvasSync(force: Bool) {
        guard isReady, repository != nil, !restorePending, !canvasSyncInProgress else { return }
        if !force, canvasSyncInterval == .manual { return }
        let credentials = UniversityCredentials.forLibrary(rootURL)
        guard (try? credentials.hasCanvasToken()) == true else {
            canvasSyncStatus = "Connect UCI Canvas to enable automatic coursework refresh."
            canvasSyncLastAttempt = Date.now
            return
        }
        let token: String
        do { token = try credentials.canvasToken() }
        catch {
            canvasSyncStatus = "Connect UCI Canvas to enable automatic coursework refresh."
            canvasSyncLastAttempt = Date.now
            return
        }
        let activeClasses = state.classes.filter { !$0.archived }
        guard !activeClasses.isEmpty else {
            canvasSyncStatus = "Add a class before enabling Canvas coursework refresh."
            canvasSyncLastAttempt = Date.now
            return
        }
        let linkedClasses = activeClasses.filter { $0.canvasCourseID != nil }
        guard !linkedClasses.isEmpty else {
            canvasSyncStatus = "Link a Canvas course to a class in University Services to enable automatic refresh."
            canvasSyncLastAttempt = Date.now
            return
        }
        let importingClasses = linkedClasses.filter { $0.canvasAutoImportEnabled != false }
        guard !importingClasses.isEmpty else {
            canvasSyncStatus = "Automatic Canvas import is paused for every linked class."
            canvasSyncLastAttempt = Date.now
            return
        }
        canvasSyncLastAttempt = Date.now
        canvasSyncInProgress = true
        canvasSyncStatus = "Refreshing Canvas coursework…"
        let client = UciCanvasClient(token: token)
        canvasSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.canvasSyncInProgress = false
                self.canvasSyncTask = nil
            }
            do {
                let courses = try await client.allCourses()
                try Task.checkCancellation()
                let matching = CanvasCourseworkSyncService.match(classes: importingClasses, courses: courses)
                let batch = try await CanvasCourseworkSyncService().fetch(client: client, matches: matching.matches)
                try Task.checkCancellation()
                guard !self.restorePending else {
                    self.canvasSyncStatus = "Canvas refresh paused while the library is being restored."
                    return
                }
                guard let repository = self.repository else { return }
                var newMaterials = 0
                var revisedMaterials = 0
                var unchangedMaterials = 0
                var failures = batch.skipped
                for source in batch.sources {
                    try Task.checkCancellation()
                    guard !self.restorePending else {
                        self.canvasSyncStatus = "Canvas refresh paused while the library is being restored."
                        return
                    }
                    guard let remoteID = source.document.remoteID, !remoteID.isEmpty else {
                        failures.append("\(source.item.title): Canvas did not provide a stable source identity")
                        continue
                    }
                    let beforeMaterials = repository.state.materials.count
                    let beforeRevisions = repository.state.materialRevisions.count
                    do {
                        _ = try MaterialService(repository: repository).importUniversityDocument(
                            source.document, classID: source.match.classID, provider: "uci-canvas",
                            remoteID: remoteID, title: source.item.title)
                        let materialDelta = repository.state.materials.count - beforeMaterials
                        let revisionDelta = repository.state.materialRevisions.count - beforeRevisions
                        if materialDelta > 0 { newMaterials += materialDelta }
                        else if revisionDelta > 0 { revisedMaterials += revisionDelta }
                        else { unchangedMaterials += 1 }
                    } catch {
                        failures.append("\(source.item.title): \(error.localizedDescription)")
                    }
                }
                self.refresh()
                self.refreshCanvasReviewQueue()
                let completedAt = Date.now
                self.canvasSyncLastRun = completedAt
                UserDefaults.standard.set(completedAt, forKey: Self.canvasSyncLastRunKey(for: self.rootURL))
                let pending = self.canvasSyncPendingReviews.count
                var message = "Canvas refreshed \(batch.sources.count) source(s). \(newMaterials) new, \(revisedMaterials) updated, \(unchangedMaterials) unchanged."
                if pending > 0 { message += " \(pending) coursework item(s) await review." }
                if !matching.unmatched.isEmpty { message += " \(matching.unmatched.count) linked class(es) need attention." }
                if !failures.isEmpty { message += " \(failures.count) item(s) were skipped." }
                self.canvasSyncStatus = message
            } catch is CancellationError {
                self.canvasSyncStatus = "Canvas refresh cancelled."
            } catch {
                self.canvasSyncStatus = "Canvas refresh failed. \(error.localizedDescription)"
            }
        }
    }

    /// Global commands share the workspace's presenter. Reserve the next turn
    /// and recheck after bringing it forward; AppKit panels run nested event loops.
    func inWorkspace(_ actionName: String, _ action: @escaping @MainActor @Sendable () -> Void) {
        guard let delegate = DesktopAppDelegate.active else {
            notice = "LCP is still opening its workspace. Try \(actionName) again when it is ready."
            return
        }
        delegate.showWorkspace()
        guard canBeginWorkspaceAction(actionName) else { return }
        queuedWorkspaceAction = actionName
        DispatchQueue.main.async { [self] in
            queuedWorkspaceAction = nil
            guard canBeginWorkspaceAction(actionName) else { return }
            runningWorkspaceAction = actionName
            defer { runningWorkspaceAction = nil }
            action()
        }
    }
    private func canBeginWorkspaceAction(_ actionName: String) -> Bool {
        let blocker: String?
        if libraryTransfer == .restore { blocker = "library restore" }
        else if let queuedWorkspaceAction { blocker = "the pending \(queuedWorkspaceAction) action" }
        else if let runningWorkspaceAction { blocker = "the \(runningWorkspaceAction) action" }
        else if presentedEditor != nil { blocker = "the current editor" }
        else if presentedCitation != nil { blocker = "the source reader" }
        else if presentedContextExportClassID != nil { blocker = "the context export review" }
        else if restoreURL != nil { blocker = "the restore confirmation" }
        else if errorMessage != nil { blocker = "the current error alert" }
        else if NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0.attachedSheet != nil }) { blocker = "the open dialog" }
        else { blocker = nil }
        guard let blocker else { return true }
        notice = "Finish or cancel \(blocker) before choosing \(actionName). Your current work is preserved."
        return false
    }
    func importMaterials(for target: UUID? = nil) {
        guard let classID = target ?? selectedClassID else { return }
        inWorkspace("Import Material") { [self] in importMaterialsInWorkspace(for: classID) }
    }
    private func importMaterialsInWorkspace(for classID: UUID) {
        guard let course = state.classes.first(where: { $0.id == classID }), let repository else { return }
        let classLabel = course.shortLabel
        let panel = NSOpenPanel()
        panel.title = "Add Materials to \(classLabel)"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "LCP keeps an immutable copy of each original. Text, Markdown, PDF, and RTF can be searched."
        guard panel.runModal() == .OK else { return }
        perform {
            let service = MaterialService(repository: repository)
            for url in panel.urls { _ = try service.importMaterial(from: url, classID: classID) }
            notice = "Added \(panel.urls.count) material\(panel.urls.count == 1 ? "" : "s") to \(classLabel)."
        }
    }
    func runSearch(offset: Int = 0) {
        guard let classID = selectedClassID, let repository else { return }
        perform {
            let materials = searchMaterialsOnly ? searchSelectedMaterialIDs.sorted { $0.uuidString < $1.uuidString } : nil
            guard !searchMaterialsOnly || !searchSelectedMaterialIDs.isEmpty else { throw DesktopUIError.message("Choose at least one material, or select all class context.") }
            let page = try RetrievalService(repository: repository).search(ContextQuery(classIDs: [classID], text: searchText, limit: 40, offset: offset,
                materialIDs: materials, eventFrom: searchTimeLimited ? searchEventFrom : nil, eventUntil: searchTimeLimited ? searchEventUntil : nil))
            searchResults = page.results; searchOmissions = page.omissions; searchOffset = offset
            searchNextOffset = page.nextOffset; searchTotal = page.total; searchHasRun = true
        }
    }
    func openCitationURL(_ url: URL, delivery: String, onPresented: @escaping @MainActor @Sendable () -> Void) {
        inWorkspace("Open Citation") { [self] in
            if let citation = resolveAndPresentCitationURL(url) {
                recordCitationEvent(citation, delivery: delivery)
                onPresented()
            }
        }
    }
    private func resolveAndPresentCitationURL(_ url: URL) -> SourceCitation? {
        do {
            guard let repository else { throw DesktopUIError.message("Open a local library before resolving a citation.") }
            try repository.refresh(); state = repository.state
            let citation = try CitationLink.decode(url)
            guard state.classes.contains(where: { $0.id == citation.classID }) else {
                throw DesktopUIError.message("This citation belongs to another library or a class that is unavailable.")
            }
            _ = try RetrievalService(repository: repository).resolve(citation)
            selection = .classDetail(citation.classID)
            presentedCitation = citation
            return citation
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    var allowsSyntheticDiagnostics: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--profile-root"), arguments.contains("--demo") || arguments.contains("--synthetic-fixture") else { return false }
        let path = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoots = [URL(fileURLWithPath: "/tmp", isDirectory: true), URL(fileURLWithPath: "/private/tmp", isDirectory: true), FileManager.default.temporaryDirectory]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return allowedRoots.contains { path.hasPrefix($0 + "/") }
    }
    func recordCitationEvent(_ citation: SourceCitation, delivery: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard allowsSyntheticDiagnostics, let index = arguments.firstIndex(of: "--event-receipt"), arguments.indices.contains(index + 1) else { return }
        struct Receipt: Encodable { var schemaVersion = 1; let delivery: String; let resolved = true; let classID: UUID; let sourceID: UUID; let revisionID: UUID; let payloadSHA256: String; let locator: SourceLocator; let receivedAt = Date() }
        do {
            let receipt = Receipt(delivery: delivery, classID: citation.classID, sourceID: citation.sourceID, revisionID: citation.revisionID, payloadSHA256: citation.payloadSHA256, locator: citation.locator)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let destination = URL(fileURLWithPath: arguments[index + 1])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(receipt).write(to: destination, options: .atomic)
        } catch { errorMessage = "Could not write the synthetic citation event receipt: \(error.localizedDescription)" }
    }
    func exportBackup() {
        inWorkspace("Back Up Library") { [self] in exportBackupInWorkspace() }
    }
    private func exportBackupInWorkspace() {
        guard let repository, libraryTransfer == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up LCP Library"
        panel.nameFieldStringValue = "LCP-Backup-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
        panel.message = "Choose a new folder for your class history, original materials, and saved citations."
        let audioOption = NSButton(checkboxWithTitle: "Include linked lecture audio", target: nil, action: nil)
        audioOption.state = .off
        audioOption.setAccessibilityHelp("Copies linked recordings into this backup for offline playback after restore.")
        audioOption.sizeToFit()
        panel.accessoryView = audioOption
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeAudio = audioOption.state == .on
        startTransfer(.backup) { [self] in
            try await repository.exportBackupInBackground(to: url, includingLinkedAudio: includeAudio)
            notice = "Backup saved to \(url.lastPathComponent)."
        }
    }
    func chooseRestore() {
        inWorkspace("Restore Verified Backup") { [self] in chooseRestoreInWorkspace() }
    }
    private func chooseRestoreInWorkspace() {
        guard libraryTransfer == nil else { return }
        do { try verifyRestoreCaptureIdle() } catch { notice = error.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.title = "Choose LCP Backup"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if repository == nil { recoverToNewProfile(from: url) } else { restoreURL = url }
    }
    private func recoverToNewProfile(from backupURL: URL) {
        let panel = NSSavePanel()
        panel.title = "Create a Recovered LCP Library"
        panel.nameFieldStringValue = "LCP Recovered Library"
        panel.message = "Choose a new folder name. LCP validates the entire backup before opening it. The unreadable original library is preserved in place."
        guard panel.runModal() == .OK, let newRoot = panel.url else { return }
        do { try verifyRestoreCaptureIdle() } catch { notice = error.localizedDescription; return }
        startTransfer(.restore) { [self] in
            guard !FileManager.default.fileExists(atPath: newRoot.path), newRoot.standardizedFileURL != rootURL.standardizedFileURL else { throw DesktopUIError.message("Choose a new folder name; existing folders will not be replaced.") }
            let recovered = try ContextRepository(rootURL: newRoot)
            try await recovered.restoreBackupInBackground(from: backupURL, expectedRevision: recovered.state.revision) {
                try self.verifyRestoreCanCommit()
            }
            let oldRoot = rootURL
            repository = recovered; rootURL = newRoot; state = recovered.state; missingPayloadCount = recovered.unavailablePayloads.count
            isReady = true; selection = .welcome; errorMessage = nil
            lastImportedFeedIndex = nil; lastAttemptedFeedIndex = nil
            if usesPersistentProfilePreference { UserDefaults.standard.set(newRoot.path, forKey: "LCPDesktopLibraryRoot") }
            notice = "Verified backup opened in a new library. The original remains at \(oldRoot.path). Agent grants require renewed setup."
        }
    }
    func restoreBackup() {
        // Continue the restore confirmation; a second admission would block it.
        guard let repository, let url = restoreURL else { return }
        // A native confirmation sheet may still be dismissing when verification finishes.
        // Only this specific sheet may remain attached when the validated state is committed.
        let closingConfirmation = NSApp.keyWindow?.sheetParent != nil ? NSApp.keyWindow : NSApp.keyWindow?.attachedSheet
        let expectedRevision = state.revision
        restoreURL = nil
        do { try verifyRestoreCaptureIdle() } catch { notice = error.localizedDescription; return }
        startTransfer(.restore) { [self] in
            try await repository.restoreBackupInBackground(from: url, expectedRevision: expectedRevision) {
                try self.verifyRestoreCanCommit(dismissing: closingConfirmation)
            }
            state = repository.state
            missingPayloadCount = repository.unavailablePayloads.count
            selection = .welcome
            lastImportedFeedIndex = nil
            lastAttemptedFeedIndex = nil
            notice = "Library restored after full payload validation. Agent grants require renewed setup."
        }
    }

    var restorePending: Bool {
        restoreURL != nil || libraryTransfer == .restore || queuedWorkspaceAction == "Restore Verified Backup"
            || runningWorkspaceAction == "Restore Verified Backup"
    }

    private func verifyRestoreCaptureIdle() throws {
        switch capture?.state {
        case .requestingPermission, .recording, .finalizing:
            throw DesktopUIError.message("Finish the current recording or microphone request before restoring your library.")
        default: break
        }
    }

    private func verifyRestoreCanCommit(dismissing confirmation: NSWindow? = nil) throws {
        try verifyRestoreCaptureIdle()
        let activeDialog = NSApp.windows.contains { window in
            guard let sheet = window.attachedSheet else { return false }
            return sheet !== confirmation
        } || (NSApp.modalWindow != nil && NSApp.modalWindow !== confirmation)
        guard presentedEditor == nil, presentedCitation == nil, presentedContextExportClassID == nil,
              errorMessage == nil, !activeDialog else {
            throw DesktopUIError.message("Restore stopped because a dialog is open. Finish or cancel it before restoring again.")
        }
    }

    private func startTransfer(_ transfer: LibraryTransfer, operation: @escaping @MainActor () async throws -> Void) {
        guard libraryTransfer == nil else { return }
        if transfer == .restore {
            canvasSyncTask?.cancel()
            canvasSyncTask = nil
            canvasSyncInProgress = false
            canvasSyncStatus = "Canvas refresh paused while the library is being restored."
            resetDriveFolderWork()
        }
        libraryTransfer = transfer
        transferTask = Task { @MainActor [self] in
            defer {
                libraryTransfer = nil
                transferTask = nil
                if transfer == .restore { processPendingDriveFolders() }
            }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { notice = transfer == .restore ? "Restore cancelled." : "Backup cancelled." }
            catch {
                // An export can finish while a class editor or other sheet is
                // active. Keep its draft and present the result in the workspace.
                notice = error.localizedDescription
            }
        }
    }

    func cancelLibraryTransfer() { transferTask?.cancel() }

    func exportContextBundle(for target: UUID? = nil) {
        guard let classID = target ?? selectedClassID else { return }
        inWorkspace("Export Class Context") { [self] in
            guard repository != nil, state.classes.contains(where: { $0.id == classID }) else { return }
            presentedContextExportClassID = classID
        }
    }
    @discardableResult
    func exportSelectedContext(classID: UUID, materialIDs: [UUID]?, eventFrom: Date?, eventUntil: Date?) -> Bool {
        // The scope review already owns the presenter. Its save panel is a
        // continuation, while new commands remain blocked by that review.
        guard let repository, let enrollment = state.classes.first(where: { $0.id == classID }) else { return false }
        let panel = NSSavePanel()
        panel.title = "Export Selected Class Context"
        panel.nameFieldStringValue = "\(enrollment.shortLabel.replacingOccurrences(of: "/", with: "-"))-Context"
        panel.message = "A snapshot of the scope you reviewed. Choose a new folder name. Review its manifest and omissions before sending it to an agent."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        var saved = false
        perform {
            let manifest = try RetrievalService(repository: repository).buildContextBundle(classIDs: [classID], to: url,
                materialIDs: materialIDs, eventFrom: eventFrom, eventUntil: eventUntil)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            notice = "Exported \(manifest.sources.count) source(s) in the reviewed scope. Sending the snapshot to an agent is a separate step."
            saved = true
        }
        return saved
    }
    func openOriginal(_ revision: MaterialRevision) {
        guard let repository else { return }
        perform {
            let url = try MaterialService(repository: repository).originalForOpening(revision)
            guard NSWorkspace.shared.open(url) else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                notice = "Choose an application in Finder to open this material."
                return
            }
        }
    }
    func acceptProposal(_ id: UUID) {
        guard let repository else { return }
        perform { _ = try ProposalService(repository: repository).accept(id); notice = "Reviewed proposal saved to class history." }
    }
    func rejectProposal(_ id: UUID) {
        guard let repository else { return }
        perform { try ProposalService(repository: repository).reject(id) }
    }
    func initializeCapture() {
        guard capture == nil else { return }
        perform {
            let coordinator = try CaptureCoordinator()
            coordinator.$state.sink { [weak self] state in self?.captureIsRecording = state == .recording || state == .finalizing }.store(in: &captureSubscriptions)
            coordinator.$lastFinalized.compactMap { $0 }.sink { [weak self] finalized in self?.saveFinalizedCapture(finalized) }.store(in: &captureSubscriptions)
            capture = coordinator
        }
    }
    func openCapture() {
        inWorkspace("Open Capture") { self.selection = .capture }
    }
    private func saveFinalizedCapture(_ finalized: FinalizedCapture) {
        let session = finalized.session
        let recording = LectureRecording(id: session.id, classID: session.academicClassID, filename: finalized.filename,
            sizeBytes: finalized.sizeBytes, sha256: finalized.sha256, capturedAt: session.startedAt,
            timeZoneID: session.timeZoneIdentifier, status: LectureStatusFacts(finalizedLocally: "yes"), localAudioPath: finalized.audioURL.path)
        var associationConflict = false
        mutate { state in
            if let index = state.recordings.firstIndex(where: { $0.id == recording.id || ($0.filename == recording.filename && $0.sha256 == recording.sha256 && $0.sizeBytes == recording.sizeBytes) }) {
                if let confirmedClassID = state.recordings[index].classID, let capturedClassID = recording.classID, confirmedClassID != capturedClassID { associationConflict = true }
                else if state.recordings[index].classID == nil { state.recordings[index].classID = recording.classID }
                state.recordings[index].capturedAt = recording.capturedAt
                state.recordings[index].timeZoneID = recording.timeZoneID
                state.recordings[index].localAudioPath = recording.localAudioPath
                state.recordings[index].status.finalizedLocally = "yes"
            } else { state.recordings.append(recording) }
        }
        if associationConflict { notice = "Recording finalized and local audio facts retained. Its existing class association differs from the capture session; review the lecture association before changing it." }
    }
    func prepareToTerminate() -> Bool {
        if quittingDuringTransfer { return true }
        guard let transferTask else { return capture?.deferApplicationTermination() ?? false }
        quittingDuringTransfer = true
        transferTask.cancel()
        if capture?.state == .recording { capture?.stop() }
        Task { @MainActor [self] in
            await transferTask.value
            if capture?.deferApplicationTermination() != true {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            quittingDuringTransfer = false
        }
        return true
    }
    func pollLocalChanges() {
        guard !restorePending else { return }
        refresh()
        processPendingDriveFolders()
        maybeSyncCanvas()
        guard let repository else { return }
        let feed = rootURL.appendingPathComponent("Feed", isDirectory: true)
        let index = feed.appendingPathComponent("index.json")
        guard let bytes = readFeedIndexHint(index), bytes != lastImportedFeedIndex, bytes != automaticFeedSuspendedIndex else { return }
        do {
            _ = try FeedImporter(repository: repository).importGeneration(from: feed)
            lastImportedFeedIndex = bytes; lastAttemptedFeedIndex = bytes; lastFeedError = nil
            refresh()
        } catch {
            let message = error.localizedDescription
            if bytes != lastAttemptedFeedIndex || message != lastFeedError {
                notice = "The latest lecture feed is incomplete or invalid. The previous verified generation remains available. \(message)"
            }
            lastAttemptedFeedIndex = bytes; lastFeedError = message
        }
    }
    func confirmUnpinnedCacheCleanup() {
        inWorkspace("Clear Unpinned Transcript Cache") { [self] in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Clear disposable transcript caches?"
            alert.informativeText = "Authored notes, bookmarks, original materials, and pinned source revisions remain. You can explicitly import the same feed later to recover available current transcript content."
            alert.addButton(withTitle: "Cancel")
            let clear = alert.addButton(withTitle: "Clear Unpinned Cache")
            clear.hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            purgeUnpinnedTranscriptCaches()
        }
    }
    private func purgeUnpinnedTranscriptCaches() {
        guard let repository else { return }
        perform {
            _ = try repository.purgeUnpinnedTranscriptCaches()
            lastImportedFeedIndex = nil; lastAttemptedFeedIndex = nil
            automaticFeedSuspendedIndex = readFeedIndexHint(rootURL.appendingPathComponent("Feed/index.json"))
            notice = "Disposable transcript caches cleared. Authored context and pinned citations remain. A later feed import can restore available current content."
        }
    }
    func importFeed(from url: URL) {
        guard let repository else { return }
        perform {
            let result = try FeedImporter(repository: repository).importGeneration(from: url)
            if url.standardizedFileURL == rootURL.appendingPathComponent("Feed", isDirectory: true).standardizedFileURL {
                lastImportedFeedIndex = readFeedIndexHint(url.appendingPathComponent("index.json")); automaticFeedSuspendedIndex = nil
            }
            notice = result.isDuplicate ? "This generation is already imported." : "Imported a complete verified generation: \(result.importedRecordings) recordings, \(result.importedTranscripts) transcript revisions."
        }
    }
    private func readFeedIndexHint(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= 8_388_608,
              let bytes = try? handle.read(upToCount: 8_388_609), bytes.count <= 8_388_608 else { return nil }
        return bytes
    }
    private func persistPresentation() {
        guard repository != nil, let selection, let bytes = try? JSONEncoder().encode(selection) else { return }
        try? bytes.write(to: rootURL.appendingPathComponent("window-context.json"), options: .atomic)
    }
    private func restorePresentation() {
        let url = rootURL.appendingPathComponent("window-context.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= 4096,
              let data = try? Data(contentsOf: url), let route = try? JSONDecoder().decode(WorkspaceRoute.self, from: data) else { return }
        if case .classDetail(let id) = route, !state.classes.contains(where: { $0.id == id }) { return }
        selection = route
    }

    private func seedDemo() throws {
        guard let repository else { return }
        let term = AcademicTerm(name: "Fictional Autumn Term", timeZoneID: "America/Los_Angeles")
        let earlier = AcademicTerm(name: "Fictional Previous Term", timeZoneID: "America/Los_Angeles", archived: true)
        let classes = [
            ClassEnrollment(termID: term.id, courseCode: "CS 201", title: "Data Structures", instructor: "Dr. Example"),
            ClassEnrollment(termID: term.id, courseCode: "PHIL 104", title: "Ethics and Technology", instructor: "Dr. Fiction"),
            ClassEnrollment(termID: term.id, courseCode: "LIT 109", title: "World Literature", instructor: "Prof. Sample"),
            ClassEnrollment(termID: earlier.id, courseCode: "CS 201", title: "Data Structures · Previous Offering", archived: true)
        ]
        try repository.update { state in
            state.terms.append(contentsOf: [term, earlier]); state.classes.append(contentsOf: classes)
        }
        let demoTexts = [
            "# Fictional CS 201 — Hash Tables\n\nHash tables associate keys with values. A hash function chooses a bucket. Collisions can be handled with chaining or open addressing.\n\nThe load factor is the number of entries divided by the number of buckets. Under uniform hashing, lookup has expected constant time. This fictional handout recommends rehashing at a load factor of 0.75.\n\nPractice: compare a chaining table and a linear probing table for the same key sequence.",
            "# Fictional PHIL 104 — Technology and Responsibility\n\nThis sample reading distinguishes intended outcomes from foreseeable consequences. A strong ethical argument states its assumptions and considers a concrete counterexample.\n\nDiscussion: who is responsible when a tool changes how people make decisions?",
            "# Fictional LIT 109 — Reading Journal\n\nThis sample course compares narrative voice across short stories. Keep quotations linked to the precise source passage and distinguish a narrator's claims from the author's position.",
            "# Fictional CS 201 — Prior Offering\n\nThis is a different enrollment in an earlier term. Its context must stay distinct from the current CS 201 class even though the code repeats."
        ]
        let fixtureFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-Demo-Materials-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureFolder) }
        for (index, enrollment) in classes.enumerated() {
            let file = fixtureFolder.appendingPathComponent(enrollment.courseCode.replacingOccurrences(of: " ", with: "-") + "-Handout-\(index + 1).md")
            try Data(demoTexts[index].utf8).write(to: file)
            _ = try MaterialService(repository: repository).importMaterial(from: file, classID: enrollment.id)
        }
        try repository.update { state in
            state.activities.append(ActivityEntry(classID: classes[0].id, kind: "study_log", title: "Review collision strategies", body: "Compared chaining and open addressing. Open question: how does clustering affect expected lookup time?"))
            state.coursework.append(CourseworkItem(classID: classes[0].id, title: "Hash Table Practice", kind: "assignment", due: .dateOnly(LocalDate(year: 2026, month: 11, day: 24)), status: "in_progress"))
        }
        refresh(); selection = .classDetail(classes[0].id)
        notice = "Demo profile: fictional classes only. Your personal library and recorder are unchanged."
    }
}

struct WorkspaceClassGroup: Identifiable {
    let term: AcademicTerm?
    let classes: [ClassEnrollment]

    var id: UUID? { term?.id }
    var title: String {
        guard let term else { return "No term" }
        return term.archived ? "\(term.name) · Archived" : term.name
    }
}

enum LibraryTransfer { case backup, restore }
enum WorkspaceRoute: Hashable, Codable { case welcome, capture, universityConnections, classDetail(UUID), connections, review }
enum WorkspaceEditor: Hashable, Identifiable {
    case newTerm, editTerm, newClass, newActivity, newCoursework, newAgentGrant, newBYOKProvider
    case editClass(UUID)
    case webLink(classID: UUID, revisionID: UUID?)
    case universityServices(classID: UUID, source: UniversitySource = .canvas)

    var id: Self { self }
}
enum DesktopUIError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let message) = self { return message }; return nil } }
