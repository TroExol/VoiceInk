import Foundation
import SwiftData
import os

@MainActor
final class SpeakerDiarizationService: ObservableObject {
    static let shared = SpeakerDiarizationService()

    @Published var selectedMode: SpeakerDiarizationMode {
        didSet {
            UserDefaults.standard.set(selectedMode.rawValue, forKey: SpeakerDiarizationMode.userDefaultsKey)
        }
    }

    @Published private(set) var lastFallbackReason: String?

    let availableModes: [SpeakerDiarizationMode] = SpeakerDiarizationMode.allCases

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerDiarizationService")

    private init() {
        if let stored = UserDefaults.standard.string(forKey: SpeakerDiarizationMode.userDefaultsKey),
           let mode = SpeakerDiarizationMode(rawValue: stored) {
            selectedMode = mode
        } else {
            selectedMode = .whisperLocal
        }
    }

    func attachSegments(
        to transcription: Transcription,
        text: String,
        audioURL _: URL?,
        in modelContext: ModelContext,
        localSegments: [WhisperSegment]
    ) async {
        let mode = selectedMode

        guard mode != .off else {
            clearSegments(for: transcription, in: modelContext)
            lastFallbackReason = nil
            return
        }

        var generatedSegments: [TranscriptionSegment] = []
        lastFallbackReason = nil

        switch mode {
        case .whisperLocal:
            if !localSegments.isEmpty {
                generatedSegments = localSegments.compactMap { segment in
                    let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedText.isEmpty else { return nil }
                    return TranscriptionSegment(
                        speaker: segment.speaker,
                        start: segment.start,
                        end: segment.end,
                        text: trimmedText,
                        transcription: transcription
                    )
                }
            } else {
                logger.warning("No local diarization segments returned; falling back to single speaker view.")
                lastFallbackReason = "local"
            }
        case .pyannote:
            logger.warning("pyannote diarization is not configured. Falling back to single speaker segments.")
            lastFallbackReason = "pyannote"
        case .deepgram:
            logger.warning("Deepgram diarization is not configured. Falling back to single speaker segments.")
            lastFallbackReason = "deepgram"
        case .off:
            break
        }

        if generatedSegments.isEmpty {
            if lastFallbackReason == nil && mode != .off {
                lastFallbackReason = "local"
            }
            let fallbackSegment = TranscriptionSegment(
                speaker: nil,
                start: 0,
                end: transcription.duration,
                text: text,
                transcription: transcription
            )
            generatedSegments = [fallbackSegment]
        }

        clearSegments(for: transcription, in: modelContext)
        for segment in generatedSegments {
            modelContext.insert(segment)
        }

        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save diarization segments: \(error.localizedDescription)")
        }
    }

    private func clearSegments(for transcription: Transcription, in modelContext: ModelContext) {
        if !transcription.segments.isEmpty {
            transcription.segments.forEach { segment in
                modelContext.delete(segment)
            }
            transcription.segments.removeAll()
        }
    }
}
