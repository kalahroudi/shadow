// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox
import ShadowKit

/// You: the microphone through AVAudioEngine, on the device chosen in Settings (R5). Nothing runs after `stop()`.
final class MicAudioSource: AudioSource, @unchecked Sendable {
    private let deviceUID: @Sendable () -> String?
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<TimedBuffer>.Continuation?

    /// `deviceUID` is read at start; nil or an unknown UID uses the system default input.
    init(deviceUID: @escaping @Sendable () -> String? = { nil }) { self.deviceUID = deviceUID }

    func start(clock: SessionClock) async throws -> AsyncStream<TimedBuffer> {
        await stop()
        guard await AVAudioApplication.requestRecordPermission() else {
            throw UserFacingError("Shadow needs Microphone access. Allow it in System Settings > Privacy & Security > Microphone.")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID(), let id = Self.deviceID(forUID: uid), let unit = input.audioUnit {
            var device = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { AppLog.info("microphone device not applied (status \(status)); using default input") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw UserFacingError("Shadow couldn't find a working microphone.")
        }
        let (buffers, continuation) = AsyncStream<TimedBuffer>.makeStream(bufferingPolicy: .bufferingNewest(256))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : AudioConversion.hostNow()
            let time = clock.time(hostSeconds: host, hostNow: AudioConversion.hostNow())
            continuation.yield(TimedBuffer(buffer: buffer, time: max(0, time)))
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            AppLog.error(error, context: "start microphone")
            throw UserFacingError("Shadow couldn't start the microphone. Check Microphone access in System Settings.")
        }
        lock.withLock { self.engine = engine; self.continuation = continuation }
        return buffers
    }

    func stop() async {
        let (engine, continuation) = lock.withLock { () -> (AVAudioEngine?, AsyncStream<TimedBuffer>.Continuation?) in
            defer { self.engine = nil; self.continuation = nil }
            return (self.engine, self.continuation)
        }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        continuation?.finish()
    }

    /// Core Audio device ID for a persisted UID.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}
