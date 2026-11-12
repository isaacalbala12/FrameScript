import Foundation

enum SampleData {
    static let templates: [FrameTemplate] = [
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, category: .script, name: "Blank", builtIn: true, structureDefinition: [], customFields: []),
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, category: .script, name: "Standard YouTube", builtIn: true, structureDefinition: ["Hook", "Problem", "Why this matters", "Explanation", "Example", "Takeaway", "CTA"], customFields: []),
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, category: .script, name: "Educational", builtIn: true, structureDefinition: ["Hook", "Context", "Problem", "Core explanation", "Example", "Summary", "CTA"], customFields: []),
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!, category: .script, name: "Storytelling", builtIn: true, structureDefinition: ["Setup", "Conflict", "Turning point", "Resolution", "Lesson", "CTA"], customFields: []),
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!, category: .script, name: "Product Review", builtIn: true, structureDefinition: ["Hook", "Product context", "What works", "What does not", "Verdict", "CTA"], customFields: []),
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000006")!, category: .script, name: "Commentary / Essay", builtIn: true, structureDefinition: ["Thesis", "Context", "Argument", "Counterpoint", "Implication", "Closing"], customFields: []),
        FrameTemplate(id: UUID(uuidString: "10000000-0000-0000-0000-000000000007")!, category: .script, name: "Tutorial", builtIn: true, structureDefinition: ["Goal", "Requirements", "Step 1", "Step 2", "Common mistake", "Recap"], customFields: [])
    ] + SimracingTemplates.frameTemplates

    static var defaultProject: FrameProject {
        project(named: "Untitled Script", template: templates.first, blankProjectStart: .oneEmptyScene)
    }

    static func project(
        named title: String,
        template: FrameTemplate?,
        blankProjectStart: BlankProjectStart = .oneEmptyScene,
        defaultSceneName: String = "New scene",
        exportPresetName: String = "Editor handoff",
        language: AppLanguage = .english,
        sceneNameResolver: (String) -> String = { $0 }
    ) -> FrameProject {
        if let template, template.builtIn, let blueprint = SimracingTemplates.definition(for: template) {
            return blueprint.makeProject(
                named: title,
                template: template,
                language: language,
                exportPresetName: exportPresetName
            )
        }
        let structure: [String]
        if template?.isBlank == true {
            structure = blankProjectStart == .oneEmptyScene ? [""] : []
        } else {
            structure = template?.structureDefinition ?? ["Hook", "Problem", "Explanation", "Example", "CTA"]
        }
        let scenes = structure.enumerated().map { index, name in
            let sceneID = UUID()
            let sceneTitle = name.isEmpty ? defaultSceneName : sceneNameResolver(name)
            return Scene(id: sceneID, order: index, sectionType: SectionType(rawValue: name) ?? .custom, title: sceneTitle, scriptText: "", notes: "", textSegments: [TextSegment(sceneID: sceneID, order: 0, sourceText: "", segmentType: .paragraph)])
        }
        return FrameProject(title: title, templateID: template?.id, scenes: scenes, exportPresets: [ExportPreset(id: UUID(), name: exportPresetName, format: .productionOutline)])
    }

    static func demoProject(language: AppLanguage) -> FrameProject {
        switch language {
        case .spanish: spanishDemoProject
        case .russian: russianDemoProject
        case .english, .system: englishDemoProject
        }
    }

    struct VisualSpec {
        let phrase: String
        let source: BRollSourceType
        let description: String
        let mood: String
        let framing: String
        let motion: String
        let duration: TimeInterval
        let notes: String
        let status: BRollStatus
    }

    struct EditSpec {
        let phrase: String
        let cut: String
        let transition: String
        let subtitles: String
        let emphasis: String
        let zoom: String
        let sfx: String
        let music: String
        let graphics: String
        let notes: String
    }

    struct ReviewSpec {
        let type: String
        let severity: AICommentSeverity
        let message: String
        let suggestion: String
    }

    static func visual(_ phrase: String, _ source: BRollSourceType, _ description: String, mood: String, framing: String, motion: String, duration: TimeInterval, notes: String, status: BRollStatus) -> VisualSpec {
        VisualSpec(phrase: phrase, source: source, description: description, mood: mood, framing: framing, motion: motion, duration: duration, notes: notes, status: status)
    }

    static func edit(_ phrase: String, cut: String, transition: String, subtitles: String, emphasis: String, zoom: String, sfx: String, music: String, graphics: String, notes: String) -> EditSpec {
        EditSpec(phrase: phrase, cut: cut, transition: transition, subtitles: subtitles, emphasis: emphasis, zoom: zoom, sfx: sfx, music: music, graphics: graphics, notes: notes)
    }

    static func review(_ type: String, _ severity: AICommentSeverity, _ message: String, _ suggestion: String) -> ReviewSpec {
        ReviewSpec(type: type, severity: severity, message: message, suggestion: suggestion)
    }

    static func anchor(_ phrase: String, in text: String) -> TextAnchor {
        guard let range = text.range(of: phrase) else { preconditionFailure("Demo anchor phrase must exist in its final script: \(phrase)") }
        let full = text as NSString
        let nsRange = NSRange(range, in: text)
        let prefixStart = max(0, nsRange.location - 48)
        let suffixStart = NSMaxRange(nsRange)
        return TextAnchor(
            startUTF16: nsRange.location,
            lengthUTF16: nsRange.length,
            selectedText: full.substring(with: nsRange),
            prefixContext: full.substring(with: NSRange(location: prefixStart, length: nsRange.location - prefixStart)),
            suffixContext: full.substring(with: NSRange(location: suffixStart, length: min(48, full.length - suffixStart)))
        )
    }

    static func scene(
        order: Int,
        type: SectionType,
        title: String,
        text: String,
        notes: String,
        visuals: [VisualSpec],
        edits: [EditSpec],
        reviews: [ReviewSpec],
        templateType: String = "Product showcase"
    ) -> Scene {
        let id = UUID()
        let segment = TextSegment(sceneID: id, order: 0, sourceText: text, segmentType: .scene, timingEstimate: DurationEstimator.estimate(text: text, wordsPerMinute: 150))
        return Scene(
            id: id,
            order: order,
            sectionType: type,
            title: title,
            scriptText: text,
            notes: notes,
            estimatedDuration: DurationEstimator.estimate(text: text, wordsPerMinute: 150),
            textSegments: [segment],
            aiComments: reviews.map { AIComment(sceneID: id, segmentID: segment.id, type: $0.type, severity: $0.severity, message: $0.message, suggestion: $0.suggestion, status: .new) },
            bRollItems: visuals.map { spec in
                BRollItem(textAnchor: anchor(spec.phrase, in: text), templateType: templateType, sourceType: spec.source, descriptionText: spec.description, mood: spec.mood, framing: spec.framing, motion: spec.motion, duration: spec.duration, notes: spec.notes, status: spec.status)
            },
            editingItems: edits.map { spec in
                EditingItem(textAnchor: anchor(spec.phrase, in: text), templateType: templateType, cutStyle: spec.cut, transition: spec.transition, subtitleStyle: spec.subtitles, emphasis: spec.emphasis, zoom: spec.zoom, sfx: spec.sfx, musicCue: spec.music, graphics: spec.graphics, notes: spec.notes)
            }
        )
    }

    private static var englishDemoProject: FrameProject {
        let hook = "A video can start as a blank page and still become a production mess. The words live in one tab, the visual plan in another, and the edit notes disappear into a chat thread.\n\nFrameScript turns that blank page into five connected decisions: what you say, what viewers see, how the edit moves, what still needs a review, and what your collaborator needs next."
        let problem = "Most creators do not lose momentum because they lack ideas. They lose it when an approved sentence has no shot, a perfect shot has no purpose, and an editor has to reconstruct both from fragments.\n\nThat handoff creates tiny questions at every beat. Which line deserves a zoom? Where should a subtitle land? Was this visual sourced, or was it only an idea?"
        let explanation = "In FrameScript, a scene is the unit of work. Write the voiceover, attach a precise visual range, and leave the edit direction beside the same words. The script stays readable while production decisions stay findable.\n\nAnchor-first links follow the selected text, so a useful note remains connected even when you refine the paragraph around it."
        let example = "Imagine a product tutorial with one promise: save ten minutes before recording. Select that promise, add a screen capture of the setup, then mark the exact click where the timer starts.\n\nYour editor opens one scene and sees the line, the proof, the transition, and the sound cue together. No detective work, no stale spreadsheet row."
        let takeaway = "The best creative system does not make a video feel more complicated. It makes the next decision obvious.\n\nOpen the showcase, explore the connected scene cards, then save your own copy when you are ready to turn a rough idea into a production-ready script."
        return FrameProject(title: "FrameScript Product Showcase", templateID: templates.first?.id, scenes: [
            scene(order: 0, type: .hook, title: "Hook", text: hook, notes: "Start on the creator's real workspace. Hold the product name until the contrast is clear.", visuals: [
                visual("blank page", .screenRecording, "A blank script beside scattered tabs and a chat thread.", mood: "focused tension", framing: "tight desktop crop", motion: "slow push-in", duration: 4, notes: "Use real-looking but generic workspace chrome.", status: .planned),
                visual("blank page", .textOnScreen, "Large kinetic words: blank page → production mess.", mood: "direct", framing: "full frame typography", motion: "snap reveal", duration: 2, notes: "Duplicate anchor intentionally groups the opening visual options.", status: .idea),
                visual("five connected decisions", .infographic, "Five linked cards for script, visuals, edit, review, and handoff.", mood: "confident", framing: "centered wide", motion: "cards assemble", duration: 5, notes: "Let each card inherit the accent color in sequence.", status: .sourced)
            ], edits: [
                edit("blank page into five connected decisions", cut: "Cold open with clean jump cuts", transition: "Hard cut into product view", subtitles: "Keyword highlights", emphasis: "Underline ‘production mess’", zoom: "8% punch-in", sfx: "Soft paper flick", music: "Minimal pulse begins", graphics: "Five-card map", notes: "Keep the opening under eight seconds."),
                edit("what viewers see, how the edit moves", cut: "Match cut", transition: "Card wipe", subtitles: "Two-line captions", emphasis: "Color-code each decision", zoom: "None", sfx: "Three light ticks", music: "Pulse continues", graphics: "Script / Visuals / Editing labels", notes: "This overlaps the first range to demonstrate grouped marker navigation.")
            ], reviews: [review("Hook clarity", .suggestion, "The contrast is strong; make the final product promise land on its own beat.", "Pause briefly before ‘FrameScript turns’.")]),
            scene(order: 1, type: .problem, title: "Problem", text: problem, notes: "Keep the pain concrete and familiar; avoid blaming the creator or editor.", visuals: [
                visual("approved sentence has no shot", .talkingHead, "Creator rereads a sentence, then looks at an empty timeline.", mood: "frustrated but calm", framing: "medium over-shoulder", motion: "static with rack focus", duration: 4, notes: "Use a natural reaction, not a comedy beat.", status: .done),
                visual("tiny questions at every beat", .stockFootage, "Rapid closeups of notes, timeline markers, and a cursor hovering.", mood: "restless", framing: "macro inserts", motion: "quick lateral cuts", duration: 5, notes: "Build rhythm without making the scene chaotic.", status: .planned)
            ], edits: [
                edit("a perfect shot has no purpose", cut: "Three-beat montage", transition: "Whip pan", subtitles: "Sentence fragments", emphasis: "Bold ‘no purpose’", zoom: "Micro punch-ins", sfx: "Muted keyboard taps", music: "Pulse narrows", graphics: "Question marks appear", notes: "Each fragment should have a distinct visual consequence.")
            ], reviews: [review("Specificity", .important, "The problem is relatable, but the second paragraph can point to the editor's consequence sooner.", "Bring ‘reconstruct both from fragments’ into the first two beats.")]),
            scene(order: 2, type: .explanation, title: "Explanation", text: explanation, notes: "Show the product as a calm workspace, not a feature checklist.", visuals: [
                visual("a scene is the unit of work", .productShot, "Clean FrameScript scene card with script, visual, and edit panels.", mood: "calm confidence", framing: "wide interface view", motion: "gentle pan", duration: 5, notes: "Reveal one column at a time.", status: .sourced),
                visual("Anchor-first links follow the selected text", .animation, "Highlighted words stay connected while surrounding copy changes.", mood: "reassuring", framing: "close interface crop", motion: "morph and settle", duration: 4, notes: "Use a subtle before/after edit.", status: .planned)
            ], edits: [
                edit("attach a precise visual range", cut: "Deliberate screen capture", transition: "Dissolve", subtitles: "Step labels", emphasis: "Highlight ‘precise’", zoom: "Cursor-follow zoom", sfx: "Single confirmation chime", music: "Warm pad enters", graphics: "Anchor line connects panels", notes: "Give viewers time to read the connection."),
                edit("production decisions stay findable", cut: "Hold on completed card", transition: "None", subtitles: "Full sentence", emphasis: "None", zoom: "Slow 4% pull-back", sfx: "", music: "Warm pad continues", graphics: "Searchable scene badge", notes: "Leave a small beat before the example.")
            ], reviews: [review("Pacing", .note, "This explanation earns a slower delivery because the anchor behavior is the product proof.", "Keep the second paragraph visually simple.")]),
            scene(order: 3, type: .example, title: "Practical Example", text: example, notes: "Treat this as a miniature handoff: one promise, one proof, one edit cue.", visuals: [
                visual("save ten minutes before recording", .textOnScreen, "Timer graphic and the promise appear beside a setup checklist.", mood: "practical", framing: "split screen", motion: "timer starts", duration: 3, notes: "Make the number readable at a glance.", status: .done),
                visual("screen capture of the setup", .screenRecording, "Cursor completes the setup while a timer begins.", mood: "instructional", framing: "full-screen capture", motion: "guided cursor", duration: 6, notes: "Use a clearly visible click target.", status: .sourced),
                visual("No detective work", .memeInsert, "A tiny magnifying glass icon is crossed out beside the finished scene.", mood: "light relief", framing: "corner insert", motion: "pop out", duration: 2, notes: "Keep this playful, not sarcastic.", status: .idea)
            ], edits: [
                edit("mark the exact click where the timer starts", cut: "Instructional hold", transition: "Click-match cut", subtitles: "Click-by-click captions", emphasis: "Circle the click", zoom: "120% interface zoom", sfx: "Click and timer start", music: "Music ducks for click", graphics: "Animated cursor ring", notes: "The action must be accessible without sound."),
                edit("the line, the proof, the transition, and the sound cue together", cut: "Four-panel reveal", transition: "Staggered slide", subtitles: "No subtitles", emphasis: "Color-code each panel", zoom: "None", sfx: "Four soft ticks", music: "Pulse opens", graphics: "Linked handoff board", notes: "End on a fully connected scene card.")
            ], reviews: [review("Demonstration", .suggestion, "The example is concrete and should now name the viewer benefit in the final sentence.", "Stress that one scene removes the handoff search.")]),
            scene(order: 4, type: .takeaway, title: "Takeaway / CTA", text: takeaway, notes: "End with an invitation to explore, not pressure to buy.", visuals: [
                visual("next decision obvious", .infographic, "A single highlighted next step moves through the five scene cards.", mood: "clear and optimistic", framing: "centered wide", motion: "guided path", duration: 4, notes: "Reuse the opening card system for a satisfying close.", status: .planned),
                visual("save your own copy", .productShot, "Save As dialog leads into a personal project title.", mood: "inviting", framing: "medium interface crop", motion: "gentle zoom out", duration: 4, notes: "Do not imply an online account or sync.", status: .idea)
            ], edits: [
                edit("Open the showcase, explore the connected scene cards", cut: "Calm closing hold", transition: "Fade through color", subtitles: "CTA sentence", emphasis: "Highlight ‘your own copy’", zoom: "Slow pull-back", sfx: "Soft resolve", music: "Resolve and fade", graphics: "Open demo / Save your copy", notes: "Keep the CTA on screen long enough to read.")
            ], reviews: [review("CTA", .note, "The call to action stays product-led and gives the viewer a low-risk next step.", "Keep the final sentence warm and unhurried.")])
        ], exportPresets: [ExportPreset(id: UUID(), name: "Editor handoff", format: .productionOutline)])
    }

    private static var russianDemoProject: FrameProject {
        let hook = "Видео может начаться с пустой страницы и всё равно превратиться в производственный хаос. Текст живёт в одной вкладке, план видеоряда — в другой, а заметки по монтажу исчезают в переписке.\n\nFrameScript превращает эту пустую страницу в пять связанных решений: что вы говорите, что видит зритель, как движется монтаж, что ещё нужно проверить и что понадобится вашему редактору дальше."
        let problem = "Большинство авторов теряют темп не потому, что у них нет идей. Он исчезает, когда у утверждённой фразы нет кадра, у идеального кадра нет смысла, а редактору приходится собирать и то и другое из фрагментов.\n\nНа каждом бите появляются маленькие вопросы. Какая строка заслуживает наезда? Где должна появиться субтитр? Этот визуал уже найден или пока остаётся только идеей?"
        let explanation = "В FrameScript сцена — это единица работы. Напишите озвучку, прикрепите точный диапазон видеоряда и оставьте монтажную задачу рядом с теми же словами. Сценарий остаётся читаемым, а производственные решения легко находятся.\n\nСвязи по якорям следуют за выделенным текстом, поэтому полезная заметка остаётся на месте, даже когда вы уточняете абзац вокруг неё."
        let example = "Представьте туториал с одним обещанием: сэкономить десять минут до записи. Выделите это обещание, добавьте запись экрана настройки, затем отметьте точный клик, с которого запускается таймер.\n\nРедактор открывает одну сцену и сразу видит строку, доказательство, переход и звуковой акцент. Никакой детективной работы и никаких устаревших строк в таблице."
        let takeaway = "Лучшая творческая система не делает видео сложнее. Она делает следующее решение очевидным.\n\nОткройте витрину, изучите связанные карточки сцен, а затем сохраните свою копию, когда будете готовы превратить сырую идею в сценарий, готовый к производству."
        return FrameProject(title: "Витрина продукта FrameScript", templateID: templates.first?.id, scenes: [
            scene(order: 0, type: .hook, title: "Хук", text: hook, notes: "Начните с реального рабочего пространства автора. Название продукта появляется только после контраста.", visuals: [
                visual("пустой страницы", .screenRecording, "Пустой сценарий рядом с вкладками и перепиской.", mood: "собранное напряжение", framing: "плотный фрагмент рабочего стола", motion: "медленный наезд", duration: 4, notes: "Интерфейс должен выглядеть знакомо, но оставаться нейтральным.", status: .planned),
                visual("пустой страницы", .textOnScreen, "Кинетическая типографика: пустая страница → производственный хаос.", mood: "прямой", framing: "текст на весь экран", motion: "быстрое появление", duration: 2, notes: "Дублирующий якорь намеренно собирает варианты вступительного визуала.", status: .idea),
                visual("пять связанных решений", .infographic, "Пять связанных карточек: сценарий, видеоряд, монтаж, проверка, передача.", mood: "уверенный", framing: "широкий центральный план", motion: "карточки собираются", duration: 5, notes: "Акцентный цвет появляется по очереди.", status: .sourced)
            ], edits: [
                edit("пустую страницу в пять связанных решений", cut: "Холодное открытие с чистыми склейками", transition: "Жёсткая склейка к продукту", subtitles: "Выделение ключевых слов", emphasis: "Подчеркнуть «хаос»", zoom: "Наезд 8%", sfx: "Тихий шелест бумаги", music: "Начинается минимальный пульс", graphics: "Карта из пяти карточек", notes: "Вступление — не дольше восьми секунд."),
                edit("что видит зритель, как движется монтаж", cut: "Склейка по совпадению", transition: "Смахивание карточек", subtitles: "Субтитры в две строки", emphasis: "Цветовой код решений", zoom: "Без наезда", sfx: "Три лёгких тика", music: "Пульс продолжается", graphics: "Подписи: сценарий / видеоряд / монтаж", notes: "Диапазон пересекается с первым, чтобы показать групповую навигацию.")
            ], reviews: [review("Ясность хука", .suggestion, "Контраст работает; дайте обещанию продукта отдельный бит.", "Сделайте короткую паузу перед «FrameScript превращает». ")]),
            scene(order: 1, type: .problem, title: "Проблема", text: problem, notes: "Боль должна быть конкретной и знакомой; не обвиняйте ни автора, ни редактора.", visuals: [
                visual("у утверждённой фразы нет кадра", .talkingHead, "Автор перечитывает фразу и смотрит на пустой таймлайн.", mood: "спокойное раздражение", framing: "средний план через плечо", motion: "статичный кадр с переводом фокуса", duration: 4, notes: "Нужна естественная реакция без комедийности.", status: .done),
                visual("маленькие вопросы", .stockFootage, "Крупные планы заметок, маркеров таймлайна и зависшего курсора.", mood: "беспокойный", framing: "макровставки", motion: "быстрые боковые склейки", duration: 5, notes: "Соберите ритм, не создавая хаоса.", status: .planned)
            ], edits: [
                edit("у идеального кадра нет смысла", cut: "Монтаж из трёх битов", transition: "Панорама-рывок", subtitles: "Фрагменты фраз", emphasis: "Выделить «нет смысла»", zoom: "Микронаезды", sfx: "Приглушённые клавиши", music: "Пульс сужается", graphics: "Появляются вопросительные знаки", notes: "У каждого фрагмента — своё визуальное последствие.")
            ], reviews: [review("Конкретность", .important, "Проблема узнаваема, но последствия для редактора можно обозначить раньше.", "Поднимите мысль о сборке из фрагментов в первые два бита.")]),
            scene(order: 2, type: .explanation, title: "Объяснение", text: explanation, notes: "Покажите продукт как спокойное рабочее пространство, а не как перечень функций.", visuals: [
                visual("сцена — это единица работы", .productShot, "Чистая карточка FrameScript со сценарным, визуальным и монтажным блоками.", mood: "спокойная уверенность", framing: "широкий вид интерфейса", motion: "мягкая панорама", duration: 5, notes: "Открывайте столбцы по одному.", status: .sourced),
                visual("Связи по якорям следуют за выделенным текстом", .animation, "Выделенные слова остаются связанными, пока соседний текст меняется.", mood: "надёжный", framing: "крупный фрагмент интерфейса", motion: "морфинг и фиксация", duration: 4, notes: "Сделайте ненавязчивое до/после.", status: .planned)
            ], edits: [
                edit("прикрепите точный диапазон видеоряда", cut: "Неторопливая запись экрана", transition: "Растворение", subtitles: "Подписи шагов", emphasis: "Выделить «точный»", zoom: "Наезд за курсором", sfx: "Один звук подтверждения", music: "Входит тёплый пад", graphics: "Якорная линия связывает панели", notes: "Дайте зрителю время увидеть связь."),
                edit("производственные решения легко находятся", cut: "Задержка на готовой карточке", transition: "Без перехода", subtitles: "Полная фраза", emphasis: "", zoom: "Медленный отъезд 4%", sfx: "", music: "Тёплый пад продолжается", graphics: "Метка поиска в сцене", notes: "Оставьте небольшой бит перед примером.")
            ], reviews: [review("Темп", .note, "Объяснение можно произнести медленнее: поведение якоря — это доказательство продукта.", "Во втором абзаце оставьте визуал простым.")]),
            scene(order: 3, type: .example, title: "Практический пример", text: example, notes: "Это мини-передача: одно обещание, одно доказательство, один монтажный сигнал.", visuals: [
                visual("сэкономить десять минут до записи", .textOnScreen, "Таймер и обещание рядом с чек-листом настройки.", mood: "практичный", framing: "разделённый экран", motion: "запуск таймера", duration: 3, notes: "Число должно читаться с первого взгляда.", status: .done),
                visual("запись экрана настройки", .screenRecording, "Курсор проходит настройку, пока запускается таймер.", mood: "обучающий", framing: "запись на весь экран", motion: "направляемый курсор", duration: 6, notes: "Точка клика должна быть заметна.", status: .sourced),
                visual("Никакой детективной работы", .memeInsert, "Маленькая лупа зачёркнута рядом с готовой сценой.", mood: "лёгкое облегчение", framing: "вставка в углу", motion: "появление", duration: 2, notes: "Легко и без сарказма.", status: .idea)
            ], edits: [
                edit("отметьте точный клик, с которого запускается таймер", cut: "Обучающая задержка", transition: "Склейка по клику", subtitles: "Пошаговые субтитры", emphasis: "Обвести клик", zoom: "Наезд интерфейса 120%", sfx: "Клик и запуск таймера", music: "Музыка приглушается", graphics: "Анимированное кольцо курсора", notes: "Действие должно быть понятно без звука."),
                edit("строку, доказательство, переход и звуковой акцент", cut: "Раскрытие четырёх панелей", transition: "Поочерёдный слайд", subtitles: "Без субтитров", emphasis: "Цветовой код панелей", zoom: "Без наезда", sfx: "Четыре мягких тика", music: "Пульс раскрывается", graphics: "Связанная доска передачи", notes: "Закончите на полностью связанной карточке сцены.")
            ], reviews: [review("Демонстрация", .suggestion, "Пример конкретный; в последней фразе стоит сильнее назвать пользу для зрителя.", "Подчеркните, что одна сцена убирает поиск при передаче.")]),
            scene(order: 4, type: .takeaway, title: "Вывод / CTA", text: takeaway, notes: "Финал приглашает исследовать продукт, а не давит продажей.", visuals: [
                visual("следующее решение очевидным", .infographic, "Один подсвеченный следующий шаг проходит через пять карточек сцен.", mood: "ясный и оптимистичный", framing: "широкий центральный план", motion: "направленный путь", duration: 4, notes: "Повторите систему карточек из вступления для цельного финала.", status: .planned),
                visual("сохраните свою копию", .productShot, "Диалог «Сохранить как» переходит к личному названию проекта.", mood: "приглашающий", framing: "средний фрагмент интерфейса", motion: "мягкий отъезд", duration: 4, notes: "Не создавайте впечатления, что нужен аккаунт или синхронизация.", status: .idea)
            ], edits: [
                edit("Откройте витрину, изучите связанные карточки сцен", cut: "Спокойная финальная задержка", transition: "Затухание через цвет", subtitles: "CTA одной фразой", emphasis: "Выделить «свою копию»", zoom: "Медленный отъезд", sfx: "Мягкое разрешение", music: "Разрешение и затухание", graphics: "Открыть демо / Сохранить свою копию", notes: "CTA остаётся на экране достаточно долго для чтения.")
            ], reviews: [review("CTA", .note, "Призыв остаётся ориентированным на продукт и даёт зрителю безопасный следующий шаг.", "Последнюю фразу произнесите тепло и без спешки.")])
        ], exportPresets: [ExportPreset(id: UUID(), name: "Передача редактору", format: .productionOutline)])
    }
}
