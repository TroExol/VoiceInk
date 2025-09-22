import Foundation

extension UserDefaults {
    enum Keys {
        static let aiProviderApiKey = "VoiceInkAIProviderKey"
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let prioritizedDevices = "prioritizedDevices"
        static let systemAudioCaptureEnabled = "systemAudioCaptureEnabled"
        static let systemAudioLoopbackUID = "systemAudioLoopbackUID"
        static let systemAudioSystemLevel = "systemAudioSystemLevel"
        static let systemAudioMicrophoneLevel = "systemAudioMicrophoneLevel"
        static let systemAudioOutputFormat = "systemAudioOutputFormat"
        static let systemAudioChannelCount = "systemAudioChannelCount"
        static let systemCaptureVolume = "systemCaptureVolume"
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
        get {
            if object(forKey: Keys.systemAudioCaptureEnabled) == nil {
                set(false, forKey: Keys.systemAudioCaptureEnabled)
            }
            return bool(forKey: Keys.systemAudioCaptureEnabled)
        }
        set { set(newValue, forKey: Keys.systemAudioCaptureEnabled) }
    }

    var systemAudioLoopbackDeviceUID: String? {
        get { string(forKey: Keys.systemAudioLoopbackUID) }
        set { setValue(newValue, forKey: Keys.systemAudioLoopbackUID) }
    }

    var systemAudioSystemLevel: Double {
        get {
            if object(forKey: Keys.systemAudioSystemLevel) == nil {
                set(0.85, forKey: Keys.systemAudioSystemLevel)
            }
            return double(forKey: Keys.systemAudioSystemLevel)
        }
        set { set(newValue, forKey: Keys.systemAudioSystemLevel) }
    }

    var systemAudioMicrophoneLevel: Double {
        get {
            if object(forKey: Keys.systemAudioMicrophoneLevel) == nil {
                set(0.85, forKey: Keys.systemAudioMicrophoneLevel)
            }
            return double(forKey: Keys.systemAudioMicrophoneLevel)
        }
        set { set(newValue, forKey: Keys.systemAudioMicrophoneLevel) }
    }

    var systemAudioOutputFormat: String {
        get {
            if object(forKey: Keys.systemAudioOutputFormat) == nil {
                set(SystemAudioCaptureConfiguration.OutputFormat.stereo.rawValue, forKey: Keys.systemAudioOutputFormat)
            }
            return string(forKey: Keys.systemAudioOutputFormat) ?? SystemAudioCaptureConfiguration.OutputFormat.stereo.rawValue
        }
        set { set(newValue, forKey: Keys.systemAudioOutputFormat) }
    }

    var systemAudioChannelCount: Int {
        get {
            if object(forKey: Keys.systemAudioChannelCount) == nil {
                set(2, forKey: Keys.systemAudioChannelCount)
            }
            return integer(forKey: Keys.systemAudioChannelCount)
        }
        set { set(newValue, forKey: Keys.systemAudioChannelCount) }
    }

    var systemCaptureVolume: Double {
        get {
            if object(forKey: Keys.systemCaptureVolume) == nil {
                set(40.0, forKey: Keys.systemCaptureVolume)
            }
            return double(forKey: Keys.systemCaptureVolume)
        }
        set { set(newValue, forKey: Keys.systemCaptureVolume) }
    }
}
