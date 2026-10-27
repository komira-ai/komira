from std.testing import TestSuite, assert_equal, assert_true

from syslib_codec import sqlite_is_loadable
from syslib_consumer import doubled


def test_the_pinned_library_is_found_by_its_bare_name() raises:
    # A Linux worker of the farm has no libsqlite3 of its own: this passes only when the run is given the pinned one.
    assert_true(sqlite_is_loadable())


def test_the_consumer_still_works() raises:
    assert_equal(doubled(21), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
# A farm worker has none of these libraries; the pinned run finds them.
