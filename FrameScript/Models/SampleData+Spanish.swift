import Foundation

extension SampleData {
    /// Spanish built-in demo. It is a self-contained anchor-first showcase set in a
    /// fictional simracing game so the app can be evaluated without real titles.
    static var spanishDemoProject: FrameProject {
        let hook = "La actualización 3.0 de Apexia promete arreglar el online y recuperar la categoría que todos pedían. También llega cuatro meses tarde.\n\n¿Devuelve la razón para volver o es otra promesa?"
        let problem = "El problema nunca fue la conducción. El modelo de neumáticos sigue siendo uno de los más legibles del mercado: notas el apoyo, entiendes la pérdida de agarre y puedes corregir sin adivinar.\n\nLo que fallaba era todo lo demás. El online abría salas vacías, el emparejamiento mezclaba niveles sin avisar y la progresión dependía de repetir la misma prueba hasta el cansancio. La 3.0 dice atacar esas tres cosas a la vez."
        let explanation = "El cambio más visible es el nuevo sistema de temporadas. Cada semana rota una serie con coches y circuitos fijos, y los resultados alimentan una clasificación dividida por divisiones.\n\nLa segunda pieza es la lluvia dinámica. La pista se seca por trazadas, los charcos cambian según la hora y el neumático intermedio por fin tiene una ventana útil. No es solo un efecto visual: obliga a elegir rueda antes de salir y a leer el cielo durante la carrera."
        let example = "Para probarlo hice tres carreras con el mismo coche y tres niveles de agarre distintos. En seco, la diferencia entre el compuesto blando y el duro se nota en la primera frenada. Con lluvia ligera, el intermedio aguanta seis vueltas antes de degradarse; con el de seco, la pérdida llega en dos.\n\nEl dato que más me sorprendió fue el frametime. En la carrera de 20 coches se mantuvo estable, pero los tres primeros segundos tras cambiar de clima dieron un tirón visible. Merece la pena esperar medio segundo antes de atacar."
        let takeaway = "La 3.0 no convierte a Apexia en otro juego. Sigue siendo un simulador que pide paciencia, lectura y ganas de entender el coche antes de pedirle un tiempo.\n\nPero por primera vez en mucho tiempo, el online tiene una estructura que invita a volver mañana. Si venías del modo carrera clásico, espera: todavía no está. Si solo querías una razón para encender el volante otra vez, esta actualización la da.\n\nCuéntame en los comentarios qué categoría quieres ver en la próxima temporada y nos vemos en la siguiente vuelta."

        let analysisTemplateID = SimracingTemplates.all
            .first(where: { $0.kind == .updateAnalysis })?
            .frameTemplate
            .id

        return FrameProject(
            title: "Análisis de Apexia: la actualización 3.0",
            templateID: analysisTemplateID,
            scenes: [
                scene(
                    order: 0,
                    type: .hook,
                    title: "Gancho",
                    text: hook,
                    notes: "Abre en frío con la promesa y el retraso. La pregunta final debe llegar antes del segundo 15.",
                    visuals: [
                        visual("actualización 3.0", .screenRecording, "Montaje de OBS con el menú de la 3.0 y tres clips de carrera.", mood: "expectación contenida", framing: "montaje rápido", motion: "cortes al ritmo", duration: 4, notes: "Usa clips propios y evita capturas de prensa.", status: .planned),
                        visual("actualización 3.0", .textOnScreen, "Rótulo: 3.0 → promesa frente a retraso.", mood: "directo", framing: "tipografía a pantalla completa", motion: "revelado seco", duration: 2, notes: "Duplica el ancla a propósito para agrupar las opciones de apertura.", status: .idea),
                        visual("cuatro meses tarde", .screenshot, "Captura de la hoja de ruta con las fechas originales y las nuevas.", mood: "sobrio", framing: "captura completa", motion: "zoom lento", duration: 3, notes: "Difumina cualquier dato personal de la cuenta.", status: .sourced)
                    ],
                    edits: [
                        edit("promete arreglar el online", cut: "Apertura en frío con tres cortes", transition: "Corte seco al rótulo", subtitles: "Palabras clave", emphasis: "Subrayar «arreglar»", zoom: "Ninguno", sfx: "Tres clics suaves", music: "Pulso mínimo", graphics: "Rótulo 3.0 → promesa", notes: "El gancho no debe pasar de quince segundos."),
                        edit("arreglar el online", cut: "Repetición del clip de apertura", transition: "Corte directo", subtitles: "Sin subtítulos", emphasis: "Ninguno", zoom: "Empuje del 6%", sfx: "", music: "El pulso baja", graphics: "Ninguno", notes: "Rango solapado a propósito para probar la navegación agrupada.")
                    ],
                    reviews: [
                        review("Claridad del gancho", .suggestion, "El contraste entre promesa y retraso funciona; conviene separar la pregunta final en su propio beat.", "Deja medio segundo de silencio antes de «¿Es el parche...?».")
                    ],
                    templateType: "Análisis de actualización"
                ),
                scene(
                    order: 1,
                    type: .problem,
                    title: "Problema",
                    text: problem,
                    notes: "La conducción no es el problema. Nombra las tres fricciones del online sin culpar al jugador.",
                    visuals: [
                        visual("El problema nunca fue la conducción", .talkingHead, "Plano medio a cámara con el volante desenfocado al fondo.", mood: "frustración tranquila", framing: "medio a cámara", motion: "estático con foco suave", duration: 4, notes: "Reacción natural, sin comedia.", status: .done),
                        visual("salas vacías", .screenshot, "Captura del navegador de servidores con muy pocas salas activas.", mood: "desierto", framing: "captura de interfaz", motion: "zoom lento", duration: 3, notes: "Difumina nombres de jugadores y servidores.", status: .planned),
                        visual("repetir la misma prueba", .stockFootage, "Repetición de vueltas idénticas en el mismo circuito.", mood: "monótono", framing: "plano recurso", motion: "acelerado suave", duration: 3, notes: "Sirve como metáfora del bucle de progresión.", status: .idea)
                    ],
                    edits: [
                        edit("emparejamiento mezclaba niveles sin avisar", cut: "Tres cortes secos", transition: "Corte al detalle", subtitles: "Sin subtítulos", emphasis: "Resaltar «sin avisar»", zoom: "Micro empuje", sfx: "Teclado suave", music: "El pulso se estrecha", graphics: "Icono de emparejamiento", notes: "Cada fricción merece una prueba visual distinta.")
                    ],
                    reviews: [
                        review("Concreción", .important, "El problema es reconocible, pero la consecuencia para el jugador puede aparecer antes.", "Adelanta «emparejamiento mezclaba niveles» al primer párrafo.")
                    ],
                    templateType: "Análisis de actualización"
                ),
                scene(
                    order: 2,
                    type: .explanation,
                    title: "Explicación",
                    text: explanation,
                    notes: "Muestra el sistema como una decisión de temporada, no como una lista de menús.",
                    visuals: [
                        visual("nuevo sistema de temporadas", .screenRecording, "OBS del calendario de temporadas y la clasificación por divisiones.", mood: "estructura clara", framing: "interfaz amplia", motion: "paneo suave", duration: 5, notes: "Revela una división a la vez.", status: .planned),
                        visual("lluvia dinámica", .screenRecording, "OBS gameplay con la pista secándose por trazadas.", mood: "inmersivo", framing: "a bordo", motion: "plano continuo", duration: 5, notes: "Elige una curva donde se vea el cambio de superficie.", status: .sourced),
                        visual("No es solo un efecto visual", .infographic, "Esquema de compuestos y ventana de uso.", mood: "didáctico", framing: "gráfico centrado", motion: "construcción por capas", duration: 4, notes: "Tres etiquetas como máximo.", status: .idea)
                    ],
                    edits: [
                        edit("obliga a elegir rueda antes de salir", cut: "Explicación pausada", transition: "Disolvencia", subtitles: "Conceptos clave", emphasis: "Resaltar «antes de salir»", zoom: "Zoom al menú", sfx: "Confirmación suave", music: "Entra un pad cálido", graphics: "Compuestos en pantalla", notes: "El espectador debe entender la decisión sin leer el menú.")
                    ],
                    reviews: [
                        review("Ritmo", .note, "La explicación gana si el segundo párrafo empieza por la consecuencia y no por el efecto.", "Abre el bloque de lluvia con «obliga a elegir rueda».")
                    ],
                    templateType: "Análisis de actualización"
                ),
                scene(
                    order: 3,
                    type: .example,
                    title: "Ejemplo práctico",
                    text: example,
                    notes: "Tres carreras, tres niveles de agarre. Un dato por idea; nada de listar vueltas.",
                    visuals: [
                        visual("tres carreras", .talkingHead, "CAM de reacción antes de la primera tanda.", mood: "concentrado", framing: "primer plano", motion: "estático", duration: 3, notes: "Graba la reacción antes de mirar los tiempos.", status: .done),
                        visual("frametime", .screenshot, "Gráfico de frametime durante el cambio de clima.", mood: "analítico", framing: "gráfico a pantalla", motion: "zoom al pico", duration: 4, notes: "Marca el pico y la vuelta exacta.", status: .planned),
                        visual("tirón visible", .screenRecording, "OBS del momento exacto del tirón al cambiar de clima.", mood: "tensión", framing: "a bordo", motion: "repetición a 0,5x", duration: 4, notes: "No lo repitas más de dos veces.", status: .sourced)
                    ],
                    edits: [
                        edit("esperar medio segundo antes de atacar", cut: "Demostración con repetición", transition: "Corte al gráfico", subtitles: "Datos clave", emphasis: "Resaltar «medio segundo»", zoom: "Pico del frametime", sfx: "Click y silencio", music: "La música baja", graphics: "Marca del pico", notes: "La explicación debe funcionar sin sonido.")
                    ],
                    reviews: [
                        review("Evidencia", .suggestion, "El ejemplo es concreto; conviene decir cuántas vueltas duró cada tanda.", "Añade el número de vueltas junto al compuesto.")
                    ],
                    templateType: "Análisis de actualización"
                ),
                scene(
                    order: 4,
                    type: .takeaway,
                    title: "Conclusión / CTA",
                    text: takeaway,
                    notes: "Veredicto por perfiles y una sola pregunta final. Sin presión de compra.",
                    visuals: [
                        visual("no convierte a Apexia en otro juego", .talkingHead, "Plano final a cámara con luz cálida.", mood: "honesto", framing: "medium close-up", motion: "estático", duration: 5, notes: "Baja el ritmo y mira a objetivo.", status: .done),
                        visual("el online tiene una estructura", .infographic, "Tres iconos: temporada, división y recompensa.", mood: "optimista", framing: "centrado", motion: "aparición secuencial", duration: 4, notes: "Reutiliza el lenguaje visual de la explicación.", status: .planned),
                        visual("Cuéntame en los comentarios", .textOnScreen, "Pregunta final en pantalla.", mood: "cercano", framing: "tipografía centrada", motion: "fundido", duration: 3, notes: "Deja la pregunta visible al menos tres segundos.", status: .idea)
                    ],
                    edits: [
                        edit("qué categoría quieres ver en la próxima temporada", cut: "Cierre pausado", transition: "Fundido a color", subtitles: "Pregunta final", emphasis: "Resaltar «próxima temporada»", zoom: "Retroceso lento", sfx: "Resolución suave", music: "Resolución y fundido", graphics: "Pregunta + siguiente vídeo", notes: "No añadas una segunda llamada a la acción.")
                    ],
                    reviews: [
                        review("CTA", .note, "El cierre es claro y deja una decisión concreta al espectador.", "Mantén la pregunta en pantalla sin rótulos extra.")
                    ],
                    templateType: "Análisis de actualización"
                )
            ],
            exportPresets: [ExportPreset(id: UUID(), name: "Entrega al editor", format: .productionOutline)]
        )
    }
}
