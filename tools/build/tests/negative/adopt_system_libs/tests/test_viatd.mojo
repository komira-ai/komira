from std.testing import TestSuite, assert_true

from syslib_codec import sqlite_is_loadable


def test_its_own_test_is_given_the_libraries() raises:
    assert_true(sqlite_is_loadable())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
