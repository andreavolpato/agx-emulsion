//  AdjustmentsModule.swift — Layer 2.
//
//  Operates on the print output as if it were a scan of a print, which is
//  what it is (frontend SPEC §3.1). Lives entirely in the client, runs in the
//  shader already compositing the canvas, needs no service call.
//
//  Headroom is the scan-normalisation margin between the paper's Dmin/Dmax
//  and 0/1 — roughly ⅓–⅔ stop each end. The paper's toe and shoulder are
//  irreversible, so large tonal moves belong to print exposure, above the
//  rule. The slider ranges here are set to that reality rather than to a
//  round number.

import SwiftUI

@MainActor
enum AdjustmentsModule {
    static let module = EditorModule(
        id: "adjustments", title: "Adjustments", systemImage: "slider.horizontal.3",
        column: .left, layer: .adjustment,
        summary: { $0.adjustments.isNeutral ? "zero" : "edited" },
        // The bypass switch of frontend SPEC §3.1 rule 2 — the only way to
        // tell, later, whether a look came from the stock or from a curve,
        // and the stable reference for judging engine changes.
        accessory: { AnyView(BypassSwitch(session: $0)) },
        content: { AnyView(Body(session: $0)) })

    private struct BypassSwitch: View {
        @Bindable var session: Session
        var body: some View {
            Toggle("", isOn: $session.adjustmentsBypassed.inverted)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help("Bypass — show the unmodified simulation")
        }
    }

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ScrubSlider(label: "Exposure", value: $session.adjustments.exposure,
                            range: -3...3, zero: 0, showsOffset: true,
                            unit: "EV", decimals: 2)
                ScrubSlider(label: "Highlights", value: $session.adjustments.highlights,
                            range: -1...1, zero: 0, showsOffset: true, decimals: 2)
                ScrubSlider(label: "Shadows", value: $session.adjustments.shadows,
                            range: -1...1, zero: 0, showsOffset: true, decimals: 2)
                ScrubSlider(label: "Black", value: $session.adjustments.blackPoint,
                            range: -0.1...0.1, zero: 0, showsOffset: true, decimals: 3)
                ScrubSlider(label: "White", value: $session.adjustments.whitePoint,
                            range: -0.1...0.1, zero: 0, showsOffset: true, decimals: 3)

                HStack {
                    Button("Reset") { session.adjustments.reset() }
                        .controlSize(.small)
                        .disabled(session.adjustments.isNeutral)
                    Spacer()
                }
            }
            .opacity(session.adjustmentsBypassed ? 0.4 : 1)
            .disabled(session.adjustmentsBypassed)
        }
    }
}


extension Binding where Value == Bool {
    /// A toggle that reads "on = enabled" over a stored "bypassed" flag.
    /// The stored sense is the honest one — bypass is the exception — but a
    /// switch that turns *off* to enable reads backwards.
    var inverted: Binding<Bool> {
        Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}
