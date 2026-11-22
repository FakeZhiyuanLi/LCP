import XCTest
import Foundation
import LCPContextCore
@testable import LCPContextServices

final class ProposalServiceTests: XCTestCase {
    @MainActor
    func testReviewPinsCitationAndRetriesDoNotDuplicateHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ProposalService(repository:fixture.repository)
        let citation = try XCTUnwrap(RetrievalService(repository:fixture.repository).search(
            ContextQuery(classIDs:[fixture.classID],text:"hashing")).results.first?.citation)
        let proposal = try service.propose(classID:fixture.classID,agentIdentity:"User-selected agent",title:"Hash table study",
                                           body:"Reviewed expected O(1) lookup.",idempotencyKey:"study-one",citations:[citation])
        XCTAssertTrue(fixture.repository.state.activities.isEmpty)
        let entry = try service.accept(proposal.id)
        XCTAssertEqual(entry.agentIdentity,"User-selected agent")
        XCTAssertEqual(entry.kind,"agent_study_log")
        XCTAssertEqual(entry.citations.first?.revisionID,citation.revisionID)
        XCTAssertTrue(fixture.repository.state.pinnedPayloads.contains(where:{$0.sha256 == citation.payloadSHA256}))
        let retry = try service.propose(classID:fixture.classID,agentIdentity:"User-selected agent",title:"Hash table study",
                                        body:"Reviewed expected O(1) lookup.",idempotencyKey:"study-one",citations:[citation])
        XCTAssertEqual(retry.id,proposal.id)
        XCTAssertEqual(try service.accept(proposal.id).id,entry.id)
        XCTAssertEqual(fixture.repository.state.activities.count,1)
        XCTAssertThrowsError(try service.propose(classID:fixture.classID,agentIdentity:"User-selected agent",title:"Different",
                                                body:"Different",idempotencyKey:"study-one")) {
            XCTAssertEqual($0 as? ProposalError,.idempotencyConflict)
        }
    }

    @MainActor
    func testRejectAndStaleCorrectionLeaveAuthoritativeHistoryUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ProposalService(repository:fixture.repository)
        let rejected = try service.propose(classID:fixture.classID,agentIdentity:"Agent",title:"Rejected",body:"Draft",idempotencyKey:"reject")
        try service.reject(rejected.id)
        try service.reject(rejected.id)
        XCTAssertTrue(fixture.repository.state.activities.isEmpty)
        XCTAssertThrowsError(try service.accept(rejected.id))

        let original = ActivityEntry(classID:fixture.classID,title:"Original",body:"Version one")
        try fixture.repository.update { $0.activities.append(original) }
        let correction = try service.propose(classID:fixture.classID,agentIdentity:"Agent",title:"Proposed correction",body:"Proposed body",
                                             targetID:original.id,expectedVersion:1,idempotencyKey:"correction")
        try fixture.repository.update { state in
            let i = try XCTUnwrap(state.activities.firstIndex(where:{$0.id == original.id}))
            state.activities[i].body="Student changed the note"
        }
        let before = fixture.repository.state.activities
        XCTAssertThrowsError(try service.accept(correction.id)) { XCTAssertEqual($0 as? ProposalError,.staleTarget) }
        XCTAssertEqual(fixture.repository.state.activities,before)
        XCTAssertEqual(fixture.repository.state.proposals.first(where:{$0.id == correction.id})?.state,"pending")
    }

    @MainActor
    func testGrantedProposalsUseConnectionIdentityAndRespectRevocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ProposalService(repository:fixture.repository)
        let connection = AgentConnection(name:"Approved Agent",mode:"stdio",capabilities:["read_context","propose_note"])
        let grant = AgentGrant(connectionID:connection.id,allowedClassIDs:[fixture.classID])
        try fixture.repository.update { state in state.connections.append(connection);state.grants.append(grant) }
        let draft = try service.propose(classID:fixture.classID,agentIdentity:"Impersonated Agent",title:"Draft",body:"Body",kind:.note,
                                        idempotencyKey:"scope",grantID:grant.id)
        XCTAssertEqual(draft.agentIdentity,"Approved Agent")
        XCTAssertThrowsError(try service.propose(classID:fixture.otherClassID,agentIdentity:"Approved Agent",title:"Other",body:"Body",kind:.note,
                                                idempotencyKey:"other",grantID:grant.id)) {
            XCTAssertEqual($0 as? ProposalError,.accessDenied)
        }
        XCTAssertThrowsError(try service.propose(classID:fixture.classID,agentIdentity:"Approved Agent",title:"Study",body:"Body",
                                                idempotencyKey:"study",grantID:grant.id)) {
            XCTAssertEqual($0 as? ProposalError,.accessDenied)
        }
        try fixture.repository.update { state in
            let i = try XCTUnwrap(state.grants.firstIndex(where:{$0.id == grant.id}))
            state.grants[i].revokedAt=Date()
        }
        XCTAssertThrowsError(try service.propose(classID:fixture.classID,agentIdentity:"Approved Agent",title:"After revoke",body:"Body",kind:.note,
                                                idempotencyKey:"revoked",grantID:grant.id)) {
            XCTAssertEqual($0 as? ProposalError,.accessDenied)
        }
    }

    @MainActor
    private struct Fixture {
        let root:URL
        let repository:ContextRepository
        let classID:UUID
        let otherClassID:UUID
        init() throws {
            root=FileManager.default.temporaryDirectory.appendingPathComponent("LCPProposalTest-"+UUID().uuidString)
            repository=try ContextRepository(rootURL:root)
            let term=AcademicTerm(name:"Synthetic term")
            let enrollment=ClassEnrollment(termID:term.id,courseCode:"TEST 101",title:"Algorithms")
            let other=ClassEnrollment(termID:term.id,courseCode:"TEST 202",title:"Other class")
            classID=enrollment.id;otherClassID=other.id
            try repository.update { state in state.terms=[term];state.classes=[enrollment,other] }
            let file=root.appendingPathComponent("source.md")
            try "Hashing can provide expected O(1) lookup with suitable load factors.".write(to:file,atomically:true,encoding:.utf8)
            _ = try MaterialService(repository:repository).importMaterial(from:file,classID:classID)
        }
        func remove() { try? FileManager.default.removeItem(at:root) }
    }
}
