import SwiftUI

/// The app's spacing and alignment system (design review, Nov 2026).
///
/// One 4 pt scale, one card recipe and one leading edge per column. New UI
/// should take its numbers from here instead of inventing local paddings;
/// `DesignAlignmentTests` asserts the column edges stay shared.
enum FrameSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum FrameRadius {
    /// Buttons, tabs, segmented items.
    static let control: CGFloat = 6
    /// Cards, callouts, list rows.
    static let card: CGFloat = 8
    /// Bars and grouped containers that hold controls (action bar, tab bar).
    static let container: CGFloat = 9
}

enum FrameControlHeight {
    /// Bar buttons, tabs, chips that carry text.
    static let compact: CGFloat = 26
    /// Toolbar icon buttons and sidebar actions.
    static let regular: CGFloat = 30
}

enum FrameLayout {
    /// Card padding shared by the inspector, AI callouts and empty states.
    static let cardPadding: CGFloat = FrameSpacing.m

    // MARK: Sidebar column

    /// Gap between the sidebar edge and a row's selection fill.
    static let sidebarOuterInset: CGFloat = 10
    /// Gap between a row's fill and its content.
    static let sidebarRowInset: CGFloat = 10
    /// Width of the icon / scene-number slot, so every title starts on the
    /// same x whether the row shows an SF Symbol or "01".
    static let sidebarLeadingSlot: CGFloat = 18
    static let sidebarSlotSpacing: CGFloat = 8
    /// x of every sidebar row's first glyph (icon, scene number, action label).
    static var sidebarContentLeading: CGFloat { sidebarOuterInset + sidebarRowInset }
    /// x of every sidebar title (Producción, Guion completo, scene titles).
    static var sidebarTitleLeading: CGFloat {
        sidebarContentLeading + sidebarLeadingSlot + sidebarSlotSpacing
    }

    // MARK: Inspector column

    /// Leading/trailing inset of the inspector header, tab bar and tab content.
    static let inspectorInset: CGFloat = 14

    // MARK: Script editor column

    /// Title → meta line.
    static let editorTitleToMeta: CGFloat = FrameSpacing.m
    /// Meta line → action bar.
    static let editorMetaToBar: CGFloat = FrameSpacing.l
    /// Action bar → script text.
    static let editorBarToText: CGFloat = FrameSpacing.xl
}
