//  StockCatalog.swift — the film and paper the engine actually ships.
//
//  Read off `src/spektrafilm/data/profiles/`. Two things about this list are
//  product decisions rather than data:
//
//  1. **Cine pairs sit at the same level as still pairs, not behind an
//     "advanced" disclosure.** API-SPEC §5 measured the two pairings on the
//     same negative and found the difference is not subtle — two different,
//     both-authentic renderings. For a user chasing "the film look" in the
//     cinema sense, `kodak_vision3_250d` / `kodak_2393` may be closer to what
//     they mean by the phrase than the still-photo default. Burying it would
//     be making that decision for them.
//
//  2. **Undeclared pairings are allowed but marked.** Each film profile
//     declares its own `info.target_print`; five print stocks have no film
//     that names them. The preview LUT is coupled to the paper's curve *and*
//     the negative's dye spectra, so an undeclared pairing is an
//     approximation with unmeasured error — which is a thing to label, not a
//     thing to forbid.
//
//  This list is hardcoded for the shell. Once the service is wired, it comes
//  from the profile library so it cannot drift from what is installed.

import Foundation

struct Stock: Identifiable, Hashable, Sendable {
    let id: String              // the wire value for film_stock / print_stock
    let name: String
    let use: Use
    /// For film: the paper its profile declares as `info.target_print`.
    var targetPrint: String?

    enum Use: String, CaseIterable, Sendable { case still, cine }
}

enum StockCatalog {
    static let films: [Stock] = [
        .init(id: "kodak_portra_400", name: "Portra 400", use: .still,
              targetPrint: "kodak_portra_endura"),
        .init(id: "kodak_portra_160", name: "Portra 160", use: .still,
              targetPrint: "kodak_portra_endura"),
        .init(id: "kodak_ektar_100", name: "Ektar 100", use: .still,
              targetPrint: "kodak_ektacolor_edge"),
        .init(id: "kodak_gold_200", name: "Gold 200", use: .still,
              targetPrint: "kodak_supra_endura"),
        .init(id: "fujifilm_pro_400h", name: "Pro 400H", use: .still,
              targetPrint: "fujifilm_crystal_archive_typeii"),
        .init(id: "kodak_vision3_50d", name: "Vision3 50D", use: .cine,
              targetPrint: "kodak_2383"),
        .init(id: "kodak_vision3_250d", name: "Vision3 250D", use: .cine,
              targetPrint: "kodak_2383"),
        .init(id: "kodak_vision3_200t", name: "Vision3 200T", use: .cine,
              targetPrint: "kodak_2383"),
        .init(id: "kodak_vision3_500t", name: "Vision3 500T", use: .cine,
              targetPrint: "kodak_2383"),
    ]

    static let papers: [Stock] = [
        .init(id: "kodak_supra_endura", name: "Supra Endura", use: .still),
        .init(id: "kodak_portra_endura", name: "Portra Endura", use: .still),
        .init(id: "kodak_endura_premier", name: "Endura Premier", use: .still),
        .init(id: "kodak_ultra_endura", name: "Ultra Endura", use: .still),
        .init(id: "kodak_ektacolor_edge", name: "Ektacolor Edge", use: .still),
        .init(id: "fujifilm_crystal_archive_typeii", name: "Crystal Archive II", use: .still),
        .init(id: "kodak_2383", name: "Vision 2383", use: .cine),
        .init(id: "kodak_2393", name: "Vision Premier 2393", use: .cine),
    ]

    static func film(_ id: String) -> Stock? { films.first { $0.id == id } }
    static func paper(_ id: String) -> Stock? { papers.first { $0.id == id } }

    /// True when the film's profile names this paper as its `target_print`.
    static func isDeclaredPair(film: String, paper: String) -> Bool {
        self.film(film)?.targetPrint == paper
    }
}
