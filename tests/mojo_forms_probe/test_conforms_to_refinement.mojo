# A trait method called inside `comptime if conforms_to(T, Trait)` with no
# `trait_downcast`: 1.1 removed `trait_downcast` and refines `T` instead.
from std.testing import assert_equal


trait Named:
    def name(self) -> String:
        ...


@fieldwise_init
struct Thing(Copyable, Named):
    var n: Int

    def name(self) -> String:
        return "thing"


@fieldwise_init
struct Plain(Copyable):
    var n: Int


def describe[T: Copyable](v: T) -> String:
    comptime if conforms_to(T, Named):
        return v.name()
    else:
        return "plain"


def main() raises:
    assert_equal(describe(Thing(1)), "thing")
    assert_equal(describe(Plain(2)), "plain")
    print("conforms_to refinement ok")
