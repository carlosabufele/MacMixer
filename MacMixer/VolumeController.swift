import AppKit
import CoreAudio

// Remembers each app's volume and mute state, and creates or removes taps.
//
// An app at 100% and not muted gets no tap at all, so its sound is completely
// untouched (no added delay). A tap is created the first time you move its
// slider down or mute it, and kept until the app goes away or MacMixer quits.
// Settings are saved, so an app you turned down comes back at the same level
// the next time it plays, even after relaunching MacMixer.
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
    // When each tapped app last passed real sound.
    private var lastHeard: [String: Date] = [:]

    // Taps that are built and running.
    private var taps: [String: AppTap] = [:]
    // Old taps kept alive for a moment after being replaced, until the new tap
    // has actually started carrying sound (see retire(_:for:replacement:)).
    private var retiring: [String: AppTap] = [:]
    // Apps whose tap is being built on tapQueue right now, with a number that
    // identifies the build so a stale result can be thrown away.
    private var building: [String: Int] = [:]
    private var nextBuildNumber = 0

    private var processesByApp: [String: [AudioObjectID]] = [:]

    // All Core Audio calls that create, start, stop or destroy taps happen here,
    // one at a time.
    private let tapQueue = DispatchQueue(label: "com.skip.MacMixer.taps", qos: .userInitiated)

    // Handlers for `kill` / Ctrl-C, kept alive for the app's lifetime.
    private var signalSources: [DispatchSourceSignal] = []

    // Saving to disk waits until the slider has been still for a moment.
    private var pendingSave: DispatchWorkItem?

    // Following the output device: which device we listen to for sample-rate
    // changes, and a pending (debounced) "rebuild taps for the new device".
    private var watchedDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var pendingDeviceRebuild: DispatchWorkItem?
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.outputDeviceChanged() }
    }
    private var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        loadSettings()

        // Remove every tap on quit so no app is left silenced.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAllTapsBeforeQuit() }
        }

        // Being killed with SIGTERM (e.g. `kill`, logout) or SIGINT (Ctrl-C when run
        // from Terminal) skips willTerminate, so catch those too and clean up the
        // same way. signal(..., SIG_IGN) turns off the default "exit immediately"
        // so the dispatch source gets a chance to run.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.removeAllTapsBeforeQuit() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // Rebuild taps when the Mac switches output device (e.g. AirPods connect).
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, deviceChanged)
        watchSampleRate()
    }

    func volume(for appID: String) -> Float { volumes[appID] ?? 1 }
    func isSounding(_ appID: String) -> Bool { sounding.contains(appID) }
    func isMuted(_ appID: String) -> Bool { muted.contains(appID) }

    func setVolume(_ value: Float, for appID: String) {
        volumes[appID] = value
        apply(appID)
        scheduleSave()
    }

    func toggleMute(_ appID: String) {
        if muted.contains(appID) { muted.remove(appID) } else { muted.insert(appID) }
        apply(appID)
        scheduleSave()
    }

    // Called whenever the list of audio apps changes, or an app starts or stops
    // playing (AudioProcessMonitor refreshes on both).
    func sync(with apps: [AudioApp]) {
        processesByApp = Dictionary(apps.map { ($0.id, $0.processObjectIDs) }, uniquingKeysWith: { a, _ in a })

        for (appID, tap) in taps {
            guard processesByApp[appID] != nil else {
                removeTap(appID)         // app is gone (quit or crashed)
                continue
            }
            // A different set of the app's processes is now playing (e.g. a new
            // Chrome helper started): rebuild the tap around them. If nothing is
            // playing we keep the old tap, so the volume still applies when the
            // same process resumes.
            let playing = playingProcesses(of: appID)
            if !playing.isEmpty && Set(playing) != Set(tap.processObjectIDs) && building[appID] == nil {
                rebuildTap(appID)
            }
        }

        // Apps turned down while silent, or turned down in an earlier session,
        // get their tap once they start playing.
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
            retiring[appID]?.setGain(gain)
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

    // Replaces an app's tap with a fresh one (new device, or different processes).
    // The old tap keeps working until the new one is ready, so the app never
    // jumps to full volume in between.
    private func rebuildTap(_ appID: String) {
        guard let old = taps[appID] else { return }
        let playing = playingProcesses(of: appID)
        startTap(for: appID, processes: playing.isEmpty ? old.processObjectIDs : playing, attempt: 1)
    }

    private func startTap(for appID: String, processes: [AudioObjectID], attempt: Int) {
        for objectID in processes {
            let pid = CoreAudioHelpers.pid(of: objectID).map(String.init) ?? "?"
            tapLog.debug("\(appID, privacy: .public): process object \(objectID) pid \(pid, privacy: .public) playing=\(CoreAudioHelpers.isRunningOutput(objectID))")
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
        if let old = taps[appID] {
            retire(old, for: appID, replacement: tap)
        }
        taps[appID] = tap
        lastError = nil
        updateSoundTimer()
        scheduleHealthCheck(appID, tap: tap, attempt: attempt)
    }

    // A tap can be created "successfully" but never actually run (for example
    // if it was made while the permission prompt was still on screen). Then the
    // app isn't muted and the slider does nothing. If the app is playing and the
    // audio callback hasn't run after a second, rebuild it.
    private func scheduleHealthCheck(_ appID: String, tap: AppTap, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak tap] in
            MainActor.assumeIsolated {
                guard let self, let tap, self.taps[appID] === tap else { return }  // replaced or removed meanwhile
                if tap.hasDeliveredAudio { return }
                let playing = self.playingProcesses(of: appID)
                if playing.isEmpty {
                    return                 // paused; the tap starts when the app plays again
                }
                tapLog.error("\(appID, privacy: .public): tap never ran (attempt \(attempt))")
                self.removeTap(appID)
                if attempt < 3 {
                    self.startTap(for: appID, processes: playing, attempt: attempt + 1)
                } else {
                    self.lastError = "Couldn't control this app's volume: the audio tap never started."
                }
            }
        }
    }

    // Keeps a replaced tap running until its replacement's audio callback has
    // run, which is the moment Core Audio starts muting the app through the new
    // tap. Destroying the old one any earlier would let the app play at full
    // volume for a few milliseconds. Gives up after 2 s (e.g. the app paused).
    private func retire(_ old: AppTap, for appID: String, replacement: AppTap) {
        if let previous = retiring.removeValue(forKey: appID) {
            destroyOnTapQueue(previous)
        }
        retiring[appID] = old
        waitThenDestroy(old, appID: appID, replacement: replacement, deadline: Date().addingTimeInterval(2))
    }

    private func waitThenDestroy(_ old: AppTap, appID: String, replacement: AppTap, deadline: Date) {
        guard retiring[appID] === old else { return }   // already cleaned up elsewhere
        if replacement.hasDeliveredAudio || Date() > deadline || taps[appID] !== replacement {
            retiring[appID] = nil
            destroyOnTapQueue(old)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                self?.waitThenDestroy(old, appID: appID, replacement: replacement, deadline: deadline)
            }
        }
    }

    private func removeTap(_ appID: String) {
        if let old = retiring.removeValue(forKey: appID) {
            destroyOnTapQueue(old)
        }
        guard let tap = taps.removeValue(forKey: appID) else { return }
        sounding.remove(appID)
        lastHeard[appID] = nil
        destroyOnTapQueue(tap)
        updateSoundTimer()
    }

    // Stopping a tap is a slow Core Audio call too. The block keeps the tap
    // alive until it's done, so its deinit (which also calls stop) runs there.
    private func destroyOnTapQueue(_ tap: AppTap) {
        tapQueue.async { tap.stop() }
    }

    // The one place we wait on tapQueue: MacMixer is quitting (normally or via
    // SIGTERM/SIGINT), and every tap must be gone before the process exits so no
    // app is left silenced. If MacMixer crashes instead, Core Audio removes our
    // private taps and aggregate devices itself when the process dies.
    func removeAllTapsBeforeQuit() {
        saveSettings()
        let all = Array(taps.values) + Array(retiring.values)
        taps.removeAll()
        retiring.removeAll()
        building.removeAll()
        sounding.removeAll()
        lastHeard.removeAll()
        updateSoundTimer()
        tapQueue.sync { all.forEach { $0.stop() } }
        tapLog.debug("Removed \(all.count) taps before quitting")
    }

    // MARK: - Following the output device

    // Bluetooth switches can send several notifications in a row, and building
    // aggregate devices back to back can make apps like YouTube pause. So wait
    // until things settle for 0.4 s, then rebuild each affected tap once.
    private func outputDeviceChanged() {
        pendingDeviceRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildTapsForCurrentDevice() }
        }
        pendingDeviceRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuildTapsForCurrentDevice() {
        watchSampleRate()
        let currentUID = CoreAudioHelpers.defaultOutputDeviceID().flatMap(CoreAudioHelpers.deviceUID)
        for (appID, tap) in taps where building[appID] == nil {
            if tap.outputUID != currentUID || currentUID == nil {
                rebuildTap(appID)
            }
        }
    }

    // Logs when the current output device's sample rate changes (e.g. an app
    // switching the speakers from 44.1 to 48 kHz). We deliberately don't rebuild
    // taps here: building an aggregate can itself change the rate, which could
    // loop. The tap's drift compensation should absorb it; if a rate change ever
    // turns out to break a tap, this log line is where to start.
    private lazy var sampleRateChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated {
            guard let self else { return }
            var rate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            AudioObjectGetPropertyData(self.watchedDeviceID, &self.sampleRateAddress, 0, nil, &size, &rate)
            tapLog.notice("Output device sample rate changed to \(rate) Hz")
        }
    }

    private func watchSampleRate() {
        let deviceID = CoreAudioHelpers.defaultOutputDeviceID() ?? AudioObjectID(kAudioObjectUnknown)
        guard deviceID != watchedDeviceID else { return }
        if watchedDeviceID != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watchedDeviceID, &sampleRateAddress, DispatchQueue.main, sampleRateChanged)
        }
        watchedDeviceID = deviceID
        if deviceID != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(deviceID, &sampleRateAddress, DispatchQueue.main, sampleRateChanged)
        }
    }

    // MARK: - Saving settings

    // Stored in UserDefaults by bundle ID. Apps we only know by process number
    // ("pid-123") aren't saved, because that number changes every launch.
    // Only non-default settings are kept: below 100% or muted.
    private static let volumesKey = "appVolumes"
    private static let mutedKey = "mutedApps"

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double] {
            volumes = saved.mapValues { Float($0) }
        }
        muted = Set(defaults.stringArray(forKey: Self.mutedKey) ?? [])
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSettings() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveSettings() {
        pendingSave?.cancel()
        pendingSave = nil
        let keep: (String) -> Bool = { !$0.hasPrefix("pid-") }
        let toSave = volumes.filter { keep($0.key) && $0.value < 0.999 }.mapValues { Double($0) }
        UserDefaults.standard.set(toSave, forKey: Self.volumesKey)
        UserDefaults.standard.set(muted.filter(keep).sorted(), forKey: Self.mutedKey)
    }

    // MARK: - "Playing" detection for tapped apps

    // While any tap exists, check 5 times a second which taps are passing
    // loud-enough sound. An app stays "playing" for 1.5 s after its last sound,
    // so it doesn't flicker to "Not playing" during a quiet bit or between songs.
    // Only publishes changes, so the UI doesn't redraw for nothing.
    private static let checkInterval: TimeInterval = 0.2
    private static let holdTime: TimeInterval = 1.5

    private func updateSoundTimer() {
        if taps.isEmpty {
            soundCheckTimer?.invalidate()
            soundCheckTimer = nil
        } else if soundCheckTimer == nil {
            soundCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSounding() }
            }
        }
    }

    private func checkSounding() {
        let now = Date()
        for (appID, tap) in taps where tap.takePeak() > 0.0001 {
            lastHeard[appID] = now
        }
        let current = Set(lastHeard.filter { now.timeIntervalSince($0.value) < Self.holdTime }.keys)
        if current != sounding { sounding = current }
    }
}
