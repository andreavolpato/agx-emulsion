#include "print_lut.hpp"

#include <fstream>
#include <sstream>

namespace spk {

namespace {

bool read_file(const std::string& path, std::string& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

}  // namespace

bool PrintLutLibrary::init(const std::string& resources_dir, std::string& error) {
    index_.clear();
    cache_.clear();
    catalog_.clear();

    std::string text;
    if (!read_file(resources_dir + "/print_luts.json", text)) {
        // Not fatal, and not silent either: the two LUT methods report the
        // missing index by name when they are called, which is the only time
        // it matters.
        return true;
    }
    Json index;
    std::string parse_error;
    if (!Json::parse(text, index, parse_error)) {
        error = "print_luts.json: " + parse_error;
        return false;
    }
    if (!index.is_object()) {
        error = "print_luts.json: expected an object keyed by print stock";
        return false;
    }
    for (const auto& kv : index.fields()) {
        const Json& v = kv.second;
        const int size = v.at("lut_size").as_int(0);
        if (size <= 1 || !v.at("paired_film").is_string()) {
            error = "print_luts.json: entry '" + kv.first + "' is missing lut_size or paired_film";
            return false;
        }
        Meta meta;
        meta.paired_film = v.at("paired_film").as_string();
        meta.declared_pairing = v.at("declared_pairing").as_bool(false);
        meta.size = uint32_t(size);
        index_[kv.first] = std::move(meta);
    }
    catalog_ = text;
    return true;
}

std::string PrintLutLibrary::available() const {
    std::string out;
    for (const auto& kv : index_) {
        if (!out.empty()) out += ", ";
        out += kv.first;
    }
    return out;
}

const PrintLut* PrintLutLibrary::get(const Blob& blob, const std::string& stock,
                                     std::string& error) {
    const auto cached = cache_.find(stock);
    if (cached != cache_.end()) return &cached->second;

    const auto meta = index_.find(stock);
    if (meta == index_.end()) {
        if (index_.empty()) {
            error = "no print-preview LUTs are bundled (print_luts.json is missing); "
                    "run engine/tools/bake_resources.py and engine/build.sh bundle";
        } else {
            error = "no shipped print-preview LUT for print stock '" + stock +
                    "'; available: " + available();
        }
        return nullptr;
    }

    // Widened to double by the blob reader and narrowed back here. The assets
    // are float32 and the kernel reads float32, so this round trip changes no
    // value -- it is the price of one reader for every baked constant, and
    // it is paid once per stock.
    std::vector<double> table, axes;
    uint32_t dims[4] = {0, 0, 0, 0};
    uint32_t ndim = 0;
    if (!blob.get("print_lut/" + stock, table, dims, ndim, error)) return nullptr;
    const uint32_t s = meta->second.size;
    if (ndim != 4 || dims[0] != s || dims[1] != s || dims[2] != s || dims[3] != 3) {
        error = "print_lut/" + stock + ": expected (" + std::to_string(s) + ", " +
                std::to_string(s) + ", " + std::to_string(s) + ", 3)";
        return nullptr;
    }
    if (!blob.get("print_lut_axes/" + stock, axes, dims, ndim, error)) return nullptr;
    if (ndim != 2 || dims[0] != 3 || dims[1] != s) {
        error = "print_lut_axes/" + stock + ": expected (3, " + std::to_string(s) + ")";
        return nullptr;
    }

    PrintLut lut;
    lut.stock = stock;
    lut.paired_film = meta->second.paired_film;
    lut.declared_pairing = meta->second.declared_pairing;
    lut.size = s;
    lut.table.resize(table.size());
    for (size_t i = 0; i < table.size(); ++i) lut.table[i] = float(table[i]);
    for (uint32_t c = 0; c < 3; ++c) {
        const double lo = axes[size_t(c) * s];
        const double hi = axes[size_t(c) * s + (s - 1)];
        if (!(hi > lo)) {
            error = "print_lut_axes/" + stock + ": channel " + std::to_string(c) +
                    " has a non-increasing density axis";
            return nullptr;
        }
        lut.lo[c] = float(lo);
        lut.hi[c] = float(hi);
        lut.inv_span[c] = float(1.0 / (hi - lo));
    }
    return &(cache_[stock] = std::move(lut));
}

}  // namespace spk
