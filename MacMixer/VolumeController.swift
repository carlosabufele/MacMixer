import AppKit
import CoreAudio

// Remembers each app's volume and mute state, and creates or removes taps.
//
// An app at 100% and not muted gets no tap at all, so its sound is completely
// untouched (no added delay). A tap is created the first time you move its
// slider down or mute it, and kept until the app goes away or MacMixer quits.
//
// Building or destroying a tap can take Core Audio several seconds, so that work
// runs on `tapQueue`, never on the main thread. The UI only ever changes numbers.
@MainActor
final class VolumeController: ObservableObject {
    @Published private(set) var volumes: [String: Float] = [:]   // 0.0 ... 1.0
    @Published private(set) var muted: Set<String> = []
    @Published private(set) var lastError: String?

    // Apps whose tap is passing real (non-silent) sound right now. Needed because
    // once an app is tapped, Core Audio may stop reporting it as playing.
    @Published private(set) var sounding: Set<String> = []
    private var soundCheckTimer: Timer?

    // Taps that are built and running.
    private var taps: [String: AppTap] = [:]
    // Apps whose tap is being built on tapQueue right now, with a number that
    // identifies the build so a stale result can be thrown away.
    private var building: [String: Int] = [:]
    private var nextBuildNumber = 0

    private var processesByApp: [String: [AudioObjectID]] = [:]

    // All Core Audio calls that create, start, stop or destroy taps happen here,
    // one at a time.
    private let tapQueue = DispatchQueue(label: "com.skip.MacMixer.taps", qos: .userInitiated)

    init() {
        // Remove every tap on quit so no app is left silenced.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAllTapsBeforeQuit() }
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
                removeTap(appID)         // app is gone
                continue
            }
            // A different set of the app's processes is now playing (e.g. a new
            // Chrome helper started): rebuild the tap around them. If nothing is
            // playing we keep the old tap, so the volume still applies when the
            // same process resumes.
            let playing = playingProcesses(of: appID)
            if !playing.isEmpty && Set(playing) != Set(tap.processObjectIDs) {
                removeTap(appID)
                apply(appID)
            }
        }

        // Apps turned down while silent get their tap once they start playing.
        for appID in processesByApp.keys where taps[appID] == nil {
            apply(appID)
        }
    }

    // Only the app's processes that are making sound right now.
    //
    // Why: a tap doesn't start until EVERY process in it is producing audio.
    // Chrome has a helper (video capture) that registers with Core Audio but
    // never plays, so a tap including it never started and Chrome stayed loud.
    private func playingProcesses(of appID: String) -> [AudioObjectID] {
        (processesByApp[appID] ?? []).filter { CoreAudioHelpers.isRunningOutput($0) }
    }

    private func currentGain(_ appID: String) -> Float {
        isMuted(appID) ? 0 : volume(for: appID)
    }

    private func apply(_ appID: String) {
        let gain = currentGain(appID)

        if let tap = taps[appID] {
            tap.setGain(gain)            // just a number; the audio thread picks it up
            return
        }

        // A tap is already on its way. It reads the latest volume when it's ready,
        // so rapid slider moves don't queue up more builds.
        guard building[appID] == nil else { return }

        // Leave apps at full volume alone. An app that isn't playing can't be
        // tapped yet; sync() calls us again when it starts.
        let processes = playingProcesses(of: appID)
        guard gain < 0.999, !processes.isEmpty else { return }

        startTap(for: appID, processes: processes, attempt: 1)
    }

    // MARK: - Building and removing taps (the slow part runs on tapQueue)

    private func startTap(for appID: String, processes: [AudioObjectID], attempt: Int) {
        for objectID in processes {
            let pid = CoreAudioHelpers.pid(of: objectID).map(String.init) ?? "?"
            tapLog.info("\(appID, privacy: .public): process object \(objectID) pid \(pid, privacy: .public) playing=\(CoreAudioHelpers.isRunningOutput(objectID))")
        }

        nextBuildNumber += 1
        let buildNumber = nextBuildNumber
        building[appID] = buildNumber
        let tap = AppTap(processObjectIDs: processes, gain: currentGain(appID))

        tapQueue.async { [weak self] in
            let result = Result { try tap.start() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishBuilding(appID, tap: tap, buildNumber: buildNumber, result: result, attempt: attempt)
                }
            }
        }
    }

    private func finishBuilding(_ appID: String, tap: AppTap, buildNumber: Int,
                                result: Result<Void, Error>, attempt: Int) {
        // If the app went away or a newer build replaced this one, throw it away.
        guard building[appID] == buildNumber, processesByApp[appID] != nil else {
            if building[appID] == buildNumber { building[appID] = nil }
            destroyOnTapQueue(tap)
            return
        }
        building[appID] = nil

        if case .failure(let error) = result {
            tapLog.error("\(appID, privacy: .public): \(String(describing: error), privacy: .public)")
            lastError = "Couldn't control this app's volume: \(error)"
            destroyOnTapQueue(tap)   // undoes anything half-created
            return
        }

        // The slider may have moved (or been dragged back to 100%) while we waited.
        tap.setGain(currentGain(appID))
        taps[appID] = tap
        lastError = nil
        updateSoundTimer()
        scheduleHealthCheck(appID, tap: tap, attempt: attempt)
    }

    // A tap can be created "successfully" but never actually run (for example
    // if it was made while the permission prompt was still on screen). Then the
    // app isn't muted and the slider does nothing. We only tap processes that are
    // playing, so if the audio callback hasn't run after a second, rebuild it.
    private func scheduleHealthCheck(_ appID: String, tap: AppTap, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak tap] in
            MainActor.assumeIsolated {
                guard let self, let tap, self.taps[appID] === tap else { return }  // replaced or removed meanwhile
                if tap.hasDeliveredAudio {
                    tapLog.info("\(appID, privacy: .public): tap is running (attempt \(attempt))")
                    return
                }
                tapLog.error("\(appID, privacy: .public): tap never ran (attempt \(attempt))")
                self.removeTap(appID)
                let playing = self.playingProcesses(of: appID)
                if playing.isEmpty {
                    return                 // stopped playing; sync() retries when it resumes
                } else if attempt < 3 {
                    self.startTap(for: appID, processes: playing, attempt: attempt + 1)
                } else {
                    self.lastError = "Couldn't control this app's volume: the audio tap never started."
                }
            }
        }
    }

    private func removeTap(_ appID: String) {
        guard let tap = taps.removeValue(forKey: appID) else { return }
        sounding.remove(appID)
        destroyOnTapQueue(tap)
        updateSoundTimer()
    }

    // Stopping a tap is a slow Core Audio call too. The block keeps the tap
    // alive until it's done, so its deinit (which also calls stop) runs there.
    private func destroyOnTapQueue(_ tap: AppTap) {
        tapQueue.async { tap.stop() }
    }

    // The one place we wait on tapQueue: the app is quitting, and every tap must
    // be gone before the process exits so no app is left silenced.
    private func removeAllTapsBeforeQuit() {
        let all = Array(taps.values)
        taps.removeAll()
        building.removeAll()
        sounding.removeAll()
        updateSoundTimer()
        tapQueue.sync { all.forEach { $0.stop() } }
    }

    // MARK: - "Playing" detection for tapped apps

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
}
