import Foundation
import XCTest
import LCPContextCore

/// Hostless native smoke test: exercises the packaged core without launching
/// the desktop, requesting microphone access, or opening the personal profile.
final class ReleaseSmokeTests: XCTestCase {
    func testNativeRepositoryCreatesAndReopensAnIsolatedProfile() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LCPDesktop-XcodeSmoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let termID = UUID()
            let expected: ContextState
            do {
                let first = try ContextRepository(rootURL: root)
                XCTAssertTrue(first.state.terms.isEmpty)
                try first.update { state in
                    state.terms.append(AcademicTerm(id: termID, name: "Fictional native smoke term"))
                }
                expected = first.state
            }
            let reopened = try ContextRepository(rootURL: root)
            XCTAssertEqual(reopened.state.terms.first?.id, termID)
            XCTAssertEqual(reopened.state, expected)
        }
    }
}
