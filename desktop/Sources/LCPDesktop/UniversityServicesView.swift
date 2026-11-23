import SwiftUI
import LCPContextCore
import LCPContextServices

enum UniversitySource: String, CaseIterable, Identifiable {
    case canvas = "UCI Canvas"
    case drive = "Google Drive"
    case gmail = "Gmail"
    case calendar = "Google Calendar"
    case campus = "Gradescope & UCI"

    var id: Self { self }

    var googleKind: GoogleUniversityKind? {
        switch self {
        case .drive: return .drive
        case .gmail: return .gmail
        case .calendar: return .calendar
        default: return nil
        }
    }
}

struct UniversityServicesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @State private var source: UniversitySource
    @State private var contentHeight: CGFloat = 120

    init(model: WorkspaceModel, classID: UUID, initialSource: UniversitySource = .canvas) {
        self.model = model
        self.classID = classID
        _source = State(initialValue: initialSource)
    }

    private var destination: String {
        guard let course = model.state.classes.first(where: { $0.id == classID }) else { return "Class unavailable" }
        return [model.state.terms.first(where: { $0.id == course.termID })?.name, course.shortLabel,
                course.section.isEmpty ? nil : course.section].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("University Services").font(.title2.bold())
                    Text(destination).foregroundStyle(.secondary).lineLimit(2).help(destination)
                }
                Spacer()
                Button("Done") { model.presentedEditor = nil }.keyboardShortcut(.cancelAction)
            }
            ViewThatFits(in: .horizontal) {
                servicePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                servicePicker.pickerStyle(.menu)
            }
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Group {
                    if source == .campus {
                        CampusResourcesView(model: model, classID: classID)
                    } else {
                        UniversitySourceBrowser(model: model, classID: classID, source: source, activeSource: $source)
                            .id(source)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, 390))
            .padding(.horizontal, -4)
        }
        .padding(22)
        .frame(minWidth: 570, idealWidth: 640, maxWidth: 720, alignment: .topLeading)
        .onChange(of: model.selectedClassID) { _, newClass in
            if newClass != classID { dismiss() }
        }
        .onChange(of: model.rootURL) { _, _ in dismiss() }
    }

    private var servicePicker: some View {
        Picker("Service", selection: $source) {
            ForEach(UniversitySource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
}

@MainActor
private struct UniversitySourceBrowser: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    let source: UniversitySource
    @Binding var activeSource: UniversitySource
    @State private var connection: UniversityConnectionStatus?
    @State private var managingConnection = false
    @State private var courses: [UniversityItem] = []
    @State private var courseCursor: String?
    @State private var loadedCourses = false
    @State private var courseID: String?
    @State private var kind = CanvasItemKind.assignments
    @State private var selectedModule: UniversityItem?
    @State private var query = ""
    @State private var loadedItems = false
    @State private var items: [UniversityItem] = []
    @State private var itemCursor: String?
    @State private var selectedID: String?
    @State private var attachments: [UniversityItem] = []
    @State private var selectedAttachmentID: String?
    @State private var attachmentMessageID: String?
    @State private var status: String?
    @State private var message: String?
    @State private var isError = false
    @State private var requestID: UUID?
    @State private var request: Task<Void, Never>?
    @State private var connectionTask: Task<Void, Never>?
    @State private var courseworkReview: CourseworkImportReview?

    private var credentials: UniversityCredentials { .forLibrary(model.rootURL) }
    private var linkedCanvasCourseID: String? {
        model.state.classes.first(where: { $0.id == classID })?.canvasCourseID
    }
    private var canvasAutoImportEnabled: Bool {
        model.state.classes.first(where: { $0.id == classID })?.canvasAutoImportEnabled != false
    }
    private var selectedItem: UniversityItem? { items.first { $0.id == selectedID } }
    private var selectedAttachment: UniversityItem? {
        guard source == .gmail, selectedItem?.id == attachmentMessageID else { return nil }
        return attachments.first { $0.id == selectedAttachmentID }
    }
    private var listingModules: Bool { source == .canvas && kind == .modules && selectedModule == nil }
    private var canUseSelection: Bool {
        guard let item = selectedItem else { return false }
        if listingModules, item.metadata["locked"] == "true" {
            return false
        }
        if source == .canvas, kind == .modules, selectedModule != nil {
            return item.metadata["canvasKind"] != nil
        }
        return true
    }
    private var isBusy: Bool { status != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let connection {
                    Text(connection.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(connection?.isConfigured == true ? "Manage Connection…" : "Set Up Connection…") {
                    managingConnection = true
                }
                .disabled(isBusy)
                .accessibilityHint("Open account settings for \(source.rawValue)")
            }
            if connection?.isConfigured == true {
                if let google = source.googleKind {
                    googleControls(google)
                } else {
                    canvasControls
                }
            }
            if let status {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                    Button("Cancel Request") { cancelRequest() }
                }
            }
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(isError ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            if !items.isEmpty {
                List(items, id: \.id, selection: $selectedID) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        if !item.detail.isEmpty { Text(item.detail).foregroundStyle(.secondary).font(.caption) }
                    }.padding(.vertical, 2).tag(item.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(item.detail)
                }.frame(height: CGFloat(min(items.count, 5)) * 42 + 8)
                HStack {
                    if let cursor = itemCursor {
                        Button("More Results") { loadItems(cursor: cursor) }.disabled(isBusy)
                    }
                    if source == .gmail, selectedItem != nil {
                        Button("Load Attachments") { loadAttachments() }.disabled(isBusy)
                    }
                    Spacer()
                    Button(listingModules ? "Open Selected Module" : "Import Selected Material") {
                        guard let item = selectedItem else { return }
                        if listingModules {
                            selectedModule = item
                            loadItems()
                        } else {
                            importItem(item)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUseSelection || isBusy)
                    .help(listingModules && selectedItem?.metadata["locked"] == "true"
                          ? "This Canvas module is locked."
                          : listingModules ? "Browse the selected Canvas module."
                          : "Import the selected material into this class.")
                }
                if source == .gmail, !attachments.isEmpty {
                    Text("Message attachments").font(.headline)
                    List(attachments, id: \.id, selection: $selectedAttachmentID) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if !item.detail.isEmpty { Text(item.detail).foregroundStyle(.secondary).font(.caption) }
                        }.padding(.vertical, 2).tag(item.id)
                    }.frame(height: CGFloat(min(attachments.count, 3)) * 42 + 8)
                    HStack {
                        Spacer()
                        Button("Import Selected Attachment") {
                            if let item = selectedAttachment { importItem(item) }
                        }.buttonStyle(.borderedProminent).disabled(selectedAttachment == nil || isBusy)
                    }
                }
            } else if loadedItems {
                Text("No matching materials.").foregroundStyle(.secondary)
                if let cursor = itemCursor {
                    Button("More Results") { loadItems(cursor: cursor) }.disabled(isBusy)
                }
            }
        }
        .onAppear { readConnection() }
        .onDisappear { cancelRequest(); connectionTask?.cancel() }
        .sheet(isPresented: $managingConnection) {
            UniversityConnectionManager(service: source, model: model, onChange: connectionChanged)
        }
        .sheet(item: $courseworkReview) { CourseworkReviewView(model: model, review: $0) }
        .onChange(of: selectedID) { _, _ in
            // Attachments belong to one Gmail message. Changing the message
            // invalidates the attachment selection and requires an explicit
            // reload, preventing an old file from being imported accidentally.
            if source == .gmail {
                attachments = []
                selectedAttachmentID = nil
                attachmentMessageID = nil
            }
        }
        .onChange(of: courseID) { _, newCourseID in
            guard let newCourseID, canvasAutoImportEnabled,
                  linkedCanvasCourseID != newCourseID else { return }
            model.linkCanvasCourse(classID: classID, courseID: newCourseID)
        }
    }

    @ViewBuilder private var canvasControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: canvasAutoImportEnabled ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(canvasAutoImportEnabled ? .green : WorkspacePalette.muted)
                        Text(canvasAutoImportEnabled ? "Automatic import is on" : "Automatic import is off")
                            .font(.callout.weight(.semibold))
                    }
                    if let linkedCanvasCourseID {
                        if let linked = courses.first(where: { $0.id == linkedCanvasCourseID }) {
                            Text(linked.detail.isEmpty ? linked.title : "\(linked.title) · \(linked.detail)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("The linked Canvas course is not in the loaded course list.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Automatically import new Canvas updates", isOn: Binding(
                        get: { canvasAutoImportEnabled },
                        set: { enabled in
                            model.setCanvasAutoImport(classID: classID, enabled: enabled)
                            if enabled, let courseID, linkedCanvasCourseID != courseID {
                                model.linkCanvasCourse(classID: classID, courseID: courseID)
                            }
                        }
                    ))
                    .disabled(linkedCanvasCourseID == nil && courseID == nil)
                    if linkedCanvasCourseID != nil {
                        Button("Remove Canvas course link", role: .destructive) {
                            model.unlinkCanvasCourse(classID: classID)
                        }
                    } else {
                        Text("Select one Canvas course below. With automatic import on, the selection is saved immediately and future assignments, quizzes, announcements, and calendar updates follow the schedule in Settings → Canvas.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Canvas subscription")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Course to sync").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(loadedCourses ? "Refresh list" : "Load my courses") { loadCourses() }
                        .disabled(isBusy)
                }
                if !courses.isEmpty {
                    Picker("Canvas course to sync", selection: Binding(get: { courseID }, set: { value in
                        resetItems()
                        selectedModule = nil
                        courseID = value
                    })) {
                        Text("Choose a course").tag(nil as String?)
                        ForEach(courses, id: \.id) { course in
                            Text(course.detail.isEmpty ? course.title : "\(course.title) · \(course.detail)").tag(Optional(course.id))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let courseID {
                        if linkedCanvasCourseID == nil {
                            Label(canvasAutoImportEnabled
                                  ? "Selecting this course will subscribe this class"
                                  : "Turn on automatic import to subscribe this class",
                                  systemImage: canvasAutoImportEnabled ? "checkmark.circle" : "pause.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if linkedCanvasCourseID != courseID {
                            Label(canvasAutoImportEnabled
                                  ? "Selecting this course will switch the subscription"
                                  : "Select this course, then turn on automatic import",
                                  systemImage: canvasAutoImportEnabled ? "arrow.triangle.2.circlepath" : "pause.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("This class is subscribed to the selected course", systemImage: "checkmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if loadedCourses {
                    Text("No active Canvas courses were returned.").foregroundStyle(.secondary)
                } else {
                    Text("Load your active Canvas courses to choose one for this class.")
                        .foregroundStyle(.secondary)
                }
                if let cursor = courseCursor {
                    Button("More courses") { loadCourses(cursor: cursor) }.disabled(isBusy)
                }
            }
            .padding(.horizontal, 4)
            if courseID != nil {
                VStack(alignment: .leading, spacing: 8) {
                Picker("Course materials", selection: Binding(get: { kind }, set: { value in
                    resetItems()
                    selectedModule = nil
                    kind = value
                })) {
                    ForEach(CanvasItemKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Button("Browse") { loadItems() }.disabled(isBusy)
                }
                if let selectedModule {
                    HStack {
                        Button("All Modules") { self.selectedModule = nil; loadItems() }
                        Text(selectedModule.title).font(.headline)
                    }
                }
            }
        }
    }

    @ViewBuilder private func googleControls(_ google: GoogleUniversityKind) -> some View {
        HStack {
            TextField(google == .drive ? "Search Drive files" : google == .gmail ? "Search Gmail messages" : "Search calendar events",
                      text: Binding(get: { query }, set: { value in
                          resetItems()
                          query = value
                      }))
                .onSubmit { if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { loadItems() } }
            Button("Search") { loadItems() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
        }
        if google == .gmail {
            Text("Gmail search supports filters such as from: and subject:.")
                .font(.caption).foregroundStyle(.secondary)
        } else if google == .calendar {
            Text("Searches your primary Google Calendar. Events are imported as dated class context.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func readConnection() {
        connectionTask?.cancel()
        let source = source
        let credentials = credentials
        connectionTask = Task { @MainActor in
            let next = await UniversityConnectionStatus.readAsync(source, credentials: credentials)
            guard !Task.isCancelled else { return }
            connection = next
            if source == .canvas, next.isConfigured, !loadedCourses {
                loadCourses()
            }
            connectionTask = nil
        }
    }

    private func connectionChanged() {
        courses = []
        courseID = nil
        selectedModule = nil
        courseCursor = nil
        loadedCourses = false
        query = ""
        resetItems()
        readConnection()
        if source == .canvas { model.syncCanvasNow() }
    }

    private func loadCourses(cursor: String? = nil) {
        if cursor == nil {
            resetItems()
            courses = []
            courseID = nil
            selectedModule = nil
            courseCursor = nil
            loadedCourses = false
        }
        run("Loading Canvas courses…") {
            let client = UciCanvasClient(token: try await credentials.canvasTokenAsync())
            let page = try await client.courses(cursor: cursor)
            try checkContext()
            append(page.items, to: &courses)
            courseCursor = page.next
            loadedCourses = true
            if courseID == nil, let linkedCanvasCourseID,
               courses.contains(where: { $0.id == linkedCanvasCourseID }) {
                courseID = linkedCanvasCourseID
            }
        }
    }

    private func loadItems(cursor: String? = nil) {
        if cursor == nil { resetItems() }
        run("Loading \(source.rawValue) materials…") {
            let page: UniversityPage
            if let google = source.googleKind {
                let token = try await credentials.googleTokenAsync(google)
                try checkContext()
                page = try await GoogleUniversityClient(token: token).items(kind: google, query: query, cursor: cursor)
            } else {
                guard let courseID else { return }
                let client = UciCanvasClient(token: try await credentials.canvasTokenAsync())
                if kind == .modules, let selectedModule {
                    page = try await client.moduleItems(courseID: courseID, moduleID: selectedModule.id, cursor: cursor)
                } else {
                    page = try await client.items(courseID: courseID, kind: kind, cursor: cursor)
                }
            }
            try checkContext()
            append(page.items, to: &items)
            itemCursor = page.next
            loadedItems = true
            attachments = []
            selectedAttachmentID = nil
            attachmentMessageID = nil
        }
    }

    private func loadAttachments() {
        guard source == .gmail, let item = selectedItem else { return }
        attachments = []
        selectedAttachmentID = nil
        attachmentMessageID = nil
        run("Loading Gmail attachments…") {
            let token = try await credentials.googleTokenAsync(.gmail)
            try checkContext()
            let found = try await GoogleUniversityClient(token: token).gmailAttachments(for: item)
            try checkContext()
            guard selectedItem?.id == item.id else { return }
            attachments = found
            attachmentMessageID = item.id
            message = found.isEmpty ? "This message has no downloadable file attachments." : "Choose an attachment to import."
        }
    }

    private func importItem(_ item: UniversityItem) {
        run("Importing selected material…") {
            let doc: UniversityDocument
            let provider: String
            let remoteID: String
            if let google = source.googleKind {
                let token = try await credentials.googleTokenAsync(google)
                try checkContext()
                doc = try await GoogleUniversityClient(token: token).document(kind: google, item: item)
                provider = google == .drive ? "google-drive" : google == .gmail ? "gmail" : "google-calendar"
                if google == .gmail {
                    guard let key = item.metadata["importID"], !key.isEmpty else {
                        throw DesktopUIError.message("Search your connected mailbox again to identify this message.")
                    }
                    remoteID = key
                } else {
                    remoteID = doc.remoteID ?? item.id
                }
            } else {
                guard let courseID else { return }
                let client = UciCanvasClient(token: try await credentials.canvasTokenAsync())
                doc = try await client.document(courseID: courseID, kind: kind, item: item)
                provider = "uci-canvas"
                guard let key = doc.remoteID, !key.isEmpty else {
                    throw DesktopUIError.message("Canvas could not identify the selected material. Browse the course again.")
                }
                remoteID = key
            }
            try checkContext()
            guard let repository = model.repository else { throw DesktopUIError.message("The class library is unavailable.") }
            let stored = try MaterialService(repository: repository).importUniversityDocument(
                doc, classID: classID, provider: provider, remoteID: remoteID, title: item.title)
            model.refresh()
            message = "Saved \(stored.title) in this class’s Materials."
            if doc.courseworkContext != nil {
                courseworkReview = try CourseworkService(repository: repository).reviewCanvasMaterial(stored.id)
            }
        }
    }

    private func append(_ additions: [UniversityItem], to list: inout [UniversityItem]) {
        var known = Set(list.map(\.id))
        list.append(contentsOf: additions.filter { known.insert($0.id).inserted })
    }

    private func checkContext() throws {
        try Task.checkCancellation()
        guard activeSource == source, model.selectedClassID == classID,
              case let .universityServices(editorClassID, _) = model.presentedEditor,
              editorClassID == classID else {
            throw CancellationError()
        }
    }

    private func run(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        cancelRequest()
        let id = UUID()
        requestID = id
        status = label
        message = nil
        isError = false
        request = Task { @MainActor in
            do {
                try checkContext()
                try await operation()
            } catch {
                if !Task.isCancelled && requestID == id && !(error is CancellationError) { showError(error) }
            }
            if requestID == id {
                status = nil
                request = nil
                requestID = nil
            }
        }
    }

    private func cancelRequest() {
        request?.cancel()
        request = nil
        requestID = nil
        status = nil
    }

    private func resetItems() {
        cancelRequest()
        items = []
        itemCursor = nil
        loadedItems = false
        selectedID = nil
        attachments = []
        selectedAttachmentID = nil
        attachmentMessageID = nil
        message = nil
        isError = false
    }

    private func showError(_ error: Error) {
        message = error.localizedDescription
        isError = true
    }
}
