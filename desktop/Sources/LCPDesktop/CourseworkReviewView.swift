import SwiftUI
import LCPContextCore
import LCPContextServices

struct CourseworkReviewView: View {
    @ObservedObject var model: WorkspaceModel
    let review: CourseworkImportReview
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?
    @State private var readingSource: SourceCitation?

    var body: some View {
        EditorFrame(title: review.previous == nil ? "Add Canvas Coursework" : "Review Canvas Coursework",
                    saveLabel: review.previous == nil ? "Add Coursework" : "Apply Reviewed Facts", save: accept) {
            Form {
                Section("Destination") {
                    if let enrollment = model.state.classes.first(where: { $0.id == review.proposed.classID }) {
                        Text([model.state.terms.first(where: { $0.id == enrollment.termID })?.name,
                              enrollment.shortLabel, enrollment.section].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
                Section("Facts from saved Canvas revision \(review.sourceSequence)") {
                    Text(review.proposed.title).font(.headline)
                    Text(review.proposed.kind.capitalized)
                    Text(review.proposed.due?.label ?? "Canvas supplied no deadline")
                    if let previous = review.previous {
                        if previous.title != review.proposed.title {
                            Text("Previous title: \(previous.title)").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Previously recorded: \(previous.due?.label ?? "No deadline")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Read Saved Source") { readingSource = review.source }
                    Link("Open Assignment in Canvas", destination: review.sourceURL)
                }
                Section {
                    Text("Saving applies these facts to Coursework only after your review. Importing or refreshing a material never changes a saved deadline. Personal progress, related materials, and your chosen submission link are preserved.")
                    Text("This uses the saved source, not a live Canvas check. Reimport in University Services to check for newer facts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let feedback { Text(feedback).foregroundStyle(.orange).accessibilityLabel("Could not save coursework: \(feedback)") }
            }.formStyle(.grouped)
        }
        .sheet(item: $readingSource) { CitationReaderView(model: model, citation: $0) }
    }

    private func accept() {
        guard model.selectedClassID == review.proposed.classID, let repository = model.repository else {
            feedback = "Reopen this review from the assignment's class."
            return
        }
        do {
            _ = try CourseworkService(repository: repository).accept(review)
            model.refresh()
            model.refreshCanvasReviewQueue()
            dismiss()
        } catch { feedback = error.localizedDescription }
    }
}
