//  TopBar.swift — tools at the left, zoom at the right, exactly the design's
//  glyphs: select · hand · crop  ……  zoom-in · [100 %] · zoom-out · fit · fullscreen.

import SwiftUI

struct TopBar: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 0) {
            toolButton("cursorarrow", .select, "Select (V)").padding(.leading, 22)
            toolButton("hand.point.up.left", .hand, "Pan (H)").padding(.leading, 22)
            toolButton("crop", .crop, "Crop (C)").padding(.leading, 22)
            if session.working {
                ProgressView().controlSize(.small).scaleEffect(0.7).padding(.leading, 18)
            }
            Text(statusText).font(Theme.Font.caption).foregroundStyle(Theme.dim).lineLimit(1)
                .padding(.leading, 12)
            if !session.serviceReady, session.selection != nil {
                Button("Restart") { session.restartService() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    .padding(.leading, 8)
                    .help("The render service is not running. Start it again.")
            }
            Spacer(minLength: 8)
            if session.detailTier != .live {
                Text(session.detailTier == .full ? "full" : "detail")
                    .font(Theme.Font.caption)
                    .foregroundStyle(session.detailPending ? Theme.accent : Theme.dim)
                    .help("The canvas is rendering this frame at \(session.detailTier.rawValue) resolution because the zoom is past the live tier.")
            }
            iconButton("plus.magnifyingglass", "Zoom in (⌘+)") { session.zoomStep(1) }
            zoomPill.padding(.horizontal, 12)
            iconButton("minus.magnifyingglass", "Zoom out (⌘−)") { session.zoomStep(-1) }
            iconButton("arrow.down.right.and.arrow.up.left", "Fit (⌘0)") { session.zoomToFit() }.padding(.leading, 18)
            iconButton("arrow.up.left.and.arrow.down.right", "Full screen (⌃⌘F)") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .padding(.leading, 12)
                .padding(.trailing, 18)
        }
        .frame(height: Theme.Metric.topBarHeight)
        .panelCard()
    }

    private var statusText: String {
        // The service cannot report real progress: a render call does not
        // return until it is finished and the transport is single-flight, so
        // there is nothing to poll. Elapsed time is what is actually known.
        guard session.working else { return session.status }
        return String(format: "%@ · %.1f s", session.status, session.workSeconds)
    }

    private func toolButton(_ name: String, _ tool: CanvasTool, _ help: String) -> some View {
        Button { session.tool = tool } label: {
            Image(systemName: name)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .foregroundStyle(session.tool == tool ? Theme.text : Theme.text.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(session.tool == tool ? Theme.well.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var zoomPill: some View {
        Menu {
            Button("Fit") { session.zoomToFit() }
            ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { f in
                Button("\(Int(f * 100)) %") { session.zoomTo(fraction: f) }
            }
        } label: {
            // zoomPercent is 0 until an image is on the canvas.
            Text(session.zoomPercent == 0 ? "—"
                 : session.isFit ? "Fit · \(session.zoomPercent) %" : "\(session.zoomPercent) %")
                .font(Theme.Font.pill)
                .foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.zoomPill.width, height: Theme.Metric.zoomPill.height)
                .background(Theme.well, in: Capsule())
                .overlay(Capsule().stroke(Theme.text, lineWidth: 1))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
