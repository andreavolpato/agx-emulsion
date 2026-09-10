// json.hpp -- a small JSON value, parser and writer.
//
// The engine ships with no third-party runtime, and it needs JSON in exactly
// three places: reading film and paper profiles, reading the neutral-filter
// database, and carrying parameters across the C ABI (RFC-014 §2.1). That is
// a narrow enough job to own outright rather than vendor a library for.
//
// Deliberately not a general JSON library: no comments, no NaN/Infinity
// literals, no duplicate-key policy beyond last-wins, and numbers are always
// double. What it does guarantee is what the profiles need -- exact round
// trip of the 17 significant digits numpy writes, and a parse that reports
// *where* it failed rather than returning a default.
#pragma once
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace spk {

class Json {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Json() : type_(Type::Null) {}
    explicit Json(bool b) : type_(Type::Bool), bool_(b) {}
    explicit Json(double d) : type_(Type::Number), num_(d) {}
    explicit Json(std::string s) : type_(Type::String), str_(std::move(s)) {}

    static Json array() { Json j; j.type_ = Type::Array; return j; }
    static Json object() { Json j; j.type_ = Type::Object; return j; }

    Type type() const { return type_; }
    bool is_null() const { return type_ == Type::Null; }
    bool is_bool() const { return type_ == Type::Bool; }
    bool is_number() const { return type_ == Type::Number; }
    bool is_string() const { return type_ == Type::String; }
    bool is_array() const { return type_ == Type::Array; }
    bool is_object() const { return type_ == Type::Object; }

    bool as_bool(bool fallback = false) const { return type_ == Type::Bool ? bool_ : fallback; }
    double as_double(double fallback = 0.0) const { return type_ == Type::Number ? num_ : fallback; }
    int as_int(int fallback = 0) const {
        return type_ == Type::Number ? static_cast<int>(num_ < 0 ? num_ - 0.5 : num_ + 0.5) : fallback;
    }
    const std::string& as_string() const { return str_; }

    const std::vector<Json>& items() const { return arr_; }
    std::vector<Json>& items() { return arr_; }
    const std::map<std::string, Json>& fields() const { return obj_; }

    // Object access. `at` returns a static null for a missing key so a chain
    // like `j.at("data").at("log_exposure")` never dereferences nothing --
    // the caller checks the leaf, not every link.
    const Json& at(const std::string& key) const;
    bool has(const std::string& key) const { return obj_.count(key) != 0; }
    void set(const std::string& key, Json value) { obj_[key] = std::move(value); type_ = Type::Object; }
    void push(Json value) { arr_.push_back(std::move(value)); type_ = Type::Array; }

    // Dotted path, for the transport schema's `film.info.stock` spellings.
    const Json& path(const std::string& dotted) const;

    std::string dump() const;                    // compact
    static bool parse(const std::string& text, Json& out, std::string& error);

private:
    void dump_into(std::string& out) const;

    Type type_;
    bool bool_ = false;
    double num_ = 0.0;
    std::string str_;
    std::vector<Json> arr_;
    std::map<std::string, Json> obj_;
};

// Flattening helpers for the numeric tables in a profile. Each checks the
// shape it was asked for and reports a mismatch by returning false, because a
// profile whose `density_curves` is (256, 3) on one release and (3, 256) on
// the next must fail at load, not at the first photograph.
bool json_to_vec(const Json& j, std::vector<double>& out);
bool json_to_mat(const Json& j, std::vector<double>& out, size_t& rows, size_t& cols);
bool json_to_3d(const Json& j, std::vector<double>& out, size_t& d0, size_t& d1, size_t& d2);

std::string json_escape(const std::string& s);

}  // namespace spk
