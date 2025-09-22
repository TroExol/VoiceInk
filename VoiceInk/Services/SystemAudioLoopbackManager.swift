import Foundation
import CoreAudio
import AVFoundation
import os

struct LoopbackAudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channelCount: UInt32

    var displayName: String { name }
}

final class SystemAudioLoopbackManager: ObservableObject {
    static let shared = SystemAudioLoopbackManager()

    @Published private(set) var availableDevices: [LoopbackAudioDevice] = []

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioLoopbackManager")
    private var deviceObserver: NSObjectProtocol?

    private init() {
        loadDevices()
        deviceObserver = AudioDeviceConfiguration.createDeviceChangeObserver { [weak self] in
            self?.loadDevices()
        }
    }

    deinit {
        if let observer = deviceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadDevices() {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else {
            logger.error("Failed to get audio device list size: \(status)")
            return
        }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &devices
        )

        guard status == noErr else {
            logger.error("Failed to get audio devices: \(status)")
            return
        }

        let discoveredDevices: [LoopbackAudioDevice] = devices.compactMap { deviceID in
            guard let name = getDeviceName(deviceID: deviceID),
                  let uid = getDeviceUID(deviceID: deviceID),
                  supportsOutput(deviceID: deviceID) else {
                return nil
            }

            let channelCount = outputChannelCount(for: deviceID)
            if channelCount == 0 {
                return nil
            }

            // Prefer devices that provide both input and output (loopback style)
            let hasInput = supportsInput(deviceID: deviceID)
            if !hasInput && !isKnownLoopbackDeviceName(name) {
                return nil
            }

            return LoopbackAudioDevice(id: deviceID, uid: uid, name: name, channelCount: channelCount)
        }

        DispatchQueue.main.async { [weak self] in
            self?.availableDevices = discoveredDevices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func deviceID(for uid: String) -> AudioDeviceID? {
        return availableDevices.first(where: { $0.uid == uid })?.id
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var nameRef: CFString? = nil
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &nameRef
        )

        if status != noErr {
            logger.error("Failed to get device name for device \(deviceID): \(status)")
            return nil
        }

        return nameRef as String?
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uidRef: CFString? = nil
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &uidRef
        )

        if status != noErr {
            logger.error("Failed to get device UID for device \(deviceID): \(status)")
            return nil
        }

        return uidRef as String?
    }

    private func supportsOutput(deviceID: AudioDeviceID) -> Bool {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        if status != noErr {
            logger.error("Failed to query output stream configuration size for device \(deviceID): \(status)")
            return false
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferListPointer)
        if status != noErr {
            logger.error("Failed to get output stream configuration for device \(deviceID): \(status)")
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func supportsInput(deviceID: AudioDeviceID) -> Bool {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        if status != noErr {
            return false
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferListPointer)
        if status != noErr {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func outputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        if status != noErr {
            logger.error("Failed to get output stream configuration size for device \(deviceID): \(status)")
            return 0
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferListPointer)
        if status != noErr {
            logger.error("Failed to get output stream configuration for device \(deviceID): \(status)")
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private func isKnownLoopbackDeviceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("loopback") || lowered.contains("blackhole") || lowered.contains("soundflower") || lowered.contains("vb-audio")
    }
}
