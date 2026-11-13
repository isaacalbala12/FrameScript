import Foundation

extension L10n {
    /// Strings owned by fix package WP4. Every key needs .english, .russian and .spanish.
    static let wp4Strings: [AppLanguage: [String: String]] = [
        .english: [
            "export.csv.sceneNotes": "Scene notes",

            "escaleta.warning.missingTitle": "The document has no usable title.",
            "escaleta.warning.noScenes": "No scenes or fallback outline were found.",
            "escaleta.warning.emptySection": "The section «%@» is empty.",
            "escaleta.warning.outlineFallback": "No timestamped scenes were found; the outline was used instead (%@ scenes).",
            "escaleta.warning.descendingTimestamp": "The timestamp %@ (%@) does not move forward from the previous scene.",
            "escaleta.warning.invalidTimestamp": "The heading «%@» looks like a scene but could not be interpreted.",
            "escaleta.warning.emptySceneTitle": "The scene on line %@ has no title.",
            "escaleta.warning.unknownCue": "Unknown cue kept in the notes: [%@].",
            "escaleta.warning.unknownCueUnanchored": "The cue [%@] could not be anchored to a paragraph of «%@».",
            "escaleta.warning.inlineCue": "Inline cue kept in the script: [%@].",
            "escaleta.warning.unknownSection": "Unrecognized section kept verbatim: «%@».",
            "escaleta.warning.seoMissingTitle": "The SEO block has no primary title or title variants.",
            "escaleta.warning.seoMissingDescription": "The SEO block has no description.",
            "escaleta.warning.duplicateTag": "Duplicate tags were removed.",
            "escaleta.warning.malformedTable": "A table row has a different number of columns than the header.",
            "escaleta.warning.thumbnailTextLength": "The thumbnail text «%@» has more than 3 words.",
            "escaleta.warning.emptyScene": "The scene %@ has no body.",
            "escaleta.warning.emptyField": "The SEO field «%@» is empty.",
            "escaleta.warning.emptySources": "The section «%@» has no sources."
        ],
        .spanish: [
            "export.csv.sceneNotes": "Notas de escena",

            "escaleta.warning.missingTitle": "El documento no tiene un título utilizable.",
            "escaleta.warning.noScenes": "No se encontraron escenas ni una escaleta de respaldo.",
            "escaleta.warning.emptySection": "La sección «%@» está vacía.",
            "escaleta.warning.outlineFallback": "No había escenas con timestamp; se usó la escaleta como respaldo (%@ escenas).",
            "escaleta.warning.descendingTimestamp": "El timestamp %@ (%@) no es ascendente respecto al anterior.",
            "escaleta.warning.invalidTimestamp": "El encabezado «%@» parece una escena pero no se pudo interpretar.",
            "escaleta.warning.emptySceneTitle": "La escena de la línea %@ no tiene título.",
            "escaleta.warning.unknownCue": "Cue desconocido conservado en notas: [%@].",
            "escaleta.warning.unknownCueUnanchored": "No se pudo anclar el cue [%@] a un párrafo de «%@».",
            "escaleta.warning.inlineCue": "Cue en línea conservado en el guion: [%@].",
            "escaleta.warning.unknownSection": "Sección no reconocida conservada: «%@».",
            "escaleta.warning.seoMissingTitle": "El bloque SEO no tiene título principal ni variantes.",
            "escaleta.warning.seoMissingDescription": "El bloque SEO no tiene descripción.",
            "escaleta.warning.duplicateTag": "Se eliminaron etiquetas duplicadas.",
            "escaleta.warning.malformedTable": "Una fila de la tabla tiene un número de columnas distinto al de la cabecera.",
            "escaleta.warning.thumbnailTextLength": "El texto de la miniatura «%@» tiene más de 3 palabras.",
            "escaleta.warning.emptyScene": "La escena %@ no tiene cuerpo.",
            "escaleta.warning.emptyField": "El campo SEO «%@» está vacío.",
            "escaleta.warning.emptySources": "La sección «%@» no contiene fuentes."
        ],
        .russian: [
            "export.csv.sceneNotes": "Заметки сцены",

            "escaleta.warning.missingTitle": "У документа нет пригодного заголовка.",
            "escaleta.warning.noScenes": "Не найдено ни сцен, ни резервной эскалеты.",
            "escaleta.warning.emptySection": "Раздел «%@» пуст.",
            "escaleta.warning.outlineFallback": "Сцен с таймкодом не найдено; использована эскалета как резерв (%@ сцен).",
            "escaleta.warning.descendingTimestamp": "Таймкод %@ (%@) не возрастает относительно предыдущей сцены.",
            "escaleta.warning.invalidTimestamp": "Заголовок «%@» похож на сцену, но не может быть разобран.",
            "escaleta.warning.emptySceneTitle": "У сцены в строке %@ нет названия.",
            "escaleta.warning.unknownCue": "Неизвестная метка сохранена в заметках: [%@].",
            "escaleta.warning.unknownCueUnanchored": "Не удалось привязать метку [%@] к абзацу «%@».",
            "escaleta.warning.inlineCue": "Метка внутри строки сохранена в сценарии: [%@].",
            "escaleta.warning.unknownSection": "Нераспознанный раздел сохранён без изменений: «%@».",
            "escaleta.warning.seoMissingTitle": "В блоке SEO нет основного заголовка или вариантов.",
            "escaleta.warning.seoMissingDescription": "В блоке SEO нет описания.",
            "escaleta.warning.duplicateTag": "Повторяющиеся теги удалены.",
            "escaleta.warning.malformedTable": "В строке таблицы другое число столбцов, чем в заголовке.",
            "escaleta.warning.thumbnailTextLength": "Текст миниатюры «%@» длиннее 3 слов.",
            "escaleta.warning.emptyScene": "У сцены %@ нет тела.",
            "escaleta.warning.emptyField": "Поле SEO «%@» пусто.",
            "escaleta.warning.emptySources": "В разделе «%@» нет источников."
        ]
    ]
}
