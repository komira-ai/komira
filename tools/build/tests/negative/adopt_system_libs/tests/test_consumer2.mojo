from std.testing import TestSuite, assert_equal, assert_true

from syslib_codec import sqlite_is_loadable
from syslib_consumer import doubled
from syslib_consumer2 import tripled


def test_the_pinned_library_reaches_a_dependent_two_levels_down() raises:
    assert_true(sqlite_is_loadable())


def test_the_chain_still_works() raises:
    assert_equal(tripled(doubled(7)), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
