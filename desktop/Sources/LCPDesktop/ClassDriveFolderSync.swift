import Foundation
import LCPClient
import LCPContextCore
import LCPContextServices

extension WorkspaceModel {
    func driveFolderStatus(for course: ClassEnrollment) -> String {
        guard let folder = course.driveFolder else { return "No Google Drive folder linked." }
        if folder.folderID != nil { return folder.name }
        return driveFolderFeedback[course.id] ?? "Waiting to set up \(folder.name) on Google Drive."
    }

    func requestDriveFolder(for id: UUID) {
        guard let course = state.classes.first(where: { $0.id == id }), course.driveFolder?.folderID == nil else { return }
        if course.driveFolder == nil {
            mutate { state in
                guard let index = state.classes.firstIndex(where: { $0.id == id }),
                      state.classes[index].driveFolder == nil else { return }
                state.classes[index].driveFolder = ClassDriveFolder(for: state.classes[index])
            }
        }
        driveFolderRetryAfter[id] = nil
        processPendingDriveFolders()
    }

    func resetDriveFolderWork() {
        driveFolderTask?.cancel()
        driveFolderRetryTask?.cancel()
        driveFolderRetryTask = nil
        driveFolderFeedback = [:]
        driveFolderRetryAfter = [:]
    }

    func wakeDriveFolders() {
        resetDriveFolderWork()
        processPendingDriveFolders()
    }

    func processPendingDriveFolders() {
        guard isReady, !restorePending, driveFolderTask == nil, let repository else { return }
        let pending = state.classes.filter { $0.driveFolder != nil && $0.driveFolder?.folderID == nil }
        guard let course = pending.first(where: { (driveFolderRetryAfter[$0.id] ?? .distantPast) <= .now }),
              let request = course.driveFolder else {
            if driveFolderRetryTask == nil, let next = pending.compactMap({ driveFolderRetryAfter[$0.id] }).min() {
                driveFolderRetryTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) }
                    catch { return }
                    driveFolderRetryTask = nil
                    processPendingDriveFolders()
                }
            }
            return
        }
        driveFolderTask = Task { @MainActor in
            defer {
                driveFolderTask = nil
                processPendingDriveFolders()
            }
            do {
                try Task.checkCancellation()
                driveFolderFeedback[course.id] = "Checking Google Drive for \(request.name)…"
                try await linkDriveFolder(for: course.id, request: request, repository: repository)
                driveFolderFeedback[course.id] = nil
            } catch is CancellationError {
                // Another process may already have linked this request.
                if self.repository === repository && !restorePending { refresh() }
            } catch {
                guard !Task.isCancelled, self.repository === repository else { return }
                driveFolderFeedback[course.id] = error.localizedDescription
                driveFolderRetryAfter[course.id] = .now.addingTimeInterval(300)
            }
        }
    }

    private func linkDriveFolder(for id: UUID, request: ClassDriveFolder, repository: ContextRepository) async throws {
        let credentials = UniversityCredentials.forLibrary(repository.rootURL)
        guard try credentials.isGoogleConnected(.drive) else {
            throw DesktopUIError.message("Connect Google Drive in Connections to set up \(request.name).")
        }
        let token = try await credentials.googleToken(.drive)
        let client = GoogleUniversityClient(token: token)

        func verifyRequest(in state: ContextState) throws -> Int {
            try Task.checkCancellation()
            guard self.repository === repository, !restorePending,
                  let index = state.classes.firstIndex(where: { $0.id == id }),
                  state.classes[index].driveFolder == request else { throw CancellationError() }
            return index
        }

        func resolve(_ name: String, under parent: String) async throws -> GoogleClassFolder {
            if let found = try await client.findClassFolder(named: name, under: parent) { return found }
            guard try credentials.canCreateDriveFolders() else {
                throw DesktopUIError.message("In Connections, open Google Drive → Manage… → Enable Folder Creation… to create \(name).")
            }
            // Use the same account and credential for the lookup and create.
            var reservedID = repository.state.reservedDriveFolder(named: name, under: parent)
            if reservedID == nil {
                let proposed = try await client.generateDriveFolderID()
                try repository.update { state in
                    _ = try verifyRequest(in: state)
                    reservedID = state.reserveDriveFolder(named: name, under: parent, proposedID: proposed)
                }
                self.state = repository.state
            }
            guard try await credentials.driveFolderToken() == token else { throw UniversityCredentialError.changed }
            try repository.refresh()
            _ = try verifyRequest(in: repository.state)
            guard let reservedID, repository.state.reservedDriveFolder(named: name, under: parent) == reservedID
            else { throw CancellationError() }
            return try await client.createClassFolder(named: name, under: parent, reservedID: reservedID)
        }

        let root: GoogleClassFolder
        if let configured = try CaptureConfiguration.live.publishedDriveRootID() {
            root = try await client.getClassFolder(id: configured)
        } else {
            // Resolve Drive's account-relative "root" alias before reserving a
            // shared folder ID. Separate accounts never share a reservation.
            let myDrive = try await client.getClassFolder(id: "root")
            root = try await resolve("School Lectures", under: myDrive.id)
        }
        let folder: GoogleClassFolder
        if let label = request.preferredExistingName, let existing = try await client.findClassFolder(named: label, under: root.id) {
            folder = existing
        } else {
            folder = try await resolve(request.name, under: root.id)
        }
        guard try await credentials.googleToken(.drive) == token else { throw UniversityCredentialError.changed }
        try repository.update { state in
            let index = try verifyRequest(in: state)
            state.classes[index].driveFolder?.folderID = folder.id
            state.classes[index].driveFolder?.name = folder.name
        }
        self.state = repository.state
    }
}
