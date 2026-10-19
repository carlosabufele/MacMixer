import AppKit
import CoreAudio

// Remembers each app's volume and mute state, and creates or removes taps.
//
// An app at 100% and not muted gets no tap at all, so its sound is completely
// untouched (no added delay). A tap is created the first time you move its
// slider down or mute it, and kept until the app goes away or MacMixer quits.
@MainActor
final class VolumeController: ObservableObject {
    @Published private(set) var volumes: [String: Float] = [:]   // 0.0 ... 1.0
    @Published private(set) var muted: Set<String> = []
    @Published private(set) var lastError: String?

    private var taps: [String: AppTap] = [:]
    private var processesByApp: [String: [AudioObjectID]] = [:]

    init() {
        // Remove every tap on quit so no app is left silenced.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAllTaps() }
        }
    }

    func volume(for appID: String) -> Float { volumes[appID] ?? 1 }
    func isMuted(_ appID: String) -> Bool { muted.contains(appID) }

    func setVolume(_ value: Float, for appID: String) {
        volumes[appID] = value
        apply(appID)
    }

    func toggleMute(_ appID: String) {
        if muted.contains(appID) { muted.remove(appID) } else { muted.insert(appID) }
        apply(appID)
    }

    // Called whenever the list of audio apps changes.
    func sync(with apps: [AudioApp]) {
        processesByApp = Dictionary(apps.map { ($0.id, $0.processObjectIDs) }, uniquingKeysWith: { a, _ in a })

        for (appID, tap) in taps {
            guard let processes = processesByApp[appID] else {
                taps[appID] = nil        // app is gone: tear down its tap
                continue
            }
            if Set(processes) != Set(tap.processObjectIDs) {
                taps[appID] = nil        // app gained/lost a helper process: rebuild
                apply(appID)
            }
        }
    }

    func removeAllTaps() {
        taps.removeAll()                 // each AppTap cleans up in deinit
    }

    private func apply(_ appID: String) {
        let gain: Float = isMuted(appID) ? 0 : volume(for: appID)

        if let tap = taps[appID] {
            tap.setGain(gain)
            return
        }

        // Leave apps at full volume alone.
        guard gain < 0.999, let processes = processesByApp[appID] else { return }

        let tap = AppTap(processObjectIDs: processes, gain: gain)
        do {
            try tap.start()
            taps[appID] = tap
            lastError = nil
        } catch {
            lastError = "Couldn't control this app's volume: \(error)"
            // `tap` is released here and its deinit undoes anything half-created.
        }
    }
}
