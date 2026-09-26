// Minimal test harness: TEST(name) { CHECK(cond); }. No framework needed for this size.
#pragma once
#include <cstdio>
#include <functional>
#include <vector>

namespace t {
struct Case { const char* name; void (*fn)(); };
inline std::vector<Case>& cases() { static std::vector<Case> c; return c; }
inline int& failures() { static int f = 0; return f; }
struct Reg { Reg(const char* n, void (*fn)()) { cases().push_back({n, fn}); } };
}  // namespace t

#define TEST(name)                                   \
    static void name();                              \
    static t::Reg reg_##name(#name, name);           \
    static void name()

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);    \
            ++t::failures();                                                 \
        }                                                                    \
    } while (0)
