#include "json.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace spk {

static const Json kNull;

const Json& Json::at(const std::string& key) const {
    auto it = obj_.find(key);
    return it == obj_.end() ? kNull : it->second;
}

const Json& Json::path(const std::string& dotted) const {
    const Json* cur = this;
    size_t start = 0;
    while (start <= dotted.size()) {
        size_t dot = dotted.find('.', start);
        std::string part = dotted.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        if (!cur->is_object()) return kNull;
        cur = &cur->at(part);
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    return *cur;
}

// --- writing ---------------------------------------------------------------

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) { char buf[8]; std::snprintf(buf, sizeof buf, "\\u%04x", c); out += buf; }
                else out += static_cast<char>(c);
        }
    }
    return out;
}

// %.17g round-trips every finite double exactly, which is what the profiles
// need. Non-finite numbers are written as `null`: JSON has no spelling for
// them, and a measured profile's NaN is load-bearing (RFC-014 §5.1 trap 5),
// so it must survive a round trip as *something* the parser reads back as
// missing data rather than as zero.
static void dump_number(double v, std::string& out) {
    if (!std::isfinite(v)) { out += "null"; return; }
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    out += buf;
}

void Json::dump_into(std::string& out) const {
    switch (type_) {
        case Type::Null: out += "null"; break;
        case Type::Bool: out += bool_ ? "true" : "false"; break;
        case Type::Number: dump_number(num_, out); break;
        case Type::String: out += '"'; out += json_escape(str_); out += '"'; break;
        case Type::Array: {
            out += '[';
            for (size_t i = 0; i < arr_.size(); ++i) { if (i) out += ','; arr_[i].dump_into(out); }
            out += ']';
            break;
        }
        case Type::Object: {
            out += '{';
            bool first = true;
            for (const auto& kv : obj_) {
                if (!first) out += ',';
                first = false;
                out += '"'; out += json_escape(kv.first); out += "\":";
                kv.second.dump_into(out);
            }
            out += '}';
            break;
        }
    }
}

std::string Json::dump() const {
    std::string out;
    dump_into(out);
    return out;
}

// --- parsing ---------------------------------------------------------------

namespace {

struct Parser {
    const char* p;
    const char* end;
    std::string err;

    bool fail(const char* what) {
        char buf[128];
        std::snprintf(buf, sizeof buf, "%s at byte %ld", what, static_cast<long>(p - begin));
        err = buf;
        return false;
    }
    const char* begin;

    void ws() { while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) ++p; }

    bool literal(const char* lit, size_t n) {
        if (static_cast<size_t>(end - p) < n || std::memcmp(p, lit, n) != 0) return false;
        p += n;
        return true;
    }

    bool value(Json& out, int depth) {
        if (depth > 64) return fail("nesting too deep");
        ws();
        if (p >= end) return fail("unexpected end of input");
        switch (*p) {
            case 'n': if (!literal("null", 4)) return fail("bad literal"); out = Json(); return true;
            case 't': if (!literal("true", 4)) return fail("bad literal"); out = Json(true); return true;
            case 'f': if (!literal("false", 5)) return fail("bad literal"); out = Json(false); return true;
            case '"': { std::string s; if (!string(s)) return false; out = Json(std::move(s)); return true; }
            case '[': return array(out, depth);
            case '{': return object(out, depth);
            default:  return number(out);
        }
    }

    bool number(Json& out) {
        char* stop = nullptr;
        // strtod over a NUL-terminated buffer: `parse` guarantees one.
        double v = std::strtod(p, &stop);
        if (stop == p) return fail("expected a value");
        p = stop;
        out = Json(v);
        return true;
    }

    bool hex4(unsigned& cp) {
        if (end - p < 4) return false;
        cp = 0;
        for (int i = 0; i < 4; ++i) {
            char c = p[i];
            cp <<= 4;
            if (c >= '0' && c <= '9') cp |= unsigned(c - '0');
            else if (c >= 'a' && c <= 'f') cp |= unsigned(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') cp |= unsigned(c - 'A' + 10);
            else return false;
        }
        p += 4;
        return true;
    }

    static void utf8(unsigned cp, std::string& s) {
        if (cp < 0x80) s += char(cp);
        else if (cp < 0x800) { s += char(0xC0 | (cp >> 6)); s += char(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) {
            s += char(0xE0 | (cp >> 12)); s += char(0x80 | ((cp >> 6) & 0x3F)); s += char(0x80 | (cp & 0x3F));
        } else {
            s += char(0xF0 | (cp >> 18)); s += char(0x80 | ((cp >> 12) & 0x3F));
            s += char(0x80 | ((cp >> 6) & 0x3F)); s += char(0x80 | (cp & 0x3F));
        }
    }

    bool string(std::string& out) {
        if (p >= end || *p != '"') return fail("expected a string");
        ++p;
        while (p < end) {
            unsigned char c = static_cast<unsigned char>(*p);
            if (c == '"') { ++p; return true; }
            if (c == '\\') {
                ++p;
                if (p >= end) return fail("unterminated escape");
                char e = *p++;
                switch (e) {
                    case '"': out += '"'; break;
                    case '\\': out += '\\'; break;
                    case '/': out += '/'; break;
                    case 'b': out += '\b'; break;
                    case 'f': out += '\f'; break;
                    case 'n': out += '\n'; break;
                    case 'r': out += '\r'; break;
                    case 't': out += '\t'; break;
                    case 'u': {
                        unsigned cp;
                        if (!hex4(cp)) return fail("bad \\u escape");
                        if (cp >= 0xD800 && cp <= 0xDBFF && end - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                            const char* save = p;
                            p += 2;
                            unsigned lo;
                            if (hex4(lo) && lo >= 0xDC00 && lo <= 0xDFFF)
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            else p = save;
                        }
                        utf8(cp, out);
                        break;
                    }
                    default: return fail("unknown escape");
                }
                continue;
            }
            if (c < 0x20) return fail("raw control character in string");
            out += static_cast<char>(c);
            ++p;
        }
        return fail("unterminated string");
    }

    bool array(Json& out, int depth) {
        ++p;  // '['
        out = Json::array();
        ws();
        if (p < end && *p == ']') { ++p; return true; }
        for (;;) {
            Json v;
            if (!value(v, depth + 1)) return false;
            out.push(std::move(v));
            ws();
            if (p >= end) return fail("unterminated array");
            if (*p == ',') { ++p; continue; }
            if (*p == ']') { ++p; return true; }
            return fail("expected ',' or ']'");
        }
    }

    bool object(Json& out, int depth) {
        ++p;  // '{'
        out = Json::object();
        ws();
        if (p < end && *p == '}') { ++p; return true; }
        for (;;) {
            ws();
            std::string key;
            if (!string(key)) return false;
            ws();
            if (p >= end || *p != ':') return fail("expected ':'");
            ++p;
            Json v;
            if (!value(v, depth + 1)) return false;
            out.set(key, std::move(v));
            ws();
            if (p >= end) return fail("unterminated object");
            if (*p == ',') { ++p; continue; }
            if (*p == '}') { ++p; return true; }
            return fail("expected ',' or '}'");
        }
    }
};

}  // namespace

bool Json::parse(const std::string& text, Json& out, std::string& error) {
    Parser ps{text.c_str(), text.c_str() + text.size(), {}, text.c_str()};
    if (!ps.value(out, 0)) { error = ps.err; return false; }
    ps.ws();
    if (ps.p != ps.end) { error = "trailing characters after the top-level value"; return false; }
    error.clear();
    return true;
}

// --- numeric flattening -----------------------------------------------------
// `null` becomes NaN on the way in. That is not a convenience: the profiles
// carry NaN where no measurement exists (Portra 400 has 22 in
// `channel_density`), the reference lets those propagate and neutralises them
// once, outside the pixel loop, and a reader that turned them into 0.0 would
// put a transmittance of 1 where there is no data.

static double number_or_nan(const Json& j) {
    return j.is_number() ? j.as_double() : std::nan("");
}

bool json_to_vec(const Json& j, std::vector<double>& out) {
    if (!j.is_array()) return false;
    out.clear();
    out.reserve(j.items().size());
    for (const Json& v : j.items()) {
        if (!v.is_number() && !v.is_null()) return false;
        out.push_back(number_or_nan(v));
    }
    return true;
}

bool json_to_mat(const Json& j, std::vector<double>& out, size_t& rows, size_t& cols) {
    if (!j.is_array() || j.items().empty()) return false;
    const Json& first = j.items()[0];
    if (!first.is_array()) return false;
    rows = j.items().size();
    cols = first.items().size();
    out.clear();
    out.reserve(rows * cols);
    for (const Json& row : j.items()) {
        if (!row.is_array() || row.items().size() != cols) return false;
        for (const Json& v : row.items()) {
            if (!v.is_number() && !v.is_null()) return false;
            out.push_back(number_or_nan(v));
        }
    }
    return true;
}

bool json_to_3d(const Json& j, std::vector<double>& out, size_t& d0, size_t& d1, size_t& d2) {
    if (!j.is_array() || j.items().empty()) return false;
    d0 = j.items().size();
    const Json& a = j.items()[0];
    if (!a.is_array() || a.items().empty()) return false;
    d1 = a.items().size();
    const Json& b = a.items()[0];
    if (!b.is_array()) return false;
    d2 = b.items().size();
    out.clear();
    out.reserve(d0 * d1 * d2);
    for (const Json& p0 : j.items()) {
        if (!p0.is_array() || p0.items().size() != d1) return false;
        for (const Json& p1 : p0.items()) {
            if (!p1.is_array() || p1.items().size() != d2) return false;
            for (const Json& v : p1.items()) {
                if (!v.is_number() && !v.is_null()) return false;
                out.push_back(number_or_nan(v));
            }
        }
    }
    return true;
}

}  // namespace spk
