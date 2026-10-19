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
    var isPlaying: Bool
    var processObjectIDs: [AudioObjectID]
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

    init() {
        listenForProcessListChanges()
        refresh()
    }

    // MARK: - Building the list

    func refresh() {
        let objectIDs = CoreAudioHelpers.processObjectIDs()
        updatePerProcessListeners(for: objectIDs)

        var grouped: [String: AudioApp] = [:]
        for objectID in objectIDs {
            guard let pid = CoreAudioHelpers.pid(of: objectID), pid != getpid() else { continue }

            let bundleID = CoreAudioHelpers.bundleID(of: objectID)
            let isPlaying = CoreAudioHelpers.isRunningOutput(objectID)
            let owner = AppResolver.owningApp(pid: pid, bundleID: bundleID)

            // Lots of background system processes register with Core Audio.
            // Only show those if they are actually making sound.
            if owner == nil && !isPlaying { continue }

            let key = owner?.bundleIdentifier ?? bundleID ?? "pid-\(pid)"
            if var existing = grouped[key] {
                existing.isPlaying = existing.isPlaying || isPlaying
                existing.processObjectIDs.append(objectID)
                grouped[key] = existing
            } else {
                grouped[key] = AudioApp(
                    id: key,
                    name: AppResolver.displayName(owner: owner, pid: pid, bundleID: bundleID),
                    icon: AppResolver.icon(owner: owner, pid: pid),
                    isPlaying: isPlaying,
                    processObjectIDs: [objectID]
                )
            }
        }

        apps = grouped.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        volumes.sync(with: apps)
    }

    // MARK: - Live updates

    // Called by Core Audio whenever a process starts or stops using audio.
    private func listenForProcessListChanges() {
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // Each process also tells us when it starts/stops *playing* (IsRunningOutput).
    // Add a listener for new processes and remove listeners for ones that are gone.
    private func updatePerProcessListeners(for objectIDs: [AudioObjectID]) {
        var address = CoreAudioHelpers.address(kAudioProcessPropertyIsRunningOutput)
        let current = Set(objectIDs)

        for (objectID, block) in processListeners where !current.contains(objectID) {
            AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
            processListeners[objectID] = nil
        }

        for objectID in objectIDs where processListeners[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block) == noErr {
                processListeners[objectID] = block
            }
        }
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
