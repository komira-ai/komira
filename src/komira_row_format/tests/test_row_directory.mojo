# =============================================================================
# `komira_row_format.row_directory.RowDirectory`: sizing, growth and the
# linear-probe slot mechanics.
# =============================================================================
#
# WHAT THIS PROVES
# ----------------
# The documented sizing rule, worked out by hand: `reserve(n)` gives the
# smallest power of two >= 2n, at least 16, every slot empty (-1). The sizes
# are checked at and either side of the powers of two the rule turns on (8/9,
# 16/17 entries). `ensure_cap` keeps the load factor <= 0.5: no change while
# 2 * n_live <= capacity, the next power of two that holds 2 * n_live
# otherwise (twice when one doubling is not enough), and on a never-sized
# directory it sizes for max(n_live, rows held, 16) entries and indexes every
# row the block already holds.
#
# After every sizing and rehash, each indexed row must be found by walking the
# probe sequence from `slot_for(hash)` through `next_slot` before an empty slot,
# and the directory must hold each row exactly once. Duplicate keys force a
# probe chain; a key whose home slot is the last one forces the chain to wrap
# to slot 0, which pins `(slot + 1) & mask`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_row_format.row_block import RowBlock, _hash_row_bytes
from komira_row_format.row_directory import RowDirectory

comptime _KS = 8  # key_stride: one i64 key per row


def _rows(keys: List[Int64]) raises -> RowBlock:
    var rb = RowBlock.with_capacity(max(len(keys), 1), 0, _KS)
    rb.set_n_rows(len(keys))
    for r in range(len(keys)):
        rb.write_fixed[DType.int64](r, 0, keys[r])
    return rb^


def _found(d: RowDirectory, rb: RowBlock, row: Int) -> Bool:
    """Walk the probe sequence from the row's home slot until `row` or an
    empty slot; at most capacity steps."""
    var slot = d.slot_for(_hash_row_bytes(rb, row, _KS))
    for _ in range(d.capacity()):
        if d.is_empty(slot):
            return False
        if d.get(slot) == row:
            return True
        slot = d.next_slot(slot)
    return False


def _assert_indexes_exactly(d: RowDirectory, rb: RowBlock, n: Int) raises:
    """Rows 0..n-1 are each found by probing and held exactly once; nothing
    else is held."""
    var seen = List[Int](length=n, fill=0)
    var held = 0
    for s in range(d.capacity()):
        if not d.is_empty(s):
            held += 1
            var r = d.get(s)
            assert_true(r >= 0 and r < n, "slot holds row " + String(r))
            seen[r] += 1
    assert_equal(held, n)
    for r in range(n):
        assert_equal(seen[r], 1, "row " + String(r) + " held once")
        assert_true(_found(d, rb, r), "row " + String(r) + " found")


def _insert_all(mut d: RowDirectory, rb: RowBlock, n: Int):
    """Index rows 0..n-1 the way the owning tables drive the slot helpers."""
    for r in range(n):
        var slot = d.slot_for(_hash_row_bytes(rb, r, _KS))
        while not d.is_empty(slot):
            slot = d.next_slot(slot)
        d.set(slot, r)


def _keys(n: Int, base: Int64) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(base + Int64(i) * 7919)
    return out^


def test_empty_shell() raises:
    """A new directory is unsized: mask 0, capacity 1, no slots."""
    var d = RowDirectory()
    assert_false(d.is_initialized())
    assert_equal(d.capacity(), 1)
    assert_equal(len(d.directory), 0)


def test_reserve_sizes_at_power_of_two_edges() raises:
    """reserve(n) is the smallest power of two >= 2n, min 16, all empty."""
    var cases: List[Int] = [0, 1, 8, 9, 16, 17, 32, 33]
    var want: List[Int] = [16, 16, 16, 32, 32, 64, 64, 128]
    for i in range(len(cases)):
        var d = RowDirectory()
        d.reserve(cases[i])
        assert_true(d.is_initialized())
        assert_equal(d.capacity(), want[i], "reserve " + String(cases[i]))
        assert_equal(d.capacity_mask, want[i] - 1)
        assert_equal(len(d.directory), want[i])
        for s in range(want[i]):
            assert_true(d.is_empty(s))
            assert_equal(d.get(s), -1)


def test_slot_helpers() raises:
    """slot_for masks the hash, next_slot wraps from the last slot to 0, set
    and get round-trip, is_empty tracks -1."""
    var d = RowDirectory()
    d.reserve(8)  # 16 slots
    assert_equal(d.slot_for(0x123), 0x3)
    assert_equal(d.slot_for(0xFFFFFFFFFFFFFFFF), 15)
    assert_equal(d.slot_for(16), 0)
    assert_equal(d.next_slot(0), 1)
    assert_equal(d.next_slot(14), 15)
    assert_equal(d.next_slot(15), 0)
    d.set(5, 42)
    assert_equal(d.get(5), 42)
    assert_false(d.is_empty(5))
    assert_true(d.is_empty(4))
    assert_true(d.is_empty(6))


def test_ensure_cap_never_sized_indexes_held_rows() raises:
    """On a never-sized directory ensure_cap sizes for max(n_live, rows held)
    with a floor of 16 entries, and indexes every row the block holds, even
    when n_live is 0."""
    var rb = _rows(_keys(5, 11))
    var d = RowDirectory()
    d.ensure_cap(rb, 0, _KS)
    assert_equal(d.capacity(), 32)  # reserve(16)
    _assert_indexes_exactly(d, rb, 5)

    var d2 = RowDirectory()
    d2.ensure_cap(rb, 40, _KS)
    assert_equal(d2.capacity(), 128)  # reserve(40)
    _assert_indexes_exactly(d2, rb, 5)

    var big = _rows(_keys(20, 3))
    var d3 = RowDirectory()
    d3.ensure_cap(big, 2, _KS)
    assert_equal(d3.capacity(), 64)  # reserve(20): rows held beat n_live
    _assert_indexes_exactly(d3, big, 20)

    var none = _rows(List[Int64]())
    var d4 = RowDirectory()
    d4.ensure_cap(none, 0, _KS)
    assert_equal(d4.capacity(), 32)
    _assert_indexes_exactly(d4, none, 0)


def test_ensure_cap_grows_only_past_half() raises:
    """With 8 rows in 16 slots, n_live 8 changes nothing; n_live 9 doubles to
    32 and rehashes every row; n_live 33 from 32 doubles twice, to 128."""
    var rb = _rows(_keys(8, 101))
    var d = RowDirectory()
    d.reserve(4)
    assert_equal(d.capacity(), 16)
    _insert_all(d, rb, 8)
    var before = d.directory.copy()
    d.ensure_cap(rb, 8, _KS)
    assert_equal(d.capacity(), 16)
    assert_equal(d.directory, before)
    d.ensure_cap(rb, 9, _KS)
    assert_equal(d.capacity(), 32)
    assert_equal(len(d.directory), 32)
    _assert_indexes_exactly(d, rb, 8)
    d.ensure_cap(rb, 16, _KS)
    assert_equal(d.capacity(), 32)
    d.ensure_cap(rb, 33, _KS)
    assert_equal(d.capacity(), 128)
    _assert_indexes_exactly(d, rb, 8)


def test_probe_chain_wraps_on_duplicate_keys() raises:
    """Three rows with one key whose home slot is 31 of 32: they land in
    slots 31, 0, 1 in row order; a rehash keeps them a contiguous chain from
    their new home slot."""
    var probe = RowBlock.with_capacity(1, 0, _KS)
    probe.set_n_rows(1)
    var k = Int64(0)
    while True:
        probe.write_fixed[DType.int64](0, 0, k)
        if (_hash_row_bytes(probe, 0, _KS) & 31) == 31:
            break
        k += 1
    var keys: List[Int64] = [k, k, k]
    var rb = _rows(keys)
    var d = RowDirectory()
    d.ensure_cap(rb, 3, _KS)
    assert_equal(d.capacity(), 32)
    assert_equal(d.get(31), 0)
    assert_equal(d.get(0), 1)
    assert_equal(d.get(1), 2)
    _assert_indexes_exactly(d, rb, 3)
    # Rehash into 64 slots: the home slot is 31 or 63 and the three rows fill
    # it and the two slots after it, wrapping past 63 to 0.
    d.ensure_cap(rb, 17, _KS)
    assert_equal(d.capacity(), 64)
    var home = Int(_hash_row_bytes(rb, 0, _KS)) & 63
    assert_true(home == 31 or home == 63)
    var got = List[Int](length=3, fill=0)
    for j in range(3):
        var r = d.get((home + j) & 63)
        assert_true(r >= 0 and r < 3)
        got[r] += 1
    assert_equal(got, [1, 1, 1])
    _assert_indexes_exactly(d, rb, 3)


def main() raises:
    var s = TestSuite()
    s.test[test_empty_shell]()
    s.test[test_reserve_sizes_at_power_of_two_edges]()
    s.test[test_slot_helpers]()
    s.test[test_ensure_cap_never_sized_indexes_held_rows]()
    s.test[test_ensure_cap_grows_only_past_half]()
    s.test[test_probe_chain_wraps_on_duplicate_keys]()
    s^.run()
