import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import KeyboardShortcuts
import os

// MARK: - Recording State Machine
enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case enhancing
    case busy
}

@MainActor
class WhisperState: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var isModelLoaded = false
    @Published var loadedLocalModel: WhisperModel?
    @Published var currentTranscriptionModel: (any TranscriptionModel)?
    @Published var isModelLoading = false
    @Published var availableModels: [WhisperModel] = []
    @Published var allAvailableModels: [any TranscriptionModel] = PredefinedModels.models
    @Published var clipboardMessage = ""
    @Published var miniRecorderError: String?
    @Published var shouldCancelRecording = false


    @Published var recorderType: String = UserDefaults.standard.string(forKey: "RecorderType") ?? "mini" {
        didSet {
            UserDefaults.standard.set(recorderType, forKey: "RecorderType")
        }
    }
    
    @Published var isMiniRecorderVisible = false {
        didSet {
            if isMiniRecorderVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }
    
    var whisperContext: WhisperContext?
    let recorder = Recorder()
    var recordedFile: URL? = nil
    let whisperPrompt = WhisperPrompt()

    private var currentRecordingSessionID: UUID?
    private var latestSessionID: UUID?

    // Prompt detection service for trigger word handling
    private let promptDetectionService = PromptDetectionService()
    
    let modelContext: ModelContext
    
    // Transcription Services
    private var localTranscriptionService: LocalTranscriptionService!
    private lazy var cloudTranscriptionService = CloudTranscriptionService()
    private lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private lazy var parakeetTranscriptionService = ParakeetTranscriptionService(customModelsDirectory: parakeetModelsDirectory)
    
    private var modelUrl: URL? {
        let possibleURLs = [
            Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin", subdirectory: "Models"),
            Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin"),
            Bundle.main.bundleURL.appendingPathComponent("Models/ggml-base.en.bin")
        ]
        
        for url in possibleURLs {
            if let url = url, FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
    
    private enum LoadError: Error {
        case couldNotLocateModel
    }
    
    let modelsDirectory: URL
    let recordingsDirectory: URL
    let parakeetModelsDirectory: URL
    let enhancementService: AIEnhancementService?
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperState")
    var notchWindowManager: NotchWindowManager?
    var miniWindowManager: MiniWindowManager?
    
    // For model progress tracking
    @Published var downloadProgress: [String: Double] = [:]
    @Published var isDownloadingParakeet = false
    
    init(modelContext: ModelContext, enhancementService: AIEnhancementService? = nil) {
        self.modelContext = modelContext
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        
        self.modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")
        self.parakeetModelsDirectory = appSupportDirectory.appendingPathComponent("ParakeetModels")
        
        self.enhancementService = enhancementService
        super.init()
        
        // Configure the session manager
        if let enhancementService = enhancementService {
            PowerModeSessionManager.shared.configure(whisperState: self, enhancementService: enhancementService)
        }
        
        // Set the whisperState reference after super.init()
        self.localTranscriptionService = LocalTranscriptionService(modelsDirectory: self.modelsDirectory, whisperState: self)
        
        setupNotifications()
        createModelsDirectoryIfNeeded()
        createRecordingsDirectoryIfNeeded()
        loadAvailableModels()
        loadCurrentTranscriptionModel()
        refreshAllAvailableModels()
    }
    
    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("Error creating recordings directory: \(error.localizedDescription)")
        }
    }
    
    func toggleRecord() async {
        if recordingState == .recording {
            let sessionID = currentRecordingSessionID ?? UUID()
            currentRecordingSessionID = nil

            await recorder.stopRecording()
            if let recordedFile {
                if !shouldCancelRecording {
                    let fileURL = recordedFile
                    Task { [weak self] in
                        await self?.transcribeAudio(fileURL, sessionID: sessionID)
                    }
                } else {
                    recordingState = .idle
                    latestSessionID = nil
                    await cleanupModelResources()
                }
            } else {
                logger.error("❌ No recorded file found after stopping recording")
                recordingState = .idle
                latestSessionID = nil
            }
        } else {
            guard currentTranscriptionModel != nil else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "notifications.noAIModelSelected"),
                    type: .error
                )
                return
            }
            shouldCancelRecording = false
            requestRecordPermission { [self] granted in
                if granted {
                    Task {
                        let sessionID = UUID()
                        let previousSessionID = self.latestSessionID
                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL
                            self.latestSessionID = sessionID

                            try await self.recorder.startRecording(toOutputFile: permanentURL)
                            self.currentRecordingSessionID = sessionID

                            self.recordingState = .recording

                            await ActiveWindowService.shared.applyConfigurationForCurrentApp()

                            if let model = self.currentTranscriptionModel {
                                switch model.provider {
                                case .local:
                                    if let localWhisperModel = self.availableModels.first(where: { $0.name == model.name }),
                                       self.whisperContext == nil {
                                        do {
                                            try await self.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error.localizedDescription)")
                                        }
                                    }
                                case .parakeet:
                                    try? await self.parakeetTranscriptionService.loadModel()
                                default:
                                    break
                                }
                            }

                            if let enhancementService = self.enhancementService,
                               enhancementService.useScreenCaptureContext {
                                await enhancementService.captureScreenContext()
                            }

                        } catch {
                            self.logger.error("❌ Failed to start recording: \(error.localizedDescription)")
                            self.latestSessionID = previousSessionID
                            self.currentRecordingSessionID = nil
                            await NotificationManager.shared.showNotification(
                                title: String(localized: "notifications.recordingFailedToStart"),
                                type: .error
                            )
                            await self.dismissMiniRecorder()
                            self.recordedFile = nil
                        }
                    }
                } else {
                    logger.error("❌ Recording permission denied.")
                }
            }
        }
    }
    
    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }
    
    private func transcribeAudio(_ url: URL, sessionID: UUID) async {
        if shouldCancelRecording {
            _ = await dismissIfCurrentSession(sessionID)
            return
        }

        updateRecordingState(.transcribing, for: sessionID)

        Task {
            let isSystemMuteEnabled = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled")
            if isSystemMuteEnabled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run {
                SoundManager.shared.playStopSound()
            }
        }

        logger.notice("🔄 Starting transcription...")

        do {
            guard let model = currentTranscriptionModel else {
                throw WhisperStateError.transcriptionFailed
            }

            let transcriptionService: TranscriptionService
            switch model.provider {
            case .local:
                transcriptionService = localTranscriptionService
            case .parakeet:
                transcriptionService = parakeetTranscriptionService
            case .nativeApple:
                transcriptionService = nativeAppleTranscriptionService
            default:
                transcriptionService = cloudTranscriptionService
            }

            let transcriptionStart = Date()
            var text = try await transcriptionService.transcribe(audioURL: url, model: model)
            text = WhisperHallucinationFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if await checkCancellationAndCleanup(for: sessionID) { return }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.object(forKey: "IsTextFormattingEnabled") as? Bool ?? true {
                text = WhisperTextFormatter.format(text)
            }

            if UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled") {
                text = WordReplacementService.shared.applyReplacements(to: text)
            }

            let audioAsset = AVURLAsset(url: url)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0
            var promptDetectionResult: PromptDetectionService.PromptDetectionResult? = nil
            let originalText = text

            if let enhancementService = enhancementService, enhancementService.isConfigured {
                let detectionResult = promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }

            if let enhancementService = enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured {
                do {
                    if await checkCancellationAndCleanup(for: sessionID) { return }

                    updateRecordingState(.enhancing, for: sessionID)
                    let textForAI = promptDetectionResult?.processedText ?? text
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(textForAI)
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: actualDuration,
                        enhancedText: enhancedText,
                        audioFileURL: url.absoluteString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementService.getAIService()?.currentModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent
                    )
                    modelContext.insert(newTranscription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                    text = enhancedText
                } catch {
                    if error is CancellationError {
                        return
                    }
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: actualDuration,
                        enhancedText: String(
                            format: String(localized: "transcription.enhancementFailedFormat"),
                            locale: Locale.current,
                            error.localizedDescription
                        ),
                        audioFileURL: url.absoluteString,
                        transcriptionModelName: model.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration
                    )
                    modelContext.insert(newTranscription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)

                    await NotificationManager.shared.showNotification(
                        title: String(localized: "notifications.aiEnhancementFailed"),
                        type: .error
                    )
                }
            } else {
                let newTranscription = Transcription(
                    text: originalText,
                    duration: actualDuration,
                    audioFileURL: url.absoluteString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration
                )
                modelContext.insert(newTranscription)
                try? modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
            }

            let shouldAddSpace = UserDefaults.standard.object(forKey: "AppendTrailingSpace") as? Bool ?? true
            if shouldAddSpace {
                text += " "
            }

            if await checkCancellationAndCleanup(for: sessionID) { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CursorPaster.pasteAtCursor(text)

                let powerMode = PowerModeManager.shared
                if let activeConfig = powerMode.currentActiveConfiguration, activeConfig.isAutoSendEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        CursorPaster.pressEnter()
                    }
                }
            }

            if let result = promptDetectionResult,
               let enhancementService = enhancementService,
               result.shouldEnableAI {
                await promptDetectionService.restoreOriginalSettings(result, to: enhancementService)
            }

            await dismissIfCurrentSession(sessionID)

        } catch {
            do {
                let audioAsset = AVURLAsset(url: url)
                let duration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

                let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
                let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

                let failedTranscription = Transcription(
                    text: String(
                        format: String(localized: "transcription.failedFormat"),
                        locale: Locale.current,
                        fullErrorText
                    ),
                    duration: duration,
                    enhancedText: nil,
                    audioFileURL: url.absoluteString,
                    promptName: nil
                )

                modelContext.insert(failedTranscription)
                try? modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: failedTranscription)
            } catch {
                logger.error("❌ Could not create a record for the failed transcription: \(error.localizedDescription)")
            }

            await NotificationManager.shared.showNotification(
                title: String(localized: "notifications.transcriptionFailed"),
                type: .error
            )

            await dismissIfCurrentSession(sessionID)
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    private func canManageUI(for sessionID: UUID) -> Bool {
        latestSessionID == sessionID && currentRecordingSessionID == nil
    }

    private func updateRecordingState(_ state: RecordingState, for sessionID: UUID) {
        if canManageUI(for: sessionID) {
            recordingState = state
        }
    }

    @discardableResult
    private func dismissIfCurrentSession(_ sessionID: UUID) async -> Bool {
        guard canManageUI(for: sessionID) else { return false }
        await dismissMiniRecorder()
        resetSessionTracking()
        return true
    }

    private func checkCancellationAndCleanup(for sessionID: UUID) async -> Bool {
        if shouldCancelRecording {
            await dismissIfCurrentSession(sessionID)
            return true
        }
        return false
    }

    func clearCurrentRecordingSession() {
        currentRecordingSessionID = nil
    }

    func resetSessionTracking() {
        currentRecordingSessionID = nil
        latestSessionID = nil
    }
}
