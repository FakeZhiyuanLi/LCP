import Combine
import Foundation
import LCPContextCore
import LCPContextServices

/// One workspace keeps a university planner and a separate planner for each class.
@MainActor
final class PlannerSession: ObservableObject {
    struct Plan {
        let result: ClassPlanResult
        let objective: String
        let profile: AgentProviderProfile
    }

    let classID: UUID?
    @Published var objective: String
    @Published var selectedProfileID: UUID?
    @Published private(set) var selectedClassIDs: Set<UUID>?
    @Published private(set) var plan: Plan?
    @Published private(set) var status: String?
    @Published private var task: Task<Void, Never>?
    var isGenerating: Bool { task != nil }

    init(classID: UUID?) {
        self.classID = classID
        objective = ClassPlannerService.defaultObjective(acrossClasses: classID == nil)
    }

    func classIDs(in model: WorkspaceModel) -> [UUID] {
        if let classID { return model.state.classes.contains { $0.id == classID } ? [classID] : [] }
        let active = model.activeClasses.map(\.id)
        guard let selectedClassIDs else { return active }
        return active.filter(selectedClassIDs.contains)
    }

    func selectClasses(_ ids: Set<UUID>) {
        guard classID == nil, !isGenerating, ids != selectedClassIDs else { return }
        selectedClassIDs = ids
        plan = nil
        status = nil
    }

    func generate(in model: WorkspaceModel, using profile: AgentProviderProfile) {
        guard !isGenerating, !model.restorePending, let repository = model.repository else { return }
        let ids = classIDs(in: model)
        let request = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ids.isEmpty, !request.isEmpty else { return }
        if classID == nil { selectedClassIDs = Set(ids) }
        plan = nil
        status = nil
        let root = model.rootURL
        let providers = model.agentProviders
        task = Task { [weak model] in
            defer { task = nil }
            do {
                try Task.checkCancellation()
                let key = try await providers.apiKey(root, profile)
                try Task.checkCancellation()
                let result = try await ClassPlannerService(repository: repository, http: providers.http)
                    .generate(classIDs: ids, objective: request, profile: profile, apiKey: key)
                try Task.checkCancellation()
                guard let model, model.rootURL == root, model.repository === repository else { return }
                guard Set(classIDs(in: model)) == Set(ids) else {
                    status = "The classes in this plan changed. Generate a plan for the current selection."
                    return
                }
                plan = Plan(result: result, objective: request, profile: profile)
            } catch {
                status = Task.isCancelled || error is CancellationError
                    ? "The planning request was cancelled." : error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }
}
