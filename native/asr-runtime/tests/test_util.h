// Tiny assertion harness: no external test framework dependency.
#pragma once

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace sdtest {

struct Case {
    const char *name;
    std::function<void()> body;
};

inline std::vector<Case> &registry() {
    static std::vector<Case> cases;
    return cases;
}

inline int &failures() {
    static int count = 0;
    return count;
}

struct Registrar {
    Registrar(const char *name, std::function<void()> body) { registry().push_back({name, std::move(body)}); }
};

inline int run_all() {
    for (const auto &c : registry()) {
        const int before = failures();
        c.body();
        std::printf("%s %s\n", failures() == before ? "PASS" : "FAIL", c.name);
    }
    std::printf("%zu cases, %d failed checks\n", registry().size(), failures());
    return failures() == 0 ? 0 : 1;
}

}  // namespace sdtest

#define SD_CONCAT2(a, b) a##b
#define SD_CONCAT(a, b) SD_CONCAT2(a, b)
#define TEST_CASE(name)                                                               \
    static void SD_CONCAT(test_body_, __LINE__)();                                    \
    static sdtest::Registrar SD_CONCAT(test_reg_, __LINE__)(name, SD_CONCAT(test_body_, __LINE__)); \
    static void SD_CONCAT(test_body_, __LINE__)()

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::printf("  check failed %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
            ++sdtest::failures();                                                     \
        }                                                                             \
    } while (0)

#define CHECK_EQ(a, b)                                                                \
    do {                                                                              \
        const auto &_a = (a);                                                         \
        const auto &_b = (b);                                                         \
        if (!(_a == _b)) {                                                            \
            std::printf("  check failed %s:%d: %s == %s\n", __FILE__, __LINE__, #a, #b); \
            ++sdtest::failures();                                                     \
        }                                                                             \
    } while (0)
