//  Spektrafilm-Bridging-Header.h — the engine's C ABI, visible to Swift.
//
//  This is the whole of the Swift/C++ boundary (RFC-014 §2.1). Swift sees the
//  `extern "C"` surface in `spk_engine.h` and nothing else: no C++ types, no
//  `std::`, no interop mode. The engine's own sources compile as C++20 in the
//  same target and link in; the header is the only thing both languages read.
//
//  Deliberately not `-cxx-interoperability-mode=default`. Xcode 26.6 and
//  Swift 6.3 support it, and it works, but a C ABI is stable across toolchains
//  in a way C++ name mangling and `std::` layouts are not, and it is what
//  keeps the boundary narrow enough that the numba parity harness can drive
//  the same binary through `ctypes`.
#import "spektrafilm/spk_engine.h"
