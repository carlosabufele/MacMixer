import Foundation
import ServiceManagement

// "Open at Login" using macOS's built-in login items (SMAppService, macOS 13+).
// This registers MacMixer itself; it shows up in System Settings > General >
// Login Items. It only works reliably when MacMixer is in /Applications.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    // Set when macOS wants the user to approve the login item in System Settings.
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    init() { refresh() }

    // Re-read the status (the user can also change it in System Settings).
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
