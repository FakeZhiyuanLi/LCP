import SwiftUI
import AppKit

@main
struct LCPDesktopApp: App {
    @StateObject private var workspace: WorkspaceModel
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var appDelegate

    init() {
        syntheticLifecycle("app-init")
        let model = WorkspaceModel()
        _workspace = StateObject(wrappedValue: model)
        DesktopAppDelegate.launchWorkspace = model
        syntheticLifecycle("model-initialized")
    }

    var body: some Scene {
        WindowGroup("LCP", id: "workspace") {
            ScopedWorkspaceView(model: workspace)
                .frame(minWidth: 980, minHeight: 660)
                .preferredColorScheme(workspace.previewColorScheme)
                .onOpenURL { url in
                    if DesktopAppDelegate.active == nil {
                        appDelegate.application(NSApp, open: [url])
                    } else {
                        workspace.openCitationURL(url, delivery: "swiftui-onOpenURL") {
                            appDelegate.prepareWindowAndPreview()
                        }
                    }
                }
                .onAppear {
                    appDelegate.workspace = workspace
                    appDelegate.prepareWindowAndPreview()
                }
        }
        .defaultSize(width: 1260, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Class…") { workspace.inWorkspace("New Class") { workspace.presentedEditor = .newClass } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Study Note…") { workspace.inWorkspace("New Study Note") { workspace.presentedEditor = .newActivity } }
                    .keyboardShortcut("j", modifiers: .command)
                    .disabled(workspace.selectedClassID == nil)
                Button("Import Material…") { workspace.importMaterials() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(workspace.selectedClassID == nil)
                Button("Study Planner…", systemImage: "sparkles") { workspace.openPlanner() }
                Button("University Chat…", systemImage: "bubble.left.and.bubble.right.fill") { workspace.openUniversityChat() }
                Button("Open Capture") { workspace.openCapture() }
            }
            CommandGroup(after: .saveItem) {
                Button("Back Up Library…") { workspace.exportBackup() }
                Button("Export Class Context…") { workspace.exportContextBundle() }
                    .disabled(workspace.selectedClassID == nil)
            }
        }
        Settings { DesktopSettingsView(model: workspace) }
        MenuBarExtra {
            DesktopMenuBarView(model: workspace)
        } label: {
            let icon = workspace.captureIsRecording
                ? Image(systemName: "record.circle.fill")
                : Image(nsImage: LCPMenuBarIcon.image)
            icon.renderingMode(.template)
                .accessibilityLabel(workspace.captureIsRecording ? "LCP Desktop, recording" : "LCP Desktop")
        }
    }
}

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    static var launchWorkspace: WorkspaceModel?
    static weak var active: DesktopAppDelegate?
    var workspace: WorkspaceModel?
    private var fallbackWindow: NSWindow?
    private var previewScheduled = false
    private var pendingURLs: [URL] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        syntheticLifecycle("did-finish-launching")
        NSApp.setActivationPolicy(.regular)
        Self.active = self
        workspace = workspace ?? Self.launchWorkspace
        Self.launchWorkspace = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            _ = workspace
            self.showWorkspace()
            self.writeReadyReceipt()
            let queuedURLs = self.pendingURLs
            self.pendingURLs.removeAll()
            if !queuedURLs.isEmpty { self.application(NSApp, open: queuedURLs) }
            self.prepareWindowAndPreview()
        }
    }
    func showWorkspace() {
        guard let workspace else { syntheticLifecycle("workspace-missing"); return }
        syntheticLifecycle("show-workspace")
        if let existing = fallbackWindow ?? NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width >= 900 }) {
            configureSyntheticWindow(existing, workspace: workspace)
            existing.makeKeyAndOrderFront(nil)
            fallbackWindow = existing
        } else {
            // Keep an explicit native window for menu-bar-scene launch routes.
            let controller = NSHostingController(rootView: ScopedWorkspaceView(model: workspace).frame(minWidth: 980, minHeight: 660).preferredColorScheme(workspace.previewColorScheme))
            let window = NSWindow(contentViewController: controller)
            window.title = "LCP"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1260, height: 820))
            window.isReleasedWhenClosed = false
            configureSyntheticWindow(window, workspace: workspace)
            let args = ProcessInfo.processInfo.arguments
            if !args.contains("--demo") && !args.contains("--profile-root") {
                window.setFrameAutosaveName("LCPDesktopWorkspace")
                if !window.setFrameUsingName("LCPDesktopWorkspace") { window.center() }
            } else { window.center() }
            window.makeKeyAndOrderFront(nil)
            fallbackWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func configureSyntheticWindow(_ window: NSWindow, workspace: WorkspaceModel) {
        guard let scheme = workspace.previewColorScheme else { return }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = scheme == .dark ? .windowBackgroundColor : .white
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--render-preview") {
            let size = arguments.contains("--preview-compact")
                ? NSSize(width: 980, height: 660)
                : NSSize(width: 1260, height: 820)
            window.setContentSize(size)
        }
    }
    private func writeReadyReceipt() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let workspace, workspace.allowsSyntheticDiagnostics,
              let index = arguments.firstIndex(of: "--ready-receipt"), arguments.indices.contains(index + 1) else { return }
        struct Receipt: Encodable { let schemaVersion = 1; let pid: Int32; let profileRoot: String; let bundleIdentifier: String?; let libraryReady: Bool; let windowVisible: Bool; let readyAt = Date() }
        do {
            let receipt = Receipt(pid: ProcessInfo.processInfo.processIdentifier, profileRoot: workspace.rootURL.path, bundleIdentifier: Bundle.main.bundleIdentifier, libraryReady: workspace.isReady, windowVisible: fallbackWindow?.isVisible ?? NSApp.windows.contains { $0.isVisible && $0.frame.width >= 900 })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let destination = URL(fileURLWithPath: arguments[index + 1])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(receipt).write(to: destination, options: .atomic)
            syntheticLifecycle("window-ready-receipt")
        } catch { FileHandle.standardError.write(Data("LCP synthetic ready receipt failed: \(error.localizedDescription)\n".utf8)) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkspace() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard workspace != nil, Self.active != nil else {
            pendingURLs.append(contentsOf: urls.prefix(max(0, 32 - pendingURLs.count)))
            syntheticLifecycle("queued-cold-start-urls")
            return
        }
        showWorkspace()
        for url in urls {
            workspace?.openCitationURL(url, delivery: "native-application-open") { [weak self] in
                self?.prepareWindowAndPreview()
            }
        }
        prepareWindowAndPreview()
    }
    func prepareWindowAndPreview() {
        guard !previewScheduled else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let workspace, workspace.allowsSyntheticDiagnostics,
              let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) else { return }
        if arguments.contains("--wait-for-citation") && workspace.presentedCitation == nil { return }
        previewScheduled = true
        let output = URL(fileURLWithPath: arguments[index + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            do {
                guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible && $0.attachedSheet != nil }).flatMap({ $0.attachedSheet }) ?? NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible && $0.frame.width >= 900 }), let view = window.contentView else { throw DesktopUIError.message("The native workspace window was not available for preview.") }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DesktopUIError.message("Could not allocate a preview bitmap.") }
                let appearance = NSAppearance(named: workspace.previewColorScheme == .dark ? .darkAqua : .aqua) ?? window.effectiveAppearance
                window.appearance = appearance
                view.appearance = appearance
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                guard let sourceImage = bitmap.cgImage,
                      let context = CGContext(data: nil, width: sourceImage.width, height: sourceImage.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw DesktopUIError.message("Could not create an opaque preview canvas.") }
                let rectangle = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
                context.setFillColor(workspace.previewColorScheme == .dark ? NSColor.black.cgColor : NSColor.white.cgColor)
                context.fill(rectangle)
                context.draw(sourceImage, in: rectangle)
                guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw DesktopUIError.message("Could not encode the preview.") }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: output, options: .atomic)
                FileHandle.standardOutput.write(Data("LCP synthetic native preview: \(output.path)\n".utf8))
                self.finishSyntheticPreview()
            } catch {
                FileHandle.standardError.write(Data("LCP preview failed: \(error.localizedDescription)\n".utf8))
                self.finishSyntheticPreview()
            }
        }
    }
    private func finishSyntheticPreview() {
        // Dismiss this fixture's source sheet before requesting normal native
        // termination; an attached modal sheet can otherwise defer Quit.
        workspace?.presentedCitation = nil
        workspace?.presentedEditor = nil
        workspace?.presentedContextExportClassID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.prepareToTerminate() == true ? .terminateLater : .terminateNow
    }
}


private extension WorkspaceModel {
    var previewColorScheme: ColorScheme? {
        guard allowsSyntheticDiagnostics else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--render-preview") && arguments.contains("--preview-dark") ? .dark : .light
    }
}

private func syntheticLifecycle(_ phase: String) {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("--profile-root"), arguments.contains("--demo") || arguments.contains("--synthetic-fixture") else { return }
    FileHandle.standardError.write(Data("LCP synthetic lifecycle: \(phase)\n".utf8))
}
