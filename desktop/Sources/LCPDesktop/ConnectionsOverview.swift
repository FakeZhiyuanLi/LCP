import AppKit
import SwiftUI

struct ConnectionsOverview: View {
    @ObservedObject var model: WorkspaceModel
    @State private var statuses: [UniversitySource: UniversityConnectionStatus] = [:]
    @State private var managing: UniversitySource?

    private let accounts: [UniversitySource] = [.canvas, .drive, .gmail, .calendar]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Connections")
                    .font(.system(size: 36, weight: .semibold)).tracking(-1.2)
                    .accessibilityAddTraits(.isHeader)

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
                    .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspacePalette.line).allowsHitTesting(false) }
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
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Connections")
        .onAppear(perform: refresh)
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
        statuses = Dictionary(uniqueKeysWithValues: accounts.map { ($0, UniversityConnectionStatus.read($0, credentials: credentials)) })
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
