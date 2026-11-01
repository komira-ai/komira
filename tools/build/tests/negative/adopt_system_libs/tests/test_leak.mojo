from std.testing import TestSuite, assert_true

from syslib_codec import sqlite_is_loadable


def test_the_libraries_of_a_test_dep_do_not_reach_a_dependent() raises:
    # Passes only if the dependent was given the libraries through syslib_viatd's test_deps, which it must not be.
    assert_true(sqlite_is_loadable())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
