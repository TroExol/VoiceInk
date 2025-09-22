import Foundation
import AVFoundation
import CoreAudio
import Combine
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
    private let systemAudioService = SystemAudioCaptureService.shared
    private var systemAudioMeterCancellable: AnyCancellable?
    private var isUsingSystemAudioCapture = false
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioLevelCheckTask: Task<Void, Never>?
    private var audioMeterUpdateTask: Task<Void, Never>?
    private var hasDetectedAudioInCurrentSession = false
    
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

        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        systemAudioMeterCancellable?.cancel()

        do {
            if systemAudioService.isCaptureEnabled {
                try startSystemAudioRecording(to: url)
            } else {
                try startMicrophoneOnlyRecording(to: url, settings: recordSettings)
            }

            Task { [weak self] in
                guard let self = self else { return }
                await self.playbackController.pauseMedia()
                _ = await self.mediaController.muteSystemAudio()
            }

            audioLevelCheckTask = Task {
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

        } catch {
            logger.error("Failed to create audio recorder: \(error.localizedDescription)")
            stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }
    
    func stopRecording() {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        systemAudioMeterCancellable?.cancel()
        systemAudioMeterCancellable = nil

        if isUsingSystemAudioCapture {
            systemAudioService.stopCapture()
            isUsingSystemAudioCapture = false
        }

        recorder?.stop()
        recorder = nil
        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        Task {
            await mediaController.unmuteSystemAudio()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await playbackController.resumeMedia()
        }
        deviceManager.isRecordingActive = false
    }

    private func startSystemAudioRecording(to url: URL) throws {
        try systemAudioService.startCapture(to: url)
        isUsingSystemAudioCapture = true
        recorder = nil

        systemAudioMeterCancellable = systemAudioService.$audioMeter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meter in
                guard let self else { return }
                self.audioMeter = meter
                if !self.hasDetectedAudioInCurrentSession && meter.averagePower > 0.01 {
                    self.hasDetectedAudioInCurrentSession = true
                }
            }
    }

    private func startMicrophoneOnlyRecording(to url: URL, settings: [String: Any]) throws {
        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true

        guard audioRecorder.record() else {
            logger.error("❌ Could not start recording")
            throw RecorderError.couldNotStartRecording
        }

        recorder = audioRecorder
        isUsingSystemAudioCapture = false

        audioMeterUpdateTask = Task { [weak self] in
            while let recorder = self?.recorder, !Task.isCancelled {
                recorder.updateMeters()

                let averagePower = recorder.averagePower(forChannel: 0)
                let peakPower = recorder.peakPower(forChannel: 0)

                self?.updateAudioMeter(averagePower: averagePower, peakPower: peakPower)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func updateAudioMeter() {
        guard let recorder = recorder else { return }
        recorder.updateMeters()

        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        updateAudioMeter(averagePower: averagePower, peakPower: peakPower)
    }

    private func updateAudioMeter(averagePower: Float, peakPower: Float) {
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

        if !hasDetectedAudioInCurrentSession && Double(normalizedAverage) > 0.01 {
            hasDetectedAudioInCurrentSession = true
        }

        let newAudioMeter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))

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