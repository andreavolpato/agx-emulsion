//  FeaturesSection.swift — Grain, Halation, Glare: three engine toggles.
//  Grain and halation are shoot-layer (film side); glare is print-layer.

import SwiftUI

struct FeaturesSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Features", systemImage: "sparkles", key: "features", menu: { AnyView(menu) }) {
            Well {
                VStack(spacing: 0) {
                    ToggleRow(label: "Grain", isOn: Binding(get: { session.params.grainActive },
                                                             set: { var p = session.params; p.grainActive = $0; session.params = p }))
                    ToggleRow(label: "Halation", isOn: Binding(get: { session.params.halationActive },
                                                                set: { var p = session.params; p.halationActive = $0; session.params = p }))
                    ToggleRow(label: "Glare", isOn: Binding(get: { session.params.glareActive },
                                                             set: { var p = session.params; p.glareActive = $0; session.params = p }))
                }
            }
        }
    }

    private var menu: some View {
        Group {
            Button("All on") { var p = session.params; p.grainActive = true; p.halationActive = true; p.glareActive = true; session.params = p }
            Button("All off") { var p = session.params; p.grainActive = false; p.halationActive = false; p.glareActive = false; session.params = p }
        }
    }
}
