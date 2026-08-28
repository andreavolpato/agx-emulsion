//  EditorWindow.swift — the window's structure.
//
//  ┌──────────────────────────────────────────────┐
//  │ toolbar                          full width  │
//  ├──────────────────────────────────────────────┤
//  │  ╭────────╮                     ╭─────────╮  │
//  │  │ dock   │      canvas         │  dock   │  │   docks float over a
//  │  ╰────────╯    (full bleed)     ╰─────────╯  │   full-bleed canvas
//  ├──────────────────────────────────────────────┤
//  │ filmstrip + status               full width  │
//  └──────────────────────────────────────────────┘
//
//  The bars span the window; the docks do not touch them. Two consequences
//  worth stating, because the previous arrangement got both wrong:
//
//  - Nothing "overflows" anything. A full-width bar under a full-height pane
//    reads as a mistake; a full-width bar under a floating card reads as a
//    bar. The docks are inset on all four sides, so the boundary is explicit.
//  - The canvas is genuinely full-bleed and is never sized by the layout
//    (frontend SPEC §5.0). Collapsing a dock reveals more image rather than
//    resizing it, so a pan or zoom does not shift under a panel toggle.

import SwiftUI

struct EditorWindow: View {
    @Environment(Session.self) private var session
    @AppStorage("leftWidth")  private var leftWidth  = Theme.leftWidthDefault
    @AppStorage("rightWidth") private var rightWidth = Theme.rightWidthDefault
    @AppStorage("stripHeight") private var stripHeight = Theme.stripHeightDefault

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            ZStack {
                CanvasArea()
                docks
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            BottomBar(stripHeight: $stripHeight)
        }
        .background(Theme.canvasVoid)
        .toolbar { toolbar }
        .navigationTitle(session.folder?.lastPathComponent ?? "Spektrafilm")
        .navigationSubtitle(session.current?.url.lastPathComponent ?? "")
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    // MARK: - docks

    private var docks: some View {
        @Bindable var session = session
        return HStack(spacing: 0) {
            if !session.leftCollapsed {
                Dock(column: .left)
                    .frame(width: leftWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ResizeHandle(size: $leftWidth, range: Theme.leftRange, edge: .leading)
            }
            Spacer(minLength: 0)
            if !session.rightCollapsed {
                ResizeHandle(size: $rightWidth, range: Theme.rightRange, edge: .trailing)
                Dock(column: .right)
                    .frame(width: rightWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(Theme.dockInset)
        // The docks are chrome over the image. Without this, the Spacer
        // between them would swallow clicks and drags meant for the canvas.
        .allowsHitTesting(true)
    }

    // MARK: - toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { session.leftCollapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Hide or show the tools")
        }
        ToolbarItemGroup(placement: .principal) {
            ZoomControl()
            Divider()
            FidelityBadge(fidelity: session.fidelity)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { session.rightCollapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Hide or show the inspector")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in session.open(url) }
        }
        return true
    }
}

// MARK: - resize handle

/// A hit target with no visual weight of its own.
///
/// The docks already have edges; a drawn divider beside one would be a second
/// edge. The cursor change is the affordance, which is how the sidebars in
/// Xcode and Finder behave too.
private struct ResizeHandle: View {
    @Binding var size: Double
    let range: ClosedRange<Double>
    let edge: HorizontalEdge

    /// Captured on drag begin: `translation` is measured from the gesture
    /// origin, not from the last event, so accumulating it drifts.
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 10)
            .contentShape(.rect)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let base = start ?? size
                        if start == nil { start = size }
                        let delta = edge == .leading ? g.translation.width : -g.translation.width
                        size = (base + delta).clamped(to: range)
                    }
                    .onEnded { _ in start = nil }
            )
            // No implicit animation: any animation on `size` makes the handle
            // lag the cursor.
            .animation(nil, value: size)
    }
}

// MARK: - toolbar pieces

private struct ZoomControl: View {
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 2) {
            Button { session.zoomOut() } label: { Image(systemName: "minus") }
                .help("Zoom out")
            Text(session.fitToWindow ? "Fit" : String(format: "%.0f%%", session.zoom * 100))
                .font(.system(size: 11)).monospacedDigit()
                .frame(width: 42)
                .foregroundStyle(.secondary)
            Button { session.zoomIn() } label: { Image(systemName: "plus") }
                .help("Zoom in")
        }
    }
}

/// Frontend SPEC §4's badge. Not decoration: the GPU path skips
/// `scanning.glare`, which is spatial and stochastic and cannot live in a
/// pointwise LUT. This says which one is on screen.
struct FidelityBadge: View {
    let fidelity: CanvasFidelity

    var body: some View {
        Text(fidelity.caption)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(fidelity == .exact ? .primary : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .help(fidelity.detail)
    }
}

// MARK: - bottom bar

private struct BottomBar: View {
    @Environment(Session.self) private var session
    @Binding var stripHeight: Double
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            if !session.stripCollapsed {
                Color.clear.frame(height: 5)
                    .contentShape(.rect)
                    .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let base = dragStart ?? stripHeight
                                if dragStart == nil { dragStart = stripHeight }
                                stripHeight = (base - g.translation.height)
                                    .clamped(to: Theme.stripRange)
                            }
                            .onEnded { _ in dragStart = nil })
                Filmstrip().frame(height: stripHeight)
                Divider()
            }
            StatusLine()
        }
        .background(.bar)
    }
}

private struct StatusLine: View {
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            if let error = session.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.orange).lineLimit(1)
            } else {
                Text(session.status).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let busy = session.busy {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
                Text(busy.label).foregroundStyle(.secondary)
            }
            if !session.frames.isEmpty, let current = session.current,
               let index = session.frames.firstIndex(where: { $0.id == current.id }) {
                Text("\(index + 1) / \(session.frames.count)")
                    .foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}
