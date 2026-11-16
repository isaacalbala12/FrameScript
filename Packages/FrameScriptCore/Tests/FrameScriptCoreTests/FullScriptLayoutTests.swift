import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Full script layout")
struct FullScriptLayoutTests {
    private func header(_ number: Int, title: String, duration: String = "1:00") -> String {
        String(format: "%02d", number) + " · " + title + " · " + duration
    }

    private func descriptor(
        _ id: UUID,
        number: Int,
        title: String,
        body: String,
        collapsed: Bool = false
    ) -> FullScriptSceneDescriptor {
        FullScriptSceneDescriptor(
            id: id,
            headerText: header(number, title: title),
            bodyText: body,
            isCollapsed: collapsed
        )
    }

    @Test("One scene keeps an exact header/body/separator layout")
    func oneScene() throws {
        let id = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(id, number: 1, title: "Gancho", body: "Hola mundo.")
        ])

        #expect(layout.text == "01 · Gancho · 1:00\nHola mundo.\n")
        let segment = try #require(layout.segment(for: id))
        #expect(layout.text.utf16.count == layout.utf16Length)
        #expect(segment.headerRange == NSRange(location: 0, length: 19))
        #expect(segment.bodyRange == NSRange(location: 19, length: 11))
        #expect(segment.separatorRange == NSRange(location: 30, length: 1))
        #expect(segment.sceneRange == NSRange(location: 0, length: 31))
        #expect(layout.sceneID(atUTF16Location: 0) == id)
        #expect(layout.sceneID(atUTF16Location: 19) == id)
        #expect(layout.sceneID(atUTF16Location: 30) == id)
        #expect(layout.sceneID(atUTF16Location: 31) == id)
        #expect(layout.sceneID(atUTF16Location: 32) == nil)
    }

    @Test("Every scene body stays byte-for-byte identical, including CRLF")
    func crlfAndWhitespace() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let bodies = [
            "Línea uno\r\nLínea dos\r\n",
            "   \n\t  ",
            ""
        ]
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "CRLF", body: bodies[0]),
            descriptor(second, number: 2, title: "Espacios", body: bodies[1]),
            descriptor(third, number: 3, title: "Vacía", body: bodies[2])
        ])

        for (index, id) in [first, second, third].enumerated() {
            let segment = try #require(layout.segment(for: id))
            let extracted = (layout.text as NSString).substring(with: segment.bodyRange)
            #expect(extracted == bodies[index])
            #expect(segment.bodyRange.length == bodies[index].utf16.count)
        }
        // CRLF survives verbatim: the separator newlines are extra characters,
        // never a normalization pass over the scene text.
        #expect(layout.text.contains("Línea uno\r\nLínea dos\r\n\n"))
        #expect(layout.sceneID(atUTF16Location: 0) == first)
    }

    @Test("Emoji, combining marks and flags use UTF-16 ranges")
    func unicodeUTF16() throws {
        let first = UUID()
        let second = UUID()
        // 👩‍🚀 is a ZWJ sequence; the flag is a surrogate pair; e + combining
        // acute is two UTF-16 units even though it is one grapheme.
        let body = "👩‍🚀 viaja 🇪🇸 con cafe\u{0301}."
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "Unicode 👩‍🚀", body: body),
            descriptor(second, number: 2, title: "Después", body: "fin")
        ])

        let firstSegment = try #require(layout.segment(for: first))
        #expect(firstSegment.bodyRange.length == (body as NSString).length)
        #expect(firstSegment.bodyRange.length > body.count)
        #expect((layout.text as NSString).substring(with: firstSegment.bodyRange) == body)

        let secondSegment = try #require(layout.segment(for: second))
        #expect(secondSegment.headerRange.location == NSMaxRange(firstSegment.separatorRange))
        #expect((layout.text as NSString).substring(with: secondSegment.bodyRange) == "fin")

        // A caret after the emoji must resolve to the first scene, and the
        // first character of the second body must resolve to the second scene.
        #expect(layout.sceneID(atUTF16Location: firstSegment.bodyRange.location + 2) == first)
        #expect(layout.sceneID(atUTF16Location: secondSegment.bodyRange.location) == second)
    }

    @Test("Empty and whitespace-only scenes keep distinct zero-length slots")
    func emptyScenes() throws {
        let first = UUID()
        let empty = UUID()
        let spaces = UUID()
        let last = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "Uno", body: "texto"),
            descriptor(empty, number: 2, title: "Vacía", body: ""),
            descriptor(spaces, number: 3, title: "Espacios", body: "  \t"),
            descriptor(last, number: 4, title: "Última", body: "")
        ])

        let emptySegment = try #require(layout.segment(for: empty))
        let spacesSegment = try #require(layout.segment(for: spaces))
        let lastSegment = try #require(layout.segment(for: last))
        #expect(emptySegment.bodyRange.length == 0)
        #expect(spacesSegment.bodyRange.length == 3)
        #expect(lastSegment.bodyRange.length == 0)
        #expect(emptySegment.bodyRange.location != spacesSegment.bodyRange.location)
        #expect(emptySegment.bodyRange.location != lastSegment.bodyRange.location)
        #expect(layout.sceneID(atUTF16Location: emptySegment.bodyRange.location) == empty)
        #expect(layout.sceneID(atUTF16Location: spacesSegment.bodyRange.location) == spaces)
        #expect(layout.sceneID(atUTF16Location: lastSegment.bodyRange.location) == last)
        // Typing into an empty scene is allowed at its single caret slot.
        #expect(layout.resolveEdit(in: NSRange(location: emptySegment.bodyRange.location, length: 0))?.sceneID == empty)
        #expect(layout.resolveEdit(in: NSRange(location: lastSegment.bodyRange.location, length: 0))?.sceneID == last)
    }

    @Test("Fifty scenes produce a complete, non-overlapping map")
    func fiftyScenes() {
        let ids = (0..<50).map { _ in UUID() }
        let descriptors = ids.enumerated().map { index, id in
            descriptor(id, number: index + 1, title: "Escena \(index + 1)", body: "Texto \(index + 1).")
        }
        let layout = FullScriptLayout(scenes: descriptors)

        #expect(layout.segments.count == 50)
        var previousEnd = 0
        for (index, segment) in layout.segments.enumerated() {
            #expect(segment.sceneID == ids[index])
            #expect(segment.headerRange.location == previousEnd)
            #expect(NSMaxRange(segment.headerRange) == segment.bodyRange.location)
            #expect(NSMaxRange(segment.bodyRange) == segment.separatorRange.location)
            #expect(segment.separatorRange.length == 1)
            #expect((layout.text as NSString).substring(with: segment.bodyRange) == "Texto \(index + 1).")
            previousEnd = NSMaxRange(segment.separatorRange)
            #expect(layout.sceneID(atUTF16Location: segment.bodyRange.location) == segment.sceneID)
        }
        #expect(previousEnd == layout.utf16Length)
        #expect(layout.sceneID(atUTF16Location: layout.utf16Length) == ids.last)
    }

    // MARK: Edit resolution

    @Test("Typing at either body edge is accepted and stays in that scene")
    func bodyEdges() throws {
        let first = UUID()
        let second = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "Uno", body: "abc"),
            descriptor(second, number: 2, title: "Dos", body: "def")
        ])
        let firstSegment = try #require(layout.segment(for: first))
        let secondSegment = try #require(layout.segment(for: second))

        let start = layout.resolveEdit(in: NSRange(location: firstSegment.bodyRange.location, length: 0))
        #expect(start?.sceneID == first)
        #expect(start?.localRange == NSRange(location: 0, length: 0))

        let end = layout.resolveEdit(in: NSRange(location: NSMaxRange(firstSegment.bodyRange), length: 0))
        #expect(end?.sceneID == first)
        #expect(end?.localRange == NSRange(location: 3, length: 0))

        let secondStart = layout.resolveEdit(in: NSRange(location: secondSegment.bodyRange.location, length: 0))
        #expect(secondStart?.sceneID == second)
        #expect(secondStart?.localRange == NSRange(location: 0, length: 0))
    }

    @Test("Backspace at a body start and forward-delete at a body end are rejected")
    func headerEditsRejected() throws {
        let first = UUID()
        let second = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "Uno", body: "abc"),
            descriptor(second, number: 2, title: "Dos", body: "def")
        ])
        let firstSegment = try #require(layout.segment(for: first))
        let secondSegment = try #require(layout.segment(for: second))

        // Backspace at the start of scene 1.
        #expect(layout.resolveEdit(in: NSRange(location: firstSegment.bodyRange.location - 1, length: 1)) == nil)
        // Backspace at the start of scene 2 would eat scene 1's separator.
        #expect(layout.resolveEdit(in: NSRange(location: secondSegment.bodyRange.location - 1, length: 1)) == nil)
        // Forward delete at the end of scene 1 eats its separator.
        #expect(layout.resolveEdit(in: NSRange(location: NSMaxRange(firstSegment.bodyRange), length: 1)) == nil)
        // Forward delete at the end of the last scene eats its separator.
        #expect(layout.resolveEdit(in: NSRange(location: NSMaxRange(secondSegment.bodyRange), length: 1)) == nil)
        // Edits fully inside the body are accepted.
        #expect(layout.resolveEdit(in: NSRange(location: firstSegment.bodyRange.location, length: 1))?.sceneID == first)
        #expect(layout.resolveEdit(in: NSRange(location: NSMaxRange(firstSegment.bodyRange) - 1, length: 1))?.sceneID == first)
    }

    @Test("Cross-scene edits, select-all and out-of-bounds ranges are rejected")
    func spanningRejected() throws {
        let first = UUID()
        let second = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "Uno", body: "abc"),
            descriptor(second, number: 2, title: "Dos", body: "def")
        ])
        let firstSegment = try #require(layout.segment(for: first))
        let secondSegment = try #require(layout.segment(for: second))

        #expect(layout.resolveEdit(in: NSRange(location: 0, length: layout.utf16Length)) == nil)
        #expect(layout.resolveEdit(in: NSRange(
            location: NSMaxRange(firstSegment.bodyRange) - 1,
            length: firstSegment.separatorRange.length + 2
        )) == nil)
        #expect(layout.resolveEdit(in: NSRange(
            location: firstSegment.bodyRange.location,
            length: NSMaxRange(secondSegment.bodyRange) - firstSegment.bodyRange.location
        )) == nil)
        #expect(layout.resolveEdit(in: NSRange(location: -1, length: 0)) == nil)
        #expect(layout.resolveEdit(in: NSRange(location: layout.utf16Length, length: 0)) == nil)
        #expect(layout.resolveEdit(in: NSRange(location: layout.utf16Length + 1, length: 0)) == nil)
        #expect(layout.resolveEdit(in: NSRange(location: layout.utf16Length, length: 1)) == nil)
        // A scene body's whole contents may be selected and replaced.
        #expect(layout.resolveEdit(in: firstSegment.bodyRange)?.sceneID == first)
        #expect(layout.resolveEdit(in: secondSegment.bodyRange)?.sceneID == second)
    }

    @Test("Collapsed scenes expose a header but no editable body")
    func collapsedScene() throws {
        let first = UUID()
        let second = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(first, number: 1, title: "Uno", body: "oculto", collapsed: true),
            descriptor(second, number: 2, title: "Dos", body: "visible")
        ])
        let firstSegment = try #require(layout.segment(for: first))
        #expect(firstSegment.isCollapsed)
        #expect(firstSegment.bodyRange.length == 0)
        #expect(layout.text.contains("oculto") == false)
        #expect(layout.resolveEdit(in: NSRange(location: firstSegment.bodyRange.location, length: 0)) == nil)
        #expect(layout.resolveEdit(in: firstSegment.headerRange) == nil)
        #expect(layout.sceneID(atUTF16Location: firstSegment.headerRange.location) == first)
        let secondSegment = try #require(layout.segment(for: second))
        #expect(layout.resolveEdit(in: secondSegment.bodyRange)?.sceneID == second)
    }

    @Test("Body length after an edit is derived from the authorized local range")
    func expectedBodyLength() throws {
        let id = UUID()
        let layout = FullScriptLayout(scenes: [
            descriptor(id, number: 1, title: "Uno", body: "abc")
        ])
        let segment = try #require(layout.segment(for: id))
        let insertion = try #require(layout.resolveEdit(in: NSRange(location: segment.bodyRange.location + 1, length: 0)))
        #expect(layout.bodyLength(afterApplying: insertion, replacementLength: 5) == 8)
        let replacement = try #require(layout.resolveEdit(in: NSRange(location: segment.bodyRange.location, length: 2)))
        #expect(layout.bodyLength(afterApplying: replacement, replacementLength: 0) == 1)
        #expect(layout.bodyLength(afterApplying: replacement, replacementLength: -1) == nil)
    }

    @Test("No scenes means an empty document and no owner")
    func noScenes() {
        let layout = FullScriptLayout(scenes: [])
        #expect(layout.text.isEmpty)
        #expect(layout.segments.isEmpty)
        #expect(layout.utf16Length == 0)
        #expect(layout.sceneID(atUTF16Location: 0) == nil)
        #expect(layout.resolveEdit(in: NSRange(location: 0, length: 0)) == nil)
    }
}
