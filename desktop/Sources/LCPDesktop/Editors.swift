import SwiftUI
import LCPContextCore
import LCPContextServices

struct EditorFrame<Content: View>: View {
    let title: String
    let canSave: Bool
    let saveLabel: String
    let height: CGFloat
    let save: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    init(title: String, canSave: Bool = true, saveLabel: String = "Save", height: CGFloat = 580, save: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title; self.canSave = canSave; self.saveLabel = saveLabel; self.height = height; self.save = save; self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.title2.bold()); Spacer() }.padding(24)
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 24)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(saveLabel, action: save).keyboardShortcut(.defaultAction).disabled(!canSave) }.padding(20)
        }
        .frame(width: 620, height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
    }
}

struct TermEditor: View {
    @ObservedObject var model: WorkspaceModel
    var existing: AcademicTerm? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var timeZoneID = "America/Los_Angeles"
    @State private var hasDates = false
    @State private var archived = false
    @State private var starts = Date.now
    @State private var ends = Date.now.addingTimeInterval(86400 * 90)
    var body: some View {
        EditorFrame(title: existing == nil ? "New Academic Term" : "Edit Academic Term", canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && TimeZone(identifier: timeZoneID) != nil && (!hasDates || ends >= starts), save: save) {
            Form {
                TextField("Term Name", text: $name, prompt: Text("Autumn 2026"))
                TextField("University Time Zone", text: $timeZoneID)
                Text("Use an IANA identifier such as America/Los_Angeles. Class dates keep the university's timezone while you travel.").font(.caption).foregroundStyle(.secondary)
                Toggle("Add Term Dates", isOn: $hasDates)
                if hasDates { DatePicker("Starts", selection: $starts, displayedComponents: .date); DatePicker("Ends", selection: $ends, displayedComponents: .date) }
                Toggle("Archived Term", isOn: $archived)
            }.formStyle(.grouped)
        }.onAppear {
            if let existing {
                name = existing.name; timeZoneID = existing.timeZoneID; archived = existing.archived
                if let start = existing.startDate, let end = existing.endDate { hasDates = true; starts = start.date; ends = end.date }
            }
        }
    }
    private func save() {
        let term = AcademicTerm(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), startDate: hasDates ? starts.localDate : nil, endDate: hasDates ? ends.localDate : nil, timeZoneID: timeZoneID, archived: archived)
        model.mutate { state in
            if let index = state.terms.firstIndex(where: { $0.id == term.id }) {
                guard state.terms[index] == existing else { throw DesktopUIError.message("This term changed while the editor was open. Reopen it before applying these changes.") }
                state.terms[index] = term
            } else { state.terms.append(term) }
        }
        if model.errorMessage == nil { dismiss() }
    }
}

struct ClassEditor: View {
    @ObservedObject var model: WorkspaceModel
    let existing: ClassEnrollment?
    @Environment(\.dismiss) private var dismiss
    @State private var termID: UUID?
    @State private var code = ""
    @State private var title = ""
    @State private var section = ""
    @State private var instructor = ""
    @State private var credits = ""
    @State private var sessionDetails = ""
    @State private var location = ""
    @State private var archived = false
    @State private var showsDetails = false

    init(model: WorkspaceModel, existing: ClassEnrollment?) {
        self.model = model
        self.existing = existing
        if let existing {
            _termID = State(initialValue: existing.termID)
        } else {
            _termID = State(initialValue: model.state.terms.last(where: { !$0.archived })?.id)
        }
    }

    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var creditText: String { credits.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validCredits: Bool {
        if creditText.isEmpty { return true }
        guard let value = Double(creditText) else { return false }
        return value.isFinite && value >= 0
    }

    var body: some View {
        EditorFrame(title: existing == nil ? "Add a Class" : "Edit Class", canSave: !name.isEmpty && validCredits, height: showsDetails ? 580 : 276, save: save) {
            Form {
                TextField("Class Name", text: $title, prompt: Text("e.g. Comlit 9"))
                DisclosureGroup("Optional details", isExpanded: $showsDetails) {
                    if !model.state.terms.isEmpty {
                        Picker("Term", selection: $termID) {
                            Text("No term").tag(nil as UUID?)
                            ForEach(model.state.terms) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    TextField("Course Code", text: $code)
                    TextField("Section", text: $section)
                    TextField("Instructor / Office Hours", text: $instructor)
                    TextField("Meeting / Session Details", text: $sessionDetails)
                    TextField("Location / Online Meeting", text: $location)
                    TextField("Credits", text: $credits)
                    if !validCredits {
                        Text("Enter a nonnegative number or leave credits empty.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Archived Class", isOn: $archived)
                }
            }.formStyle(.grouped)
        }.onAppear {
            if let existing {
                code = existing.courseCode
                title = existing.title
                section = existing.section
                instructor = existing.instructor
                credits = existing.credits.map { String($0) } ?? ""
                archived = existing.archived
                sessionDetails = existing.sessionDetails ?? ""
                location = existing.location ?? ""
                showsDetails = true
            }
        }
    }

    private func save() {
        guard !name.isEmpty, validCredits else { return }
        var enrollment = existing ?? ClassEnrollment(termID: nil, courseCode: "", title: name)
        enrollment.termID = termID
        enrollment.courseCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        enrollment.title = name
        enrollment.section = section
        enrollment.instructor = instructor
        enrollment.credits = Double(creditText)
        enrollment.archived = archived
        enrollment.sessionDetails = sessionDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sessionDetails
        enrollment.location = location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : location
        model.mutate { state in
            if let index = state.classes.firstIndex(where: { $0.id == enrollment.id }) {
                var baseline = existing
                baseline?.driveFolder = state.classes[index].driveFolder
                guard state.classes[index] == baseline else { throw DesktopUIError.message("This class changed while the editor was open. Reopen it before applying these changes.") }
                enrollment.driveFolder = state.classes[index].driveFolder
                state.classes[index] = enrollment
            } else {
                guard existing == nil else { throw DesktopUIError.message("This class is no longer in the library.") }
                enrollment.driveFolder = ClassDriveFolder(for: enrollment)
                state.classes.append(enrollment)
            }
        }
        if model.errorMessage == nil {
            if existing == nil { model.processPendingDriveFolders() }
            if model.selection == .capture, existing == nil, !model.captureInProgress {
                model.captureClassID = enrollment.id
            } else {
                model.selection = .classDetail(enrollment.id)
            }
            dismiss()
        }
    }
}

struct ActivityEditor: View {
    @ObservedObject var model: WorkspaceModel
    let existing: ActivityEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var kind = "note"
    @State private var eventAt = Date.now
    @State private var agentIdentity = ""
    @State private var citationText = ""
    @State private var citations: [SourceCitation] = []
    @State private var transcriptReview: TranscriptCitationReview?
    @State private var replacements: [Int: TranscriptCitationReplacement] = [:]
    @State private var inputCitationText = ""
    @State private var reviewedInputContext = false
    @State private var inputContextCitations: [SourceCitation] = []
    @State private var editingClassID: UUID?
    private var hasAgentAttribution: Bool { kind == "agent_artifact" || existing?.agentIdentity != nil }
    var body: some View {
        EditorFrame(title: existing == nil ? "Log Class Context" : "Correct History Entry", canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save: save) {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Type", selection: $kind) { Text("Student Note").tag("note"); Text("Study Session").tag("study_log"); Text("Class Activity").tag("class_activity"); Text("Question").tag("question"); Text("Selected Agent Answer").tag("agent_artifact") }
                    DatePicker("Happened", selection: $eventAt)
                }
                if hasAgentAttribution { TextField("Agent Identity", text: $agentIdentity).textFieldStyle(.roundedBorder) }
                TextEditor(text: $bodyText).font(.body).border(.quaternary).accessibilityLabel("Entry text").frame(minHeight: 180)
                HStack {
                    TextField("Paste an lcp:// citation link", text: $citationText).textFieldStyle(.roundedBorder)
                    Button("Attach") {
                        model.perform {
                            guard let url = URL(string: citationText) else { throw DesktopUIError.message("Enter a valid LCP citation URL.") }
                            let citation = try CitationLink.decode(url)
                            guard citation.classID == editingClassID else { throw DesktopUIError.message("Attach a source from this class.") }
                            guard let repository = model.repository else { throw DesktopUIError.message("Open the local library before attaching a source.") }
                            _ = try RetrievalService(repository: repository).resolve(citation)
                            citations.append(citation); citationText = ""
                        }
                    }.disabled(citationText.isEmpty)
                }
                if !citations.isEmpty { Text("\(citations.count) exact source citation(s) will be retained with this entry.").font(.caption).foregroundStyle(.secondary) }
                if let existing {
                    ForEach(existing.citations.indices, id: \.self) { index in
                        let citation = existing.citations[index]
                        if let replacement = replacements[index] {
                            HStack {
                                Text("On save, \(citation.label) will cite \(replacement.citation.label).")
                                    .font(.callout)
                                Button("Undo Replacement") { replacements[index] = nil }
                            }
                        } else if let recording = model.state.recordings.first(where: { $0.id == citation.sourceID }),
                                  citation.sourceKind == "transcript", recording.classID == existing.classID,
                                  !recording.retired, let currentID = recording.currentTranscriptRevisionID, currentID != citation.revisionID {
                            HStack {
                                Text("A newer transcript is available for \(citation.label).").font(.callout)
                                Button("Review Replacement…") {
                                    guard let repo = model.repository else { return }
                                    model.perform {
                                        transcriptReview = try RetrievalService(repository: repo).reviewTranscriptCitation(in: existing, at: index)
                                    }
                                }
                                .accessibilityLabel("Review replacement for \(citation.label)")
                            }
                        }
                    }
                }
                if hasAgentAttribution {
                    GroupBox("Agent Input Context") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("I reviewed which LCP sources were supplied", isOn: $reviewedInputContext)
                            if reviewedInputContext {
                                Text("Record the actual source inputs separately from citations in the answer. An empty list records your review that no LCP sources were supplied.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    TextField("Paste an input source's lcp:// citation", text: $inputCitationText).textFieldStyle(.roundedBorder)
                                    Button("Add Input", action: attachInputCitation).disabled(inputCitationText.isEmpty || inputContextCitations.count >= 128)
                                }
                                ForEach(inputContextCitations) { citation in
                                    HStack {
                                        Text(citation.label.isEmpty ? "Exact \(citation.sourceKind) source" : citation.label).font(.caption).lineLimit(2)
                                        Spacer()
                                        Button("Remove") { inputContextCitations.removeAll { $0.id == citation.id } }.font(.caption)
                                    }
                                }
                                Text("\(inputContextCitations.count) reviewed input source(s). Exact revisions are retained in backups.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Input context is unknown. Answer citations do not prove which sources the agent received.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(6)
                    }
                }
                Text(existing == nil ? "Event time records when it happened. Recorded time is saved separately." : "Saving creates a new immutable revision; previous text and cited sources remain available.").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 16)
            }
        }.sheet(item: $transcriptReview) { review in
            TranscriptCitationCorrectionView(review: review) { replacement in
                replacements[review.citationIndex] = replacement
                transcriptReview = nil
            }
        }.onAppear {
            guard editingClassID == nil else { return }
            editingClassID = existing?.classID ?? model.selectedClassID
            if let existing { title = existing.title; bodyText = existing.body; kind = existing.kind; eventAt = existing.eventAt; agentIdentity = existing.agentIdentity ?? ""; citations = existing.citations; reviewedInputContext = existing.inputContextManifest != nil; inputContextCitations = existing.inputContextManifest ?? [] }
        }
    }
    private func attachInputCitation() {
        model.perform {
            guard let url = URL(string: inputCitationText) else { throw DesktopUIError.message("Enter a valid LCP citation URL.") }
            let citation = try CitationLink.decode(url)
            guard citation.classID == editingClassID else { throw DesktopUIError.message("Choose an input source from this class.") }
            guard let repository = model.repository else { throw DesktopUIError.message("Open the local library before recording input sources.") }
            _ = try RetrievalService(repository: repository).resolve(citation)
            if !inputContextCitations.contains(citation) { inputContextCitations.append(citation) }
            inputCitationText = ""
        }
    }
    private func save() {
        guard let classID = editingClassID else { return }
        var entry = existing ?? ActivityEntry(classID: classID, title: title)
        entry.title = title; entry.body = bodyText; entry.kind = kind; entry.eventAt = eventAt
        entry.agentIdentity = hasAgentAttribution ? (agentIdentity.isEmpty ? "Unspecified external agent (manual save)" : agentIdentity) : nil
        entry.citations = citations
        entry.inputContextManifest = hasAgentAttribution && reviewedInputContext ? inputContextCitations : nil
        if existing != nil { entry.version += 1; entry.revisionID = UUID(); entry.recordedAt = Date(); entry.content = nil }
        model.mutate { state in
            if let index = state.activities.firstIndex(where: { $0.id == entry.id }) {
                guard state.activities[index].version == existing?.version,
                      state.activities[index].revisionID == existing?.revisionID else { throw DesktopUIError.message("This entry changed while the editor was open. Review its current revision before saving a correction.") }
                for position in replacements.keys.sorted() {
                    try replacements[position]?.apply(to: &entry, in: state)
                }
                state.activities[index] = entry
            }
            else {
                guard existing == nil else { throw DesktopUIError.message("The original entry is unavailable. Reopen your class history.") }
                state.activities.append(entry)
            }
        }
        if model.errorMessage == nil { dismiss() }
    }
}

private struct TranscriptCitationCorrectionView: View {
    let review: TranscriptCitationReview
    let choose: (TranscriptCitationReplacement) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?
    @State private var search = ""
    @State private var failure: String?

    private var matchingCues: [Int] {
        review.current.cues.indices.filter { index in
            let cue = review.current.cues[index]
            return search.isEmpty || cue.text.localizedCaseInsensitiveContains(search)
                || formatDuration(cue.start).contains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Replacement Cue").font(.title2.bold())
            Text(review.recordingName).foregroundStyle(.secondary)
            TextField("Find words or a start time in the current transcript", text: $search)
                .textFieldStyle(.roundedBorder)
            List(matchingCues, id: \.self, selection: $selection) { index in
                let cue = review.current.cues[index]
                HStack(alignment: .top) {
                    Text(formatDuration(cue.start)).monospacedDigit()
                    Text(cue.text).lineLimit(2)
                }.tag(index)
            }
            .accessibilityLabel("Current transcript cues")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Saved passage").font(.headline)
                    ScrollView {
                        Text(review.original.text + (review.original.isTruncated ? "…" : ""))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Selected replacement").font(.headline)
                    if let selection {
                        let cue = review.current.cues[selection]
                        Text("\(formatDuration(cue.start))–\(formatDuration(cue.end))").monospacedDigit()
                        ScrollView {
                            Text(cue.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("Select a cue above.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Selected Cue") {
                    guard let selection else { return }
                    do { choose(try review.choose(cueIndex: selection)) }
                    catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }.padding(20).frame(minWidth: 640, minHeight: 460)
    }
}

struct CourseworkEditor: View {
    @ObservedObject var model: WorkspaceModel
    let existing: CourseworkItem?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = "assignment"
    @State private var deadlineMode = "none"
    @State private var due = Date.now
    @State private var zone = "America/Los_Angeles"
    @State private var status = "not_started"
    @State private var link = ""
    @State private var editingClassID: UUID?
    @State private var selectedMaterials: Set<UUID> = []
    @State private var readingSource: SourceCitation?
    @State private var feedback: String?
    var body: some View {
        EditorFrame(title: existing == nil ? "Add Coursework Context" : "Edit Coursework", canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (deadlineMode != "timed" || TimeZone(identifier: zone) != nil), save: save) {
            Form {
                TextField("Title", text: $title)
                Picker("Kind", selection: $kind) { Text("Assignment").tag("assignment"); Text("Reading").tag("reading"); Text("Quiz").tag("quiz"); Text("Project").tag("project"); Text("Exam").tag("exam") }
                Picker("Deadline", selection: $deadlineMode) { Text("Unknown / None").tag("none"); Text("Date Only").tag("date"); Text("Exact Time").tag("timed") }
                if deadlineMode == "date" { DatePicker("Due Date", selection: $due, displayedComponents: .date); Text("Date only. LCP will not invent an 11:59 p.m. deadline.").font(.caption).foregroundStyle(.secondary) }
                if deadlineMode == "timed" { DatePicker("Due", selection: $due).environment(\.timeZone, TimeZone(identifier: zone) ?? .current); TextField("Deadline Time Zone", text: $zone) }
                Picker("Progress", selection: $status) { Text("Not Started").tag("not_started"); Text("In Progress").tag("in_progress"); Text("Completed").tag("completed"); Text("Submitted").tag("submitted"); Text("Graded").tag("graded") }
                TextField("Submission Link", text: $link)
                if let source = existing?.sourceCitation {
                    Button("Read Reviewed Canvas Source") { readingSource = source }
                    Text("This is saved source evidence. Changes you make here are local; reimport Canvas and review its facts to update from the source.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Related class materials") {
                    Text("Attach saved Drive files, Gmail messages, Gradescope feedback, UCI references, or local readings. Each selection keeps its exact revision offline.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.state.materials.filter { $0.classID == editingClassID && $0.id != existing?.sourceCitation?.sourceID }) { material in
                        Toggle(isOn: Binding(get: { selectedMaterials.contains(material.id) }, set: {
                            if $0 { selectedMaterials.insert(material.id) } else { selectedMaterials.remove(material.id) }
                        })) {
                            Text(material.title)
                            Text(material.kind).font(.caption).foregroundStyle(.secondary)
                        }.toggleStyle(.checkbox)
                    }
                }
                Text("Official deadline context is separate from a personal work plan. No grade calculation or reminders are scheduled.").font(.caption).foregroundStyle(.secondary)
                if let feedback { Text(feedback).foregroundStyle(.orange) }
            }.formStyle(.grouped)
        }.onAppear {
            editingClassID = existing?.classID ?? model.selectedClassID
            selectedMaterials = Set((existing?.relatedCitations ?? []).map(\.sourceID))
            if let existing { title = existing.title; kind = existing.kind; status = existing.status; link = existing.submissionURL ?? ""; switch existing.due { case .dateOnly(let day): deadlineMode = "date"; due = day.date; case .timed(let instant, let tz): deadlineMode = "timed"; due = instant; zone = tz; default: break } }
            else if let selected = model.selectedClass, let term = model.state.terms.first(where: { $0.id == selected.termID }) { zone = term.timeZoneID }
        }.sheet(item: $readingSource) { CitationReaderView(model: model, citation: $0) }
    }
    private func save() {
        guard let classID = editingClassID else { return }
        var item = existing ?? CourseworkItem(classID: classID, title: title)
        item.title = title; item.kind = kind; item.status = status; item.submissionURL = link.isEmpty ? nil : link
        item.due = deadlineMode == "date" ? .dateOnly(due.localDate) : (deadlineMode == "timed" ? .timed(instant: due, timeZoneID: zone) : nil)
        guard let repository = model.repository else { return }
        do {
            let service = CourseworkService(repository: repository)
            if !selectedMaterials.isEmpty || existing?.relatedCitations != nil {
                item.relatedCitations = try service.evidence(materialIDs: selectedMaterials, classID: classID,
                    preserving: existing?.relatedCitations ?? [])
            }
            _ = try service.save(item, expectedVersion: existing?.version)
            model.refresh()
            dismiss()
        } catch { feedback = error.localizedDescription }
    }
}

extension Date {
    var localDate: LocalDate { let c = Calendar.current.dateComponents([.year,.month,.day], from: self); return LocalDate(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1) }
}
extension LocalDate {
    var date: Date { Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast }
    var label: String { String(format: "%04d-%02d-%02d", year, month, day) }
}
extension AcademicDeadline {
    var label: String { switch self { case .dateOnly(let day): return "\(day.label) · date only"; case .timed(let date, let zone): let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = TimeZone(identifier: zone); return "\(formatter.string(from: date)) · \(zone)" } }
}
