# =============================================================================
# Unit tests for Slab[T]
# =============================================================================
#
# Coverage:
#   Universal (any T: Deinitable):
#     1. Empty construction + len/capacity == 0
#     2. create(n) has len=n, cap=n
#     3. init_slot[init_fn] on a non-Movable Atomic-bearing T (the init_fn's
#        writes land in the slot it was given, and only that slot)
#     4. __getitem__ read on init_slot-populated non-Movable T
#     5. field_fetch_add_i64 / field_load_i64 on an Atomic[Int64] field
#     6. clear / reserve / resize / set_len_unchecked
#   Movable-gated (T: Movable & Deinitable):
#     7. append growth schedule (4 -> 8 -> 16)
#     8. pop returns the last appended value, or None when empty
#     9. extend merges two slabs, len matches sum
#    10. take_at returns the middle slot and shifts remaining
#    11. swap_remove on an interior index returns that slot in O(1)
#    12. shrink_to_fit reduces capacity to len
#    13. __setitem__ replaces a live slot (destroys the prior)
#
# Negative test (type-level):
#   A call to Slab[NonMovable].append / pop / extend / etc. fails to
#   compile with "no matching method" -- this is the receiver-refinement
#   contract. Documented in the comment block at the bottom.

from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI64
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_collections.slab import Slab


# =============================================================================
# Test types
# =============================================================================


struct AtomicCounter(Deinitable):
    """Non-Movable: contains Atomic fields."""

    var counter: AtomicI64
    var generation: Int


struct SlotWithList(Deinitable, Movable):
    """Movable: heap-owning inner field (canary for stale bytes across destroy-recreate)."""

    var items: List[Int]
    var tag: Int

    def __init__(out self, var items: List[Int], tag: Int):
        self.items = items^
        self.tag = tag


# =============================================================================
# init_fn closures (comptime-specialized, not fn-ptr values)
# =============================================================================


def _zero_atomic_counter(mut slot: AtomicCounter):
    """Single-threaded in-place init of an AtomicCounter slot.

    Assigns fields through the `mut` reference init_slot hands over; no
    pointer is involved.
    """
    slot.counter = AtomicI64(0)
    slot.generation = 0


def _mark_generation_7(mut slot: AtomicCounter):
    """init_fn that writes a value a zero-filled slot cannot hold by chance."""
    slot.counter = AtomicI64(-3)
    slot.generation = 7


# =============================================================================
# field_accessor (comptime fn-parameter; subfield widen)
# =============================================================================


def _consume_like_worker(
    s: Slab[AtomicCounter], wid: Int, delta: Int64
):
    """Immutable-borrow helper that mirrors the `MorselSinkImpl.consume`
    shape: `self` is an immutable borrow, yet the worker mutates its
    own per-worker slot through `get_mut_interior`.

    SAFETY: single-threaded test — disjointness trivially holds. The
    interior-mutability contract (non-Atomic cross-thread access is UB)
    is not stressed here; the test only verifies that the signature
    compiles AND the Atomic write lands. A concurrent-access test is
    deliberately NOT written.
    """
    # SAFETY: wid is in [0, 4) by construction at every call site in
    # test_get_mut_interior_immutable_self_write. The Atomic fetch_add
    # is sound regardless of the non-Atomic cross-thread discipline.
    ref slot = s.get_mut_interior(wid)
    _ = slot.counter.fetch_add(Scalar[DType.int64](delta))


def _counter_accessor[
    o: MutOrigin
](ref [o] v: AtomicCounter) -> ref [o] AtomicI64:
    """Extract .counter from an AtomicCounter slot.

    `v.counter` inside an origin-generic accessor yields
    `ref [o.counter]`, which does NOT unify with the return type
    `ref [o]`. We widen via UnsafePointer(to=...).unsafe_origin_cast[o]()[].

    SAFETY: sound because `v` has origin `o`; sub-field access through
    `v` inherits o-or-tighter liveness. The widen relaxes the origin
    for the compiler; runtime aliasing is unchanged.
    """
    ref inner = v.counter
    return UnsafePointer(to=inner).unsafe_origin_cast[o]()[]


# =============================================================================
# Universal tests (any T)
# =============================================================================


def test_empty_slab() raises:
    """Default-constructed Slab has len/cap=0 and destroys cleanly."""
    var s = Slab[AtomicCounter]()
    assert_equal(s.len(), 0)
    assert_equal(s.capacity(), 0)
    assert_true(s.is_empty())


def test_create_allocates_with_len_and_cap() raises:
    """create_prefilled(n) sets both len and cap to n.

    Semantics: `create(n)` is empty-with-capacity (_len_t=0);
    `create_prefilled(n)` is all-slots-live (_len_t=n, zero-filled bytes).
    """
    var s = Slab[AtomicCounter].create_prefilled(10)
    assert_equal(s.len(), 10)
    assert_equal(s.capacity(), 10)
    # Initialize all slots so __del__ sees valid state.
    for i in range(10):
        s.init_slot[_zero_atomic_counter](i)


def test_init_slot_non_movable() raises:
    """init_slot + __getitem__ on an Atomic-bearing non-Movable T."""
    var s = Slab[AtomicCounter].create_prefilled(4)
    for i in range(4):
        s.init_slot[_zero_atomic_counter](i)

    # After init_slot, __getitem__ on the slab returns a readable ref.
    # Direct field mutation via __getitem__ is NOT supported for non-
    # Movable T (the ref is ref [self._bytes] T). Instead we use the
    # field_fetch_add helper (universal), which does the Atomic op
    # through a widened accessor. Read-back is via the same accessor's
    # load path -- see test_field_fetch_add_load below.
    for i in range(4):
        # load_i64 returns 0 because _zero_atomic_counter wrote 0.
        assert_equal(
            s.field_load_i64[_counter_accessor](i), Int64(0)
        )


def test_init_slot_runs_init_fn_on_that_slot() raises:
    """init_slot calls init_fn on slot idx, and on no other slot.

    The slab is zero-filled, so a zero read-back cannot tell "init_fn ran"
    from "init_fn never ran"; this init_fn writes (-3, 7), which a
    zero-filled slot cannot hold by chance. Catches an init_slot that skips
    the call, or hands init_fn a different slot.
    """
    var s = Slab[AtomicCounter].create_prefilled(3)
    s.init_slot[_mark_generation_7](1)
    assert_equal(s[1].generation, 7, "init_fn did not run on slot 1")
    assert_equal(s.field_load_i64[_counter_accessor](1), Int64(-3))
    assert_equal(s[0].generation, 0, "init_fn wrote slot 0")
    assert_equal(s[2].generation, 0, "init_fn wrote slot 2")
    assert_equal(s.field_load_i64[_counter_accessor](0), Int64(0))


def test_field_fetch_add_load() raises:
    """field_fetch_add_i64 + field_load_i64 on an Atomic[Int64] field."""
    var s = Slab[AtomicCounter].create_prefilled(3)
    for i in range(3):
        s.init_slot[_zero_atomic_counter](i)

    # fetch_add returns the value BEFORE the add (load; add).
    var old0 = s.field_fetch_add_i64[_counter_accessor](0, Int64(5))
    assert_equal(old0, Int64(0))
    var old1 = s.field_fetch_add_i64[_counter_accessor](0, Int64(3))
    assert_equal(old1, Int64(5))
    # Load reflects accumulated value.
    assert_equal(
        s.field_load_i64[_counter_accessor](0), Int64(8)
    )
    # Untouched slots stay 0.
    assert_equal(
        s.field_load_i64[_counter_accessor](1), Int64(0)
    )
    assert_equal(
        s.field_load_i64[_counter_accessor](2), Int64(0)
    )


def test_get_mut_interior_immutable_self_write() raises:
    """Interior-mutability primitive: immutable `self` + mutable slot write.

    `get_mut_interior(self, i) -> ref [MutExternalOrigin] T`
    is the blessed interior-mutability primitive (Mojo analog of C++
    `mutable` / Rust `UnsafeCell<T>`). It powers the
    `MorselSinkImpl.consume(self, worker_id, var morsel)` trait contract:
    the generic executor fans `self` out to multiple worker threads as
    an immutable borrow, each worker writes to its own slot.

    This test calls `get_mut_interior` through a helper that takes `self`
    by immutable borrow — matching the consume-trait shape — and verifies
    the Atomic field write lands and is observable through both the old
    `_mut_ptr` alias and the `field_load_i64` read path.
    """
    # Container-by-value so we can call _consume_like with immutable borrow.
    var s = Slab[AtomicCounter].create_prefilled(4)
    for i in range(4):
        s.init_slot[_zero_atomic_counter](i)

    # Immutable-borrow helper that mirrors consume(self, worker_id, ...).
    # Inside, interior mutability is used to write slot `wid` through
    # `self` despite `self` being an immutable borrow.
    _consume_like_worker(s, 0, Int64(11))
    _consume_like_worker(s, 1, Int64(22))
    _consume_like_worker(s, 2, Int64(33))
    _consume_like_worker(s, 3, Int64(44))

    # Read-back via the universal field_load_i64 helper.
    assert_equal(s.field_load_i64[_counter_accessor](0), Int64(11))
    assert_equal(s.field_load_i64[_counter_accessor](1), Int64(22))
    assert_equal(s.field_load_i64[_counter_accessor](2), Int64(33))
    assert_equal(s.field_load_i64[_counter_accessor](3), Int64(44))


def test_get_mut_interior_matches_mut_ptr_alias() raises:
    """Deprecated `_mut_ptr` alias produces the same observable effect
    as `get_mut_interior` — same wildcard origin, same slot addressing.
    """
    var s1 = Slab[AtomicCounter].create_prefilled(2)
    var s2 = Slab[AtomicCounter].create_prefilled(2)
    for i in range(2):
        s1.init_slot[_zero_atomic_counter](i)
        s2.init_slot[_zero_atomic_counter](i)

    # s1: write via new primitive (ref-returning).
    ref slot1a = s1.get_mut_interior(0)
    _ = slot1a.counter.fetch_add(Scalar[DType.int64](7))
    ref slot1b = s1.get_mut_interior(1)
    _ = slot1b.counter.fetch_add(Scalar[DType.int64](9))

    # s2: write via deprecated alias (pointer-returning).
    var p2a = s2._mut_ptr(0)
    _ = p2a[].counter.fetch_add(Scalar[DType.int64](7))
    var p2b = s2._mut_ptr(1)
    _ = p2b[].counter.fetch_add(Scalar[DType.int64](9))

    # Same results.
    assert_equal(s1.field_load_i64[_counter_accessor](0), Int64(7))
    assert_equal(s1.field_load_i64[_counter_accessor](1), Int64(9))
    assert_equal(s2.field_load_i64[_counter_accessor](0), Int64(7))
    assert_equal(s2.field_load_i64[_counter_accessor](1), Int64(9))


def test_clear_resets_len() raises:
    """clear() sets len=0 but keeps capacity."""
    var s = Slab[SlotWithList]()
    for i in range(3):
        s.append(SlotWithList(List[Int](), i))
    assert_equal(s.len(), 3)
    var cap_before = s.capacity()
    s.clear()
    assert_equal(s.len(), 0)
    # Capacity is preserved -- the byte buffer is kept for future append.
    assert_equal(s.capacity(), cap_before)


def test_reserve_and_resize() raises:
    """reserve grows cap >= len + additional; resize grows cap to target."""
    var s = Slab[SlotWithList]()
    s.reserve(32)
    assert_true(s.capacity() >= 32)
    s.resize(64)
    assert_true(s.capacity() >= 64)


def test_set_len_unchecked_non_movable() raises:
    """set_len_unchecked + init_slot on a non-Movable slab.

    This exercises the "create cap, init each, commit len" pattern
    that morsel-plan fast paths use.
    """
    var s = Slab[AtomicCounter]()
    s.reserve(5)
    # At this point _len_t == 0 but _cap_t >= 5. Init each of the 5 slots.
    for i in range(5):
        s.init_slot[_zero_atomic_counter](i)
    s.set_len_unchecked(5)
    assert_equal(s.len(), 5)
    for i in range(5):
        assert_equal(
            s.field_load_i64[_counter_accessor](i), Int64(0)
        )


# =============================================================================
# Movable-gated tests (T: Movable & Deinitable)
# =============================================================================


def test_append_growth_schedule() raises:
    """10 appends starting from cap=0 reach cap=16 (4 -> 8 -> 16)."""
    var s = Slab[SlotWithList]()
    # From cap=0 the first grow goes to min_cap = 4.
    s.append(SlotWithList(List[Int](), 0))
    assert_equal(s.len(), 1)
    assert_equal(s.capacity(), 4)

    # Fill to cap=4 without triggering another grow.
    s.append(SlotWithList(List[Int](), 1))
    s.append(SlotWithList(List[Int](), 2))
    s.append(SlotWithList(List[Int](), 3))
    assert_equal(s.len(), 4)
    assert_equal(s.capacity(), 4)

    # Next append forces grow to 8.
    s.append(SlotWithList(List[Int](), 4))
    assert_equal(s.len(), 5)
    assert_equal(s.capacity(), 8)

    # Fill to 8, then cross to 16.
    for i in range(5, 8):
        s.append(SlotWithList(List[Int](), i))
    assert_equal(s.len(), 8)
    assert_equal(s.capacity(), 8)

    s.append(SlotWithList(List[Int](), 8))
    s.append(SlotWithList(List[Int](), 9))
    assert_equal(s.len(), 10)
    assert_equal(s.capacity(), 16)

    # Values preserved through grows.
    for i in range(10):
        assert_equal(s[i].tag, i)


def test_pop_empty_returns_none() raises:
    """pop() on empty returns None; no crash."""
    var s = Slab[SlotWithList]()
    var popped = s.pop()
    assert_false(Bool(popped))


def test_pop_returns_last() raises:
    """pop() returns the last appended value and shrinks len by 1."""
    var s = Slab[SlotWithList]()
    s.append(SlotWithList([10, 20], 1))
    s.append(SlotWithList([30, 40], 2))
    assert_equal(s.len(), 2)
    var maybe = s.pop()
    assert_true(Bool(maybe))
    ref popped = maybe.value()
    assert_equal(popped.tag, 2)
    assert_equal(popped.items[0], 30)
    assert_equal(popped.items[1], 40)
    assert_equal(s.len(), 1)


def test_extend_merges_two_slabs() raises:
    """extend merges all elements from `src` into self; len sums."""
    var a = Slab[SlotWithList]()
    a.append(SlotWithList(List[Int](), 1))
    a.append(SlotWithList(List[Int](), 2))

    var b = Slab[SlotWithList]()
    b.append(SlotWithList(List[Int](), 3))
    b.append(SlotWithList(List[Int](), 4))
    b.append(SlotWithList(List[Int](), 5))

    a.extend(b^)
    assert_equal(a.len(), 5)
    for i in range(5):
        assert_equal(a[i].tag, i + 1)


def test_take_at_middle_shifts_remaining() raises:
    """take_at returns the target slot; remaining shifts left."""
    var s = Slab[SlotWithList]()
    for i in range(5):
        s.append(SlotWithList(List[Int](), i))

    var taken = s.take_at(2)
    assert_equal(taken.tag, 2)
    assert_equal(s.len(), 4)
    # Remaining slots: [0, 1, 3, 4]
    assert_equal(s[0].tag, 0)
    assert_equal(s[1].tag, 1)
    assert_equal(s[2].tag, 3)
    assert_equal(s[3].tag, 4)


def test_swap_remove_interior() raises:
    """swap_remove removes an interior slot; last slot moves into its place."""
    var s = Slab[SlotWithList]()
    for i in range(5):
        s.append(SlotWithList(List[Int](), i))

    var taken = s.swap_remove(1)
    assert_equal(taken.tag, 1)
    assert_equal(s.len(), 4)
    # swap_remove moves last (tag=4) into index 1.
    assert_equal(s[0].tag, 0)
    assert_equal(s[1].tag, 4)
    assert_equal(s[2].tag, 2)
    assert_equal(s[3].tag, 3)


def test_shrink_to_fit() raises:
    """shrink_to_fit reduces capacity down to len; elements preserved."""
    var s = Slab[SlotWithList]()
    for i in range(3):
        s.append(SlotWithList(List[Int](), i))
    # After 3 appends from cap=0, cap is 4.
    assert_equal(s.capacity(), 4)
    s.shrink_to_fit()
    assert_equal(s.capacity(), 3)
    assert_equal(s.len(), 3)
    for i in range(3):
        assert_equal(s[i].tag, i)


def test_setitem_replaces_live_slot() raises:
    """__setitem__ destroys the prior value and moves the new one in."""
    var s = Slab[SlotWithList]()
    s.append(SlotWithList([10], 1))
    s.append(SlotWithList([20], 2))
    assert_equal(s[1].tag, 2)

    s[1] = SlotWithList([99], 42)
    assert_equal(s.len(), 2)
    assert_equal(s[1].tag, 42)
    assert_equal(s[1].items[0], 99)


# =============================================================================
# ⛔⛔ DRAIN-UNDER-UNWIND — the accounting hole in a raising bulk drain
# =============================================================================
# `take_slot_unchecked(i)` + a trailing `set_len_unchecked(0)` is the canonical
# bulk drain, and it is UNSOUND the moment the loop body can raise: the length
# fix is a SEPARATE STATEMENT, so an escaping error skips it and the slab
# unwinds still counting the moved-out slots as live. For a heap-owning T the
# destructor then double-frees them.
#
# These two tests pin the two halves as MEASURED FACTS rather than prose. They
# are cheap, they need no engine, and they are what a reader of any
# `take_slot_unchecked` call site should run.


def _drain_helper_that_raises(var v: SlotWithList, fail: Bool) raises -> Int:
    """Consumes `v` and raises — the shape of the engine's UDF helpers
    (`var batch: RecordBatch`, `raises`)."""
    var tag = v.tag
    _ = v^
    if fail:
        raise Error("DRAIN_HELPER_RAISED")
    return tag


def test_take_slot_unchecked_drain_leaves_a_stale_len_when_the_body_raises() raises:
    """⛔ THE HAZARD, MEASURED. After an error escapes the drain, the slab
    still reports EVERY slot live — including the ones already moved out."""
    var s = Slab[SlotWithList]()
    for i in range(3):
        s.append(SlotWithList(List[Int](), i))

    var stale = -1
    try:
        for i in range(s.len()):
            _ = _drain_helper_that_raises(s.take_slot_unchecked(i), i == 1)
        s.set_len_unchecked(0)
    except e:
        stale = s.len()

    # Slots 0 and 1 were moved out; slot 2 was never reached. The slab has no
    # way to know that — the caller owed it a `set_len_unchecked`, and the
    # raise skipped the statement that would have paid it.
    assert_equal(
        stale,
        3,
        "if this is no longer 3, `take_slot_unchecked` began adjusting the"
        " length and the ⛔⛔ clause in its docstring can be lifted —"
        " re-derive that, do not weaken this assertion",
    )
    # ⚠ NEUTRALISE BEFORE THE DROP. Without this the destructor would
    # `destroy_pointee` slots 0 and 1 a SECOND time, which is the double free
    # this whole block is about. Slot 2 leaks instead; a leak in a test is the
    # price of keeping the test defined rather than UB.
    s.set_len_unchecked(0)


def test_replace_drain_keeps_the_len_honest_when_the_body_raises() raises:
    """✅ THE FIX. `replace(i, default)` leaves EVERY slot initialised at
    EVERY point, so the destructor is sound on any unwind path and no
    trailing length fix is owed."""
    var s = Slab[SlotWithList]()
    for i in range(3):
        s.append(SlotWithList(List[Int](), i))

    var after = -1
    try:
        for i in range(s.len()):
            _ = _drain_helper_that_raises(
                s.replace(i, SlotWithList(List[Int](), -1)), i == 1
            )
    except e:
        after = s.len()

    assert_equal(
        after,
        3,
        "`replace` does not shrink the slab — it swaps a default in, so the"
        " length is still 3 and every slot is still INITIALISED",
    )
    # The drained slots hold the default sentinel, not moved-out bytes. That
    # is the property the destructor needs, and it is what makes this drain
    # safe where the one above is not. No neutralisation: `s` drops cleanly.
    assert_equal(s[0].tag, -1, "slot 0 was drained and holds the sentinel")
    assert_equal(s[1].tag, -1, "slot 1 was drained and holds the sentinel")
    assert_equal(s[2].tag, 2, "slot 2 was never reached")


# =============================================================================
# Compile-fail documentation (in-tree proof for receiver refinement)
# =============================================================================
# If you uncomment ANY of the following lines on a Slab[AtomicCounter]
# (which is non-Movable), the compiler emits "no matching method" at the
# call site -- exactly the receiver-refinement contract.
#
#   var s = Slab[AtomicCounter]()                              # OK: universal
#   s.append(AtomicCounter(...))                               # FAILS
#   _ = s.pop()                                                # FAILS
#   _ = s.take_at(0)                                           # FAILS
#   _ = s.swap_remove(0)                                       # FAILS
#   s.shrink_to_fit()                                          # FAILS
#   s.extend(Slab[AtomicCounter]())                            # FAILS
#   s[0] = AtomicCounter(...)                                  # FAILS (__setitem__)
#
# stdlib Span uses the same receiver-refinement path and produces the same
# negative-test diagnostic.


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
