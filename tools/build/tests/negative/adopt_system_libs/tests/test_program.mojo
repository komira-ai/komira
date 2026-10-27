from std.testing import TestSuite, assert_true

from syslib_codec import sqlite_is_loadable


def test_the_pinned_library_is_found_by_its_bare_name() raises:
    assert_true(sqlite_is_loadable())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
