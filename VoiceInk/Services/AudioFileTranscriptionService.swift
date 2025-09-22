import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?
    
    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let whisperState: WhisperState
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionService")
    private let speakerDiarizationService = SpeakerDiarizationService.shared
    
    // Transcription services
    private let localTranscriptionService: LocalTranscriptionService
    private lazy var cloudTranscriptionService = CloudTranscriptionService()
    private lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private lazy var parakeetTranscriptionService = ParakeetTranscriptionService(customModelsDirectory: whisperState.parakeetModelsDirectory)
    
    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }
    
    init(modelContext: ModelContext, whisperState: WhisperState) {
        self.modelContext = modelContext
        self.whisperState = whisperState
        self.enhancementService = whisperState.enhancementService
        self.localTranscriptionService = LocalTranscriptionService(modelsDirectory: whisperState.modelsDirectory, whisperState: whisperState)
    }
    
    func retranscribeAudio(from url: URL, using model: any TranscriptionModel) async throws -> Transcription {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }
        
        await MainActor.run {
            isTranscribing = true
        }
        
        do {
            // Delegate transcription to appropriate service
            let transcriptionStart = Date()
            var text: String
            var rawSegments: [WhisperTranscriptionSegment] = []

            switch model.provider {
            case .local:
                text = try await localTranscriptionService.transcribe(audioURL: url, model: model)
                rawSegments = localTranscriptionService.consumeLastSegments()
            case .parakeet:
                text = try await parakeetTranscriptionService.transcribe(audioURL: url, model: model)
            case .nativeApple:
                text = try await nativeAppleTranscriptionService.transcribe(audioURL: url, model: model)
            default: // Cloud models
                text = try await cloudTranscriptionService.transcribe(audioURL: url, model: model)
            }
            
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = WhisperHallucinationFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.object(forKey: "IsTextFormattingEnabled") as? Bool ?? true {
                text = WhisperTextFormatter.format(text)
            }

            // Apply word replacements if enabled
            let isWordReplacementEnabled = UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled")
            if isWordReplacementEnabled {
                text = WordReplacementService.shared.applyReplacements(to: text)
                logger.notice("✅ Word replacements applied")
            }

            // Get audio duration
            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            
            // Create a permanent copy of the audio file
            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.prakashjoshipax.VoiceInk")
                .appendingPathComponent("Recordings")
            
            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)
            
            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error.localizedDescription)")
                isTranscribing = false
                throw error
            }
            
            let permanentURLString = permanentURL.absoluteString

            var diarizedSegments = await speakerDiarizationService.assignSpeakers(
                rawSegments: rawSegments,
                fullText: text,
                totalDuration: duration,
                audioURL: url
            )

            diarizedSegments = prepareSegments(
                diarizedSegments,
                applyWordReplacement: isWordReplacementEnabled,
                derivedFromRawSegments: !rawSegments.isEmpty
            )

            if diarizedSegments.isEmpty, !text.isEmpty {
                diarizedSegments = [SpeakerSegment(speaker: nil, start: 0, end: duration, text: text)]
            }
            
            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured {
                do {
                    // inside the enhancement success path where newTranscription is created
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(text)
                    let newTranscription = Transcription(
                        text: text,
                        duration: duration,
                        enhancedText: enhancedText,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementService.getAIService()?.currentModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent
                    )
                    attachSegments(diarizedSegments, to: newTranscription)
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error.localizedDescription)")
                    }
                    
                    await MainActor.run {
                        isTranscribing = false
                    }

                    return newTranscription
                } catch {
                    if error is CancellationError {
                        await MainActor.run {
                            isTranscribing = false
                        }
                        throw error
                    }
                    let newTranscription = Transcription(
                        text: text,
                        duration: duration,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration
                    )
                    attachSegments(diarizedSegments, to: newTranscription)
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error.localizedDescription)")
                    }
                    
                    await MainActor.run {
                        isTranscribing = false
                    }
                    
                    return newTranscription
                }
            } else {
                let newTranscription = Transcription(
                    text: text,
                    duration: duration,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration
                )
                attachSegments(diarizedSegments, to: newTranscription)
                modelContext.insert(newTranscription)
                do {
                    try modelContext.save()
                } catch {
                    logger.error("❌ Failed to save transcription: \(error.localizedDescription)")
                }
                
                await MainActor.run {
                    isTranscribing = false
                }
                
                return newTranscription
            }
        } catch {
            if error is CancellationError {
                isTranscribing = false
                throw error
            }
            logger.error("❌ Transcription failed: \(error.localizedDescription)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }

    private func prepareSegments(_ segments: [SpeakerSegment], applyWordReplacement: Bool, derivedFromRawSegments: Bool) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return [] }
        return segments.map { segment in
            var normalizedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if applyWordReplacement && derivedFromRawSegments {
                normalizedText = WordReplacementService.shared.applyReplacements(to: normalizedText)
            }
            return SpeakerSegment(
                speaker: segment.speaker,
                start: segment.start,
                end: segment.end,
                text: normalizedText
            )
        }
    }

    private func attachSegments(_ segments: [SpeakerSegment], to transcription: Transcription) {
        guard !segments.isEmpty else { return }
        transcription.segments.removeAll()
        for segment in segments {
            let modelSegment = TranscriptionSegment(
                speaker: segment.speaker,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                transcription: transcription
            )
            transcription.segments.append(modelSegment)
        }
    }
}
