# The type of `Atomic(Int64(0))`: the parameter is inferred from the argument,
# whichever of `DType` (1.0.0) or a value type (1.1) it is.
from std.atomic import Atomic
from std.memory import OwnedPointer
from std.testing import assert_equal

comptime AtomicI64 = type_of(Atomic(Int64(0)))
comptime AtomicU8 = type_of(Atomic(UInt8(0)))


struct Holder(Movable):
    var counter: OwnedPointer[AtomicI64]

    def __init__(out self):
        self.counter = OwnedPointer[AtomicI64](AtomicI64(Int64(0)))


def main() raises:
    var h = Holder()
    _ = h.counter[].fetch_add(5)
    assert_equal(h.counter[].load(), 5)
    var b = AtomicU8(UInt8(1))
    _ = b.fetch_add(1)
    assert_equal(b.load(), 2)
    print("atomic type_of ok")
