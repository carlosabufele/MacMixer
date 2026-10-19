import CoreAudio
import Foundation

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
// touch Swift objects. So it only uses a raw pointer to two Floats.
final class AppTap {
    let processObjectIDs: [AudioObjectID]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // gain[0] = target gain, written by the slider (main thread).
    // gain[1] = gain the audio thread applied last, used to fade smoothly.
    private let gain: UnsafeMutablePointer<Float>

    init(processObjectIDs: [AudioObjectID], gain initialGain: Float) {
        self.processObjectIDs = processObjectIDs
        gain = .allocate(capacity: 2)
        gain[0] = initialGain
        gain[1] = initialGain
    }

    deinit {
        stop()
        gain.deallocate()
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

        // 2. The aggregate device: your current output device plus the tap.
        guard let outputID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outputUID = CoreAudioHelpers.deviceUID(of: outputID) else {
            throw TapError(step: "Finding the output device", status: -1)
        }

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
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, gain: gain)
        }
        guard status == noErr else { throw TapError(step: "Creating the audio callback", status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(step: "Starting audio", status: status) }
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
                               gain: UnsafeMutablePointer<Float>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = gain[0]
        let startGain = gain[1]

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
            }
            if count < outCount {
                (outSamples + count).update(repeating: 0, count: outCount - count)
            }
        }
        gain[1] = target
    }
}
