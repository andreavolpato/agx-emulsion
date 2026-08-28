//  MasksModule.swift — one mask list serving both layers.
//
//  Each mask has a shape, a value in stops, and a target. `After print` is
//  Layer 2 and needs no service change; `Enlarger` is physically correct
//  dodging and burning and needs `exposure_mask` on `reprint`, which the
//  service does not have (frontend SPEC §1.5).
//
//  The mask geometry is identical either way — only the application point
//  changes — so shipping `After print` first wastes nothing.
//
//  Explicitly not: local contrast, local saturation, local anything else.
//  The justification for this tool is that it is what a printer's hands do
//  under the enlarger. Nothing else a brush could do has that justification.

import SwiftUI

@MainActor
enum MasksModule {
    static let module = EditorModule(
        id: "masks", title: "Masks", systemImage: "circle.dotted",
        column: .left, layer: .physical, defaultExpanded: false,
        summary: { _ in "none" },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        Button { } label: {
                            Image(systemName: tool.icon).frame(width: 24, height: 20)
                        }
                        .controlSize(.small)
                        .help(tool.help)
                    }
                    Spacer()
                }
                .disabled(true)
                Text("No masks")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }

        private enum Tool: CaseIterable {
            case linear, radial, brush, subject
            var icon: String {
                switch self {
                case .linear: "line.diagonal"
                case .radial: "circle"
                case .brush: "paintbrush.pointed"
                case .subject: "person.and.background.dotted"
                }
            }
            var help: String {
                switch self {
                case .linear: "Linear gradient"
                case .radial: "Radial gradient"
                case .brush: "Brush"
                case .subject: "Subject — Vision foreground instance mask"
                }
            }
        }
    }
}
