//  EditorWindow.swift — the four cards on the ground, exactly as drawn:
//
//     ┌ left ┐  ┌───────── top bar ─────────┐  ┌ right ┐
//     │ 328  │  │          canvas           │  │  286  │
//     │      │  │                           │  │       │
//     │      │  └──────── filmstrip ────────┘  │       │
//     └──────┘                                 └───────┘
//
//  Outer margins 9/7 pt, gutters 8 pt, radius 15 pt. The side panels are
//  fixed width (the drawing's), so a wider window gives the canvas the extra
//  room and a narrower one takes it from the canvas — never from a panel.
//  Collapsing a card removes it from the HStack/VStack, so the canvas grows
//  into its place; the small tabs on the canvas edges bring it back.

import SwiftUI
import UniformTypeIdentifiers

struct EditorWindow: View {
    @Bindable var session: Session

    var body: some View {
        Group {
            if session.browsing && !session.frames.isEmpty {
                BrowseView(session: session)
                    .padding(.horizontal, Theme.Metric.outerX)
                    .padding(.vertical, Theme.Metric.outerY)
                    .transition(.opacity)
            } else {
                printLayout
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.browsing)
        .background(Theme.ground)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                }
                if !urls.isEmpty { session.open(urls: urls) }
            }
            return true
        }
        .sheet(isPresented: $session.showExport) { ExportSheet(session: session) }
    }

    /// The Print state: the four cards, exactly as drawn.
    private var printLayout: some View {
        HStack(spacing: Theme.Metric.gutter) {
            if !session.leftCollapsed {
                LeftPanel(session: session)
                    .frame(width: Theme.Metric.leftPanelWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: Theme.Metric.gutter) {
                if !session.topCollapsed {
                    TopBar(session: session).transition(.move(edge: .top).combined(with: .opacity))
                }
                CanvasArea(session: session)
                if !session.filmstripCollapsed {
                    Filmstrip(session: session)
                        .frame(height: Theme.Metric.filmstripHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.rightCollapsed {
                RightPanel(session: session)
                    .frame(width: Theme.Metric.rightPanelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Metric.outerX)
        .padding(.vertical, Theme.Metric.outerY)
        .transition(.opacity)
    }
}

/// The centre: the Metal view (or, in snapshot mode, an offscreen render of
/// it) with the four collapse tabs on its edges.
struct CanvasArea: View {
    @Bindable var session: Session
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        ZStack {
            if snapshotMode {
                SnapshotCanvas(session: session)
            } else {
                MetalCanvasView(host: session)
            }
            // Handles, thirds grid and the straighten line. The shader does
            // the dimming; this does the lines, which want to stay crisp.
            if session.tool == .crop && !snapshotMode {
                CropOverlay(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) { CollapseTab(edge: .leading, collapsed: $session.leftCollapsed) }
        .overlay(alignment: .trailing) { CollapseTab(edge: .trailing, collapsed: $session.rightCollapsed) }
        .overlay(alignment: .top) { CollapseTab(edge: .top, collapsed: $session.topCollapsed).padding(.top, 4) }
        .overlay(alignment: .bottom) { CollapseTab(edge: .bottom, collapsed: $session.filmstripCollapsed).padding(.bottom, 4) }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                // Space is a decode-vs-print comparison, and the spec's "show
                // original" was ambiguous about which; the label says which
                // (HANDOFF §6).
                if session.showingOriginal { badge("original · decode") }
                if session.detailPending {
                    badge(session.detailTier == .full ? "full resolution…" : "detail…")
                } else if session.detailTier != .live {
                    badge(session.detailTier == .full ? "full" : "detail")
                }
                if session.previewSoft && session.selection != nil { badge("preview") }
            }
            .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            if let w = session.stockWarning {
                Text(w).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(2)
                    .padding(6).background(Theme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).padding(8)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.card.opacity(0.8), in: Capsule())
    }
}

/// Snapshot stand-in: the renderer draws offscreen into an image at the
/// canvas's real size, so a capture shows the real render path.
struct SnapshotCanvas: View {
    @Bindable var session: Session
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image { Image(decorative: image, scale: 2).resizable() } else { Theme.ground }
            }
            .onChange(of: geo.size, initial: true) { _, size in render(size) }
            .onChange(of: session.previewSoft) { _, _ in render(geo.size) }
            .onChange(of: session.histogram) { _, _ in render(geo.size) }
            // The stand-in has to follow the same state the real canvas does,
            // or a capture of the detail tier shows the live tier.
            .onChange(of: session.zoomPercent) { _, _ in render(geo.size) }
            .onChange(of: session.detailTier) { _, _ in render(geo.size) }
            .onChange(of: session.detailPending) { _, _ in render(geo.size) }
        }
    }

    private func render(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        session.renderer.viewport.backingScale = 2
        session.renderer.viewport.resize(viewport: size)
        session.viewportChanged()
        image = session.renderer.renderOffscreen(size: size, backingScale: 2)?.makeCGImage()
    }
}

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotMode: Bool { get { self[SnapshotModeKey.self] } set { self[SnapshotModeKey.self] = newValue } }
}

/// The window's drag handle. `.windowStyle(.hiddenTitleBar)` removes the
/// titlebar a window is normally dragged by, and the strip reserved for the
/// traffic lights is SwiftUI content, which would otherwise eat the gesture.
/// `performDrag` hands it to the window server the way the real titlebar does.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}
