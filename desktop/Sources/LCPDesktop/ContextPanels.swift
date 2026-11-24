import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct ClassDriveFolderActions: View {
    @ObservedObject var model: WorkspaceModel
    let course: ClassEnrollment

    var body: some View {
        if let id = course.driveFolder?.folderID {
            if id.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil,
               let url = URL(string: "https://drive.google.com/drive/folders/" + id) {
                Link(destination: url) { Label("Open Google Drive Folder", systemImage: "arrow.up.right.square") }
            }
        } else if course.driveFolder != nil {
            Button("Retry Folder Setup") { model.requestDriveFolder(for: course.id) }
            Button("Manage Connections") { model.selection = .universityConnections }
        } else {
            Button("Set Up Google Drive Folder", systemImage: "folder.badge.plus") {
                model.requestDriveFolder(for: course.id)
            }
        }
    }
}

struct MaterialLibraryView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @Binding var expandedMaterial: UUID?
    @State private var courseworkReview: CourseworkImportReview?
    @Binding var filter: String
    @FocusState private var filterFocused: Bool

    private var materials: [SourceMaterial] {
        model.state.materials.filter { $0.classID == classID }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let sources = materials
        let revisions = Dictionary(uniqueKeysWithValues: model.state.materialRevisions.map { ($0.id, $0) })
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? sources : sources.filter { material in
            let filename = material.currentRevisionID.flatMap { revisions[$0]?.originalFilename }
            return [material.title, material.origin, filename ?? ""].contains { $0.localizedStandardContains(query) }
        }
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterField.frame(minWidth: 150, maxWidth: 340)
                    Spacer(minLength: 4)
                    importActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    filterField
                    importActions
                }
            }
            if let course = model.state.classes.first(where: { $0.id == classID }) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        folderStatus(for: course)
                        Spacer(minLength: 8)
                        ClassDriveFolderActions(model: model, course: course)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        folderStatus(for: course)
                        HStack { ClassDriveFolderActions(model: model, course: course) }
                    }
                }
                .controlSize(.small)
            }
            if sources.isEmpty {
                ContentUnavailableView("Add your first material", systemImage: "tray",
                                       description: Text("Import a class file, save a web link, or choose a source from University Services."))
            } else if matches.isEmpty {
                ContentUnavailableView {
                    Label("No matching materials", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another title, filename, or source.")
                } actions: {
                    Button("Clear Filter") { filter = "" }
                }
            } else {
                List {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, material in
                        materialRow(material, current: material.currentRevisionID.flatMap { revisions[$0] },
                                    showsDivider: index < matches.count - 1)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(WorkspacePalette.line)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $courseworkReview) { CourseworkReviewView(model: model, review: $0) }
    }

    private func folderStatus(for course: ClassEnrollment) -> some View {
        Label(model.driveFolderStatus(for: course), systemImage: "folder")
            .font(.callout)
            .foregroundStyle(WorkspacePalette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(WorkspacePalette.muted).accessibilityHidden(true)
            TextField("Filter materials", text: $filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .accessibilityLabel("Filter materials by title or source")
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear material filter")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(filterFocused ? WorkspacePalette.accent : WorkspacePalette.line, lineWidth: filterFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    private var importActions: some View {
        HStack(spacing: 8) {
            Button("University Services…", systemImage: "building.columns") {
                model.presentedEditor = .universityServices(classID: classID)
            }
            Menu {
                Button("Import Files…", systemImage: "doc.badge.plus") { model.importMaterials() }
                Button("Add Web Link…", systemImage: "link") {
                    model.presentedEditor = .webLink(classID: classID, revisionID: nil)
                }
            } label: {
                Label("Add Material", systemImage: "plus")
            }
            .fixedSize()
        }
    }

    private func materialRow(_ material: SourceMaterial, current: MaterialRevision?, showsDivider: Bool) -> some View {
        let isWebLink = material.kind == MaterialService.webLinkKind
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 13) {
                Image(systemName: isWebLink ? "link" : "doc.text")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(WorkspacePalette.accent)
                    .frame(width: 36, height: 40)
                    .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(material.title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(WorkspacePalette.ink)
                        .lineLimit(2)
                    Text(sourceDetails(material, revision: current))
                        .font(.caption)
                        .foregroundStyle(WorkspacePalette.muted)
                }
                Spacer(minLength: 4)
                if let current {
                    Button("Read") { model.presentedCitation = citation(material, current) }
                        .accessibilityLabel("Read \(material.title), revision \(current.sequence)")
                }
                MoreActionsMenu(title: "Actions for material \(material.title)") {
                    if let current {
                        if isWebLink {
                            OpenWebsiteButton(model: model, revision: current, title: material.title)
                        } else {
                            Button("Open Original") { model.openOriginal(current) }
                                .accessibilityLabel("Open original of \(material.title), revision \(current.sequence)")
                        }
                        if current.courseworkContext != nil {
                            Button("Review Coursework…") { reviewCoursework(material.id) }
                        }
                        Divider()
                    }
                    if isWebLink {
                        if let revisionID = material.currentRevisionID {
                            Button("Edit Web Link…") { model.presentedEditor = .webLink(classID: classID, revisionID: revisionID) }
                        }
                    } else if MaterialService.isUniversityMaterial(material) {
                        Button("Reimport from University Services…") { model.presentedEditor = .universityServices(classID: classID) }
                    } else {
                        Button("Add Revised File…") { revise(material) }
                            .accessibilityLabel("Add revised file for \(material.title)")
                    }
                    Button(expandedMaterial == material.id ? "Hide Revision History" : "Show Revision History") {
                        expandedMaterial = expandedMaterial == material.id ? nil : material.id
                    }
                }
            }
            if expandedMaterial == material.id {
                Divider()
                ForEach(model.state.materialRevisions.filter { $0.materialID == material.id }.sorted { $0.sequence > $1.sequence }) { revision in
                    ViewThatFits(in: .horizontal) {
                        HStack { revisionLabel(revision); Spacer(); revisionActions(material, revision) }
                        VStack(alignment: .leading, spacing: 6) { revisionLabel(revision); revisionActions(material, revision) }
                    }
                }
            }
            if showsDivider {
                Divider().padding(.leading, 68)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sourceDetails(_ material: SourceMaterial, revision: MaterialRevision?) -> String {
        let isWebLink = material.kind == MaterialService.webLinkKind
        let suffix = ((revision?.originalFilename ?? "") as NSString).pathExtension.uppercased()
        let type = isWebLink ? "Web link" : (suffix.isEmpty ? material.kind.capitalized : suffix)
        var details = [type]
        if let revision {
            if let provider = revision.importedSource?.provider { details.append(provider) }
            details.append("Revision \(revision.sequence)")
            if revision.extractionState != "ready" {
                details.append(revision.extractionState.replacingOccurrences(of: "_", with: " "))
            }
        }
        return details.joined(separator: "  ·  ")
    }

    private func revisionLabel(_ revision: MaterialRevision) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Revision \(revision.sequence) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption.weight(.medium))
            Text(String(revision.original.sha256.prefix(12)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WorkspacePalette.muted)
        }
    }

    private func revisionActions(_ material: SourceMaterial, _ revision: MaterialRevision) -> some View {
        HStack {
            Button("Read Exact Revision") { model.presentedCitation = citation(material, revision) }
                .accessibilityLabel("Read \(material.title), exact revision \(revision.sequence), digest \(revision.original.sha256.prefix(12))")
            if material.kind != MaterialService.webLinkKind {
                Button("Relink Original…") { relink(revision) }
                    .accessibilityLabel("Relink original of \(material.title), revision \(revision.sequence)")
            }
        }
        .controlSize(.small)
    }
    private func reviewCoursework(_ materialID: UUID) {
        guard let repository = model.repository else { return }
        do { courseworkReview = try CourseworkService(repository: repository).reviewCanvasMaterial(materialID) }
        catch { model.errorMessage = error.localizedDescription }
    }
    private func citation(_ material: SourceMaterial, _ revision: MaterialRevision) -> SourceCitation {
        SourceCitation(classID: classID, sourceKind: "material", sourceID: material.id, revisionID: revision.id, payloadSHA256: revision.text?.sha256 ?? revision.original.sha256, label: "\(material.title) · revision \(revision.sequence)")
    }
    private func revise(_ material: SourceMaterial) {
        guard let repository = model.repository else { return }; let panel = NSOpenPanel(); panel.title = "Add Revised Material"; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.perform { _ = try MaterialService(repository: repository).reviseMaterial(materialID: material.id, from: url) }
    }
    private func relink(_ revision: MaterialRevision) {
        guard let repository = model.repository else { return }; let panel = NSOpenPanel(); panel.title = "Relink Exact Original"; panel.message = "The selected file must match this revision's original digest. A changed document belongs in a new revision."; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.perform { try MaterialService(repository: repository).relinkOriginal(revisionID: revision.id, from: url) }
    }
}

struct OpenWebsiteButton: View {
    @ObservedObject var model: WorkspaceModel
    let revision: MaterialRevision
    let title: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Website") {
            guard let repository = model.repository else { return }
            do {
                guard let url = try MaterialService(repository: repository).webURL(for: revision) else {
                    throw DesktopUIError.message("This revision has no saved website.")
                }
                openURL(url) { accepted in
                    if !accepted { model.errorMessage = "macOS could not open the saved website." }
                }
            } catch { model.errorMessage = error.localizedDescription }
        }
        .accessibilityLabel("Open website for \(title), revision \(revision.sequence)")
    }
}

struct WebLinkEditor: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    let revisionID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        let validAddress = (try? MaterialService.validatedWebURL(address)) != nil
        EditorFrame(title: revisionID == nil ? "Add Web Link" : "Edit Web Link",
                    canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validAddress,
                    save: save) {
            Form {
                TextField("Title", text: $title, prompt: Text("Course syllabus"))
                TextField("Website URL", text: $address, prompt: Text("https://"))
                    .disableAutocorrection(true)
                if !address.isEmpty && !validAddress {
                    Text("Enter a full http:// or https:// website address.").foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped)
        }
        .onAppear {
            guard !loaded, let revisionID else { return }
            loaded = true
            do {
                let revision = try sourceRevision(revisionID)
                guard let repository = model.repository,
                      let url = try MaterialService(repository: repository).webURL(for: revision),
                      let material = model.state.materials.first(where: { $0.id == revision.materialID }) else {
                    throw DesktopUIError.message("The saved web link is unavailable.")
                }
                title = material.title
                address = url.absoluteString
            } catch { failure = error.localizedDescription }
        }
    }

    private func sourceRevision(_ id: UUID) throws -> MaterialRevision {
        guard let revision = model.state.materialRevisions.first(where: { $0.id == id }),
              model.state.materials.contains(where: {
                  $0.id == revision.materialID && $0.currentRevisionID == id && $0.classID == classID
              }) else {
            throw DesktopUIError.message("This web link changed. Reopen the editor to see its current revision.")
        }
        return revision
    }

    private func save() {
        guard let repository = model.repository else { failure = "The library is unavailable."; return }
        do {
            let service = MaterialService(repository: repository)
            if let revisionID {
                let revision = try sourceRevision(revisionID)
                _ = try service.reviseWebLink(materialID: revision.materialID, title: title, urlString: address, expectedRevisionID: revisionID)
            } else {
                _ = try service.addWebLink(classID: classID, title: title, urlString: address)
            }
            model.refresh()
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

struct ActivityHistoryView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @State private var editing: ActivityEntry?
    @State private var showHistory: UUID?
    var entries: [ActivityEntry] { model.state.activities.filter { $0.classID == classID }.sorted { $0.eventAt == $1.eventAt ? $0.id.uuidString < $1.id.uuidString : $0.eventAt > $1.eventAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(entries.count == 1 ? "1 entry" : "\(entries.count) entries").font(.callout).foregroundStyle(WorkspacePalette.muted); Spacer(); Button("Log an Entry…") { model.presentedEditor = .newActivity } }
            if entries.isEmpty { ContentUnavailableView("Build Your Class History", systemImage: "square.and.pencil", description: Text("Log a lecture topic, study session, open question, or selected agent answer. Sources and authorship stay visible.")) }
            else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(entry.kind.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: entry.agentIdentity == nil ? "person.crop.circle" : "sparkles").font(.caption).foregroundStyle(entry.agentIdentity == nil ? WorkspacePalette.muted : WorkspacePalette.accent)
                            if let agent = entry.agentIdentity { Text(agent).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(entry.eventAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Button("Correct") { editing = entry }.accessibilityLabel("Correct history entry \(entry.title), revision \(entry.version)")
                        }
                        Text(entry.title).font(.headline)
                        if entry.agentIdentity != nil || entry.kind == "agent_artifact" {
                            AgentOutputView(source: entry.body)
                        } else { Text(verbatim: entry.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        if !entry.citations.isEmpty {
                            FlowCitationLinks(citations: entry.citations, open: { model.presentedCitation = $0 })
                        }
                        if entry.agentIdentity != nil || entry.kind == "agent_artifact" {
                            InputContextManifestView(manifest: entry.inputContextManifest, open: { model.presentedCitation = $0 })
                        }
                        HStack {
                            Text("Recorded \(entry.recordedAt.formatted(date: .abbreviated, time: .shortened)) · revision \(entry.version)").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button(showHistory == entry.id ? "Hide Corrections" : "Correction History") { showHistory = showHistory == entry.id ? nil : entry.id }.font(.caption)
                                .accessibilityLabel("\(showHistory == entry.id ? "Hide" : "Show") correction history for \(entry.title)")
                        }
                        if showHistory == entry.id {
                            ForEach(model.state.activityRevisions.filter { $0.activityID == entry.id }.sorted { $0.version > $1.version }) { revision in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Revision \(revision.version) · \(revision.recordedAt.formatted())").font(.caption.bold())
                                    Text(revision.title).font(.subheadline)
                                    if revision.agentIdentity != nil || entry.kind == "agent_artifact" {
                                        AgentOutputView(source: revision.body).font(.caption)
                                    } else { Text(verbatim: revision.body).font(.caption).textSelection(.enabled) }
                                    if !revision.citations.isEmpty {
                                        Text("Sources cited in revision \(revision.version)").font(.caption.bold())
                                        FlowCitationLinks(citations: revision.citations, open: { model.presentedCitation = $0 })
                                    }
                                    if revision.agentIdentity != nil || entry.agentIdentity != nil {
                                        InputContextManifestView(manifest: revision.inputContextManifest, open: { model.presentedCitation = $0 })
                                    }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.workspaceListRow()
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.sheet(item: $editing) { ActivityEditor(model: model, existing: $0) }
    }
}

struct CourseworkListView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @State private var editing: CourseworkItem?
    @State private var sourceReview: CourseworkImportReview?
    var entries: [CourseworkItem] { model.state.coursework.filter { $0.classID == classID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var body: some View {
        let pendingReviews = model.canvasSyncPendingReviews.filter { $0.proposed.classID == classID }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entries.count == 1 ? "1 coursework item" : "\(entries.count) coursework items").font(.callout).foregroundStyle(WorkspacePalette.muted)
                Spacer()
                Button("Refresh Canvas", systemImage: "arrow.clockwise") { model.syncCanvasNow() }
                    .disabled(model.canvasSyncInProgress)
                Button("University Services…") { model.presentedEditor = .universityServices(classID: classID) }
                Button("Add Coursework…") { model.presentedEditor = .newCoursework }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: model.canvasSyncInProgress ? "arrow.triangle.2.circlepath" : "graduationcap")
                        .foregroundStyle(WorkspacePalette.accent)
                    Text("Canvas coursework refresh").font(.headline)
                    Spacer()
                    if model.canvasSyncInProgress { ProgressView().controlSize(.small) }
                }
                Text(model.canvasSyncStatus).font(.callout).foregroundStyle(.secondary)
                if let lastRun = model.canvasSyncLastRun {
                    Text("Last successful refresh \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !pendingReviews.isEmpty {
                    HStack {
                        Text("\(pendingReviews.count) Canvas item(s) are ready for review.")
                            .font(.callout)
                        Spacer()
                        Button("Review next") {
                            model.presentedCanvasCourseworkReview = pendingReviews.first
                        }
                    }
                }
            }
            .padding(12)
            .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 12))
            if entries.isEmpty { ContentUnavailableView("Keep Coursework in Context", systemImage: "checklist", description: Text("Save official dates, submission links, and progress. Date-only deadlines stay date-only.")) }
            else {
                List(entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: ["completed", "submitted", "graded"].contains(entry.status) ? "checkmark.circle.fill" : "circle").foregroundStyle(["completed", "submitted", "graded"].contains(entry.status) ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.headline)
                            Text("\(entry.kind.capitalized) · \(entry.status.replacingOccurrences(of: "_", with: " "))").font(.caption).foregroundStyle(.secondary)
                            Text(entry.due?.label ?? "No official deadline recorded").font(.callout)
                            if let citation = entry.sourceCitation {
                                Text("Reviewed Canvas source").font(.caption).foregroundStyle(.secondary)
                                FlowCitationLinks(citations: [citation], open: { model.presentedCitation = $0 })
                                Button("Review Saved Canvas Facts…") { reviewSource(citation.sourceID) }
                                    .font(.caption)
                                    .accessibilityLabel("Review saved Canvas facts for \(entry.title)")
                            }
                            if let related = entry.relatedCitations, !related.isEmpty {
                                Text("Related class materials").font(.caption).foregroundStyle(.secondary)
                                FlowCitationLinks(citations: related, open: { model.presentedCitation = $0 })
                            }
                            if let text = entry.submissionURL, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") { Link("Submission Link", destination: url).font(.caption).accessibilityLabel("Submission link for \(entry.title)") }
                        }
                        Spacer(); Button("Edit") { editing = entry }.accessibilityLabel("Edit coursework \(entry.title)")
                    }.workspaceListRow()
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.sheet(item: $editing) { CourseworkEditor(model: model, existing: $0) }
            .sheet(item: $sourceReview) { CourseworkReviewView(model: model, review: $0) }
    }
    private func reviewSource(_ materialID: UUID) {
        guard let repository = model.repository else { return }
        do { sourceReview = try CourseworkService(repository: repository).reviewCanvasMaterial(materialID) }
        catch { model.errorMessage = error.localizedDescription }
    }
}

struct ClassSearchView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @State private var showScope = false
    private var materials: [SourceMaterial] {
        model.state.materials.filter { $0.classID == classID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this class's materials, notes, and lectures", text: $model.searchText).textFieldStyle(.roundedBorder).onSubmit { model.runSearch() }
                Button("Search") { model.runSearch() }.keyboardShortcut(.return, modifiers: [])
            }
            DisclosureGroup(isExpanded: $showScope) {
                SourceScopeControls(state: model.state, materials: materials, materialsOnly: $model.searchMaterialsOnly, selectedMaterialIDs: $model.searchSelectedMaterialIDs,
                    timeLimited: $model.searchTimeLimited, eventFrom: $model.searchEventFrom, eventUntil: $model.searchEventUntil)
                    .padding(.vertical, 8)
            } label: {
                Text("Scope: \(model.selectedClass?.shortLabel ?? "selected class") · " + (model.searchMaterialsOnly ? "\(model.searchSelectedMaterialIDs.count) selected material(s)" : "all source types") + (model.searchTimeLimited ? " · time limited" : " · all times")).font(.caption)
            }
            if !model.searchOmissions.isEmpty {
                DisclosureGroup("\(model.searchOmissions.count) source omission(s)") { ForEach(Array(model.searchOmissions.enumerated()), id: \.offset) { _, omission in Text(omission).font(.caption).foregroundStyle(.secondary) } }
            }
            if model.searchHasRun && model.searchTotal > 0 {
                HStack {
                    Text("Results \(model.searchOffset + 1)–\(model.searchOffset + model.searchResults.count) of \(model.searchTotal)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Previous") { model.runSearch(offset: max(0, model.searchOffset - 40)) }.disabled(model.searchOffset == 0)
                    Button("Next") { if let offset = model.searchNextOffset { model.runSearch(offset: offset) } }.disabled(model.searchNextOffset == nil)
                }
            }
            if model.searchHasRun && model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.searchResults.isEmpty {
                ContentUnavailableView("Ask the Sources First", systemImage: "text.magnifyingglass", description: Text("Search returns class-scoped source passages with exact revision citations. Your external agent can use the same retrieval service."))
            } else {
                List(Array(model.searchResults.enumerated()), id: \.offset) { _, result in
                    Button { model.presentedCitation = result.citation } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(result.title).font(.headline)
                            Text(result.excerpt).lineLimit(6).foregroundStyle(.primary).textSelection(.enabled)
                            Text(result.provenance).font(.caption).foregroundStyle(.secondary)
                            Label("Open Exact Source", systemImage: "arrow.up.right.square").font(.caption).foregroundStyle(.tint)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).workspaceListRow()
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.onChange(of: classID) { _, _ in invalidateResults(); showScope = false }
            .onChange(of: model.searchMaterialsOnly) { _, _ in invalidateResults() }
            .onChange(of: model.searchSelectedMaterialIDs) { _, _ in invalidateResults() }
            .onChange(of: model.searchTimeLimited) { _, _ in invalidateResults() }
            .onChange(of: model.searchEventFrom) { _, _ in invalidateResults() }
            .onChange(of: model.searchEventUntil) { _, _ in invalidateResults() }
    }
    private func invalidateResults() {
        model.searchResults = []; model.searchHasRun = false; model.searchOmissions = []
        model.searchTotal = 0; model.searchOffset = 0; model.searchNextOffset = nil
    }
}

private struct InputContextManifestView: View {
    let manifest: [SourceCitation]?
    let open: (SourceCitation) -> Void
    var body: some View {
        if let manifest {
            if manifest.isEmpty {
                Text("Input context reviewed: no source citations recorded.").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Reviewed input context · \(manifest.count) exact source(s)") {
                    FlowCitationLinks(citations: manifest, open: open)
                }.font(.caption)
            }
        } else {
            Text("Agent input context unknown. Answer citations do not establish every source the agent used.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FlowCitationLinks: View {
    let citations: [SourceCitation]
    let open: (SourceCitation) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { ForEach(citations) { citation in Button { open(citation) } label: { Label(citation.label.isEmpty ? "Exact \(citation.sourceKind) Source" : citation.label, systemImage: "link") }.buttonStyle(.link).font(.caption) } }
    }
}
