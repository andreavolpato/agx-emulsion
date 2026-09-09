//  CollapseTab.swift — the small pill with a chevron that sits on each edge
//  of the canvas and folds the neighbouring card away.

import SwiftUI

struct CollapseTab: View {
    enum Edge { case leading, trailing, top, bottom }
    let edge: Edge
    @Binding var collapsed: Bool

    private var horizontal: Bool { edge == .top || edge == .bottom }
    private var glyph: String {
        switch (edge, collapsed) {
        case (.leading, false): "chevron.left"
        case (.leading, true): "chevron.right"
        case (.trailing, false): "chevron.right"
        case (.trailing, true): "chevron.left"
        case (.top, false): "chevron.up"
        case (.top, true): "chevron.down"
        case (.bottom, false): "chevron.down"
        case (.bottom, true): "chevron.up"
        }
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() } } label: {
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: horizontal ? Theme.Metric.tabLength : Theme.Metric.tabThickness,
                       height: horizontal ? Theme.Metric.tabThickness : Theme.Metric.tabLength)
                .background(Theme.card, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
