import AppKit
import SwiftUI
import LCPContextCore
import LCPContextServices

struct CitationReaderSource {
    let citation: SourceCitation
    let course: ClassEnrollment?
    let timeZone: TimeZone
    let material: SourceMaterial?
    let revision: MaterialRevision?

    init(_ citation: SourceCitation, in state: ContextState) {
        self.citation = citation
        let course = state.classes.first { $0.id == citation.classID }
        self.course = course
        let zone = state.terms.first { $0.id == course?.termID }?.timeZoneID ?? AcademicTerm.defaultTimeZoneID
        timeZone = TimeZone(identifier: zone) ?? .current
        let material = state.materials.first {
            citation.sourceKind == "material" && $0.id == citation.sourceID && $0.classID == citation.classID
        }
        self.material = material
        revision = state.materialRevisions.first { $0.materialID == material?.id && $0.id == citation.revisionID }
    }

    var coursework: ImportedCourseworkContext? { material?.kind == "uci-canvas" ? revision?.courseworkContext : nil }
    var isWebLink: Bool { material?.kind == MaterialService.webLinkKind }
    var serviceName: String? { material?.kind == "uci-canvas" ? "Canvas" : revision?.importedSource?.provider }
    var serviceURL: URL? {
        guard let url = revision?.importedSource?.url, url.scheme?.lowercased() == "https" else { return nil }
        return try? MaterialService.validatedWebURL(url.absoluteString)
    }
    var kindLabel: String {
        if let coursework { return "Canvas " + coursework.kind }
        if let serviceName { return serviceName }
        if isWebLink { return "Web link" }
        switch citation.sourceKind {
        case "transcript": return "Lecture transcript"
        case "activity": return "Class history"
        default: return "Class material"
        }
    }
    var symbol: String {
        if coursework != nil { return "list.clipboard" }
        if isWebLink { return "link" }
        switch citation.sourceKind {
        case "transcript": return "waveform"
        case "activity": return "text.book.closed"
        default: return "doc.text"
        }
    }

    func instructions(in passage: ResolvedPassage) -> String? {
        guard citation.locator == .whole, citation.payloadSHA256 == revision?.text?.sha256,
              let coursework, let url = revision?.importedSource?.url else { return nil }
        return UciCanvasClient.courseworkInstructions(in: passage.text, facts: coursework, source: url)
    }
}

struct CitationReaderView: View {
    @ObservedObject var model: WorkspaceModel
    let citation: SourceCitation
    @Environment(\.dismiss) private var dismiss
    @State private var passage: ResolvedPassage?
    @State private var failure: String?
    @State private var showsDetails = false
    @State private var copiedLink = false
    @State private var actionError: String?

    private var title: String { passage?.title ?? (citation.label.isEmpty ? "Source" : citation.label) }
    private var isPinned: Bool {
        model.state.pinnedCitations.contains {
            $0.classID == citation.classID && $0.sourceKind == citation.sourceKind && $0.sourceID == citation.sourceID
                && $0.revisionID == citation.revisionID && $0.locator == citation.locator && $0.payloadSHA256 == citation.payloadSHA256
        }
    }
    private var hasNewerTranscript: Bool {
        guard citation.sourceKind == "transcript",
              let recording = model.state.recordings.first(where: { $0.id == citation.sourceID && $0.classID == citation.classID }),
              let current = recording.currentTranscriptRevisionID else { return false }
        return current != citation.revisionID
    }

    var body: some View {
        let source = CitationReaderSource(citation, in: model.state)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: source.symbol)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(WorkspacePalette.accent)
                    .frame(width: 48, height: 48)
                    .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text([source.course?.shortLabel, source.kindLabel].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.subheadline.weight(.medium)).foregroundStyle(WorkspacePalette.muted)
                    Text(title).font(.system(size: 26, weight: .semibold))
                        .tracking(-0.5).lineLimit(3).help(title).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 24).padding(.bottom, 18)

            ReaderViewport(maxHeight: showsDetails ? 235 : 350) {
                readerContent(source)
            }
            sourceDetails(source)
                .padding(.horizontal, 24).padding(.bottom, 18)
            if let actionError {
                Text(actionError).font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 12) {
                if source.revision != nil && (!source.isWebLink || passage != nil) {
                    primaryAction(source)
                    Spacer(minLength: 4)
                    copyButton.buttonStyle(.borderless)
                } else {
                    copyButton.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 8))
                    Spacer(minLength: 4)
                }
                MoreActionsMenu(title: "More source actions") {
                    if source.serviceURL != nil, !source.isWebLink, let revision = source.revision {
                        Button("Open original file", systemImage: "doc") { model.openOriginal(revision) }
                    }
                    Button(isPinned ? "Kept for backup" : "Keep for backup", systemImage: isPinned ? "pin.fill" : "pin") {
                        guard let repository = model.repository else { return }
                        do {
                            try RetrievalService(repository: repository).pin(citation)
                            model.refresh()
                            actionError = nil
                        } catch { actionError = error.localizedDescription }
                    }
                    .disabled(isPinned || passage == nil)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(WorkspacePalette.surface)
        }
        .foregroundStyle(WorkspacePalette.ink)
        .tint(WorkspacePalette.accent)
        .background(WorkspacePalette.canvas)
        .frame(minWidth: 490, idealWidth: 600, maxWidth: 660)
        .task(id: citation) {
            passage = nil
            failure = nil
            showsDetails = false
            copiedLink = false
            actionError = nil
            guard let repository = model.repository else { failure = "Open your library and try again."; return }
            do { passage = try RetrievalService(repository: repository).resolve(citation) }
            catch { failure = error.localizedDescription }
        }
        .task(id: copiedLink) {
            guard copiedLink else { return }
            do { try await Task.sleep(for: .seconds(3)); copiedLink = false } catch {}
        }
    }

    private func readerContent(_ source: CitationReaderSource) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasNewerTranscript {
                Label("A newer transcript is available. To update a saved entry, choose Correct in class history.", systemImage: "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(WorkspacePalette.muted)
            }
            if let failure {
                Label("Source unavailable", systemImage: "doc.badge.exclamationmark").font(.headline)
                Text(failure).textSelection(.enabled)
            } else if let passage {
                if let coursework = source.coursework {
                    CourseworkFacts(facts: coursework, timeZone: source.timeZone)
                }
                let instructions = source.instructions(in: passage)
                if instructions == "", !passage.isTruncated {
                    Text("Canvas included no instructions in this revision.")
                        .font(.callout).foregroundStyle(WorkspacePalette.muted)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if instructions != nil {
                            Text("Instructions").font(.headline).accessibilityAddTraits(.isHeader)
                        } else if citation.locator != .whole {
                            Text("Cited passage").font(.headline).accessibilityAddTraits(.isHeader)
                        }
                        Text(verbatim: instructions ?? passage.text)
                            .font(.body).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if passage.isTruncated {
                            Text("Showing the first \(passage.text.utf8.count.formatted()) of \(passage.totalUTF8Bytes.formatted()) bytes.")
                                .font(.caption).foregroundStyle(WorkspacePalette.muted)
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).workspacePanel()
                }
            } else {
                ProgressView("Opening source…").controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func sourceDetails(_ source: CitationReaderSource) -> some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            ReaderViewport(maxHeight: 135) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    if let revision = source.revision {
                        detail("Revision", "\(revision.sequence) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        if !revision.originalFilename.isEmpty { detail("File", revision.originalFilename) }
                    }
                    detail("Selection", selectionLabel)
                    if let url = source.serviceURL { detail("Address", url.absoluteString) }
                    GridRow {
                        Text("SHA-256").foregroundStyle(WorkspacePalette.muted)
                        Text(verbatim: citation.payloadSHA256).font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        } label: {
            HStack {
                Text("Source details").fontWeight(.medium)
                if isPinned { Label("Kept for backup", systemImage: "pin.fill").font(.caption) }
            }
            .font(.callout).foregroundStyle(WorkspacePalette.muted)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(WorkspacePalette.muted)
            Text(verbatim: value)
        }
    }

    private var selectionLabel: String {
        switch citation.locator {
        case .whole: return "Whole source"
        case let .page(page): return "Page \(page)"
        case let .section(title): return title
        case let .text(start, length): return "\(length) bytes at UTF-8 offset \(start)"
        case let .cues(start, end): return start == end ? "Transcript cue \(start)" : "Transcript cues \(start)–\(end)"
        }
    }

    private var copyButton: some View {
        Button(copiedLink ? "Link copied" : "Copy citation link", systemImage: copiedLink ? "checkmark" : "link") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            copiedLink = pasteboard.setString(CitationLink.url(for: citation).absoluteString, forType: .string)
            actionError = copiedLink ? nil : "Couldn’t copy the citation link."
        }
    }

    @ViewBuilder private func primaryAction(_ source: CitationReaderSource) -> some View {
        Group {
            if let revision = source.revision {
                if source.isWebLink {
                    if let passage { OpenWebsiteButton(model: model, revision: revision, title: passage.title) }
                } else if let url = source.serviceURL, let name = source.serviceName {
                    Link(destination: url) { Label("Open in \(name)", systemImage: "arrow.up.right") }
                } else {
                    Button("Open original file", systemImage: "doc") { model.openOriginal(revision) }
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 8))
    }
}

private struct ReaderViewport<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }.frame(height: maxHeight)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CourseworkFacts: View {
    let facts: ImportedCourseworkContext
    let timeZone: TimeZone

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Due date", systemImage: "calendar")
                    .font(.subheadline.weight(.medium)).foregroundStyle(WorkspacePalette.muted)
                if let due = facts.dueAt {
                    Text(due, format: Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day().year())
                        .font(.headline)
                    Text(due, format: Date.FormatStyle(timeZone: timeZone).hour().minute().timeZone(.specificName(.short)))
                        .font(.callout).foregroundStyle(WorkspacePalette.muted)
                } else {
                    Text("No due date listed").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Canvas submission").font(.subheadline.weight(.medium)).foregroundStyle(WorkspacePalette.muted)
                Label(facts.submissionState?.rawValue.capitalized ?? "Not reported", systemImage: statusSymbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(WorkspacePalette.ink)
                    .background(statusBackground, in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .workspacePanel()
    }

    private var statusBackground: Color {
        switch facts.submissionState {
        case .submitted, .graded: return WorkspacePalette.tintSurface
        case .missing: return Color.orange.opacity(0.16)
        default: return WorkspacePalette.line.opacity(0.4)
        }
    }

    private var statusSymbol: String {
        switch facts.submissionState {
        case .graded: return "checkmark.seal"
        case .submitted: return "checkmark.circle"
        case .unsubmitted: return "circle"
        case .missing: return "exclamationmark.circle"
        case .excused: return "minus.circle"
        case nil: return "questionmark.circle"
        }
    }
}
