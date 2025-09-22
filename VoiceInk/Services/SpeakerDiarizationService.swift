import Foundation
import os

@MainActor
final class SpeakerDiarizationService {
    static let shared = SpeakerDiarizationService()
    static let selectedModelDefaultsKey = "SpeakerDiarization.SelectedModel"
    static let fallbackDefaultsKey = "SpeakerDiarization.FallbackEnabled"

    enum Model: String, CaseIterable, Identifiable {
        case none
        case whisper
        case pyannote
        case deepgram

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none:
                return "Disabled"
            case .whisper:
                return "Whisper (Local)"
            case .pyannote:
                return "pyannote.ai"
            case .deepgram:
                return "Deepgram"
            }
        }

        var description: String {
            switch self {
            case .none:
                return "Speaker labels will not be generated."
            case .whisper:
                return "Use the local whisper.cpp speaker model when available."
            case .pyannote:
                return "Requires integration with the pyannote.ai diarization pipeline."
            case .deepgram:
                return "Use Deepgram's diarization API (additional setup required)."
            }
        }
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerDiarizationService")
    private let defaults = UserDefaults.standard

    private init() {}

    var selectedModel: Model {
        get {
            let rawValue = defaults.string(forKey: Self.selectedModelDefaultsKey) ?? Model.whisper.rawValue
            return Model(rawValue: rawValue) ?? .whisper
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.selectedModelDefaultsKey)
        }
    }

    var isFallbackEnabled: Bool {
        get {
            defaults.object(forKey: Self.fallbackDefaultsKey) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Self.fallbackDefaultsKey)
        }
    }

    func attachSegments(from metadata: [WhisperSegmentMetadata]?, to transcription: Transcription, baseText: String, audioDuration: TimeInterval) {
        let trimmedBaseText = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = generateSegments(for: transcription, metadata: metadata, baseText: trimmedBaseText, audioDuration: audioDuration)

        transcription.segments.removeAll()
        transcription.segments.append(contentsOf: segments)
    }

    private func generateSegments(for transcription: Transcription, metadata: [WhisperSegmentMetadata]?, baseText: String, audioDuration: TimeInterval) -> [TranscriptionSegment] {
        switch selectedModel {
        case .none:
            return fallbackSegments(for: transcription, baseText: baseText, audioDuration: audioDuration)
        case .whisper:
            guard let metadata, !metadata.isEmpty else {
                logger.notice("Speaker metadata unavailable for Whisper diarization; applying fallback.")
                return fallbackSegments(for: transcription, baseText: baseText, audioDuration: audioDuration)
            }
            return metadata.compactMap { segment in
                let cleanedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedText.isEmpty else { return nil }
                let displayName = makeDisplayName(forRawSpeaker: segment.speakerId, index: segment.speakerIndex, isDerived: segment.isSpeakerDerived)
                let diarizedSegment = TranscriptionSegment(
                    speaker: displayName,
                    start: segment.startTime,
                    end: segment.endTime,
                    text: cleanedText,
                    speakerIndex: segment.speakerIndex,
                    isSpeakerDerived: segment.isSpeakerDerived,
                    transcription: transcription
                )
                return diarizedSegment
            }
        case .pyannote, .deepgram:
            logger.notice("External diarization model \(selectedModel.rawValue) is not configured. Falling back to default behaviour.")
            return fallbackSegments(for: transcription, baseText: baseText, audioDuration: audioDuration)
        }
    }

    private func fallbackSegments(for transcription: Transcription, baseText: String, audioDuration: TimeInterval) -> [TranscriptionSegment] {
        guard isFallbackEnabled else { return [] }
        let cleanedText = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return [] }
        let duration = audioDuration > 0 ? audioDuration : 0
        let fallbackSegment = TranscriptionSegment(
            speaker: makeFallbackDisplayName(forIndex: 0),
            start: 0,
            end: duration,
            text: cleanedText,
            speakerIndex: 0,
            isSpeakerDerived: true,
            transcription: transcription
        )
        return [fallbackSegment]
    }

    private func makeDisplayName(forRawSpeaker rawSpeaker: String, index: Int, isDerived: Bool) -> String {
        if isDerived {
            return makeFallbackDisplayName(forIndex: index)
        }
        let trimmed = rawSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return makeFallbackDisplayName(forIndex: index)
        }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("speaker_") || lowercased.hasPrefix("speaker ") {
            return makeFallbackDisplayName(forIndex: index)
        }
        return trimmed
    }

    private func makeFallbackDisplayName(forIndex index: Int) -> String {
        "Speaker \(index + 1)"
    }
}
