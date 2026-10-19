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

    // Apps whose tap is passing real (non-silent) sound right now. Needed because
    // once an app is tapped, Core Audio may stop reporting it as playing.
    @Published private(set) var sounding: Set<String> = []
    private var soundCheckTimer: Timer?

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
    func isSounding(_ appID: String) -> Bool { sounding.contains(appID) }
    func isMuted(_ appID: String) -> Bool { muted.contains(appID) }

    func setVolume(_ value: Float, for appID: String) {
        volumes[appID] = value
        apply(appID)
    }

    func toggleMute(_ appID: String) {
        if muted.contains(appID) { muted.remove(appID) } else { muted.insert(appID) }
        apply(appID)
    }

    // Called whenever the list of audio apps changes, or an app starts or stops
    // playing (AudioProcessMonitor refreshes on both).
    func sync(with apps: [AudioApp]) {
        processesByApp = Dictionary(apps.map { ($0.id, $0.processObjectIDs) }, uniquingKeysWith: { a, _ in a })

        for (appID, tap) in taps {
            guard processesByApp[appID] != nil else {
                taps[appID] = nil        // app is gone: tear down its tap
                continue
            }
            // A different set of the app's processes is now playing (e.g. a new
            // Chrome helper started): rebuild the tap around them. If nothing is
            // playing we keep the old tap, so the volume still applies when the
            // same process resumes.
            let playing = playingProcesses(of: appID)
            if !playing.isEmpty && Set(playing) != Set(tap.processObjectIDs) {
                taps[appID] = nil
                apply(appID)
            }
        }

        // Apps turned down while silent get their tap once they start playing.
        for appID in processesByApp.keys where taps[appID] == nil {
            apply(appID)
        }

        sounding.formIntersection(taps.keys)
        updateSoundTimer()
    }

    func removeAllTaps() {
        taps.removeAll()                 // each AppTap cleans up in deinit
        sounding.removeAll()
        updateSoundTimer()
    }

    // Only the app's processes that are making sound right now.
    //
    // Why: a tap doesn't start until EVERY process in it is producing audio.
    // Chrome has a helper (video capture) that registers with Core Audio but
    // never plays, so a tap including it never started and Chrome stayed loud.
    private func playingProcesses(of appID: String) -> [AudioObjectID] {
        (processesByApp[appID] ?? []).filter { CoreAudioHelpers.isRunningOutput($0) }
    }

    // While any tap exists, check twice a second which taps are passing
    // loud-enough sound. Only publishes changes, so the UI doesn't redraw for nothing.
    private func updateSoundTimer() {
        if taps.isEmpty {
            soundCheckTimer?.invalidate()
            soundCheckTimer = nil
        } else if soundCheckTimer == nil {
            soundCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSounding() }
            }
        }
    }

    private func checkSounding() {
        let now = Set(taps.filter { $0.value.takePeak() > 0.0001 }.keys)
        if now != sounding { sounding = now }
    }

    private func apply(_ appID: String) {
        let gain: Float = isMuted(appID) ? 0 : volume(for: appID)

        if let tap = taps[appID] {
            tap.setGain(gain)
            return
        }

        // Leave apps at full volume alone. An app that isn't playing can't be
        // tapped yet; sync() calls us again when it starts.
        let processes = playingProcesses(of: appID)
        guard gain < 0.999, !processes.isEmpty else { return }

        startTap(for: appID, processes: processes, gain: gain, attempt: 1)
    }

    private func startTap(for appID: String, processes: [AudioObjectID], gain: Float, attempt: Int) {
        for objectID in processes {
            let pid = CoreAudioHelpers.pid(of: objectID).map(String.init) ?? "?"
            tapLog.info("\(appID, privacy: .public): process object \(objectID) pid \(pid, privacy: .public) playing=\(CoreAudioHelpers.isRunningOutput(objectID))")
        }

        let tap = AppTap(processObjectIDs: processes, gain: gain)
        do {
            try tap.start()
            taps[appID] = tap
            lastError = nil
            updateSoundTimer()
        } catch {
            tapLog.error("\(appID, privacy: .public): \(String(describing: error), privacy: .public)")
            lastError = "Couldn't control this app's volume: \(error)"
            // `tap` is released here and its deinit undoes anything half-created.
            return
        }

        // Health check: a tap can be created "successfully" but never actually
        // run (for example if it was made while the permission prompt was still
        // on screen). Then the app isn't muted and the slider does nothing.
        // We only tap processes that are playing, so if the callback hasn't
        // run after a second, rebuild the tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak tap] in
            MainActor.assumeIsolated {
                guard let self, let tap, self.taps[appID] === tap else { return }  // replaced or removed meanwhile
                if tap.hasDeliveredAudio {
                    tapLog.info("\(appID, privacy: .public): tap is running (attempt \(attempt))")
                    return
                }
                tapLog.error("\(appID, privacy: .public): tap never ran (attempt \(attempt))")
                self.taps[appID] = nil
                self.sounding.remove(appID)
                self.updateSoundTimer()
                let playing = self.playingProcesses(of: appID)
                if playing.isEmpty {
                    return                 // stopped playing; sync() retries when it resumes
                } else if attempt < 3 {
                    self.startTap(for: appID, processes: playing,
                                  gain: self.isMuted(appID) ? 0 : self.volume(for: appID),
                                  attempt: attempt + 1)
                } else {
                    self.lastError = "Couldn't control this app's volume: the audio tap never started."
                }
            }
        }
    }
}
