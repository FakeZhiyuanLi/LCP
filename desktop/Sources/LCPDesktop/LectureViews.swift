import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct LectureLibraryView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @Binding var selectedRecordingID: UUID?
    @Binding var showUnassigned: Bool
    var recordings: [LectureRecording] { model.state.recordings.filter { $0.classID == classID || (showUnassigned && $0.classID == nil) }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let generation = model.state.feedGeneration {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Feed exported \(generation.exportedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                        Text(Date.now.timeIntervalSince(generation.exportedAt) > 86400 ? "Cached feed is stale. Current server activity is unknown." : "Last verified complete generation").font(.caption2).foregroundStyle(.secondary)
                    }
                } else { Text("No server generation imported. Local recordings still appear here.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Toggle("Unassigned", isOn: $showUnassigned).toggleStyle(.checkbox)
                Menu("Import Feed") {
                    Button("Import Latest Synced Generation") { importFeed(model.rootURL.appendingPathComponent("Feed", isDirectory: true)) }
                    Button("Choose Feed Folder…") { chooseFeed() }
                }
            }
            if recordings.isEmpty {
                ContentUnavailableView("Lecture Context Appears Here", systemImage: "waveform", description: Text("Recordings and verified synced transcripts keep separate processing, quality, and publication facts. Import a complete feed to read transcript content offline."))
            } else {
                recordingPanes
            }
        }
        .onChange(of: recordings.map(\.id)) { _, visibleIDs in
            if let selectedRecordingID, !visibleIDs.contains(selectedRecordingID) { self.selectedRecordingID = nil }
        }
    }

    private var recordingPanes: some View {
        HSplitView {
            List(recordings, selection: $selectedRecordingID) { recording in
                VStack(alignment: .leading, spacing: 7) {
                    Text(recording.filename).font(.headline).lineLimit(2)
                    Text(recording.classID == nil ? "Unassigned · review class association" : recording.status.processing).font(.caption).foregroundStyle(recording.classID == nil ? Color.orange : Color.secondary)
                    Text(recording.status.transcriptAvailable == "available" || recording.status.transcriptAvailable == "yes" ? "Transcript available" : "Content: \(recording.status.transcriptAvailable)").font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 8).tag(recording.id)
            }.frame(minWidth: 210, idealWidth: 280, maxWidth: 380, minHeight: 0, maxHeight: .infinity)
            VStack {
                if let selected = recordings.first(where: { $0.id == selectedRecordingID }) {
                    LectureDetailView(model: model, recording: selected, viewingClassID: classID).id(selected.id)
                } else { ContentUnavailableView("Choose a Lecture", systemImage: "text.page") }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
    private func chooseFeed() {
        let panel = NSOpenPanel(); panel.title = "Choose Desktop Snapshot Feed"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; importFeed(url)
    }
    private func importFeed(_ url: URL) {
        model.importFeed(from: url)
    }
}

private struct LectureDetailView: View {
    @ObservedObject var model: WorkspaceModel
    let recording: LectureRecording
    let viewingClassID: UUID
    @StateObject private var playback = AudioPlaybackService()
    @State private var revisionID: UUID?
    @State private var audioLoadTask: Task<Void, Never>?
    @State private var showAssociationEditor = false
    var revisions: [TranscriptRevision] { model.state.transcriptRevisions.filter { $0.recordingID == recording.id }.sorted { $0.createdAt > $1.createdAt } }
    var revision: TranscriptRevision? {
        if let revisionID { return revisions.first { $0.id == revisionID } }
        guard let currentID = recording.currentTranscriptRevisionID else { return nil }
        return revisions.first { $0.id == currentID }
    }
    var body: some View {
        ScrollView {
            detailContents.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDisappear {
            audioLoadTask?.cancel()
            audioLoadTask = nil
            playback.stop()
        }
        .sheet(isPresented: $showAssociationEditor) { RecordingClassAssociationEditor(model: model, recording: recording) }
    }

    private var detailContents: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(recording.filename).font(.headline).textSelection(.enabled)
                Spacer()
                if recording.retired { Label("Retired at Server", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
            }
            if recording.classID == nil {
                HStack {
                    Text("Review this historical recording before class-scoped retrieval.").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Associate with This Class") {
                        model.mutate { state in
                            guard let index = state.recordings.firstIndex(where: { $0.id == recording.id }), state.recordings[index].classID == nil,
                                  state.classes.contains(where: { $0.id == viewingClassID }) else { throw DesktopUIError.message("This lecture's class association changed. Review its current association before assigning it.") }
                            state.recordings[index].classID = viewingClassID
                        }
                    }
                        .accessibilityLabel("Associate \(recording.filename) with \(model.state.classes.first { $0.id == viewingClassID }?.shortLabel ?? "the selected class")")
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Academic Class").font(.caption).foregroundStyle(.secondary)
                        Text(lectureAcademicClassLabel(recording.classID, state: model.state)).font(.callout).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Change Class…") { showAssociationEditor = true }
                        .accessibilityLabel("Review class association for \(recording.filename)")
                }
            }
            if let history = recording.associationHistory, !history.isEmpty {
                RecordingAssociationHistoryView(model: model, history: history)
            }
            if let capturedAt = recording.capturedAt {
                Text("Captured \(capturedAt.formatted()) · \(recording.timeZoneID ?? "timezone unknown")").font(.caption).foregroundStyle(.secondary)
            } else if let legacyTime = recording.legacyLocalTimestamp {
                Text("Legacy filename time: \(legacyTime) · exact timezone unknown").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Processing and Publication Facts") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    fact("Finalized locally", recording.status.finalizedLocally)
                    fact("Server received", recording.status.serverReceived)
                    fact("Processing", recording.status.processing)
                    fact("Quality", recording.status.quality)
                    fact("Transcript content", recording.status.transcriptAvailable)
                    fact("Drive publication", recording.status.drivePublication)
                    fact("External agent ingestion", recording.status.externalIngestion)
                }.font(.caption).padding(.vertical, 8)
            }
            Divider()
            audioControls
            if !revisions.isEmpty {
                Picker("Transcript Revision", selection: $revisionID) {
                    Text(recording.currentTranscriptRevisionID == nil ? "No current accepted content" : "Current accepted revision").tag(nil as UUID?)
                    ForEach(revisions.filter { $0.id != recording.currentTranscriptRevisionID }) { r in
                        Text("Historical · \(r.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(String(r.content.sha256.prefix(10)))").tag(Optional(r.id))
                    }
                }
                if revisionID != nil { Text("Viewing an explicitly selected historical revision. Current processing facts may differ.").font(.caption).foregroundStyle(.orange) }
            }
            if let revision {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(revision.cues.enumerated()), id: \.offset) { index, cue in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Button(formatDuration(cue.start)) { play(from: cue.start) }.buttonStyle(.link).disabled(playback.recordingID != recording.id).font(.system(.callout, design: .monospaced))
                                    .accessibilityLabel("Play \(recording.filename) at \(formatDuration(cue.start))")
                                if let speaker = cue.speaker { Text(speaker).font(.caption2).foregroundStyle(.secondary) }
                            }.frame(width: 70, alignment: .leading)
                            Text(cue.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            MoreActionsMenu(title: "Citation actions for \(recording.filename) at \(formatDuration(cue.start))") {
                                Button("Open Exact Citation") { model.presentedCitation = citation(revision, cueIndex: index) }
                                Button("Copy Citation Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(CitationLink.url(for: citation(revision, cueIndex: index)).absoluteString, forType: .string) }
                                Button("Bookmark Cue") { bookmark(revision, cueIndex: index) }
                            }
                            .disabled(recording.classID == nil)
                        }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(Array(revision.audioEvents.enumerated()), id: \.offset) { _, event in
                        Text("[\(formatDuration(event.start))] \(event.text)").font(.caption).italic().foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            } else {
                ContentUnavailableView("Transcript Content Unavailable", systemImage: "text.badge.xmark", description: Text("No accepted transcript revision is cached. Status does not trigger transcription or a retry. You can continue using materials and notes."))
            }
        }
    }
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if playback.recordingID == recording.id {
                    Button(playback.isPlaying ? "Pause" : "Play") {
                        if playback.isPlaying { playback.pause() } else { play() }
                    }
                    .accessibilityLabel(playback.isPlaying ? "Pause \(recording.filename)" : "Play \(recording.filename)")
                    Text("\(formatDuration(playback.currentTime)) / \(formatDuration(playback.duration))")
                        .font(.caption.monospacedDigit())
                        .accessibilityLabel("\(formatDuration(playback.currentTime)) of \(formatDuration(playback.duration))")
                } else if let path = recording.localAudioPath, path.hasPrefix("/"), !path.utf8.contains(0) {
                    Button("Load Linked Audio") {
                        loadAudio(URL(fileURLWithPath: path, isDirectory: false), rememberLink: false)
                    }
                    .accessibilityHint("Verifies the saved audio file for \(recording.filename) and enables playback.")
                }
                Button(recording.localAudioPath == nil ? "Choose Local Audio…" : "Relink Audio…", action: chooseAudio)
                    .accessibilityHint("Choose an audio file matching this lecture’s size and SHA-256.")
                if audioLoadTask != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Verifying local audio")
                }
            }
            .disabled(audioLoadTask != nil)
            Text(playback.status).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func fact(_ label: String, _ value: String) -> some View { GridRow { Text(label).foregroundStyle(.secondary); Text(value.replacingOccurrences(of: "_", with: " ")).textSelection(.enabled) } }
    private func citation(_ revision: TranscriptRevision, cueIndex: Int) -> SourceCitation {
        SourceCitation(classID: recording.classID ?? viewingClassID, sourceKind: "transcript", sourceID: recording.id, revisionID: revision.id, payloadSHA256: revision.content.sha256, locator: .cues(start: cueIndex, end: cueIndex), label: "\(recording.filename) [\(formatDuration(revision.cues[cueIndex].start))]")
    }
    private func bookmark(_ revision: TranscriptRevision, cueIndex: Int) {
        guard let repository = model.repository, let classID = recording.classID else { return }
        model.perform {
            let source = try RetrievalService(repository: repository).pin(citation(revision, cueIndex: cueIndex))
            try repository.update { $0.activities.append(ActivityEntry(classID: classID, kind: "bookmark", title: source.label, body: revision.cues[cueIndex].text, citations: [source])) }
            model.notice = "Bookmarked the exact cue and retained its revision."
        }
    }
    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio for This Lecture"
        panel.message = "LCP verifies the file’s size and SHA-256 before linking it to this lecture."
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadAudio(url, rememberLink: true)
    }
    private func loadAudio(_ url: URL, rememberLink: Bool) {
        guard audioLoadTask == nil else { return }
        audioLoadTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            defer { if !Task.isCancelled { audioLoadTask = nil } }
            do {
                try await playback.load(url: url, recording: recording)
                guard !Task.isCancelled, rememberLink else { return }
                model.mutate { state in
                    guard let i = state.recordings.firstIndex(where: { $0.id == recording.id }),
                          state.recordings[i].sizeBytes == recording.sizeBytes,
                          state.recordings[i].sha256 == recording.sha256,
                          state.recordings[i].localAudioPath == recording.localAudioPath else {
                        throw DesktopUIError.message("This lecture changed during verification. Reopen it to link its audio.")
                    }
                    state.recordings[i].localAudioPath = url.path
                }
            } catch {
                if !Task.isCancelled { model.errorMessage = error.localizedDescription }
            }
        }
    }
    private func play(from time: TimeInterval? = nil) {
        do { try playback.play(from: time) }
        catch { model.errorMessage = error.localizedDescription }
    }
}


private struct RecordingClassAssociationEditor: View {
    @ObservedObject var model: WorkspaceModel
    let recording: LectureRecording
    @Environment(\.dismiss) private var dismiss
    @State private var previousClassID: UUID?
    @State private var previousAssociationHistory: [RecordingAssociationRevision]?
    @State private var selectedClassID: UUID?
    @State private var reviewedClassID: UUID?
    @State private var confirmChange = false

    init(model: WorkspaceModel, recording: LectureRecording) {
        self.model = model
        self.recording = recording
        _previousClassID = State(initialValue: recording.classID)
        _previousAssociationHistory = State(initialValue: recording.associationHistory)
        _selectedClassID = State(initialValue: recording.classID)
    }
    private var sourceAssociationIsCurrent: Bool {
        guard let current = model.state.recordings.first(where: { $0.id == recording.id }) else { return false }
        return current.classID == previousClassID && current.associationHistory == previousAssociationHistory
    }
    private var selectionIsValid: Bool {
        selectedClassID == nil || model.state.classes.contains { $0.id == selectedClassID }
    }
    private var classes: [ClassEnrollment] {
        model.state.classes.sorted {
            lectureAcademicClassLabel($0.id, state: model.state).localizedStandardCompare(lectureAcademicClassLabel($1.id, state: model.state)) == .orderedAscending
        }
    }
    var body: some View {
        EditorFrame(title: "Review Lecture Class Association", canSave: sourceAssociationIsCurrent && selectionIsValid && selectedClassID != previousClassID,
                    saveLabel: "Review Change…", save: reviewChange) {
            VStack(alignment: .leading, spacing: 18) {
                Text(recording.filename).font(.headline).textSelection(.enabled)
                LabeledContent("Current Academic Class") {
                    Text(lectureAcademicClassLabel(previousClassID, state: model.state)).multilineTextAlignment(.trailing)
                }
                Picker("New Academic Class", selection: $selectedClassID) {
                    Text("Unassigned").tag(nil as UUID?)
                    ForEach(classes) { enrollment in
                        Text(lectureAcademicClassLabel(enrollment.id, state: model.state)).tag(Optional(enrollment.id))
                    }
                }
                .accessibilityHint("Choose a term-specific class or Unassigned. The choice is saved only after the following confirmation.")
                Text("Future lecture browsing and search use the new academic class. Existing saved citations stay linked to their original class and exact transcript revision.")
                    .foregroundStyle(.secondary)
                Text("This correction changes which class lists the lecture. Its audio file, recording destination, and Drive publication history are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Every saved association change is retained in the lecture's history.").font(.caption).foregroundStyle(.secondary)
                if !selectionIsValid { Text("The selected class is no longer available. Choose an existing class or Unassigned.").font(.caption).foregroundStyle(.orange) }
                if !sourceAssociationIsCurrent { Text("This lecture's association history changed while the review was open. Cancel and reopen the review before saving.").font(.caption).foregroundStyle(.orange) }
                Spacer(minLength: 0)
            }.padding(.bottom, 16)
        }
        .confirmationDialog("Save this lecture's class association change?", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("Save Class Change", action: applyReviewedChange)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From: \(lectureAcademicClassLabel(previousClassID, state: model.state))\nTo: \(lectureAcademicClassLabel(reviewedClassID, state: model.state))\n\nSaved citations retain their original class and source revision. Recording and publication identities stay unchanged.")
        }
    }
    private func reviewChange() {
        model.refresh()
        guard sourceAssociationIsCurrent else {
            model.errorMessage = "This lecture's class association or history changed while you were reviewing it. Cancel and reopen the review before saving."
            return
        }
        guard selectionIsValid, selectedClassID != previousClassID else { return }
        reviewedClassID = selectedClassID
        confirmChange = true
    }
    private func applyReviewedChange() {
        guard reviewedClassID != previousClassID else { return }
        model.mutate { state in
            guard let index = state.recordings.firstIndex(where: { $0.id == recording.id }) else {
                throw DesktopUIError.message("The lecture is unavailable. Its existing context has not been changed.")
            }
            guard state.recordings[index].classID == previousClassID,
                  state.recordings[index].associationHistory == previousAssociationHistory else {
                throw DesktopUIError.message("This lecture's class association or history changed while you were reviewing it. Cancel and reopen the review before saving.")
            }
            guard reviewedClassID == nil || state.classes.contains(where: { $0.id == reviewedClassID }) else {
                throw DesktopUIError.message("The reviewed target class is unavailable. Choose an existing class or Unassigned.")
            }
            state.recordings[index].classID = reviewedClassID
        }
        if model.errorMessage == nil {
            model.notice = "Lecture association updated. Future browsing uses \(lectureAcademicClassLabel(reviewedClassID, state: model.state)); saved citations retain their original class and transcript revision."
            dismiss()
        }
    }
}

private struct RecordingAssociationHistoryView: View {
    @ObservedObject var model: WorkspaceModel
    let history: [RecordingAssociationRevision]
    var body: some View {
        DisclosureGroup("Class Association History · \(history.count) change(s)") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(history.sorted { $0.changedAt == $1.changedAt ? $0.id.uuidString < $1.id.uuidString : $0.changedAt > $1.changedAt }) { revision in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(revision.changedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text("From: \(lectureAcademicClassLabel(revision.fromClassID, state: model.state))").font(.callout)
                            Text("To: \(lectureAcademicClassLabel(revision.toClassID, state: model.state))").font(.callout)
                            if !revision.retainedCitations.isEmpty {
                                Text("\(revision.retainedCitations.count) existing exact citation(s) retained with their original class and revision.").font(.caption).foregroundStyle(.secondary)
                                FlowCitationLinks(citations: revision.retainedCitations, open: { model.presentedCitation = $0 })
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 8)
            }.frame(height: CGFloat(min(history.count, 2)) * 90)
            Text("Association history is retained automatically. Correcting a class association does not rewrite an earlier saved citation.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private func lectureAcademicClassLabel(_ id: UUID?, state: ContextState) -> String {
    guard let id else { return "Unassigned" }
    guard let enrollment = state.classes.first(where: { $0.id == id }) else { return "Unavailable academic class" }
    let term = state.terms.first(where: { $0.id == enrollment.termID })?.name
    return [enrollment.displayLabel, term, enrollment.section.isEmpty ? nil : "Section " + enrollment.section]
        .compactMap { $0 }.joined(separator: " · ")
}
