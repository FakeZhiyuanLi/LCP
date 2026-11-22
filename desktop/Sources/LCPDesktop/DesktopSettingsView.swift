import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct DesktopSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var selectedTab = "library"
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Local Context Library") {
                    LabeledContent("Location") { Text(model.rootURL.path).font(.caption).textSelection(.enabled) }
                    LabeledContent("Schema", value: String(model.state.schemaVersion))
                    LabeledContent("Repository Revision", value: String(model.state.revision))
                    Button("Show Library in Finder") { NSWorkspace.shared.open(model.rootURL) }
                    Text("Original materials and immutable cited payloads are stored separately from the versioned context database. Opening the app does not start recording, networking, or transcription.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Backup and Recovery") {
                    HStack { Button("Back Up Library…") { model.exportBackup() }; Button("Restore Verified Backup…") { model.chooseRestore() } }
                        .disabled(model.libraryTransfer != nil)
                    Text("Backups keep your class history, original materials, and saved citations. Select Include linked lecture audio when saving to keep recordings for offline playback. Other external files may need relinking.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Library", systemImage: "externaldrive") }.tag("library")
            Form {
                Section("Academic Terms") {
                    ForEach(model.state.terms) { term in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(term.name).font(.headline)
                                Text(term.timeZoneID).font(.caption).foregroundStyle(.secondary)
                                if let starts = term.startDate, let ends = term.endDate { Text("\(starts.label) – \(ends.label)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Edit…") { model.inWorkspace("Edit Term") { model.editingTermID = term.id; model.presentedEditor = .editTerm } }
                                .accessibilityLabel("Edit academic term \(term.name)")
                            Toggle("Archived", isOn: Binding(get: { term.archived }, set: { value in model.mutate { state in if let i = state.terms.firstIndex(where: { $0.id == term.id }) { state.terms[i].archived = value } } })).toggleStyle(.checkbox)
                                .accessibilityLabel("Archive academic term \(term.name)")
                        }.padding(.vertical, 5)
                    }
                    Button("Create a Term…") { model.inWorkspace("Create a Term") { model.presentedEditor = .newTerm } }
                    Text("Archiving hides terms from the main sidebar until Show Archived is enabled. Context and source identities remain available.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Terms", systemImage: "graduationcap") }.tag("terms")
            Form {
                Section("Canvas coursework refresh") {
                    Picker("Refresh interval", selection: Binding(get: { model.canvasSyncInterval }, set: model.setCanvasSyncInterval)) {
                        ForEach(CanvasSyncInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    LabeledContent("Status") { Text(model.canvasSyncStatus).multilineTextAlignment(.trailing) }
                    if let lastRun = model.canvasSyncLastRun {
                        LabeledContent("Last successful refresh", value: lastRun.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("Last successful refresh", value: "Not yet")
                    }
                    LabeledContent("Pending reviews", value: String(model.canvasSyncPendingReviews.count))
                    HStack {
                        Button("Refresh Canvas Now", systemImage: "arrow.clockwise") { model.syncCanvasNow() }
                            .disabled(model.canvasSyncInProgress)
                        Button("Review Next Item") { model.presentNextCanvasReview() }
                            .disabled(model.canvasSyncPendingReviews.isEmpty)
                    }
                }
                Section("How automatic refresh works") {
                    Text("Each class subscribes to one Canvas course that you select in that class's University Services view. LCP imports read-only snapshots of assignments, quizzes, announcements, and course calendar events for subscribed classes only.")
                    Text("New or changed official deadlines are placed in the review queue. They never overwrite your progress, submission links, citations, or reviewed Coursework until you approve the saved Canvas source.")
                    Text("Connect UCI Canvas in Connections, open a class, choose University Services → UCI Canvas, load your courses, and select a course. The Automatically import new Canvas updates switch is on by default and can pause future imports for that class. Classes without an explicit subscription are skipped. Archived classes are skipped.")
                }
            }.formStyle(.grouped).tabItem { Label("Canvas", systemImage: "arrow.triangle.2.circlepath") }.tag("canvas")
            Form {
                Section("Optional Lecture Feed") {
                    Text("Read-only, one-way snapshot delivery").font(.headline)
                    LabeledContent("Local Folder") { Text(model.rootURL.appendingPathComponent("Feed").path).font(.caption).textSelection(.enabled) }
                    if let feed = model.state.feedGeneration {
                        LabeledContent("Producer", value: feed.producer)
                        LabeledContent("Environment", value: feed.environment)
                        LabeledContent("Exported", value: feed.exportedAt.formatted())
                        LabeledContent("Imported", value: feed.importedAt.formatted())
                    } else { Text("No generation imported. Set up the dedicated receive-only feed separately, or choose a feed folder from a class's Lectures tab.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Import Latest Synced Feed") { model.inWorkspace("Import Latest Synced Feed") { model.importFeed(from: model.rootURL.appendingPathComponent("Feed", isDirectory: true)) } }
                        Button("Clear Unpinned Transcript Cache…", role: .destructive) { model.confirmUnpinnedCacheCleanup() }
                    }
                    Text("An incomplete or corrupt generation never replaces the last verified one. Feed browsing cannot resume paid work or publish to Drive. No server credentials are needed here.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Capture") {
                    Text("The existing synced catalog and finalized v1 audio markers remain the capture contract. The desktop checks the installed recorder and uses a shared process lease before recording. Capture setup is explicit in a class's Capture tab.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Lectures", systemImage: "waveform") }.tag("lectures")
        }.disabled(model.libraryTransfer == .restore)
            .frame(width: 700, height: 600)
    }
}
