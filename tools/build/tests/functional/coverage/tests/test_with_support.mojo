# Test 47: a test of branchtd that imports branchtdsup, a package only its
# `test_deps` gives it, which calls into C; two of sign's three arms.
from std.testing import assert_equal

from branchtd import sign
from branchtdsup import c_add


def main() raises:
    assert_equal(sign(c_add(Int32(40), Int32(2))), Int32(1), "positive")
    assert_equal(sign(c_add(Int32(-2), Int32(2))), Int32(0), "zero")
