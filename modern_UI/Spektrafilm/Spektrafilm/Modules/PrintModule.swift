//  PrintModule.swift — the three enlarger controls, and the solve.
//
//  These are the sliders actually dragged, and all three are `LIVE_MUTABLE`
//  on the service — writable onto a live pipeline without rebuilding it, which
//  is what makes the ~193 ms reprint the primary interaction (API-SPEC §6).
//
//  Two labelling decisions that are not cosmetic:
//
//  - Exposure is labelled by what it does to the print. The paper convention
//    inverts — less enlarger exposure prints brighter — and the UI should not
//    make the user hold that in their head (frontend SPEC §5.2).
//  - The filter shifts are labelled by their actual filter axes. Not "hue",
//    not "temperature". Colour is produced by the spectral dye simulation,
//    not graded, so a generic HSV control would be the same category of
//    dishonesty as the gain/temp/tint non-goal (API-SPEC §4).

import SwiftUI

@MainActor
enum PrintModule {
    static let module = EditorModule(
        id: "print", title: "Print", systemImage: "lamp.desk",
        column: .left, layer: .physical,
        summary: { String(format: "%.2f", $0.number("print_exposure")) },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ScrubSlider(label: "Exposure",
                            value: session.numberBinding("print_exposure"),
                            range: Schema.range(of: "print_exposure") ?? 0.05...20,
                            zero: 1.0, decimals: 2,
                            onCommit: { session.commit("print_exposure") })
                    .help("Enlarger exposure. Less exposure prints brighter.")

                ScrubSlider(label: "Yellow – Blue",
                            value: session.numberBinding("y_filter_shift"),
                            range: -1...1, zero: 0, showsOffset: true, decimals: 3,
                            tint: Theme.yellowBlue,
                            onCommit: { session.commit("y_filter_shift") })

                ScrubSlider(label: "Magenta – Green",
                            value: session.numberBinding("m_filter_shift"),
                            range: -1...1, zero: 0, showsOffset: true, decimals: 3,
                            tint: Theme.magentaGreen,
                            onCommit: { session.commit("m_filter_shift") })

                solve
            }
        }

        /// The solve, shown rather than hidden. PRD §0's model is that the
        /// sliders exist to *override* the solve, which only means anything
        /// if the solve is legible — and it is what the zero tick points at.
        private var solve: some View {
            HStack(spacing: 6) {
                Button("Auto") { session.status = "solve" }
                    .controlSize(.small)
                Spacer()
                if let s = session.solve {
                    Text(String(format: "%+.2f EV · M%.0f Y%.0f",
                                s.exposureCompensationEV ?? 0,
                                s.mFilterNeutral ?? 0, s.yFilterNeutral ?? 0))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
