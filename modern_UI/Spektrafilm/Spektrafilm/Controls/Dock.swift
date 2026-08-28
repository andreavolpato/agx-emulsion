//  Dock.swift — a floating inspector column.
//
//  A rounded, material-backed card inset over the canvas rather than a pane
//  butted against the window edge. Two reasons, beyond taste: the canvas
//  stays full-bleed underneath so the image is never boxed in by the layout
//  (frontend SPEC §5.0), and the material reads as floating without a border
//  heavy enough to compete with the image — which is the treatment Photos'
//  edit mode and Final Cut's inspector use, and what the SPEC asks for when
//  it says "the material blur alone reads as floating and does not fight the
//  image".
//
//  The dock renders whatever `ModuleRegistry` lists for its column and knows
//  nothing about any individual module.

import SwiftUI

struct Dock: View {
    let column: DockColumn
    @Environment(Session.self) private var session

    private var modules: [EditorModule] { ModuleRegistry.modules(in: column) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                    // The layer boundary is drawn by the dock, once, where the
                    // declared layer changes — not by each module. A module
                    // cannot accidentally omit it or draw a second one.
                    if index > 0, modules[index - 1].layer != module.layer {
                        LayerRule(from: modules[index - 1].layer, to: module.layer)
                    } else if index > 0 {
                        Divider().overlay(Theme.hairline)
                    }
                    DockSection(module: module, session: session)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.dockRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.dockRadius)
                .strokeBorder(Theme.dockStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }
}

/// One collapsible module. Expansion persists per module id.
private struct DockSection: View {
    let module: EditorModule
    let session: Session
    @AppStorage private var expanded: Bool

    init(module: EditorModule, session: Session) {
        self.module = module
        self.session = session
        _expanded = AppStorage(wrappedValue: module.defaultExpanded, "dock.\(module.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                module.content(session)
                    .padding(.horizontal, Theme.dockPad)
                    .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: module.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            Text(module.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if !expanded, let summary = module.summary(session) {
                Text(summary)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let accessory = module.accessory(session) { accessory }
        }
        .padding(.horizontal, Theme.dockPad)
        .frame(height: 30)
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        }
    }
}

/// The boundary between the two editing layers. Frontend SPEC §3.1 rule 1:
/// at no point should it be unclear which layer a control belongs to.
private struct LayerRule: View {
    let from: EditLayer
    let to: EditLayer

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.horizontal, Theme.dockPad)
        .padding(.vertical, 8)
    }

    private var label: String {
        switch to {
        case .adjustment: "after the print"
        case .readout: "readout"
        case .physical: "simulation"
        }
    }
}
