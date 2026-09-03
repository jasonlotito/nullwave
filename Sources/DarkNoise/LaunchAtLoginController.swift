import AppKit
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool, resumePlaybackAfterInstall: Bool = false) {
        errorMessage = nil

        if enabled && !isRunningFromApplications {
            offerInstallation(resumePlayback: resumePlaybackAfterInstall)
            return
        }

        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
            NSLog("Nullwave could not update Launch at Login: %@", error as NSError)
        }

        refresh()

        if enabled && !isRegistered {
            showRegistrationError()
        }
    }

    func refresh() {
        switch service.status {
        case .enabled:
            isRegistered = true
            requiresApproval = false
        case .requiresApproval:
            isRegistered = true
            requiresApproval = true
        case .notRegistered, .notFound:
            isRegistered = false
            requiresApproval = false
        @unknown default:
            isRegistered = false
            requiresApproval = false
        }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    private func offerInstallation(resumePlayback: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Move Nullwave to Applications?"
        alert.informativeText = "Launch at Login works from Applications. Nullwave can move itself there, reopen, and finish enabling this setting. If audio is playing, the same sound and volume will resume automatically."
        alert.addButton(withTitle: "Move to Applications & Relaunch")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installAndRelaunch(resumePlayback: resumePlayback)
    }

    private func installAndRelaunch(resumePlayback: Bool) {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL.standardizedFileURL
        let destination = URL(fileURLWithPath: "/Applications/Nullwave.app", isDirectory: true)
        let staging = URL(
            fileURLWithPath: "/Applications/.Nullwave-\(UUID().uuidString).app",
            isDirectory: true
        )

        do {
            if fileManager.fileExists(atPath: destination.path),
               Bundle(url: destination)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                throw InstallationError.nameConflict
            }

            try fileManager.copyItem(at: source, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--enable-launch-at-login"]
            if resumePlayback {
                configuration.arguments.append("--resume-playback")
            }
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        self.showInstallationError(error)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            showInstallationError(error)
        }
    }

    private func showRegistrationError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Couldn’t Enable Launch at Login"
        alert.informativeText = errorMessage ?? "macOS did not register Nullwave as a login item."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Login Items")
        if alert.runModal() == .alertSecondButtonReturn {
            openLoginItemSettings()
        }
    }

    private func showInstallationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Couldn’t Move Nullwave"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum InstallationError: LocalizedError {
    case nameConflict

    var errorDescription: String? {
        "An unrelated app already uses the name “Nullwave.app” in Applications."
    }
}
