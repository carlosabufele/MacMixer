import SwiftUI

// The panel that drops down from the menu bar icon, styled like Control Center:
// a "Sound" card for the whole Mac, then one card per group of apps.
struct ContentView: View {
    @ObservedObject var monitor: AudioProcessMonitor
    @ObservedObject var volumes: VolumeController
    @ObservedObject var output: OutputDevice
    @ObservedObject var login: LaunchAtLogin
    @State private var showNotPlaying = false

    // An app counts as playing if Core Audio says so, or if its tap is passing sound.
    private func isPlaying(_ app: AudioApp) -> Bool { app.isPlaying || volumes.isSounding(app.id) }
    private var playing: [AudioApp] { monitor.apps.filter { isPlaying($0) } }
    private var notPlaying: [AudioApp] { monitor.apps.filter { !isPlaying($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SoundCard(output: output)

            SectionHeader(title: "PLAYING")
            VStack(alignment: .leading, spacing: 10) {
                if playing.isEmpty {
                    Text("Nothing is playing right now")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(playing) { app in
                        AppRow(app: app, volumes: volumes)
                    }
                }
            }
            .card()

            if !notPlaying.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showNotPlaying.toggle() }
                } label: {
                    HStack {
                        SectionHeader(title: "NOT PLAYING  \(notPlaying.count)")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showNotPlaying ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showNotPlaying {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notPlaying) { app in
                            AppRow(app: app, volumes: volumes)
                        }
                    }
                    .card()
                }
            }

            if let error = volumes.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("Open at Login")
                Spacer()
                Toggle("Open at Login", isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            if login.needsApproval {
                Button("Approve in System Settings…") { login.openLoginItemsSettings() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if let message = login.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Sound Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { login.refresh() }   // in case it was changed in System Settings
    }
}

// The whole Mac's volume: a slider for the current output device, a mute
// button, and the device's name and icon underneath.
struct SoundCard: View {
    @ObservedObject var output: OutputDevice

    private var speakerSymbol: String {
        if output.isMuted || output.volume == 0 { return "speaker.slash.fill" }
        return output.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound")
                .font(.headline)

            HStack(spacing: 8) {
                Button {
                    output.toggleMute()
                } label: {
                    Image(systemName: speakerSymbol)
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                // The panel gives its first button keyboard focus, which draws a
                // focus ring around it. Make this button not take focus at all.
                .focusable(false)
                .disabled(!output.canMute)
                .help(output.isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { Double(output.isMuted ? 0 : output.volume) },
                        set: { output.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!output.hasVolume)

                Text(output.isMuted ? "Muted" : "\(Int((output.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Image(systemName: output.symbolName)
                Text(output.name)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !output.hasVolume {
                Text("This device's volume can't be changed from the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

// One app: its icon (click to mute), name, percentage, and a thin slider.
struct AppRow: View {
    let app: AudioApp
    @ObservedObject var volumes: VolumeController

    private var isMuted: Bool { volumes.isMuted(app.id) }
    private var volume: Float { volumes.volume(for: app.id) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                volumes.toggleMute(app.id)
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .opacity(isMuted ? 0.35 : 1)
                        .saturation(isMuted ? 0 : 1)
                    if isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .padding(3)
                            .background(Circle().fill(.background))
                            .offset(x: 3, y: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name)
                        .lineLimit(1)
                    Spacer()
                    Text(isMuted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { volumes.setVolume(Float($0), for: app.id) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                .disabled(isMuted)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// The rounded, slightly lighter box Control Center uses for each group.
private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
}
