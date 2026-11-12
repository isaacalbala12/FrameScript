import Foundation

/// A B-roll or checklist item as seen by the diff layer.
///
/// The app's richer model can map to this value without the core package
/// depending on UI types. IDs must be stable and unique inside one list.
public struct SceneItem: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// The parts of a scene that version history compares (F21).
public struct SceneSnapshot: Sendable, Equatable, Codable {
    public var text: String
    public var notes: String
    public var broll: [SceneItem]

    public init(text: String = "", notes: String = "", broll: [SceneItem] = []) {
        self.text = text
        self.notes = notes
        self.broll = broll
    }
}

/// Added / removed / changed items between two lists, matched by ID.
public struct ItemListDiff<Item: Equatable & Sendable>: Sendable, Equatable {
    public struct ChangedPair: Sendable, Equatable {
        public let old: Item
        public let new: Item

        public init(old: Item, new: Item) {
            self.old = old
            self.new = new
        }
    }

    public let added: [Item]
    public let removed: [Item]
    public let changed: [ChangedPair]
    /// True when the shared items appear in a different relative order.
    public let orderChanged: Bool

    public var isIdentical: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && !orderChanged
    }

    public var hasChanges: Bool { !isIdentical }

    public init(
        added: [Item] = [],
        removed: [Item] = [],
        changed: [ChangedPair] = [],
        orderChanged: Bool = false
    ) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.orderChanged = orderChanged
    }

    /// Diffs two ID-keyed lists. Items present only in `new` are additions,
    /// items present only in `old` are removals and items with equal IDs but
    /// different values are changes. Duplicate IDs are collapsed to their first
    /// occurrence.
    public static func compute(
        old: [Item],
        new: [Item],
        id: @Sendable (Item) -> String
    ) -> ItemListDiff<Item> {
        var oldByID: [String: Item] = [:]
        var oldOrder: [String] = []
        oldByID.reserveCapacity(old.count)
        oldOrder.reserveCapacity(old.count)
        for item in old {
            let key = id(item)
            guard oldByID[key] == nil else { continue }
            oldByID[key] = item
            oldOrder.append(key)
        }

        var newByID: [String: Item] = [:]
        var newOrder: [String] = []
        newByID.reserveCapacity(new.count)
        newOrder.reserveCapacity(new.count)
        for item in new {
            let key = id(item)
            guard newByID[key] == nil else { continue }
            newByID[key] = item
            newOrder.append(key)
        }

        var added: [Item] = []
        for key in newOrder where oldByID[key] == nil {
            if let item = newByID[key] { added.append(item) }
        }

        var removed: [Item] = []
        for key in oldOrder where newByID[key] == nil {
            if let item = oldByID[key] { removed.append(item) }
        }

        var changed: [ChangedPair] = []
        for key in newOrder {
            guard let oldItem = oldByID[key], let newItem = newByID[key], oldItem != newItem else { continue }
            changed.append(ChangedPair(old: oldItem, new: newItem))
        }

        let commonOldOrder = oldOrder.filter { newByID[$0] != nil }
        let commonNewOrder = newOrder.filter { oldByID[$0] != nil }
        let orderChanged = commonOldOrder != commonNewOrder

        return ItemListDiff(
            added: added,
            removed: removed,
            changed: changed,
            orderChanged: orderChanged
        )
    }
}

/// Diffs two `SceneSnapshot` values for the version-history viewer.
///
/// Text and notes are compared word by word. B-roll items are matched by ID.
public struct SceneDiff: Sendable, Equatable {
    public enum Field: String, Sendable, Codable, CaseIterable {
        case text
        case notes
        case broll
    }

    public struct TextFieldDiff: Sendable, Equatable {
        public let field: Field
        public let oldText: String
        public let newText: String
        public let ops: [DiffOp]

        public init(field: Field, oldText: String, newText: String, ops: [DiffOp]) {
            self.field = field
            self.oldText = oldText
            self.newText = newText
            self.ops = ops
        }

        public var hasChanges: Bool { oldText != newText }
    }

    public let text: TextFieldDiff
    public let notes: TextFieldDiff
    public let broll: ItemListDiff<SceneItem>

    public var hasChanges: Bool {
        text.hasChanges || notes.hasChanges || broll.hasChanges
    }

    /// Fields with changes, in display order.
    public var changedFields: [Field] {
        var fields: [Field] = []
        if text.hasChanges { fields.append(.text) }
        if notes.hasChanges { fields.append(.notes) }
        if broll.hasChanges { fields.append(.broll) }
        return fields
    }

    public init(
        text: TextFieldDiff,
        notes: TextFieldDiff,
        broll: ItemListDiff<SceneItem>
    ) {
        self.text = text
        self.notes = notes
        self.broll = broll
    }

    public static func compute(old: SceneSnapshot, new: SceneSnapshot) -> SceneDiff {
        SceneDiff(
            text: textDiff(field: .text, old: old.text, new: new.text),
            notes: textDiff(field: .notes, old: old.notes, new: new.notes),
            broll: ItemListDiff.compute(old: old.broll, new: new.broll, id: \.id)
        )
    }

    private static func textDiff(field: Field, old: String, new: String) -> TextFieldDiff {
        let ops = old == new ? [] : WordDiff.diff(old: old, new: new)
        return TextFieldDiff(field: field, oldText: old, newText: new, ops: ops)
    }
}
