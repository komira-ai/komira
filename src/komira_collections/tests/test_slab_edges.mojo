# =============================================================================
# Unit tests for Slab[T]: no-op fast paths, the `mut src` extend, factories,
# raw-buffer adoption, buffer stealing and the length aliases
# =============================================================================
#
# "Same buffer" below compares `_unsafe_as_pointer()` before and after: a
# fast path that reallocates (even to the same capacity) moves the buffer.
#
# Tests:
#   1. reserve(0), reserve(-3) and a reserve that fits exactly keep the
#      capacity and the buffer, below the minimum capacity of 4; one more
#      slot grows to 4 (mutants caught: `required <= cap` -> `<`, the
#      fits-already return deleted, the additional <= 0 return growing)
#   2. extend by an empty slab (both overloads) keeps len, capacity, buffer
#      and values (mutant caught: the empty-source return growing the buffer)
#   3. the `mut src` extend: into an empty slab (0 -> 4 -> 8), into one with
#      room (no growth, appended after the live slots), the source left
#      empty and usable (mutants caught: src not emptied, writes at slot i
#      instead of len + i, growth by 3 instead of 2)
#   4. shrink_to_fit on a full slab keeps the buffer (mutant caught: the
#      len == cap return deleted, which reallocates)
#   5. _reserve_t never shrinks: a smaller or equal capacity keeps capacity,
#      buffer and values. Every caller in slab.mojo asks for more than the
#      capacity, so only a direct call reaches the guard (mutant caught: the
#      guard's return deleted, which shrinks the capacity: checked after
#      each call, as a later larger call would restore it)
#   6. with_capacity / create_with_capacity: len 0, capacity as asked, none
#      for 0 or less (mutant caught: capacity + 1)
#   7. from_raw_parts adopts 3 of 4, 1 of 2 and 0 of 2 initialized slots
#      (mutants caught: len set to size - 1, the move skipped for size 1)
#   8. from_slab passes the slab through; steal_slab moves the buffer out
#      and leaves an empty, usable slab (mutants caught: the stolen slab's
#      capacity not copied, the source's length not reset)
#   9. is_full, set_len, unsafe_set_len (mutants caught: is_full comparing
#      with >, set_len / unsafe_set_len storing new_len - 1)
#  10. _unsafe_as_pointer is slot 0: reads and writes go to the slab
#      (mutant caught: the pointer offset by one slot)
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_collections.slab import Slab


struct Item(Deinitable, Movable):
    """A heap-owning slot: a wrong move or a double drop shows in `items`."""

    var items: List[Int]
    var tag: Int

    def __init__(out self, tag: Int):
        self.items = [tag, tag * 10]
        self.tag = tag


def _items(first: Int, count: Int) -> Slab[Item]:
    var s = Slab[Item]()
    for i in range(count):
        s.append(Item(first + i))
    return s^


def _assert_tags(s: Slab[Item], first: Int, count: Int) raises:
    assert_equal(s.len(), count)
    for i in range(count):
        assert_equal(s[i].tag, first + i)
        assert_equal(len(s[i].items), 2)
        assert_equal(s[i].items[1], (first + i) * 10)


def test_reserve_fast_paths_keep_buffer() raises:
    var s = Slab[Int](2)
    s.append(7)
    var p = s._unsafe_as_pointer()
    s.reserve(0)
    s.reserve(-3)
    assert_equal(s.capacity(), 2)
    assert_true(s._unsafe_as_pointer() == p)
    s.reserve(1)  # len 1 + 1 == capacity 2: fits exactly
    assert_equal(s.capacity(), 2)
    assert_true(s._unsafe_as_pointer() == p)
    s.reserve(2)  # 3 > 2: grows to the minimum capacity
    assert_equal(s.capacity(), 4)
    assert_equal(s.len(), 1)
    assert_equal(s[0], 7)


def test_extend_by_empty_is_a_no_op() raises:
    var a = Slab[Item](4)
    a.append(Item(1))
    a.append(Item(2))
    var p = a._unsafe_as_pointer()
    a.extend(Slab[Item]())
    var empty = Slab[Item]()
    a.extend(empty)
    assert_equal(a.capacity(), 4)
    assert_true(a._unsafe_as_pointer() == p)
    _assert_tags(a, 1, 2)
    assert_equal(empty.len(), 0)


def test_extend_mut_src() raises:
    var a = Slab[Item]()
    var b = _items(1, 5)
    a.extend(b)  # b is a variable, not moved: the `mut src` overload
    assert_equal(b.len(), 0)
    assert_equal(a.capacity(), 8)
    _assert_tags(a, 1, 5)
    # The emptied source is still a usable slab.
    b.append(Item(6))
    b.append(Item(7))
    var p = a._unsafe_as_pointer()
    a.extend(b)  # 5 + 2 <= 8: no growth, appended after slot 4
    assert_equal(b.len(), 0)
    assert_equal(a.capacity(), 8)
    assert_true(a._unsafe_as_pointer() == p)
    _assert_tags(a, 1, 7)


def test_shrink_to_fit_when_full_keeps_buffer() raises:
    var s = Slab[Int](4)
    for i in range(4):
        s.append(i * 3)
    var p = s._unsafe_as_pointer()
    s.shrink_to_fit()
    assert_equal(s.capacity(), 4)
    assert_true(s._unsafe_as_pointer() == p)
    for i in range(4):
        assert_equal(s[i], i * 3)


def test_reserve_t_never_shrinks() raises:
    var s = Slab[Int](8)
    for i in range(3):
        s.append(i + 100)
    var p = s._unsafe_as_pointer()
    s._reserve_t(2)
    assert_equal(s.capacity(), 8)
    s._reserve_t(8)
    assert_equal(s.capacity(), 8)
    assert_true(s._unsafe_as_pointer() == p)
    for i in range(3):
        assert_equal(s[i], i + 100)
    # The kept capacity is real: five more appends need no growth.
    for i in range(5):
        s.append(i)
    assert_true(s._unsafe_as_pointer() == p)


def test_capacity_factories() raises:
    var a = Slab[Int].with_capacity(5)
    assert_equal(a.len(), 0)
    assert_equal(a.capacity(), 5)
    var b = Slab[Int].create_with_capacity(3)
    assert_equal(b.len(), 0)
    assert_equal(b.capacity(), 3)
    assert_equal(Slab[Int].with_capacity(0).capacity(), 0)
    assert_equal(Slab[Int].with_capacity(-2).capacity(), 0)
    assert_equal(Slab[Int].create_with_capacity(0).capacity(), 0)


def test_from_raw_parts() raises:
    # SAFETY: each buffer comes from `alloc`, whose origin is the one
    # `from_raw_parts` names, so it is passed as is (no origin cast); the Slab
    # adopts and frees it.
    var data = alloc[Item](4)
    for i in range(3):
        (data + i).init_pointee_move(Item(i + 1))
    var s = Slab[Item].from_raw_parts[Item](
        data, 3, 4
    )
    assert_equal(s.capacity(), 4)
    _assert_tags(s, 1, 3)
    var p = s._unsafe_as_pointer()
    s.append(Item(4))  # the fourth slot is room, not a slot to grow into
    assert_true(s._unsafe_as_pointer() == p)
    _assert_tags(s, 1, 4)

    var one = alloc[Item](2)
    one.init_pointee_move(Item(9))
    var t = Slab[Item].from_raw_parts[Item](
        one, 1, 2
    )
    assert_equal(t.capacity(), 2)
    _assert_tags(t, 9, 1)

    var none = alloc[Item](2)
    var u = Slab[Item].from_raw_parts[Item](
        none, 0, 2
    )
    assert_equal(u.len(), 0)
    assert_equal(u.capacity(), 2)


def test_from_slab_and_steal_slab() raises:
    var s = _items(1, 3)
    var cap = s.capacity()
    var p = s._unsafe_as_pointer()
    var t = Slab[Item].from_slab(s^)
    assert_true(t._unsafe_as_pointer() == p)
    _assert_tags(t, 1, 3)

    var stolen = t.steal_slab()
    assert_equal(stolen.capacity(), cap)
    assert_true(stolen._unsafe_as_pointer() == p)
    _assert_tags(stolen, 1, 3)
    assert_equal(t.len(), 0)
    assert_equal(t.capacity(), 0)
    t.append(Item(20))
    _assert_tags(t, 20, 1)


def test_is_full_and_length_aliases() raises:
    assert_true(Slab[Int]().is_full())  # 0 of 0
    var s = Slab[Int](4)
    assert_false(s.is_full())
    for i in range(4):
        s.append(i + 1)
    assert_true(s.is_full())
    s.set_len(2)  # Int needs no drop: shortening abandons slots 2 and 3
    assert_equal(s.len(), 2)
    assert_false(s.is_full())
    s.unsafe_set_len(3)  # slot 2's bytes are still the value 3
    assert_equal(s.len(), 3)
    assert_equal(s[2], 3)
    s.set_len(4)
    assert_true(s.is_full())
    assert_equal(s[3], 4)


def test_unsafe_as_pointer_is_slot_zero() raises:
    var s = Slab[Int]()
    s.append(10)
    s.append(20)
    var p = s._unsafe_as_pointer()
    assert_equal(p[0], 10)
    assert_equal(p[1], 20)
    p[1] = 25
    assert_equal(s[1], 25)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
