# Test 47: a test whose library calls into C; two of add_clamped's three
# arms (never "below 0").
from std.testing import assert_equal

from branchc import add_clamped


def main() raises:
    assert_equal(add_clamped(Int32(40), Int32(2)), Int32(42), "in range")
    assert_equal(add_clamped(Int32(90), Int32(20)), Int32(100), "above 100")
