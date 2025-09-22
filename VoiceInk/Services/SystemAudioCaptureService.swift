import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine
import os

final class SystemAudioCaptureService: ObservableObject {
    enum SystemAudioCaptureError: LocalizedError {
        case alreadyRunning
        case missingLoopbackDevice
        case failedToCreateAudioUnit(status: OSStatus)
        case failedToInitializeAudioUnit(status: OSStatus)
        case failedToStartAudioUnit(status: OSStatus)
        case fileSystemError(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return String(localized: "recorder.systemCapture.alreadyRunning", defaultValue: "System audio capture is already active.")
            case .missingLoopbackDevice:
                return String(localized: "recorder.systemCapture.missingDevice", defaultValue: "No loopback device selected. Choose a virtual device in Settings.")
            case .failedToCreateAudioUnit(let status):
                return String(localized: "recorder.systemCapture.audioUnitCreate", defaultValue: "Failed to create audio unit (status: \(status)).")
            case .failedToInitializeAudioUnit(let status):
                return String(localized: "recorder.systemCapture.audioUnitInitialize", defaultValue: "Failed to initialize audio unit (status: \(status)).")
            case .failedToStartAudioUnit(let status):
                return String(localized: "recorder.systemCapture.audioUnitStart", defaultValue: "Failed to start audio unit (status: \(status)).")
            case .fileSystemError(let error):
                return String(localized: "recorder.systemCapture.fileSystem", defaultValue: "Unable to prepare output file: \(error.localizedDescription)")
            }
        }
    }

    private enum CaptureSource {
        case microphone
        case system
    }

    private final class AudioCaptureContext {
        let service: SystemAudioCaptureService
        let audioUnit: AudioUnit
        let source: CaptureSource

        init(service: SystemAudioCaptureService, audioUnit: AudioUnit, source: CaptureSource) {
            self.service = service
            self.audioUnit = audioUnit
            self.source = source
        }
    }

    private static let audioUnitCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
        let context = Unmanaged<AudioCaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
        return context.service.handleRenderCallback(
            context: context,
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    static let shared = SystemAudioCaptureService()

    @Published var isSystemAudioCaptureEnabled: Bool {
        didSet {
            if isSystemAudioCaptureEnabled != oldValue {
                UserDefaults.standard.recordSystemAudio = isSystemAudioCaptureEnabled
            }
        }
    }

    @Published var selectedSystemDeviceUID: String? {
        didSet {
            if selectedSystemDeviceUID != oldValue {
                if let value = selectedSystemDeviceUID {
                    UserDefaults.standard.systemAudioDeviceUID = value
                } else {
                    UserDefaults.standard.removeObject(forKey: UserDefaults.Keys.systemAudioDeviceUID)
                }
            }
        }
    }

    @Published var systemLevel: Float {
        didSet {
            let clamped = max(0, min(systemLevel, 1))
            if clamped != systemLevel {
                systemLevel = clamped
                return
            }
            UserDefaults.standard.systemAudioLoopbackLevel = clamped
            mixQueue.async { [clamped] in
                self.systemGain = clamped
            }
        }
    }

    @Published var microphoneLevel: Float {
        didSet {
            let clamped = max(0, min(microphoneLevel, 1))
            if clamped != microphoneLevel {
                microphoneLevel = clamped
                return
            }
            UserDefaults.standard.systemAudioMicrophoneLevel = clamped
            mixQueue.async { [clamped] in
                self.microphoneGain = clamped
            }
        }
    }

    @Published private(set) var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    @Published private(set) var isCapturing = false
    @Published private(set) var availableSystemDevices: [(id: AudioDeviceID, uid: String, name: String)] = []

    var selectedSystemDeviceName: String? {
        availableSystemDevices.first(where: { $0.uid == selectedSystemDeviceUID })?.name
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioCapture")
    private let deviceManager = AudioDeviceManager.shared
    private var cancellables = Set<AnyCancellable>()

    private var microphoneUnit: AudioUnit?
    private var systemUnit: AudioUnit?
    private var microphoneContext: AudioCaptureContext?
    private var systemContext: AudioCaptureContext?
    private var outputFile: AVAudioFile?
    private var recordingFormat: AVAudioFormat?
    private var microphoneFormat: AVAudioFormat?
    private var systemFormat: AVAudioFormat?
    private var microphoneConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var includeSystemAudioInCurrentSession = false

    private var microphoneBufferQueue: [AVAudioPCMBuffer] = []
    private var systemBufferQueue: [AVAudioPCMBuffer] = []
    private var microphoneGain: Float = 0.8
    private var systemGain: Float = 0.6

    private let mixQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.systemAudio.mix")

    private init() {
        if !UserDefaults.standard.contains(key: UserDefaults.Keys.recordSystemAudio) {
            UserDefaults.standard.recordSystemAudio = false
        }
        if !UserDefaults.standard.contains(key: UserDefaults.Keys.systemAudioLoopbackLevel) {
            UserDefaults.standard.systemAudioLoopbackLevel = 0.6
        }
        if !UserDefaults.standard.contains(key: UserDefaults.Keys.systemAudioMicrophoneLevel) {
            UserDefaults.standard.systemAudioMicrophoneLevel = 0.8
        }

        isSystemAudioCaptureEnabled = UserDefaults.standard.recordSystemAudio
        selectedSystemDeviceUID = UserDefaults.standard.systemAudioDeviceUID
        systemLevel = UserDefaults.standard.systemAudioLoopbackLevel
        microphoneLevel = UserDefaults.standard.systemAudioMicrophoneLevel
        microphoneGain = microphoneLevel
        systemGain = systemLevel

        availableSystemDevices = deviceManager.availableDevices

        deviceManager.$availableDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self = self else { return }
                self.availableSystemDevices = devices
                if let selectedUID = self.selectedSystemDeviceUID,
                   !devices.contains(where: { $0.uid == selectedUID }) {
                    self.selectedSystemDeviceUID = nil
                }
            }
            .store(in: &cancellables)
    }

    func startCapture(to url: URL, microphoneDeviceID: AudioDeviceID, includeSystemAudio: Bool) throws {
        guard !isCapturing else {
            throw SystemAudioCaptureError.alreadyRunning
        }

        let includeSystem = includeSystemAudio
        if includeSystem && selectedSystemDeviceUID == nil {
            throw SystemAudioCaptureError.missingLoopbackDevice
        }

        let microphoneChannels = max(1, deviceManager.inputChannelCount(for: microphoneDeviceID) ?? 1)
        let microphoneSampleRate = deviceManager.nominalSampleRate(for: microphoneDeviceID) ?? 48_000

        var resolvedSystemDeviceID: AudioDeviceID?
        var systemChannels: Int = 0
        var systemSampleRate = microphoneSampleRate

        if includeSystem, let systemUID = selectedSystemDeviceUID,
           let deviceID = deviceManager.getDeviceID(forUID: systemUID) {
            resolvedSystemDeviceID = deviceID
            systemChannels = Int(deviceManager.inputChannelCount(for: deviceID) ?? 2)
            systemSampleRate = deviceManager.nominalSampleRate(for: deviceID) ?? microphoneSampleRate
        }

        let effectiveSampleRate = includeSystem ? max(microphoneSampleRate, systemSampleRate) : microphoneSampleRate
        let targetChannelCount: AVAudioChannelCount = includeSystem
            ? AVAudioChannelCount(max(2, systemChannels))
            : AVAudioChannelCount(microphoneChannels)

        recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: effectiveSampleRate,
            channels: targetChannelCount,
            interleaved: false
        )

        microphoneFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: effectiveSampleRate,
            channels: AVAudioChannelCount(microphoneChannels),
            interleaved: false
        )

        if includeSystem, let resolvedSystemDeviceID {
            systemFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: effectiveSampleRate,
                channels: AVAudioChannelCount(max(1, systemChannels)),
                interleaved: false
            )
        } else {
            systemFormat = nil
        }

        microphoneConverter = needsConversion(from: microphoneFormat, to: recordingFormat)
            ? AVAudioConverter(from: microphoneFormat!, to: recordingFormat!)
            : nil
        systemConverter = needsConversion(from: systemFormat, to: recordingFormat)
            ? AVAudioConverter(from: systemFormat!, to: recordingFormat!)
            : nil
        microphoneConverter?.reset()
        systemConverter?.reset()

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw SystemAudioCaptureError.fileSystemError(error)
            }
        }

        guard let recordingFormat else { return }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: recordingFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SystemAudioCaptureError.fileSystemError(error)
        }

        mixQueue.sync {
            self.microphoneBufferQueue.removeAll()
            self.systemBufferQueue.removeAll()
            self.outputFile = audioFile
        }

        includeSystemAudioInCurrentSession = includeSystem
        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        do {
            microphoneUnit = try prepareAudioUnit(for: microphoneDeviceID, format: microphoneFormat!)
            microphoneContext = try installCallback(for: microphoneUnit!, source: .microphone)

            if includeSystem, let systemFormat, let resolvedSystemDeviceID {
                systemUnit = try prepareAudioUnit(for: resolvedSystemDeviceID, format: systemFormat)
                systemContext = try installCallback(for: systemUnit!, source: .system)
            } else {
                systemUnit = nil
                systemContext = nil
            }

            try startAudioUnitIfNeeded(microphoneUnit)
            try startAudioUnitIfNeeded(systemUnit)

            isCapturing = true
        } catch {
            cleanupAudioUnits()
            mixQueue.sync {
                self.outputFile = nil
                self.microphoneBufferQueue.removeAll()
                self.systemBufferQueue.removeAll()
            }
            throw error
        }
    }

    func stopCapture() {
        guard isCapturing else { return }

        cleanupAudioUnits()

        mixQueue.sync {
            microphoneBufferQueue.removeAll()
            systemBufferQueue.removeAll()
            outputFile = nil
        }

        recordingFormat = nil
        microphoneFormat = nil
        systemFormat = nil
        microphoneConverter = nil
        systemConverter = nil
        includeSystemAudioInCurrentSession = false
        isCapturing = false
        DispatchQueue.main.async {
            self.audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        }
    }

    private func needsConversion(from source: AVAudioFormat?, to target: AVAudioFormat?) -> Bool {
        guard let source, let target else { return false }
        return source.channelCount != target.channelCount || source.sampleRate != target.sampleRate
    }

    private func prepareAudioUnit(for deviceID: AudioDeviceID, format: AVAudioFormat) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: -1)
        }

        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let audioUnit = newUnit else {
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: status)
        }

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: status)
        }

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: status)
        }

        var deviceID = deviceID
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: status)
        }

        var asbd = format.streamDescription.pointee
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: status)
        }

        var maxFrames: UInt32 = 1024
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            throw SystemAudioCaptureError.failedToInitializeAudioUnit(status: status)
        }

        return audioUnit
    }

    private func installCallback(for audioUnit: AudioUnit, source: CaptureSource) throws -> AudioCaptureContext {
        let context = AudioCaptureContext(service: self, audioUnit: audioUnit, source: source)
        var callback = AURenderCallbackStruct(
            inputProc: SystemAudioCaptureService.audioUnitCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
        )

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        guard status == noErr else {
            throw SystemAudioCaptureError.failedToCreateAudioUnit(status: status)
        }

        return context
    }

    private func startAudioUnitIfNeeded(_ audioUnit: AudioUnit?) throws {
        guard let audioUnit else { return }
        let status = AudioOutputUnitStart(audioUnit)
        if status != noErr {
            throw SystemAudioCaptureError.failedToStartAudioUnit(status: status)
        }
    }

    private func cleanupAudioUnits() {
        if let audioUnit = microphoneUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        if let audioUnit = systemUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        microphoneUnit = nil
        systemUnit = nil
        microphoneContext = nil
        systemContext = nil
    }

    private func handleRenderCallback(
        context: AudioCaptureContext,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard inNumberFrames > 0 else { return noErr }
        guard isCapturing else { return noErr }

        let format: AVAudioFormat?
        switch context.source {
        case .microphone:
            format = microphoneFormat
        case .system:
            format = systemFormat
        }

        guard let format else { return noErr }

        let channelCount = Int(format.channelCount)
        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )

        defer {
            audioBufferListPointer.deallocate()
        }

        let audioBufferList = audioBufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for index in 0..<channelCount {
            buffers[index].mNumberChannels = 1
            buffers[index].mDataByteSize = UInt32(inNumberFrames) * UInt32(MemoryLayout<Float>.size)
            buffers[index].mData = UnsafeMutableRawPointer.allocate(
                byteCount: Int(inNumberFrames) * MemoryLayout<Float>.size,
                alignment: MemoryLayout<Float>.alignment
            )
        }

        defer {
            for buffer in buffers {
                buffer.mData?.deallocate()
            }
        }

        var timestamp = inTimeStamp.pointee
        let status = AudioUnitRender(
            context.audioUnit,
            ioActionFlags,
            &timestamp,
            inBusNumber,
            inNumberFrames,
            audioBufferList
        )

        guard status == noErr else {
            logger.error("AudioUnitRender failed with status: \(status)")
            return status
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames) else {
            return noErr
        }
        pcmBuffer.frameLength = inNumberFrames

        if let channelData = pcmBuffer.floatChannelData {
            for channelIndex in 0..<channelCount {
                let destination = channelData[channelIndex]
                if let sourcePointer = buffers[channelIndex].mData?.assumingMemoryBound(to: Float.self) {
                    destination.assign(from: sourcePointer, count: Int(inNumberFrames))
                }
            }
        }

        enqueue(buffer: pcmBuffer, for: context.source)

        return noErr
    }

    private func enqueue(buffer: AVAudioPCMBuffer, for source: CaptureSource) {
        mixQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCapturing else { return }
            guard let recordingFormat = self.recordingFormat else { return }

            switch source {
            case .microphone:
                if let converter = self.microphoneConverter,
                   let converted = self.convert(buffer, using: converter, targetFormat: recordingFormat) {
                    self.microphoneBufferQueue.append(converted)
                } else {
                    self.microphoneBufferQueue.append(buffer)
                }
            case .system:
                guard self.includeSystemAudioInCurrentSession else { return }
                if let converter = self.systemConverter,
                   let converted = self.convert(buffer, using: converter, targetFormat: recordingFormat) {
                    self.systemBufferQueue.append(converted)
                } else {
                    self.systemBufferQueue.append(buffer)
                }
            }

            self.processPendingBuffers()
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        converter.reset()
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)

        if status == .error || conversionError != nil {
            if let conversionError {
                logger.error("Audio conversion error: \(conversionError.localizedDescription)")
            }
            return nil
        }

        convertedBuffer.frameLength = min(buffer.frameLength, convertedBuffer.frameCapacity)
        return convertedBuffer
    }

    private func processPendingBuffers() {
        guard let recordingFormat else { return }

        while !microphoneBufferQueue.isEmpty {
            var mixedBuffer: AVAudioPCMBuffer?
            var micBuffer = microphoneBufferQueue.removeFirst()

            if includeSystemAudioInCurrentSession {
                guard !systemBufferQueue.isEmpty else {
                    microphoneBufferQueue.insert(micBuffer, at: 0)
                    break
                }

                var systemBuffer = systemBufferQueue.removeFirst()
                let frameLength = min(micBuffer.frameLength, systemBuffer.frameLength)
                micBuffer.frameLength = frameLength
                systemBuffer.frameLength = frameLength
                mixedBuffer = mix(microphoneBuffer: micBuffer, systemBuffer: systemBuffer, format: recordingFormat)
            } else {
                mixedBuffer = applyGain(to: micBuffer, gain: microphoneGain, format: recordingFormat)
            }

            if let buffer = mixedBuffer {
                write(buffer: buffer)
            }
        }
    }

    private func applyGain(to buffer: AVAudioPCMBuffer, gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        targetBuffer.frameLength = buffer.frameLength

        guard let sourceData = buffer.floatChannelData, let targetData = targetBuffer.floatChannelData else {
            return nil
        }

        let sourceChannels = Int(buffer.format.channelCount)
        let targetChannels = Int(format.channelCount)

        for channel in 0..<targetChannels {
            let sourceIndex = min(channel, sourceChannels - 1)
            let sourcePointer = sourceData[sourceIndex]
            let targetPointer = targetData[channel]
            let frameCount = Int(buffer.frameLength)
            for frame in 0..<frameCount {
                targetPointer[frame] = sourcePointer[frame] * gain
            }
        }

        updateAudioMeter(with: targetBuffer)
        return targetBuffer
    }

    private func mix(microphoneBuffer: AVAudioPCMBuffer, systemBuffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: microphoneBuffer.frameLength) else {
            return nil
        }

        targetBuffer.frameLength = microphoneBuffer.frameLength

        guard let micData = microphoneBuffer.floatChannelData,
              let sysData = systemBuffer.floatChannelData,
              let targetData = targetBuffer.floatChannelData else {
            return nil
        }

        let micChannels = Int(microphoneBuffer.format.channelCount)
        let sysChannels = Int(systemBuffer.format.channelCount)
        let targetChannels = Int(format.channelCount)
        let frameCount = Int(targetBuffer.frameLength)

        for channel in 0..<targetChannels {
            let micIndex = min(channel, micChannels - 1)
            let sysIndex = min(channel, sysChannels - 1)
            let micPointer = micData[micIndex]
            let sysPointer = sysData[sysIndex]
            let targetPointer = targetData[channel]

            for frame in 0..<frameCount {
                targetPointer[frame] = (micPointer[frame] * microphoneGain) + (sysPointer[frame] * systemGain)
            }
        }

        updateAudioMeter(with: targetBuffer)
        return targetBuffer
    }

    private func write(buffer: AVAudioPCMBuffer) {
        guard let file = outputFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            logger.error("Failed to write audio buffer: \(error.localizedDescription)")
        }
    }

    private func updateAudioMeter(with buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var totalRms: Float = 0
        var peak: Float = 0

        for channel in 0..<channelCount {
            let data = channelData[channel]
            for frame in 0..<frameCount {
                let sample = data[frame]
                peak = max(peak, abs(sample))
                totalRms += sample * sample
            }
        }

        let mean = totalRms / Float(frameCount * channelCount)
        let rms = sqrt(mean)
        let normalizedAverage = max(0, min(rms, 1))
        let normalizedPeak = max(0, min(peak, 1))

        DispatchQueue.main.async {
            self.audioMeter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))
        }
    }
}
