import AVFoundation
import CoreAudio
import Foundation

/// One native tap and its aggregate; a replacement can start before the old one stops.
final class SystemAudioTap {
    private(set) var id = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    let uuid: UUID
    private(set) var format: AVAudioFormat!

    init(description: CATapDescription) throws {
        uuid = description.uuid
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw SystemAudioRecorder.RecorderError.tapCreationFailed(status) }
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &asbd)
            guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
                throw SystemAudioRecorder.RecorderError.tapFormatUnreadable(status)
            }
            self.format = format
            let settings: [String: Any] = [
                kAudioAggregateDeviceNameKey: "verbemo-tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            let result = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
            guard result == noErr else { throw SystemAudioRecorder.RecorderError.aggregateCreationFailed(result) }
        } catch {
            stop()
            throw error
        }
    }

    func start(queue: DispatchQueue, receive: @escaping (AVAudioPCMBuffer, Double) -> Void) throws {
        let format = format!
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) {
            _, input, time, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input,
                                               deallocator: nil) else { return }
            let timestamp = time.pointee
            let start = timestamp.mFlags.contains(.hostTimeValid)
                ? Double(AudioConvertHostTimeToNanos(timestamp.mHostTime)) / 1_000_000_000
                : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
            receive(buffer, start)
        }
        guard status == noErr, let proc else {
            throw SystemAudioRecorder.RecorderError.ioProcCreationFailed(status)
        }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw SystemAudioRecorder.RecorderError.deviceStartFailed(status) }
    }

    func stop() {
        if let proc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if id != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(id) }
        id = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
