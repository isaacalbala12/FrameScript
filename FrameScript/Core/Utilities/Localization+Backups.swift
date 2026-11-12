import Foundation

extension L10n {
    /// F29 automatic backups. Registered in `Localization+Features.swift`.
    static let backupsStrings: [AppLanguage: [String: String]] = [
        .english: [
            "backups.menu": "Backups…",
            "backups.title": "Project Backups",
            "backups.subtitle": "Automatic copies saved before FrameScript overwrites the project file.",
            "backups.emptyTitle": "No backups yet",
            "backups.emptyMessage": "FrameScript saves a backup before the next overwrite. Backups appear here after that save.",
            "backups.untitled": "Save this project to start automatic backups.",
            "backups.column.date": "Date",
            "backups.column.size": "Size",
            "backups.column.original": "Original file",
            "backups.originalUnknown": "Original location unknown",
            "backups.openAsCopy": "Open as Copy",
            "backups.openAsCopy.help": "Opens this backup as a new untitled project. The current project file is not changed.",
            "backups.restore": "Restore",
            "backups.restore.help": "Replaces the current project file with this backup. The current version is backed up first.",
            "backups.restore.title": "Restore This Backup?",
            "backups.restore.message": "The current project file will be replaced by the selected backup. FrameScript saves a copy of the current version before restoring.",
            "backups.restore.confirm": "Restore",
            "backups.restore.done": "Backup restored.",
            "backups.restore.failed": "Could not restore the backup. The current project file was not changed.",
            "backups.refresh": "Refresh",
            "backups.close": "Close",
            "backups.warning.lastFailure": "The last automatic backup failed. Saving still works; check disk space and folder permissions.",
            "backups.error.title": "Backups Unavailable",
            "backups.error.message": "FrameScript could not read the backup folder. The project file was not changed."
        ],
        .russian: [
            "backups.menu": "Резервные копии…",
            "backups.title": "Резервные копии проекта",
            "backups.subtitle": "Автоматические копии, сохранённые перед перезаписью файла проекта.",
            "backups.emptyTitle": "Резервных копий пока нет",
            "backups.emptyMessage": "FrameScript сохранит копию перед следующей перезаписью. После этого копии появятся здесь.",
            "backups.untitled": "Сохраните проект, чтобы начать автоматическое резервное копирование.",
            "backups.column.date": "Дата",
            "backups.column.size": "Размер",
            "backups.column.original": "Исходный файл",
            "backups.originalUnknown": "Исходное расположение неизвестно",
            "backups.openAsCopy": "Открыть как копию",
            "backups.openAsCopy.help": "Открывает копию как новый проект без имени. Текущий файл проекта не изменяется.",
            "backups.restore": "Восстановить",
            "backups.restore.help": "Заменяет текущий файл проекта этой копией. Перед восстановлением текущая версия копируется.",
            "backups.restore.title": "Восстановить эту копию?",
            "backups.restore.message": "Текущий файл проекта будет заменён выбранной копией. Перед восстановлением FrameScript сохранит копию текущей версии.",
            "backups.restore.confirm": "Восстановить",
            "backups.restore.done": "Копия восстановлена.",
            "backups.restore.failed": "Не удалось восстановить копию. Текущий файл проекта не изменён.",
            "backups.refresh": "Обновить",
            "backups.close": "Закрыть",
            "backups.warning.lastFailure": "Последняя автоматическая резервная копия не создана. Сохранение работает; проверьте место на диске и права на папку.",
            "backups.error.title": "Резервные копии недоступны",
            "backups.error.message": "FrameScript не удалось прочитать папку резервных копий. Файл проекта не изменён."
        ]
    ]

    /// Spanish values, ready to register once `AppLanguage.spanish` exists.
    /// Kept unwired on purpose: adding a case to `AppLanguage` belongs to F3.
    static let backupsSpanish: [String: String] = [
        "backups.menu": "Copias de seguridad…",
        "backups.title": "Copias de seguridad del proyecto",
        "backups.subtitle": "Copias automáticas guardadas antes de que FrameScript sobrescriba el archivo del proyecto.",
        "backups.emptyTitle": "Todavía no hay copias",
        "backups.emptyMessage": "FrameScript guarda una copia antes de la próxima sobrescritura. Las copias aparecerán aquí después de ese guardado.",
        "backups.untitled": "Guarda el proyecto para empezar las copias automáticas.",
        "backups.column.date": "Fecha",
        "backups.column.size": "Tamaño",
        "backups.column.original": "Archivo original",
        "backups.originalUnknown": "Ubicación original desconocida",
        "backups.openAsCopy": "Abrir como copia",
        "backups.openAsCopy.help": "Abre esta copia como un proyecto nuevo sin título. El archivo del proyecto actual no cambia.",
        "backups.restore": "Restaurar",
        "backups.restore.help": "Sustituye el archivo del proyecto actual por esta copia. Antes se guarda una copia de la versión actual.",
        "backups.restore.title": "¿Restaurar esta copia?",
        "backups.restore.message": "El archivo del proyecto actual se sustituirá por la copia seleccionada. FrameScript guarda antes una copia de la versión actual.",
        "backups.restore.confirm": "Restaurar",
        "backups.restore.done": "Copia restaurada.",
        "backups.restore.failed": "No se pudo restaurar la copia. El archivo del proyecto actual no ha cambiado.",
        "backups.refresh": "Actualizar",
        "backups.close": "Cerrar",
        "backups.warning.lastFailure": "La última copia automática falló. Guardar sigue funcionando; revisa el espacio en disco y los permisos de la carpeta.",
        "backups.error.title": "Copias de seguridad no disponibles",
        "backups.error.message": "FrameScript no pudo leer la carpeta de copias. El archivo del proyecto no ha cambiado."
    ]
}
