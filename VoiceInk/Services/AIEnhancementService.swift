import Foundation
import SwiftData
import AppKit
import os
import CryptoKit

enum EnhancementPrompt {
    case transcriptionEnhancement
    case aiAssistant
}

class AIEnhancementService: ObservableObject {
    private struct EnhancementResult: Sendable {
        let text: String
        let duration: TimeInterval
        let promptName: String?
    }
    
    private actor EnhancementRequestCoordinator {
        struct Group {
            var tasks: [UUID: Task<EnhancementResult, Error>] = [:]
        }
        
        private var groups: [String: Group] = [:]
        
        func prepare(signature: String, requestID: UUID) {
            if groups[signature] == nil {
                groups[signature] = Group()
            }
        }
        
        func attach(signature: String, requestID: UUID, task: Task<EnhancementResult, Error>) {
            guard var group = groups[signature] else {
                task.cancel()
                return
            }
            group.tasks[requestID] = task
            groups[signature] = group
        }
        
        func markSuccess(signature: String, requestID: UUID) -> (shouldDeliver: Bool, tasksToCancel: [Task<EnhancementResult, Error>]) {
            guard let group = groups.removeValue(forKey: signature) else {
                return (false, [])
            }
            let tasksToCancel = group.tasks.compactMap { $0.key == requestID ? nil : $0.value }
            return (true, tasksToCancel)
        }
        
        func markFailure(signature: String, requestID: UUID) {
            guard var group = groups[signature] else { return }
            group.tasks.removeValue(forKey: requestID)
            if group.tasks.isEmpty {
                groups.removeValue(forKey: signature)
            } else {
                groups[signature] = group
            }
        }
    }
    private let logger = Logger(subsystem: "com.voiceink.enhancement", category: "AIEnhancementService")

    @Published var isEnhancementEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnhancementEnabled, forKey: "isAIEnhancementEnabled")
            if isEnhancementEnabled && selectedPromptId == nil {
                selectedPromptId = customPrompts.first?.id
            }
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            NotificationCenter.default.post(name: .enhancementToggleChanged, object: nil)
        }
    }

    @Published var useClipboardContext: Bool {
        didSet {
            UserDefaults.standard.set(useClipboardContext, forKey: "useClipboardContext")
        }
    }

    @Published var useScreenCaptureContext: Bool {
        didSet {
            UserDefaults.standard.set(useScreenCaptureContext, forKey: "useScreenCaptureContext")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published var customPrompts: [CustomPrompt] {
        didSet {
            if let encoded = try? JSONEncoder().encode(customPrompts) {
                UserDefaults.standard.set(encoded, forKey: "customPrompts")
            }
        }
    }

    @Published var selectedPromptId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPromptId?.uuidString, forKey: "selectedPromptId")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            NotificationCenter.default.post(name: .promptSelectionChanged, object: nil)
        }
    }

    @Published var lastSystemMessageSent: String?
    @Published var lastUserMessageSent: String?

    var activePrompt: CustomPrompt? {
        allPrompts.first { $0.id == selectedPromptId }
    }

    var allPrompts: [CustomPrompt] {
        return customPrompts
    }

    private let aiService: AIService
    private let screenCaptureService: ScreenCaptureService
    private let dictionaryContextService: DictionaryContextService
    private let baseTimeout: TimeInterval = 30
    private let rateLimitInterval: TimeInterval = 1.0
    private var lastRequestTime: Date?
    private let modelContext: ModelContext
    private let requestCoordinator = EnhancementRequestCoordinator()

    init(aiService: AIService = AIService(), modelContext: ModelContext) {
        self.aiService = aiService
        self.modelContext = modelContext
        self.screenCaptureService = ScreenCaptureService()
        self.dictionaryContextService = DictionaryContextService.shared

        self.isEnhancementEnabled = UserDefaults.standard.bool(forKey: "isAIEnhancementEnabled")
        self.useClipboardContext = UserDefaults.standard.bool(forKey: "useClipboardContext")
        self.useScreenCaptureContext = UserDefaults.standard.bool(forKey: "useScreenCaptureContext")

        self.customPrompts = PromptMigrationService.migratePromptsIfNeeded()

        if let savedPromptId = UserDefaults.standard.string(forKey: "selectedPromptId") {
            self.selectedPromptId = UUID(uuidString: savedPromptId)
        }

        if isEnhancementEnabled && (selectedPromptId == nil || !allPrompts.contains(where: { $0.id == selectedPromptId })) {
            self.selectedPromptId = allPrompts.first?.id
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAPIKeyChange),
            name: .aiProviderKeyChanged,
            object: nil
        )

        initializePredefinedPrompts()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAPIKeyChange() {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            if !self.aiService.isAPIKeyValid {
                self.isEnhancementEnabled = false
            }
        }
    }

    func getAIService() -> AIService? {
        return aiService
    }

    var isConfigured: Bool {
        aiService.isAPIKeyValid
    }

    private func waitForRateLimit() async throws {
        if let lastRequest = lastRequestTime {
            let timeSinceLastRequest = Date().timeIntervalSince(lastRequest)
            if timeSinceLastRequest < rateLimitInterval {
                try await Task.sleep(nanoseconds: UInt64((rateLimitInterval - timeSinceLastRequest) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    private func getSystemMessage(for mode: EnhancementPrompt) -> String {
        let selectedText = SelectedTextService.fetchSelectedText()

        if let activePrompt = activePrompt,
           activePrompt.id == PredefinedPrompts.assistantPromptId,
           let selectedText = selectedText, !selectedText.isEmpty {

            let selectedTextContext = "\n\nSelected Text: \(selectedText)"
            let generalContextSection = "\n\n<CONTEXT_INFORMATION>\(selectedTextContext)\n</CONTEXT_INFORMATION>"
            let dictionaryContextSection = if !dictionaryContextService.getDictionaryContext().isEmpty {
                "\n\n<DICTIONARY_CONTEXT>\(dictionaryContextService.getDictionaryContext())\n</DICTIONARY_CONTEXT>"
            } else {
                ""
            }
            return activePrompt.promptText + generalContextSection + dictionaryContextSection
        }

        let clipboardContext = if useClipboardContext,
                              let clipboardText = NSPasteboard.general.string(forType: .string),
                              !clipboardText.isEmpty {
            "\n\n<CLIPBOARD_CONTEXT>\n\(clipboardText)\n</CLIPBOARD_CONTEXT>"
        } else {
            ""
        }

        let screenCaptureContext = if useScreenCaptureContext,
                                   let capturedText = screenCaptureService.lastCapturedText,
                                   !capturedText.isEmpty {
            "\n\nActive Window Context: \(capturedText)"
        } else {
            ""
        }

        let dictionaryContext = dictionaryContextService.getDictionaryContext()

        let generalContextSection = if !clipboardContext.isEmpty || !screenCaptureContext.isEmpty {
            "\n\n<CONTEXT_INFORMATION>\(clipboardContext)\(screenCaptureContext)\n</CONTEXT_INFORMATION>"
        } else {
            ""
        }

        let dictionaryContextSection = if !dictionaryContext.isEmpty {
            "\n\n<DICTIONARY_CONTEXT>\(dictionaryContext)\n</DICTIONARY_CONTEXT>"
        } else {
            ""
        }

        guard let activePrompt = activePrompt else {
            if let defaultPrompt = allPrompts.first(where: { $0.id == PredefinedPrompts.defaultPromptId }) {
                var systemMessage = String(format: AIPrompts.customPromptTemplate, defaultPrompt.promptText)
                systemMessage += generalContextSection + dictionaryContextSection
                return systemMessage
            }
            return AIPrompts.assistantMode + generalContextSection + dictionaryContextSection
        }

        if activePrompt.id == PredefinedPrompts.assistantPromptId {
            return activePrompt.promptText + generalContextSection + dictionaryContextSection
        }

        var systemMessage = String(format: AIPrompts.customPromptTemplate, activePrompt.promptText)
        systemMessage += generalContextSection + dictionaryContextSection
        return systemMessage
    }

    private func makeRequest(text: String, mode: EnhancementPrompt, timeout: TimeInterval) async throws -> String {
        guard isConfigured else {
            throw EnhancementError.notConfigured
        }

        guard !text.isEmpty else {
            return "" // Silently return empty string instead of throwing error
        }

        let formattedText = "\n<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>"
        let systemMessage = getSystemMessage(for: mode)
        
        // Persist the exact payload being sent (also used for UI)
        self.lastSystemMessageSent = systemMessage
        self.lastUserMessageSent = formattedText

        // Log the message being sent to AI enhancement
        logger.notice("AI Enhancement - System Message: \(systemMessage, privacy: .public)")
        logger.notice("AI Enhancement - User Message: \(formattedText, privacy: .public)")

        if aiService.selectedProvider == .ollama {
            do {
                let result = try await aiService.enhanceWithOllama(text: formattedText, systemPrompt: systemMessage)
                let filteredResult = AIEnhancementOutputFilter.filter(result)
                return filteredResult
            } catch {
                if let localError = error as? LocalAIError {
                    throw EnhancementError.customError(localError.errorDescription ?? "An unknown Ollama error occurred.")
                } else {
                    throw EnhancementError.customError(error.localizedDescription)
                }
            }
        }

        try await waitForRateLimit()

        switch aiService.selectedProvider {
        case .anthropic:
            let requestBody: [String: Any] = [
                "model": aiService.currentModel,
                "max_tokens": 8192,
                "system": systemMessage,
                "messages": [
                    ["role": "user", "content": formattedText]
                ]
            ]

            var request = URLRequest(url: URL(string: aiService.selectedProvider.baseURL)!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue(aiService.apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = timeout
            request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw EnhancementError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let content = jsonResponse["content"] as? [[String: Any]],
                          let firstContent = content.first,
                          let enhancedText = firstContent["text"] as? String else {
                        throw EnhancementError.enhancementFailed
                    }

                    let filteredText = AIEnhancementOutputFilter.filter(enhancedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    return filteredText
                } else if httpResponse.statusCode == 429 {
                    throw EnhancementError.rateLimitExceeded
                } else if (500...599).contains(httpResponse.statusCode) {
                    throw EnhancementError.serverError
                } else {
                    let errorString = String(data: data, encoding: .utf8) ?? "Could not decode error response."
                    throw EnhancementError.customError("HTTP \(httpResponse.statusCode): \(errorString)")
                }

            } catch let error as EnhancementError {
                throw error
            } catch let error as URLError {
                throw error
            } catch {
                throw EnhancementError.customError(error.localizedDescription)
            }

        default:
            let url = URL(string: aiService.selectedProvider.baseURL)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(aiService.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = timeout

            let messages: [[String: Any]] = [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": formattedText]
            ]

            let requestBody: [String: Any] = [
                "model": aiService.currentModel,
                "messages": messages,
                "temperature": aiService.currentModel.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3,
                "stream": false
            ]

            request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw EnhancementError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = jsonResponse["choices"] as? [[String: Any]],
                          let firstChoice = choices.first,
                          let message = firstChoice["message"] as? [String: Any],
                          let enhancedText = message["content"] as? String else {
                        throw EnhancementError.enhancementFailed
                    }

                    let filteredText = AIEnhancementOutputFilter.filter(enhancedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    return filteredText
                } else if httpResponse.statusCode == 429 {
                    throw EnhancementError.rateLimitExceeded
                } else if (500...599).contains(httpResponse.statusCode) {
                    throw EnhancementError.serverError
                } else {
                    let errorString = String(data: data, encoding: .utf8) ?? "Could not decode error response."
                    throw EnhancementError.customError("HTTP \(httpResponse.statusCode): \(errorString)")
                }

            } catch let error as EnhancementError {
                throw error
            } catch let error as URLError {
                throw error
            } catch {
                throw EnhancementError.customError(error.localizedDescription)
            }
        }
    }

    private func makeRequestWithRetry(text: String, mode: EnhancementPrompt) async throws -> String {
        let maxAttempts = 3
        let launchInterval = baseTimeout

        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: (Int, Result<String, Error>).self, returning: String.self) { group in
            for attemptIndex in 0..<maxAttempts {
                let delay = TimeInterval(attemptIndex) * launchInterval
                let attemptTimeout = launchInterval * TimeInterval(maxAttempts - attemptIndex)

                group.addTask { [weak self, delay, attemptTimeout] in
                    do {
                        if delay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }

                        try Task.checkCancellation()

                        guard let self else {
                            throw CancellationError()
                        }

                        let value = try await self.makeRequest(text: text, mode: mode, timeout: attemptTimeout)
                        return (attemptIndex, .success(value))
                    } catch {
                        return (attemptIndex, .failure(error))
                    }
                }
            }

            var lastError: Error?

            while let result = try await group.next() {
                switch result.1 {
                case .success(let value):
                    group.cancelAll()
                    return value
                case .failure(let error):
                    if error is CancellationError {
                        group.cancelAll()
                        throw error
                    }

                    lastError = error
                    if result.0 == maxAttempts - 1 {
                        group.cancelAll()
                        throw lastError ?? EnhancementError.enhancementFailed
                    }
                }
            }

            throw lastError ?? EnhancementError.enhancementFailed
        }
    }

    func enhance(_ text: String) async throws -> (String, TimeInterval, String?) {
        let signature = buildSignature(for: text)
        let requestID = UUID()
        await requestCoordinator.prepare(signature: signature, requestID: requestID)
        let task = Task<EnhancementResult, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performEnhancement(text)
        }
        await requestCoordinator.attach(signature: signature, requestID: requestID, task: task)

        do {
            let result = try await task.value
            let (shouldDeliver, tasksToCancel) = await requestCoordinator.markSuccess(signature: signature, requestID: requestID)
            for otherTask in tasksToCancel {
                otherTask.cancel()
            }
            guard shouldDeliver else {
                task.cancel()
                throw CancellationError()
            }
            return (result.text, result.duration, result.promptName)
        } catch {
            await requestCoordinator.markFailure(signature: signature, requestID: requestID)
            throw error
        }
    }

    private func performEnhancement(_ text: String) async throws -> EnhancementResult {
        let startTime = Date()
        let enhancementPrompt: EnhancementPrompt = .transcriptionEnhancement
        let promptName = activePrompt?.title
        let result = try await makeRequestWithRetry(text: text, mode: enhancementPrompt)
        let duration = Date().timeIntervalSince(startTime)
        return EnhancementResult(text: result, duration: duration, promptName: promptName)
    }

    private func buildSignature(for text: String) -> String {
        let promptID = activePrompt?.id.uuidString ?? "none"
        let provider = aiService.selectedProvider.rawValue
        let model = aiService.currentModel
        let payload = [text, promptID, provider, model].joined(separator: "|::|")
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func captureScreenContext() async {
        guard useScreenCaptureContext else { return }

        if let capturedText = await screenCaptureService.captureAndExtractText() {
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }

    func addPrompt(title: String, promptText: String, icon: PromptIcon = .documentFill, description: String? = nil, triggerWords: [String] = []) {
        let newPrompt = CustomPrompt(title: title, promptText: promptText, icon: icon, description: description, isPredefined: false, triggerWords: triggerWords)
        customPrompts.append(newPrompt)
        if customPrompts.count == 1 {
            selectedPromptId = newPrompt.id
        }
    }

    func updatePrompt(_ prompt: CustomPrompt) {
        if let index = customPrompts.firstIndex(where: { $0.id == prompt.id }) {
            customPrompts[index] = prompt
        }
    }

    func deletePrompt(_ prompt: CustomPrompt) {
        customPrompts.removeAll { $0.id == prompt.id }
        if selectedPromptId == prompt.id {
            selectedPromptId = allPrompts.first?.id
        }
    }

    func setActivePrompt(_ prompt: CustomPrompt) {
        selectedPromptId = prompt.id
    }

    private func initializePredefinedPrompts() {
        let predefinedTemplates = PredefinedPrompts.createDefaultPrompts()

        for template in predefinedTemplates {
            if let existingIndex = customPrompts.firstIndex(where: { $0.id == template.id }) {
                var updatedPrompt = customPrompts[existingIndex]
                updatedPrompt = CustomPrompt(
                    id: updatedPrompt.id,
                    title: template.title,
                    promptText: template.promptText,
                    isActive: updatedPrompt.isActive,
                    icon: template.icon,
                    description: template.description,
                    isPredefined: true,
                    triggerWords: updatedPrompt.triggerWords
                )
                customPrompts[existingIndex] = updatedPrompt
            } else {
                customPrompts.append(template)
            }
        }
    }
}

enum EnhancementError: Error {
    case notConfigured
    case invalidResponse
    case enhancementFailed
    case networkError
    case serverError
    case rateLimitExceeded
    case customError(String)
}

extension EnhancementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI provider not configured. Please check your API key."
        case .invalidResponse:
            return "Invalid response from AI provider."
        case .enhancementFailed:
            return "AI enhancement failed to process the text."
        case .networkError:
            return "Network connection failed. Check your internet."
        case .serverError:
            return "The AI provider's server encountered an error. Please try again later."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .customError(let message):
            return message
        }
    }
}
