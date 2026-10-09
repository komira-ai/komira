# A welded test at the package's top (as a cloud SDK client's): set aside
# like elsewhere/tests/test_top.mojo (test 46).
from covtop import top
from std.testing import assert_equal


def main() raises:
    var got = top()
    assert_equal(got, "top", "top")
