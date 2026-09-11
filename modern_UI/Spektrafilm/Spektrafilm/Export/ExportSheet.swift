//  ExportSheet.swift — one sheet, four routes.

import SwiftUI

struct ExportSheet: View {
    @Bindable var session: Session
    @State private var format: ExportFormat = .jpeg
    @State private var running = false
    @State private var result: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.system(size: 15, weight: .semibold))
            Picker("Format", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(format.note).font(Theme.Font.sublabel).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let sel = session.selection {
                Text("→ \(Exporter.destination(for: sel, params: session.params, format: format).path)")
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            if format == .di {
                Text("Photoshop: open the TIFF, add a Color Lookup adjustment layer, load the .cube. Capture One cannot load .cube; convert it to an ICC (see docs).")
                    .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let result { Text(result).font(Theme.Font.sublabel).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(running ? "Exporting…" : "Export") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || session.selection == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func run() {
        running = true
        result = nil
        Task {
            defer { running = false }
            do {
                guard let sid = await session.currentServiceSession() else { result = "The frame is still developing."; return }
                session.exportProgress = 0
                let r = try await Exporter.export(session: session, format: format, sessionID: sid)
                session.exportProgress = nil
                result = "Wrote " + r.urls.map(\.lastPathComponent).joined(separator: ", ") + (r.note.map { "\n\($0)" } ?? "")
                NSWorkspace.shared.activateFileViewerSelecting(r.urls)
            } catch {
                session.exportProgress = nil
                result = EngineMessage.userFacing(error)
            }
        }
    }
}
