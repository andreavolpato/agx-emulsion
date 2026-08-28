//  DecodeModule.swift — how the file was decoded. Right column, read-only.
//
//  This exists because colour failures in this pipeline are silent. RFC-010's
//  rule is that the API says what it *inferred* and how; the same obligation
//  applies to the client's own decode. Two decoders are in play and they do
//  not agree — Core Image here, rawpy/LibRaw in the service (`raw_engine:
//  "dcraw"`). Different demosaic, different camera matrices, different
//  highlight recovery. So the decoder is named, never implied.

import SwiftUI

@MainActor
enum DecodeModule {
    static let module = EditorModule(
        id: "decode", title: "Decode", systemImage: "camera.aperture",
        column: .right, layer: .readout,
        summary: { $0.decoded?.decoder.rawValue },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                if let d = session.decoded {
                    KeyValue("Decoder", d.decoder.label)
                    KeyValue("Space", colorSpaceName(d.workingSpace))
                    KeyValue("Transfer", d.isLinear ? "Linear" : "Encoded")
                    KeyValue("Canvas", "Display P3")
                    if let ms = session.renderer?.lastUploadMs {
                        KeyValue("Upload", String(format: "%.0f ms", ms))
                    }
                } else {
                    Text("Nothing decoded").font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                KeyValue("Service", "Not connected")
            }
        }

        /// Trimmed for display only. The sidecar records the raw name.
        private func colorSpaceName(_ space: CGColorSpace) -> String {
            guard let name = space.name else { return "Linear ProPhoto" }
            return (name as String).replacingOccurrences(of: "kCGColorSpace", with: "")
        }
    }
}
