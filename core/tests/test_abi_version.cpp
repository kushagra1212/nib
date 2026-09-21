#include <catch2/catch_test_macros.hpp>
#include "nib/nib_core.h"

TEST_CASE("the ABI reports the version it was compiled with") {
    REQUIRE(nib_abi_version() == NIB_CORE_ABI_VERSION);
}

TEST_CASE("the ABI version is 2") {
    // 2 since nib_sentences stopped taking text as a struct by value.
    REQUIRE(nib_abi_version() == 2);
}
