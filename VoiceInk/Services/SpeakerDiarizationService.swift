import Foundation
import os

enum SpeakerDiarizationDefaults {
    static let selectedModelKey = "SpeakerDiarizationSelectedModel"
    static let tinydiarizeEnabledKey = "SpeakerDiarizationTinydiarizeEnabled"
    static let pyannoteAPIKey = "SpeakerDiarizationPyannoteAPIKey"
    static let deepgramAPIKey = "SpeakerDiarizationDeepgramAPIKey"
}

enum SpeakerDiarizationModel: String, CaseIterable, Identifiable {
    case none
    case whisperTinydiarize
    case pyannote
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return String(localized: "settings.diarization.option.none", defaultValue: "No diarization")
        case .whisperTinydiarize:
            return String(localized: "settings.diarization.option.whisper", defaultValue: "Whisper tinydiarize")
        case .pyannote:
            return String(localized: "settings.diarization.option.pyannote", defaultValue: "pyannote")
        case .deepgram:
            return String(localized: "settings.diarization.option.deepgram", defaultValue: "Deepgram")
        }
    }

    var description: String {
        switch self {
        case .none:
            return String(localized: "settings.diarization.option.none.description", defaultValue: "Speaker labels are not generated.")
        case .whisperTinydiarize:
            return String(localized: "settings.diarization.option.whisper.description", defaultValue: "Run the lightweight tinydiarize algorithm bundled with whisper.cpp.")
        case .pyannote:
            return String(localized: "settings.diarization.option.pyannote.description", defaultValue: "Requires a valid pyannote API token.")
        case .deepgram:
            return String(localized: "settings.diarization.option.deepgram.description", defaultValue: "Requires a Deepgram API key with diarization enabled.")
        }
    }

    var requiresExternalAPI: Bool {
        switch self {
        case .pyannote, .deepgram:
            return true
        default:
            return false
        }
    }
}

struct SpeakerSegment: Sendable {
    let speaker: String?
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    func updatingText(_ newText: String) -> SpeakerSegment {
        SpeakerSegment(speaker: speaker, start: start, end: end, text: newText)
    }
}

@MainActor
final class SpeakerDiarizationService: ObservableObject {
    static let shared = SpeakerDiarizationService()

    @Published private(set) var selectedModel: SpeakerDiarizationModel

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerDiarizationService")

    private init() {
        if let stored = UserDefaults.standard.string(forKey: SpeakerDiarizationDefaults.selectedModelKey),
           let model = SpeakerDiarizationModel(rawValue: stored) {
            self.selectedModel = model
        } else {
            self.selectedModel = .none
        }
        updateTinydiarizeFlag()
    }

    func updateSelectedModel(_ model: SpeakerDiarizationModel) {
        guard selectedModel != model else { return }
        selectedModel = model
        persistSelection()
    }

    var pyannoteAPIKey: String {
        get { UserDefaults.standard.string(forKey: SpeakerDiarizationDefaults.pyannoteAPIKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SpeakerDiarizationDefaults.pyannoteAPIKey) }
    }

    var deepgramAPIKey: String {
        get { UserDefaults.standard.string(forKey: SpeakerDiarizationDefaults.deepgramAPIKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SpeakerDiarizationDefaults.deepgramAPIKey) }
    }

    func assignSpeakers(rawSegments: [WhisperTranscriptionSegment], fullText: String, totalDuration: TimeInterval, audioURL: URL?) async -> [SpeakerSegment] {
        _ = audioURL
        if rawSegments.isEmpty {
            guard !fullText.isEmpty else { return [] }
            return [SpeakerSegment(speaker: nil, start: 0, end: totalDuration, text: fullText)]
        }

        switch selectedModel {
        case .none:
            return rawSegments.map { segment in
                SpeakerSegment(speaker: nil, start: segment.start, end: segment.end, text: segment.text)
            }
        case .whisperTinydiarize:
            let segments = convertFromWhisper(rawSegments)
            if segments.allSatisfy({ ($0.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) {
                logger.info("whisper.cpp returned no speaker identifiers; falling back to heuristic labels.")
                return generateFallbackSegments(from: rawSegments)
            }
            return segments
        case .pyannote:
            if pyannoteAPIKey.isEmpty {
                logger.error("pyannote diarization selected but API token is missing; using fallback strategy.")
            } else {
                logger.info("pyannote diarization not available in this environment; using fallback strategy.")
            }
            return generateFallbackSegments(from: rawSegments)
        case .deepgram:
            if deepgramAPIKey.isEmpty {
                logger.error("Deepgram diarization selected but API key is missing; using fallback strategy.")
            } else {
                logger.info("Deepgram diarization not available in this environment; using fallback strategy.")
            }
            return generateFallbackSegments(from: rawSegments)
        }
    }

    private func convertFromWhisper(_ segments: [WhisperTranscriptionSegment]) -> [SpeakerSegment] {
        segments.map { segment in
            let cleanedSpeaker = segment.speakerIdentifier.flatMap(cleanSpeakerIdentifier)
            return SpeakerSegment(
                speaker: cleanedSpeaker,
                start: segment.start,
                end: segment.end,
                text: segment.text
            )
        }
    }

    private func cleanSpeakerIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let digits = trimmed.compactMap { $0.wholeNumberValue }
        if !digits.isEmpty {
            let number = digits.reduce(0) { partialResult, digit in
                (partialResult * 10) + digit
            }
            let base = String(localized: "transcription.speaker.generic", defaultValue: "Speaker")
            // whisper.cpp speaker identifiers are zero-based
            return "\(base) \(number + 1)"
        }

        return trimmed
    }

    private func generateFallbackSegments(from segments: [WhisperTranscriptionSegment]) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return [] }
        let base = String(localized: "transcription.speaker.generic", defaultValue: "Speaker")
        let fallbackNames = (1...4).map { "\(base) \($0)" }
        var currentIndex = 0

        return segments.enumerated().map { index, segment in
            if index > 0, segments[index - 1].hasSpeakerTurnNext {
                currentIndex = (currentIndex + 1) % fallbackNames.count
            }
            let speaker = fallbackNames[currentIndex]
            return SpeakerSegment(speaker: speaker, start: segment.start, end: segment.end, text: segment.text)
        }
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedModel.rawValue, forKey: SpeakerDiarizationDefaults.selectedModelKey)
        updateTinydiarizeFlag()
    }

    private func updateTinydiarizeFlag() {
        let shouldEnable = selectedModel == .whisperTinydiarize
        UserDefaults.standard.set(shouldEnable, forKey: SpeakerDiarizationDefaults.tinydiarizeEnabledKey)
    }
}
