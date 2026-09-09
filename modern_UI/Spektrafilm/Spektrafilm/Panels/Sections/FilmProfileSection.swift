//  FilmProfileSection.swift — the film list with cover art. The selected
//  film carries the white frame (that is the selection mark, per the design).

import SwiftUI

struct FilmProfileSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Film Profile", systemImage: "list.and.film", key: "film", menu: { AnyView(menu) }) {
            Well(padding: 6, vertical: 6) {
                ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(session.catalog.filmsForPicker) { film in
                        FilmRow(film: film, selected: film.id == session.params.filmStock) {
                            var p = session.params; p.filmStock = film.id
                            if let target = film.targetPrint, session.catalog.stock(target) != nil,
                               !session.catalog.isDeclaredPairing(film: p.filmStock, paper: p.printStock) {
                                p.printStock = target   // follow the declared pairing
                            }
                            session.params = p
                        }
                        .id(film.id)
                    }
                }
                }
                .frame(height: Theme.Metric.listRowHeight * 7)
                .onAppear { proxy.scrollTo(session.params.filmStock, anchor: .center) }
                .onChange(of: session.params.filmStock) { _, new in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
        }
    }

    private var menu: some View {
        Group {
            Button("Reset to Portra 400") { var p = session.params; p.filmStock = "kodak_portra_400"; session.params = p }
        }
    }
}

struct FilmRow: View {
    let film: Stock
    let selected: Bool
    let action: () -> Void
    @State private var cover: NSImage? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(brandColor)
                    if let cover { Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill) }
                    else { Text(film.brand.prefix(1)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8)) }
                }
                .frame(width: Theme.Metric.filmCover, height: Theme.Metric.filmCover)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                Text(film.name).font(Theme.Font.listItem).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if film.isCine {
                    Text("CINE").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Theme.Metric.listRowHeight)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.selectionFrame, lineWidth: selected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: film.id) {
            guard let url = film.coverURL else { cover = nil; return }
            cover = NSImage(contentsOf: url)
        }
    }

    private var brandColor: Color {
        switch film.brand.lowercased() {
        case "kodak": Color(hex: 0xC8A128)
        case "fujifilm": Color(hex: 0x2E8B57)
        default: Theme.dim
        }
    }
}
