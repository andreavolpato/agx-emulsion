//  ScopeModule.swift — the two characteristic curves. Read-only.
//
//  Frontend SPEC §5.2 item 5. An editable curve here would be the same
//  category error as a hue slider — this is the one place in the interface
//  that explains *why* the highlight rolloff looks the way it does, which is
//  the difference between this and a filter.
//
//  Curve data comes from the profile JSON (CC BY-SA, in-repo, no RPC).
//  Histograms come from the live negative via MPSImageHistogram on the GPU.
//  Neither is wired yet; the geometry below settles the layout.

import SwiftUI

@MainActor
enum ScopeModule {
    static let module = EditorModule(
        id: "scope", title: "Scope", systemImage: "chart.xyaxis.line",
        column: .right, layer: .readout, defaultExpanded: false,
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                CurveView(kind: .film)
                CurveView(kind: .paper)
            }
        }
    }
}
