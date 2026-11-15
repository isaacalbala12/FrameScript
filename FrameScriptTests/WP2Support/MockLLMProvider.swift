import Foundation
import FrameScriptCore
@testable import FrameScript

/// Deterministic provider used by the hook generator and hook-prompt tests.
///
/// It used to live in the app target; only tests ever used it, so it lives in
/// the test target now and the shipping app has no fake provider to confuse a
/// future wiring mistake.
@MainActor
struct MockLLMProvider: LLMProviderProtocol {
    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        let russian = request.systemPrompt.contains("Russian")
        switch request.task {
        case .autocomplete:
            return LLMResponse(text: russian ? " с более ясным следующим акцентом." : " with a clearer next beat.")
        case .rewrite:
            return LLMResponse(text: russian ? "Вот более ясная и компактная версия выбранного фрагмента." : "Here is a cleaner, tighter version of the selected passage.")
        case .analyze:
            return LLMResponse(text: russian
                ? #"{"title":"Хук","severity":"suggestion","message":"Хук понятен, но ему нужен более конкретный пример.","suggestion":"Добавьте пример перед объяснением."}"#
                : #"{"title":"Hook","severity":"suggestion","message":"The hook is clear, but it needs a more concrete example.","suggestion":"Add the example before the explanation."}"#)
        case .bRollGeneration:
            return LLMResponse(text: russian
                ? #"{"source":"Custom","description":"Добавьте спокойную запись экрана с крупным планом.","notes":"Используйте одну простую подпись."}"#
                : #"{"source":"Custom","description":"Use a calm screen recording with a close-up insert.","notes":"Use one simple label."}"#)
        case .editingGeneration:
            return LLMResponse(text: russian
                ? #"{"description":"Сохраните прямые склейки и легкие приближения.","notes":"Оставьте в субтитрах только ключевые слова."}"#
                : #"{"description":"Keep hard cuts and subtle punch-ins.","notes":"Use keyword-only captions."}"#)
        case .hook:
            return LLMResponse(text: russian
                ? #"{"hooks":[{"angle":"контраст","text":"Новый патч обещает больше, чем даёт. Проблема в одном изменении, о котором никто не говорит.","onScreenText":"Что изменилось?"}]}"#
                : #"{"hooks":[{"angle":"contraste","text":"El parche promete más de lo que da. El problema está en un cambio del que nadie habla.","onScreenText":"¿Qué ha cambiado?"}]}"#)
        case .rehook:
            return Self.rehookResponse(for: request.userPrompt, russian: russian)
        case .clipAdaptation:
            return LLMResponse(text: ##"{"hook":"El detalle que cambia la decisión está en una sola curva.","adaptedText":"El detalle que cambia la decisión está en una sola curva. El resto del vídeo lo explica con calma.","onScreenText":"Una sola curva","description":"Versión corta del análisis, sin datos nuevos.","hashtags":["#simracing","#analisis"]}"##)
        }
    }

    /// Builds a valid bridge response from the first anchor in the prompt so
    /// the mock never returns an empty anchor when multiple positions exist.
    static func rehookResponse(for userPrompt: String, russian: Bool = false) -> LLMResponse {
        let text = russian
            ? "Но есть вторая деталь, которая меняет весь расклад."
            : "Pero hay una segunda pieza que cambia todo el planteamiento."
        let anchor = firstAnchor(in: userPrompt) ?? ""
        let payload: [String: Any] = ["bridges": [["text": text, "anchor": anchor]]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return LLMResponse(text: #"{"bridges":[]}"#)
        }
        return LLMResponse(text: json)
    }

    static func firstAnchor(in userPrompt: String) -> String? {
        for line in userPrompt.components(separatedBy: .newlines) {
            guard let range = line.range(of: "Anchor:") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }
}
