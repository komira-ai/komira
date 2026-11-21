# `Atomic[Int64]`: 1.1 parameterizes `Atomic` on a value type.
from std.atomic import Atomic
from std.testing import assert_equal


def main() raises:
    var a = Atomic[Int64](Int64(0))
    _ = a.fetch_add(3)
    assert_equal(a.load(), 3)
    print("atomic value type ok")
