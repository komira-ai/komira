# =============================================================================
# Unit tests for VariadicPack[*Ts: VariadicElement]
# =============================================================================
#
# Tests:
#   1. arity() is the number of element types, for packs of 1 and 4 types,
#      repeats included (mutant caught: arity one short; one too many
#      indexes past the pack and does not compile)
#   2. get[k] with a literal k reaches the concrete element of slot k, and a
#      comptime for over arity() calls each slot's trait method once, in
#      slot order (a weighted sum tells slots apart)
#   3. get_mut[k] returns a reference: a write through it is seen by get[k]
#      and by no other slot (mutant caught: get_mut returning a copy, which
#      this test refuses at compile time: the write needs a mutable place)
#   4. a moved pack keeps its elements, heap-owning ones included
#
# Only identity rewrites of __init__ and get type-check (the slot type of
# get[k] is Self.Ts[k]), so their tests read values back rather than kill a
# planted mutant.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_collections.variadic_pack import VariadicElement, VariadicPack


@fieldwise_init
struct Width(VariadicElement):
    var px: Int

    def variadic_tag(self) -> Int:
        return self.px


@fieldwise_init
struct Label(VariadicElement):
    var text: String
    var weight: Int

    def variadic_tag(self) -> Int:
        return self.weight + self.text.byte_length()


def _weighted_tags[*Ts: VariadicElement](pack: VariadicPack[*Ts]) -> Int:
    """Sum of (k + 1) * tag(k): a slot visited twice, skipped or swapped
    with another of a different tag changes the sum."""
    var sum = 0
    comptime for k in range(VariadicPack[*Ts].arity()):
        sum += (k + 1) * pack.get[k]().variadic_tag()
    return sum


def test_arity() raises:
    assert_equal(VariadicPack[Width].arity(), 1)
    assert_equal(VariadicPack[Width, Label, Width, Width].arity(), 4)


def test_get_reaches_each_slot() raises:
    var pack = VariadicPack[Width, Label, Width](
        Width(100), Label("ab", 5), Width(3)
    )
    # Literal indices pin the concrete type and reach concrete fields.
    assert_equal(pack.get[0]().px, 100)
    assert_equal(pack.get[1]().text, "ab")
    assert_equal(pack.get[1]().weight, 5)
    assert_equal(pack.get[2]().px, 3)
    # 1*100 + 2*(5 + 2) + 3*3
    assert_equal(_weighted_tags(pack), 123)


def test_get_mut_writes_through() raises:
    var pack = VariadicPack[Width, Width, Label](
        Width(1), Width(2), Label("x", 0)
    )
    pack.get_mut[1]().px = 40
    pack.get_mut[2]().text = "xyz"
    assert_equal(pack.get[0]().px, 1)
    assert_equal(pack.get[1]().px, 40)
    assert_equal(pack.get[2]().text, "xyz")
    # 1*1 + 2*40 + 3*(0 + 3)
    assert_equal(_weighted_tags(pack), 90)


def test_moved_pack_keeps_elements() raises:
    var pack = VariadicPack[Label, Width](Label("heap-owned text", 7), Width(9))
    var moved = pack^
    assert_equal(moved.get[0]().text, "heap-owned text")
    assert_equal(moved.get[1]().px, 9)
    # 1*(7 + 15) + 2*9
    assert_equal(_weighted_tags(moved), 40)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
