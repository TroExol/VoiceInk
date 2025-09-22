import Foundation
import AVFoundation

final class SystemAudioCapturePreferences: ObservableObject {
    enum OutputMode: String, CaseIterable, Identifiable {
        case stereo
        case multichannel

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stereo:
                return String(localized: "Stereo")
            case .multichannel:
                return String(localized: "Multichannel")
            }
        }
    }

    static let shared = SystemAudioCapturePreferences()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: UserDefaults.Keys.systemAudioCaptureEnabled) }
    }

    @Published var selectedLoopbackDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedLoopbackDeviceUID, forKey: UserDefaults.Keys.systemAudioLoopbackDeviceUID) }
    }

    @Published var microphoneLevel: Double {
        didSet { UserDefaults.standard.set(microphoneLevel, forKey: UserDefaults.Keys.systemAudioMicrophoneLevel) }
    }

    @Published var systemLevel: Double {
        didSet { UserDefaults.standard.set(systemLevel, forKey: UserDefaults.Keys.systemAudioSystemLevel) }
    }

    @Published var outputMode: OutputMode {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: UserDefaults.Keys.systemAudioOutputMode) }
    }

    @Published var multichannelCount: Int {
        didSet { UserDefaults.standard.set(multichannelCount, forKey: UserDefaults.Keys.systemAudioChannelCount) }
    }

    @Published var fadeDuration: Double {
        didSet { UserDefaults.standard.set(fadeDuration, forKey: UserDefaults.Keys.systemAudioFadeDuration) }
    }

    /// Target system volume (0...1) applied during capture when system audio recording is enabled.
    @Published var captureVolume: Double {
        didSet { UserDefaults.standard.set(captureVolume, forKey: UserDefaults.Keys.systemAudioCaptureVolume) }
    }

    private init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: UserDefaults.Keys.systemAudioCaptureEnabled) as? Bool ?? false
        isEnabled = enabled

        selectedLoopbackDeviceUID = defaults.string(forKey: UserDefaults.Keys.systemAudioLoopbackDeviceUID)
        let savedMicLevel = defaults.object(forKey: UserDefaults.Keys.systemAudioMicrophoneLevel) as? Double ?? 0.7
        microphoneLevel = max(0.0, min(savedMicLevel, 1.0))

        let savedSystemLevel = defaults.object(forKey: UserDefaults.Keys.systemAudioSystemLevel) as? Double ?? 0.7
        systemLevel = max(0.0, min(savedSystemLevel, 1.0))

        if let rawValue = defaults.string(forKey: UserDefaults.Keys.systemAudioOutputMode),
           let mode = OutputMode(rawValue: rawValue) {
            outputMode = mode
        } else {
            outputMode = .stereo
        }

        let savedChannelCount = defaults.object(forKey: UserDefaults.Keys.systemAudioChannelCount) as? Int ?? 6
        multichannelCount = max(2, savedChannelCount)

        let savedFadeDuration = defaults.object(forKey: UserDefaults.Keys.systemAudioFadeDuration) as? Double ?? 0.35
        fadeDuration = max(0.05, savedFadeDuration)

        let savedVolume = defaults.object(forKey: UserDefaults.Keys.systemAudioCaptureVolume) as? Double ?? 1.0
        captureVolume = max(0.0, min(savedVolume, 1.0))
    }

    var outputChannelCount: AVAudioChannelCount {
        switch outputMode {
        case .stereo:
            return 2
        case .multichannel:
            return AVAudioChannelCount(max(2, multichannelCount))
        }
    }

    var microphoneGain: Float {
        return Float(max(0.0, min(microphoneLevel, 1.0)))
    }

    var systemGain: Float {
        return Float(max(0.0, min(systemLevel, 1.0)))
    }

    var captureVolumePercentage: Int {
        return Int((max(0.0, min(captureVolume, 1.0))) * 100.0)
    }
}
