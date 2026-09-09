//  Filmstrip.swift — the library. Thumbnails at one height, a white frame on
//  the selected frame, a three-state badge bottom-right (nothing / filled
//  dot / hollow dot: unprocessed / processed / stale), chevrons at both
//  ends, and the folder name with a count at the far left when there is room.
//
//  `LazyHStack` so a 500-image folder builds only what is visible; thumbnails
//  come from ImageIO off the main actor and are replaced by the rendered print
//  once a frame has been through the engine.

import SwiftUI

struct Filmstrip: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 0) {
            edgeButton("chevron.left") { session.selectRelative(-1) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(session.frames) { frame in
                            FilmstripCell(frame: frame,
                                          selected: frame.id == session.selection,
                                          state: session.frameStates[frame.id] ?? .unprocessed)
                                .id(frame.id)
                                .onTapGesture { session.select(frame.id) }
                                .contextMenu {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([frame.id]) }
                                    Button("Reset to defaults") {
                                        if frame.id == session.selection { session.resetParams(); session.resetAdjustments() }
                                        else { Sidecar.remove(for: frame.id) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Metric.filmstripHeight)
                }
                .onChange(of: session.selection) { _, new in
                    if let new { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            edgeButton("chevron.right") { session.selectRelative(1) }
        }
        .overlay(alignment: .center) {
            // Always in the tree, hidden by opacity. As a `if
            // frames.isEmpty { … }` inside an overlay builder it was observed
            // still on screen next to a loaded thumbnail: the branch had been
            // taken when the strip was empty and was not re-evaluated when it
            // filled. Opacity depends on the same value every pass, so it
            // cannot go stale.
            Text("Drop a folder or images here, or press ⌘O.")
                .font(Theme.Font.label).foregroundStyle(Theme.dim)
                .opacity(session.frames.isEmpty ? 1 : 0)
                .allowsHitTesting(false)
        }
        .panelCard()
    }

    private func edgeButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 18, height: Theme.Metric.filmstripHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.frames.isEmpty)
    }
}

struct FilmstripCell: View {
    let frame: Frame
    let selected: Bool
    let state: FrameState
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                }
            }
            .frame(height: Theme.Metric.thumbHeight)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.selectionFrame, lineWidth: selected ? 1.5 : 0))
            badge.padding(4)
        }
        .help(frame.name)
        .task(id: frame.id) {
            image = await ThumbnailCache.shared.thumbnail(for: frame.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
            guard (n.object as? URL) == frame.id else { return }
            Task { image = await ThumbnailCache.shared.thumbnail(for: frame.id) }
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .unprocessed: EmptyView()
        case .processed: Circle().fill(Theme.text).frame(width: 6, height: 6).shadow(radius: 1)
        case .stale: Circle().stroke(Theme.text, lineWidth: 1.2).frame(width: 6, height: 6).shadow(radius: 1)
        }
    }
}
