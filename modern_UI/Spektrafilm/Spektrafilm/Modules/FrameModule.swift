//  FrameModule.swift — what file this is. Right column, read-only.

import SwiftUI

@MainActor
enum FrameModule {
    static let module = EditorModule(
        id: "frame", title: "Frame", systemImage: "photo",
        column: .right, layer: .readout,
        summary: { $0.current?.url.lastPathComponent },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                if let frame = session.current {
                    KeyValue("File", frame.url.lastPathComponent)
                    if let d = session.decoded {
                        KeyValue("Size", "\(Int(d.pixelSize.width)) × \(Int(d.pixelSize.height))")
                        KeyValue("Pixels", String(format: "%.1f MP", d.megapixels))
                        // The service refuses above 60 MP, and a refusal
                        // after a 7 s decode is worse than a warning before.
                        if d.megapixels > 60 {
                            Label("Over the 60 MP service limit",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("No selection").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
