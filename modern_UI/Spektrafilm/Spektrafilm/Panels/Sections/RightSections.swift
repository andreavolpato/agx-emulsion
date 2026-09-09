//  RightSections.swift — the read-and-adjust column: Histogram, White
//  Balance, Exposure, Curve, Color Balance. All Layer 2 except the histogram,
//  which reads the adjusted image. Each is its own view; the panel lists them.

import SwiftUI

struct HistogramSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection("Histogram", key: "histogram", menu: { AnyView(EmptyView()) }) {
            VStack(spacing: 3) {
                HistogramPlot(bins: session.histogram, channels: [.rgb])
                    .frame(height: 64)
                HStack {
                    Text(session.exif?.iso ?? "")
                    Spacer()
                    Text(session.exif?.shutter ?? "")
                    Spacer()
                    Text(session.exif?.aperture ?? "")
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, Theme.Metric.wellInset + 4)
        }
    }
}

struct WhiteBalanceSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection("Print White Balance", key: "wb2", initiallyExpanded: false, menu: { AnyView(Button("Reset") {
            var a = session.adjustments; a.temperature = 0; a.tint = 0; session.adjustments = a }) }) {
            Well {
                VStack(spacing: 4) {
                    ScrubSlider(label: "Temp.", value: adj(\.temperature), range: -100...100, snap: 5,
                                format: { String(format: "%+.0f", $0) },
                                trackGradient: [Color(hex: 0x6E8FD8), Color(hex: 0xA9B4C4), Color(hex: 0xD9A45B)])
                    ScrubSlider(label: "Tint", value: adj(\.tint), range: -100...100, snap: 5,
                                format: { String(format: "%+.0f", $0) },
                                trackGradient: [Color(hex: 0x7CBF7C), Color(hex: 0xB4B4B4), Color(hex: 0xC97CC0)])
                    // The other white balance in this window is the decode
                    // block in Camera. This one is Layer 2, on the print
                    // (HANDOFF §6).
                    Text("Print — an adjustment on the scan.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func adj(_ kp: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { session.adjustments[keyPath: kp] }, set: { var a = session.adjustments; a[keyPath: kp] = $0; session.adjustments = a })
    }
}

struct ExposureSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection("Exposure", key: "exposure2", initiallyExpanded: false, menu: { AnyView(Button("Reset") {
            var a = session.adjustments
            a.exposure = 0; a.contrast = 0; a.brightness = 0; a.saturation = 0
            a.highlights = 0; a.shadows = 0; a.blackPoint = 0; a.whitePoint = 0
            session.adjustments = a }) }) {
            Well {
                VStack(spacing: 4) {
                    ScrubSlider(label: "Exposure", value: adj(\.exposure), range: -3...3, snap: 0.25, format: { String(format: "%+.2f", $0) })
                    ScrubSlider(label: "Contrast", value: adj(\.contrast), range: -50...50, snap: 5, format: { String(format: "%+.0f", $0) })
                    ScrubSlider(label: "Brightness", value: adj(\.brightness), range: -50...50, snap: 5, format: { String(format: "%+.0f", $0) })
                    ScrubSlider(label: "Saturation", value: adj(\.saturation), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                    Divider().overlay(Theme.dim.opacity(0.5)).padding(.vertical, 3)
                    ScrubSlider(label: "Highlights", value: adj(\.highlights), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                    ScrubSlider(label: "Shadows", value: adj(\.shadows), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                    ScrubSlider(label: "Black Point", value: adj(\.blackPoint), range: 0...50, snap: 1, format: { String(format: "%.0f", $0) })
                    ScrubSlider(label: "White Point", value: adj(\.whitePoint), range: 0...50, snap: 1, format: { String(format: "%.0f", $0) })
                }
            }
        }
    }
    private func adj(_ kp: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { session.adjustments[keyPath: kp] }, set: { var a = session.adjustments; a[keyPath: kp] = $0; session.adjustments = a })
    }
}

struct CurveSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection("Curve", key: "curve", menu: { AnyView(Button("Reset all channels") {
            var a = session.adjustments; a.curves = CurveSet(); session.adjustments = a }) }) {
            CurveEditor(session: session)
                .padding(.horizontal, Theme.Metric.wellInset + 4)
        }
    }
}

struct ColorBalanceSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection("Color Balance", key: "colorbalance", initiallyExpanded: false, menu: { AnyView(Button("Reset") {
            var a = session.adjustments; a.colorBalance = ColorBalance(); session.adjustments = a }) }) {
            ColorBalanceEditor(session: session)
                .padding(.horizontal, Theme.Metric.wellInset + 4)
        }
    }
}
