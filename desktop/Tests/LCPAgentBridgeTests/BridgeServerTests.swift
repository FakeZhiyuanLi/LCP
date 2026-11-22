import XCTest
import Foundation
import LCPContextCore
import LCPContextServices
@testable import LCPAgentBridge

final class BridgeServerTests: XCTestCase {
    @MainActor
    func testSuccessfulReadRecordsSanitizedClientInfoAndVerification() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = server.handle(request(1, "initialize", [
            "clientInfo": .object(["name": .string("Codex\nDesktop"), "version": .string(" 0.171.0 ")])
        ]))
        XCTAssertNil(fixture.repository.state.connections.first?.clientVersion)
        XCTAssertNil(fixture.repository.state.connections.first?.verifiedAt)

        let response = server.handle(request(2, "tools/call", [
            "name": .string("list_classes"), "arguments": .object([:])
        ]))
        XCTAssertEqual(response?.object?["result"]?.object?["isError"], .bool(false))
        let connection = try XCTUnwrap(fixture.repository.state.connections.first)
        XCTAssertEqual(connection.clientVersion, "Codex Desktop 0.171.0")
        XCTAssertNotNil(connection.verifiedAt)
    }

    @MainActor
    func testReconnectUpdatesClientInfoAndDoesNotRewriteOnRepeatedReads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = first.handle(request(1, "initialize", [
            "clientInfo": .object(["name": .string("Codex"), "version": .string("1")])
        ]))
        _ = first.handle(request(2, "tools/call", ["name": .string("list_classes"), "arguments": .object([:])]))
        let firstVerified = try XCTUnwrap(fixture.repository.state.connections.first?.verifiedAt)
        let firstRevision = fixture.repository.state.revision
        _ = first.handle(request(3, "tools/call", ["name": .string("list_materials"), "arguments": .object([
            "class_id": .string(fixture.classID.uuidString)
        ])]))
        XCTAssertEqual(fixture.repository.state.revision, firstRevision)

        let second = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = second.handle(request(4, "initialize", [
            "clientInfo": .object(["name": .string("Claude Duet"), "version": .string("2")])
        ]))
        _ = second.handle(request(5, "resources/list"))
        let connection = try XCTUnwrap(fixture.repository.state.connections.first)
        XCTAssertEqual(connection.clientVersion, "Claude Duet 2")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(connection.verifiedAt), firstVerified)
        XCTAssertGreaterThan(fixture.repository.state.revision, firstRevision)
    }

    @MainActor
    func testMalformedClientInfoIsIgnoredButSuccessfulReadStillVerifies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        let huge = String(repeating: "x", count: 129)
        let response = server.handle(request(1, "initialize", [
            "clientInfo": .object(["name": .string(huge), "version": .bool(true), "unexpected": .string("ignored")])
        ]))
        XCTAssertEqual(response?.object?["result"]?.object?["protocolVersion"], .string("2024-11-05"))
        _ = server.handle(request(2, "tools/call", ["name": .string("list_classes"), "arguments": .object([:])]))
        let connection = try XCTUnwrap(fixture.repository.state.connections.first)
        XCTAssertNil(connection.clientVersion)
        XCTAssertNotNil(connection.verifiedAt)
        let audit = try String(contentsOf: fixture.root.appendingPathComponent("agent-access.json"), encoding: .utf8)
        XCTAssertFalse(audit.contains(huge))
    }

    @MainActor
    func testRevokedGrantCannotRecordInteroperability() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = server.handle(request(1, "initialize", [
            "clientInfo": .object(["name": .string("Codex"), "version": .string("1")])
        ]))
        let desktop = try ContextRepository(rootURL: fixture.repository.rootURL)
        try desktop.update { state in
            let index = try XCTUnwrap(state.grants.firstIndex(where: { $0.id == fixture.grant.id }))
            state.grants[index].revokedAt = Date()
        }
        let response = server.handle(request(2, "tools/call", ["name": .string("list_classes"), "arguments": .object([:])]))
        XCTAssertEqual(response?.object?["result"]?.object?["isError"], .bool(true))
        let connection = try XCTUnwrap(fixture.repository.state.connections.first)
        XCTAssertNil(connection.clientVersion)
        XCTAssertNil(connection.verifiedAt)
    }

    @MainActor
    func testScopedLiveRetrievalExactCitationAndRevocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = server.handle(request(1, "initialize", ["protocolVersion": .string("2024-11-05")]))
        XCTAssertNil(server.handle(.object(["jsonrpc":.string("2.0"),"method":.string("notifications/initialized")])))

        let classes = try resultText(server.handle(request(2,"tools/call",[
            "name":.string("list_classes"),"arguments":.object([:])
        ])))
        let visibleClasses = try XCTUnwrap(classes.object?["classes"]?.array)
        XCTAssertEqual(visibleClasses.count,1)
        XCTAssertEqual(visibleClasses.first?.object?["id"]?.string?.lowercased(),fixture.classID.uuidString.lowercased())

        let search = try resultText(server.handle(request(3,"tools/call",[
            "name":.string("search_class_context"),
            "arguments":.object(["class_ids":.array([.string(fixture.classID.uuidString)]),"query":.string("amortized")])
        ])))
        let hit = try XCTUnwrap(search.object?["results"]?.array?.first?.object)
        let citationURL = try XCTUnwrap(hit["citation_url"]?.string)
        let passage = try resultText(server.handle(request(4,"tools/call",[
            "name":.string("resolve_citation"),"arguments":.object(["citation_url":.string(citationURL)])
        ])))
        XCTAssertTrue(passage.object?["text"]?.string?.contains("amortized") == true)
        XCTAssertEqual(passage.object?["citation_url"]?.string,citationURL)

        let crossClass = server.handle(request(5,"tools/call",[
            "name":.string("search_class_context"),
            "arguments":.object(["class_ids":.array([.string(fixture.otherClassID.uuidString)]),"query":.string("private")])
        ]))
        XCTAssertEqual(crossClass?.object?["result"]?.object?["isError"],.bool(true))
        XCTAssertFalse(String(describing:crossClass).contains("SECRET UNRELATED SOURCE"))

        // Simulate revocation in the independently running desktop process.
        let desktop = try ContextRepository(rootURL: fixture.repository.rootURL)
        try desktop.update { state in
            let index = try XCTUnwrap(state.grants.firstIndex(where:{$0.id == fixture.grant.id}))
            state.grants[index].revokedAt = Date()
        }
        let revoked = server.handle(request(6,"tools/call",[
            "name":.string("list_classes"),"arguments":.object([:])
        ]))
        XCTAssertEqual(revoked?.object?["result"]?.object?["isError"],.bool(true))
        let audit = try String(contentsOf: fixture.root.appendingPathComponent("agent-access.json"), encoding: .utf8)
        XCTAssertFalse(audit.contains("amortized"))
        XCTAssertFalse(audit.contains("Dynamic arrays"))
    }

    @MainActor
    func testMCPResourcesExposeOnlyGrantedClassMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.repository.update { state in
            let index = try XCTUnwrap(state.classes.firstIndex { $0.id == fixture.classID })
            state.classes[index].courseCode = ""
            state.classes[index].termID = nil
            state.classes[index].recordingDestination = RecordingDestination(driveFolderID: "synthetic-capture", exactCourseCode: "Algorithms")
            var folder = ClassDriveFolder(for: state.classes[index])
            folder.folderID = "synthetic-materials"
            state.classes[index].driveFolder = folder
        }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        let initialized = server.handle(request(1, "initialize", ["protocolVersion": .string("2025-06-18")]))
        XCTAssertEqual(initialized?.object?["result"]?.object?["capabilities"]?.object?["resources"]?.object?["listChanged"], .bool(false))

        let listing = try XCTUnwrap(server.handle(request(2, "resources/list"))?.object?["result"]?.object?["resources"]?.array)
        XCTAssertEqual(listing.count, 1)
        let resource = try XCTUnwrap(listing.first?.object)
        XCTAssertEqual(resource["name"], .string("Algorithms context"))
        let uri = try XCTUnwrap(resource["uri"]?.string)
        XCTAssertTrue(uri.hasPrefix("lcp://class/"))
        XCTAssertEqual(resource["mimeType"], .string("application/json"))

        let read = server.handle(request(3, "resources/read", ["uri": .string(uri)]))
        let contents = try XCTUnwrap(read?.object?["result"]?.object?["contents"]?.array?.first?.object)
        XCTAssertEqual(contents["uri"]?.string, uri)
        XCTAssertEqual(contents["mimeType"], .string("application/json"))
        let payload = try XCTUnwrap(contents["text"]?.string)
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        XCTAssertEqual(metadata.object?["class"]?.object?["id"]?.string?.lowercased(), fixture.classID.uuidString.lowercased())
        let classes = try resultText(server.handle(request(30, "tools/call", ["name": .string("list_classes")])))
        let listed = try XCTUnwrap(classes.object?["classes"]?.array?.first)
        XCTAssertEqual(listed, metadata.object?["class"])
        XCTAssertNil(listed.object?["driveFolder"])
        XCTAssertNil(listed.object?["recordingDestination"])
        XCTAssertEqual(metadata.object?["materials"]?.array?.count, 1)
        XCTAssertTrue(payload.contains("Material metadata only"))

        let blocked = server.handle(request(4, "resources/read", ["uri": .string("lcp://class/\(fixture.otherClassID.uuidString)/context")]))
        XCTAssertEqual(blocked?.object?["error"]?.object?["code"], .number(-32602))
    }

    @MainActor
    func testProposalToolRequiresCapabilityAndNeverAccepts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository:fixture.repository,grantID:fixture.grant.id)
        _ = server.handle(request(1,"initialize"))
        let draftArgs: [String:JSONValue] = ["class_id":.string(fixture.classID.uuidString),"title":.string("Study outcome"),
                                           "body":.string("We reviewed amortized resizing."),"idempotency_key":.string("test-one")]
        let rejected = server.handle(request(2,"tools/call",["name":.string("propose_study_log"),"arguments":.object(draftArgs)]))
        XCTAssertEqual(rejected?.object?["result"]?.object?["isError"],.bool(true))
        XCTAssertTrue(fixture.repository.state.proposals.isEmpty)
        try fixture.repository.update { state in
            let index = try XCTUnwrap(state.connections.firstIndex(where:{$0.id == fixture.connection.id}))
            state.connections[index].capabilities.append("propose_study_log")
        }
        _ = try resultText(server.handle(request(30,"tools/call",[
            "name":.string("search_class_context"),"arguments":.object([
                "class_ids":.array([.string(fixture.classID.uuidString)]),"query":.string("amortized")
            ])
        ])))
        let draft = try resultText(server.handle(request(3,"tools/call",[
            "name":.string("propose_study_log"),"arguments":.object(draftArgs)
        ])))
        XCTAssertEqual(draft.object?["review_required"],.bool(true))
        XCTAssertEqual(draft.object?["class_history_changed"],.bool(false))
        XCTAssertEqual(draft.object?["proposal"]?.object?["contextManifest"]?.array?.count,1)
        XCTAssertEqual(fixture.repository.state.proposals.count,1)
        XCTAssertTrue(fixture.repository.state.activities.isEmpty)
        _ = server.handle(request(4,"tools/call",["name":.string("propose_study_log"),"arguments":.object(draftArgs)]))
        XCTAssertEqual(fixture.repository.state.proposals.count,1)
        let forbidden = server.handle(request(5,"tools/call",["name":.string("accept_proposal"),"arguments":.object([:])]))
        XCTAssertEqual(forbidden?.object?["result"]?.object?["isError"],.bool(true))
        XCTAssertTrue(fixture.repository.state.activities.isEmpty)
    }

    @MainActor
    func testMalformedRequestsDoNotExecuteAndToolArgumentsAreBounded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository:fixture.repository,grantID:fixture.grant.id)
        XCTAssertNotNil(server.handle(.array([]))?.object?["error"])
        XCTAssertNotNil(server.handle(request(1,"tools/list"))?.object?["error"])
        _ = server.handle(request(2,"initialize"))
        let limit = server.handle(request(3,"tools/call",[
            "name":.string("search_class_context"),"arguments":.object([
                "class_ids":.array([.string(fixture.classID.uuidString)]),"query":.string("x"),"limit":.number(5000)
            ])
        ]))
        XCTAssertEqual(limit?.object?["result"]?.object?["isError"],.bool(true))
        let pathInjection = server.handle(request(4,"tools/call",[
            "name":.string("build_context_bundle"),"arguments":.object([
                "class_ids":.array([.string(fixture.classID.uuidString)]),"destination":.string("/tmp/overwrite")
            ])
        ]))
        XCTAssertEqual(pathInjection?.object?["result"]?.object?["isError"],.bool(true))
    }

    @MainActor
    func testMaterialAndInstantFiltersAreBoundedAndScoped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = server.handle(request(1, "initialize"))
        let material = try XCTUnwrap(fixture.repository.state.materials.first(where: { $0.classID == fixture.classID }))
        let unrelated = try XCTUnwrap(fixture.repository.state.materials.first(where: { $0.classID == fixture.otherClassID }))
        let revision = fixture.repository.state.revision
        var arguments: [String: JSONValue] = ["class_ids": .array([.string(fixture.classID.uuidString)]), "query": .string("amortized"),
                                              "material_ids": .array([.string(material.id.uuidString)]),
                                              "event_from": .string("2000-01-01T00:00:00.000-08:00"), "event_until": .string("2099-01-01T00:00:00Z")]
        func search(_ args: [String: JSONValue], id: Int) -> JSONValue? {
            server.handle(request(id, "tools/call", ["name": .string("search_class_context"), "arguments": .object(args)]))
        }
        let allowed = try resultText(search(arguments, id: 2))
        XCTAssertEqual(allowed.object?["total"], .number(1))
        XCTAssertNotNil(allowed.object?["time_filter_semantics"])
        arguments["event_from"] = .string("2098-01-01T00:00:00Z")
        XCTAssertEqual(try resultText(search(arguments, id: 3)).object?["total"], .number(0))
        arguments["event_from"] = .string("2026-11-19")
        XCTAssertEqual(search(arguments, id: 4)?.object?["result"]?.object?["isError"], .bool(true))
        arguments["event_from"] = .string("2099-02-01T00:00:00Z")
        XCTAssertEqual(search(arguments, id: 5)?.object?["result"]?.object?["isError"], .bool(true))
        arguments.removeValue(forKey: "event_from")
        arguments["material_ids"] = .array([.string(unrelated.id.uuidString)])
        XCTAssertEqual(search(arguments, id: 6)?.object?["result"]?.object?["isError"], .bool(true))
        arguments["material_ids"] = .array(Array(repeating: .string(material.id.uuidString), count: 129))
        XCTAssertEqual(search(arguments, id: 7)?.object?["result"]?.object?["isError"], .bool(true))
        arguments["material_ids"] = .array([.string(material.id.uuidString), .string(material.id.uuidString)])
        XCTAssertEqual(search(arguments, id: 8)?.object?["result"]?.object?["isError"], .bool(true))
        XCTAssertGreaterThan(fixture.repository.state.revision, revision)
    }

    @MainActor
    func testRunningStdioProcessObservesDesktopRevocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let binary = Bundle(for: BridgeServerTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("LCPAgentBridge")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Bridge executable is unavailable beside the test bundle.") }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--root", fixture.repository.rootURL.path, "--grant", fixture.grant.id.uuidString]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 20)
        watchdog.setEventHandler { if process.isRunning { process.terminate() } }
        watchdog.resume()
        defer {
            watchdog.cancel()
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        func exchange(_ message: JSONValue) throws -> JSONValue {
            var bytes = try JSONEncoder().encode(message); bytes.append(10)
            try stdin.fileHandleForWriting.write(contentsOf: bytes)
            var line = Data()
            while line.count <= 2_097_152 {
                guard let next = try stdout.fileHandleForReading.read(upToCount: 1), !next.isEmpty else {
                    throw BridgeFailure("Bridge process closed before responding.")
                }
                if next[0] == 10 { return try JSONDecoder().decode(JSONValue.self, from: line) }
                line.append(next)
            }
            throw BridgeFailure("Bridge response exceeded its bound.")
        }
        _ = try exchange(request(1, "initialize"))
        let before = try exchange(request(2, "tools/call", ["name": .string("list_classes"), "arguments": .object([:])]))
        XCTAssertEqual(before.object?["result"]?.object?["isError"], .bool(false))
        // The bridge is a different OS process and retains its SwiftData container.
        try fixture.repository.update { state in
            let i = try XCTUnwrap(state.grants.firstIndex(where: { $0.id == fixture.grant.id }))
            state.grants[i].revokedAt = Date()
        }
        let after = try exchange(request(3, "tools/call", ["name": .string("list_classes"), "arguments": .object([:])]))
        XCTAssertEqual(after.object?["result"]?.object?["isError"], .bool(true))
    }

    /// Deliberate opt-in fixture for an actual compatible agent, never paid work
    /// during ordinary unit tests. All content below is fictional.
    @MainActor
    func testExportFictionalInteropFixtureWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LCP_AGENT_INTEROP_FIXTURE"] else {
            throw XCTSkip("Set LCP_AGENT_INTEROP_FIXTURE to deliberately create a fictional interoperability profile.")
        }
        guard path.hasPrefix("/tmp/LCPAgentInterop-") || path.hasPrefix(FileManager.default.temporaryDirectory.path + "LCPAgentInterop-") else {
            throw BridgeFailure("Use a new temporary LCPAgentInterop- fixture path.")
        }
        let fixture = try Fixture(rootOverride: URL(fileURLWithPath: path, isDirectory: true))
        let cues = [TranscriptCue(start: 12.5, end: 24.0, text: "Using geometric growth, the total copying work over n appends is O(n), giving amortized O(1) append.", speaker: "Speaker 1")]
        var recording = LectureRecording(classID: fixture.classID, filename: "TEST 101_2026-11-19_0900.m4a", sizeBytes: 1234,
                                         sha256: String(repeating: "a", count: 64), acceptedJobID: "synthetic-job-interop",
                                         status: LectureStatusFacts(serverReceived: "received", processing: "complete", quality: "eligible", transcriptAvailable: "available"))
        let content: [String: JSONValue] = ["schema_version": .number(1), "filename": .string(recording.filename),
                                            "size_bytes": .number(Double(recording.sizeBytes)), "sha256": .string(recording.sha256),
                                            "accepted_job_id": .string("synthetic-job-interop"), "cues": try JSONValue.encoded(cues)]
        let payload = try fixture.repository.storePayload(JSONEncoder().encode(JSONValue.object(content)), mediaType: "application/vnd.lcp.transcript+json")
        let transcript = TranscriptRevision(recordingID: recording.id, acceptedJobID: "synthetic-job-interop", content: payload, cues: cues, duration: 30)
        recording.currentTranscriptRevisionID = transcript.id
        let committedRecording = recording
        try fixture.repository.update { state in state.recordings.append(committedRecording); state.transcriptRevisions.append(transcript) }
        let selected = try RetrievalService(repository: fixture.repository).search(ContextQuery(classIDs: [fixture.classID], text: "amortized"), grantID: fixture.grant.id)
        XCTAssertEqual(Set(selected.results.map(\.sourceKind)), Set(["material", "transcript"]))
        let manifest: JSONValue = .object(["schema_version": .number(1), "fictional": .bool(true), "root": .string(path),
                                          "class_id": .string(fixture.classID.uuidString), "other_class_id": .string(fixture.otherClassID.uuidString),
                                          "grant_id": .string(fixture.grant.id.uuidString), "question": .string("Why is a dynamic array append amortized O(1)? Cite both the course material and lecture cue.")])
        try JSONEncoder().encode(manifest).write(to: fixture.root.appendingPathComponent("interop-manifest.json"), options: .atomic)
    }

    @MainActor
    func testPersistentTimeAndMaterialScopeControlsMetadataCitationsAndBundles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let insideFile = fixture.root.appendingPathComponent("inside-scope.txt")
        try Data("inside scoped evidence".utf8).write(to: insideFile)
        let inside = try MaterialService(repository: fixture.repository).importMaterial(from: insideFile, classID: fixture.classID)
        try fixture.repository.update { state in
            for i in state.materials.indices { state.materials[i].createdAt = Date(timeIntervalSince1970: state.materials[i].id == inside.id ? 300 : 100) }
        }
        let outside = try XCTUnwrap(RetrievalService(repository: fixture.repository).search(ContextQuery(classIDs: [fixture.classID], text: "amortized")).results.first?.citation)
        try fixture.repository.update { state in
            state.grants[0].eventFrom = Date(timeIntervalSince1970: 200)
            state.grants[0].eventUntil = Date(timeIntervalSince1970: 400)
            state.grants[0].allowedMaterialIDs = [inside.id]
        }
        let server = BridgeServer(repository: fixture.repository, grantID: fixture.grant.id)
        _ = server.handle(request(1, "initialize"))
        let listed = try resultText(server.handle(request(2, "tools/call", ["name": .string("list_materials"), "arguments": .object(["class_id": .string(fixture.classID.uuidString)])])))
        XCTAssertEqual(listed.object?["total"], .number(1))
        XCTAssertEqual(listed.object?["materials"]?.array?.first?.object?["id"]?.string?.lowercased(), inside.id.uuidString.lowercased())
        let blocked = server.handle(request(3, "tools/call", ["name": .string("resolve_citation"), "arguments": .object(["citation_url": .string(CitationLink.url(for: outside).absoluteString)])]))
        XCTAssertEqual(blocked?.object?["result"]?.object?["isError"], .bool(true))
        let bundle = try resultText(server.handle(request(4, "tools/call", ["name": .string("build_context_bundle"), "arguments": .object([
            "class_ids": .array([.string(fixture.classID.uuidString)]), "material_ids": .array([.string(inside.id.uuidString)]),
            "event_from": .string("1970-01-01T00:04:10Z"), "event_until": .string("1970-01-01T00:05:50Z")
        ])])))
        let sources = try XCTUnwrap(bundle.object?["manifest"]?.object?["sources"]?.array)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.object?["citation"]?.object?["sourceID"]?.string?.lowercased(), inside.id.uuidString.lowercased())
        XCTAssertFalse(String(describing: bundle).contains("amortized"))
        // Revoking write capabilities takes effect without killing read access.
        try fixture.repository.update { $0.connections[0].capabilities = ["read_context"] }
        let draft = server.handle(request(5, "tools/call", ["name": .string("propose_note"), "arguments": .object([
            "class_id": .string(fixture.classID.uuidString), "title": .string("Blocked"), "body": .string("draft"), "idempotency_key": .string("disabled")
        ])]))
        XCTAssertEqual(draft?.object?["result"]?.object?["isError"], .bool(true))
        let stillReadable = try resultText(server.handle(request(6, "tools/call", ["name": .string("list_materials"), "arguments": .object(["class_id": .string(fixture.classID.uuidString)])])))
        XCTAssertEqual(stillReadable.object?["total"], .number(1))
    }

    private func request(_ id:Int,_ method:String,_ params:[String:JSONValue]=[:])->JSONValue {
        .object(["jsonrpc":.string("2.0"),"id":.number(Double(id)),"method":.string(method),"params":.object(params)])
    }
    private func resultText(_ response:JSONValue?) throws -> JSONValue {
        let result = try XCTUnwrap(response?.object?["result"]?.object)
        XCTAssertEqual(result["isError"],.bool(false),String(describing:result))
        let text = try XCTUnwrap(result["content"]?.array?.first?.object?["text"]?.string)
        return try JSONDecoder().decode(JSONValue.self,from:Data(text.utf8))
    }

    @MainActor
    private struct Fixture {
        let root:URL
        let repository:ContextRepository
        let classID:UUID
        let otherClassID:UUID
        let connection:AgentConnection
        let grant:AgentGrant
        init(rootOverride: URL? = nil) throws {
            root = rootOverride ?? FileManager.default.temporaryDirectory.appendingPathComponent("LCPBridgeTest-"+UUID().uuidString)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw BridgeFailure("Fixture destination already exists.") }
            repository = try ContextRepository(rootURL:root)
            let term = AcademicTerm(name:"Fictional autumn")
            let enrollment = ClassEnrollment(termID:term.id,courseCode:"TEST 101",title:"Algorithms")
            let other = ClassEnrollment(termID:term.id,courseCode:"TEST 202",title:"Unrelated")
            classID = enrollment.id
            otherClassID = other.id
            connection = AgentConnection(name:"Fictional MCP Client",mode:"stdio",capabilities:["read_context"])
            grant = AgentGrant(connectionID:connection.id,allowedClassIDs:[enrollment.id])
            let localConnection=connection,localGrant=grant
            try repository.update { state in
                state.terms=[term];state.classes=[enrollment,other]
                state.connections=[localConnection];state.grants=[localGrant]
            }
            let selected = root.appendingPathComponent("selected.md")
            try "Dynamic arrays use amortized O(1) append by doubling capacity.".write(to:selected,atomically:true,encoding:.utf8)
            let unrelated = root.appendingPathComponent("other.md")
            try "SECRET UNRELATED SOURCE is not selected.".write(to:unrelated,atomically:true,encoding:.utf8)
            _ = try MaterialService(repository:repository).importMaterial(from:selected,classID:classID)
            _ = try MaterialService(repository:repository).importMaterial(from:unrelated,classID:otherClassID)
        }
        func remove() { try? FileManager.default.removeItem(at:root) }
    }
}
