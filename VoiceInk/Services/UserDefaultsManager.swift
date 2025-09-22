import Foundation

extension UserDefaults {
    enum Keys {
        static let aiProviderApiKey = "VoiceInkAIProviderKey"
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let prioritizedDevices = "prioritizedDevices"
        static let recordSystemAudio = "recordSystemAudio"
        static let systemAudioDeviceUID = "systemAudioDeviceUID"
        static let systemAudioLoopbackLevel = "systemAudioLoopbackLevel"
        static let systemAudioMicrophoneLevel = "systemAudioMicrophoneLevel"
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

    var recordSystemAudio: Bool {
        get { bool(forKey: Keys.recordSystemAudio) }
        set { setValue(newValue, forKey: Keys.recordSystemAudio) }
    }

    var systemAudioDeviceUID: String? {
        get { string(forKey: Keys.systemAudioDeviceUID) }
        set { setValue(newValue, forKey: Keys.systemAudioDeviceUID) }
    }

    var systemAudioLoopbackLevel: Float {
        get { float(forKey: Keys.systemAudioLoopbackLevel) }
        set { setValue(newValue, forKey: Keys.systemAudioLoopbackLevel) }
    }

    var systemAudioMicrophoneLevel: Float {
        get { float(forKey: Keys.systemAudioMicrophoneLevel) }
        set { setValue(newValue, forKey: Keys.systemAudioMicrophoneLevel) }
    }

    var systemCaptureVolume: Double {
        get { double(forKey: Keys.systemCaptureVolume) }
        set { setValue(newValue, forKey: Keys.systemCaptureVolume) }
    }
}
