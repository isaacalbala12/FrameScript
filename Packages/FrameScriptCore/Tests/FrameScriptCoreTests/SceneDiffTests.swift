import Foundation
import Testing
@testable import FrameScriptCore

@Suite("SceneDiff")
struct SceneDiffTests {
    @Test func identicalSnapshotsHaveNoChanges() {
        let snapshot = SceneSnapshot(
            text: "Hola mundo.",
            notes: "Nota de edición.",
            broll: [SceneItem(id: "b1", text: "Plano del coche")]
        )
        let diff = SceneDiff.compute(old: snapshot, new: snapshot)
        #expect(!diff.hasChanges)
        #expect(diff.changedFields.isEmpty)
        #expect(diff.text.ops.isEmpty)
        #expect(diff.notes.ops.isEmpty)
        #expect(diff.broll.isIdentical)
    }

    @Test func textAndNotesUseWordDiff() {
        let old = SceneSnapshot(text: "El niño comió piña.", notes: "Grabar de cerca.")
        let new = SceneSnapshot(text: "El niño comió sandía.", notes: "Grabar de lejos.")
        let diff = SceneDiff.compute(old: old, new: new)

        #expect(diff.hasChanges)
        #expect(diff.changedFields == [.text, .notes])
        #expect(diff.text.hasChanges)
        #expect(diff.notes.hasChanges)
        #expect(WordDiff.apply(diff.text.ops, to: old.text) == new.text)
        #expect(WordDiff.apply(diff.notes.ops, to: old.notes) == new.notes)
    }

    @Test func onlyTextChanged() {
        let old = SceneSnapshot(text: "Uno.", notes: "Igual")
        let new = SceneSnapshot(text: "Dos.", notes: "Igual")
        let diff = SceneDiff.compute(old: old, new: new)
        #expect(diff.changedFields == [.text])
        #expect(diff.notes.ops.isEmpty)
    }

    @Test func brollAddedRemovedAndChanged() {
        let old = SceneSnapshot(
            text: "Guion",
            broll: [
                SceneItem(id: "b1", text: "Coche entrando en curva"),
                SceneItem(id: "b2", text: "Onboard"),
                SceneItem(id: "b3", text: "Público")
            ]
        )
        let new = SceneSnapshot(
            text: "Guion",
            broll: [
                SceneItem(id: "b2", text: "Onboard del piloto"),
                SceneItem(id: "b4", text: "Drone")
            ]
        )
        let diff = SceneDiff.compute(old: old, new: new)

        #expect(diff.changedFields == [.broll])
        #expect(diff.broll.added.map(\.id) == ["b4"])
        #expect(diff.broll.removed.map(\.id).sorted() == ["b1", "b3"])
        #expect(diff.broll.changed.count == 1)
        #expect(diff.broll.changed.first?.old.text == "Onboard")
        #expect(diff.broll.changed.first?.new.text == "Onboard del piloto")
    }

    @Test func brollReorderIsDetected() {
        let old = SceneSnapshot(broll: [
            SceneItem(id: "a", text: "A"),
            SceneItem(id: "b", text: "B"),
            SceneItem(id: "c", text: "C")
        ])
        let new = SceneSnapshot(broll: [
            SceneItem(id: "c", text: "C"),
            SceneItem(id: "a", text: "A"),
            SceneItem(id: "b", text: "B")
        ])
        let diff = SceneDiff.compute(old: old, new: new)
        #expect(diff.broll.orderChanged)
        #expect(diff.broll.added.isEmpty)
        #expect(diff.broll.removed.isEmpty)
        #expect(diff.broll.changed.isEmpty)
        #expect(diff.hasChanges)
    }

    @Test func addingItemDoesNotCountAsReorder() {
        let old = SceneSnapshot(broll: [SceneItem(id: "a", text: "A")])
        let new = SceneSnapshot(broll: [
            SceneItem(id: "x", text: "X"),
            SceneItem(id: "a", text: "A"),
            SceneItem(id: "y", text: "Y")
        ])
        let diff = SceneDiff.compute(old: old, new: new)
        #expect(!diff.broll.orderChanged)
        #expect(diff.broll.added.count == 2)
    }

    @Test func notesChangeUsesDiffOps() {
        let old = SceneSnapshot(notes: "Luz cálida, plano medio, sin música.")
        let new = SceneSnapshot(notes: "Luz fría, plano medio, con música.")
        let diff = SceneDiff.compute(old: old, new: new)
        #expect(diff.changedFields == [.notes])
        #expect(diff.notes.ops.contains { $0.kind == .insert })
        #expect(diff.notes.ops.contains { $0.kind == .delete })
    }

    @Test func itemListDiffWithGenericItems() {
        struct Tag: Equatable, Sendable {
            let id: String
            let value: String
        }
        let diff = ItemListDiff<Tag>.compute(
            old: [Tag(id: "1", value: "uno"), Tag(id: "2", value: "dos")],
            new: [Tag(id: "2", value: "DOS"), Tag(id: "3", value: "tres")],
            id: \.id
        )
        #expect(diff.added.map(\.id) == ["3"])
        #expect(diff.removed.map(\.id) == ["1"])
        #expect(diff.changed.count == 1)
        #expect(diff.changed.first?.new.value == "DOS")
    }
}
