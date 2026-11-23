import AppKit
import SwiftUI

struct ConnectionsOverview: View {
    @ObservedObject var model: WorkspaceModel
    @State private var statuses: [UniversitySource: UniversityConnectionStatus] = [:]
    @State private var managing: UniversitySource?
    @State private var statusTask: Task<Void, Never>?

    private let accounts: [UniversitySource] = [.canvas, .drive, .gmail, .calendar]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Connections").workspacePageTitle()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("University accounts").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Refresh Status", systemImage: "arrow.clockwise", action: refresh)
                            .help("Reread the account settings saved for this library")
                    }
                    VStack(spacing: 0) {
                        ForEach(accounts) { service in
                            if service != accounts.first { Divider().padding(.leading, 64) }
                            accountRow(service)
                        }
                    }
                    .workspacePanel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Class resources").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Save Gradescope, Piazza, or Zoom links to a class, import a Gradescope PDF, or look up a course in the UCI Registrar.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.visibleClassGroups.contains(where: { !$0.classes.isEmpty }) {
                        Menu("Open for Class…") {
                            ForEach(model.visibleClassGroups.filter { !$0.classes.isEmpty }) { group in
                                Section(group.title) {
                                    ForEach(group.classes) { course in
                                        Button([course.displayLabel, course.section].filter { !$0.isEmpty }.joined(separator: " · ")) {
                                            model.selection = .classDetail(course.id)
                                            model.presentedEditor = .universityServices(classID: course.id, source: .campus)
                                        }
                                    }
                                }
                            }
                        }.fixedSize()
                    } else {
                        Button("New Class…") { model.presentedEditor = .newClass }
                    }
                }
            }
            .workspacePage()
        }
        .navigationTitle("Connections")
        .onAppear(perform: refresh)
        .onDisappear { statusTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .sheet(item: $managing, onDismiss: refresh) { service in
            UniversityConnectionManager(service: service, model: model, onChange: {
                refresh()
                if service == .canvas { model.syncCanvasNow() }
            })
        }
    }

    private func accountRow(_ service: UniversitySource) -> some View {
        let status = statuses[service]
        return HStack(spacing: 14) {
            Image(systemName: service.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(WorkspacePalette.accent)
                .frame(width: 36, height: 36)
                .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(service.rawValue).font(.headline)
                Label(status?.label ?? "Reading status…", systemImage: statusSymbol(status))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button(status?.isConfigured == true ? "Manage…" : "Set Up…") { managing = service }
                .accessibilityLabel("Manage \(service.rawValue) connection")
                .disabled(status == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func statusSymbol(_ status: UniversityConnectionStatus?) -> String {
        switch status {
        case .verified: "checkmark.circle"
        case .checkFailed, .unavailable: "exclamationmark.circle"
        case .saved: "key"
        default: "circle"
        }
    }

    private func refresh() {
        let credentials = UniversityCredentials.forLibrary(model.rootURL)
        statusTask?.cancel()
        let accounts = accounts
        statusTask = Task { @MainActor in
            var next: [UniversitySource: UniversityConnectionStatus] = [:]
            for service in accounts {
                guard !Task.isCancelled else { return }
                next[service] = await UniversityConnectionStatus.readAsync(service, credentials: credentials)
            }
            guard !Task.isCancelled else { return }
            statuses = next
            statusTask = nil
        }
    }
}

private extension UniversitySource {
    var symbol: String {
        switch self {
        case .canvas: "graduationcap"
        case .drive: "externaldrive"
        case .gmail: "envelope"
        case .calendar: "calendar"
        case .campus: "building.columns"
        }
    }
}
