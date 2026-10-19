import CoreAudio
import Foundation
import os

let tapLog = Logger(subsystem: "com.skip.MacMixer", category: "tap")

struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (error \(status))" }
}

// Controls the volume of one app.
//
// How it works:
// 1. A "process tap" grabs the app's sound and silences the original
//    (muteBehavior = .mutedWhenTapped), so you don't hear it twice.
// 2. A private "aggregate device" combines that tap with your real speakers.
// 3. Core Audio calls our IOProc block on a real-time audio thread for every
//    few milliseconds of sound. We copy the tapped sound to the speakers,
//    multiplied by the gain (0.0 = silent, 1.0 = original volume).
//
// Real-time rule: the IOProc block must never allocate memory, take locks, or
// touch Swift objects. So it only uses raw pointers to a few numbers.
//
// Threads: start() and stop() run on VolumeController's tap queue, one at a time.
// setGain() / takePeak() are called from the main thread and only touch the
// shared numbers, which is why it's safe to mark this @unchecked Sendable.
final class AppTap: @unchecked Sendable {
    let processObjectIDs: [AudioObjectID]

    // The output device this tap plays to (set by start()). When the Mac's
    // default output changes, taps for the old device get rebuilt.
    private(set) var outputUID: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // gain[0] = target gain, written by the slider (main thread).
    // gain[1] = gain the audio thread applied last, used to fade smoothly.
    private let gain: UnsafeMutablePointer<Float>

    // How many times the IOProc has run. Core Audio only runs it while the app
    // is actually producing sound, so if it stays 0 while the app is playing,
    // the tap is dead and the app is NOT being muted.
    // Written only by the audio thread; read by the main thread.
    private let callbackCount: UnsafeMutablePointer<UInt32>

    // Loudest input sample since the main thread last asked (see takePeak()).
    // Lets us tell "playing" from "running but silent".
    private let inputPeak: UnsafeMutablePointer<Float>

    var hasDeliveredAudio: Bool { callbackCount.pointee > 0 }

    // Returns the loudest sample since the last call, and starts over.
    // A race with the audio thread can at worst lose one buffer's peak,
    // which is fine for a "playing or not" indicator.
    func takePeak() -> Float {
        let peak = inputPeak.pointee
        inputPeak.pointee = 0
        return peak
    }

    init(processObjectIDs: [AudioObjectID], gain initialGain: Float) {
        self.processObjectIDs = processObjectIDs
        gain = .allocate(capacity: 2)
        gain[0] = initialGain
        gain[1] = initialGain
        callbackCount = .allocate(capacity: 1)
        callbackCount.pointee = 0
        inputPeak = .allocate(capacity: 1)
        inputPeak.pointee = 0
    }

    deinit {
        stop()
        gain.deallocate()
        callbackCount.deallocate()
        inputPeak.deallocate()
    }

    func setGain(_ value: Float) {
        gain[0] = max(0, min(1, value))
    }

    func start() throws {
        // 1. The tap. The first time this runs, macOS asks for the
        //    "System Audio Recording" permission.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "MacMixer tap"

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError(step: "Creating the tap", status: status) }
        tapLog.debug("Created tap \(self.tapID) for processes \(self.processObjectIDs, privacy: .public), format: \(Self.tapFormatDescription(self.tapID), privacy: .public)")

        // 2. The aggregate device: your current output device plus the tap.
        guard let outputID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outputUID = CoreAudioHelpers.deviceUID(of: outputID) else {
            throw TapError(step: "Finding the output device", status: -1)
        }
        self.outputUID = outputUID
        tapLog.debug("Output device \(outputID) uid=\(outputUID, privacy: .public)")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacMixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,   // hidden from other apps
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    // Lets Core Audio smooth out tiny clock differences
                    // between the app and your speakers.
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError(step: "Creating the aggregate device", status: status) }

        // 3. The audio callback. Capture only the raw pointer, nothing else.
        let gain = self.gain
        let callbackCount = self.callbackCount
        let inputPeak = self.inputPeak
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            callbackCount.pointee &+= 1
            AppTap.render(input: input, output: output, gain: gain, peak: inputPeak)
        }
        guard status == noErr else { throw TapError(step: "Creating the audio callback", status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(step: "Starting audio", status: status) }
        tapLog.debug("Started aggregate device \(self.aggregateID)")
    }

    // For the log: the tap's sample rate and channel count, e.g. "48000 Hz, 2 ch".
    private static func tapFormatDescription(_ tapID: AudioObjectID) -> String {
        var address = CoreAudioHelpers.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { return "unknown (error \(status))" }
        return "\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch"
    }

    // Tear everything down in reverse order. Once the tap is destroyed,
    // macOS un-mutes the app automatically.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // Runs on the real-time audio thread. Copies tapped sound to the output,
    // fading from the previous gain to the new one across the buffer so
    // slider moves don't click.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: UnsafeMutablePointer<Float>,
                               peak: UnsafeMutablePointer<Float>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = gain[0]
        let startGain = gain[1]
        var loudest = peak.pointee

        for index in 0..<outputs.count {
            guard let outData = outputs[index].mData else { continue }
            let outSamples = outData.assumingMemoryBound(to: Float.self)
            let outCount = Int(outputs[index].mDataByteSize) / MemoryLayout<Float>.size

            guard index < inputs.count, let inData = inputs[index].mData else {
                outSamples.update(repeating: 0, count: outCount)
                continue
            }
            let inSamples = inData.assumingMemoryBound(to: Float.self)
            let count = min(outCount, Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size)

            let step = count > 0 ? (target - startGain) / Float(count) : 0
            var current = startGain
            for n in 0..<count {
                current += step
                outSamples[n] = inSamples[n] * current
                loudest = max(loudest, abs(inSamples[n]))
            }
            if count < outCount {
                (outSamples + count).update(repeating: 0, count: outCount - count)
            }
        }
        gain[1] = target
        peak.pointee = loudest
    }
}
