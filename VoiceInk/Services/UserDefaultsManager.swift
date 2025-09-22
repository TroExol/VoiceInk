import Foundation

extension UserDefaults {
    enum Keys {
        static let aiProviderApiKey = "VoiceInkAIProviderKey"
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let prioritizedDevices = "prioritizedDevices"
        static let systemAudioCaptureEnabled = "systemAudioCaptureEnabled"
        static let systemAudioDeviceUID = "systemAudioDeviceUID"
        static let systemAudioMixBalance = "systemAudioMixBalance"
        static let systemAudioPlaybackVolume = "systemAudioPlaybackVolume"
    }
    
    // MARK: - AI Provider API Key
    var aiProviderApiKey: String? {
        get { string(forKey: Keys.aiProviderApiKey) }
        set { setValue(newValue, forKey: Keys.aiProviderApiKey) }
    }

    // MARK: - Audio Input Mode
    var audioInputModeRawValue: String? {
        get { string(forKey: Keys.audioInputMode) }
        set { setValue(newValue, forKey: Keys.audioInputMode) }
    }

    // MARK: - Selected Audio Device UID
    var selectedAudioDeviceUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceUID) }
    }

    // MARK: - Prioritized Devices
    var prioritizedDevicesData: Data? {
        get { data(forKey: Keys.prioritizedDevices) }
        set { setValue(newValue, forKey: Keys.prioritizedDevices) }
    }

    // MARK: - System Audio Capture
    var isSystemAudioCaptureEnabled: Bool {
        get { object(forKey: Keys.systemAudioCaptureEnabled) as? Bool ?? false }
        set { set(newValue, forKey: Keys.systemAudioCaptureEnabled) }
    }

    var systemAudioDeviceUID: String? {
        get { string(forKey: Keys.systemAudioDeviceUID) }
        set { setValue(newValue, forKey: Keys.systemAudioDeviceUID) }
    }

    var systemAudioMixBalance: Double {
        get {
            if object(forKey: Keys.systemAudioMixBalance) == nil {
                return 0.5
            }
            return double(forKey: Keys.systemAudioMixBalance)
        }
        set { set(newValue, forKey: Keys.systemAudioMixBalance) }
    }

    var systemAudioPlaybackVolume: Double {
        get {
            if object(forKey: Keys.systemAudioPlaybackVolume) == nil {
                return 0.7
            }
            return double(forKey: Keys.systemAudioPlaybackVolume)
        }
        set { set(newValue, forKey: Keys.systemAudioPlaybackVolume) }
    }
}
