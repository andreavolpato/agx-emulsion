//  StockModule.swift — film × paper.
//
//  Mandatory, with no "off" state: `RuntimePhotoParams.film`/`.print` are
//  non-optional and the engine raises if either is missing (API-SPEC §4).
//
//  Cine pairs sit at the same level as still pairs. API-SPEC §5 measured the
//  two pairings on one negative and the difference is not subtle — for a user
//  chasing "the film look" in the cinema sense, the cine pair may be closer to
//  what they mean. Burying it would make that choice for them.

import SwiftUI

@MainActor
enum StockModule {
    static let module = EditorModule(
        id: "stock", title: "Stock", systemImage: "film.stack",
        column: .left, layer: .physical,
        summary: { StockCatalog.film($0.text("film_stock"))?.name },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View {
        @Bindable var session: Session

        private var declared: Bool {
            StockCatalog.isDeclaredPair(film: session.text("film_stock"),
                                        paper: session.text("print_stock"))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                LabeledRow("Film") {
                    StockPicker(selection: session.textBinding("film_stock"),
                                stocks: StockCatalog.films)
                }
                LabeledRow("Paper") {
                    StockPicker(selection: session.textBinding("print_stock"),
                                stocks: StockCatalog.papers)
                }
                // Marked, not blocked. The preview LUT is coupled to the
                // paper's curve *and* the negative's dye spectra, so an
                // undeclared pairing is an approximation with unmeasured
                // error — a thing to label.
                if !declared {
                    Label("Undeclared pairing", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("This paper is not the film's declared target print. "
                            + "The preview LUT is coupled to the negative's dye spectra "
                            + "as well as the paper curve, so the result is an "
                            + "approximation with unmeasured error.")
                }
            }
        }
    }
}

/// Grouped by use so cine and still read as peers.
private struct StockPicker: View {
    @Binding var selection: String
    let stocks: [Stock]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Stock.Use.allCases, id: \.self) { use in
                Section(use.rawValue.capitalized) {
                    ForEach(stocks.filter { $0.use == use }) { Text($0.name).tag($0.id) }
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}
