import Foundation

extension L10n {
    static let autosaveStrings: [AppLanguage: [String: String]] = [
        .english: [
            "dialog.externalChange.title": "Project file changed on disk",
            "dialog.externalChange.message": "Another app or agent changed this project file after FrameScript last read or saved it. Reload the file, keep your version and overwrite it, or save your version as a copy.",
            "dialog.externalChange.reload": "Reload",
            "dialog.externalChange.keepMine": "Keep Mine (Overwrite)",
            "dialog.externalChange.saveCopy": "Save Mine as Copy…"
        ],
        .russian: [
            "dialog.externalChange.title": "Файл проекта изменён на диске",
            "dialog.externalChange.message": "Другое приложение или агент изменили этот файл после того, как FrameScript прочитал или сохранил его. Перезагрузите файл, оставьте свою версию и перезапишите файл или сохраните свою версию как копию.",
            "dialog.externalChange.reload": "Перезагрузить",
            "dialog.externalChange.keepMine": "Оставить мою версию (перезаписать)",
            "dialog.externalChange.saveCopy": "Сохранить мою версию как копию…"
        ]
    ]

    /// Wired into `autosaveStrings` once `AppLanguage.spanish` exists.
    static let autosaveSpanish: [String: String] = [
        "dialog.externalChange.title": "El archivo del proyecto cambió en el disco",
        "dialog.externalChange.message": "Otra aplicación o agente modificó este archivo después de que FrameScript lo leyera o guardara. Recarga el archivo, conserva tu versión y sobrescríbelo, o guarda tu versión como copia.",
        "dialog.externalChange.reload": "Recargar",
        "dialog.externalChange.keepMine": "Conservar la mía (sobrescribir)",
        "dialog.externalChange.saveCopy": "Guardar la mía como copia…"
    ]
}
