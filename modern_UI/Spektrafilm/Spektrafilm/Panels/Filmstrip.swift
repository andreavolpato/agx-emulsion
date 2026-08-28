//  Filmstrip.swift — the bottom strip.
//
//  Thumbnails come from the file's embedded preview via ImageIO, never from
//  the engine (UI-GUIDELINE §6). Browsing a folder must not cost a render:
//  `open` is 6.98 s at 45 MP, so an engine-backed strip would make a folder
//  unusable long before it made it informative.

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct Filmstrip: View {
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // Lazy so a 500-image folder does not build 500 views.
                LazyHStack(spacing: 8) {
                    ForEach(session.frames) { frame in
                        FilmstripCell(frame: frame,
                                      selected: frame.id == session.selection)
                            .id(frame.id)
                            .onTapGesture { session.selection = frame.id }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: session.selection) { _, new in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

struct FilmstripCell: View {
    let frame: Frame
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                if let cg = frame.thumbnail {
                    Image(decorative: cg, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                } else {
                    ProgressView().controlSize(.small)
                }
                // The three-state badge of frontend SPEC §5.1, bottom-right.
                // Not colour, not a banner, not desaturation — a dot, because
                // it has to be readable at 96 pt without competing with the
                // image it sits on.
                if frame.state != .unprocessed {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Circle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                                .background(Circle().fill(
                                    frame.state == .processed ? .white : .clear))
                                .frame(width: 5, height: 5)
                                .padding(3)
                                .shadow(radius: 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? AnyShapeStyle(Color.accentColor)
                                       : AnyShapeStyle(Theme.hairline),
                              lineWidth: selected ? 2 : 1))

            Text(frame.url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
        }
        .frame(width: 78)
        .task(id: frame.id) { await loadThumbnail() }
        .contextMenu {
            // Frontend SPEC §5.5. Copy/paste settings are offsets only:
            // because sliders are offsets from the solve, pasting offsets
            // means "same print recipe, each frame solves its own exposure",
            // which is what a lab does across a roll.
            Button("Open") {}
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([frame.url])
            }
            Divider()
            Button("Copy Settings") {}
            Button("Paste Settings") {}
            Button("Reset to Auto") {}
            Divider()
            Button("Export…") {}
        }
    }

    private func loadThumbnail() async {
        guard frame.thumbnail == nil else { return }
        let url = frame.url
        let cg = await Task.detached(priority: .utility) {
            ThumbnailCache.shared.thumbnail(for: url, maxEdge: 256)
        }.value
        await MainActor.run { frame.thumbnail = cg }
    }
}

/// NSCache keyed by path, per UI-GUIDELINE §6. Generation is off the main
/// actor; results are published back onto it.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    func thumbnail(for url: URL, maxEdge: Int) -> CGImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        cache.setObject(cg, forKey: key)
        return cg
    }
}
