import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(model: model)
            .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 310)
        } detail: {
            Group {
                if !model.isReady {
                    VStack(spacing: 18) {
                        ContentUnavailableView("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text("Existing files are preserved. Recover a verified backup into a new library, or inspect the storage location in Settings."))
                        Button("Recover Backup to a New Library…") { model.chooseRestore() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    switch model.selection {
                    case .classDetail(let id):
                        if let enrollment = model.state.classes.first(where: { $0.id == id }) {
                            ClassContextView(model: model, enrollment: enrollment).id(id)
                        } else { WelcomeView(model: model) }
                    case .capture: CaptureWorkspaceView(model: model)
                    case .universityConnections: ConnectionsOverview(model: model).id(model.rootURL)
                    case .planner: ClassPlannerView(model: model, globalScope: true)
                    case .connections: AgentConnectionsView(model: model)
                    case .review: ProposalReviewView(model: model)
                    default: WelcomeView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspacePalette.canvas)
            .safeAreaInset(edge: .top) {
                if model.missingPayloadCount > 0 {
                    Label("\(model.missingPayloadCount) source payload(s) are unavailable. Existing context remains usable; relink exact originals or restore a verified backup.", systemImage: "doc.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
                    }.padding(12).background(.quaternary)
                }
            }
        }
        .tint(WorkspacePalette.accent)
        .disabled(model.libraryTransfer == .restore)
        .safeAreaInset(edge: .bottom) {
            if let transfer = model.libraryTransfer {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(transfer == .restore ? "Validating and restoring your library…" : "Backing up your library…")
                    Spacer()
                    if transfer == .restore, model.captureIsRecording {
                        Button("Stop and Finalize Recording") { model.capture?.stop() }
                    }
                    Button("Cancel") { model.cancelLibraryTransfer() }
                        .accessibilityLabel(transfer == .restore ? "Cancel restore" : "Cancel backup")
                }.padding(12).background(.bar)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.pollLocalChanges() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.pollLocalChanges() }
        .sheet(item: $model.presentedEditor) { editor in
            switch editor {
            case .newTerm: TermEditor(model: model)
            case .editTerm: TermEditor(model: model, existing: model.state.terms.first { $0.id == model.editingTermID })
            case .newClass: ClassEditor(model: model, existing: nil)
            case .editClass(let id):
                if let course = model.state.classes.first(where: { $0.id == id }) {
                    ClassEditor(model: model, existing: course)
                }
            case .newAgentGrant: NewAgentGrantView(model: model)
            case .newBYOKProvider: NewBYOKProviderView(model: model)
            case .newActivity: ActivityEditor(model: model, existing: nil)
            case .newCoursework: CourseworkEditor(model: model, existing: nil)
            case .webLink(let classID, let revisionID):
                WebLinkEditor(model: model, classID: classID, revisionID: revisionID)
            case .universityServices(let classID, let source):
                UniversityServicesView(model: model, classID: classID, initialSource: source)
            }
        }
        .sheet(item: $model.presentedCitation) { citation in CitationReaderView(model: model, citation: citation) }
        .sheet(item: $model.presentedCanvasCourseworkReview) { review in
            CourseworkReviewView(model: model, review: review)
        }
        .alert("LCP Could Not Complete This Action", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Restore this library from backup?", isPresented: Binding(get: { model.restoreURL != nil }, set: { if !$0 { model.restoreURL = nil } }), titleVisibility: .visible) {
            Button("Validate and Restore", role: .destructive) { model.restoreBackup() }
            Button("Cancel", role: .cancel) { model.restoreURL = nil }
        } message: { Text("LCP verifies the backup and all retained payloads before replacing current context. Export a current backup first if you need to retain newer work.") }
    }
}

private struct WorkspaceSidebar: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var focusedRoute: WorkspaceRoute?

    private var visibleRoutes: [WorkspaceRoute] {
        [.welcome, .capture, .universityConnections] + model.visibleClassGroups.flatMap { group in
            group.classes.map { .classDetail($0.id) }
        } + [.planner, .connections, .review]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text("LCP").font(.system(size: 22, weight: .semibold)).tracking(-1)
                    .foregroundStyle(WorkspacePalette.ink)
            }
            .padding(.leading, 15).padding(.top, 10).padding(.bottom, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        row(.welcome, title: "Class Library", icon: "square.grid.2x2")
                            .contextMenu {
                                Button("Open Class Library") { model.selection = .welcome }
                                Divider()
                                createItems
                                Divider()
                                Toggle("Show Archived", isOn: $model.showArchived)
                            }
                        row(.capture, title: "Capture", icon: "mic")
                            .contextMenu { Button("Open Capture") { model.selection = .capture } }
                        row(.universityConnections, title: "Connections", icon: "link")
                            .contextMenu { Button("Manage Connections") { model.selection = .universityConnections } }
                        ForEach(model.visibleClassGroups) { group in
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WorkspacePalette.muted)
                                .padding(.leading, 9).padding(.top, 20).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                                .contextMenu {
                                    if let term = group.term {
                                        Button("Edit Term…") { model.editingTermID = term.id; model.presentedEditor = .editTerm }
                                        Button(term.archived ? "Unarchive Term" : "Archive Term") {
                                            model.mutate { state in
                                                if let index = state.terms.firstIndex(where: { $0.id == term.id }) {
                                                    state.terms[index].archived.toggle()
                                                }
                                            }
                                        }
                                    }
                                }
                            ForEach(group.classes) { course in
                                row(.classDetail(course.id), title: course.shortLabel,
                                    subtitle: course.displayLabel == course.title ? nil : course.title, icon: "book.closed")
                                    .contextMenu { ClassMenuItems(model: model, enrollment: course, includeOpen: true) }
                            }
                        }
                        Text("Agent Access")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkspacePalette.muted)
                            .padding(.leading, 9).padding(.top, 20).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        row(.planner, title: "Study Planner", icon: "sparkles")
                            .contextMenu {
                                Button("Open Study Planner") { model.selection = .planner }
                            }
                        row(.connections, title: "Agent Connections", icon: "point.3.connected.trianglepath.dotted")
                            .contextMenu {
                                Button("Open Agent Connections") { model.selection = .connections }
                                Button("New Local Agent Grant…") {
                                    model.selection = .connections
                                    model.presentedEditor = .newAgentGrant
                                }
                                Button("Add BYOK Provider…") {
                                    model.selection = .connections
                                    model.presentedEditor = .newBYOKProvider
                                }
                            }
                        row(.review, title: "Review Proposals", icon: "checkmark.bubble",
                            count: model.state.proposals.filter { $0.state == "pending" }.count)
                            .contextMenu {
                                Button("Review Proposals") { model.selection = .review }
                                Button("Open Agent Connections") { model.selection = .connections }
                            }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
                .onChange(of: model.selection) { _, route in
                    if let route { proxy.scrollTo(route) }
                }
            }
            Divider()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(WorkspacePalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                SettingsLink { Text("Open Settings…") }
            }
            .accessibilityIdentifier("workspace-settings")
            .padding(.horizontal, 10).padding(.top, 6)
            HStack {
                Menu {
                    createItems
                } label: {
                    Label("Add", systemImage: "plus").foregroundStyle(WorkspacePalette.ink)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Toggle(isOn: $model.showArchived) {
                    Text("Archived").font(.caption).foregroundStyle(WorkspacePalette.ink)
                }
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 17).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspacePalette.surface)
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    @ViewBuilder private var createItems: some View {
        Button("New Class…") { model.presentedEditor = .newClass }
        Button("New Term…") { model.presentedEditor = .newTerm }
    }

    private func row(_ route: WorkspaceRoute, title: String, subtitle: String? = nil,
                     icon: String, count: Int = 0) -> some View {
        let selected = model.selection == route
        let outline = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let accessibilityName = [title, subtitle, count > 0 ? "\(count) pending" : nil].compactMap { $0 }.joined(separator: ", ")
        return Button {
            model.selection = route
            focusedRoute = route
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium)).frame(width: 24)
                    .foregroundStyle(selected ? WorkspacePalette.accent : WorkspacePalette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: selected || subtitle != nil ? .semibold : .regular))
                        .foregroundStyle(WorkspacePalette.ink)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(WorkspacePalette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if count > 0 {
                    Text(count.formatted()).font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(WorkspacePalette.accent)
                        .background(WorkspacePalette.tintSurface, in: Capsule())
                }
            }
            .padding(.horizontal, 9).padding(.vertical, subtitle == nil ? 8 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? WorkspacePalette.tintSurface : WorkspacePalette.surface, in: outline)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(WorkspacePalette.accent).frame(width: 3, height: 15)
                        .padding(.leading, 4)
                }
            }
            .overlay {
                if focusedRoute == route && controlActiveState != .inactive {
                    outline.strokeBorder(WorkspacePalette.accent, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(outline)
        }
        .buttonStyle(.plain)
        .focusable(true, interactions: .edit)
        .focused($focusedRoute, equals: route)
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(subtitle ?? title)
        .id(route)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let routes = visibleRoutes
        guard let focusedRoute, let index = routes.firstIndex(of: focusedRoute) else { return .ignored }
        let next = index + offset
        if routes.indices.contains(next) {
            self.focusedRoute = routes[next]
            model.selection = routes[next]
        }
        return .handled
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        let groups = model.visibleClassGroups.filter { !$0.classes.isEmpty }
        let classes = groups.flatMap(\.classes)
        let classByID = Dictionary(uniqueKeysWithValues: classes.map { ($0.id, $0) })
        let materials = model.state.materials.filter { classByID[$0.classID] != nil }
        let materialCounts = Dictionary(grouping: materials, by: \.classID).mapValues(\.count)
        let recent = materials.sorted { $0.createdAt > $1.createdAt }.prefix(5)

        GeometryReader { viewport in
            let gridWidth = min(viewport.size.width, 1030) - 64
            let columnLimit = max(1, Int((gridWidth + 12) / 206))
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Class library")
                                .font(.system(size: 36, weight: .semibold)).tracking(-1.2)
                                .accessibilityAddTraits(.isHeader)
                            if !classes.isEmpty {
                                Text("\(classes.count) \(classes.count == 1 ? "class" : "classes") · \(materials.count) \(materials.count == 1 ? "material" : "materials")")
                                    .font(.callout).foregroundStyle(WorkspacePalette.muted)
                            }
                        }
                        Spacer(minLength: 0)
                        if !classes.isEmpty {
                            Button("New Class", systemImage: "plus") { model.presentedEditor = .newClass }
                                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .controlSize(.large)
                        }
                    }

                    if classes.isEmpty {
                        emptyLibrary
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.title).font(.headline).accessibilityAddTraits(.isHeader)
                                let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: min(group.classes.count, columnLimit))
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(group.classes) { enrollment in
                                        HomeClassTile(enrollment: enrollment, materialCount: materialCounts[enrollment.id, default: 0]) {
                                            model.selection = .classDetail(enrollment.id)
                                        }
                                        .contextMenu { ClassMenuItems(model: model, enrollment: enrollment, includeOpen: true) }
                                    }
                                }
                            }
                        }
                        if !recent.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Recent materials").font(.headline).accessibilityAddTraits(.isHeader)
                                ForEach(recent) { material in
                                    if let enrollment = classByID[material.classID] {
                                        Divider()
                                        recentMaterial(material, in: enrollment)
                                    }
                                }
                            }
                        }
                    }

                    Button("Agent connections", systemImage: "point.3.connected.trianglepath.dotted") {
                        model.selection = .connections
                    }
                    .buttonStyle(.link)
                }
                .foregroundStyle(WorkspacePalette.ink)
                .padding(32)
                .frame(maxWidth: 1030, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(WorkspacePalette.canvas)
        .navigationTitle("Class library")
    }

    private var emptyLibrary: some View {
        let hasArchivedClasses = !model.state.classes.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(WorkspacePalette.accent)
                .accessibilityHidden(true)
            Text(hasArchivedClasses ? "Your classes are archived" : "Add your first class")
                .font(.title2.weight(.semibold))
            if hasArchivedClasses {
                Text("Show archived classes to revisit their materials and lectures.").foregroundStyle(WorkspacePalette.muted)
            }
            HStack {
                if hasArchivedClasses {
                    Button("Show archived classes") { model.showArchived = true }
                }
                Button("New Class…") { model.presentedEditor = .newClass }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }.padding(.top, 4)
        }
        .padding(26).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(WorkspacePalette.line) }
    }

    private func recentMaterial(_ material: SourceMaterial, in enrollment: ClassEnrollment) -> some View {
        Button {
            guard let revision = model.state.materialRevisions.first(where: { $0.id == material.currentRevisionID && $0.materialID == material.id }) else {
                model.selection = .classDetail(enrollment.id)
                return
            }
            model.presentedCitation = SourceCitation(
                classID: enrollment.id, sourceKind: "material", sourceID: material.id, revisionID: revision.id,
                payloadSHA256: revision.text?.sha256 ?? revision.original.sha256,
                label: "\(material.title) · revision \(revision.sequence)"
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: material.kind == MaterialService.webLinkKind ? "link" : "doc.text")
                    .foregroundStyle(WorkspacePalette.muted)
                    .frame(width: 32, height: 32)
                    .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(material.title).font(.body.weight(.medium)).lineLimit(2)
                    Text(enrollment.shortLabel).font(.caption).foregroundStyle(WorkspacePalette.muted)
                }
                Spacer(minLength: 8)
                Text(material.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption).foregroundStyle(WorkspacePalette.muted)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(material.title) in \(enrollment.shortLabel)")
    }
}

private struct HomeClassTile: View {
    let enrollment: ClassEnrollment
    let materialCount: Int
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    if enrollment.displayLabel == enrollment.title {
                        Image(systemName: "book.closed").font(.headline)
                            .foregroundStyle(.white).padding(.leading, 16).accessibilityHidden(true)
                    } else {
                        Text(enrollment.courseCode)
                            .font(.system(.headline, design: .monospaced, weight: .semibold))
                            .lineLimit(2).foregroundStyle(.white)
                            .padding(.leading, 16).padding(.vertical, 9)
                    }
                    Spacer(minLength: 4)
                    CourseCoverLines().frame(width: 68).clipped()
                }
                .frame(height: 56)
                .background(WorkspacePalette.cover(for: enrollment.shortLabel))

                VStack(alignment: .leading, spacing: 9) {
                    Text(enrollment.title).font(.title3.weight(.semibold)).lineLimit(2, reservesSpace: true)
                    HStack {
                        Text(enrollment.archived ? "Archived" : "\(materialCount) \(materialCount == 1 ? "material" : "materials")")
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(.caption).foregroundStyle(WorkspacePalette.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .multilineTextAlignment(.leading)
            .background(hovered ? WorkspacePalette.tintSurface : WorkspacePalette.surface)
            .clipShape(shape)
            .overlay { shape.strokeBorder(hovered ? WorkspacePalette.accent : WorkspacePalette.line) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open \(enrollment.displayLabel)")
    }
}

private struct ClassMenuItems: View {
    @ObservedObject var model: WorkspaceModel
    let enrollment: ClassEnrollment
    let includeOpen: Bool

    var body: some View {
        if includeOpen {
            Button("Open Class", systemImage: "book") { model.selection = .classDetail(enrollment.id) }
            Divider()
        }
        Button("Edit Class…", systemImage: "pencil") { model.presentedEditor = .editClass(enrollment.id) }
        Button("New Note…", systemImage: "square.and.pencil") {
            model.selection = .classDetail(enrollment.id)
            model.presentedEditor = .newActivity
        }
        Button("Plan with Agent…", systemImage: "sparkles") {
            model.openPlanner(for: enrollment.id)
        }
        Button("Import Material…", systemImage: "square.and.arrow.down") { model.importMaterials(for: enrollment.id) }
        ClassDriveFolderActions(model: model, course: enrollment)
        Button("Export Class Context…", systemImage: "square.and.arrow.up") { model.exportContextBundle(for: enrollment.id) }
        Divider()
        Button(enrollment.archived ? "Unarchive Class" : "Archive Class", systemImage: "archivebox") {
            let archive = !enrollment.archived
            model.mutate { state in
                guard let index = state.classes.firstIndex(where: { $0.id == enrollment.id }) else {
                    throw DesktopUIError.message("This class is no longer in the library.")
                }
                state.classes[index].archived = archive
            }
            if model.errorMessage == nil && archive && !model.showArchived && model.selectedClassID == enrollment.id {
                model.selection = .welcome
            }
        }
    }
}

struct ClassContextView: View {
    @ObservedObject var model: WorkspaceModel
    let enrollment: ClassEnrollment
    @State private var selectedTab = CourseSection.materials
    @State private var materialFilter = ""
    @State private var expandedMaterial: UUID?
    @State private var selectedRecording: UUID?
    @State private var showUnassigned = false
    var body: some View {
        VStack(spacing: 0) {
            courseCover
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            CourseSectionPicker(selection: $selectedTab)
                .padding(.horizontal, 20).padding(.bottom, 14)
            Group {
                switch selectedTab {
                case .planner:
                    ClassPlannerView(model: model, classID: enrollment.id)
                case .materials:
                    MaterialLibraryView(model: model, classID: enrollment.id, expandedMaterial: $expandedMaterial, filter: $materialFilter)
                case .history:
                    ActivityHistoryView(model: model, classID: enrollment.id)
                case .coursework:
                    CourseworkListView(model: model, classID: enrollment.id)
                case .search:
                    ClassSearchView(model: model, classID: enrollment.id)
                case .lectures:
                    LectureLibraryView(model: model, classID: enrollment.id, selectedRecordingID: $selectedRecording, showUnassigned: $showUnassigned)
                case .capture:
                    ClassCaptureView(model: model, enrollment: enrollment)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .navigationTitle(enrollment.shortLabel)
        .onAppear {
            activatePlannerIfRequested()
        }
        .onChange(of: model.plannerClassID) { _, _ in
            activatePlannerIfRequested()
        }
    }

    private func activatePlannerIfRequested() {
        guard model.plannerClassID == enrollment.id else { return }
        selectedTab = .planner
        model.plannerClassID = nil
    }

    private var courseCover: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                if enrollment.displayLabel != enrollment.title {
                    Text(enrollment.courseCode)
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                }
                if let term = model.state.terms.first(where: { $0.id == enrollment.termID }) {
                    Text(term.name).font(.callout).foregroundStyle(.white.opacity(0.86))
                }
                if enrollment.archived { Label("Archived", systemImage: "archivebox").font(.caption) }
                Spacer(minLength: 4)
                Menu {
                    ClassMenuItems(model: model, enrollment: enrollment, includeOpen: false)
                } label: {
                    Text("Class actions").font(.callout.weight(.medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .tint(Color(red: 0.09, green: 0.17, blue: 0.16))
                .environment(\.colorScheme, .light)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(white: 0.94), in: Capsule())
                .accessibilityLabel("Class actions").help("Class actions")
            }
            Text(enrollment.title)
                .font(.system(size: 30, weight: .semibold)).tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
            let details = [enrollment.instructor, enrollment.section, enrollment.sessionDetails ?? "", enrollment.location ?? ""]
                .filter { !$0.isEmpty }.joined(separator: "  ·  ")
            if !details.isEmpty {
                Text(details).font(.callout).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                let materials = model.state.materials.filter { $0.classID == enrollment.id }.count
                let history = model.state.activities.filter { $0.classID == enrollment.id }.count
                let lectures = model.state.recordings.filter { $0.classID == enrollment.id }.count
                Label("\(materials) \(materials == 1 ? "material" : "materials")", systemImage: "doc.on.doc")
                Label("\(history) \(history == 1 ? "entry" : "entries")", systemImage: "clock")
                Label("\(lectures) \(lectures == 1 ? "lecture" : "lectures")", systemImage: "waveform")
            }
            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            .padding(.top, 5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            WorkspacePalette.cover(for: enrollment.shortLabel)
                .overlay { LinearGradient(colors: [.black.opacity(0.46), .clear], startPoint: .leading, endPoint: .trailing) }
                .overlay(alignment: .trailing) { CourseCoverLines().frame(maxWidth: 270) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
