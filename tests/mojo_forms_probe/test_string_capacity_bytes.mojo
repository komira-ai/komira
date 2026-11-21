# `String(capacity_bytes=)`, the keyword 1.1 accepts.
from std.testing import assert_equal


def main() raises:
    var s = String(capacity_bytes=16)
    s += "abc"
    assert_equal(s, "abc")
    print("string capacity_bytes ok")
