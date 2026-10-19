import SwiftUI

// The panel that drops down from the menu bar icon.
struct ContentView: View {
    @ObservedObject var monitor: AudioProcessMonitor
    @State private var showNotPlaying = false

    private var playing: [AudioApp] { monitor.apps.filter { $0.isPlaying } }
    private var notPlaying: [AudioApp] { monitor.apps.filter { !$0.isPlaying } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MacMixer")
                .font(.headline)

            Text("PLAYING")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if playing.isEmpty {
                Text("Nothing is playing right now")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playing) { app in
                    AppRow(app: app)
                }
            }

            if !notPlaying.isEmpty {
                DisclosureGroup(isExpanded: $showNotPlaying) {
                    ForEach(notPlaying) { app in
                        AppRow(app: app)
                    }
                } label: {
                    Text("NOT PLAYING  \(notPlaying.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Quit MacMixer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }
}

// One line in the list: icon, name, and a speaker badge while it plays.
struct AppRow: View {
    let app: AudioApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 28, height: 28)
            Text(app.name)
                .lineLimit(1)
            Spacer()
            if app.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
