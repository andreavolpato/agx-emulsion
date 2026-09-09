//  CameraSection.swift — Format, Vignetting, Exp. Comp., white balance.
//
//  Format → `film_format_mm` (shoot layer; changes grain scale).
//  Exp. Comp. → `exposure_compensation_ev`, an offset on the engine's own
//  auto-exposure, so zero is the solve.
//  Vignetting is client-side (Layer 2's lens-fall-off stage): the engine has
//  no vignette parameter. It sits here because that is where a photographer
//  looks for it, and the doc says so.

import SwiftUI

struct CameraSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Camera", systemImage: "camera", key: "camera", menu: { AnyView(menu) }) {
            Well {
                VStack(spacing: 4) {
                    PillMenu(label: "Format", options: FilmFormat.all, title: { $0.id },
                             selection: Binding(get: { FilmFormat.nearest(mm: session.params.filmFormatMM) },
                                                set: { var p = session.params; p.filmFormatMM = $0.mm; session.params = p }))
                    ScrubSlider(label: "Vignetting",
                                value: Binding(get: { session.adjustments.vignette.amount },
                                               set: { var a = session.adjustments; a.vignette.amount = $0; session.adjustments = a }),
                                range: -100...100, snap: 5, format: { String(format: "%.0f", $0) })
                    ScrubSlider(label: "Exp. Comp.", sublabel: session.solvedEVLabel,
                                value: Binding(get: { session.params.exposureCompensationEV },
                                               set: { var p = session.params; p.exposureCompensationEV = $0; session.params = p }),
                                range: -4...4, snap: 1 / 3, format: { String(format: "%+.1f", $0) })
                    Divider().overlay(Theme.dim.opacity(0.5)).padding(.vertical, 4)
                    WhiteBalanceBlock(session: session)
                }
            }
        }
    }

    private var menu: some View {
        Group {
            Button("Reset exposure") { var p = session.params; p.exposureCompensationEV = 0; session.params = p }
            Button("As Shot white balance") { session.setWhiteBalance(.asShot) }
        }
    }
}
