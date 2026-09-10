// blob.hpp -- the baked constants, mmapped and looked up by name.
//
// `engine/tools/bake_resources.py` writes it; this reads it. Every entry is
// returned as float64 whatever it was stored as, because the reference
// arithmetic these feed is float64 and narrowing at the door would be a
// silent precision change nothing tests for. (`hanatos/spectra_lut` is stored
// float16 for size; the reference widens it to double too.)
//
// A missing key is an error with the key in the message, never a zero array:
// RFC-012 §4.1's named failure mode is a silently-wrong constant, and half of
// avoiding it is refusing to invent one.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace spk {

struct BlobEntry {
    std::string name;
    uint32_t dtype = 0;
    uint32_t ndim = 0;
    uint32_t dims[4] = {0, 0, 0, 0};
    uint64_t offset = 0;
    uint64_t nbytes = 0;

    size_t count() const {
        size_t n = 1;
        for (uint32_t i = 0; i < ndim; ++i) n *= dims[i];
        return ndim ? n : 0;
    }
};

class Blob {
public:
    ~Blob();
    bool open(const std::string& path, std::string& error);
    bool has(const std::string& name) const;

    // Widened to double, copied out. These are all small (the largest is the
    // 5.97 MB spectra LUT) and read once at setup, so a copy costs nothing
    // and buys the caller an owned, aligned, contiguous array.
    bool get(const std::string& name, std::vector<double>& out, std::string& error) const;
    bool get(const std::string& name, std::vector<double>& out, uint32_t dims[4],
             uint32_t& ndim, std::string& error) const;

    std::vector<std::string> names() const;

private:
    const BlobEntry* find(const std::string& name) const;

    const uint8_t* base_ = nullptr;
    size_t size_ = 0;
    int fd_ = -1;
    std::vector<BlobEntry> entries_;
};

}  // namespace spk
