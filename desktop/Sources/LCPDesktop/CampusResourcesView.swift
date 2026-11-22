import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LCPContextCore
import LCPContextServices

struct CampusResourcesView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    private enum Resource: String, CaseIterable {
        case gradescope = "Gradescope"
        case registrar = "UCI Registrar"
        case piazza = "Piazza"
        case zoom = "UCI Zoom"
    }
    @State private var resource = Resource.gradescope

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Campus resource", selection: $resource) {
                ForEach(Resource.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.menu)
            if resource == .registrar {
                RegistrarImportView(model: model, classID: classID)
            } else if resource == .gradescope {
                GradescopeImportView(model: model, classID: classID)
            } else if resource == .piazza {
                CampusLinkImportView(model: model, classID: classID, kind: .piazza)
            } else {
                CampusLinkImportView(model: model, classID: classID, kind: .zoom)
            }
        }
        .id(classID)
    }
}

private struct CampusLinkImportView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    let kind: UciCampusLink.Kind
    @State private var title = ""
    @State private var address = ""
    @State private var feedback: String?

    private var reference: UciCampusLink? { try? UciCampusLink(kind: kind, address: address) }
    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save a class link for \(kind.label). LCP keeps the address with this class for offline reference.")
            HStack {
                Link("Open \(kind.label)", destination: kind.helpURL)
            }
            TextField("Title", text: $title).accessibilityLabel("\(kind.label) title")
            TextField("\(kind.label) class or meeting URL", text: $address)
                .accessibilityLabel("\(kind.label) URL")
            if !address.isEmpty && reference == nil {
                Text("Use a HTTPS \(kind.label) class or meeting address.").font(.caption)
            }
            Button("Save \(kind.label) Link") { saveLink() }
                .disabled(reference == nil || name.isEmpty)
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
        }
        .onChange(of: address) { _, _ in feedback = nil }
        .onChange(of: title) { _, _ in feedback = nil }
    }

    private func saveLink() {
        guard let reference, let repo = model.repository else { return }
        do {
            try repo.refresh()
            let service = MaterialService(repository: repo)
            for material in repo.state.materials where material.classID == classID && material.kind == MaterialService.webLinkKind && material.title == name {
                if let revision = repo.state.materialRevisions.first(where: { $0.id == material.currentRevisionID }),
                   try service.webURL(for: revision) == reference.url {
                    feedback = "This \(kind.label) link is already in the class materials."
                    return
                }
            }
            _ = try service.addWebLink(classID: classID, title: name, urlString: reference.url.absoluteString)
            model.refresh()
            feedback = "Saved \(name) to class materials."
        } catch { feedback = error.localizedDescription }
    }
}

private struct GradescopeImportView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @State private var title = ""
    @State private var address = ""
    @State private var feedback: String?
    private var reference: GradescopeResource? { try? GradescopeResource(address: address) }
    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Gradescope from your Canvas assignment or course navigation. Paste the Gradescope address here to keep it with this class.")
            HStack {
                Link("Open UCI Canvas", destination: URL(string: "https://canvas.eee.uci.edu/")!)
                Link("Open Gradescope", destination: URL(string: "https://www.gradescope.com/")!)
            }
            TextField("Title", text: $title).accessibilityLabel("Gradescope title")
            TextField("Gradescope course, assignment, or submission URL", text: $address).accessibilityLabel("Gradescope URL")
            if !address.isEmpty && reference == nil {
                Text("Use a Gradescope address from a course, assignment, or submission page.").font(.caption)
            }
            Button("Save Gradescope Link") { saveLink() }
                .disabled(reference == nil || name.isEmpty)
            Divider()
            Text("For graded work, choose Download Submission in Gradescope, then import the PDF with its assignment or submission address.")
            Button("Import Graded PDF…") { importPDF() }
                .disabled(reference?.isAssignment != true || name.isEmpty)
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
        }
        .onChange(of: address) { _, _ in feedback = nil }
        .onChange(of: title) { _, _ in feedback = nil }
    }

    private func saveLink() {
        guard let reference, let repo = model.repository else { return }
        do {
            try repo.refresh()
            let service = MaterialService(repository: repo)
            for material in repo.state.materials where material.classID == classID && material.kind == MaterialService.webLinkKind && material.title == name {
                if let revision = repo.state.materialRevisions.first(where: { $0.id == material.currentRevisionID }),
                   try service.webURL(for: revision) == reference.url {
                    feedback = "This Gradescope link is already in the class materials."
                    return
                }
            }
            _ = try service.addWebLink(classID: classID, title: name, urlString: reference.url.absoluteString)
            model.refresh()
            feedback = "Saved \(name) to class materials."
        } catch { feedback = error.localizedDescription }
    }

    private func importPDF() {
        guard let reference, let repo = model.repository else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Downloaded Gradescope PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let doc = try reference.gradedPDF(at: file)
            let stored = try MaterialService(repository: repo).importUniversityDocument(doc, classID: classID,
                provider: "gradescope", remoteID: reference.url.path, title: name)
            model.refresh()
            feedback = "Imported \(stored.title). Open the saved PDF in Materials."
        } catch { feedback = error.localizedDescription }
    }
}

private struct RegistrarImportView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var term = UciTerm.fall
    @State private var department = ""
    @State private var course = ""
    @State private var result: UniversityDocument?
    @State private var resultQuery: UciRegistrarQuery?
    @State private var lookup: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var feedback: String?
    private var query: UciRegistrarQuery? {
        try? UciRegistrarQuery(department: department, courseNumber: course, year: year, term: term)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Stepper("Year \(String(year))", value: $year, in: 1900...2100)
                Picker("Term", selection: $term) {
                    ForEach(UciTerm.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }.frame(maxWidth: 300)
            }
            HStack {
                TextField("Department (e.g. I&C SCI)", text: $department).accessibilityLabel("UCI department")
                TextField("Course number", text: $course)
                    .accessibilityLabel("UCI course number")
            }
            HStack {
                Button("Find Sections") { findSections() }.disabled(query == nil || lookup != nil)
                if let query { Link("Open WebSOC", destination: query.url()) }
                Link("UCI Course Catalogue", destination: URL(string: "https://catalogue.uci.edu/allcourses/")!)
                if lookup != nil { ProgressView().controlSize(.small) }
            }
            if let result, let resultQuery, resultQuery == query {
                Text(resultQuery.title).font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(String(decoding: result.data, as: UTF8.self))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(6)
                }.frame(height: 160).background(.quaternary.opacity(0.3))
                Button("Import Schedule") { save(result, for: resultQuery) }
            }
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
        }
        .onAppear { prefill() }
        .onDisappear { reset() }
        .onChange(of: query) { _, _ in reset() }
    }

    private func prefill() {
        guard department.isEmpty, course.isEmpty,
              let enrollment = model.state.classes.first(where: { $0.id == classID }) else { return }
        let parts = enrollment.courseCode.split(whereSeparator: \.isWhitespace)
        if parts.count >= 2 {
            department = parts.dropLast().joined(separator: " ")
            course = String(parts.last!)
        }
        if let termName = model.state.terms.first(where: { $0.id == enrollment.termID })?.name {
            let words = termName.components(separatedBy: CharacterSet.alphanumerics.inverted)
            if let yearValue = words.compactMap(Int.init).first(where: { (1900...2100).contains($0) }) { year = yearValue }
            if let exact = UciTerm.allCases.sorted(by: { $0.label.count > $1.label.count }).first(where: {
                termName.localizedCaseInsensitiveContains($0.label)
            }) { term = exact }
        }
    }

    private func reset() {
        requestID = nil
        lookup?.cancel()
        lookup = nil
        result = nil
        resultQuery = nil
        feedback = nil
    }

    private func findSections() {
        guard let query else { return }
        reset()
        let id = UUID()
        requestID = id
        lookup = Task { @MainActor in
            do {
                let doc = try await query.load()
                guard !Task.isCancelled, requestID == id else { return }
                result = doc
                resultQuery = query
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                feedback = error.localizedDescription
            }
            lookup = nil
        }
    }

    private func save(_ doc: UniversityDocument, for selected: UciRegistrarQuery) {
        guard selected == query, let repo = model.repository else { return }
        do {
            let stored = try MaterialService(repository: repo).importUniversityDocument(doc, classID: classID,
                provider: "uci-registrar", remoteID: selected.remoteID, title: selected.title)
            model.refresh()
            feedback = "Imported \(stored.title) to class materials."
        } catch { feedback = error.localizedDescription }
    }
}
