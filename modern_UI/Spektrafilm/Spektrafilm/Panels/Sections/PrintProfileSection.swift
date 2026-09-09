//  PrintProfileSection.swift — the paper list, grouped Still / Cine, with the
//  white frame on the selected paper.

import SwiftUI

struct PrintProfileSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Print Profile", systemImage: "doc", key: "print", menu: { AnyView(menu) }) {
            Well(padding: 6, vertical: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.catalog.paperGroups, id: \.title) { group in
                        Text(group.title).font(Theme.Font.groupHeader).foregroundStyle(Theme.text)
                            .padding(.leading, 10).frame(height: 18)
                        ForEach(group.papers) { paper in
                            let declared = session.catalog.isDeclaredPairing(film: session.params.filmStock, paper: paper.id)
                            Button {
                                var p = session.params; p.printStock = paper.id; session.params = p
                            } label: {
                                HStack(spacing: 6) {
                                    Text(paper.name).font(Theme.Font.listItem).foregroundStyle(Theme.text).lineLimit(1)
                                    if declared {
                                        Circle().fill(Theme.text.opacity(0.7)).frame(width: 4, height: 4)
                                            .help("Declared pairing for the selected film")
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 18).padding(.trailing, 6)
                                .frame(height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(Theme.selectionFrame, lineWidth: paper.id == session.params.printStock ? 1 : 0))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var menu: some View {
        Group {
            Button("Use the film's declared paper") {
                if let t = session.catalog.stock(session.params.filmStock)?.targetPrint { var p = session.params; p.printStock = t; session.params = p }
            }
        }
    }
}
