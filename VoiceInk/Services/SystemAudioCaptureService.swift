import AVFoundation
import AudioToolbox
import CoreAudio
import Combine
import os

struct LoopbackDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let channelCount: Int
    let sampleRate: Double
    let isRecommended: Bool

    var id: String { uid }
}

enum SystemAudioCaptureError: LocalizedError {
    case loopbackDeviceUnavailable
    case audioEngineUnavailable
    case couldNotCreateTargetFormat
    case couldNotCreateAudioFile
    case audioUnit(OSStatus)

    var errorDescription: String? {
        switch self {
        case .loopbackDeviceUnavailable:
            return "Loopback device is not available"
        case .audioEngineUnavailable:
            return "Audio engine is not available"
        case .couldNotCreateTargetFormat:
            return "Could not create target audio format"
        case .couldNotCreateAudioFile:
            return "Could not create audio file for system capture"
        case .audioUnit(let status):
            return "Audio unit error: \(status)"
        }
    }
}

final class SystemAudioCaptureService: ObservableObject {
    static let shared = SystemAudioCaptureService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioCapture")

    @Published var isCaptureEnabled: Bool {
        didSet {
            UserDefaults.standard.isSystemAudioCaptureEnabled = isCaptureEnabled
        }
    }

    @Published var availableDevices: [LoopbackDevice] = []

    @Published var selectedDeviceUID: String? {
        didSet {
            UserDefaults.standard.systemAudioDeviceUID = selectedDeviceUID
        }
    }

    @Published var mixBalance: Double {
        didSet {
            mixBalance = clamp(value: mixBalance)
            UserDefaults.standard.systemAudioMixBalance = mixBalance
        }
    }

    @Published var playbackVolumeDuringCapture: Double {
        didSet {
            playbackVolumeDuringCapture = clamp(value: playbackVolumeDuringCapture)
            UserDefaults.standard.systemAudioPlaybackVolume = playbackVolumeDuringCapture
        }
    }

    @Published private(set) var audioMeter: AudioMeter = .init(averagePower: 0, peakPower: 0)
    @Published private(set) var isCapturing: Bool = false

    private var hardwareListenerQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.systemAudio.hardware")
    private let mixingQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.systemAudio.mixing", qos: .userInitiated)

    private var microphoneEngine: AVAudioEngine?
    private var microphoneConverter: AVAudioConverter?
    private var systemAudioUnit: AudioUnit?
    private var recordingFile: AVAudioFile?

    private var targetFormat: AVAudioFormat?

    private var microphoneBuffers: [AVAudioPCMBuffer] = []
    private var systemBuffers: [AVAudioPCMBuffer] = []

    private var hardwareListenerToken: AudioObjectPropertyAddress?
    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        isCaptureEnabled = UserDefaults.standard.isSystemAudioCaptureEnabled
        selectedDeviceUID = UserDefaults.standard.systemAudioDeviceUID
        mixBalance = clamp(value: UserDefaults.standard.systemAudioMixBalance)
        playbackVolumeDuringCapture = clamp(value: UserDefaults.standard.systemAudioPlaybackVolume)

        loadAvailableDevices()
        registerHardwareListener()
    }

    deinit {
        unregisterHardwareListener()
    }

    var microphoneGain: Float {
        Float(1.0 - mixBalance)
    }

    var systemGain: Float {
        Float(mixBalance)
    }

    var playbackVolumeValue: Int {
        Int(round(playbackVolumeDuringCapture * 100))
    }

    func refreshDevices() {
        loadAvailableDevices()
    }

    func startCapture(to url: URL) throws {
        guard isCaptureEnabled else { return }
        guard let selectedDevice = currentDevice else {
            logger.error("❌ Loopback device unavailable")
            throw SystemAudioCaptureError.loopbackDeviceUnavailable
        }

        if isCapturing {
            logger.info("⚠️ System audio capture already active")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let microphoneFormat = inputNode.inputFormat(forBus: 0)

        guard let format = createTargetFormat(microphoneFormat: microphoneFormat, device: selectedDevice) else {
            logger.error("❌ Unable to create target format for capture")
            throw SystemAudioCaptureError.couldNotCreateTargetFormat
        }

        guard let audioFile = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            logger.error("❌ Unable to create audio file at \(url.path)")
            throw SystemAudioCaptureError.couldNotCreateAudioFile
        }

        microphoneBuffers.removeAll(keepingCapacity: true)
        systemBuffers.removeAll(keepingCapacity: true)
        recordingFile = audioFile
        targetFormat = format

        microphoneConverter = AVAudioConverter(from: microphoneFormat, to: format)
        if microphoneFormat.channelCount == 1 {
            microphoneConverter?.channelMap = (0..<Int(format.channelCount)).map { _ in NSNumber(value: 0) }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: microphoneFormat) { [weak self] buffer, _ in
            self?.enqueueMicrophoneBuffer(buffer)
        }

        try engine.start()
        microphoneEngine = engine

        try configureSystemAudioUnit(device: selectedDevice, format: format)

        DispatchQueue.main.async {
            self.audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
            self.isCapturing = true
        }
    }
    func stopCapture() {
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            microphoneEngine = nil
        }

        if let audioUnit = systemAudioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            systemAudioUnit = nil
        }

        mixingQueue.sync {
            drainRemainingBuffers()
            microphoneBuffers.removeAll(keepingCapacity: true)
            systemBuffers.removeAll(keepingCapacity: true)
        }

        recordingFile = nil
        targetFormat = nil
        microphoneConverter = nil

        DispatchQueue.main.async {
            self.isCapturing = false
            self.audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        }
    }

    private var currentDevice: LoopbackDevice? {
        guard let selectedUID = selectedDeviceUID else {
            return availableDevices.first
        }
        return availableDevices.first { $0.uid == selectedUID }
    }

    private func loadAvailableDevices() {
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

        if status != noErr {
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

        if status != noErr {
            logger.error("Failed to get device list: \(status)")
            return
        }

        var loopbackDevices: [LoopbackDevice] = []

        for deviceID in deviceIDs {
            guard let name = getDeviceName(deviceID: deviceID),
                  let uid = getDeviceUID(deviceID: deviceID),
                  let channelCount = getOutputChannelCount(deviceID: deviceID),
                  channelCount > 0 else {
                continue
            }

            let sampleRate = getDeviceSampleRate(deviceID: deviceID) ?? 48_000
            let recommended = name.localizedCaseInsensitiveContains("blackhole") ||
                name.localizedCaseInsensitiveContains("loopback") ||
                name.localizedCaseInsensitiveContains("aggregate")

            let device = LoopbackDevice(
                deviceID: deviceID,
                uid: uid,
                name: name,
                channelCount: channelCount,
                sampleRate: sampleRate,
                isRecommended: recommended
            )
            loopbackDevices.append(device)
        }

        loopbackDevices.sort { lhs, rhs in
            if lhs.isRecommended == rhs.isRecommended {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.isRecommended && !rhs.isRecommended
        }

        DispatchQueue.main.async {
            self.availableDevices = loopbackDevices
            guard !loopbackDevices.isEmpty else {
                self.selectedDeviceUID = nil
                return
            }

            if let selectedUID = self.selectedDeviceUID,
               loopbackDevices.contains(where: { $0.uid == selectedUID }) {
                return
            }

            if let recommended = loopbackDevices.first(where: { $0.isRecommended }) ?? loopbackDevices.first {
                self.selectedDeviceUID = recommended.uid
            }
        }
    }

    private func registerHardwareListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.loadAvailableDevices()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            hardwareListenerQueue,
            block
        )

        if status == noErr {
            hardwareListenerToken = address
            hardwareListenerBlock = block
        } else {
            logger.error("Failed to register hardware listener: \(status)")
        }
    }

    private func unregisterHardwareListener() {
        guard var address = hardwareListenerToken, let block = hardwareListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            hardwareListenerQueue,
            block
        )
        hardwareListenerToken = nil
        hardwareListenerBlock = nil
    }
    private func configureSystemAudioUnit(device: LoopbackDevice, format: AVAudioFormat) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            logger.error("❌ Unable to find HAL output component")
            throw SystemAudioCaptureError.audioUnit(kAudioHardwareBadObjectError)
        }

        var audioUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            logger.error("❌ Unable to create audio unit: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableIO,
            UInt32(MemoryLayout.size(ofValue: enableIO))
        )
        guard status == noErr else {
            logger.error("❌ Unable to enable IO on audio unit: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableIO,
            UInt32(MemoryLayout.size(ofValue: disableIO))
        )
        guard status == noErr else {
            logger.error("❌ Unable to disable output on audio unit: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        var deviceID = device.deviceID
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            logger.error("❌ Unable to bind audio unit to device: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        var streamDescription = format.streamDescription.pointee
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamDescription,
            UInt32(MemoryLayout.size(ofValue: streamDescription))
        )
        guard status == noErr else {
            logger.error("❌ Unable to configure audio unit stream format: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: { (
                inRefCon,
                ioActionFlags,
                inTimeStamp,
                inBusNumber,
                inNumberFrames,
                ioData
            ) -> OSStatus in
                let service = Unmanaged<SystemAudioCaptureService>.fromOpaque(inRefCon).takeUnretainedValue()
                return service.renderSystemAudio(
                    ioActionFlags: ioActionFlags,
                    timeStamp: inTimeStamp,
                    busNumber: inBusNumber,
                    frameCount: inNumberFrames
                )
            },
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout.size(ofValue: callback))
        )
        guard status == noErr else {
            logger.error("❌ Unable to set audio unit callback: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            logger.error("❌ Unable to initialize audio unit: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            logger.error("❌ Unable to start audio unit: \(status)")
            throw SystemAudioCaptureError.audioUnit(status)
        }

        systemAudioUnit = audioUnit
    }

    private func renderSystemAudio(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        timeStamp: UnsafePointer<AudioTimeStamp>?,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let audioUnit = systemAudioUnit,
              let format = targetFormat,
              frameCount > 0 else {
            return noErr
        }

        let channelCount = Int(format.channelCount)
        let bufferListPointer = UnsafeMutableAudioBufferListPointer.allocate(maximumBuffers: channelCount)
        var allocatedPointers: [UnsafeMutableRawPointer] = []

        for index in 0..<channelCount {
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
            allocatedPointers.append(pointer)
            bufferListPointer[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteCount),
                mData: pointer
            )
        }

        let status: OSStatus
        if let flagsPointer = ioActionFlags {
            if let providedTimestamp = timeStamp {
                status = AudioUnitRender(
                    audioUnit,
                    flagsPointer,
                    providedTimestamp,
                    busNumber,
                    frameCount,
                    bufferListPointer.unsafeMutablePointer
                )
            } else {
                var localTimestamp = AudioTimeStamp()
                status = withUnsafePointer(to: &localTimestamp) { timestampPointer in
                    AudioUnitRender(
                        audioUnit,
                        flagsPointer,
                        timestampPointer,
                        busNumber,
                        frameCount,
                        bufferListPointer.unsafeMutablePointer
                    )
                }
            }
        } else {
            var localFlags = AudioUnitRenderActionFlags()
            if let providedTimestamp = timeStamp {
                status = withUnsafeMutablePointer(to: &localFlags) { flagsPointer in
                    AudioUnitRender(
                        audioUnit,
                        flagsPointer,
                        providedTimestamp,
                        busNumber,
                        frameCount,
                        bufferListPointer.unsafeMutablePointer
                    )
                }
            } else {
                var localTimestamp = AudioTimeStamp()
                status = withUnsafeMutablePointer(to: &localFlags) { flagsPointer in
                    withUnsafePointer(to: &localTimestamp) { timestampPointer in
                        AudioUnitRender(
                            audioUnit,
                            flagsPointer,
                            timestampPointer,
                            busNumber,
                            frameCount,
                            bufferListPointer.unsafeMutablePointer
                        )
                    }
                }
            }
        }

        if status == noErr {
            if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) {
                pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                if let floatChannels = pcmBuffer.floatChannelData {
                    for channel in 0..<channelCount {
                        guard let source = bufferListPointer[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        floatChannels[channel].assign(from: source, count: Int(frameCount))
                    }
                }
                enqueueSystemBuffer(pcmBuffer)
            }
        }

        for pointer in allocatedPointers {
            pointer.deallocate()
        }
        bufferListPointer.deallocate()

        return status
    }
    private func enqueueMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        mixingQueue.async { [weak self] in
            guard let self else { return }
            guard let format = self.targetFormat else { return }
            guard let converter = self.microphoneConverter else { return }

            guard let converted = self.convert(buffer: buffer, using: converter, targetFormat: format) else {
                return
            }

            self.microphoneBuffers.append(converted)
            self.processQueues()
        }
    }

    private func enqueueSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        mixingQueue.async { [weak self] in
            guard let self else { return }
            self.systemBuffers.append(buffer)
            self.processQueues()
        }
    }

    private func processQueues() {
        guard let file = recordingFile, let format = targetFormat else { return }

        while let micBuffer = microphoneBuffers.first, let systemBuffer = systemBuffers.first {
            let frameCount = min(micBuffer.frameLength, systemBuffer.frameLength)
            guard frameCount > 0 else { break }

            guard let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            mixBuffer.frameLength = frameCount

            guard let micChannels = micBuffer.floatChannelData,
                  let systemChannels = systemBuffer.floatChannelData,
                  let mixChannels = mixBuffer.floatChannelData else {
                break
            }

            let channelCount = Int(format.channelCount)
            let micGain = microphoneGain
            let systemGain = systemGain

            for channel in 0..<channelCount {
                let micData = micChannels[channel]
                let systemData = systemChannels[channel]
                let mixData = mixChannels[channel]

                for frame in 0..<Int(frameCount) {
                    mixData[frame] = micData[frame] * micGain + systemData[frame] * systemGain
                }
            }

            updateAudioMeter(with: mixBuffer)

            do {
                try file.write(from: mixBuffer)
            } catch {
                logger.error("❌ Failed to write mixed buffer: \(error.localizedDescription)")
            }

            if micBuffer.frameLength == frameCount {
                microphoneBuffers.removeFirst()
            } else if let trimmed = micBuffer.trimming(from: frameCount) {
                microphoneBuffers[0] = trimmed
            } else {
                microphoneBuffers.removeFirst()
            }

            if systemBuffer.frameLength == frameCount {
                systemBuffers.removeFirst()
            } else if let trimmed = systemBuffer.trimming(from: frameCount) {
                systemBuffers[0] = trimmed
            } else {
                systemBuffers.removeFirst()
            }
        }
    }

    private func drainRemainingBuffers() {
        guard let format = targetFormat else { return }

        while let micBuffer = microphoneBuffers.first {
            let frameCount = micBuffer.frameLength
            guard let silentSystem = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            silentSystem.frameLength = frameCount
            silentSystem.clear()
            systemBuffers.insert(silentSystem, at: 0)
            processQueues()
        }

        while let systemBuffer = systemBuffers.first {
            let frameCount = systemBuffer.frameLength
            guard let silentMic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            silentMic.frameLength = frameCount
            silentMic.clear()
            microphoneBuffers.insert(silentMic, at: 0)
            processQueues()
        }
    }

    private func createTargetFormat(microphoneFormat: AVAudioFormat, device: LoopbackDevice) -> AVAudioFormat? {
        let channelCount = max(AVAudioChannelCount(device.channelCount), 2)
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: device.sampleRate,
            channels: channelCount,
            interleaved: false
        )
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameLength) else { return nil }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return outputBuffer
        case .error:
            if let error {
                logger.error("❌ Conversion error: \(error.localizedDescription)")
            }
            return nil
        case .endOfStream:
            return nil
        @unknown default:
            return nil
        }
    }

    private func updateAudioMeter(with buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var rms: Float = 0
        var peak: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                rms += sample * sample
                peak = max(peak, abs(sample))
            }
        }

        let meanSquare = rms / Float(frameLength * channelCount)
        let average = sqrt(meanSquare)
        let averageDb = 20 * log10(max(average, 1e-7))
        let peakDb = 20 * log10(max(peak, 1e-7))

        let normalizedAverage = normalize(db: averageDb)
        let normalizedPeak = normalize(db: peakDb)

        DispatchQueue.main.async {
            self.audioMeter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))
        }
    }

    private func normalize(db: Float) -> Float {
        let minDb: Float = -60
        let maxDb: Float = 0

        if db <= minDb { return 0 }
        if db >= maxDb { return 1 }
        return (db - minDb) / (maxDb - minDb)
    }
    private func clamp(value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &name)
        if status != noErr {
            return nil
        }
        return name as String?
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &uid)
        if status != noErr {
            return nil
        }
        return uid as String?
    }

    private func getOutputChannelCount(deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        if status != noErr {
            return nil
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        if status != noErr {
            return nil
        }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        var channelCount = 0
        for buffer in audioBufferList {
            channelCount += Int(buffer.mNumberChannels)
        }
        return channelCount
    }

    private func getDeviceSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Double = 0
        var propertySize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &sampleRate)
        if status != noErr {
            return nil
        }
        return sampleRate
    }
}

private extension AVAudioPCMBuffer {
    func trimming(from frameOffset: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frameOffset < frameLength else { return nil }
        let remaining = frameLength - frameOffset
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else { return nil }
        newBuffer.frameLength = remaining

        if let floatSource = floatChannelData, let floatDestination = newBuffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                let sourcePointer = floatSource[channel] + Int(frameOffset)
                floatDestination[channel].assign(from: sourcePointer, count: Int(remaining))
            }
        } else if let int16Source = int16ChannelData, let int16Destination = newBuffer.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                let sourcePointer = int16Source[channel] + Int(frameOffset)
                int16Destination[channel].assign(from: sourcePointer, count: Int(remaining))
            }
        }

        return newBuffer
    }

    func clear() {
        if let floatChannels = floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                floatChannels[channel].initialize(repeating: 0, count: Int(frameCapacity))
            }
        } else if let int16Channels = int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                int16Channels[channel].initialize(repeating: 0, count: Int(frameCapacity))
            }
        }
    }
}
