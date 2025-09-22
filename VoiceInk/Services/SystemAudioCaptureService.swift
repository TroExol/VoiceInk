import Foundation
import AVFoundation
import CoreAudio
import os
import Combine

struct LoopbackDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channelCount: UInt32
    let transportType: UInt32

    var isVirtual: Bool {
        transportType == kAudioDeviceTransportTypeVirtual || transportType == kAudioDeviceTransportTypeAggregate
    }
}

struct SystemAudioCaptureConfiguration {
    enum OutputFormat: String, CaseIterable, Identifiable {
        case stereo
        case multiChannel

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .stereo:
                return String(localized: "settings.systemAudio.outputFormat.stereo")
            case .multiChannel:
                return String(localized: "settings.systemAudio.outputFormat.multichannel")
            }
        }
    }

    let loopbackDeviceID: AudioDeviceID
    var outputFormat: OutputFormat
    var systemLevel: Float
    var microphoneLevel: Float
    var systemChannelCount: Int
    var microphoneChannelCountOverride: Int?

    var normalizedSystemLevel: Float {
        max(0, min(systemLevel, 1))
    }

    var normalizedMicrophoneLevel: Float {
        max(0, min(microphoneLevel, 1))
    }

    var microphoneChannelCount: Int? {
        microphoneChannelCountOverride
    }
}

@MainActor
final class SystemAudioCaptureService: ObservableObject {
    static let shared = SystemAudioCaptureService()

    @Published private(set) var availableLoopbackDevices: [LoopbackDevice] = []
    @Published private(set) var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    @Published private(set) var isCapturing = false

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioCaptureService")
    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var configuration: SystemAudioCaptureConfiguration?
    private var previousInputDevice: AudioDeviceID?
    private var converter: AVAudioConverter?
    private let processingQueue = DispatchQueue(label: "com.voiceink.systemAudioCapture.processing")
    private var deviceObserver: NSObjectProtocol?

    private init() {
        refreshAvailableDevices()
        deviceObserver = AudioDeviceConfiguration.createDeviceChangeObserver { [weak self] in
            Task { @MainActor in
                self?.refreshAvailableDevices()
            }
        }
    }

    deinit {
        if let observer = deviceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refreshAvailableDevices() {
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
            logger.error("Failed to get device list size: \(status)")
            return
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard status == noErr else {
            logger.error("Failed to get device list: \(status)")
            return
        }

        var loopbackDevices: [LoopbackDevice] = []

        for deviceID in deviceIDs {
            guard isInputDevice(deviceID: deviceID) else { continue }
            let channelCount = getChannelCount(deviceID: deviceID)
            guard channelCount > 0 else { continue }
            let transportType = getTransportType(deviceID: deviceID)
            guard let name = AudioDeviceManager.shared.getDeviceName(deviceID: deviceID),
                  let uid = AudioDeviceManager.shared.getDeviceUID(deviceID: deviceID) else {
                continue
            }

            let device = LoopbackDevice(
                id: deviceID,
                uid: uid,
                name: name,
                channelCount: channelCount,
                transportType: transportType
            )
            loopbackDevices.append(device)
        }

        loopbackDevices.sort { lhs, rhs in
            if lhs.isVirtual == rhs.isVirtual {
                if lhs.channelCount == rhs.channelCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.channelCount > rhs.channelCount
            }
            return lhs.isVirtual && !rhs.isVirtual
        }

        availableLoopbackDevices = loopbackDevices
    }

    func deviceID(for uid: String) -> AudioDeviceID? {
        availableLoopbackDevices.first(where: { $0.uid == uid })?.id
    }

    func startCapture(to url: URL, configuration: SystemAudioCaptureConfiguration) throws {
        guard !isCapturing else {
            logger.warning("Capture already running")
            return
        }

        guard availableLoopbackDevices.contains(where: { $0.id == configuration.loopbackDeviceID }) else {
            logger.error("Requested loopback device is not available")
            throw NSError(domain: "SystemAudioCaptureService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Loopback device not available"])
        }

        previousInputDevice = AudioDeviceConfiguration.getDefaultInputDevice()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var tapInstalled = false

        do {
            try AudioDeviceConfiguration.setDefaultInputDevice(configuration.loopbackDeviceID)

            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard Int(inputFormat.channelCount) >= configuration.systemChannelCount else {
                logger.error("Loopback device does not expose enough channels. Expected at least \(configuration.systemChannelCount), got \(inputFormat.channelCount)")
                throw NSError(domain: "SystemAudioCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Loopback device has insufficient channels"])
            }

            let outputFormat: AVAudioFormat
            switch configuration.outputFormat {
            case .stereo:
                guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                       sampleRate: inputFormat.sampleRate,
                                                       channels: 2,
                                                       interleaved: false) else {
                    throw NSError(domain: "SystemAudioCaptureService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to create stereo format"])
                }
                outputFormat = stereoFormat
            case .multiChannel:
                outputFormat = inputFormat
            }

            outputFile = try AVAudioFile(forWriting: url, settings: outputFormat.settings)

            self.configuration = configuration
            converter = nil

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                guard let copiedBuffer = self.copyBuffer(buffer) else { return }
                self.processingQueue.async { [weak self] in
                    self?.process(buffer: copiedBuffer)
                }
            }
            tapInstalled = true

            try engine.start()

            self.engine = engine
            isCapturing = true
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            outputFile = nil
            self.configuration = nil
            converter = nil
            if let previous = previousInputDevice {
                try? AudioDeviceConfiguration.setDefaultInputDevice(previous)
            }
            previousInputDevice = nil
            throw error
        }
    }

    func stopCapture() {
        guard isCapturing else { return }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        processingQueue.sync {
            outputFile = nil
            configuration = nil
            converter = nil
        }

        if let previous = previousInputDevice {
            try? AudioDeviceConfiguration.setDefaultInputDevice(previous)
        }

        previousInputDevice = nil
        isCapturing = false
        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    }

    func updateLevels(systemLevel: Float, microphoneLevel: Float) {
        guard var config = configuration else { return }
        config.systemLevel = systemLevel
        config.microphoneLevel = microphoneLevel
        configuration = config
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let config = configuration, let outputFile = outputFile else { return }

        let floatBuffer: AVAudioPCMBuffer
        if buffer.format.commonFormat == .pcmFormatFloat32 && !buffer.format.isInterleaved {
            floatBuffer = buffer
        } else {
            if converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                                   sampleRate: buffer.format.sampleRate,
                                                                                   channels: buffer.format.channelCount,
                                                                                   interleaved: false)!)
            }

            guard let converter = converter,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                                         frameCapacity: buffer.frameCapacity) else {
                logger.error("Failed to create converter or buffer for conversion")
                return
            }

            convertedBuffer.frameLength = buffer.frameLength
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            do {
                try converter.convert(to: convertedBuffer, error: nil, withInputFrom: inputBlock)
            } catch {
                logger.error("Conversion error: \(error.localizedDescription)")
                return
            }
            floatBuffer = convertedBuffer
        }

        guard let floatData = floatBuffer.floatChannelData else { return }

        let totalChannels = Int(floatBuffer.format.channelCount)
        if totalChannels == 0 { return }

        let systemChannelCount = min(config.systemChannelCount, totalChannels)
        let microphoneChannelCount: Int
        if let override = config.microphoneChannelCount {
            microphoneChannelCount = min(max(override, 0), totalChannels - systemChannelCount)
        } else {
            microphoneChannelCount = max(0, totalChannels - systemChannelCount)
        }

        let frameLength = Int(floatBuffer.frameLength)
        guard frameLength > 0 else { return }

        let outputFormat = outputFile.processingFormat
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameLength)) else {
            logger.error("Failed to create output buffer")
            return
        }
        outputBuffer.frameLength = AVAudioFrameCount(frameLength)

        guard let outputData = outputBuffer.floatChannelData else { return }

        switch config.outputFormat {
        case .stereo:
            mixToStereo(floatData: floatData,
                        systemChannels: systemChannelCount,
                        microphoneChannels: microphoneChannelCount,
                        frameLength: frameLength,
                        systemLevel: config.normalizedSystemLevel,
                        microphoneLevel: config.normalizedMicrophoneLevel,
                        outputData: outputData)
        case .multiChannel:
            mixToMultichannel(floatData: floatData,
                              totalChannels: totalChannels,
                              systemChannels: systemChannelCount,
                              microphoneChannels: microphoneChannelCount,
                              frameLength: frameLength,
                              systemLevel: config.normalizedSystemLevel,
                              microphoneLevel: config.normalizedMicrophoneLevel,
                              outputData: outputData)
        }

        do {
            try outputFile.write(from: outputBuffer)
            updateAudioMeter(with: outputBuffer)
        } catch {
            logger.error("Failed to write buffer: \(error.localizedDescription)")
        }
    }

    private func mixToStereo(floatData: UnsafePointer<UnsafeMutablePointer<Float>>, systemChannels: Int, microphoneChannels: Int, frameLength: Int, systemLevel: Float, microphoneLevel: Float, outputData: UnsafePointer<UnsafeMutablePointer<Float>>) {
        let left = outputData[0]
        let right = outputData[1]

        for frame in 0..<frameLength {
            let systemLeft: Float
            let systemRight: Float

            if systemChannels >= 2 {
                systemLeft = floatData[0][frame]
                systemRight = floatData[1][frame]
            } else if systemChannels == 1 {
                systemLeft = floatData[0][frame]
                systemRight = systemLeft
            } else {
                systemLeft = 0
                systemRight = 0
            }

            var microphoneSample: Float = 0
            if microphoneChannels > 0 {
                var accumulator: Float = 0
                for channel in 0..<microphoneChannels {
                    let index = systemChannels + channel
                    accumulator += floatData[index][frame]
                }
                microphoneSample = accumulator / Float(microphoneChannels)
            }

            let mixedLeft = clamp(sample: systemLeft * systemLevel + microphoneSample * microphoneLevel)
            let mixedRight = clamp(sample: systemRight * systemLevel + microphoneSample * microphoneLevel)

            left[frame] = mixedLeft
            right[frame] = mixedRight
        }
    }

    private func mixToMultichannel(floatData: UnsafePointer<UnsafeMutablePointer<Float>>, totalChannels: Int, systemChannels: Int, microphoneChannels: Int, frameLength: Int, systemLevel: Float, microphoneLevel: Float, outputData: UnsafePointer<UnsafeMutablePointer<Float>>) {
        for channel in 0..<totalChannels {
            let isSystemChannel = channel < systemChannels
            let gain = isSystemChannel ? systemLevel : microphoneLevel
            let inputChannel = floatData[channel]
            let outputChannel = outputData[channel]

            for frame in 0..<frameLength {
                outputChannel[frame] = clamp(sample: inputChannel[frame] * gain)
            }
        }
    }

    private func clamp(sample: Float) -> Float {
        min(max(sample, -1.0), 1.0)
    }

    private func updateAudioMeter(with buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        var sumSquares: Float = 0
        var peak: Float = 0

        for channel in 0..<channelCount {
            let channelData = data[channel]
            for frame in 0..<frameLength {
                let sample = channelData[frame]
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
        }

        let meanSquare = sumSquares / Float(frameLength * channelCount)
        let rms = sqrt(meanSquare)
        let averageDb = 20 * log10(max(rms, 0.000_000_1))
        let peakDb = 20 * log10(max(peak, 0.000_000_1))

        let minVisibleDb: Float = -60
        let maxVisibleDb: Float = 0

        let normalizedAverage: Float
        if averageDb < minVisibleDb {
            normalizedAverage = 0
        } else if averageDb >= maxVisibleDb {
            normalizedAverage = 1
        } else {
            normalizedAverage = (averageDb - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakDb < minVisibleDb {
            normalizedPeak = 0
        } else if peakDb >= maxVisibleDb {
            normalizedPeak = 1
        } else {
            normalizedPeak = (peakDb - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        Task { @MainActor in
            self.audioMeter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))
        }
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        if buffer.format.isInterleaved {
            if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
                let byteCount = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
                memcpy(destination.pointee, source.pointee, byteCount)
            } else if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
                let byteCount = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
                memcpy(destination.pointee, source.pointee, byteCount)
            }
        } else {
            if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
                let channelCount = Int(buffer.format.channelCount)
                for channel in 0..<channelCount {
                    let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
                    memcpy(destination[channel], source[channel], byteCount)
                }
            } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
                let channelCount = Int(buffer.format.channelCount)
                for channel in 0..<channelCount {
                    let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
                    memcpy(destination[channel], source[channel], byteCount)
                }
            }
        }

        return copy
    }

    private func isInputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard status == noErr else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard status == noErr else { return false }

        let audioBufferList = bufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func getChannelCount(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard status == noErr else { return 0 }

        let audioBufferList = bufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private func getTransportType(deviceID: AudioDeviceID) -> UInt32 {
        var transportType = UInt32(0)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &transportType)
        if status != noErr {
            return 0
        }

        return transportType
    }
}
