import Foundation

extension L10n {
    /// Strings owned by fix package WP2. Every key needs .english, .russian and .spanish.
    static let wp2Strings: [AppLanguage: [String: String]] = [
        .english: [
            "aiTask.rehook": "Rehooks",
            "aiError.issue.unknownProviderKind": "The saved AI provider is not recognised. Choose a provider in Settings.",
            // `L10n.displayName` builds the key from `AIProviderKind.rawValue`,
            // which is ASCII since WP2. These mirror the legacy-key strings.
            "aiProvider.disabled": "Disabled",
            "aiProvider.openAICompatible": "OpenAI-compatible",
            "aiProvider.openRouter": "OpenRouter",
            "aiProvider.groq": "Groq",
            "aiProvider.googleAIStudio": "Google AI Studio",
            "aiProvider.t3Code": "T3 Code (subscription)",
            "aiProvider.claudeCode": "Claude Code (subscription)",
            "aiProvider.codex": "Codex (subscription)",
            "ai.review.closeHelp": "Hide the AI review panel",
            "ai.analyzeCurrentSceneHelp": "Ask the configured AI provider to review the current scene",
            "settings.ai.subscription.secondsFormat": "%d s",
            "settings.ai.subscription.recoveredTitle": "Saved AI settings could not be read",
            "settings.ai.subscription.recoveredMessage": "A copy of the unreadable data was kept. FrameScript uses the defaults until you change a setting here.",
            "settings.ai.subscription.dismissHelp": "Dismiss",
            "settings.ai.subscription.activityFallback": "%@ · %@ (fallback)",
            "settings.ai.subscription.activityFallbackHelp": "The selected provider (%@) is not available, so this request runs with %@.",
            "hooks.words.one": "%d word",
            "hooks.words.other": "%d words"
        ],
        .russian: [
            "aiTask.rehook": "Мосты",
            "aiError.issue.unknownProviderKind": "Сохранённый провайдер ИИ не распознан. Выберите провайдера в настройках.",
            "aiProvider.disabled": "Отключено",
            "aiProvider.openAICompatible": "OpenAI-совместимый",
            "aiProvider.openRouter": "OpenRouter",
            "aiProvider.groq": "Groq",
            "aiProvider.googleAIStudio": "Google AI Studio",
            "aiProvider.t3Code": "T3 Code (подписка)",
            "aiProvider.claudeCode": "Claude Code (подписка)",
            "aiProvider.codex": "Codex (подписка)",
            "ai.review.closeHelp": "Скрыть панель ИИ-проверки",
            "ai.analyzeCurrentSceneHelp": "Попросить настроенного провайдера ИИ проверить текущую сцену",
            "settings.ai.subscription.secondsFormat": "%d с",
            "settings.ai.subscription.recoveredTitle": "Не удалось прочитать сохранённые настройки ИИ",
            "settings.ai.subscription.recoveredMessage": "Копия нечитаемых данных сохранена. FrameScript использует значения по умолчанию, пока вы не измените настройку здесь.",
            "settings.ai.subscription.dismissHelp": "Скрыть",
            "settings.ai.subscription.activityFallback": "%@ · %@ (резерв)",
            "settings.ai.subscription.activityFallbackHelp": "Выбранный провайдер (%@) недоступен, поэтому запрос выполняется через %@.",
            "hooks.words.one": "%d слово",
            "hooks.words.few": "%d слова",
            "hooks.words.many": "%d слов"
        ],
        .spanish: [
            "aiTask.rehook": "Reenganches",
            "aiError.issue.unknownProviderKind": "El proveedor de IA guardado no se reconoce. Elige un proveedor en Ajustes.",
            "aiProvider.disabled": "Desactivado",
            "aiProvider.openAICompatible": "Compatible con OpenAI",
            "aiProvider.openRouter": "OpenRouter",
            "aiProvider.groq": "Groq",
            "aiProvider.googleAIStudio": "Google AI Studio",
            "aiProvider.t3Code": "T3 Code (suscripción)",
            "aiProvider.claudeCode": "Claude Code (suscripción)",
            "aiProvider.codex": "Codex (suscripción)",
            "ai.review.closeHelp": "Ocultar el panel de revisión de IA",
            "ai.analyzeCurrentSceneHelp": "Pedir al proveedor de IA configurado que revise la escena actual",
            "settings.ai.subscription.secondsFormat": "%d s",
            "settings.ai.subscription.recoveredTitle": "No se pudieron leer los ajustes de IA guardados",
            "settings.ai.subscription.recoveredMessage": "Se guardó una copia de los datos ilegibles. FrameScript usa los valores por defecto hasta que cambies un ajuste aquí.",
            "settings.ai.subscription.dismissHelp": "Descartar",
            "settings.ai.subscription.activityFallback": "%@ · %@ (alternativa)",
            "settings.ai.subscription.activityFallbackHelp": "El proveedor elegido (%@) no está disponible, así que este encargo se ejecuta con %@.",
            "hooks.words.one": "%d palabra",
            "hooks.words.other": "%d palabras"
        ]
    ]
}
