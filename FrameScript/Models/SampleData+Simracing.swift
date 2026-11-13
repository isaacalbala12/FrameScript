import Foundation

/// Built-in simracing templates. The catalog carries the scene blueprint that
/// `FrameTemplate.structureDefinition` cannot express on its own: per-scene
/// prompts, re-hook cues, capture sources, editing notes and target durations.
enum SimracingTemplates {
    // MARK: - Public catalog

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case updateAnalysis
        case modReview
        case comparison
        case news
        case raceChronicle

        var id: String { rawValue }
    }

    enum CaptureSource: String, CaseIterable, Sendable {
        case cam
        case obsGameplay
        case screenshot
        case web

        var brollSource: BRollSourceType {
            switch self {
            case .cam: .talkingHead
            case .obsGameplay: .screenRecording
            case .screenshot, .web: .screenshot
            }
        }

        func label(_ language: AppLanguage) -> String {
            let resolved = SimracingCopy.resolvedLanguage(language)
            switch self {
            case .cam: return "CAM"
            case .obsGameplay: return "OBS gameplay"
            case .screenshot: return resolved == .spanish ? "Captura de pantalla" : (resolved == .russian ? "Скриншот" : "Screenshot")
            case .web: return "Web"
            }
        }
    }

    struct CaptureIdea: Sendable {
        let source: CaptureSource
        let description: SimracingCopy
    }

    struct SceneBlueprint: Sendable {
        let canonicalTitle: String
        let titleKey: String
        let sectionType: SectionType
        let prompt: SimracingCopy
        let reHook: SimracingCopy?
        let captures: [CaptureIdea]
        let editingNote: SimracingCopy
        let targetDuration: TimeInterval

        func localizedTitle(_ language: AppLanguage) -> String {
            L10n.tr(titleKey, language: SimracingCopy.resolvedLanguage(language))
        }

        func guidance(_ language: AppLanguage) -> String {
            // Russian template guidance is intentionally not translated yet; it falls
            // back to English as a whole instead of mixing Russian labels with English copy.
            let resolved = SimracingCopy.guidanceLanguage(language)
            var lines: [String] = []
            lines.append("\(Self.label("Objetivo", "Goal", resolved)): \(prompt.text(for: resolved))")
            if let reHook {
                lines.append("\(Self.label("Gancho intermedio", "Re-hook", resolved)): \(reHook.text(for: resolved))")
            }
            lines.append("")
            lines.append("\(Self.label("Visuales", "Visuals", resolved)):")
            for capture in captures {
                lines.append("• \(capture.source.label(resolved)): \(capture.description.text(for: resolved))")
            }
            lines.append("")
            lines.append("\(Self.label("Edición", "Editing", resolved)): \(editingNote.text(for: resolved))")
            lines.append("\(Self.label("Duración objetivo", "Target duration", resolved)): \(DurationEstimator.formatted(targetDuration))")
            return lines.joined(separator: "\n")
        }

        private static func label(_ spanish: String, _ english: String, _ language: AppLanguage) -> String {
            language == .spanish ? spanish : english
        }
    }

    struct Definition: Sendable {
        let id: UUID
        let kind: Kind
        let name: String
        let scenes: [SceneBlueprint]

        var frameTemplate: FrameTemplate {
            FrameTemplate(
                id: id,
                category: .script,
                name: name,
                builtIn: true,
                structureDefinition: scenes.map(\.canonicalTitle),
                customFields: []
            )
        }

        var targetDuration: TimeInterval {
            scenes.reduce(0) { $0 + $1.targetDuration }
        }

        func localizedName(_ language: AppLanguage) -> String {
            L10n.tr("template.\(name)", language: SimracingCopy.resolvedLanguage(language))
        }

        func localizedDescription(_ language: AppLanguage) -> String {
            L10n.tr("template.\(name).description", language: SimracingCopy.resolvedLanguage(language))
        }

        func makeProject(named title: String, template: FrameTemplate, language: AppLanguage, exportPresetName: String) -> FrameProject {
            let contentLanguage = SimracingCopy.guidanceLanguage(language)
            let builtScenes = scenes.enumerated().map { index, blueprint in
                let sceneID = UUID()
                let segment = TextSegment(
                    sceneID: sceneID,
                    order: 0,
                    sourceText: "",
                    segmentType: .paragraph
                )
                return Scene(
                    id: sceneID,
                    order: index,
                    sectionType: blueprint.sectionType,
                    title: blueprint.localizedTitle(language),
                    scriptText: "",
                    notes: blueprint.guidance(language),
                    textSegments: [segment],
                    bRollItems: blueprint.captures.map { idea in
                        BRollItem(
                            templateType: "Simracing",
                            sourceType: idea.source.brollSource,
                            descriptionText: idea.description.text(for: contentLanguage),
                            notes: idea.source.label(contentLanguage),
                            status: .idea
                        )
                    },
                    editingItems: [
                        EditingItem(
                            templateType: "Simracing",
                            cutStyle: SimracingTemplates.templateNoteLabel.text(for: contentLanguage),
                            transition: "",
                            subtitleStyle: "",
                            notes: blueprint.editingNote.text(for: contentLanguage)
                        )
                    ]
                )
            }
            return FrameProject(
                title: title,
                templateID: template.id,
                scenes: builtScenes,
                exportPresets: [ExportPreset(id: UUID(), name: exportPresetName, format: .productionOutline)],
                primaryLanguage: SimracingCopy.resolvedLanguage(language).contentLanguageCode
            )
        }
    }

    static let all: [Definition] = [
        updateAnalysis,
        modReview,
        comparison,
        news,
        raceChronicle
    ]

    static let frameTemplates: [FrameTemplate] = all.map(\.frameTemplate)

    static let templateNoteLabel = SimracingCopy(
        english: "Template note",
        spanish: "Nota de plantilla",
        russian: "Заметка шаблона"
    )

    static func definition(for template: FrameTemplate) -> Definition? {
        if let match = all.first(where: { $0.id == template.id }) {
            return match
        }
        if let sourceName = template.builtInSourceName,
           let match = all.first(where: { $0.name == sourceName }) {
            return match
        }
        return all.first { $0.name == template.name }
    }

    // MARK: - Blueprint helpers

    static func copy(_ spanish: String, _ english: String, russian: String? = nil) -> SimracingCopy {
        SimracingCopy(english: english, spanish: spanish, russian: russian)
    }

    static func cam(_ spanish: String, _ english: String) -> CaptureIdea {
        CaptureIdea(source: .cam, description: copy(spanish, english))
    }

    static func obs(_ spanish: String, _ english: String) -> CaptureIdea {
        CaptureIdea(source: .obsGameplay, description: copy(spanish, english))
    }

    static func shot(_ spanish: String, _ english: String) -> CaptureIdea {
        CaptureIdea(source: .screenshot, description: copy(spanish, english))
    }

    static func web(_ spanish: String, _ english: String) -> CaptureIdea {
        CaptureIdea(source: .web, description: copy(spanish, english))
    }

    static func scene(
        _ canonicalTitle: String,
        _ sectionType: SectionType,
        _ targetDuration: TimeInterval,
        prompt: SimracingCopy,
        captures: [CaptureIdea],
        editing: SimracingCopy,
        reHook: SimracingCopy? = nil
    ) -> SceneBlueprint {
        SceneBlueprint(
            canonicalTitle: canonicalTitle,
            titleKey: titleKey(for: canonicalTitle),
            sectionType: sectionType,
            prompt: prompt,
            reHook: reHook,
            captures: captures,
            editingNote: editing,
            targetDuration: targetDuration
        )
    }

    static func titleKey(for canonicalTitle: String) -> String {
        switch canonicalTitle {
        case "Hook": "template.scene.hook"
        case "Context": "template.scene.context"
        case "CTA": "template.scene.cta"
        default: "template.scene.\(canonicalTitle)"
        }
    }

    // MARK: - 1. Update analysis (10 scenes)

    private static let updateAnalysis = Definition(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        kind: .updateAnalysis,
        name: "Simracing Update Analysis",
        scenes: [
            scene("Hook", .hook, 15,
                prompt: copy(
                    "Abre con el conflicto y la promesa en 10–15 s: qué cambia, por qué importa ahora y qué pregunta responde el vídeo. No leas la lista de cambios.",
                    "Open with the conflict and the promise in 10–15 s: what changed, why it matters now and which question the video answers. Do not read the changelog."
                ),
                captures: [
                    cam("Plano medio a cámara con una reacción breve; el juego al fondo, desenfocado.", "Medium talking-head shot with a brief reaction; the game soft in the background."),
                    obs("Montaje de tres clips: menú de la versión, coche nuevo y un adelantamiento.", "Three-clip montage: version menu, new car and an overtake."),
                    shot("Rótulo con la versión y la fecha real frente a la anunciada.", "Title card with the actual version and release date next to the announced one."),
                    web("Captura de la hoja de ruta o nota oficial con la promesa principal.", "Capture of the roadmap or official post carrying the main promise.")
                ],
                editing: copy(
                    "Corte seco al terminar la pregunta; deja medio segundo de silencio antes del rótulo.",
                    "Hard cut after the question; leave half a second of silence before the title card."
                )
            ),
            scene("Context and thesis", .whyThisMatters, 60,
                prompt: copy(
                    "Qué había antes, qué promete la versión y tu tesis en una frase. Separa expectativa, anuncio y realidad.",
                    "What came before, what the version promises and your thesis in one sentence. Separate expectation, announcement and reality."
                ),
                captures: [
                    cam("Plano fijo a cámara; baja el ritmo y mira al objetivo al decir la tesis.", "Locked-off talking head; slow down and look into the lens for the thesis."),
                    obs("Gameplay de la versión anterior en el mismo circuito para comparar.", "Gameplay from the previous version on the same track for comparison."),
                    web("Nota oficial o hoja de ruta con la frase que resume la promesa.", "Official post or roadmap with the sentence that sums up the promise.")
                ],
                editing: copy(
                    "Muestra la tesis en rótulo mientras la dices y no la repitas literalmente.",
                    "Show the thesis on screen while you say it and do not repeat it word for word."
                )
            ),
            scene("What changes I", .explanation, 75,
                prompt: copy(
                    "Desarrolla el cambio principal: qué es, dónde se usa y qué nota el jugador. Una idea, una prueba en pantalla.",
                    "Develop the main change: what it is, where it is used and what the player notices. One idea, one proof on screen."
                ),
                captures: [
                    obs("Menú nuevo con el cursor marcando la opción exacta.", "New menu with the cursor on the exact option."),
                    obs("Gameplay usando la función en una situación real.", "Gameplay using the feature in a real situation."),
                    shot("Detalle de la interfaz o del ajuste con un círculo de énfasis.", "Interface or setting detail with an emphasis ring.")
                ],
                editing: copy(
                    "Alterna captura limpia y detalle; señaliza el menú exacto con un círculo.",
                    "Alternate clean capture and detail; mark the exact menu item with a ring."
                ),
                reHook: copy(
                    "Antes del segundo cambio: «Pero hay otra pieza que cambia más de lo que parece».",
                    "Before the second change: “But there is another piece that changes more than it looks”."
                )
            ),
            scene("What changes II", .explanation, 75,
                prompt: copy(
                    "Segundo cambio con la misma estructura. Si hay letra pequeña o límites, enséñalos en pantalla.",
                    "Second change with the same structure. If there is fine print or a limit, show it on screen."
                ),
                captures: [
                    obs("Gameplay del segundo sistema en condiciones distintas.", "Gameplay of the second system under different conditions."),
                    shot("Captura del menú o de la letra pequeña del parche.", "Capture of the menu or the patch's fine print."),
                    web("Fuente oficial que explique el alcance real del cambio.", "Official source explaining the real scope of the change.")
                ],
                editing: copy(
                    "Reutiliza el mismo orden visual que en el primer bloque para que la comparación sea inmediata.",
                    "Reuse the same visual order as the first block so the comparison reads instantly."
                ),
                reHook: copy(
                    "Puente hacia las sensaciones: «La lista de cambios no dice cómo se siente».",
                    "Bridge into feel: “The changelog does not say how it feels”."
                )
            ),
            scene("Physics and performance", .example, 75,
                prompt: copy(
                    "Cuenta qué probaste, con qué coche y en qué condiciones. Separa sensación de dato: FFB, neumáticos, frametime.",
                    "Say what you tested, in which car and under which conditions. Separate feel from data: FFB, tires, frametime."
                ),
                captures: [
                    obs("Gameplay a bordo con tres curvas representativas.", "Cockpit gameplay through three representative corners."),
                    shot("Gráfico de telemetría o frametime con una lectura clara.", "Telemetry or frametime chart with a clear reading."),
                    cam("Reacción a cámara después de la primera tanda.", "Talking-head reaction after the first stint.")
                ],
                editing: copy(
                    "Baja la música en los momentos de telemetría y deja respirar el sonido del motor.",
                    "Drop the music during telemetry moments and let the engine breathe."
                ),
                reHook: copy(
                    "Antes del contenido: «Y después de conducirlo, toca mirar el garaje».",
                    "Before content: “And after driving it, it is time to look at the garage”."
                )
            ),
            scene("Content", .explanation, 60,
                prompt: copy(
                    "Coches, pistas y modos. Valora calidad frente a variedad y di qué falta sin convertirlo en una lista.",
                    "Cars, tracks and modes. Weigh quality against variety and say what is missing without turning it into a list."
                ),
                captures: [
                    obs("Selección de coches y pistas en el menú, sin recorrerlos todos.", "Car and track selection in the menu, without scrolling through everything."),
                    shot("Captura del garaje con los coches nuevos agrupados.", "Garage capture with the new cars grouped together."),
                    web("Página oficial con el contenido incluido en la versión.", "Official page listing the content included in the version.")
                ],
                editing: copy(
                    "Agrupa los coches por categoría en un solo plano; evita una diapositiva por coche.",
                    "Group cars by category in one shot; avoid one slide per car."
                )
            ),
            scene("What is missing", .problem, 60,
                prompt: copy(
                    "Lo que la actualización no trae: hoja de ruta, funciones canceladas y fechas. Distingue hecho, rumor y deseo.",
                    "What the update does not bring: roadmap, canceled features and dates. Separate fact, rumor and wish."
                ),
                captures: [
                    web("Hoja de ruta con las fechas anteriores y las nuevas.", "Roadmap with the old dates and the new ones."),
                    cam("Plano a cámara con tono calmado; no conviertas la ausencia en un sketch.", "Talking head with a calm tone; do not turn the absence into a sketch."),
                    shot("Rótulo de «confirmado», «rumor» o «sin fecha» sobre la captura.", "“Confirmed”, “rumor” or “no date” label over the capture.")
                ],
                editing: copy(
                    "Marca cada ausencia con un rótulo corto y una fuente visible.",
                    "Mark each missing item with a short label and a visible source."
                ),
                reHook: copy(
                    "«Y todo esto importa porque la comunidad no reacciona solo a lo que llega».",
                    "“And all of this matters because the community does not react only to what arrives”."
                )
            ),
            scene("Community", .whyThisMatters, 45,
                prompt: copy(
                    "Resume la reacción con dos posturas razonables. Cita sin convertir el vídeo en un hilo de comentarios.",
                    "Sum up the reaction with two reasonable positions. Quote without turning the video into a comment thread."
                ),
                captures: [
                    web("Mosaico de dos o tres comentarios positivos y negativos.", "Mosaic of two or three positive and negative comments."),
                    shot("Captura de una encuesta o de un hilo representativo.", "Capture of a poll or a representative thread."),
                    cam("Plano corto a cámara para matizar tu lectura.", "Short talking-head shot to qualify your reading.")
                ],
                editing: copy(
                    "Difumina nombres y avatares; deja solo el texto de la cita.",
                    "Blur names and avatars; leave only the quoted text."
                )
            ),
            scene("Verdict by profile", .takeaway, 60,
                prompt: copy(
                    "Tres perfiles: quien lo dejó, quien compite y quien va a comprar. Un veredicto claro por cada uno.",
                    "Three profiles: the lapsed player, the competitor and the new buyer. One clear verdict for each."
                ),
                captures: [
                    cam("Tres planos o tres marcas de cámara, uno por perfil.", "Three shots or three camera marks, one per profile."),
                    shot("Rótulo con el perfil y una palabra de veredicto.", "Title card with the profile and a one-word verdict."),
                    obs("Un clip corto que represente cada perfil.", "A short clip representing each profile.")
                ],
                editing: copy(
                    "Tres rótulos, tres cortes: no mezcles los perfiles en el mismo plano.",
                    "Three cards, three cuts: do not mix profiles in the same shot."
                )
            ),
            scene("CTA", .cta, 20,
                prompt: copy(
                    "Una pregunta concreta y una sola acción. Nada de tres llamadas seguidas.",
                    "One specific question and one action. No three calls to action in a row."
                ),
                captures: [
                    cam("Plano final a cámara, luz cálida y ritmo pausado.", "Final talking-head shot with warm light and a slower pace."),
                    web("Pantalla de comentarios o encuesta preparada para la pregunta.", "Comment section or poll screen prepared for the question."),
                    obs("Clip de cierre con el coche en pista.", "Closing clip with the car on track.")
                ],
                editing: copy(
                    "Deja la pregunta en pantalla al menos tres segundos después de decirla.",
                    "Keep the question on screen for at least three seconds after saying it."
                )
            )
        ]
    )

    // MARK: - 2. Mod or car review (9 scenes)

    private static let modReview = Definition(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        kind: .modReview,
        name: "Simracing Mod or Car Review",
        scenes: [
            scene("Hook", .hook, 15,
                prompt: copy(
                    "Un dato o una contradicción en 10–15 s y la promesa de responder si merece la pena. Deja claro que no es para todo el mundo.",
                    "A fact or contradiction in 10–15 s and the promise of whether it is worth it. Make clear it is not for everyone."
                ),
                captures: [
                    cam("Plano medio a cámara con el coche o el mod al fondo.", "Medium talking-head shot with the car or mod in the background."),
                    obs("Primer clip conduciendo el coche o el mod en su hábitat.", "First clip driving the car or mod in its natural habitat."),
                    shot("Rótulo con el nombre, la versión y el precio.", "Title card with the name, version and price.")
                ],
                editing: copy(
                    "Empieza por el veredicto visual y abre con la pregunta; no empieces por la ficha técnica.",
                    "Start with the visual verdict and the question; do not open with the spec sheet."
                )
            ),
            scene("What it is and who makes it", .whyThisMatters, 45,
                prompt: copy(
                    "Estudio, licencia, precio y reputación. Lo justo para entender quién está detrás.",
                    "Studio, license, price and reputation. Just enough to understand who is behind it."
                ),
                captures: [
                    web("Página del estudio o del mod con la licencia visible.", "Studio or mod page with the license visible."),
                    shot("Captura de la ficha con precio y requisitos.", "Capture of the listing with price and requirements."),
                    obs("Un plano del coche o del mod en el garaje.", "A shot of the car or mod in the garage.")
                ],
                editing: copy(
                    "No leas la ficha: destaca solo el dato que cambia la decisión.",
                    "Do not read the listing: highlight only the detail that changes the decision."
                )
            ),
            scene("Versions and installation", .explanation, 60,
                prompt: copy(
                    "Versiones disponibles, requisitos y pasos de instalación. Enseña el orden real, no un diagrama.",
                    "Available versions, requirements and installation steps. Show the real order, not a diagram."
                ),
                captures: [
                    obs("Instalación o configuración paso a paso, con cursor visible.", "Step-by-step installation or setup with a visible cursor."),
                    shot("Captura de la carpeta o del gestor con la versión correcta.", "Capture of the folder or manager with the correct version."),
                    web("Página de descarga con requisitos y notas de compatibilidad.", "Download page with requirements and compatibility notes.")
                ],
                editing: copy(
                    "Acelera las partes repetitivas y deja en tiempo real el paso que suele fallar.",
                    "Speed through repetitive parts and keep the step that usually fails in real time."
                )
            ),
            scene("How it works I", .explanation, 60,
                prompt: copy(
                    "Dos o tres conceptos clave, con una analogía técnica corta. Nada de teoría sin consecuencia.",
                    "Two or three key concepts with a short technical analogy. No theory without a consequence."
                ),
                captures: [
                    obs("Interfaz o menú donde se ajusta el concepto explicado.", "Interface or menu where the explained concept is adjusted."),
                    shot("Esquema sencillo con las dos o tres piezas clave.", "Simple diagram with the two or three key parts."),
                    cam("Plano a cámara para la analogía, sin atrezo.", "Talking-head shot for the analogy, no props.")
                ],
                editing: copy(
                    "Una idea por bloque; si el esquema necesita cinco etiquetas, divídelo.",
                    "One idea per block; if the diagram needs five labels, split it."
                )
            ),
            scene("How it works II", .explanation, 60,
                prompt: copy(
                    "Volante, interfaz, telemetría y botones. Explica solo lo que cambia la experiencia.",
                    "Wheel, interface, telemetry and buttons. Explain only what changes the experience."
                ),
                captures: [
                    obs("Recorrido por la interfaz y los botones que importan.", "Walkthrough of the interface and the buttons that matter."),
                    cam("Plano de manos y volante usando el control.", "Hands-and-wheel shot using the control."),
                    shot("Captura de telemetría o de la pantalla auxiliar.", "Telemetry or auxiliary-screen capture.")
                ],
                editing: copy(
                    "Señala cada botón con un rótulo breve; no narres el manual entero.",
                    "Point to each button with a short label; do not narrate the whole manual."
                ),
                reHook: copy(
                    "«Y todo esto se entiende mejor cuando lo llevas a la pista».",
                    "“And all of this makes more sense once you take it to the track”."
                )
            ),
            scene("Driving feel", .example, 75,
                prompt: copy(
                    "Tacto, frenada y límites con una prueba real. Describe qué puedes corregir y qué no.",
                    "Feel, braking and limits with a real test. Describe what you can correct and what you cannot."
                ),
                captures: [
                    obs("Gameplay a bordo con frenadas y apoyo en tres curvas.", "Cockpit gameplay with braking and support through three corners."),
                    cam("Reacción a cámara después de la tanda.", "Talking-head reaction after the stint."),
                    shot("Telemetría con la comparación de frenada o de velocidad.", "Telemetry comparing braking or speed.")
                ],
                editing: copy(
                    "Deja el sonido del motor limpio en las frenadas; la música entra después.",
                    "Keep the engine sound clean under braking; bring the music in afterwards."
                )
            ),
            scene("Comparison", .whyThisMatters, 60,
                prompt: copy(
                    "Compara con la versión anterior, el juego base o la competencia. Una diferencia por bloque.",
                    "Compare with the previous version, the base game or the competition. One difference per block."
                ),
                captures: [
                    obs("Pantalla dividida con la misma curva en dos versiones.", "Split screen with the same corner in two versions."),
                    shot("Tabla de dos columnas con tres diferencias objetivas.", "Two-column table with three objective differences."),
                    web("Fuente de precio, licencia o compatibilidad para la comparación.", "Price, license or compatibility source for the comparison.")
                ],
                editing: copy(
                    "Mantén el mismo encuadre y la misma hora del día; si cambias uno, avísalo.",
                    "Keep the same framing and time of day; if you change one, say so."
                )
            ),
            scene("Gripes and who should skip it", .problem, 45,
                prompt: copy(
                    "IA, complejidad, requisitos y precio. Sé explícito sobre quién no debería comprarlo.",
                    "AI, complexity, requirements and price. Be explicit about who should not buy it."
                ),
                captures: [
                    cam("Plano a cámara con tono directo, sin disculpas.", "Talking-head shot with a direct tone, no apologies."),
                    shot("Captura de requisitos o de la limitación concreta.", "Capture of the requirements or the specific limitation."),
                    web("Comentario o fuente que documente la pega.", "Comment or source documenting the gripe.")
                ],
                editing: copy(
                    "Agrupa las pegas en dos bloques; no encadenes diez quejas sin respirar.",
                    "Group the gripes into two blocks; do not chain ten complaints without a breath."
                ),
                reHook: copy(
                    "«Y aun con todo, hay un perfil al que sí le encaja».",
                    "“And even so, there is one profile it fits perfectly”."
                )
            ),
            scene("Verdict and CTA", .cta, 45,
                prompt: copy(
                    "Resume para quién sí y para quién no, con una recomendación final y una pregunta.",
                    "Sum up who it is for and who it is not, with a final recommendation and a question."
                ),
                captures: [
                    cam("Plano final a cámara con el coche detrás.", "Final talking-head shot with the car behind you."),
                    obs("Clip final conduciendo el coche o el mod.", "Closing clip driving the car or mod."),
                    shot("Rótulo con el veredicto en una frase.", "Title card with the verdict in one sentence.")
                ],
                editing: copy(
                    "Cierra con la recomendación dicha y escrita; no añadas una tercera idea.",
                    "Close with the recommendation spoken and written; do not add a third idea."
                )
            )
        ]
    )

    // MARK: - 3. Comparison (8 scenes)

    private static let comparison = Definition(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
        kind: .comparison,
        name: "Simracing Comparison",
        scenes: [
            scene("Hook", .hook, 15,
                prompt: copy(
                    "La pregunta de comparación y el conflicto en 10–15 s. Anuncia los criterios, no el ganador.",
                    "The comparison question and the conflict in 10–15 s. Announce the criteria, not the winner."
                ),
                captures: [
                    cam("Plano medio a cámara con los dos candidatos al fondo.", "Medium talking-head shot with both contenders in the background."),
                    obs("Pantalla dividida con los dos candidatos en la misma curva.", "Split screen with both contenders in the same corner."),
                    shot("Rótulo con la pregunta y los dos nombres.", "Title card with the question and both names.")
                ],
                editing: copy(
                    "Corta entre los dos nombres al ritmo de la pregunta; no muestres el ganador todavía.",
                    "Cut between both names on the beat of the question; do not reveal the winner yet."
                )
            ),
            scene("Criteria", .whyThisMatters, 45,
                prompt: copy(
                    "Qué se compara y por qué esos criterios importan. Fija el protocolo: mismo circuito, misma hora, mismos ajustes y mismas vueltas. Define el marco antes de defender nada.",
                    "What is being compared and why those criteria matter. Fix the protocol: same track, same time of day, same settings and same number of laps. Define the frame before arguing for anything."
                ),
                captures: [
                    shot("Tabla de criterios con tres o cuatro filas, legible en móvil.", "Criteria table with three or four rows, readable on mobile."),
                    web("Fuente oficial de cada dato que se va a comparar.", "Official source for each data point being compared."),
                    cam("Plano a cámara para explicar el criterio que más pesa.", "Talking-head shot to explain the criterion that matters most.")
                ],
                editing: copy(
                    "Mantén los criterios en pantalla mientras comparas; no los repitas en cada bloque.",
                    "Keep the criteria on screen while comparing; do not repeat them in every block."
                )
            ),
            scene("Competitor A", .explanation, 60,
                prompt: copy(
                    "Fortalezas y debilidades del primer candidato, con una prueba por cada una.",
                    "Strengths and weaknesses of the first contender, with one proof for each."
                ),
                captures: [
                    obs("Gameplay del candidato A en su mejor escenario.", "Gameplay of contender A in its best scenario."),
                    shot("Captura de la función o del dato que lo hace fuerte.", "Capture of the feature or data point that makes it strong."),
                    web("Fuente que documente la debilidad principal.", "Source documenting the main weakness.")
                ],
                editing: copy(
                    "Usa el mismo color de acento para el candidato A en todo el vídeo.",
                    "Use the same accent color for contender A throughout the video."
                )
            ),
            scene("Competitor B", .explanation, 60,
                prompt: copy(
                    "Mismo orden y mismo nivel de exigencia para el segundo. No cambies la vara de medir.",
                    "Same order and same level of scrutiny for the second. Avoid moving the goalposts."
                ),
                captures: [
                    obs("Gameplay del candidato B en el mismo escenario.", "Gameplay of contender B in the same scenario."),
                    shot("Captura de la función o del dato equivalente.", "Capture of the equivalent feature or data point."),
                    web("Fuente que documente la debilidad principal.", "Source documenting the main weakness.")
                ],
                editing: copy(
                    "Reutiliza los mismos planos y rótulos; solo cambia el color y el nombre.",
                    "Reuse the same shots and labels; only the color and name change."
                )
            ),
            scene("On-screen table", .example, 45,
                prompt: copy(
                    "Datos objetivos en una tabla legible. Explica cómo leerla y qué no mide.",
                    "Objective data in a readable table. Explain how to read it and what it does not measure."
                ),
                captures: [
                    shot("Tabla completa a pantalla, con la fila que más importa resaltada.", "Full table on screen with the most important row highlighted."),
                    obs("Clip corto de cada candidato junto a la tabla.", "Short clip of each contender next to the table."),
                    web("Enlace o captura de la fuente de cada cifra.", "Link or capture of the source for each figure.")
                ],
                editing: copy(
                    "Aguanta la tabla al menos cinco segundos; si necesitas más, divídela en dos.",
                    "Hold the table for at least five seconds; if you need more, split it in two."
                ),
                reHook: copy(
                    "«Pero los números no siempre cuentan la misma historia que las manos».",
                    "“But the numbers do not always tell the same story as your hands”."
                )
            ),
            scene("Winner by profile", .takeaway, 45,
                prompt: copy(
                    "Tres perfiles y un ganador por perfil. Si no hay ganador claro, dilo.",
                    "Three profiles and a winner for each. If there is no clear winner, say so."
                ),
                captures: [
                    cam("Tres marcas de cámara, una por perfil.", "Three camera marks, one per profile."),
                    shot("Rótulo con el perfil y el ganador.", "Title card with the profile and the winner."),
                    obs("Un clip del ganador en la situación de ese perfil.", "A clip of the winner in that profile's situation.")
                ],
                editing: copy(
                    "No mezcles dos perfiles en el mismo plano; cambia el rótulo antes de cambiar de clip.",
                    "Do not mix two profiles in the same shot; change the card before changing the clip."
                ),
                reHook: copy(
                    "«Pero hay cosas que ninguna tabla puede comparar».",
                    "“But there are things no table can compare”."
                )
            ),
            scene("What cannot be compared", .problem, 45,
                prompt: copy(
                    "Precio, plataforma, licencia y matices. Lo que la tabla deja fuera también decide.",
                    "Price, platform, license and nuance. What the table leaves out also decides."
                ),
                captures: [
                    web("Captura de precio, plataforma o licencia de cada opción.", "Capture of price, platform or license for each option."),
                    shot("Rótulo de «fuera de la tabla» con el criterio que falta.", "“Outside the table” label with the missing criterion."),
                    cam("Plano a cámara para el matiz que no cabe en una fila.", "Talking-head shot for the nuance that does not fit in a row.")
                ],
                editing: copy(
                    "Baja el ritmo: este bloque evita que la tabla parezca una verdad absoluta.",
                    "Slow the pace: this block keeps the table from looking like absolute truth."
                )
            ),
            scene("CTA", .cta, 20,
                prompt: copy(
                    "Pregunta al espectador por su caso concreto y propón una sola acción.",
                    "Ask about the viewer's specific case and one action."
                ),
                captures: [
                    cam("Plano final a cámara con los dos candidatos al fondo.", "Final talking-head shot with both contenders in the background."),
                    web("Encuesta o pantalla de comentarios lista para la pregunta.", "Poll or comment screen ready for the question."),
                    shot("Rótulo con la pregunta final.", "Title card with the final question.")
                ],
                editing: copy(
                    "Deja la pregunta en pantalla y corta antes de que el vídeo pierda energía.",
                    "Keep the question on screen and cut before the video loses energy."
                )
            )
        ]
    )

    // MARK: - 4. News and reaction (7 scenes)

    private static let news = Definition(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
        kind: .news,
        name: "Simracing News and Reaction",
        scenes: [
            scene("Hook", .hook, 15,
                prompt: copy(
                    "Qué ha pasado y por qué importa en 10–15 s. Si es un rumor, dilo en la primera frase.",
                    "What happened and why it matters in 10–15 s. If it is a rumor, say so in the first sentence."
                ),
                captures: [
                    cam("Plano medio a cámara, reacción breve y mirada directa.", "Medium talking-head shot, brief reaction and direct eye contact."),
                    web("Captura del titular o del comunicado original.", "Capture of the headline or the original statement."),
                    shot("Rótulo con la fecha y la fuente principal.", "Title card with the date and the main source.")
                ],
                editing: copy(
                    "Enseña el titular real antes de dar tu opinión; no lo tapes con rótulos.",
                    "Show the real headline before giving your opinion; do not cover it with labels."
                )
            ),
            scene("Confirmed facts", .explanation, 45,
                prompt: copy(
                    "Fuentes, fechas y cifras. Cita solo lo que puedas sostener.",
                    "Sources, dates and figures. Cite only what you can stand behind."
                ),
                captures: [
                    web("Comunicado o nota oficial con el dato clave resaltado.", "Official statement or post with the key fact highlighted."),
                    shot("Captura de la fecha y la cifra en contexto.", "Capture of the date and figure in context."),
                    obs("Clip del juego o del contenido afectado por la noticia.", "Clip of the game or content affected by the news.")
                ],
                editing: copy(
                    "Una fuente por dato; si no hay fuente, no lo presentes como hecho.",
                    "One source per fact; if there is no source, do not present it as fact."
                )
            ),
            scene("What it means", .whyThisMatters, 45,
                prompt: copy(
                    "Consecuencias para el jugador, el juego o la comunidad. Separa consecuencia de deseo.",
                    "Consequences for the player, the game or the community. Separate consequence from wish."
                ),
                captures: [
                    obs("Gameplay del escenario que cambia con la noticia.", "Gameplay of the scenario the news changes."),
                    shot("Rótulo de «qué cambia» con dos consecuencias.", "“What changes” card with two consequences."),
                    cam("Plano a cámara para la consecuencia menos obvia.", "Talking-head shot for the least obvious consequence.")
                ],
                editing: copy(
                    "No repitas los hechos: empieza directamente por la consecuencia.",
                    "Do not repeat the facts: start directly with the consequence."
                )
            ),
            scene("What is not confirmed", .problem, 45,
                prompt: copy(
                    "Rumores y especulación, con su origen y su nivel de confianza.",
                    "Rumors and speculation, with their origin and confidence level."
                ),
                captures: [
                    web("Captura del rumor y de su autor original.", "Capture of the rumor and its original author."),
                    shot("Rótulo de «no confirmado» o «sin fecha».", "“Unconfirmed” or “no date” label."),
                    cam("Plano a cámara para marcar el límite entre dato y deseo.", "Talking-head shot to mark the line between fact and wish.")
                ],
                editing: copy(
                    "Usa un tono visual distinto para lo no confirmado; que se note sin leer el rótulo.",
                    "Use a different visual tone for the unconfirmed part; make it visible without reading the label."
                ),
                reHook: copy(
                    "«Y aquí es donde la noticia deja de ser solo un titular».",
                    "“And this is where the news stops being just a headline”."
                )
            ),
            scene("Community", .whyThisMatters, 30,
                prompt: copy(
                    "Dos reacciones representativas, sin amplificar la más ruidosa.",
                    "Two representative reactions, without amplifying the loudest one."
                ),
                captures: [
                    web("Mosaico de dos comentarios con posturas opuestas.", "Mosaic of two comments with opposing positions."),
                    shot("Captura de una encuesta o de un hilo con contexto.", "Capture of a poll or thread with context.")
                ],
                editing: copy(
                    "Difumina nombres y deja el texto legible; no conviertas una cita en la voz de toda la comunidad.",
                    "Blur names and keep the text readable; do not turn one quote into the voice of the whole community."
                )
            ),
            scene("Opinion", .takeaway, 45,
                prompt: copy(
                    "Tu tesis en tres frases. No repitas el resumen de hechos.",
                    "Your thesis in three sentences. Do not repeat the fact summary."
                ),
                captures: [
                    cam("Plano a cámara más cerrado para la opinión.", "Tighter talking-head shot for the opinion."),
                    obs("Clip de cierre que ilustre la tesis.", "Closing clip illustrating the thesis."),
                    shot("Rótulo con la tesis en una frase.", "Title card with the thesis in one sentence.")
                ],
                editing: copy(
                    "Cambia el tratamiento visual al entrar en opinión; el espectador debe saber que es tu lectura.",
                    "Change the visual treatment when the opinion starts; the viewer must know it is your reading."
                )
            ),
            scene("CTA", .cta, 20,
                prompt: copy(
                    "Pregunta qué haría el espectador y cierra con una acción.",
                    "Ask what the viewer would do and close with one action."
                ),
                captures: [
                    cam("Plano final a cámara, tono de conversación.", "Final talking-head shot with a conversational tone."),
                    web("Pantalla de comentarios o encuesta lista.", "Comment screen or poll ready."),
                    shot("Rótulo con la pregunta final.", "Title card with the final question.")
                ],
                editing: copy(
                    "Corta justo después de la pregunta; no añadas un resumen final.",
                    "Cut right after the question; do not add a final recap."
                )
            )
        ]
    )

    // MARK: - 5. Race chronicle (7 scenes)

    private static let raceChronicle = Definition(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!,
        kind: .raceChronicle,
        name: "Simracing Race Chronicle",
        scenes: [
            scene("Hook / result", .hook, 15,
                prompt: copy(
                    "El momento clave o el resultado en 10–15 s. Sitúa al espectador antes de explicar cómo llegaste.",
                    "The key moment or the result in 10–15 s. Place the viewer before explaining how you got there."
                ),
                captures: [
                    obs("Repetición del adelantamiento o del incidente clave.", "Replay of the key overtake or incident."),
                    cam("Plano a cámara con la reacción del momento.", "Talking-head shot with the reaction of the moment."),
                    shot("Rótulo con la posición final y el tiempo.", "Title card with the final position and time.")
                ],
                editing: copy(
                    "Abre con la repetición en el momento exacto; no empieces por la parrilla.",
                    "Open on the replay at the exact moment; do not start with the grid."
                )
            ),
            scene("Context", .whyThisMatters, 45,
                prompt: copy(
                    "Campeonato, coche, pista y objetivo. Solo lo necesario para entender la carrera.",
                    "Championship, car, track and goal. Only what is needed to understand the race."
                ),
                captures: [
                    shot("Captura de la clasificación antes de la carrera.", "Standings capture before the race."),
                    web("Fuente del calendario, las reglas o la clasificación.", "Source for the calendar, rules or standings."),
                    shot("Rótulo con coche, pista y objetivo.", "Title card with car, track and goal.")
                ],
                editing: copy(
                    "No pases de cuarenta y cinco segundos de contexto; si necesitas más, repártelo en dos escenas.",
                    "Do not spend more than forty-five seconds on context; if you need more, split it into two scenes."
                )
            ),
            scene("Preparation", .example, 45,
                prompt: copy(
                    "Setup, estrategia y clasificación. Qué probaste y qué decidiste antes de salir.",
                    "Setup, strategy and qualifying. What you tested and decided before the start."
                ),
                captures: [
                    obs("Pantalla de setup con los cambios clave.", "Setup screen with the key changes."),
                    shot("Telemetría o comparación de la vuelta de clasificación.", "Telemetry or comparison of the qualifying lap."),
                    cam("Plano a cámara explicando la decisión de estrategia.", "Talking-head shot explaining the strategy call.")
                ],
                editing: copy(
                    "Una decisión por bloque; no enseñes el setup entero si solo cambiaste dos cosas.",
                    "One decision per block; do not show the whole setup if you only changed two things."
                )
            ),
            scene("The race", .explanation, 90,
                prompt: copy(
                    "Inicio, incidente y remontada. Cuenta la carrera con una idea por bloque y una prueba visual.",
                    "Start, incident and comeback. Tell the race with one idea per block and one visual proof."
                ),
                captures: [
                    obs("Gameplay de la salida y de las primeras vueltas.", "Gameplay of the start and first laps."),
                    cam("Reacción a cámara en el momento del incidente.", "Talking-head reaction at the moment of the incident."),
                    shot("Repetición o telemetría del punto de adelantamiento.", "Replay or telemetry of the overtake point.")
                ],
                editing: copy(
                    "Alterna repetición y cámara; si una vuelta no cambia la historia, resúmela en un rótulo.",
                    "Alternate replay and camera; if a lap does not change the story, sum it up in a card."
                ),
                reHook: copy(
                    "«Todo lo que probé en la preparación se juega ahora».",
                    "“Everything I tested in practice is decided now”."
                )
            ),
            scene("Data", .example, 45,
                prompt: copy(
                    "Telemetría, tiempos y posiciones. Un dato por idea y una lectura clara.",
                    "Telemetry, times and positions. One data point per idea and a clear reading."
                ),
                captures: [
                    shot("Gráfico de telemetría con una sola comparación resaltada.", "Telemetry chart with a single highlighted comparison."),
                    obs("Clip de la vuelta más rápida o del sector clave.", "Clip of the fastest lap or the key sector."),
                    web("Clasificación final o estadística oficial.", "Final standings or official statistic.")
                ],
                editing: copy(
                    "Muestra el número y dilo una vez; no leas la tabla entera.",
                    "Show the number and say it once; do not read the whole table."
                ),
                reHook: copy(
                    "«Y lo que dicen los números no siempre coincide con lo que sentí».",
                    "“And what the numbers say does not always match what I felt”."
                )
            ),
            scene("Conclusion", .takeaway, 45,
                prompt: copy(
                    "Qué aprendiste y qué cambiarías en la próxima. Sin moraleja genérica.",
                    "What you learned and what you would change next time. No generic moral."
                ),
                captures: [
                    cam("Plano a cámara con el casco o el volante fuera de plano.", "Talking-head shot with the helmet or wheel out of frame."),
                    obs("Clip final del coche en pista o en el garaje.", "Closing clip of the car on track or in the garage."),
                    shot("Rótulo con la lección en una frase.", "Title card with the lesson in one sentence.")
                ],
                editing: copy(
                    "Cierra con una imagen tranquila y deja que la frase final respire.",
                    "Close on a calm image and let the final sentence breathe."
                )
            ),
            scene("CTA", .cta, 20,
                prompt: copy(
                    "Anuncia el siguiente reto y pide una decisión concreta.",
                    "Announce the next challenge and ask for one specific decision."
                ),
                captures: [
                    cam("Plano final a cámara, tono cercano.", "Final talking-head shot with a warm tone."),
                    web("Encuesta o comentario fijado con el siguiente reto.", "Poll or pinned comment with the next challenge."),
                    obs("Avance corto del siguiente coche o circuito.", "Short teaser of the next car or track.")
                ],
                editing: copy(
                    "Deja el siguiente reto escrito en pantalla; no lo digas solo de pasada.",
                    "Leave the next challenge written on screen; do not just mention it in passing."
                )
            )
        ]
    )
}

/// Small Spanish/English copy pair with an optional Russian translation.
/// Russian template guidance falls back to English until it is translated.
struct SimracingCopy: Sendable {
    let english: String
    let spanish: String
    let russian: String?

    func text(for language: AppLanguage) -> String {
        switch Self.resolvedLanguage(language) {
        case .spanish: spanish
        case .russian: russian ?? english
        default: english
        }
    }

    static func resolvedLanguage(_ language: AppLanguage) -> AppLanguage {
        guard language == .system else { return language }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        if preferred.hasPrefix("es") { return .spanish }
        if preferred.hasPrefix("ru") { return .russian }
        return .english
    }

    /// Guidance, capture suggestions and editing notes have no Russian translation
    /// yet. Russian projects use the complete English guidance instead of a mix.
    static func guidanceLanguage(_ language: AppLanguage) -> AppLanguage {
        let resolved = resolvedLanguage(language)
        return resolved == .russian ? .english : resolved
    }
}

