import Foundation

enum SpeakerDiarizationMode: String, CaseIterable, Identifiable {
    case off
    case whisperLocal
    case pyannote
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "speakerDiarization.mode.off")
        case .whisperLocal:
            return String(localized: "speakerDiarization.mode.whisper")
        case .pyannote:
            return String(localized: "speakerDiarization.mode.pyannote")
        case .deepgram:
            return String(localized: "speakerDiarization.mode.deepgram")
        }
    }

    var details: String {
        switch self {
        case .off:
            return String(localized: "speakerDiarization.mode.off.description")
        case .whisperLocal:
            return String(localized: "speakerDiarization.mode.whisper.description")
        case .pyannote:
            return String(localized: "speakerDiarization.mode.pyannote.description")
        case .deepgram:
            return String(localized: "speakerDiarization.mode.deepgram.description")
        }
    }

    var requiresNetwork: Bool {
        switch self {
        case .off, .whisperLocal:
            return false
        case .pyannote, .deepgram:
            return true
        }
    }
}

extension SpeakerDiarizationMode {
    static let userDefaultsKey = "SpeakerDiarizationMode"
}
