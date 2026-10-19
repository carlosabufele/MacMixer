import SwiftUI

// The app's entry point. There is no window: the whole app lives in a
// menu bar icon that opens a small panel (MenuBarExtra with .window style).
@main
struct MacMixerApp: App {
    // One shared object that watches Core Audio for apps making sound.
    @StateObject private var monitor = AudioProcessMonitor()

    var body: some Scene {
        MenuBarExtra("MacMixer", systemImage: "slider.vertical.3") {
            ContentView(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
