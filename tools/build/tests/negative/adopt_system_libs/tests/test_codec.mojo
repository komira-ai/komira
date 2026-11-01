from std.testing import TestSuite, assert_equal

from syslib_codec import answer


# The package's own test does not call `sqlite_is_loadable`: it runs where the library may be absent.
def test_the_pure_function() raises:
    assert_equal(answer(), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
