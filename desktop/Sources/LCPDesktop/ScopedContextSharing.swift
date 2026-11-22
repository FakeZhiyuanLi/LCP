import SwiftUI
import LCPContextCore
import LCPContextServices

/// A local review draft. An empty selected-material scope never means all sources.
struct ContextScopeDraft {
    var materialsOnly = false
    var materialIDs: Set<UUID> = []
    var timeLimited = false
    var eventFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var eventUntil = Date()

    var selectedMaterialIDs: [UUID]? { materialsOnly ? materialIDs.sorted { $0.uuidString < $1.uuidString } : nil }
    var from: Date? { timeLimited ? eventFrom : nil }
    var until: Date? { timeLimited ? eventUntil : nil }
    var isValid: Bool {
        (!materialsOnly || (!materialIDs.isEmpty && materialIDs.count <= 1_000)) &&
            RetrievalService.validTimeBounds(eventFrom: from, eventUntil: until)
    }
}

struct SourceScopeControls: View {
    let state: ContextState
    let materials: [SourceMaterial]
    @Binding var materialsOnly: Bool
    @Binding var selectedMaterialIDs: Set<UUID>
    @Binding var timeLimited: Bool
    @Binding var eventFrom: Date
    @Binding var eventUntil: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source scope", selection: $materialsOnly) {
                Text("All Class Context").tag(false)
                Text("Selected Materials Only").tag(true)
            }.pickerStyle(.segmented)
            if materialsOnly {
                if materials.isEmpty {
                    Text("No materials are available in the chosen classes. Import a source or choose all class context.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(materials) { material in
                                Toggle(isOn: Binding(get: { selectedMaterialIDs.contains(material.id) }, set: { selected in
                                    if selected { selectedMaterialIDs.insert(material.id) }
                                    else { selectedMaterialIDs.remove(material.id) }
                                })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(material.title)
                                        Text(classIdentity(for: material)).font(.caption).foregroundStyle(.secondary)
                                        Text(revisionIdentity(for: material)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                            .help(revisionDetails(for: material))
                                        Text("Imported \(material.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.toggleStyle(.checkbox)
                                    .accessibilityLabel("Include \(material.title), \(classIdentity(for: material)), \(revisionIdentity(for: material))")
                                    .accessibilityHint("Selects this material's current revision when the scope is used. Notes and lecture transcripts are excluded in selected-material mode.")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }.frame(minHeight: 80, maxHeight: 170)
                }
                Text("Only the selected documents are included. Notes and lecture transcripts are excluded.").font(.caption).foregroundStyle(.secondary)
                if selectedMaterialIDs.isEmpty { Text("Choose at least one material.").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Includes the chosen classes' materials, current notes, and available lecture transcripts.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Limit source time range", isOn: $timeLimited)
            if timeLimited {
                DatePicker("From (inclusive)", selection: $eventFrom, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Until (inclusive)", selection: $eventUntil, displayedComponents: [.date, .hourAndMinute])
                if eventFrom > eventUntil { Text("The end must be at or after the start.").font(.caption).foregroundStyle(.orange) }
                Text("Times use \(TimeZone.current.identifier). Materials use import time, notes use event time, and lectures use their known capture time. Lectures with unknown capture times are omitted.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: materials.map(\.id)) { _, ids in selectedMaterialIDs.formIntersection(Set(ids)) }
    }
    private func classIdentity(for material: SourceMaterial) -> String {
        guard let enrollment = state.classes.first(where: { $0.id == material.classID }) else { return "Class unavailable · \(material.classID.uuidString.prefix(8))" }
        let term = state.terms.first(where: { $0.id == enrollment.termID })?.name
        return [enrollment.shortLabel, term, enrollment.section.isEmpty ? nil : enrollment.section].compactMap { $0 }.joined(separator: " · ")
    }
    private func revisionIdentity(for material: SourceMaterial) -> String {
        guard let revision = state.materialRevisions.first(where: { $0.id == material.currentRevisionID }) else { return "No current revision" }
        return "Current revision \(revision.sequence)"
    }
    private func revisionDetails(for material: SourceMaterial) -> String {
        guard let revision = state.materialRevisions.first(where: { $0.id == material.currentRevisionID }) else { return "Current revision unavailable." }
        return "SHA-256: \(revision.original.sha256)\nSource: \(material.id.uuidString)"
    }
}

struct ContextExportView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var scope = ContextScopeDraft()
    private var materials: [SourceMaterial] {
        model.state.materials.filter { $0.classID == classID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var enrollment: ClassEnrollment? { model.state.classes.first { $0.id == classID } }
    var body: some View {
        EditorFrame(title: "Review Context to Share", canSave: enrollment != nil && scope.isValid, saveLabel: "Choose Export Folder…", save: save) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(enrollment?.displayLabel ?? "Class unavailable").font(.headline)
                    SourceScopeControls(state: model.state, materials: materials, materialsOnly: $scope.materialsOnly, selectedMaterialIDs: $scope.materialIDs,
                        timeLimited: $scope.timeLimited, eventFrom: $scope.eventFrom, eventUntil: $scope.eventUntil)
                    GroupBox("Review before sharing") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(scope.materialsOnly ? "\(scope.materialIDs.count) selected material(s); no notes or lectures." : "All source types in this class, within any selected time range.")
                            Text(scope.timeLimited ? "\(scope.eventFrom.formatted()) through \(scope.eventUntil.formatted())." : "No source time limit.")
                            Text("This creates a portable snapshot. Original audio, access grants, credentials, and other classes are excluded. Review its manifest and omissions before sending it to an external agent.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
            }
        }
    }
    private func save() {
        let available = Set(materials.map(\.id))
        guard scope.isValid, !scope.materialsOnly || scope.materialIDs.isSubset(of: available) else { return }
        if model.exportSelectedContext(classID: classID, materialIDs: scope.selectedMaterialIDs, eventFrom: scope.from, eventUntil: scope.until) {
            model.presentedContextExportClassID = nil
            dismiss()
        }
    }
}

/// Apply the same presentation to normal and native fallback workspace windows.
struct ScopedWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        WorkspaceView(model: model)
            .sheet(isPresented: Binding(get: { model.presentedContextExportClassID != nil }, set: { if !$0 { model.presentedContextExportClassID = nil } })) {
                if let id = model.presentedContextExportClassID { ContextExportView(model: model, classID: id) }
            }
    }
}
