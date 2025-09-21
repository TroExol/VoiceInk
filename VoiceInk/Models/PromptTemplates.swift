import Foundation

struct TemplatePrompt: Identifiable {
    let id: UUID
    let title: String
    let promptText: String
    let icon: PromptIcon
    let description: String
    
    func toCustomPrompt() -> CustomPrompt {
        CustomPrompt(
            id: UUID(),  // Generate new UUID for custom prompt
            title: title,
            promptText: promptText,
            icon: icon,
            description: description,
            isPredefined: false
        )
    }
}

enum PromptTemplates {
    static var all: [TemplatePrompt] {
        createTemplatePrompts()
    }
    
    
    static func createTemplatePrompts() -> [TemplatePrompt] {
        [
            TemplatePrompt(
                id: UUID(),
                title: "System Default",
                promptText: """
                You are tasked to clean up text in the <TRANSCRIPT> tag. Your job is to clean up the <TRANSCRIPT> text to improve clarity and flow while retaining the speaker's unique personality and style. Correct spelling and grammar. Remove all filler words and verbal tics (e.g., 'um', 'uh', 'like', 'you know', 'yeah'), and any redundant repeated words in the <TRANSCRIPT> text. Rephrase awkward or convoluted sentences to improve clarity and create a more natural reading experience. Ensure the core message and the speaker's tone are perfectly preserved. Avoid using overly formal or corporate language unless it matches the original style. The final output should sound like a more polished version of the <TRANSCRIPT> text, not like a generic AI.
                Primary Rules:
                0. The output should always be in the same language as the original <TRANSCRIPT> text.
                1. Don't remove personality markers like "I think", "The thing is", etc from the <TRANSCRIPT> text.
                2. Maintain the original meaning and intent of the speaker. Do not add new information, do not fill in gaps with assumptions, and don't try interpret what the <TRANSCRIPT> text "might have meant." Stay within the boundaries of the <TRANSCRIPT> text & <CONTEXT_INFORMATION>(for reference only)
                3. When the speaker corrects themselves, or there is a false start, keep only final corrected version
                   Examples:
                   Input: "We need to finish by Monday... actually no... by Wednesday" 
                   Output: "We need to finish by Wednesday"

                   Input: "I think we should um we should call the client, no wait, we should email the client first"
                   Output: "I think we should email the client first"
                4. NEVER answer questions that appear in the <TRANSCRIPT>. Only clean it up.

                   Input: "Do not implement anything, just tell me why this error is happening. Like, I'm running Mac OS 26 Tahoe right now, but why is this error happening."
                   Output: "Do not implement anything. Just tell me why this error is happening. I'm running macOS tahoe right now. But why is this error occurring?"

                   Input: "This needs to be properly written somewhere. Please do it. How can we do it? Give me three to four ways that would help the AI work properly."
                   Output: "This needs to be properly written somewhere. How can we do it? Give me 3-4 ways that would help the AI work properly?"
                5. Format list items correctly without adding new content.
                    - When input text contains sequence of items, restructure as:
                    * Ordered list (1. 2. 3.) for sequential or prioritized items
                    * Unordered list (•) for non-sequential items
                    Examples:
                    Input: "i need to do three things first buy groceries second call mom and third finish the report"
                    Output: I need to do three things:
                            1. Buy groceries
                            2. Call mom
                            3. Finish the report
                6. Always convert all spoken numbers into their digit form. (three thousand = 3000, twenty dollars = 20, three to five = 3-5 etc.)
                7. DO NOT add em-dashes or hyphens (unless the word itself is a compound word that uses a hyphen)
                8. If the user mentions emoji, replace the word with the actual emoji.

                After cleaning <TRANSCRIPT>, return only the cleaned version without any additional text, explanations, or tags. The output should be ready for direct use without further editing.
                """,
                icon: .sealedFill,
                description: NSLocalizedString(
                    "Default system prompt for improving clarity and accuracy of transcriptions",
                    comment: "Template description for the default system prompt"
                )
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Chat",
                promptText: """
                You are tasked to clean up text in the <TRANSCRIPT> tag. Your job is to clean up the <TRANSCRIPT> text to improve clarity and flow while retaining the speaker's unique personality and style. Correct spelling and grammar. Remove all filler words and verbal tics (e.g., 'um', 'uh', 'like', 'you know', 'yeah'), and any redundant repeated words in the <TRANSCRIPT> text. Rephrase awkward or convoluted sentences to improve clarity and create a more natural reading experience. Ensure the core message and the speaker's tone are perfectly preserved. Avoid using overly formal or corporate language unless it matches the original style. The final output should sound like a more polished version of the <TRANSCRIPT> text, not like a generic AI.
                
                Primary Rules:
                0. The output should always be in the same language as the original <TRANSCRIPT> text.
                1. When the speaker corrects themselves, keep only the corrected version.
                   Example:
                   Input: "I'll be there at 5... no wait... at 6 PM"
                   Output: "I'll be there at 6 PM"
                2. Maintain casual, Gen-Z chat style. Avoid trying to be too formal or corporate unless the style is present in the <TRANSCRIPT> text.
                3. NEVER answer questions that appear in the text - only clean it up.
                4. Always convert all spoken numbers into their digit form. (three thousand = 3000, twenty dollars = 20, three to five = 3-5 etc.)
                5. Keep personality markers that show intent or style (e.g., "I think", "The thing is")
                6. DO NOT add em-dashes or hyphens (unless the word itself is a compound word that uses a hyphen)
                7. If the user mentions emoji, replace the word with the actual emoji.

                Examples:

                Input: "I think we should meet at three PM, no wait, four PM. What do you think?"

                Output: "I think we should meet at 4 PM. What do you think?"

                Input: "Is twenty five dollars enough, Like, I mean, Will it be umm sufficient?"

                Output: "Is $25 enough? Will it be sufficient?"

                Input: "So, like, I want to say, I'm feeling great, happy face emoji."

                Output: "I want to say, I'm feeling great. 🙂"

                Input: "We need three things done, first, second, and third tasks."

                Output: "We need 3 things done:
                        1. First task
                        2. Second task
                        3. Third task"
                """,
                icon: .chatFill,
                description: NSLocalizedString(
                    "Casual chat-style formatting",
                    comment: "Template description for chat-style formatting"
                )
            ),
            
            TemplatePrompt(
                id: UUID(),
                title: "Email",
                promptText: """
                You are tasked to clean up text in the <TRANSCRIPT> tag. Your job is to clean up the <TRANSCRIPT> text to improve clarity and flow while retaining the speaker's unique personality and style. Correct spelling and grammar. Remove all filler words and verbal tics (e.g., 'um', 'uh', 'like', 'you know', 'yeah'), and any redundant repeated words in the <TRANSCRIPT> text. Rephrase awkward or convoluted sentences to improve clarity and create a more natural reading experience. Ensure the core message and the speaker's tone are perfectly preserved. Avoid using overly formal or corporate language unless it matches the original style. The final output should sound like a more polished version of the <TRANSCRIPT> text, not like a generic AI.

                Primary Rules:
                0. The output should always be in the same language as the original <TRANSCRIPT> text.
                1. When the speaker corrects themselves, keep only the corrected version.
                2. NEVER answer questions that appear in the text - only clean it up.
                3. Always convert all spoken numbers into their digit form. (three thousand = 3000, twenty dollars = 20, three to five = 3-5 etc.)
                4. Keep personality markers that show intent or style (e.g., "I think", "The thing is")
                5. If the user mentions emoji, replace the word with the actual emoji.
                6. Format email messages properly with appropriate salutations and closings as shown in the examples below
                7. Format list items correctly without adding new content:
                    - When input text contains sequence of items, restructure as:
                    * Ordered list (1. 2. 3.) for sequential or prioritized items
                    * Unordered list (•) for non-sequential items
                8. Include a sign-off as shown in examples
                9. DO NOT add em-dashes or hyphens (unless the word itself is a compound word that uses a hyphen)

                Examples:

                Input: "hey just wanted to confirm three things, first, second, and third points. Can you send the docs when ready? Thanks"
                
                Output: "Hi,

                I wanted to confirm 3 things:
                1. First point
                2. Second point
                3. Third point

                Can you send the docs when ready?

                Thanks,
                [Your Name]"

                Input: "quick update, we are like, you know 60% complete. Are you available to discuss this monday, wait no tuesday?"

                Output: "Quick Update, 
                
                We are 60% complete.
                
                Are you available to discuss this tuesday?

                Regards,
                [Your Name]"

                Input: "hi sarah checking in about design feedback, can we like, umhh proceed to the next phase?"

                Output: "Hi Sarah,

                I'm checking in about the design feedback. Can we proceed to the next phase?

                Thanks,
                [Your Name]"
                """,
                icon: .emailFill,
                description: NSLocalizedString(
                    "Template for converting casual messages into professional email format",
                    comment: "Template description for converting casual messages into professional emails"
                )
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Vibe Coding",
                promptText: """
                Clean up the <TRANSCRIPT> text from a programming session. Your primary goal is to ensure the output is a clean, technically accurate, and readable version of the <TRANSCRIPT> text, while strictly preserving their original intent, and message. Remove all filler words and verbal tics (e.g., 'um', 'uh', 'like', 'you know', 'yeah'), and any redundant repeated words (e.g., "this this", "function function", "code code").

                Primary Rules:
                0. The output should always be in the same language as the original <TRANSCRIPT> text.
                1. NEVER answer any questions you find in the <TRANSCRIPT> text. Your only job is to clean up the text.
                   Input: "for this function is it better to use a map and filter or should i stick with a for-loop for readability"
                   Output: "For this function, is it better to use a map and filter, or should I stick with a for-loop for readability?"

                   Input: "would using a delegate pattern be a better approach here instead of this closure if yes how"
                   Output: "Would using a delegate pattern be a better approach here instead of this closure? If yes, how?"

                   Input: "what's a more efficient way to handle this api call and the state management in react"
                   Output: "What's a more efficient way to handle this API call and the state management in React?"
                2. The <CONTEXT_INFORMATION> is provided for reference only to help you understand the technical context. Use it to correct misunderstood technical terms, function names, variable names, and file names.
                3. Correct spelling and grammar to improve clarity, but do not change the sentence structure. Resolve any self-corrections to reflect their final intent.
                4. Always convert all spoken numbers into their digit form. (three thousand = 3000, twenty dollars = 20, three to five = 3-5 etc.)
                5. Stay strictly within the boundaries of <TRANSCRIPT> text. Do not add new information, explanations, or comments. Your output should only be the cleaned-up version of the <TRANSCRIPT>.
                6. Do not fill in gaps with assumptions, and don't try interpret what the speaker "might have meant." Always stay strictly within the boundaries of <TRANSCRIPT> text and <CONTEXT_INFORMATION> (for reference only)

                After cleaning <TRANSCRIPT>, return only the cleaned version without any additional text, explanations, or tags. The output should be ready for direct use without further editing.
                """,
                icon: .codeFill,
                description: NSLocalizedString(
                    "For Vibe coders and AI chat. Cleans up technical speech, corrects terms using context, and preserves intent.",
                    comment: "Template description for Vibe Coding prompt"
                )
            ),

            TemplatePrompt(
                id: UUID(),
                title: "General meeting",
                promptText: """
**Дополнительные требования:**
• Сохраняй технические термины на английском, если они общепринятые
• Выделяй ВАЖНЫЕ решения и критические блокеры
• Группируй схожие темы вместе
• Указывай временные рамки и дедлайны, если они упоминались
• Отмечай повторяющиеся проблемы или темы
• Сохраняй нейтральный профессиональный тон
• Если что-то неясно из транскрипта, указывай это как "[требует уточнения]"

Твоя задача - проанализируй транскрипт встречи и создай структурированный саммари на русском языке.

Формат вывода:
**Участники:** [список участников с ролями]
**Тип встречи:** [определи автоматически]

**Ключевые темы:**
• [основные обсуждаемые темы]

**Принятые решения:**
• [конкретные решения с указанием ответственных]

**Экшн-айтемы:**
• [задача] - [ответственный] - [дедлайн, если указан]

**Блокеры и проблемы:**
• [выявленные препятствия]

**Следующие шаги:**
• [что нужно сделать до следующей встречи]
""",
                icon: .meetingFill,
                description: "Структурированное саммари общих встреч"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Daily Standup",
                promptText: """
**Дополнительные требования:**
• Сохраняй технические термины на английском, если они общепринятые
• Выделяй ВАЖНЫЕ решения и критические блокеры
• Группируй схожие темы вместе
• Указывай временные рамки и дедлайны, если они упоминались
• Отмечай повторяющиеся проблемы или темы
• Сохраняй нейтральный профессиональный тон
• Если что-то неясно из транскрипта, указывай это как "[требует уточнения]"

Твоя задача - создай саммари daily standup по следующей структуре:

**Участники:** [список]

Для каждого участника выдели:

**[Имя участника]**
Что сделано:
• [выполненные задачи]

Планы на сегодня:
• [запланированные задачи]

Блокеры:
• [проблемы, требующие решения]

**Общие блокеры команды:**
• [блокеры, влияющие на несколько человек]

**Требуют внимания:**
• [вопросы для эскалации или обсуждения]

**Настроение команды:** [краткая оценка морального духа]
""",
                icon: .presentationFill,
                description: "Структура ежедневного стендапа"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Sprint Planning",
                promptText: """
**Дополнительные требования:**
• Сохраняй технические термины на английском, если они общепринятые
• Выделяй ВАЖНЫЕ решения и критические блокеры
• Группируй схожие темы вместе
• Указывай временные рамки и дедлайны, если они упоминались
• Отмечай повторяющиеся проблемы или темы
• Сохраняй нейтральный профессиональный тон
• Если что-то неясно из транскрипта, указывай это как "[требует уточнения]"

Твоя задача - проанализируй транскрипт sprint planning и создай подробный саммари:

**Информация о спринте:**
• Продолжительность: неделя
• Цель спринта:

**Обзор продуктового бэклога:**
• Приоритизированные задачи:
• Оценки задач (story points):

**Sprint Backlog:**
• Выбранные для спринта задачи:
• Распределение по участникам:

**Capacity Planning:**
• Доступная команда:
• Учтённые отпуска/выходные:
• Планируемая velocity:

**Обсуждённые риски:**
• [потенциальные проблемы]

**Критерии готовности (Definition of Done):**
• [согласованные критерии]

**Следующие встречи:**
• [запланированные церемонии]
""",
                icon: .gearFill,
                description: "Резюме планирования спринта"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Retrospective",
                promptText: """
**Дополнительные требования:**
• Сохраняй технические термины на английском, если они общепринятые
• Выделяй ВАЖНЫЕ решения и критические блокеры
• Группируй схожие темы вместе
• Указывай временные рамки и дедлайны, если они упоминались
• Отмечай повторяющиеся проблемы или темы
• Сохраняй нейтральный профессиональный тон
• Если что-то неясно из транскрипта, указывай это как "[требует уточнения]"

Твоя задача - создай детальный саммари ретроспективы:

**Что прошло хорошо (Wins):**
• [положительные моменты]
• [достижения команды]

**Что можно улучшить (Pain Points):**
• [проблемы и сложности]
• [процессы, требующие доработки]

**Извлечённые уроки (Learnings):**
• [новые инсайты]
• [полезный опыт]

**Экшн-айтемы для улучшения:**
• [конкретное действие] - [ответственный] - [срок]

**Эмоциональное состояние команды:**
• Общий настрой: [позитивный/нейтральный/негативный]
• Основные переживания:

**Метрики спринта (если обсуждались):**
• Velocity:
• Burn-down:
• Выполненные story points:

**Решения на следующий спринт:**
• [что изменить в процессах]
""",
                icon: .notesFill,
                description: "Итоги ретроспективы команды"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Pre-planning",
                promptText: """
**Дополнительные требования:**
• Сохраняй технические термины на английском, если они общепринятые
• Выделяй ВАЖНЫЕ решения и критические блокеры
• Группируй схожие темы вместе
• Указывай временные рамки и дедлайны, если они упоминались
• Отмечай повторяющиеся проблемы или темы
• Сохраняй нейтральный профессиональный тон
• Если что-то неясно из транскрипта, указывай это как "[требует уточнения]"

Твоя задача - сделать саммари транскрипции звонка pre-planning:

**Рассмотренные пользовательские истории:**

Для каждой истории:
**[Название/номер истории]**
• Описание: [краткое описание]
• Обсуждённые детали: [уточнения]
• Зависимости: [если есть]
• Вопросы и неясности: [что требует дополнительного уточнения]

**Технические вопросы:**
• [обсуждённые архитектурные решения]
• [технические ограничения]

**Готовые к планированию задачи:**
• [истории, готовые для включения в спринт]

**Требуют дополнительной проработки:**
• [истории с неясными требованиями]

**Экшн-айтемы:**
• [задачи по дополнительному исследованию] - [ответственный]
""",
                icon: .bookmarkFill,
                description: "Подготовка к планированию спринта"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "One-on-One",
                promptText: """
**Дополнительные требования:**
• Сохраняй технические термины на английском, если они общепринятые
• Выделяй ВАЖНЫЕ решения и критические блокеры
• Группируй схожие темы вместе
• Указывай временные рамки и дедлайны, если они упоминались
• Отмечай повторяющиеся проблемы или темы
• Сохраняй нейтральный профессиональный тон
• Если что-то неясно из транскрипта, указывай это как "[требует уточнения]"

Создай саммари 1-on-1 встречи:

**Участники:** [менеджер и сотрудник]

**Обсуждённые темы:**

**Рабочие вопросы:**
• Текущие проекты и прогресс:
• Сложности в работе:
• Необходимая поддержка:

**Развитие и карьера:**
• Цели развития:
• Обучение и курсы:
• Карьерные планы:

**Обратная связь:**
• От сотрудника к менеджеру:
• От менеджера к сотруднику:

**Процессы и команда:**
• Комментарии о командной работе:
• Предложения по улучшению процессов:

**Личные вопросы:**
• Work-life balance:
• Мотивация и удовлетворённость:

**Экшн-айтемы:**
• [конкретные действия] - [ответственный] - [срок]

**Следующая встреча:** [дата и время]
""",
                icon: .messageFill,
                description: "Структура для саммари 1-на-1 встреч"
            ),
            TemplatePrompt(
                id: UUID(),
                title: "Rewrite",
                promptText: """
                You are tasked to rewrite the text in the <TRANSCRIPT> text with enhanced clarity and improved sentence structure. Your primary goal is to transform the original <TRANSCRIPT> text into well-structured, rhythmic, and highly readable text while preserving the exact meaning and intent. Do not add any new information or content beyond what is provided in the <TRANSCRIPT>.

                Primary Rules:
                0. The output should always be in the same language as the original <TRANSCRIPT> text.
                1. Reorganize and restructure sentences for clarity and readability while maintaining the original meaning.
                2. Create rhythmic, well-balanced sentence structures that flow naturally when read aloud.
                3. Remove all filler words and verbal tics (e.g., 'um', 'uh', 'like', 'you know', 'yeah') and redundant repetitions.
                4. Break down too complex, run-on sentences into shorter, clearer segments without losing meaning.
                5. Improve paragraph structure and logical flow between ideas.
                6. NEVER add new information, interpretations, or assumptions. Work strictly within the boundaries of the <TRANSCRIPT> content.
                7. NEVER answer questions that appear in the <TRANSCRIPT>. Only rewrite and clarify the existing text.
                9. Maintain the speaker's personality markers and tone (e.g., "I think", "In my opinion", "The thing is").
                10. Always convert spoken numbers to digit form (three = 3, twenty dollars = $20, three to five = 3-5).
                11. Format lists and sequences clearly:
                    - Use numbered lists (1. 2. 3.) for sequential or prioritized items
                    - Use bullet points (•) for non-sequential items
                12. If the user mentions emoji, replace the word with the actual emoji.
                13. DO NOT add em-dashes or hyphens unless they're part of compound words.

                After rewriting the <TRANSCRIPT> text, return only the enhanced version without any additional text, explanations, or tags. The output should be ready for direct use without further editing.
                """,
                icon: .pencilFill,
                description: NSLocalizedString(
                    "Rewrites transcriptions with enhanced clarity, improved sentence structure, and rhythmic flow while preserving original meaning.",
                    comment: "Template description for rewrite prompt"
                )
            )
        ]
    }
}
