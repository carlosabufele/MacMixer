import AudioToolbox
import CoreAudio
import Foundation

// The Mac's current output device (speakers, headphones, AirPods...) and its
// volume and mute. Follows the system default device, and stays in sync when
// the volume is changed elsewhere (keyboard keys, Control Center).
@MainActor
final class OutputDevice: ObservableObject {
    @Published private(set) var name = "No output device"
    @Published private(set) var symbolName = "speaker.wave.2"   // SF Symbol for the device type
    @Published private(set) var volume: Float = 0               // 0.0 ... 1.0
    @Published private(set) var isMuted = false
    @Published private(set) var hasVolume = false               // false for some HDMI / aggregate devices
    @Published private(set) var canMute = false

    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    // "Virtual main volume" is the one slider macOS itself shows: it moves all
    // of the device's channels together and keeps their balance.
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    // Also watched, so we notice every way the volume or device can change:
    // the device's own volume control (some devices only report changes here)
    // and its data source (e.g. headphones plugged into the built-in jack).
    private var watchedExtras = [
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain),
    ]

    // One listener block for everything on the current device; re-read it all.
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.readState() }
    }

    init() {
        // Follow the default output device when it changes (e.g. AirPods connect).
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.switchToDefaultDevice() }
        }
        switchToDefaultDevice()
    }

    func setVolume(_ value: Float) {
        guard hasVolume else { return }
        var newValue = max(0, min(1, value))
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, size, &newValue)
        volume = newValue
        // Dragging the slider up un-mutes, like the macOS sound slider.
        if isMuted && newValue > 0 { setMuted(false) }
    }

    func toggleMute() { setMuted(!isMuted) }

    private func setMuted(_ muted: Bool) {
        guard canMute else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    // MARK: - Following the device

    private func switchToDefaultDevice() {
        // Stop listening to the old device.
        if deviceID != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, deviceListener)
            AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, deviceListener)
            for index in watchedExtras.indices {
                AudioObjectRemovePropertyListenerBlock(deviceID, &watchedExtras[index], DispatchQueue.main, deviceListener)
            }
        }

        deviceID = CoreAudioHelpers.defaultOutputDeviceID() ?? AudioObjectID(kAudioObjectUnknown)

        if deviceID != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, deviceListener)
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, deviceListener)
            for index in watchedExtras.indices where AudioObjectHasProperty(deviceID, &watchedExtras[index]) {
                AudioObjectAddPropertyListenerBlock(deviceID, &watchedExtras[index], DispatchQueue.main, deviceListener)
            }
        }
        readState()
    }

    // Re-read the device's name, volume and mute (e.g. when the panel opens).
    func refresh() { readState() }

    private func readState() {
        guard deviceID != kAudioObjectUnknown else {
            name = "No output device"
            symbolName = "speaker.slash"
            hasVolume = false
            canMute = false
            return
        }

        name = CoreAudioHelpers.deviceName(of: deviceID) ?? "Unknown device"
        symbolName = Self.symbol(for: deviceID, name: name)

        hasVolume = Self.isSettable(deviceID, &volumeAddress)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if hasVolume, AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &value) == noErr {
            volume = value
        }

        canMute = Self.isSettable(deviceID, &muteAddress)
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        isMuted = canMute
            && AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &mute) == noErr
            && mute != 0
    }

    private static func isSettable(_ deviceID: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    // Picks an SF Symbol from how the device is connected and what it's called.
    private static func symbol(for deviceID: AudioObjectID, name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        if lowered.contains("beats pill") || lowered.contains("pill") { return "beats.pill" }

        switch CoreAudioHelpers.transportType(of: deviceID) {
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in output is either the speakers or the headphone jack.
            return CoreAudioHelpers.outputDataSource(of: deviceID) == fourCC("hdpn") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return lowered.contains("speaker") ? "hifispeaker" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return "hifispeaker"
        }
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
