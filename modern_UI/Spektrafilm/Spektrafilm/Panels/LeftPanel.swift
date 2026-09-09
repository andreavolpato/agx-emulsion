//  LeftPanel.swift — the Layer 1 column: import/export, then the five
//  sections in the design's order. To add a section: write a view in
//  Panels/Sections and add one line to `sections`. Nothing else changes.

import SwiftUI

struct LeftPanel: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    FilmProfileSection(session: session)
                    PrintProfileSection(session: session)
                    CameraSection(session: session)
                    CropSection(session: session)
                    FeaturesSection(session: session)
                    EnlargerSection(session: session)
                }
                .padding(.top, 4)
            }
        }
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            // The window's three buttons are aligned to *this row's*
            // centreline rather than left where AppKit floats them, which is
            // 13 pt higher (Windows/TrafficLights.swift). The leading inset
            // then follows from where the row ends. Every other card keeps
            // the drawing's 12 pt.
            PanelIconButton(systemImage: "square.and.arrow.down", help: "Open a folder or image (⌘O)") { session.openPanel() }
                .padding(.leading, Theme.Metric.panelHeaderLeading)
            PanelIconButton(systemImage: "square.and.arrow.up", help: "Export (⌘E)") { session.showExport = true }
                .padding(.leading, 12)
                .disabled(session.selection == nil)
            Spacer()
            Menu {
                Button("Reset Layer 1 (film, paper, camera, enlarger)") { session.resetParams() }
                Button("Reset Layer 2 (adjustments)") { session.resetAdjustments() }
                Divider()
                Button("Reveal sidecar in Finder") {
                    if let u = session.selection { NSWorkspace.shared.activateFileViewerSelecting([Sidecar.url(for: u)]) }
                }
            } label: {
                VerticalEllipsis().frame(width: 3, height: 15).padding(10).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 6)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The header row is the window's drag surface here, as a sidebar
        // header is in Xcode. The buttons sit above it and keep their clicks.
        .background(WindowDragHandle())
        .background(
            TrafficLightAlignment(centreY: Theme.Metric.trafficLightCentreY,
                                  leading: Theme.Metric.trafficLightLeading)
                .frame(width: 0, height: 0)
        )
    }
}

struct PanelIconButton: View {
    let systemImage: String
    var help: String = ""
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct VerticalEllipsis: View {
    var body: some View {
        VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.text).frame(width: 3, height: 3) } }
    }
}

extension View {
    /// One of the four floating cards.
    func panelCard() -> some View {
        self.background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
    }
}
