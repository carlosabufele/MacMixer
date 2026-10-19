import SwiftUI

// The panel that drops down from the menu bar icon.
struct ContentView: View {
    @ObservedObject var monitor: AudioProcessMonitor
    @ObservedObject var volumes: VolumeController
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
                    AppRow(app: app, volumes: volumes)
                }
            }

            if !notPlaying.isEmpty {
                DisclosureGroup(isExpanded: $showNotPlaying) {
                    ForEach(notPlaying) { app in
                        AppRow(app: app, volumes: volumes)
                    }
                } label: {
                    Text("NOT PLAYING  \(notPlaying.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = volumes.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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

// One app: icon, name, percentage, then a mute button and volume slider.
struct AppRow: View {
    let app: AudioApp
    @ObservedObject var volumes: VolumeController

    private var isMuted: Bool { volumes.isMuted(app.id) }
    private var volume: Float { volumes.volume(for: app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(app.name)
                    .lineLimit(1)
                Spacer()
                Text(isMuted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    volumes.toggleMute(app.id)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(isMuted ? Color.secondary : (app.isPlaying ? Color.green : Color.primary))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help(isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { volumes.setVolume(Float($0), for: app.id) }
                    ),
                    in: 0...1
                )
                .disabled(isMuted)
            }
        }
    }
}
