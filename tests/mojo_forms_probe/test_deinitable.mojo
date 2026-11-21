# `Deinitable`, the name 1.1 keeps after removing `ImplicitlyDestructible`.
from std.testing import assert_equal


def take[T: Movable & Deinitable](var v: T) -> Int:
    _ = v^
    return 1


def main() raises:
    assert_equal(take(String("x")), 1)
    print("deinitable ok")
