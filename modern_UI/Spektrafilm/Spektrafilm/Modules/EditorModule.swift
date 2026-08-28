//  EditorModule.swift — the plug-in contract for everything in a dock.
//
//  Every editing surface (stock, print, character, adjustments, …) is one
//  module, in one file, that knows nothing about any other module. A module
//  declares where it wants to live and hands back a view; the dock renders
//  whatever the registry lists, in order.
//
//  What this buys, concretely:
//
//  - **Adding a surface** is a new file plus one line in `ModuleRegistry`.
//  - **Removing one** is deleting that line. Nothing else references it.
//  - **Reordering** is moving the line.
//  - **Replacing one** — a different curve editor, a different stock picker —
//    is swapping which type contributes the descriptor. Call sites don't move.
//
//  The rule that keeps this true: a module may read and write `Session`, and
//  may use anything in `Controls/`. A module must never import, reference, or
//  assume the presence of another module. If two modules need to agree on
//  something, that something belongs in `Session`.

import SwiftUI

/// Which side of the window a module docks to.
enum DockColumn: String, Sendable { case left, right }

/// Which of the two editing layers a module belongs to.
///
/// This is the structural distinction of frontend SPEC §3.1, and the dock
/// draws a rule between the groups rather than each module drawing its own.
/// A module declares its layer; it does not decide how the boundary is drawn.
enum EditLayer: Int, Sendable, Comparable {
    /// The physical simulation. Nothing may be inserted here that is not
    /// physically part of a darkroom.
    case physical = 0
    /// Ordinary editing, on the print output, treated as a scan of a print.
    case adjustment = 1
    /// Read-only reporting. Never between the two above.
    case readout = 2

    static func < (a: EditLayer, b: EditLayer) -> Bool { a.rawValue < b.rawValue }
}

/// `@MainActor` because a descriptor closes over view construction and
/// reads `Session`, both of which are main-actor bound.
@MainActor
struct EditorModule: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let column: DockColumn
    let layer: EditLayer
    var defaultExpanded = true
    /// One short line shown in the header when the section is collapsed.
    /// Keep it to a value, not a sentence.
    var summary: (Session) -> String? = { _ in nil }
    /// An optional control in the header itself — a bypass switch, a reset.
    var accessory: (Session) -> AnyView? = { _ in nil }
    let content: (Session) -> AnyView
}

/// The one list. Order here is order on screen.
@MainActor
enum ModuleRegistry {
    static let all: [EditorModule] = [
        StockModule.module,
        PrintModule.module,
        MasksModule.module,
        CharacterModule.module,
        AdjustmentsModule.module,

        FrameModule.module,
        DecodeModule.module,
        ScopeModule.module,
    ]

    static func modules(in column: DockColumn) -> [EditorModule] {
        all.filter { $0.column == column }
    }
}
