import SwiftUI

struct APIKeyManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var apiKey: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isVerifying = false
    @State private var ollamaBaseURL: String = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
    @State private var ollamaModels: [OllamaService.OllamaModel] = []
    @State private var selectedOllamaModel: String = UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
    @State private var isCheckingOllama = false
    @State private var isEditingURL = false
    @State private var isEditingCustomProvider = false
    @State private var providerTimeout: Double = 30
    @State private var providerAttempts: Int = 3
    
    private let timeoutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximumFractionDigits = 1
        formatter.allowsFloats = true
        formatter.usesGroupingSeparator = false
        return formatter
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header Section
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enhance your transcriptions with AI")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if aiService.isAPIKeyValid && aiService.selectedProvider != .ollama {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Connected to")
                            .font(.caption)
                        Text(aiService.selectedProvider.rawValue)
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .foregroundColor(.secondary)
                    .cornerRadius(6)
                }
            }
            
            // Provider Selection
            Picker("AI Provider", selection: $aiService.selectedProvider) {
                ForEach(AIProvider.allCases.filter { $0 != .elevenLabs && $0 != .deepgram }, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            
            .onChange(of: aiService.selectedProvider) { oldValue, newValue in
                providerTimeout = aiService.timeout(for: newValue)
                providerAttempts = aiService.attempts(for: newValue)
                
                if aiService.selectedProvider == .ollama {
                    checkOllamaConnection()
                }
                if newValue == .custom {
                    isEditingCustomProvider = !aiService.isAPIKeyValid
                    apiKey = ""
                } else {
                    isEditingCustomProvider = false
                }
            }
            
            // Model Selection
            if aiService.selectedProvider == .openRouter {
                HStack {
                    if aiService.availableModels.isEmpty {
                        Text("No models loaded")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Model", selection: Binding(
                            get: { aiService.currentModel },
                            set: { aiService.selectModel($0) }
                        )) {
                            ForEach(aiService.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    
                    
                    
                    Button(action: {
                        Task {
                            await aiService.fetchOpenRouterModels()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .localizedHelp("Refresh models")
                }
            } else if !aiService.availableModels.isEmpty && 
                        aiService.selectedProvider != .ollama && 
                        aiService.selectedProvider != .custom {
                HStack {
                    Picker("Model", selection: Binding(
                        get: { aiService.currentModel },
                        set: { aiService.selectModel($0) }
                    )) {
                        ForEach(aiService.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }
            
            if aiService.selectedProvider == .ollama {
                VStack(alignment: .leading, spacing: 16) {
                    // Header with status
                    HStack {
                        Label("Ollama Configuration", systemImage: "server.rack")
                            .font(.headline)
                        
                        Spacer()
                        
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isCheckingOllama ? Color.orange : (ollamaModels.isEmpty ? Color.red : Color.green))
                                .frame(width: 8, height: 8)
                            Text(isCheckingOllama ? "Checking..." : (ollamaModels.isEmpty ? "Disconnected" : "Connected"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                    }
                    
                    // Server URL
                    HStack {
                        Label("Server URL", systemImage: "link")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if isEditingURL {
                            TextField("Base URL", text: $ollamaBaseURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(maxWidth: 200)
                            
                            Button("Save") {
                                aiService.updateOllamaBaseURL(ollamaBaseURL)
                                checkOllamaConnection()
                                isEditingURL = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Text(ollamaBaseURL)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                            
                            Button(action: { isEditingURL = true }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            
                            Button(action: {
                                ollamaBaseURL = "http://localhost:11434"
                                aiService.updateOllamaBaseURL(ollamaBaseURL)
                                checkOllamaConnection()
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                            .controlSize(.small)
                        }
                    }
                    
                    // Model selection and refresh
                    HStack {
                        Label("Model", systemImage: "cpu")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if ollamaModels.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("No models available")
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        } else {
                            Picker("", selection: $selectedOllamaModel) {
                                ForEach(ollamaModels) { model in
                                    Text(model.name).tag(model.name)
                                }
                            }
                            .onChange(of: selectedOllamaModel) { oldValue, newValue in
                                aiService.updateSelectedOllamaModel(newValue)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 150)
                        }
                        
                        Button(action: { checkOllamaConnection() }) {
                            Label(isCheckingOllama ? "Refreshing..." : "Refresh", systemImage: isCheckingOllama ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                                .font(.caption)
                        }
                        .disabled(isCheckingOllama)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    // Help text for troubleshooting
                    if ollamaModels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Troubleshooting")
                                .font(.subheadline)
                                .bold()
                            
                            VStack(alignment: .leading, spacing: 4) {
                                bulletPoint("Ensure Ollama is installed and running")
                                bulletPoint("Check if the server URL is correct")
                                bulletPoint("Verify you have at least one model pulled")
                            }
                            
                            Button("Learn More") {
                                NSWorkspace.shared.open(URL(string: "https://ollama.ai/download")!)
                            }
                            .font(.caption)
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.03))
                .cornerRadius(12)

            } else if aiService.selectedProvider == .custom {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Custom Provider Configuration")
                                .font(.headline)
                            Spacer()
                            if aiService.isAPIKeyValid {
                                Button(isEditingCustomProvider ? "Done" : "Edit") {
                                    isEditingCustomProvider.toggle()
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Requires OpenAI-compatible API endpoint")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Configuration Fields
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("API Endpoint URL (e.g., https://api.example.com/v1/chat/completions)", text: $aiService.customBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(aiService.isAPIKeyValid && !isEditingCustomProvider)
                        TextField("Model Name (e.g., gpt-4o-mini, claude-3-5-sonnet-20240620)", text: $aiService.customModel)
                            .textFieldStyle(.roundedBorder)
                            .disabled(aiService.isAPIKeyValid && !isEditingCustomProvider)
                        
                        if aiService.isAPIKeyValid && !isEditingCustomProvider {
                            TextField("API Key", text: .constant(String(repeating: "•", count: max(aiService.apiKey.count, 8))))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .disabled(true)
                        } else {
                            if apiKey.isEmpty {
                                SecureField(
                                    "API Key",
                                    text: Binding(
                                        get: { String(repeating: "•", count: max(aiService.apiKey.count, 8)) },
                                        set: { apiKey = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField("API Key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }

                        HStack {
                            Button(action: {
                                let keyToVerify = apiKey.isEmpty ? aiService.apiKey : apiKey
                                guard !keyToVerify.isEmpty else { return }
                                isVerifying = true
                                aiService.saveAPIKey(keyToVerify) { success in
                                    isVerifying = false
                                    if success {
                                        isEditingCustomProvider = false
                                        apiKey = ""
                                    } else {
                                        alertMessage = "Invalid API key. Please check and try again."
                                        showAlert = true
                                    }
                                }
                            }) {
                                HStack {
                                    if isVerifying {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                    Text("Verify Connection")
                                }
                            }
                            .disabled((aiService.customBaseURL.isEmpty || aiService.customModel.isEmpty) || (aiService.apiKey.isEmpty && apiKey.isEmpty))
                            
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.03))
                .cornerRadius(12)
            } else {
                // API Key Display for other providers if valid
                if aiService.isAPIKeyValid {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text(String(repeating: "•", count: 40))
                                .font(.system(.body, design: .monospaced))
                            
                            Spacer()
                            
                            Button(action: {
                                aiService.clearAPIKey()
                            }) {
                                Label("Remove Key", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } else {
                    // API Key Input for other providers
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter your API Key")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(.body, design: .monospaced))
                        
                        HStack {
                            Button(action: {
                                isVerifying = true
                                aiService.saveAPIKey(apiKey) { success in
                                    isVerifying = false
                                    if !success {
                                        alertMessage = "Invalid API key. Please check and try again."
                                        showAlert = true
                                    }
                                    apiKey = ""
                                }
                            }) {
                                HStack {
                                    if isVerifying {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                    Text("Verify and Save")
                                }
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                Text((aiService.selectedProvider == .groq || aiService.selectedProvider == .gemini || aiService.selectedProvider == .cerebras) ? "Free" : "Paid")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                                
                                if aiService.selectedProvider != .ollama && aiService.selectedProvider != .custom {
                                    Button {
                                        let url = switch aiService.selectedProvider {
                                        case .groq:
                                            URL(string: "https://console.groq.com/keys")!
                                        case .openAI:
                                            URL(string: "https://platform.openai.com/api-keys")!
                                        case .gemini:
                                            URL(string: "https://makersuite.google.com/app/apikey")!
                                        case .anthropic:
                                            URL(string: "https://console.anthropic.com/settings/keys")!
                                        case .mistral:
                                            URL(string: "https://console.mistral.ai/api-keys")!
                                        case .elevenLabs:
                                            URL(string: "https://elevenlabs.io/speech-synthesis")!
                                        case .deepgram:
                                            URL(string: "https://console.deepgram.com/api-keys")!
                                        case .ollama, .custom:
                                            URL(string: "")! // This case should never be reached
                                        case .openRouter:
                                            URL(string: "https://openrouter.ai/keys")!
                                        case .cerebras:
                                            URL(string: "https://cloud.cerebras.ai/")!
                                        }
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text("Get API Key")
                                                .foregroundColor(.accentColor)
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption)
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            if aiService.selectedProvider != .ollama {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Request Scheduling", systemImage: "timer")
                            .font(.headline)

                        HStack {
                            Text("Launch interval (s)")
                                .foregroundColor(.secondary)
                            Spacer()
                            TextField("Timeout", value: $providerTimeout, formatter: timeoutFormatter)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 100)
                                .multilineTextAlignment(.trailing)
                        }

                        Stepper(value: $providerAttempts, in: 1...10) {
                            let format = languageManager.localizedString(
                                for: "enhancement.maxAttempts",
                                defaultValue: "Max attempts: %d"
                            )
                            Text(String(format: format, locale: languageManager.locale, providerAttempts))
                        }

                        Text("Each attempt times out after interval × remaining attempts.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            if aiService.selectedProvider == .ollama {
                checkOllamaConnection()
            }
            if aiService.selectedProvider == .custom && !aiService.isAPIKeyValid {
                isEditingCustomProvider = true
            }
            providerTimeout = aiService.timeout(for: aiService.selectedProvider)
            providerAttempts = aiService.attempts(for: aiService.selectedProvider)
        }
        .onChange(of: aiService.isAPIKeyValid) { oldValue, newValue in
            if !newValue {
                isEditingCustomProvider = true
            }
        }
        .onChange(of: providerTimeout) { _, newValue in
            let sanitized = max(newValue, 1)
            if sanitized != providerTimeout {
                providerTimeout = sanitized
                return
            }
            aiService.updateTimeout(for: aiService.selectedProvider, value: sanitized)
        }
        .onChange(of: providerAttempts) { _, newValue in
            let sanitized = max(newValue, 1)
            if sanitized != providerAttempts {
                providerAttempts = sanitized
                return
            }
            aiService.updateAttempts(for: aiService.selectedProvider, value: sanitized)
        }
    }
    
    private func checkOllamaConnection() {
        isCheckingOllama = true
        aiService.checkOllamaConnection { connected in
            if connected {
                Task {
                    ollamaModels = await aiService.fetchOllamaModels()
                    isCheckingOllama = false
                }
            } else {
                ollamaModels = []
                isCheckingOllama = false
                alertMessage = "Could not connect to Ollama. Please check if Ollama is running and the base URL is correct."
                showAlert = true
            }
        }
    }
    
    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•")
            Text(text)
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        return String(format: "%.1f GB", gigabytes)
    }
}
