import Foundation

extension UserDefaults {
    enum Keys {
        static let aiProviderApiKey = "VoiceInkAIProviderKey"
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let prioritizedDevices = "prioritizedDevices"
        static let systemAudioCaptureEnabled = "systemAudioCaptureEnabled"
        static let systemAudioLoopbackDeviceUID = "systemAudioLoopbackDeviceUID"
        static let systemAudioMicrophoneLevel = "systemAudioMicrophoneLevel"
        static let systemAudioSystemLevel = "systemAudioSystemLevel"
        static let systemAudioOutputMode = "systemAudioOutputMode"
        static let systemAudioChannelCount = "systemAudioChannelCount"
        static let systemAudioFadeDuration = "systemAudioFadeDuration"
        static let systemAudioCaptureVolume = "systemAudioCaptureVolume"
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
} 
