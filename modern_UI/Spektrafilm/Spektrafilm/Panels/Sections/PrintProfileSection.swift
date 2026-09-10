//  PrintProfileSection.swift — the paper list, grouped Still / Cine / Positive,
//  with the white frame on the selected paper, and the two actions that belong
//  to the print: Solve and Original.
//
//  The Positive group holds one row, "No print Profile": scan the developed
//  film instead of printing it. It is where a slide film belongs — printing
//  Provia onto Endura is a thing the engine will happily do and a thing nobody
//  wants — and it is also the only way to look at what the film stage actually
//  produced, orange mask and all.
//
//  It is `scan_film`, not a paper. Selecting it therefore does not clear the
//  paper: turn it off again and the print comes back on whatever was chosen
//  before, which is what makes it usable as a comparison rather than a
//  destination.

import SwiftUI

struct PrintProfileSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Print Profile", systemImage: "doc", key: "print", menu: { AnyView(menu) }) {
            VStack(spacing: 8) {
                Well(padding: 6, vertical: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(session.catalog.paperGroups, id: \.title) { group in
                            groupHeader(group.title)
                            ForEach(group.papers) { paper in
                                row(paper.name,
                                    selected: !session.params.scanFilm && paper.id == session.params.printStock,
                                    help: helpFor(paper.id)) {
                                    session.selectPrintStock(paper.id)
                                }
                            }
                        }
                        groupHeader("Positive")
                        row("No print Profile", selected: session.params.scanFilm,
                            help: "Scan the developed film instead of printing it — a slide film reads as a positive, a negative film as the negative it is.") {
                            var p = session.params
                            p.scanFilm = true
                            session.params = p
                        }
                    }
                }
                actions
            }
        }
    }

    /// Only says something when there is something to say: which film the
    /// paper's baked LUT was paired with, and only while the fast flip is on.
    private func helpFor(_ stock: String) -> String {
        guard session.fastStockPreview, let entry = session.printLUTStocks[stock] else { return "" }
        return "Fast flip available — baked against \(entry.pairedFilm)."
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title).font(Theme.Font.groupHeader).foregroundStyle(Theme.text)
            .padding(.leading, 10).frame(height: 18)
    }

    private func row(_ name: String, selected: Bool, help: String,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name).font(Theme.Font.listItem).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18).padding(.trailing, 6)
            .frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Theme.selectionFrame, lineWidth: selected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Solve and Original, in the drawing's two-pill row.
    ///
    /// They sit here rather than in the toolbar because both are questions
    /// about the *print*: "what would the engine choose for this paper" and
    /// "what did I start from". Original is a toggle, not a press-and-hold —
    /// Space already does press-and-hold on the canvas, and a panel button
    /// that only works while the mouse is down is a button nobody finds.
    private var actions: some View {
        HStack(spacing: 8) {
            pill("Solve", help: "Auto-expose this frame and solve the enlarger filter pack for the selected paper.",
                 active: false, enabled: session.canSolve) {
                session.solveNow()
            }
            pill("Original", help: "Show the decoded frame before any simulation (Space does the same, while held).",
                 active: session.showingOriginal, enabled: session.selection != nil) {
                session.toggledOriginal(!session.showingOriginal)
            }
        }
        // The wells above are inset by `wellInset`, and a pill that is not
        // runs to the card's own edge. A pill's fill *is* the ground colour,
        // so at the edge it merges with the window around the card and the
        // row reads as a bar spilling out of the panel — which is what it
        // looked like. Same inset as the well, so the two line up.
        .padding(.horizontal, Theme.Metric.wellInset)
    }

    private func pill(_ title: String, help: String, active: Bool, enabled: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.listItem)
                .foregroundStyle(active ? Theme.accent : (enabled ? Theme.text : Theme.dim))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Theme.well, in: Capsule())
                .overlay(Capsule().stroke(Theme.accent, lineWidth: active ? 1 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var menu: some View {
        Group {
            Button("Use the film's declared paper") {
                if let t = session.catalog.stock(session.params.filmStock)?.targetPrint {
                    var p = session.params; p.printStock = t; p.scanFilm = false; session.params = p
                }
            }
            Button("Solve exposure and filter pack") { session.solveNow() }
                .disabled(!session.canSolve)
            Divider()
            // The caveat is in the label because it is the whole decision.
            // A toggle called "Fast preview" with the explanation somewhere
            // else is a toggle whose behaviour is a surprise.
            Toggle("Fast flip (baked LUT, no glare, ignores your print grade)",
                   isOn: Binding(get: { session.fastStockPreview },
                                 set: { session.fastStockPreview = $0 }))
                .disabled(session.printLUTStocks.isEmpty)
        }
    }
}
