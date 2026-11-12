import Foundation

extension L10n {
    /// Teleprompter-owned strings. Registered in `Localization+Features.swift`.
    static let teleprompterStrings: [AppLanguage: [String: String]] = [
        .english: [
            "menu.teleprompter": "Teleprompter",
            "toolbar.teleprompter": "Open the teleprompter",
            "teleprompter.windowTitle": "Teleprompter",
            "teleprompter.play": "Play",
            "teleprompter.pause": "Pause",
            "teleprompter.previousScene": "Previous Scene",
            "teleprompter.nextScene": "Next Scene",
            "teleprompter.restartScene": "Restart Scene",
            "teleprompter.countdown": "3-2-1 Countdown",
            "teleprompter.mirrorHorizontal": "Mirror Horizontally",
            "teleprompter.mirrorVertical": "Mirror Vertically",
            "teleprompter.speed": "Speed",
            "teleprompter.fontSize": "Text Size",
            "teleprompter.columnWidth": "Column Width",
            "teleprompter.readingLine": "Reading Line",
            "teleprompter.display": "Display",
            "teleprompter.fullScreen": "Full Screen",
            "teleprompter.close": "Close",
            "teleprompter.noText": "This scene has no text.",
            "teleprompter.ready": "Press Space to start",
            "teleprompter.hint": "Space play/pause  ·  ↑↓ speed  ·  ←→ scene  ·  Home start  ·  [ ] text size  ·  ; ' width  ·  H/V mirror  ·  Esc close",
            "teleprompter.wpmValue": "%d WPM",
            "teleprompter.pointsValue": "%d pt"
        ],
        .russian: [
            "menu.teleprompter": "Телесуфлёр",
            "toolbar.teleprompter": "Открыть телесуфлёр",
            "teleprompter.windowTitle": "Телесуфлёр",
            "teleprompter.play": "Пуск",
            "teleprompter.pause": "Пауза",
            "teleprompter.previousScene": "Предыдущая сцена",
            "teleprompter.nextScene": "Следующая сцена",
            "teleprompter.restartScene": "Начать сцену заново",
            "teleprompter.countdown": "Отсчёт 3-2-1",
            "teleprompter.mirrorHorizontal": "Отразить по горизонтали",
            "teleprompter.mirrorVertical": "Отразить по вертикали",
            "teleprompter.speed": "Скорость",
            "teleprompter.fontSize": "Размер текста",
            "teleprompter.columnWidth": "Ширина колонки",
            "teleprompter.readingLine": "Линия чтения",
            "teleprompter.display": "Экран",
            "teleprompter.fullScreen": "Полный экран",
            "teleprompter.close": "Закрыть",
            "teleprompter.noText": "В этой сцене нет текста.",
            "teleprompter.ready": "Нажмите пробел, чтобы начать",
            "teleprompter.hint": "Пробел — пуск/пауза  ·  ↑↓ — скорость  ·  ←→ — сцены  ·  Home — начало  ·  [ ] — размер  ·  ; ' — ширина  ·  H/V — отражение  ·  Esc — закрыть",
            "teleprompter.wpmValue": "%d сл/мин",
            "teleprompter.pointsValue": "%d пт"
        ]
    ]

    /// Spanish values, ready for the `.spanish` case once it lands in
    /// `AppLanguage`. Not registered in `featureTables` yet because the enum has
    /// no Spanish case in this wave.
    static let teleprompterSpanish: [String: String] = [
        "menu.teleprompter": "Teleprompter",
        "toolbar.teleprompter": "Abrir el teleprompter",
        "teleprompter.windowTitle": "Teleprompter",
        "teleprompter.play": "Reproducir",
        "teleprompter.pause": "Pausa",
        "teleprompter.previousScene": "Escena anterior",
        "teleprompter.nextScene": "Escena siguiente",
        "teleprompter.restartScene": "Reiniciar escena",
        "teleprompter.countdown": "Cuenta atrás 3-2-1",
        "teleprompter.mirrorHorizontal": "Espejar horizontalmente",
        "teleprompter.mirrorVertical": "Espejar verticalmente",
        "teleprompter.speed": "Velocidad",
        "teleprompter.fontSize": "Tamaño del texto",
        "teleprompter.columnWidth": "Ancho de columna",
        "teleprompter.readingLine": "Línea de lectura",
        "teleprompter.display": "Pantalla",
        "teleprompter.fullScreen": "Pantalla completa",
        "teleprompter.close": "Cerrar",
        "teleprompter.noText": "Esta escena no tiene texto.",
        "teleprompter.ready": "Pulsa espacio para empezar",
        "teleprompter.hint": "Espacio reproducir/pausar  ·  ↑↓ velocidad  ·  ←→ escena  ·  Inicio principio  ·  [ ] tamaño  ·  ; ' ancho  ·  H/V espejo  ·  Esc cerrar",
        "teleprompter.wpmValue": "%d ppm",
        "teleprompter.pointsValue": "%d pt"
    ]
}
