import Foundation
import SwiftUI    // Import to ensure we have access to SwiftUI types if needed

enum PredefinedPrompts {
    private static let predefinedPromptsKey = "PredefinedPrompts"
    
    // Static UUIDs for predefined prompts
    static let defaultPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let assistantPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let chatPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let generalMeetingPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let dailyStandupPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let sprintPlanningPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    static let retrospectivePromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    static let prePlanningPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    static let oneOnOnePromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    
    static var all: [CustomPrompt] {
        // Always return the latest predefined prompts from source code
        createDefaultPrompts()
    }
    
    static func createDefaultPrompts() -> [CustomPrompt] {
        [
            CustomPrompt(
                id: defaultPromptId,
                title: "Default",
                promptText: PromptTemplates.all.first { $0.title == "System Default" }?.promptText ?? "",
                icon: .sealedFill,
                description: "Default mode to improved clarity and accuracy of the transcription",
                isPredefined: true
            ),
            
            CustomPrompt(
                id: assistantPromptId,
                title: "Assistant",
                promptText: AIPrompts.assistantMode,
                icon: .chatFill,
                description: "AI assistant that provides direct answers to queries",
                isPredefined: true
            ),

            CustomPrompt(
                id: chatPromptId,
                title: "Chat",
                promptText: templatePromptText(named: "Chat"),
                icon: .chatFill,
                description: "Чистка чат-сообщений с сохранением живого тона",
                isPredefined: true
            ),

            CustomPrompt(
                id: generalMeetingPromptId,
                title: "General meeting",
                promptText: templatePromptText(named: "General meeting"),
                icon: .meetingFill,
                description: "Структурированное саммари общих встреч",
                isPredefined: true
            ),

            CustomPrompt(
                id: dailyStandupPromptId,
                title: "Daily Standup",
                promptText: templatePromptText(named: "Daily Standup"),
                icon: .presentationFill,
                description: "Подведи ежедневные статусы команды",
                isPredefined: true
            ),

            CustomPrompt(
                id: sprintPlanningPromptId,
                title: "Sprint Planning",
                promptText: templatePromptText(named: "Sprint Planning"),
                icon: .gearFill,
                description: "Резюме планирования спринта",
                isPredefined: true
            ),

            CustomPrompt(
                id: retrospectivePromptId,
                title: "Retrospective",
                promptText: templatePromptText(named: "Retrospective"),
                icon: .notesFill,
                description: "Итоги ретроспективы команды",
                isPredefined: true
            ),

            CustomPrompt(
                id: prePlanningPromptId,
                title: "Pre-planning",
                promptText: templatePromptText(named: "Pre-planning"),
                icon: .bookmarkFill,
                description: "Подготовка к планированию спринта",
                isPredefined: true
            ),

            CustomPrompt(
                id: oneOnOnePromptId,
                title: "One-on-One",
                promptText: templatePromptText(named: "One-on-One"),
                icon: .messageFill,
                description: "Конспект 1-на-1 встречи",
                isPredefined: true
            )
        ]
    }

    private static func templatePromptText(named title: String) -> String {
        PromptTemplates.all.first { $0.title == title }?.promptText ?? ""
    }
}
