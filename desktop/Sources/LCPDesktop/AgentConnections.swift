import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct AgentConnectionsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var providerProfiles: [AgentProviderProfile] = []
    @State private var providerError: String?
    @State private var providerLoading = false
    @State private var providerTask: Task<Void, Never>?

    private var providerCredentials: AgentProviderCredentials {
        AgentProviderCredentials.forLibrary(model.rootURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent Connections").workspacePageTitle()
                    Text("Connect a chat provider or choose which classes a local agent can access.")
                        .font(.callout).foregroundStyle(WorkspacePalette.muted)
                }
                HStack(spacing: 10) {
                    Button("New Local Agent Grant…", systemImage: "plus") { model.presentedEditor = .newAgentGrant }
                        .buttonStyle(.borderedProminent)
                    Button("Add BYOK Provider…", systemImage: "key") { model.presentedEditor = .newBYOKProvider }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                if providerLoading {
                    Label("Checking the Mac Keychain…", systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !providerProfiles.isEmpty {
                    GroupBox("Bring your own provider") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Provider keys stay in the Mac Keychain. LCP sends only the small connection check until you explicitly use a provider with class context.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(providerProfiles) { profile in
                                BYOKProviderCard(profile: profile, credentials: providerCredentials, onChanged: refreshProviderProfiles)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if model.state.connections.isEmpty {
                    ContentUnavailableView("No local agent grants", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create a grant to let an MCP client read selected classes."))
                        .frame(maxWidth: .infinity)
                        .workspacePanel()
                }
                ForEach(model.state.connections) { connection in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(connection.name, systemImage: "terminal").font(.headline)
                                Spacer()
                                Text(connection.mode == "stdio" ? "Local live retrieval" : connection.mode.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                            if let version = connection.clientVersion { Text(version).font(.caption).foregroundStyle(.secondary) }
                            Text(connection.verifiedAt.map { "Interoperability recorded \($0.formatted())" } ?? "Connection created. Successful client consumption has not been recorded in this library.").font(.caption).foregroundStyle(.secondary)
                            ForEach(model.state.grants.filter { $0.connectionID == connection.id }) { grant in
                                GrantCard(model: model, connection: connection, grant: grant)
                            }
                        }.padding(8)
                    }
                }
                DisclosureGroup("Share class context with an external agent") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Select a class and choose Export Class Context. Review the materials, dates, and exported context.md, then attach that file in Grok Bot using Attach files.").foregroundStyle(.secondary)
                        Text("Ask for the exact LCP citation and open it on this Mac to check the answer. End-to-end retrieval in Grok Bot is awaiting verification.").font(.caption).foregroundStyle(.secondary)
                        Text("For an MCP-capable client such as OpenAI Dots or Claude Duet, open MCP JSON on the matching grant and copy the credential-free stdio configuration. LCP records the client label and verification time after its first successful scoped read.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .padding(16)
                .workspacePanel()
                Text("Revocation prevents future local tool requests. It cannot recall context already sent to an external agent. Connection secrets are not included in exports; the local stdio bridge does not require provider credentials.").font(.caption).foregroundStyle(.secondary)
            }.workspacePage()
        }.navigationTitle("Agent Connections")
            .onAppear(perform: refreshProviderProfiles)
            .onChange(of: model.rootURL) { _, _ in refreshProviderProfiles() }
            .onDisappear { providerTask?.cancel() }
            .alert("Provider Connections Unavailable", isPresented: Binding(get: { providerError != nil }, set: { if !$0 { providerError = nil } })) {
                Button("OK") { providerError = nil }
            } message: { Text(providerError ?? "") }
    }

    private func refreshProviderProfiles() {
        providerTask?.cancel()
        providerLoading = true
        providerError = nil
        let credentials = providerCredentials
        providerTask = Task { @MainActor in
            defer {
                providerLoading = false
                providerTask = nil
            }
            do {
                let values = try await credentials.profilesListAsync().filter(\.enabled)
                guard !Task.isCancelled else { return }
                providerProfiles = values
            } catch {
                guard !Task.isCancelled else { return }
                providerProfiles = []
                providerError = error.localizedDescription
            }
        }
    }
}

private struct BYOKProviderCard: View {
    let profile: AgentProviderProfile
    let credentials: AgentProviderCredentials
    let onChanged: () -> Void
    @State private var testing = false
    @State private var removing = false
    @State private var status: String?
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(profile.name, systemImage: "key.fill").font(.headline)
                Spacer()
                Text(profile.enabled ? "Enabled" : "Paused")
                    .font(.caption).foregroundStyle(profile.enabled ? .green : .secondary)
            }
            Text("OpenAI-compatible · \(profile.model)").font(.callout)
            Text(redactedURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 10) {
                Button(testing ? "Testing…" : "Test Connection") { test() }
                    .disabled(testing || !profile.enabled)
                Button(removing ? "Removing…" : "Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(testing || removing)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("Remove \(profile.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Provider", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) { confirmRemove = false }
        } message: {
            Text("LCP removes the provider metadata and API key from this library's Keychain entry. Class context remains unchanged.")
        }
    }

    private var redactedURL: String {
        guard let url = URL(string: profile.baseURL), let host = url.host else { return "Invalid provider URL" }
        let path = url.path == "/" ? "" : url.path
        return "Endpoint · \(host)\(path)"
    }

    private func test() {
        testing = true
        status = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let key = try await credentials.apiKeyAsync(for: profile)
                let result = try await OpenAICompatibleAgentClient(profile: profile, apiKey: key).checkConnection()
                _ = result
                status = "Verified just now"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func remove() {
        guard !removing else { return }
        removing = true
        status = nil
        Task { @MainActor in
            defer { removing = false }
            do {
                try await credentials.removeAsync(profile: profile)
                onChanged()
            } catch { status = error.localizedDescription }
        }
    }
}

struct NewBYOKProviderView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "OpenAI via sub2api"
    @State private var baseURL = "https://sub2api.ihealth-eng.com/v1"
    @State private var modelName = "gpt-6.2-sol"
    @State private var apiKey = ""
    @State private var testing = false
    @State private var status: String?

    private var credentials: AgentProviderCredentials { AgentProviderCredentials.forLibrary(model.rootURL) }
    private var profile: AgentProviderProfile {
        AgentProviderProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), model: modelName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.isEmpty && !testing
    }

    var body: some View {
        EditorFrame(title: "Add BYOK Provider", canSave: canSave, saveLabel: "Test & Save", height: 560, width: 680, save: testAndSave) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Bring your own key to use an OpenAI-compatible agent provider. LCP stores the key in the Mac Keychain and keeps it out of class backups and context exports.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Import from Codex config", systemImage: "arrow.down.doc") { importCodex() }
                        Text("Reads ~/.codex/config.toml on this Mac")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Form {
                        TextField("Connection name", text: $name, prompt: Text("OpenAI via sub2api"))
                        TextField("Base URL", text: $baseURL, prompt: Text("https://provider.example/v1"))
                            .textContentType(.URL)
                        TextField("Model", text: $modelName, prompt: Text("gpt-6.2-sol"))
                        SecureField("API key", text: $apiKey)
                            .privacySensitive()
                    }.formStyle(.grouped)
                    HStack(spacing: 10) {
                        Button(testing ? "Testing…" : "Test Connection") { test(saveAfter: false) }
                            .disabled(!canSave)
                        if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                    }
                    Text("The test sends a single short Responses API request with no class context and asks for a bounded reply. Future subscription support can use the same provider abstraction without requiring a personal key.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 16)
            }
        }
    }

    private func importCodex() {
        do {
            let imported = try credentials.importCodexConfiguration()
            baseURL = imported.baseURL
            modelName = imported.model
            apiKey = imported.apiKey
            status = "Codex provider settings imported. Test the connection to continue."
        } catch { status = error.localizedDescription }
    }

    private func testAndSave() { test(saveAfter: true) }

    private func test(saveAfter: Bool) {
        guard !testing else { return }
        testing = true
        status = nil
        let nextProfile = profile
        let nextKey = apiKey
        Task { @MainActor in
            defer { testing = false }
            do {
                let client = try OpenAICompatibleAgentClient(profile: nextProfile, apiKey: nextKey)
                let result = try await client.checkConnection()
                if saveAfter {
                    try await credentials.saveAsync(profile: nextProfile, apiKey: nextKey)
                    model.notice = "BYOK provider connected. Its API key is stored in the Mac Keychain."
                    dismiss()
                } else {
                    status = "Verified \(result.model) just now"
                }
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

private struct GrantCard: View {
    @ObservedObject var model: WorkspaceModel
    let connection: AgentConnection
    let grant: AgentGrant
    @State private var showCommand = false
    @State private var showConfiguration = false
    @State private var confirmRevoke = false
    private var grantIdentity: String { "\(connection.name), grant \(grant.id.uuidString.prefix(8))" }
    private var bridgeExecutable: String {
        let bridge = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LCPAgentBridge").path : (Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LCPAgentBridge").path ?? "/path/to/LCPAgentBridge")
        return bridge
    }
    private var command: String {
        "\(shellQuote(bridgeExecutable)) --root \(shellQuote(model.rootURL.path)) --grant \(grant.id.uuidString)"
    }
    private var configurationText: String? {
        guard let configuration = try? AgentBridgeConfiguration(serverName: connection.name,
                                                                 command: bridgeExecutable,
                                                                 root: model.rootURL.path,
                                                                 grantID: grant.id),
              let data = try? configuration.encoded() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(grant.isActive ? "Access Active" : "Revoked", systemImage: grant.isActive ? "checkmark.shield" : "nosign").foregroundStyle(grant.isActive ? Color.green : Color.secondary)
                Spacer()
                if grant.isActive {
                    Button("Setup Command") { showCommand.toggle() }.accessibilityLabel("Show setup command for \(grantIdentity)")
                    Button("MCP JSON") { showConfiguration.toggle() }.accessibilityLabel("Show MCP JSON configuration for \(grantIdentity)")
                    Button("Revoke…", role: .destructive) { confirmRevoke = true }.accessibilityLabel("Revoke access for \(grantIdentity)")
                }
            }
            Text(grant.allowedClassIDs.compactMap { id in
                guard let course = model.state.classes.first(where: { $0.id == id }) else { return nil }
                let term = model.state.terms.first { $0.id == course.termID }?.name
                return [course.shortLabel, term].compactMap { $0 }.joined(separator: " · ")
            }.joined(separator: ", ")).font(.callout)
            if let ids = grant.allowedMaterialIDs {
                Text("Selected materials only: \(ids.count). Notes and lecture transcripts excluded.").font(.caption).foregroundStyle(.secondary)
                Text(ids.compactMap { id in model.state.materials.first { $0.id == id }?.title }.joined(separator: ", ")).font(.caption).lineLimit(3)
            } else { Text("All class source types").font(.caption).foregroundStyle(.secondary) }
            if grant.eventFrom != nil || grant.eventUntil != nil {
                Text("Source time: \(grant.eventFrom?.formatted() ?? "unbounded start") through \(grant.eventUntil?.formatted() ?? "unbounded end")").font(.caption).foregroundStyle(.secondary)
            } else { Text("No source time limit").font(.caption).foregroundStyle(.secondary) }
            Text("Capabilities: \(connection.capabilities.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            if grant.isActive {
                Toggle("Allow future note proposals", isOn: capability("propose_note")).toggleStyle(.checkbox)
                    .accessibilityLabel("Allow future note proposals from \(connection.name)")
                if grant.allowedMaterialIDs == nil && grant.eventFrom == nil && grant.eventUntil == nil {
                    Toggle("Allow reading class chat attachments and suggesting where to file them", isOn: capability(ChatFilingTool.name))
                        .toggleStyle(.checkbox)
                }
                Toggle("Allow future study-log proposals", isOn: capability("propose_study_log")).toggleStyle(.checkbox)
                    .accessibilityLabel("Allow future study-log proposals from \(connection.name)")
                Text("Changing proposal permission keeps read access. Existing drafts still require your review.").font(.caption2).foregroundStyle(.secondary)
            }
            if showCommand && grant.isActive {
                Text("Configure your compatible client's stdio MCP server with this executable and arguments. Keep this grant scoped to the chosen classes.").font(.caption)
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button("Copy Launch Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
                    .accessibilityLabel("Copy launch command for \(grantIdentity)")
                Text("Grant \(grant.id.uuidString)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            if showConfiguration && grant.isActive {
                Text("Paste this credential-free JSON into a compatible MCP client's local configuration. It launches the scoped bridge over stdio and keeps the grant UUID explicit.").font(.caption)
                if let configurationText {
                    Text(configurationText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Button("Copy MCP JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configurationText, forType: .string)
                    }.accessibilityLabel("Copy MCP JSON configuration for \(grantIdentity)")
                } else {
                    Text("This app could not construct an absolute local bridge path.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .confirmationDialog("Revoke future access for \(grantIdentity)?", isPresented: $confirmRevoke, titleVisibility: .visible) {
                Button("Revoke Access", role: .destructive) { model.mutate { state in if let index = state.grants.firstIndex(where: { $0.id == grant.id }) { state.grants[index].revokedAt = Date() } } }
            } message: { Text("Existing exported context cannot be recalled. Local tools will reject subsequent requests with this grant.") }
    }
    private func capability(_ name: String) -> Binding<Bool> {
        Binding(get: { connection.capabilities.contains(name) }, set: { enabled in
            model.mutate { state in
                guard let index = state.connections.firstIndex(where: { $0.id == connection.id }) else { return }
                if enabled {
                    if !state.connections[index].capabilities.contains(name) { state.connections[index].capabilities.append(name) }
                } else { state.connections[index].capabilities.removeAll { $0 == name } }
            }
        })
    }
}

struct LocalAgentGrantDraft {
    var name = "Codex (local MCP)"
    var classIDs: Set<UUID> = []
    var allowProposals = false
    var allowChatFiles = false
    var scope = ContextScopeDraft()

    func canCreate(visibleClassIDs: Set<UUID>, availableMaterialIDs: Set<UUID>) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (1...128).contains(classIDs.count) && classIDs.isSubset(of: visibleClassIDs) &&
            scope.isValid && (!scope.materialsOnly || scope.materialIDs.isSubset(of: availableMaterialIDs))
    }

    func create(in state: inout ContextState, includingArchived: Bool) throws {
        let groups = state.visibleClassGroups(includingArchived: includingArchived)
        let visibleClassIDs = Set(groups.flatMap { $0.classes.map(\.id) })
        let availableMaterialIDs = Set(state.materials.lazy.filter { classIDs.contains($0.classID) }.map(\.id))
        guard canCreate(visibleClassIDs: visibleClassIDs, availableMaterialIDs: availableMaterialIDs) else {
            throw DesktopUIError.message("The available classes or materials changed. Review your selection before creating the grant.")
        }
        var capabilities = allowProposals ? ["read_context", "propose_note", "propose_study_log"] : ["read_context"]
        if allowChatFiles && !scope.materialsOnly && !scope.timeLimited { capabilities.append(ChatFilingTool.name) }
        let connection = AgentConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), mode: "stdio",
                                         capabilities: capabilities)
        let grant = AgentGrant(connectionID: connection.id, allowedClassIDs: classIDs.sorted { $0.uuidString < $1.uuidString },
            allowedMaterialIDs: scope.selectedMaterialIDs, eventFrom: scope.from, eventUntil: scope.until)
        state.connections.append(connection)
        state.grants.append(grant)
    }
}

struct NewAgentGrantView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LocalAgentGrantDraft()
    @State private var saveError: String?

    var body: some View {
        let groups = model.visibleClassGroups
        let visibleClassIDs = Set(groups.flatMap { $0.classes.map(\.id) })
        let selectedClassIDs = draft.classIDs.intersection(visibleClassIDs)
        let materials = model.state.materials.filter { selectedClassIDs.contains($0.classID) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let availableMaterialIDs = Set(materials.map(\.id))
        let canSave = draft.canCreate(visibleClassIDs: visibleClassIDs, availableMaterialIDs: availableMaterialIDs)
        EditorFrame(title: "Create Scoped Agent Access", canSave: canSave, saveLabel: "Create Grant", save: save) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let saveError { Text(saveError).foregroundStyle(.red) }
                    TextField("Client Name", text: $draft.name).textFieldStyle(.roundedBorder)
                    Text("Allowed classes").font(.headline)
                    if visibleClassIDs.isEmpty {
                        Text(model.state.classes.isEmpty ? "Add a class to create a grant." : "Turn on Archived in the sidebar to choose an archived class.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        ForEach(group.classes) { enrollment in
                            Toggle(isOn: Binding(get: { draft.classIDs.contains(enrollment.id) }, set: {
                                if $0 { draft.classIDs.insert(enrollment.id) } else { draft.classIDs.remove(enrollment.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(enrollment.displayLabel)
                                    HStack {
                                        if let term = group.term { Text(term.name) }
                                        if enrollment.archived || group.term?.archived == true { Text("Archived") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                    Divider()
                    SourceScopeControls(state: model.state, materials: materials, materialsOnly: $draft.scope.materialsOnly, selectedMaterialIDs: $draft.scope.materialIDs,
                        timeLimited: $draft.scope.timeLimited, eventFrom: $draft.scope.eventFrom, eventUntil: $draft.scope.eventUntil)
                    Toggle("Allow proposals for notes and study logs", isOn: $draft.allowProposals)
                    if !draft.scope.materialsOnly && !draft.scope.timeLimited {
                        Toggle("Allow reading class chat attachments and suggesting where to file them", isOn: $draft.allowChatFiles)
                    }
                    Text("Proposals require your review. This never grants permission to silently change sources, official deadlines, grades, recording controls, or class mappings.").font(.caption).foregroundStyle(.secondary)
                    GroupBox("Access to create") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(selectedClassIDs.count) selected class(es) · " + (draft.scope.materialsOnly ? "\(draft.scope.materialIDs.intersection(availableMaterialIDs).count) selected documents only" : "all class source types"))
                            Text(draft.scope.timeLimited ? "Inclusive source times: \(draft.scope.eventFrom.formatted()) through \(draft.scope.eventUntil.formatted())." : "No source time limit.")
                            Text("The bridge enforces this scope for future reads, direct citation requests, and snapshot exports.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    Text("Transport: local stdio MCP. This creates no network listener and sends no context until you configure and use the client.").font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 16)
            }
        }
        .onAppear {
            if let id = model.selectedClassID, visibleClassIDs.contains(id) { draft.classIDs.insert(id) }
        }
        .onChange(of: visibleClassIDs) { _, ids in draft.classIDs.formIntersection(ids) }
        .onChange(of: availableMaterialIDs) { _, ids in draft.scope.materialIDs.formIntersection(ids) }
    }

    private func save() {
        guard let repository = model.repository else { return }
        do {
            try repository.update { try draft.create(in: &$0, includingArchived: model.showArchived) }
            model.refresh()
            dismiss()
        } catch {
            model.refresh()
            saveError = error.localizedDescription
        }
    }
}

struct ProposalReviewView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var includeReviewed = false
    var proposals: [AgentProposal] { model.state.proposals.filter { includeReviewed || $0.state == "pending" }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review Proposals").workspacePageTitle()
                    Text("Review suggested notes and corrections before adding them to class history.").font(.callout).foregroundStyle(WorkspacePalette.muted)
                }
                Spacer(); Toggle("Show Reviewed", isOn: $includeReviewed).toggleStyle(.checkbox)
            }
            if proposals.isEmpty { ContentUnavailableView("No Proposals to Review", systemImage: "checkmark.bubble", description: Text("A connection with proposal permission can suggest a note or study log. You can also manually save a selected agent answer in class history.")) }
            else {
                List(proposals) { proposal in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.state.classes.first { $0.id == proposal.classID }?.shortLabel ?? "Unknown Class").font(.caption.bold()).foregroundStyle(.tint)
                            Label(proposal.agentIdentity, systemImage: "sparkles").font(.caption).foregroundStyle(WorkspacePalette.accent)
                            Spacer(); Text(proposal.state.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(proposal.title).font(.headline)
                        AgentOutputView(source: proposal.body)
                        if proposal.targetID != nil {
                            Text("Proposed correction · requires target version \(proposal.expectedVersion.map(String.init) ?? "unknown")").font(.caption).foregroundStyle(.orange)
                            if let target = model.state.activities.first(where: { $0.id == proposal.targetID }) {
                                GroupBox("Current entry · version \(target.version)") {
                                    if target.agentIdentity != nil { AgentOutputView(source: target.body) }
                                    else { Text(verbatim: target.body).textSelection(.enabled) }
                                }
                            }
                        }
                        FlowCitationLinks(citations: proposal.citations, open: { model.presentedCitation = $0 })
                        HStack {
                            Text(proposal.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if proposal.state == "pending" {
                                Button("Reject", role: .destructive) { model.rejectProposal(proposal.id) }
                                    .accessibilityLabel("Reject proposal \(proposal.title) from \(proposal.agentIdentity), \(classIdentity(proposal.classID))")
                                Button("Accept into Class History") { model.acceptProposal(proposal.id) }.buttonStyle(.borderedProminent)
                                    .accessibilityLabel("Accept proposal \(proposal.title) from \(proposal.agentIdentity) into \(classIdentity(proposal.classID)) history")
                            }
                        }
                    }.workspaceListRow()
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .workspacePage()
        .navigationTitle("Review Proposals")
    }
    private func classIdentity(_ id: UUID) -> String {
        guard let enrollment = model.state.classes.first(where: { $0.id == id }) else { return "unavailable class" }
        let term = model.state.terms.first { $0.id == enrollment.termID }?.name
        return [enrollment.shortLabel, term].compactMap { $0 }.joined(separator: ", ")
    }
}

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
