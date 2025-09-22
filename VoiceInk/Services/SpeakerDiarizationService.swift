import Foundation
import os

@MainActor
final class SpeakerDiarizationService: ObservableObject {
    static let shared = SpeakerDiarizationService()

    enum Model: String, CaseIterable, Identifiable {
        case none
        case whisper
        case pyannote
        case deepgram

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none:
                return String(localized: "Speaker diarization off", defaultValue: "Disabled")
            case .whisper:
                return "Whisper (local)"
            case .pyannote:
                return "pyannote (cloud)"
            case .deepgram:
                return "Deepgram (cloud)"
            }
        }

        var description: String {
            switch self {
            case .none:
                return "Speaker labels will not be generated."
            case .whisper:
                return "Use the bundled whisper.cpp speaker model when available."
            case .pyannote:
                return "Requires external integration. Falls back to heuristic labels when unavailable."
            case .deepgram:
                return "Uses Deepgram diarization if configured. Falls back to heuristics otherwise."
            }
        }
    }

    struct SpeakerSegment {
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private static let defaultsKey = "SelectedSpeakerDiarizationModel"

    @Published var selectedModel: Model {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.defaultsKey)
        }
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerDiarizationService")

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let stored = Model(rawValue: raw) {
            selectedModel = stored
        } else {
            selectedModel = .whisper
        }
    }

    var isEnabled: Bool { selectedModel != .none }

    func diarize(baseSegments: [WhisperSegment], transcriptionText: String, audioURL: URL?) async -> [SpeakerSegment] {
        let trimmedText = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }

        guard isEnabled else { return [] }

        let segments = sanitize(baseSegments: baseSegments, fallbackText: trimmedText)

        switch selectedModel {
        case .whisper:
            return assignSpeakers(using: segments)
        case .pyannote, .deepgram:
            logger.notice("External diarization model \(selectedModel.rawValue) is not configured; using fallback labels.")
            return assignSpeakers(using: segments)
        case .none:
            return []
        }
    }

    private func sanitize(baseSegments: [WhisperSegment], fallbackText: String) -> [WhisperSegment] {
        let prepared = baseSegments.compactMap { segment -> WhisperSegment? in
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return WhisperSegment(
                index: segment.index,
                text: trimmed,
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker
            )
        }

        if !prepared.isEmpty {
            return prepared
        }

        guard !fallbackText.isEmpty else { return [] }
        return [WhisperSegment(index: 0, text: fallbackText, start: 0, end: 0, speaker: nil)]
    }

    private func assignSpeakers(using segments: [WhisperSegment]) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return [] }

        var speakerMap: [String: String] = [:]
        var generatedIndex = 1

        return segments.map { segment in
            let label: String
            if let speakerId = segment.speaker, !speakerId.isEmpty {
                if let mapped = speakerMap[speakerId] {
                    label = mapped
                } else {
                    let generated = "Speaker \(generatedIndex)"
                    speakerMap[speakerId] = generated
                    generatedIndex += 1
                    label = generated
                }
            } else {
                let generated = "Speaker \(generatedIndex)"
                generatedIndex += 1
                label = generated
            }

            return SpeakerSegment(
                speaker: label,
                start: segment.start,
                end: segment.end,
                text: segment.text
            )
        }
    }
}
