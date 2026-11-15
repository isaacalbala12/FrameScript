import Foundation

extension L10n {
    /// Strings owned by fix package WP5. Every key needs .english, .russian and .spanish.
    static let wp5Strings: [AppLanguage: [String: String]] = [
        .english: [
            "menu.openDemo": "Open Demo Project",
            "menu.nextScene": "Next Scene",
            "menu.previousScene": "Previous Scene",
            "menu.revertToSaved": "Revert to Saved…",
            "dialog.revertToSaved.revert": "Revert",
            "shortcuts.remove": "Remove",
            "shortcuts.rejected.modifiers": "%@ needs ⌘, ⌃ or ⌥.",
            "shortcuts.rejected.command": "%@ needs ⌘.",
            "command.noResults": "No command matches “%@”.",
            "command.clearSearch": "Clear search",
            "welcome.dropProject": "Drop a FrameScript project or a .md escaleta anywhere on this window."
        ],
        .russian: [
            "menu.openDemo": "Открыть демонстрационный проект",
            "menu.nextScene": "Следующая сцена",
            "menu.previousScene": "Предыдущая сцена",
            "menu.revertToSaved": "Вернуться к сохранённой версии…",
            "dialog.revertToSaved.revert": "Вернуть",
            "shortcuts.remove": "Убрать",
            "shortcuts.rejected.modifiers": "Для %@ нужны ⌘, ⌃ или ⌥.",
            "shortcuts.rejected.command": "Для %@ нужна ⌘.",
            "command.noResults": "Нет команд, подходящих под «%@».",
            "command.clearSearch": "Очистить поиск",
            "welcome.dropProject": "Перетащите проект FrameScript или .md-эскалету в это окно."
        ],
        .spanish: [
            "menu.openDemo": "Abrir proyecto de demostración",
            "menu.nextScene": "Escena siguiente",
            "menu.previousScene": "Escena anterior",
            "menu.revertToSaved": "Volver a la versión guardada…",
            "dialog.revertToSaved.revert": "Revertir",
            "shortcuts.remove": "Quitar",
            "shortcuts.rejected.modifiers": "%@ necesita ⌘, ⌃ o ⌥.",
            "shortcuts.rejected.command": "%@ necesita ⌘.",
            "command.noResults": "Ningún comando coincide con «%@».",
            "command.clearSearch": "Borrar búsqueda",
            "welcome.dropProject": "Arrastra un proyecto de FrameScript o una escaleta .md a esta ventana."
        ]
    ]
}
