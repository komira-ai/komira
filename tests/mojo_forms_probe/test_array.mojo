# `Array[T, N]`, the name 1.1 keeps after removing the `InlineArray` alias.
from std.testing import assert_equal


def main() raises:
    var a = Array[UInt8, 4](fill=7)
    a[1] = 9
    assert_equal(Int(a[0]) + Int(a[1]), 16)
    print("array ok")
