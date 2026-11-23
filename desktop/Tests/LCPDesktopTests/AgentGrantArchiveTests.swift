import XCTest
import LCPContextCore
@testable import LCPDesktop

@MainActor
final class AgentGrantArchiveTests: XCTestCase {
    func testPickerIncludesUngroupedClassesAndRespectsClassAndTermArchiving() throws {
        let current = AcademicTerm(name: "Current")
        let past = AcademicTerm(name: "Past", archived: true)
        let active = ClassEnrollment(termID: current.id, title: "Astronomy")
        let archived = ClassEnrollment(termID: current.id, title: "Geology", archived: true)
        let pastClass = ClassEnrollment(termID: past.id, title: "Optics")
        let ungrouped = ClassEnrollment(title: "Geometry")
        let archivedUngrouped = ClassEnrollment(title: "Mechanics", archived: true)
        var state = ContextState()
        state.terms = [current, past]
        state.classes = [archivedUngrouped, pastClass, archived, ungrouped, active]

        let visible = state.visibleClassGroups(includingArchived: false)
        XCTAssertEqual(visible.map(\.id), [current.id, nil])
        XCTAssertEqual(visible.flatMap(\.classes), [active, ungrouped])
        let all = state.visibleClassGroups(includingArchived: true)
        XCTAssertEqual(all.map(\.id), [current.id, past.id, nil])
        XCTAssertEqual(all.flatMap(\.classes), [active, archived, pastClass, ungrouped, archivedUngrouped])

        var draft = LocalAgentGrantDraft()
        draft.classIDs = [archived.id, pastClass.id]
        XCTAssertThrowsError(try draft.create(in: &state, includingArchived: false))
        XCTAssertTrue(state.connections.isEmpty)
        XCTAssertTrue(state.grants.isEmpty)
        try draft.create(in: &state, includingArchived: true)
        XCTAssertEqual(Set(try XCTUnwrap(state.grants.first).allowedClassIDs), draft.classIDs)
    }

    func testArchiveBetweenSelectionAndSaveRejectsEntireNewGrant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let term = AcademicTerm(name: "Current")
        let selected = ClassEnrollment(termID: term.id, title: "Optics")
        let other = ClassEnrollment(title: "Algebra")
        let notes = SourceMaterial(classID: selected.id, title: "Fictional notes")
        var draft = LocalAgentGrantDraft()
        draft.classIDs = [selected.id, other.id]
        draft.scope.materialsOnly = true
        draft.scope.materialIDs = [notes.id]
        try repository.update { state in
            state.terms = [term]
            state.classes = [selected, other]
            state.materials = [notes]
            try draft.create(in: &state, includingArchived: false)
        }
        let existingGrants = repository.state.grants
        let existingConnections = repository.state.connections
        let writer = try ContextRepository(rootURL: root)
        try writer.update { $0.terms[0].archived = true }

        // The open editor still has the pre-archive snapshot.
        XCTAssertFalse(repository.state.terms[0].archived)
        XCTAssertThrowsError(try repository.update { try draft.create(in: &$0, includingArchived: false) })
        try repository.refresh()
        XCTAssertEqual(repository.state.revision, writer.state.revision)
        XCTAssertEqual(repository.state.grants, existingGrants)
        XCTAssertEqual(repository.state.connections, existingConnections)

        // Removing a hidden class cannot carry its documents into the remaining scope.
        draft.classIDs = [other.id]
        XCTAssertThrowsError(try repository.update { try draft.create(in: &$0, includingArchived: false) })
        draft.scope.materialIDs.removeAll()
        XCTAssertThrowsError(try repository.update { try draft.create(in: &$0, includingArchived: false) })
        draft.scope.materialsOnly = false
        try repository.update { try draft.create(in: &$0, includingArchived: false) }
        XCTAssertEqual(repository.state.grants.last?.allowedClassIDs, [other.id])
    }
}
