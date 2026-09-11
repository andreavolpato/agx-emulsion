//  CameraSection.swift — Tone, Format, Vignetting, Exp. Comp., white balance.
//
//  **Tone** → `auto_exposure_method` (RFC-015 §2.3): which of the four
//  exposure *intents* the engine's meter follows — overall correctness
//  (`balanced`), a subject in the middle (`center`), the brightest part kept
//  (`protect highlights`), the darkest part kept (`protect shadows`). It is an
//  intent rather than a meter pattern: the two protect modes are bounds on
//  `balanced`, so a frame with nothing at risk is metered exactly as
//  `balanced` would. A sidecar written before the field existed has no method
//  and keeps the engine's own `center_weighted`, which the pill names rather
//  than pretending to be one of the four.
//
//  **Exp. Comp.** → `exposure_compensation_ev`, and it is **film placement,
//  not print brightness**. The print gain is taken from a mid-grey exposed at
//  this offset (`printing.cpp`), so the print re-normalises what the slider
//  moves: measured on the smoke frame, a 4 EV sweep moves the mean print
//  luminance by 2.4 %, and *downward* — while the contrast rises. What it
//  really buys is where the scene sits on the film curve: grain, latitude,
//  saturation. The sublabel says what the meter chose, so this is an offset
//  from that.
//
//  **Format** → `film_format_mm` (shoot layer; changes grain scale).
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
                    PillMenu(label: "Tone",
                             options: ExposureMethod.allCases.map { Optional($0.rawValue) },
                             title: { ExposureMethod.title(forWire: $0) },
                             selection: Binding(get: { session.params.autoExposureMethod },
                                                set: { session.setAutoExposureMethod($0) }))
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
                    WhiteBalanceRows(session: session)
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
