import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

struct SystemAudioCaptureConfiguration {
    let captureSystemAudio: Bool
    let loopbackDeviceID: AudioDeviceID?
    let outputFormat: AVAudioFormat
    let microphoneLevel: Float
    let systemLevel: Float
}

@MainActor
final class SystemAudioCaptureService: NSObject, ObservableObject {
    private struct PendingBuffer {
        var buffer: AVAudioPCMBuffer
        var offset: AVAudioFramePosition = 0

        var remainingFrames: AVAudioFrameCount {
            guard buffer.frameLength > offset else { return 0 }
            return AVAudioFrameCount(buffer.frameLength - offset)
        }

        mutating func consume(_ frames: AVAudioFrameCount) {
            offset += AVAudioFramePosition(frames)
        }
    }

    static let shared = SystemAudioCaptureService()

    @Published private(set) var isCapturing = false

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var configuration: SystemAudioCaptureConfiguration?
    private var systemAudioUnit: AudioUnit?
    private var microphoneConverter: AVAudioConverter?

    private let mixQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.systemAudioMixQueue")
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioCaptureService")

    private var microphoneBuffers: [PendingBuffer] = []
    private var systemBuffers: [PendingBuffer] = []

    var onAudioMeterUpdate: ((AudioMeter) -> Void)?

    func startCapture(configuration: SystemAudioCaptureConfiguration, outputURL: URL) async throws {
        stopCapture()

        self.configuration = configuration
        audioFile = try AVAudioFile(forWriting: outputURL, settings: configuration.outputFormat.settings)

        do {
            try startMicrophoneCapture()

            if configuration.captureSystemAudio {
                try startSystemAudioCapture()
            } else {
                systemAudioUnit = nil
                systemBuffers.removeAll()
            }

            isCapturing = true
        } catch {
            stopCapture()
            throw error
        }
    }

    func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        if let audioUnit = systemAudioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            systemAudioUnit = nil
        }

        mixQueue.sync {
            processPendingBuffersLocked(flush: true)
            microphoneBuffers.removeAll()
            systemBuffers.removeAll()
        }

        microphoneConverter = nil
        audioFile = nil
        configuration = nil
        isCapturing = false
    }

    // MARK: - Setup

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicrophoneBuffer(buffer)
        }

        try engine.start()
    }

    private func startSystemAudioCapture() throws {
        guard let configuration = configuration else { return }

        var audioUnitDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &audioUnitDescription) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement), userInfo: [NSLocalizedDescriptionKey: "Unable to locate HAL output component"])
        }

        var newAudioUnit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &newAudioUnit)
        guard status == noErr, let audioUnit = newAudioUnit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to create HAL output instance"])
        }

        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to enable input on HAL output"])
        }

        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to disable output on HAL output"])
        }

        if let deviceID = configuration.loopbackDeviceID {
            var mutableDeviceID = deviceID
            status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to bind loopback device"])
            }
        }

        var streamDescription = configuration.outputFormat.streamDescription.pointee
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to configure HAL stream format"])
        }

        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to configure HAL input format"])
        }

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
                let unmanaged = Unmanaged<SystemAudioCaptureService>.fromOpaque(inRefCon)
                let service = unmanaged.takeUnretainedValue()
                return service.renderSystemAudio(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, frameCount: inNumberFrames)
            },
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to set HAL render callback"])
        }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to initialize HAL"])
        }

        status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to start HAL output"])
        }

        systemAudioUnit = audioUnit
    }

    private func renderSystemAudio(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timeStamp: UnsafePointer<AudioTimeStamp>?, busNumber: UInt32, frameCount: UInt32) -> OSStatus {
        guard let audioUnit = systemAudioUnit,
              let configuration = configuration,
              frameCount > 0 else {
            return noErr
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: configuration.outputFormat, frameCapacity: frameCount) else {
            return kAudio_ParamError
        }
        buffer.frameLength = frameCount

        let listPointer = buffer.mutableAudioBufferList
        let status = AudioUnitRender(audioUnit, ioActionFlags, timeStamp, 1, frameCount, listPointer.unsafeMutablePointer)
        if status != noErr {
            logger.error("System audio render error: \(status)")
            return status
        }

        enqueueSystemBuffer(buffer)
        return noErr
    }

    // MARK: - Buffer Handling

    private func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let configuration = configuration else { return }

        guard let converted = convert(buffer: buffer, using: &microphoneConverter, targetFormat: configuration.outputFormat) else {
            return
        }

        enqueueMicrophoneBuffer(converted)
    }

    private func enqueueMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        let pending = PendingBuffer(buffer: buffer)
        mixQueue.async { [weak self] in
            guard let self = self else { return }
            self.microphoneBuffers.append(pending)
            self.processPendingBuffersLocked(flush: false)
        }
    }

    private func enqueueSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        let pending = PendingBuffer(buffer: buffer)
        mixQueue.async { [weak self] in
            guard let self = self else { return }
            self.systemBuffers.append(pending)
            self.processPendingBuffersLocked(flush: false)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: inout AVAudioConverter?, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat {
            return duplicate(buffer: buffer)
        }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }

        guard let converter = converter,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        convertedBuffer.frameLength = buffer.frameLength

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            logger.error("Conversion error: \(error.localizedDescription)")
            return nil
        }

        return duplicate(buffer: convertedBuffer)
    }

    private func duplicate(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        if let floatData = buffer.floatChannelData, let copyData = copy.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            for channel in 0..<channels {
                copyData[channel].assign(from: floatData[channel], count: frames)
            }
        } else if let int16Data = buffer.int16ChannelData, let copyData = copy.int16ChannelData {
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            for channel in 0..<channels {
                copyData[channel].assign(from: int16Data[channel], count: frames)
            }
        } else if let int32Data = buffer.int32ChannelData, let copyData = copy.int32ChannelData {
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            for channel in 0..<channels {
                copyData[channel].assign(from: int32Data[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    private func processPendingBuffersLocked(flush: Bool) {
        dispatchPrecondition(condition: .onQueue(mixQueue))
        guard let configuration = configuration, let audioFile = audioFile else { return }

        while let firstMicBuffer = microphoneBuffers.first {
            var framesToProcess = firstMicBuffer.remainingFrames
            if framesToProcess == 0 {
                microphoneBuffers.removeFirst()
                continue
            }

            var systemBuffer: PendingBuffer?
            var useSilence = false

            if configuration.captureSystemAudio {
                while let firstSystemBuffer = systemBuffers.first, firstSystemBuffer.remainingFrames == 0 {
                    systemBuffers.removeFirst()
                }

                if let firstSystemBuffer = systemBuffers.first {
                    framesToProcess = min(framesToProcess, firstSystemBuffer.remainingFrames)
                    systemBuffer = firstSystemBuffer
                } else if flush {
                    useSilence = true
                } else {
                    break
                }
            }

            guard framesToProcess > 0 else { break }

            guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: configuration.outputFormat, frameCapacity: framesToProcess) else {
                break
            }
            mixedBuffer.frameLength = framesToProcess

            mixBuffers(
                destination: mixedBuffer,
                microphoneBuffer: firstMicBuffer,
                systemBuffer: systemBuffer,
                frames: framesToProcess,
                useSilenceForMissingSystem: useSilence,
                configuration: configuration
            )

            do {
                try audioFile.write(from: mixedBuffer)
                updateMeter(with: mixedBuffer)
            } catch {
                logger.error("Failed to write mixed buffer: \(error.localizedDescription)")
            }

            microphoneBuffers[0].consume(framesToProcess)
            if microphoneBuffers[0].remainingFrames == 0 {
                microphoneBuffers.removeFirst()
            }

            if configuration.captureSystemAudio && !useSilence {
                systemBuffers[0].consume(framesToProcess)
                if systemBuffers[0].remainingFrames == 0 {
                    systemBuffers.removeFirst()
                }
            }
        }

        if flush {
            microphoneBuffers.removeAll()
            systemBuffers.removeAll()
        }
    }

    private func mixBuffers(
        destination: AVAudioPCMBuffer,
        microphoneBuffer: PendingBuffer,
        systemBuffer: PendingBuffer?,
        frames: AVAudioFrameCount,
        useSilenceForMissingSystem: Bool,
        configuration: SystemAudioCaptureConfiguration
    ) {
        guard let outputData = destination.floatChannelData else { return }

        let micChannels = Int(microphoneBuffer.buffer.format.channelCount)
        let systemChannels = Int(systemBuffer?.buffer.format.channelCount ?? 0)
        let outputChannels = Int(destination.format.channelCount)

        let microphoneData = microphoneBuffer.buffer.floatChannelData
        let systemData = systemBuffer?.buffer.floatChannelData

        for channel in 0..<outputChannels {
            let outputChannel = outputData[channel]
            let micChannelIndex = min(channel, max(micChannels - 1, 0))
            let micPointer = microphoneData?[micChannelIndex].advanced(by: Int(microphoneBuffer.offset))
            let systemChannelIndex = min(channel, max(systemChannels - 1, 0))
            let systemPointer = systemData?[systemChannelIndex].advanced(by: Int(systemBuffer?.offset ?? 0))

            for frame in 0..<Int(frames) {
                let micSample = micPointer?[frame] ?? 0
                let systemSample: Float
                if let systemPointer = systemPointer, !useSilenceForMissingSystem {
                    systemSample = systemPointer[frame]
                } else {
                    systemSample = 0
                }

                outputChannel[frame] = micSample * configuration.microphoneLevel + systemSample * configuration.systemLevel
            }
        }
    }

    private func updateMeter(with buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var peak: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
        }

        let rms = sqrt(sumSquares / Float(frameLength * max(channelCount, 1)))
        let averageDb = 20 * log10(max(rms, Float.leastNonzeroMagnitude))
        let peakDb = 20 * log10(max(peak, Float.leastNonzeroMagnitude))

        let normalizedAverage = normalize(decibels: averageDb)
        let normalizedPeak = normalize(decibels: peakDb)

        let meter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onAudioMeterUpdate?(meter)
        }
    }

    private func normalize(decibels: Float) -> Float {
        let minDb: Float = -60.0
        let maxDb: Float = 0.0

        if decibels <= minDb {
            return 0
        }
        if decibels >= maxDb {
            return 1
        }
        return (decibels - minDb) / (maxDb - minDb)
    }
}
