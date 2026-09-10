#include "setup_cache.hpp"

#include <algorithm>
#include <cstdio>

namespace spk {

namespace {

// A key that folds in every input the product depends on. Not a hash of a
// pointer and not the stock name alone: the sensitivity array is where the
// camera's UV/IR cut and the profile's own log_sensitivity land, and two
// different sensitivities with the same stock name must not share a LUT.
//
// FNV-1a over the raw bytes. A collision here is a wrong photograph, so the
// digest is over the values themselves rather than over a summary of them.
std::string digest(const double* data, size_t count) {
    uint64_t h = 0xcbf29ce484222325ull;
    const auto* bytes = reinterpret_cast<const unsigned char*>(data);
    for (size_t i = 0; i < count * sizeof(double); ++i) {
        h ^= bytes[i];
        h *= 0x100000001b3ull;
    }
    char buf[24];
    std::snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h));
    return buf;
}

std::string tc_lut_key(const Profile& film, const SettingsParams& settings,
                       const GamutCompressSpec& compress, const Vec& sensitivity) {
    std::string key = film.info.stock;
    key += '|';
    key += digest(sensitivity.data(), sensitivity.size());
    key += settings.apply_hanatos2025_adaptation_window ? "|w1" : "|w0";
    key += settings.apply_hanatos2025_adaptation_surface ? "|s1" : "|s0";
    char buf[64];
    std::snprintf(buf, sizeof buf, "|b%.17g", settings.spectral_gaussian_blur);
    key += buf;
    if (compress.active) {
        std::snprintf(buf, sizeof buf, "|c%s,%.17g,%.17g,%.17g", compress.algorithm.c_str(),
                      compress.knee[0], compress.knee[1], compress.knee[2]);
        key += buf;
    } else {
        key += "|c0";
    }
    // The window and surface parameters come from the profile, and a profile
    // edited in place with the same stock name would otherwise hit.
    if (!film.data.adaptation_window_params.empty())
        key += "|" + digest(film.data.adaptation_window_params.data(),
                            film.data.adaptation_window_params.size());
    if (!film.data.adaptation_surface_params.empty())
        key += "|" + digest(film.data.adaptation_surface_params.data(),
                            film.data.adaptation_surface_params.size());
    return key;
}

}  // namespace

bool SetupCache::cam16(const Colour& colour, const std::string& cs,
                       const Cam16Setup*& out, std::string& error) {
    std::lock_guard<std::mutex> guard(lock_);
    auto it = cam16_.find(cs);
    if (it != cam16_.end()) {
        ++hits_;
        out = &it->second;
        return true;
    }
    ++misses_;
    Cam16Setup setup;
    if (!cam16_setup_for(colour, cs, setup, error)) return false;
    out = &cam16_.emplace(cs, std::move(setup)).first->second;
    return true;
}

bool SetupCache::tc_lut(const Colour& colour, const Blob& blob, const Profile& film,
                        const SettingsParams& settings, const GamutCompressSpec& compress,
                        const Vec& sensitivity, const Vec*& out, size_t& side,
                        std::string& error) {
    const std::string key = tc_lut_key(film, settings, compress, sensitivity);
    std::lock_guard<std::mutex> guard(lock_);
    for (size_t i = 0; i < luts_.size(); ++i) {
        if (luts_[i].key != key) continue;
        ++hits_;
        if (i != 0) std::rotate(luts_.begin(), luts_.begin() + long(i), luts_.begin() + long(i) + 1);
        out = &luts_.front().lut;
        side = luts_.front().side;
        return true;
    }
    ++misses_;
    LutEntry entry;
    entry.key = key;
    if (!build_tc_lut(colour, blob, film, settings, compress, sensitivity,
                      entry.lut, entry.side, error)) return false;
    luts_.insert(luts_.begin(), std::move(entry));
    if (luts_.size() > kMaxLuts) luts_.pop_back();
    out = &luts_.front().lut;
    side = luts_.front().side;
    return true;
}

SetupCache::Stats SetupCache::stats() const {
    std::lock_guard<std::mutex> guard(lock_);
    return Stats{cam16_.size(), luts_.size(), hits_, misses_};
}

}  // namespace spk
