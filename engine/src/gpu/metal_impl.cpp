// metal_impl.cpp -- metal-cpp's out-of-line symbols, in exactly one place.
//
// metal-cpp is header-only with a twist: the selectors and class lookups it
// caches need one translation unit to define these three macros and emit them.
// Defining them in more than one TU is a duplicate-symbol link error; in none,
// an undefined-symbol one. This file exists to be that one place, and to have
// nothing else in it so it cannot accidentally stop being it.
#define NS_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Metal/Metal.hpp>
