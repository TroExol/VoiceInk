import Foundation
import AVFoundation
import CoreAudio
import os
import Combine

@MainActor
class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    private let systemAudioService = SystemAudioCaptureService.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioLevelCheckTask: Task<Void, Never>?
    private var audioMeterUpdateTask: Task<Void, Never>?
    private var systemAudioMeterCancellable: AnyCancellable?
    private var isUsingSystemCapture = false
    private var hasDetectedAudioInCurrentSession = false
    private var activeRecordingURL: URL?
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
        setupDeviceChangeObserver()
    }
    
    private func setupDeviceChangeObserver() {
        deviceObserver = AudioDeviceConfiguration.createDeviceChangeObserver { [weak self] in
            Task {
                await self?.handleDeviceChange()
            }
        }
    }
    
    private func handleDeviceChange() async {
        guard !isReconfiguring else { return }
        isReconfiguring = true
        
        if isUsingSystemCapture && systemAudioService.isCapturing {
            let currentURL = activeRecordingURL
            stopRecording()

            if let url = currentURL {
                do {
                    try await startRecording(toOutputFile: url)
                } catch {
                    logger.error("❌ Failed to restart recording after device change: \(error.localizedDescription)")
                }
            }
        } else if recorder != nil {
            let currentURL = recorder?.url
            stopRecording()

            if let url = currentURL {
                do {
                    try await startRecording(toOutputFile: url)
                } catch {
                    logger.error("❌ Failed to restart recording after device change: \(error.localizedDescription)")
                }
            }
        }
        isReconfiguring = false
    }
    
    private func configureAudioSession(with deviceID: AudioDeviceID) async throws {
        try AudioDeviceConfiguration.setDefaultInputDevice(deviceID)
    }
    
    func startRecording(toOutputFile url: URL) async throws {
        deviceManager.isRecordingActive = true
        activeRecordingURL = url
        hasDetectedAudioInCurrentSession = false
        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        do {
            let shouldCaptureSystemAudio = UserDefaults.standard.isSystemAudioCaptureEnabled
            var hasStarted = false

            if shouldCaptureSystemAudio {
                do {
                    try await startSystemAudioRecording(to: url)
                    isUsingSystemCapture = true
                    hasStarted = true
                } catch {
                    isUsingSystemCapture = false
                    logger.error("❌ Failed to start system audio capture: \(error.localizedDescription)")
                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: String(localized: "notifications.systemAudioCaptureFailed"),
                            type: .error
                        )
                    }
                }
            }

            if !hasStarted {
                try await startMicrophoneRecording(to: url)
                isUsingSystemCapture = false
            }

            startAudioLevelCheckTask()
        } catch {
            audioLevelCheckTask?.cancel()
            audioMeterUpdateTask?.cancel()
            systemAudioMeterCancellable?.cancel()
            systemAudioMeterCancellable = nil
            systemAudioService.stopCapture()
            recorder?.stop()
            recorder = nil
            audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
            deviceManager.isRecordingActive = false
            activeRecordingURL = nil
            isUsingSystemCapture = false
            throw RecorderError.couldNotStartRecording
        }
    }

    private func startMicrophoneRecording(to url: URL) async throws {
        systemAudioMeterCancellable?.cancel()
        systemAudioMeterCancellable = nil

        let currentDeviceID = deviceManager.getCurrentDevice()
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")

        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                await MainActor.run {
                    let message = String(
                        format: String(localized: "notifications.usingDevice"),
                        locale: Locale.current,
                        deviceName
                    )
                    NotificationManager.shared.showNotification(
                        title: message,
                        type: .info
                    )
                }
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        if currentDeviceID != 0 {
            do {
                try await configureAudioSession(with: currentDeviceID)
            } catch {
                logger.warning("⚠️ Failed to configure audio session for device \(currentDeviceID), attempting to continue: \(error.localizedDescription)")
            }
        }

        let recordSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: recordSettings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true

            if recorder?.record() == false {
                logger.error("❌ Could not start recording")
                throw RecorderError.couldNotStartRecording
            }

            Task { [weak self] in
                guard let self = self else { return }
                await self.playbackController.pauseMedia()
                _ = await self.mediaController.muteSystemAudio()
            }

            audioMeterUpdateTask?.cancel()
            audioMeterUpdateTask = Task { [weak self] in
                while let recorder = self?.recorder, !Task.isCancelled {
                    self?.updateAudioMeter()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }

        } catch {
            recorder?.stop()
            recorder = nil
            throw RecorderError.couldNotStartRecording
        }
    }

    private func startSystemAudioRecording(to url: URL) async throws {
        audioMeterUpdateTask?.cancel()
        audioMeterUpdateTask = nil

        let defaults = UserDefaults.standard
        guard let loopbackUID = defaults.systemAudioLoopbackDeviceUID,
              let loopbackDeviceID = systemAudioService.deviceID(for: loopbackUID) else {
            throw RecorderError.couldNotStartRecording
        }

        let systemLevel = defaults.systemAudioSystemLevel
        let microphoneLevel = defaults.systemAudioMicrophoneLevel
        let systemChannelCount = defaults.systemAudioChannelCount > 0 ? defaults.systemAudioChannelCount : 2
        let outputFormatRaw = defaults.systemAudioOutputFormat
        let outputFormat = SystemAudioCaptureConfiguration.OutputFormat(rawValue: outputFormatRaw) ?? .stereo

        let configuration = SystemAudioCaptureConfiguration(
            loopbackDeviceID: loopbackDeviceID,
            outputFormat: outputFormat,
            systemLevel: Float(systemLevel),
            microphoneLevel: Float(microphoneLevel),
            systemChannelCount: systemChannelCount,
            microphoneChannelCountOverride: nil
        )

        try systemAudioService.startCapture(to: url, configuration: configuration)

        systemAudioMeterCancellable?.cancel()
        systemAudioMeterCancellable = systemAudioService.$audioMeter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meter in
                guard let self = self else { return }
                self.audioMeter = meter
                if meter.averagePower > 0.01 {
                    self.hasDetectedAudioInCurrentSession = true
                }
            }

        systemAudioService.updateLevels(systemLevel: Float(systemLevel), microphoneLevel: Float(microphoneLevel))

        Task { [weak self] in
            guard let self = self else { return }
            await self.playbackController.pauseMedia()
            await self.mediaController.reduceSystemAudioForCapture()
        }
    }

    private func startAudioLevelCheckTask() {
        audioLevelCheckTask?.cancel()
        audioLevelCheckTask = Task { [weak self] in
            guard let self = self else { return }
            let notificationChecks: [TimeInterval] = [5.0, 12.0]

            for delay in notificationChecks {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                if Task.isCancelled { return }

                if self.hasDetectedAudioInCurrentSession {
                    return
                }

                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "notifications.noAudioDetected"),
                        type: .warning
                    )
                }
            }
        }
    }

    func stopRecording() {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        systemAudioMeterCancellable?.cancel()
        systemAudioMeterCancellable = nil

        if isUsingSystemCapture {
            systemAudioService.stopCapture()
        } else {
            recorder?.stop()
            recorder = nil
        }

        recorder = nil

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        Task {
            if self.isUsingSystemCapture {
                await self.mediaController.restoreSystemAudioAfterCapture()
            } else {
                await self.mediaController.unmuteSystemAudio()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await self.playbackController.resumeMedia()
        }

        isUsingSystemCapture = false
        deviceManager.isRecordingActive = false
        activeRecordingURL = nil
    }

    private func updateAudioMeter() {
        guard let recorder = recorder else { return }
        recorder.updateMeters()
        
        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        
        let minVisibleDb: Float = -60.0 
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }
        
        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }
        
        let newAudioMeter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))

        if !hasDetectedAudioInCurrentSession && newAudioMeter.averagePower > 0.01 {
            hasDetectedAudioInCurrentSession = true
        }
        
        audioMeter = newAudioMeter
    }
    
    // MARK: - AVAudioRecorderDelegate
    
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            logger.error("❌ Recording finished unsuccessfully - file may be corrupted or empty")
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "notifications.recordingCorrupted"),
                    type: .error
                )
            }
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            logger.error("❌ Recording encode error during session: \(error.localizedDescription)")
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "notifications.recordingError"),
                        locale: Locale.current,
                        error.localizedDescription
                    ),
                    type: .error
                )
            }
        }
    }
    
    deinit {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        if let observer = deviceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}