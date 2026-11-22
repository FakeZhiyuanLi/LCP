import Foundation
import LCPContextCore

public enum ProposalKind: String, Codable, Sendable {
    case note
    case studyLog = "study_log"
}

public enum ProposalError: Error, LocalizedError, Equatable {
    case invalidInput
    case classUnavailable
    case accessDenied
    case missingProposal
    case alreadyReviewed
    case idempotencyConflict
    case staleTarget
    case unsupportedTarget
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "The proposal exceeds its limits or is incomplete."
        case .classUnavailable: return "The selected class is unavailable."
        case .accessDenied: return "This connection does not have permission to propose changes to these sources."
        case .missingProposal: return "The proposal is unavailable."
        case .alreadyReviewed: return "The proposal has already been reviewed."
        case .idempotencyConflict: return "This retry key was already used for a different proposal."
        case .staleTarget: return "The target has changed. Review a new proposal against its current version."
        case .unsupportedTarget: return "Agents may propose notes and study history only."
        }
    }
}

/// Agents can create drafts. Only an explicit user action in the desktop invokes
/// accept/reject; neither operation is exposed as an MCP tool.
@MainActor
public final class ProposalService {
    private let repository: ContextRepository
    public init(repository: ContextRepository) { self.repository = repository }

    public func pending(classID: UUID? = nil) -> [AgentProposal] {
        repository.state.proposals.filter { $0.state == "pending" && (classID == nil || $0.classID == classID) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func propose(classID: UUID, agentIdentity: String, title: String, body: String,
                        kind: ProposalKind = .studyLog, targetID: UUID? = nil,
                        expectedVersion: UInt64? = nil, idempotencyKey: String,
                        citations: [SourceCitation] = [], contextManifest: [SourceCitation]? = nil, grantID: UUID? = nil) throws -> AgentProposal {
        let inputManifest = contextManifest ?? citations
        guard inputManifest.count <= 128, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !agentIdentity.isEmpty, title.utf8.count <= 512, body.utf8.count <= 262_144,
              agentIdentity.utf8.count <= 512, !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256,
              citations.count <= 32, (targetID == nil) == (expectedVersion == nil) else {
            throw ProposalError.invalidInput
        }
        try repository.refresh()
        let retrieval = RetrievalService(repository: repository)
        for citation in citations + inputManifest {
            guard citation.classID == classID else { throw ProposalError.accessDenied }
            _ = try retrieval.resolve(citation, grantID: grantID)
        }
        var result: AgentProposal?
        try repository.update { state in
            guard state.classes.contains(where: { $0.id == classID }) else { throw ProposalError.classUnavailable }
            let identity = try Self.authorizedIdentity(state: state, grantID: grantID, classID: classID,
                                                       kind: kind, fallback: agentIdentity)
            // Scope retry keys to the stable connection ID; a display-name change
            // cannot cause an agent retry to create a second artifact.
            let key = grantID.flatMap { id in state.grants.first(where: { $0.id == id }) }
                .map { $0.connectionID.uuidString + ":" + idempotencyKey } ?? idempotencyKey
            if let existing = state.proposals.first(where: {
                $0.classID == classID && $0.idempotencyKey == key && (grantID != nil || $0.agentIdentity == identity)
            }) {
                guard existing.title == title, existing.body == body,
                      existing.targetKind == kind.rawValue, existing.targetID == targetID,
                      existing.expectedVersion == expectedVersion,
                      Self.sameCitations(existing.citations, citations) else { throw ProposalError.idempotencyConflict }
                // Preserve the first input manifest when an identical request
                // retries after the agent has retrieved additional context.
                result = existing
                return
            }
            if let targetID = targetID {
                if let grantID, let grant = state.grants.first(where: { $0.id == grantID }), grant.allowedMaterialIDs != nil {
                    // A material-only grant cannot inspect/correct unrelated
                    // activity records, even within an allowed class.
                    throw ProposalError.accessDenied
                }
                guard let target = state.activities.first(where: { $0.id == targetID && $0.classID == classID }),
                      target.version == expectedVersion,
                      !state.activities.contains(where: { $0.supersedesID == targetID }) else {
                    throw ProposalError.staleTarget
                }
                if let grantID, let grant = state.grants.first(where: { $0.id == grantID }),
                   !RetrievalService.matchesEventTime(target.eventAt, eventFrom: grant.eventFrom, eventUntil: grant.eventUntil) {
                    throw ProposalError.accessDenied
                }
            }
            let proposal = AgentProposal(classID: classID, agentIdentity: identity, targetKind: kind.rawValue,
                                         targetID: targetID, expectedVersion: expectedVersion, idempotencyKey: key,
                                         title: title, body: body, citations: citations, contextManifest: inputManifest)
            state.proposals.append(proposal)
            result = proposal
        }
        guard let result else { throw ProposalError.invalidInput }
        return result
    }

    @discardableResult
    public func accept(_ proposalID: UUID) throws -> ActivityEntry {
        try repository.refresh()
        guard let proposal = repository.state.proposals.first(where: { $0.id == proposalID }) else {
            throw ProposalError.missingProposal
        }
        if proposal.state == "accepted", let existing = repository.state.activities.first(where: { $0.id == proposal.id }) {
            return existing
        }
        guard proposal.state == "pending" else { throw ProposalError.alreadyReviewed }
        guard ProposalKind(rawValue: proposal.targetKind) != nil else { throw ProposalError.unsupportedTarget }
        // Validate source fidelity before committing. The core repository pins
        // the exact cited payloads as part of the same state transaction.
        let retrieval = RetrievalService(repository: repository)
        for citation in proposal.citations + proposal.contextManifest { _ = try retrieval.resolve(citation) }
        var result: ActivityEntry?
        try repository.update { state in
            guard let index = state.proposals.firstIndex(where: { $0.id == proposalID }) else {
                throw ProposalError.missingProposal
            }
            let current = state.proposals[index]
            if current.state == "accepted", let existing = state.activities.first(where: { $0.id == current.id }) {
                result = existing
                return
            }
            guard current.state == "pending" else { throw ProposalError.alreadyReviewed }
            guard state.classes.contains(where: { $0.id == current.classID }) else { throw ProposalError.classUnavailable }
            var version: UInt64 = 1
            if let targetID = current.targetID {
                guard let target = state.activities.first(where: { $0.id == targetID && $0.classID == current.classID }),
                      target.version == current.expectedVersion,
                      !state.activities.contains(where: { $0.supersedesID == targetID }) else {
                    throw ProposalError.staleTarget
                }
                guard target.version < UInt64.max else { throw ProposalError.staleTarget }
                version = target.version + 1
            }
            let entry = ActivityEntry(id: current.id, classID: current.classID,
                                      kind: "agent_" + current.targetKind, title: current.title, body: current.body,
                                      version: version, citations: current.citations, agentIdentity: current.agentIdentity,
                                      supersedesID: current.targetID, inputContextManifest: current.contextManifest)
            state.activities.append(entry)
            state.proposals[index].state = "accepted"
            state.proposals[index].reviewedAt = Date()
            result = entry
        }
        guard let result else { throw ProposalError.invalidInput }
        return result
    }

    public func reject(_ proposalID: UUID) throws {
        try repository.update { state in
            guard let index = state.proposals.firstIndex(where: { $0.id == proposalID }) else {
                throw ProposalError.missingProposal
            }
            if state.proposals[index].state == "rejected" { return }
            guard state.proposals[index].state == "pending" else { throw ProposalError.alreadyReviewed }
            state.proposals[index].state = "rejected"
            state.proposals[index].reviewedAt = Date()
        }
    }

    private static func authorizedIdentity(state: ContextState, grantID: UUID?, classID: UUID,
                                           kind: ProposalKind, fallback: String) throws -> String {
        guard let grantID else { return fallback }
        guard let grant = state.grants.first(where: { $0.id == grantID }), grant.isActive,
              grant.allowedClassIDs.contains(classID),
              let connection = state.connections.first(where: { $0.id == grant.connectionID }),
              connection.capabilities.contains(kind == .note ? "propose_note" : "propose_study_log") else {
            throw ProposalError.accessDenied
        }
        return connection.name
    }

    private static func sameCitations(_ lhs: [SourceCitation], _ rhs: [SourceCitation]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        // A transport may regenerate display citation IDs, but a retry must pin
        // exactly the same source identity, revision, payload and locator.
        return zip(lhs, rhs).allSatisfy {
            $0.classID == $1.classID && $0.sourceKind == $1.sourceKind && $0.sourceID == $1.sourceID &&
            $0.revisionID == $1.revisionID && $0.payloadSHA256 == $1.payloadSHA256 && $0.locator == $1.locator
        }
    }
}
