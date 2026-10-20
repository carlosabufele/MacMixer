import AppKit
import CoreAudio
import Darwin
import UniformTypeIdentifiers

// One row in the mixer: an app plus the Core Audio "process objects" that
// belong to it. Browsers often have several (one per helper process).
struct AudioApp: Identifiable {
    let id: String              // bundle ID when we know it, otherwise "pid-123"
    let name: String
    let icon: NSImage
    var processObjectIDs: [AudioObjectID]
    // The ones making sound right now. Taps are built from these (see VolumeController).
    var playingObjectIDs: [AudioObjectID]

    var isPlaying: Bool { !playingObjectIDs.isEmpty }

    // Nothing changed that we show or tap? (The icon is fixed per app.)
    func looksSame(as other: AudioApp) -> Bool {
        id == other.id && name == other.name
            && processObjectIDs == other.processObjectIDs && playingObjectIDs == other.playingObjectIDs
    }
}

// Watches Core Audio for processes that use audio and keeps `apps` up to date.
// Everything here runs on the main thread. The real-time audio work is in AppTap.
@MainActor
final class AudioProcessMonitor: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []

    // Per-app volume and mute, kept in step with the app list.
    let volumes = VolumeController()

    // Listener blocks we registered, kept so we can remove them later.
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    // True while a refresh is already queued for the next run-loop turn.
    private var refreshQueued = false

    // What we've worked out about each process object. None of it changes while
    // the process runs, so it's looked up once instead of on every refresh.
    private struct ProcessFacts {
        let pid: pid_t
        let bundleID: String?
        let owner: NSRunningApplication?   // the Dock app it belongs to, if any
    }
    private var facts: [AudioObjectID: ProcessFacts] = [:]
    // Whether each process is playing. Each process's own listener keeps its
    // entry current (see updatePerProcessListeners), so a refresh doesn't have to
    // ask Core Audio about every process again (each question is a round-trip
    // to the audio server).
    private var playingState: [AudioObjectID: Bool] = [:]
    // Small copies of app icons, by app key (see AppResolver.smallIcon).
    private var icons: [String: NSImage] = [:]

    // Safety net, once a second: re-checks every process while the panel is open,
    // and otherwise only apps that are turned down but not tapped yet (so they get
    // their tap the moment they start playing). Usually that's nothing to check.
    private var revalidateTimer: Timer?
    private var panelIsOpen = false

    init() {
        listenForProcessListChanges()
        refresh()
        // Before the user changes an app's volume, make sure we know which of its
        // processes are playing right now, so its tap is built from the right ones.
        volumes.willAdjust = { [weak self] appID in self?.revalidate(appIDs: [appID]) }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.safetyNetTick() }
        }
        timer.tolerance = 0.5   // lets macOS batch this wake-up with others
        RunLoop.main.add(timer, forMode: .common)
        revalidateTimer = timer
    }

    private func safetyNetTick() {
        if panelIsOpen {
            revalidate(appIDs: nil)
        } else {
            let waiting = volumes.appsWaitingForTap()
            if !waiting.isEmpty { revalidate(appIDs: waiting) }
        }
    }

    // Core Audio often sends a burst of notifications at once (an app starting
    // can change the process list and several "is playing" flags together).
    // Ask for a refresh here; it runs once, right after the burst.
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    // The panel just opened or closed. On open, re-read everything so what you
    // see is current even if a notification was missed.
    func setPanelOpen(_ open: Bool) {
        panelIsOpen = open
        volumes.setPanelOpen(open)
        if open {
            playingState.removeAll()   // ask Core Audio afresh, in case we missed something
            setNeedsRefresh()
        }
    }

    // MARK: - Building the list

    func refresh() {
        let objectIDs = CoreAudioHelpers.processObjectIDs()
        let newObjects = updatePerProcessListeners(for: objectIDs)

        // An app that starts playing the moment it appears can flip its "is
        // playing" flag before our listener for it is in place, and then we'd
        // never hear about it. So look at new processes again shortly after
        // they show up (a cheap check; a full refresh only if one changed).
        if !newObjects.isEmpty {
            for delay in [0.1, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated { self?.recheck(newObjects) }
                }
            }
        }

        // Forget processes that are gone.
        let current = Set(objectIDs)
        facts = facts.filter { current.contains($0.key) }
        playingState = playingState.filter { current.contains($0.key) }

        var grouped: [String: AudioApp] = [:]
        for objectID in objectIDs {
            guard let info = processFacts(objectID), info.pid != getpid() else { continue }
            let pid = info.pid, bundleID = info.bundleID, owner = info.owner
            let isPlaying = playing(objectID)

            // Lots of background system processes register with Core Audio.
            // Only show those if they are actually making sound.
            if owner == nil && !isPlaying { continue }

            let key = owner?.bundleIdentifier ?? bundleID ?? "pid-\(pid)"
            if var existing = grouped[key] {
                existing.processObjectIDs.append(objectID)
                if isPlaying { existing.playingObjectIDs.append(objectID) }
                grouped[key] = existing
            } else {
                grouped[key] = AudioApp(
                    id: key,
                    name: AppResolver.displayName(owner: owner, pid: pid, bundleID: bundleID),
                    icon: icon(for: key, owner: owner, pid: pid),
                    processObjectIDs: [objectID],
                    playingObjectIDs: isPlaying ? [objectID] : []
                )
            }
        }

        let sorted = grouped.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // Most notifications don't change anything we show. Only publish (and
        // make SwiftUI redraw) when the list really changed.
        let unchanged = sorted.count == apps.count && zip(sorted, apps).allSatisfy { $0.looksSame(as: $1) }
        guard !unchanged else { return }
        apps = sorted
        volumes.sync(with: apps)
    }

    private func playing(_ objectID: AudioObjectID) -> Bool {
        if let known = playingState[objectID] { return known }
        let value = CoreAudioHelpers.isRunningOutput(objectID)
        playingState[objectID] = value
        return value
    }

    // A process's "is playing" may have changed: ask Core Audio about just that
    // one, and refresh only if it really changed.
    private func updatePlaying(_ objectID: AudioObjectID) {
        let value = CoreAudioHelpers.isRunningOutput(objectID)
        guard playingState[objectID] != value else { return }
        playingState[objectID] = value
        setNeedsRefresh()
    }

    private func processFacts(_ objectID: AudioObjectID) -> ProcessFacts? {
        if let known = facts[objectID] { return known }
        guard let pid = CoreAudioHelpers.pid(of: objectID) else { return nil }
        let bundleID = CoreAudioHelpers.bundleID(of: objectID)
        let info = ProcessFacts(pid: pid, bundleID: bundleID,
                                owner: AppResolver.owningApp(pid: pid, bundleID: bundleID))
        facts[objectID] = info
        return info
    }

    private func icon(for key: String, owner: NSRunningApplication?, pid: pid_t) -> NSImage {
        if let cached = icons[key] { return cached }
        let small = AppResolver.smallIcon(AppResolver.icon(owner: owner, pid: pid))
        icons[key] = small
        return small
    }

    // Re-asks Core Audio whether processes are playing: these apps' (nil = all),
    // and refreshes right away if anything differs from what we had cached.
    private func revalidate(appIDs: [String]?) {
        let objectIDs = appIDs.map { ids in apps.filter { ids.contains($0.id) }.flatMap(\.processObjectIDs) }
            ?? Array(playingState.keys)
        var changed = false
        for objectID in objectIDs {
            let value = CoreAudioHelpers.isRunningOutput(objectID)
            if playingState[objectID] != value {
                playingState[objectID] = value
                changed = true
            }
        }
        if changed { refresh() }
    }

    // Re-asks about these processes; refreshes only if one of them changed.
    private func recheck(_ objectIDs: [AudioObjectID]) {
        for objectID in objectIDs where playingState[objectID] != nil {
            updatePlaying(objectID)
        }
    }

    // MARK: - Live updates

    // Called by Core Audio whenever a process starts or stops using audio.
    private func listenForProcessListChanges() {
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        }
    }

    // Each process also tells us when it starts or stops playing. Add a listener
    // for new processes and remove listeners for ones that are gone. Returns the
    // processes that are new since last time.
    //
    // Careful: Core Audio never sends a notification for "is running output"
    // itself (tested on macOS 14.7: the value flips, the listener stays silent).
    // What does change on every start/stop is the process's list of output
    // devices, so we listen to that and then re-read "is running output".
    private func updatePerProcessListeners(for objectIDs: [AudioObjectID]) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let current = Set(objectIDs)

        for (objectID, block) in processListeners where !current.contains(objectID) {
            AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
            processListeners[objectID] = nil
        }

        var added: [AudioObjectID] = []
        for objectID in objectIDs where processListeners[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updatePlaying(objectID) }
            }
            if AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block) == noErr {
                processListeners[objectID] = block
                added.append(objectID)
            }
        }
        return added
    }
}

// MARK: - Small wrappers around the Core Audio C API

enum CoreAudioHelpers {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // Every process Core Audio knows about (macOS 14.2+).
    static func processObjectIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func pid(of objectID: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    // True while the process is actually sending sound to an output device.
    static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func bundleID(of objectID: AudioObjectID) -> String? {
        stringProperty(kAudioProcessPropertyBundleID, of: objectID)
    }

    // The device sound currently goes to (speakers, headphones, AirPods...).
    static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func deviceUID(of deviceID: AudioObjectID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    static func deviceName(of deviceID: AudioObjectID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    // How the device is connected: built-in, Bluetooth, HDMI, AirPlay...
    static func transportType(of deviceID: AudioObjectID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        return uint32Property(deviceID, &address) ?? kAudioDeviceTransportTypeUnknown
    }

    // Which physical output a device is using, e.g. 'ispk' (internal speakers)
    // or 'hdpn' (headphone jack) on the built-in device.
    static func outputDataSource(of deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return uint32Property(deviceID, &address)
    }

    private static func uint32Property(_ objectID: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        // Core Audio hands us a string we own, so take the retained value.
        guard status == noErr, let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }
}

// MARK: - Turning a process into a real app (name + icon)

enum AppResolver {
    // Sound often comes from a helper process (e.g. "Google Chrome Helper").
    // Walk up the parent chain until we hit a normal Dock app.
    static func owningApp(pid: pid_t, bundleID: String?) -> NSRunningApplication? {
        // Best answer: ask macOS which app is "responsible" for the process (what
        // Activity Monitor uses). This is the only way to tell that Safari's sound,
        // which plays from a shared "com.apple.WebKit.GPU" helper started by the
        // system, belongs to Safari.
        if let responsible = responsiblePID(of: pid), responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible), app.activationPolicy == .regular {
            return app
        }

        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 10 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return app
            }
            current = parentPID(of: p)
            hops += 1
        }

        // Some helpers are started by the system, not by their app, so the parent
        // chain doesn't help. Try matching bundle IDs instead:
        // "com.google.Chrome.helper" belongs to "com.google.Chrome".
        guard let bundleID else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular, let appID = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix(appID + ".")
        }
    }

    static func displayName(owner: NSRunningApplication?, pid: pid_t, bundleID: String?) -> String {
        owner?.localizedName
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? bundleID
            ?? "Process \(pid)"
    }

    static func icon(owner: NSRunningApplication?, pid: pid_t) -> NSImage {
        owner?.icon
            ?? NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
    }

    // App icons come with many large sizes (up to 1024 px). The panel shows them
    // at 28 pt, so draw one 64 x 64 px copy (sharp on Retina) and keep only that.
    static func smallIcon(_ image: NSImage) -> NSImage {
        let pixels = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: rep.size)
        small.addRepresentation(rep)
        return small
    }

    // macOS's responsible_pid lookup. It's not a documented API, so we look it up
    // by name at runtime: if a future macOS removes it, this returns nil and we
    // fall back to the parent-process and bundle-ID checks.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let result = function(pid)
        return result > 0 ? result : nil
    }

    // Asks the kernel for a process's parent PID. Returns nil for launchd (PID 1).
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }
}
