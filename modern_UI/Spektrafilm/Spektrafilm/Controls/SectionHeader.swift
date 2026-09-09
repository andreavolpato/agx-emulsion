//  SectionHeader.swift — disclosure triangle, glyph, title, "•••" — the row
//  every section in both panels starts with, and the well under it.

import SwiftUI

struct SectionHeader: View {
    let title: String
    var systemImage: String? = nil
    @Binding var expanded: Bool
    var menu: (() -> AnyView)? = nil

    var body: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Triangle()
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    .frame(width: Theme.Metric.disclosure.width, height: Theme.Metric.disclosure.height)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: Theme.Metric.sectionIcon + 4, height: Theme.Metric.sectionIcon)
                    .padding(.leading, 8)
            }
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.text)
                .padding(.leading, 10)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let menu {
                Menu { menu() } label: {
                    EllipsisGlyph().frame(width: 15, height: 3).padding(8).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                EllipsisGlyph().frame(width: 15, height: 3).padding(8)
            }
        }
        .frame(height: Theme.Metric.headerHeight)
        .padding(.horizontal, Theme.Metric.wellInset)
        .contentShape(Rectangle())
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct EllipsisGlyph: View {
    var body: some View {
        HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.text).frame(width: 3, height: 3) } }
    }
}

/// The rounded well every section's content sits in.
struct Well<Content: View>: View {
    var padding: CGFloat = Theme.Metric.wellPadding
    var vertical: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, padding)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Metric.wellRadius, style: .continuous))
            .padding(.horizontal, Theme.Metric.wellInset)
    }
}

/// A section: header + collapsible well. `expanded` persists per key.
struct PanelSection<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    let key: String
    var initiallyExpanded = true
    var menu: (() -> AnyView)? = nil
    @ViewBuilder var content: () -> Content
    @AppStorage private var expanded: Bool

    init(_ title: String, systemImage: String? = nil, key: String, initiallyExpanded: Bool = true,
         menu: (() -> AnyView)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.systemImage = systemImage; self.key = key
        self.initiallyExpanded = initiallyExpanded; self.menu = menu; self.content = content
        _expanded = AppStorage(wrappedValue: initiallyExpanded, Session.uiKey + "section.\(key)")
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: title, systemImage: systemImage, expanded: $expanded, menu: menu)
            if expanded {
                content().padding(.top, Theme.Metric.headerToWell)
            }
        }
        .padding(.bottom, Theme.Metric.wellToHeader)
    }
}
