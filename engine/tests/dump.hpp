// dump.hpp -- a named float64 dump, so the C++ setup maths can be diffed
// against the Python reference value for value.
//
// RFC-014 §3: numba (and colour-science, and scipy) stay the oracle; only the
// language on the other side changes. This is the transport for that
// comparison on the *setup* half -- the ~1,100 lines that dominate the port
// and that no picture would show to be subtly wrong.
#pragma once
#include <cstdio>
#include <string>
#include <vector>

namespace spk {

class Dump {
public:
    Dump(const std::string& data_path, const std::string& index_path)
        : data_(std::fopen(data_path.c_str(), "wb")), index_(std::fopen(index_path.c_str(), "w")) {}
    ~Dump() { if (data_) std::fclose(data_); if (index_) std::fclose(index_); }

    bool ok() const { return data_ && index_; }

    void add(const std::string& name, const double* p, size_t n) {
        std::fwrite(p, sizeof(double), n, data_);
        std::fprintf(index_, "%s\t%lld\t%zu\n", name.c_str(), static_cast<long long>(offset_), n);
        offset_ += static_cast<long long>(n);
    }
    void add(const std::string& name, const std::vector<double>& v) { add(name, v.data(), v.size()); }
    void add(const std::string& name, double v) { add(name, &v, 1); }

private:
    std::FILE* data_;
    std::FILE* index_;
    long long offset_ = 0;
};

}  // namespace spk
