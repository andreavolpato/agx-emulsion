// print_lut.hpp -- the baked print+scan LUTs, looked up by print stock.
//
// `preview_stock_lut` and the DI package are the only two callers and they
// want the same three things: a (S, S, S, 3) table, the (3, S) per-channel
// density axes it is indexed by, and the film the bake was paired with. All
// three come out of `engine/resources` -- the tables from the constants blob
// (`print_lut/<stock>`, `print_lut_axes/<stock>`) and the metadata from
// `print_luts.json`, one index rather than eight sidecars.
//
// Two things this deliberately does *not* do.
//
// **It does not bake.** The eight assets were baked, measured and validated
// by `scripts/bake_all_print_luts.py` (HANDOFF-PRINT-LUT §1); baking a ninth
// needs the whole print+scan chain evaluated over a 33^3 grid, which is the
// Python reference's job. A stock with no shipped LUT is refused by name.
//
// **It does not know about glare.** Glare is a spatial, stochastic veiling
// field and cannot live in a pointwise table. Leaving it out costs mean abs
// 0.00085 -> 0.00177 against a production render, which is the measured price
// of the preview being 47 ms instead of a 167 ms reprint at 45 MP
// (HANDOFF-PRINT-LUT §2).
// That is a design decision, not a gap.
#pragma once
#include <map>
#include <string>
#include <vector>

#include "blob.hpp"
#include "json.hpp"

namespace spk {

// One stock's table, host side. `lo` and `inv_span` are what the trilinear
// kernel actually indexes with; the axes themselves are uniform (checked at
// bake time), so the endpoints are the whole of the mapping.
struct PrintLut {
    std::string stock;
    std::string paired_film;
    bool declared_pairing = false;
    uint32_t size = 0;
    std::vector<float> table;     // (size, size, size, 3), row-major
    float lo[3] = {0, 0, 0};
    float hi[3] = {1, 1, 1};
    float inv_span[3] = {1, 1, 1};
};

class PrintLutLibrary {
public:
    // Reads `print_luts.json`. A resources directory without one is not an
    // error -- the engine still opens frames and renders them; only the two
    // LUT methods refuse, and they say why.
    bool init(const std::string& resources_dir, std::string& error);

    bool has(const std::string& stock) const { return index_.count(stock) != 0; }
    // The stocks that have a shipped LUT, comma-separated, for an error
    // message that tells the caller what it *could* have asked for.
    std::string available() const;
    // The `print_luts.json` index, verbatim, for `capabilities`.
    const std::string& catalog_json() const { return catalog_; }

    // Loads the table on first use and keeps it: 431 kB per stock, and the
    // whole point of the LUT path is that flipping between stocks is cheap.
    const PrintLut* get(const Blob& blob, const std::string& stock, std::string& error);

private:
    struct Meta {
        std::string paired_film;
        bool declared_pairing = false;
        uint32_t size = 0;
    };
    std::map<std::string, Meta> index_;
    std::map<std::string, PrintLut> cache_;
    std::string catalog_;
};

}  // namespace spk
