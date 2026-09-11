//  TopBar.swift — tools at the left, zoom at the right, exactly the design's
//  glyphs: select · hand · crop  ……  before/after · zoom-in · [100 %] ·
//  zoom-out · fit · fullscreen.
//
//  **Selection is orange, not grey.** A selected control tints the glyph
//  itself (`Theme.accent`) instead of putting a darker plate behind it. That
//  is Capture One's convention and it is the better one here for a specific
//  reason: this interface is almost entirely greys, so a grey-on-grey plate
//  reads as a rendering artefact at a glance and has to be looked *for*. The
//  one accent colour in the palette exists to be found without looking.

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
            // The empty middle of the bar is the window's drag surface: the
            // titlebar is hidden, and this is where a toolbar would be.
            WindowDragHandle().frame(minWidth: 8, maxWidth: .infinity)
            if session.detailTier != .live {
                Text(session.detailTier == .full ? "full" : "detail")
                    .font(Theme.Font.caption)
                    .foregroundStyle(session.detailPending ? Theme.accent : Theme.dim)
                    .help("The canvas is rendering this frame at \(session.detailTier.rawValue) resolution because the zoom is past the live tier.")
            }
            // Before/after, immediately left of the zoom controls — the
            // reference layout's position
            // (`reference_layout/before_and_after/`). It belongs with zoom
            // rather than with the tools because it changes how the canvas is
            // *displayed*, not what a click on it does.
            Button { session.comparing.toggle() } label: {
                BeforeAfterIcon(color: session.comparing ? Theme.accent : Theme.text)
                    .frame(width: 20, height: 16)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.canCompare)
            .opacity(session.canCompare ? 1 : 0.4)
            .help("Before / after split — drag the line on the canvas (⌥\\)")
            .padding(.trailing, 6)
            iconButton("plus.magnifyingglass", "Zoom in (⌘+)", disabled: session.zoomLocked) { session.zoomStep(1) }
            zoomPill.padding(.horizontal, 12)
                .disabled(session.zoomLocked)
                .opacity(session.zoomLocked ? 0.4 : 1)
            iconButton("minus.magnifyingglass", "Zoom out (⌘−)", disabled: session.zoomLocked) { session.zoomStep(-1) }
            iconButton("arrow.down.right.and.arrow.up.left", "Fit (⌘0)", disabled: session.zoomLocked) { session.zoomToFit() }.padding(.leading, 18)
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
                .foregroundStyle(session.tool == tool ? Theme.accent : Theme.text.opacity(0.55))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// `disabled` is for the controls the crop tool locks: greyed out, so the
    /// toolbar says *why* nothing happens, rather than a live-looking button
    /// that quietly does nothing (`Theme.text` at 0.4 is the same weight the
    /// before/after button uses when it has nothing to compare).
    private func iconButton(_ name: String, _ help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .foregroundStyle(disabled ? Theme.text.opacity(0.4) : Theme.text)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
