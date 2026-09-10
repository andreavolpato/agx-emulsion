#include "blob.hpp"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>

namespace spk {

namespace {
constexpr char kMagic[4] = {'S', 'P', 'K', 'R'};
constexpr uint32_t kVersion = 1;
constexpr size_t kNameLen = 64;
// name[64] + dtype + ndim + dims[4] + offset + nbytes, packed as the baker
// writes it. Checked against sizeof below so a struct-layout surprise is a
// compile error rather than a garbled table.
constexpr size_t kEntrySize = kNameLen + 4 * 6 + 8 * 2;

// float16 -> double, including subnormals and the specials. The spectra LUT
// is stored half; every value in it is finite and positive, but the specials
// are handled anyway because a reader that quietly mangles them is a reader
// that will mangle a future table.
double half_to_double(uint16_t h) {
    const uint32_t sign = uint32_t(h >> 15) & 1u;
    const uint32_t exp = uint32_t(h >> 10) & 0x1Fu;
    const uint32_t man = uint32_t(h) & 0x3FFu;
    double value;
    if (exp == 0) value = man == 0 ? 0.0 : double(man) * 5.9604644775390625e-08;  // 2^-24
    else if (exp == 31) value = man == 0 ? __builtin_inf() : __builtin_nan("");
    else {
        const int e = int(exp) - 15;
        value = (1.0 + double(man) / 1024.0) * __builtin_ldexp(1.0, e);
    }
    return sign ? -value : value;
}
}  // namespace

Blob::~Blob() {
    if (base_) ::munmap(const_cast<uint8_t*>(base_), size_);
    if (fd_ >= 0) ::close(fd_);
}

bool Blob::open(const std::string& path, std::string& error) {
    fd_ = ::open(path.c_str(), O_RDONLY);
    if (fd_ < 0) { error = "cannot open " + path; return false; }
    struct stat st {};
    if (::fstat(fd_, &st) != 0 || st.st_size < 16) { error = "cannot stat " + path; return false; }
    size_ = static_cast<size_t>(st.st_size);
    void* m = ::mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, fd_, 0);
    if (m == MAP_FAILED) { error = "cannot map " + path; return false; }
    base_ = static_cast<const uint8_t*>(m);

    if (std::memcmp(base_, kMagic, 4) != 0) { error = path + ": not a spektrafilm resource blob"; return false; }
    uint32_t version, count;
    std::memcpy(&version, base_ + 4, 4);
    std::memcpy(&count, base_ + 8, 4);
    if (version != kVersion) {
        error = path + ": blob version " + std::to_string(version) + ", this build reads " +
                std::to_string(kVersion) + " -- re-run engine/tools/bake_resources.py";
        return false;
    }
    const size_t table = 16 + size_t(count) * kEntrySize;
    if (table > size_) { error = path + ": truncated entry table"; return false; }

    entries_.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        const uint8_t* p = base_ + 16 + size_t(i) * kEntrySize;
        BlobEntry e;
        char name[kNameLen + 1] = {};
        std::memcpy(name, p, kNameLen);
        e.name = name;
        p += kNameLen;
        std::memcpy(&e.dtype, p, 4); p += 4;
        std::memcpy(&e.ndim, p, 4);  p += 4;
        std::memcpy(e.dims, p, 16);  p += 16;
        std::memcpy(&e.offset, p, 8); p += 8;
        std::memcpy(&e.nbytes, p, 8);
        if (e.offset + e.nbytes > size_) { error = path + ": entry '" + e.name + "' runs past the file"; return false; }
        entries_.push_back(std::move(e));
    }
    return true;
}

const BlobEntry* Blob::find(const std::string& name) const {
    for (const BlobEntry& e : entries_) if (e.name == name) return &e;
    return nullptr;
}

bool Blob::has(const std::string& name) const { return find(name) != nullptr; }

std::vector<std::string> Blob::names() const {
    std::vector<std::string> out;
    out.reserve(entries_.size());
    for (const BlobEntry& e : entries_) out.push_back(e.name);
    return out;
}

bool Blob::get(const std::string& name, std::vector<double>& out, std::string& error) const {
    uint32_t dims[4]; uint32_t ndim;
    return get(name, out, dims, ndim, error);
}

bool Blob::get(const std::string& name, std::vector<double>& out, uint32_t dims[4],
               uint32_t& ndim, std::string& error) const {
    const BlobEntry* e = find(name);
    if (!e) { error = "no baked constant '" + name + "'; re-run engine/tools/bake_resources.py"; return false; }
    const size_t n = e->count();
    out.resize(n);
    std::memcpy(dims, e->dims, sizeof e->dims);
    ndim = e->ndim;
    const uint8_t* src = base_ + e->offset;
    switch (e->dtype) {
        case 0: {  // float64
            if (e->nbytes != n * 8) { error = name + ": size does not match its shape"; return false; }
            std::memcpy(out.data(), src, e->nbytes);
            break;
        }
        case 1: {  // float32
            if (e->nbytes != n * 4) { error = name + ": size does not match its shape"; return false; }
            for (size_t i = 0; i < n; ++i) { float v; std::memcpy(&v, src + 4 * i, 4); out[i] = double(v); }
            break;
        }
        case 2: {  // float16
            if (e->nbytes != n * 2) { error = name + ": size does not match its shape"; return false; }
            for (size_t i = 0; i < n; ++i) { uint16_t v; std::memcpy(&v, src + 2 * i, 2); out[i] = half_to_double(v); }
            break;
        }
        case 3: {  // int32
            if (e->nbytes != n * 4) { error = name + ": size does not match its shape"; return false; }
            for (size_t i = 0; i < n; ++i) { int32_t v; std::memcpy(&v, src + 4 * i, 4); out[i] = double(v); }
            break;
        }
        case 4: {  // uint8
            if (e->nbytes != n) { error = name + ": size does not match its shape"; return false; }
            for (size_t i = 0; i < n; ++i) out[i] = double(src[i]);
            break;
        }
        default: error = name + ": unknown dtype tag " + std::to_string(e->dtype); return false;
    }
    return true;
}

}  // namespace spk
