import SwiftUI

// The app's entry point. There is no window: the whole app lives in a
// menu bar icon that opens a small panel (MenuBarExtra with .window style).
@main
struct MacMixerApp: App {
    init() {
        // Start everything at launch, not when the panel first opens, so saved
        // volumes are applied as soon as their apps play.
        _ = Shared.monitor
        _ = Shared.output
        _ = Shared.login
    }

    var body: some Scene {
        MenuBarExtra("MacMixer", systemImage: "slider.vertical.3") {
            ContentView(monitor: Shared.monitor, volumes: Shared.monitor.volumes,
                        output: Shared.output, login: Shared.login)
        }
        .menuBarExtraStyle(.window)
    }
}

// The app's long-lived objects, created exactly once (Swift runs a static
// constant's initializer only the first time it's used).
//
// They're deliberately not @StateObject properties of MacMixerApp: that would
// make the whole scene, including the menu bar icon, re-render every time the
// app list changes, even with the panel closed (it cost ~9x more CPU). The
// panel's views watch these objects themselves (@ObservedObject).
@MainActor
enum Shared {
    // Watches Core Audio for apps making sound; owns the per-app volumes.
    static let monitor = AudioProcessMonitor()
    // The Mac's current output device and its volume (the "Sound" card).
    static let output = OutputDevice()
    // The "Open at Login" switch.
    static let login = LaunchAtLogin()
}
