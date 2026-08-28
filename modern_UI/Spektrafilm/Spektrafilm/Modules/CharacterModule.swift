//  CharacterModule.swift — grain and halation.
//
//  The 100% button is not convenience. API-SPEC §4 measured both effects as
//  invisible at thumbnail scale (grain mean 0.011 / max 0.52; halation mean
//  0.017 / max 1.21) while genuinely present at full resolution. A toggle
//  whose effect cannot be seen at the current zoom reads as broken.
//
//  `io.scan_film` is deliberately absent. It changes what the artifact *is* —
//  a scanned negative rather than a print — so it is not a checkbox in a list.

import SwiftUI

@MainActor
enum CharacterModule {
    static let module = EditorModule(
        id: "character", title: "Character", systemImage: "circle.grid.cross",
        column: .left, layer: .physical,
        summary: { s in
            [s.flag("grain_active") ? "grain" : nil,
             s.flag("halation_active") ? "halation" : nil]
                .compactMap { $0 }.joined(separator: " · ").ifEmpty("off")
        },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Grain", isOn: session.flagBinding("grain_active"))
                Toggle("Halation", isOn: session.flagBinding("halation_active"))
                    .help("Highlight-driven. Needs a bright practical or a backlit "
                        + "edge in frame to be visible at all.")
                Button("Inspect at 100%") { session.zoomTo100() }
                    .controlSize(.small)
                    .help("Grain and halation are not legible below full resolution.")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
