import Foundation
import os

class CustomModelManager: ObservableObject {
    static let shared = CustomModelManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CustomModelManager")
    private let userDefaults = UserDefaults.standard
    private let customModelsKey = "customCloudModels"
    
    @Published var customModels: [CustomCloudModel] = []
    
    private init() {
        loadCustomModels()
    }
    
    // MARK: - CRUD Operations
    
    func addCustomModel(_ model: CustomCloudModel) {
        customModels.append(model)
        saveCustomModels()
        logger.info("Added custom model: \(model.displayName)")
    }
    
    func removeCustomModel(withId id: UUID) {
        customModels.removeAll { $0.id == id }
        saveCustomModels()
        logger.info("Removed custom model with ID: \(id)")
    }
    
    func updateCustomModel(_ updatedModel: CustomCloudModel) {
        if let index = customModels.firstIndex(where: { $0.id == updatedModel.id }) {
            customModels[index] = updatedModel
            saveCustomModels()
            logger.info("Updated custom model: \(updatedModel.displayName)")
        }
    }
    
    // MARK: - Persistence
    
    private func loadCustomModels() {
        guard let data = userDefaults.data(forKey: customModelsKey) else {
            logger.info("No custom models found in UserDefaults")
            return
        }
        
        do {
            customModels = try JSONDecoder().decode([CustomCloudModel].self, from: data)
        } catch {
            logger.error("Failed to decode custom models: \(error.localizedDescription)")
            customModels = []
        }
    }
    
    func saveCustomModels() {
        do {
            let data = try JSONEncoder().encode(customModels)
            userDefaults.set(data, forKey: customModelsKey)
        } catch {
            logger.error("Failed to encode custom models: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Validation
    
    func validateModel(name: String, displayName: String, apiEndpoint: String, apiKey: String, modelName: String) -> [String] {
        validateModel(
            name: name,
            displayName: displayName,
            apiEndpoint: apiEndpoint,
            apiKey: apiKey,
            modelName: modelName,
            excludingId: nil
        )
    }

    func validateModel(name: String, displayName: String, apiEndpoint: String, apiKey: String, modelName: String, excludingId: UUID? = nil) -> [String] {
        var errors: [String] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "customModel.validation.nameEmpty"))
        }

        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "customModel.validation.displayNameEmpty"))
        }

        if apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "customModel.validation.apiEndpointEmpty"))
        } else if !isValidURL(apiEndpoint) {
            errors.append(String(localized: "customModel.validation.apiEndpointInvalid"))
        }

        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "customModel.validation.apiKeyEmpty"))
        }

        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "customModel.validation.modelNameEmpty"))
        }

        if customModels.contains(where: { $0.name == name && (excludingId == nil || $0.id != excludingId) }) {
            errors.append(String(localized: "customModel.validation.duplicateName"))
        }

        return errors
    }
    
    private func isValidURL(_ string: String) -> Bool {
        if let url = URL(string: string) {
            return url.scheme != nil && url.host != nil
        }
        return false
    }
} 
