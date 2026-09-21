#include <catch2/catch_test_macros.hpp>
#include "nib/nib_core.h"

TEST_CASE("the ABI reports the version it was compiled with") {
    REQUIRE(nib_abi_version() == NIB_CORE_ABI_VERSION);
}

TEST_CASE("the ABI version starts at 1") {
    REQUIRE(nib_abi_version() == 1);
}
