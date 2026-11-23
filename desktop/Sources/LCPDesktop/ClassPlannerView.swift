import SwiftUI
import LCPContextCore
import LCPContextServices

struct ClassPlannerView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID?
    let globalScope: Bool

    @State private var profiles: [AgentProviderProfile] = []
    @State private var selectedProfileID: UUID?
    @State private var selectedClassIDs: Set<UUID> = []
    @State private var objective: String
    @State private var coursework: [PlannerSource] = []
    private struct GeneratedPlan {
        let result: ClassPlanResult
        let objective: String
        let profile: AgentProviderProfile
    }
    @State private var plan: GeneratedPlan?
    @State private var generating = false
    @State private var status: String?
    @State private var profileTask: Task<Void, Never>?

    private var credentials: AgentProviderCredentials { AgentProviderCredentials.forLibrary(model.rootURL) }
    private var selectedProfile: AgentProviderProfile? { profiles.first { $0.id == selectedProfileID } }
    private var activeClasses: [ClassEnrollment] {
        model.state.classes.filter { !$0.archived }.sorted {
            let order = $0.shortLabel.localizedStandardCompare($1.shortLabel)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private var activeClassIDs: [UUID] {
        if let classID { return [classID] }
        return activeClasses.filter { selectedClassIDs.contains($0.id) }.map(\.id)
    }

    init(model: WorkspaceModel, classID: UUID) {
        self.model = model
        self.classID = classID
        self.globalScope = false
        _objective = State(initialValue: ClassPlannerService.defaultObjective(acrossClasses: false))
    }

    init(model: WorkspaceModel, globalScope: Bool) {
        self.model = model
        self.classID = nil
        self.globalScope = globalScope
        _objective = State(initialValue: ClassPlannerService.defaultObjective(acrossClasses: globalScope))
    }

    var body: some View {
        ScrollView {
            if globalScope {
                plannerContent.workspacePage()
            } else {
                plannerContent
            }
        }
        .onAppear {
            if globalScope && selectedClassIDs.isEmpty {
                selectedClassIDs = Set(activeClasses.map(\.id))
            }
            refreshProfiles()
            refreshCoursework()
        }
        .onChange(of: model.rootURL) { _, _ in
            plan = nil
            refreshProfiles()
            refreshCoursework()
        }
        .onChange(of: activeClassIDs) { _, _ in
            plan = nil
            refreshCoursework()
        }
        .onChange(of: model.state.revision) { _, _ in refreshCoursework() }
        .task(id: objective) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            refreshCoursework()
        }
        .onDisappear { profileTask?.cancel() }
    }

    private var plannerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if globalScope { scopeCard.disabled(generating) }
            if profiles.isEmpty {
                noProvider
            } else {
                requestCard
                if let plan { resultCard(plan) }
            }
            contextCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                if globalScope {
                    Text("Study Planner").workspacePageTitle()
                } else {
                    Text("Class planner").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                }
                Spacer()
                if generating { ProgressView().controlSize(.small) }
            }
            Text(globalScope
                 ? "Ask an agent to coordinate your classes using their materials, coursework, notes, and available lecture transcripts."
                 : "Ask an agent to turn this class's materials, coursework, notes, and available lecture transcripts into a practical next-step plan.")
                .font(.callout)
                .foregroundStyle(WorkspacePalette.muted)
            Text("LCP sends a fresh, bounded snapshot for each request. Source text is treated as study data, and no official class record is changed automatically.")
                .font(.caption)
                .foregroundStyle(WorkspacePalette.muted)
        }
    }

    private var noProvider: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect an agent provider", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Add a BYOK provider in Agent Connections before generating a plan. The key stays in this library's Mac Keychain.")
                .foregroundStyle(WorkspacePalette.muted)
            HStack(spacing: 10) {
                Button("Add BYOK Provider…", systemImage: "key") {
                    model.presentedEditor = .newBYOKProvider
                }
                .buttonStyle(.borderedProminent)
                Button("Open Agent Connections", systemImage: "arrow.right") {
                    model.selection = .connections
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspacePanel()
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Label("Classes in this plan", systemImage: "books.vertical")
                    .font(.headline)
                Spacer()
                Button("Select all active") {
                    selectedClassIDs = Set(activeClasses.map(\.id))
                }
                .buttonStyle(.borderless)
                Button("Clear") { selectedClassIDs.removeAll() }
                    .buttonStyle(.borderless)
            }
            Text("LCP will use the selected classes as one bounded context. Choose fewer classes for a focused plan.")
                .font(.caption)
                .foregroundStyle(WorkspacePalette.muted)
            if activeClasses.isEmpty {
                Text("Create a class before opening a multi-class plan.")
                    .font(.callout)
                    .foregroundStyle(WorkspacePalette.muted)
            } else {
                ForEach(activeClasses) { course in
                    Toggle(isOn: Binding(
                        get: { selectedClassIDs.contains(course.id) },
                        set: { selected in
                            if selected { selectedClassIDs.insert(course.id) }
                            else { selectedClassIDs.remove(course.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(course.shortLabel)
                            if course.displayLabel != course.title {
                                Text(course.title).font(.caption).foregroundStyle(WorkspacePalette.muted)
                            }
                        }
                    }
                    .accessibilityLabel("Include \(course.shortLabel) in plan")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspacePanel()
    }

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What do you want to accomplish?").font(.headline)
                Spacer()
                Picker("Agent provider", selection: Binding(get: { selectedProfileID ?? profiles.first?.id }, set: { selectedProfileID = $0 })) {
                    ForEach(profiles.filter(\.enabled)) { profile in
                        Text("\(profile.name) · \(profile.model)").tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 270)
                .accessibilityLabel("Agent provider")
            }
            TextEditor(text: $objective)
                .disabled(generating)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 104)
                .background(WorkspacePalette.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspacePalette.line) }
                .accessibilityLabel("Planning request")
            HStack {
                Text("Examples: plan this week, prepare for the next exam, or catch me up on missed lectures.")
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
                Spacer()
                Button(generating ? "Generating…" : "Generate Plan", systemImage: "sparkles") {
                    generate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating || activeClassIDs.isEmpty || selectedProfile == nil || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.orange) }
        }
        .padding(18)
        .workspacePanel()
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Coursework in focus", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    model.refreshIfChanged()
                    refreshCoursework()
                }.disabled(generating)
            }
            if !activeClassIDs.isEmpty {
                if coursework.isEmpty {
                    Text("No upcoming or outstanding coursework found here. You can still plan a review using your readings, notes, and lectures.")
                        .font(.callout).foregroundStyle(WorkspacePalette.muted)
                }
                ForEach(coursework) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.classLabel + " · " + item.title).font(.callout.weight(.semibold))
                            Text([item.timing, item.progress].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(WorkspacePalette.muted)
                        }
                        Spacer()
                        if let citation = item.citation {
                            Button("View source") { model.presentedCitation = citation }
                                .accessibilityLabel("View source for \(item.title)")
                        }
                    }
                }
            } else {
                Text("Select a class to see its upcoming coursework.")
                    .font(.callout)
                    .foregroundStyle(WorkspacePalette.muted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func resultCard(_ plan: GeneratedPlan) -> some View {
        let result = plan.result
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(result.isLocalReply ? "Plan from your library" : "Your study plan", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Button(globalScope ? "Save to Class Histories" : "Save to Class History") {
                    model.saveAgentPlan(classIDs: result.context.classIDs, objective: plan.objective,
                                        plan: result.response.text, profile: plan.profile, context: result.context, generatedLocally: result.isLocalReply)
                }
                .buttonStyle(.borderedProminent)
            }
            AgentOutputView(source: result.response.text)
            DisclosureGroup("Sources for this plan · \(result.context.sourceCitations.count)") {
                ForEach(result.context.sourceCitations) { citation in
                    Button(citation.label.isEmpty ? citation.sourceKind.capitalized : citation.label) {
                        model.presentedCitation = citation
                    }.buttonStyle(.link).font(.caption)
                }
            }
            if !result.context.omissions.isEmpty {
                DisclosureGroup("Unavailable sources · \(result.context.omissions.count)") {
                    ForEach(Array(result.context.omissions.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption).foregroundStyle(WorkspacePalette.muted)
                    }
                }
            }
            Text("Review the answer before saving. Saving creates an attributed, citation-backed history entry and does not edit Canvas or other university services.")
                .font(.caption)
                .foregroundStyle(WorkspacePalette.muted)
        }
        .padding(18)
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.accent, lineWidth: 1.5) }
    }

    private func refreshProfiles() {
        profileTask?.cancel()
        let credentials = credentials
        profileTask = Task { @MainActor in
            do {
                let values = try await credentials.profilesListAsync().filter(\.enabled)
                guard !Task.isCancelled else { return }
                profiles = values
                if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
                    selectedProfileID = profiles.first?.id
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
        }
    }

    private func refreshCoursework() {
        guard let repository = model.repository else { coursework = []; return }
        coursework = ClassPlannerService(repository: repository).courseworkPreview(classIDs: activeClassIDs, objective: objective)
    }

    private func generate() {
        guard let repository = model.repository, let profile = selectedProfile else { return }
        let requestedClassIDs = activeClassIDs
        guard !requestedClassIDs.isEmpty else {
            status = "Select at least one class before generating a plan."
            return
        }
        generating = true
        plan = nil
        status = nil
        let request = objective
        Task { @MainActor in
            defer { generating = false }
            do {
                let key = try await credentials.apiKeyAsync(for: profile)
                let result = try await ClassPlannerService(repository: repository).generate(
                    classIDs: requestedClassIDs, objective: request, profile: profile, apiKey: key)
                guard model.repository === repository, activeClassIDs == requestedClassIDs else { return }
                plan = GeneratedPlan(result: result, objective: request, profile: profile)
            } catch is CancellationError {
                status = "The planning request was cancelled."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
