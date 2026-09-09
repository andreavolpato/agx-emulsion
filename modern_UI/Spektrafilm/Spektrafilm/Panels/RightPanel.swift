//  RightPanel.swift — the Layer 2 column. The header's two glyphs are the
//  "adjustments" tab (always on — there is one tab) and the bypass switch:
//  the dotted circle shows the pure simulation while it is active.

import SwiftUI

struct RightPanel: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    HistogramSection(session: session)
                    WhiteBalanceSection(session: session)
                    ExposureSection(session: session)
                    CurveSection(session: session)
                    ColorBalanceSection(session: session)
                }
                .padding(.top, 4)
            }
        }
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .padding(.leading, 12)
            PanelIconButton(systemImage: session.adjustments.enabled ? "circle.dotted.circle" : "circle.dotted",
                            help: session.adjustments.enabled ? "Bypass adjustments (show the pure print)" : "Adjustments bypassed — click to enable",
                            active: !session.adjustments.enabled) {
                var a = session.adjustments; a.enabled.toggle(); session.adjustments = a
            }
            .padding(.leading, 10)
            Spacer()
            Menu {
                Button("Reset all adjustments") { session.resetAdjustments() }
            } label: {
                VerticalEllipsis().frame(width: 3, height: 15).padding(10).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 6)
        }
        .frame(height: 44)
    }
}
