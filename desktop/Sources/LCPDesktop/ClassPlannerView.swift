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
    @State private var objective = "Help me plan what to do next for this class. Prioritize urgent coursework and the highest-value review."
    @State private var context: ClassPlannerContext?
    @State private var plan: String?
    @State private var generating = false
    @State private var loadingContext = false
    @State private var status: String?

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
    }

    init(model: WorkspaceModel, globalScope: Bool) {
        self.model = model
        self.classID = nil
        self.globalScope = globalScope
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if profiles.isEmpty {
                    noProvider
                } else {
                    if globalScope { scopeCard }
                    requestCard
                    contextCard
                    if let plan { resultCard(plan) }
                }
            }
            .padding(.top, 12)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            let initialIDs = activeClassIDs
            if globalScope && selectedClassIDs.isEmpty {
                selectedClassIDs = Set(activeClasses.map(\.id))
            }
            refreshProfiles()
            refreshContext(classIDs: initialIDs.isEmpty && globalScope ? activeClasses.map(\.id) : initialIDs)
        }
        .onChange(of: model.rootURL) { _, _ in
            refreshProfiles()
            refreshContext()
        }
        .onChange(of: selectedClassIDs) { _, _ in
            guard globalScope else { return }
            refreshContext()
        }
        .onChange(of: model.state.revision) { _, _ in
            refreshContext()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(globalScope ? "Study planner" : "Class planner", systemImage: "sparkles")
                    .font(.title2.weight(.semibold))
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
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
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
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
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
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Context that will be used", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if loadingContext { ProgressView().controlSize(.small) }
                Button("Refresh") { refreshContext() }.disabled(loadingContext || generating)
            }
            if let context {
                Text("\(context.sourceCount) source\(context.sourceCount == 1 ? "" : "s") across \(context.classLabels.joined(separator: ", ")) · library revision \(context.repositoryRevision)")
                    .font(.callout)
                Text("Includes current materials, class history, coursework, and available accepted lecture transcripts. Raw audio, credentials, and connection grants stay local.")
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
                if !context.omissions.isEmpty {
                    DisclosureGroup("\(context.omissions.count) context note(s)") {
                        ForEach(Array(context.omissions.prefix(8).enumerated()), id: \.offset) { _, omission in
                            Text(omission).font(.caption).foregroundStyle(WorkspacePalette.muted)
                        }
                    }
                }
            } else {
                Text(activeClassIDs.isEmpty
                     ? "Select at least one class to prepare a verified context snapshot."
                     : "LCP is preparing a verified snapshot of \(globalScope ? "the selected classes" : "this class").")
                    .font(.callout)
                    .foregroundStyle(WorkspacePalette.muted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func resultCard(_ plan: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Generated plan", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Button(globalScope ? "Save to Class Histories" : "Save to Class History") {
                    guard let context, let profile = selectedProfile else { return }
                    model.saveAgentPlan(classIDs: context.classIDs, objective: objective, plan: plan, profile: profile, context: context)
                }
                .buttonStyle(.borderedProminent)
            }
            Text(plan)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let context {
                DisclosureGroup("Sources supplied to the agent · \(context.sourceCitations.count)") {
                    ForEach(context.sourceCitations) { citation in
                        Text(citation.label.isEmpty ? citation.sourceKind.capitalized : citation.label)
                            .font(.caption)
                            .foregroundStyle(WorkspacePalette.muted)
                            .textSelection(.enabled)
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
        do {
            profiles = try credentials.profilesList().filter(\.enabled)
            if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = profiles.first?.id
            }
        } catch { status = error.localizedDescription }
    }

    private func refreshContext(classIDs: [UUID]? = nil) {
        guard let repository = model.repository else { return }
        let requestedIDs = classIDs ?? activeClassIDs
        guard !requestedIDs.isEmpty else {
            context = nil
            loadingContext = false
            return
        }
        loadingContext = true
        status = nil
        do {
            context = try ClassPlannerService(repository: repository).makeContext(classIDs: requestedIDs)
        } catch { status = error.localizedDescription }
        loadingContext = false
    }

    private func generate() {
        guard let repository = model.repository, let profile = selectedProfile else { return }
        let requestedClassIDs = activeClassIDs
        guard !requestedClassIDs.isEmpty else {
            status = "Select at least one class before generating a plan."
            return
        }
        let key: String
        do { key = try credentials.apiKey(for: profile) }
        catch { status = error.localizedDescription; return }
        generating = true
        plan = nil
        status = nil
        let request = objective
        Task { @MainActor in
            defer { generating = false }
            do {
                let result = try await ClassPlannerService(repository: repository).generate(
                    classIDs: requestedClassIDs, objective: request, profile: profile, apiKey: key)
                context = result.context
                plan = result.response.text
            } catch is CancellationError {
                status = "The planning request was cancelled."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
