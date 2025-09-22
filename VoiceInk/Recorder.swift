import Foundation
import AVFoundation
import CoreAudio
import os

@MainActor
class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    private let systemAudioCaptureService = SystemAudioCaptureService.shared
    private let systemAudioPreferences = SystemAudioCapturePreferences.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioLevelCheckTask: Task<Void, Never>?
    private var audioMeterUpdateTask: Task<Void, Never>?
    private var hasDetectedAudioInCurrentSession = false
    private var isUsingSystemCapture = false
    
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
        
        if recorder != nil {
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
        
        hasDetectedAudioInCurrentSession = false

        let deviceID = deviceManager.getCurrentDevice()
        if deviceID != 0 {
            do {
                try await configureAudioSession(with: deviceID)
            } catch {
                logger.warning("⚠️ Failed to configure audio session for device \(deviceID), attempting to continue: \(error.localizedDescription)")
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
            if systemAudioPreferences.isEnabled {
                isUsingSystemCapture = true
                try await startSystemAudioRecording(toOutputFile: url)
            } else {
                isUsingSystemCapture = false
                try startMicrophoneOnlyRecording(toOutputFile: url, settings: recordSettings)
            }

            Task { [weak self] in
                guard let self = self else { return }
                await self.playbackController.pauseMedia()
                _ = await self.mediaController.muteSystemAudio()
            }

        } catch {
            logger.error("Failed to create audio recorder: \(error.localizedDescription)")
            stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }
    
    private func startMicrophoneOnlyRecording(toOutputFile url: URL, settings: [String: Any]) throws {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        systemAudioCaptureService.onAudioMeterUpdate = nil

        recorder = try AVAudioRecorder(url: url, settings: settings)
        guard let recorder = recorder else {
            throw RecorderError.couldNotStartRecording
        }

        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            logger.error("❌ Could not start recording")
            throw RecorderError.couldNotStartRecording
        }

        audioMeterUpdateTask = Task { [weak self] in
            while let self = self, self.recorder != nil && !Task.isCancelled {
                await MainActor.run {
                    self.updateAudioMeter()
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }

        scheduleAudioLevelCheck()
    }

    private func startSystemAudioRecording(toOutputFile url: URL) async throws {
        audioMeterUpdateTask?.cancel()
        audioMeterUpdateTask = nil
        recorder = nil

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: systemAudioPreferences.outputChannelCount,
            interleaved: false
        ) else {
            throw RecorderError.couldNotStartRecording
        }

        let loopbackDeviceID = systemAudioPreferences.selectedLoopbackDeviceUID.flatMap {
            SystemAudioLoopbackManager.shared.deviceID(for: $0)
        }

        let configuration = SystemAudioCaptureConfiguration(
            captureSystemAudio: true,
            loopbackDeviceID: loopbackDeviceID,
            outputFormat: format,
            microphoneLevel: systemAudioPreferences.microphoneGain,
            systemLevel: systemAudioPreferences.systemGain
        )

        systemAudioCaptureService.onAudioMeterUpdate = { [weak self] meter in
            Task { @MainActor in
                guard let self = self else { return }
                self.audioMeter = meter
                if !self.hasDetectedAudioInCurrentSession && meter.averagePower > 0.01 {
                    self.hasDetectedAudioInCurrentSession = true
                }
            }
        }

        do {
            try await systemAudioCaptureService.startCapture(configuration: configuration, outputURL: url)
        } catch {
            systemAudioCaptureService.onAudioMeterUpdate = nil
            throw error
        }

        scheduleAudioLevelCheck()
    }

    private func scheduleAudioLevelCheck() {
        audioLevelCheckTask?.cancel()
        audioLevelCheckTask = Task { [weak self] in
            let notificationChecks: [TimeInterval] = [5.0, 12.0]

            for delay in notificationChecks {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                if Task.isCancelled { return }

                let hasAudio = await MainActor.run { self?.hasDetectedAudioInCurrentSession ?? false }
                if hasAudio { return }

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
        audioLevelCheckTask = nil
        audioMeterUpdateTask?.cancel()
        audioMeterUpdateTask = nil

        if isUsingSystemCapture {
            systemAudioCaptureService.onAudioMeterUpdate = nil
            systemAudioCaptureService.stopCapture()
            isUsingSystemCapture = false
        } else {
            recorder?.stop()
            recorder = nil
        }

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        hasDetectedAudioInCurrentSession = false

        Task {
            await mediaController.unmuteSystemAudio()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await playbackController.resumeMedia()
        }
        deviceManager.isRecordingActive = false
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