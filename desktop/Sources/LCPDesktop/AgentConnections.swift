import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct AgentConnectionsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var providerProfiles: [AgentProviderProfile] = []
    @State private var providerError: String?

    private var providerCredentials: AgentProviderCredentials {
        AgentProviderCredentials.forLibrary(model.rootURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Choose what your agents can see.").font(.largeTitle.bold())
                Text("LCP keeps the source context. Each local agent connection receives an explicit class scope. A snapshot export is a separate, deliberate sharing route.").font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("New Local Agent Grant…", systemImage: "plus") { model.presentedEditor = .newAgentGrant }
                        .buttonStyle(.borderedProminent)
                    Button("Add BYOK Provider…", systemImage: "key") { model.presentedEditor = .newBYOKProvider }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                if !providerProfiles.isEmpty {
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
                    ContentUnavailableView("No Agent Connections", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create a scoped local MCP grant for a compatible client, or export a selected class's context from its toolbar. No subscription is required to maintain your library."))
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
                GroupBox("Use a class snapshot with Grok Bot") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Select a class and choose Export Class Context. Review the materials, dates, and exported context.md, then attach that file in Grok Bot using Attach files.").foregroundStyle(.secondary)
                        Text("Ask for the exact LCP citation and open it on this Mac to check the answer. End-to-end retrieval in Grok Bot is awaiting verification.").font(.caption).foregroundStyle(.secondary)
                        Text("For an MCP-capable client such as OpenAI Dots or Claude Duet, open MCP JSON on the matching grant and copy the credential-free stdio configuration. LCP records the client label and verification time after its first successful scoped read.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("Revocation prevents future local tool requests. It cannot recall context already sent to an external agent. Connection secrets are not included in exports; the local stdio bridge does not require provider credentials.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Agent Connections")
            .onAppear(perform: refreshProviderProfiles)
            .onChange(of: model.rootURL) { _, _ in refreshProviderProfiles() }
            .alert("Provider Connections Unavailable", isPresented: Binding(get: { providerError != nil }, set: { if !$0 { providerError = nil } })) {
                Button("OK") { providerError = nil }
            } message: { Text(providerError ?? "") }
    }

    private func refreshProviderProfiles() {
        do { providerProfiles = try providerCredentials.profilesList() }
        catch { providerError = error.localizedDescription }
    }
}

private struct BYOKProviderCard: View {
    let profile: AgentProviderProfile
    let credentials: AgentProviderCredentials
    let onChanged: () -> Void
    @State private var testing = false
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
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(testing)
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
                let key = try credentials.apiKey(for: profile)
                let result = try await OpenAICompatibleAgentClient(profile: profile, apiKey: key).checkConnection()
                _ = result
                status = "Verified just now"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func remove() {
        do {
            try credentials.remove(profile: profile)
            onChanged()
        } catch { status = error.localizedDescription }
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
                    try credentials.save(profile: nextProfile, apiKey: nextKey)
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

struct NewAgentGrantView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Codex (local MCP)"
    @State private var selectedClassIDs: Set<UUID> = []
    @State private var allowProposals = false
    @State private var scope = ContextScopeDraft()
    private var materials: [SourceMaterial] {
        model.state.materials.filter { selectedClassIDs.contains($0.classID) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        EditorFrame(title: "Create Scoped Agent Access", canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedClassIDs.isEmpty && selectedClassIDs.count <= 128 && scope.isValid, saveLabel: "Create Grant", save: save) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Client Name", text: $name).textFieldStyle(.roundedBorder)
                    Text("Allowed classes").font(.headline)
                    ForEach(model.state.classes) { enrollment in
                        Toggle(isOn: Binding(get: { selectedClassIDs.contains(enrollment.id) }, set: {
                            if $0 { selectedClassIDs.insert(enrollment.id) } else { selectedClassIDs.remove(enrollment.id) }
                            scope.materialIDs.formIntersection(Set(materials.map(\.id)))
                        })) {
                            VStack(alignment: .leading) {
                                Text(enrollment.displayLabel)
                                Text(model.state.terms.first { $0.id == enrollment.termID }?.name ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    Divider()
                    SourceScopeControls(state: model.state, materials: materials, materialsOnly: $scope.materialsOnly, selectedMaterialIDs: $scope.materialIDs,
                        timeLimited: $scope.timeLimited, eventFrom: $scope.eventFrom, eventUntil: $scope.eventUntil)
                    Toggle("Allow proposals for notes and study logs", isOn: $allowProposals)
                    Text("Proposals require your review. This never grants permission to silently change sources, official deadlines, grades, recording controls, or class mappings.").font(.caption).foregroundStyle(.secondary)
                    GroupBox("Access to create") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(selectedClassIDs.count) selected class(es) · " + (scope.materialsOnly ? "\(scope.materialIDs.count) selected documents only" : "all class source types"))
                            Text(scope.timeLimited ? "Inclusive source times: \(scope.eventFrom.formatted()) through \(scope.eventUntil.formatted())." : "No source time limit.")
                            Text("The bridge enforces this scope for future reads, direct citation requests, and snapshot exports.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    Text("Transport: local stdio MCP. This creates no network listener and sends no context until you configure and use the client.").font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 16)
            }
        }.onAppear { if let id = model.selectedClassID { selectedClassIDs.insert(id) } }
    }
    private func save() {
        guard scope.isValid, !scope.materialsOnly || scope.materialIDs.isSubset(of: Set(materials.map(\.id))) else { return }
        let connection = AgentConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), mode: "stdio", capabilities: allowProposals ? ["read_context", "propose_note", "propose_study_log"] : ["read_context"])
        let grant = AgentGrant(connectionID: connection.id, allowedClassIDs: selectedClassIDs.sorted { $0.uuidString < $1.uuidString },
            allowedMaterialIDs: scope.selectedMaterialIDs, eventFrom: scope.from, eventUntil: scope.until)
        model.mutate { $0.connections.append(connection); $0.grants.append(grant) }
        if model.errorMessage == nil { dismiss() }
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
                    Text("Review Agent Proposals").font(.largeTitle.bold())
                    Text("An agent's output becomes durable class history only after you accept it.").foregroundStyle(.secondary)
                }
                Spacer(); Toggle("Show Reviewed", isOn: $includeReviewed).toggleStyle(.checkbox)
            }.padding(.top, 10)
            if proposals.isEmpty { ContentUnavailableView("No Proposals to Review", systemImage: "checkmark.bubble", description: Text("A connection with proposal permission can suggest a note or study log. You can also manually save a selected agent answer in class history.")) }
            else {
                List(proposals) { proposal in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.state.classes.first { $0.id == proposal.classID }?.shortLabel ?? "Unknown Class").font(.caption.bold()).foregroundStyle(.tint)
                            Label(proposal.agentIdentity, systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                            Spacer(); Text(proposal.state.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(proposal.title).font(.headline)
                        Text(proposal.body).textSelection(.enabled)
                        if proposal.targetID != nil {
                            Text("Proposed correction · requires target version \(proposal.expectedVersion.map(String.init) ?? "unknown")").font(.caption).foregroundStyle(.orange)
                            if let target = model.state.activities.first(where: { $0.id == proposal.targetID }) {
                                GroupBox("Current entry · version \(target.version)") { Text(target.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
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
                    }.padding(.vertical, 14)
                }.listStyle(.inset)
            }
        }.padding(24).navigationTitle("Review Proposals")
    }
    private func classIdentity(_ id: UUID) -> String {
        guard let enrollment = model.state.classes.first(where: { $0.id == id }) else { return "unavailable class" }
        let term = model.state.terms.first { $0.id == enrollment.termID }?.name
        return [enrollment.shortLabel, term].compactMap { $0 }.joined(separator: ", ")
    }
}

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
