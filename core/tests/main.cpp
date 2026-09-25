#include <cstring>

#include "check.hpp"

// Usage: lenny_tests [name-substring]
int main(int argc, char** argv) {
    int run = 0;
    for (auto& c : t::cases()) {
        if (argc > 1 && !std::strstr(c.name, argv[1])) continue;
        const int before = t::failures();
        c.fn();
        std::printf("%s %s\n", t::failures() == before ? "ok  " : "FAIL", c.name);
        ++run;
    }
    std::printf("%d tests, %d failed checks\n", run, t::failures());
    return t::failures() == 0 && run > 0 ? 0 : 1;
}
