# =============================================================================
# test_byte_hash_agg_table.mojo — Sub-A4.1 byte-keyed HashAggTable tests
# =============================================================================
#
# Direct unit tests for the new byte-keyed dense growing HashAggTable family
# (`ByteHashAggTableF64` / `ByteHashAggTableI64` over the
# `_DenseByteAggDirectory`) which lands STRING / Bytes group-by support per
# an internal doc §6.2 Phase-4 (Sub-A4.1).
#
# These tests mirror `test_dense_hash_agg_table.mojo` structure but exercise
# the byte-keyed path:
#   - 17-group boundary: distinct string keys past the old 16-cap
#   - 50_000 distinct groups (no saturation; ~7 doublings from 2048 init)
#   - resize-correctness: stable group_ids across multiple grow boundaries
#   - SUM vs COUNT routing parity (typed-state separation)
#   - MIN / MAX correctness over many groups
#   - F64-state table correctness
#   - reset clears state
#   - gap6 destroy-recreate stress (50 cycles, >cap groups each)
#   - the 32-bit `keys_offsets` ceiling: an insert whose END offset would not
#     fit is REFUSED before any byte is appended ()
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_engine_operators.stage_primitives.byte_hash_agg_table import (
    BYTE_DENSE_INITIAL_CAPACITY,
    ByteHashAggTableF64,
    ByteHashAggTableI64,
)
from komira_engine_operators.agg.agg_state_slab import (
    CountI64,
    MaxI64,
    MinI64,
    SumF64,
    SumI64,
)


# -----------------------------------------------------------------------------
# Helpers — string ↔ List[UInt8] roundtrip + Span construction
# -----------------------------------------------------------------------------


def _bytes_of(s: String) -> List[UInt8]:
    """Materialize a String into a List[UInt8] (the storage owning origin)."""
    var sb = s.as_bytes()
    var out = List[UInt8](capacity=len(sb))
    for k in range(len(sb)):
        out.append(sb[k])
    return out^


def _key_eq_list(a: List[UInt8], b: List[UInt8]) -> Bool:
    """Element-wise compare for two byte lists (test helper)."""
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


# =============================================================================
# §1 — 17-group boundary
# =============================================================================


def test_byte_17_group_boundary() raises:
    """17 distinct byte keys (`k0` .. `k16`), SUM(value=index). Must yield
    17 distinct dense groups; each group's SUM matches its own index."""
    var table = ByteHashAggTableI64[SumI64]()
    # Build a stable owning buffer for each key so the Span origin is safe.
    var key_buffers = List[List[UInt8]]()
    for k in range(17):
        key_buffers.append(_bytes_of(String("k") + String(k)))

    for k in range(17):
        ref kb = key_buffers[k]
        table.update_scalar(Span(kb), Int64(k))

    assert_equal(table.size(), 17, "17 distinct byte keys -> 17 dense groups")

    # Every group's SUM must equal its own index.
    var seen = List[Bool]()
    for _ in range(17):
        seen.append(False)
    for g in range(table.size()):
        var kbytes = table.key_at(g)
        # Recover the index by re-probing with the stored key bytes.
        ref kb_for_probe = kbytes
        var g_probe = table.lookup_or_insert(Span(kb_for_probe))
        assert_equal(g_probe, g, "key_at round-trips through lookup")
        # Find which test index produced this key by sequential scan.
        var found = -1
        for k in range(17):
            if _key_eq_list(kbytes, key_buffers[k]):
                found = k
        assert_true(found >= 0, "byte key recovered to test domain")
        assert_equal(
            Int(table.finalize_at(g)), found, "group SUM == its own index"
        )
        assert_true(not seen[found], "no duplicate group")
        seen[found] = True
    for k in range(17):
        assert_true(seen[k], "every key 0..16 present")


# =============================================================================
# §2 — 50,000 distinct byte keys (no saturation; ~5 doublings from init)
# =============================================================================


def test_byte_50k_distinct_groups() raises:
    """50,000 distinct byte keys, COUNT per group, each key fed 3 times. Asserts
    n_groups == 50_000 and a sampled set of groups each have COUNT == 3 with
    the correct key. Forces multiple directory grows past the 2048 init cap."""
    var n = 50_000
    var table = ByteHashAggTableI64[CountI64]()
    # Pre-allocate all key buffers — Spans need stable owning origin per row.
    var key_buffers = List[List[UInt8]]()
    for k in range(n):
        key_buffers.append(_bytes_of(String("group_") + String(k)))

    for k in range(n):
        ref kb = key_buffers[k]
        table.update_scalar(Span(kb), Int64(0))
        table.update_scalar(Span(kb), Int64(0))
        table.update_scalar(Span(kb), Int64(0))

    assert_equal(table.size(), n, "50K distinct byte keys -> 50K dense groups")
    assert_true(
        table.capacity() > BYTE_DENSE_INITIAL_CAPACITY,
        "directory must have grown",
    )

    # Re-probe a sample.
    var probe_ks = List[Int]()
    probe_ks.append(0)
    probe_ks.append(1)
    probe_ks.append(15)
    probe_ks.append(16)
    probe_ks.append(17)
    probe_ks.append(2047)
    probe_ks.append(2048)
    probe_ks.append(25_000)
    probe_ks.append(n - 1)
    for i in range(len(probe_ks)):
        var k = probe_ks[i]
        ref kb = key_buffers[k]
        var g = table.lookup_or_insert(Span(kb))
        assert_equal(
            table.size(), n, "lookup of existing key must not insert"
        )
        assert_equal(Int(table.finalize_at(g)), 3, "each key counted 3x")


# =============================================================================
# §3 — resize-correctness across multiple grow boundaries
# =============================================================================


def test_byte_resize_index_stability() raises:
    """Insert keys spanning several grow boundaries, then re-update every
    key. Group_ids must stay stable across resizes so the second-pass
    updates land on the same group — assert each group's SUM == 2*key."""
    var n = 10_000
    var table = ByteHashAggTableI64[SumI64]()
    var key_buffers = List[List[UInt8]]()
    for k in range(n):
        key_buffers.append(_bytes_of(String("k_") + String(k)))

    # First pass: insert each key with value == k.
    for k in range(n):
        ref kb = key_buffers[k]
        table.update_scalar(Span(kb), Int64(k))
    assert_equal(table.size(), n, "n distinct groups after first pass")
    assert_true(
        table.capacity() > BYTE_DENSE_INITIAL_CAPACITY,
        "directory must have grown past initial capacity",
    )

    # Second pass: capture group_ids, re-update; positional stability check.
    for k in range(n):
        ref kb = key_buffers[k]
        var g_before = table.lookup_or_insert(Span(kb))
        table.update_scalar(Span(kb), Int64(k))
        var g_after = table.lookup_or_insert(Span(kb))
        assert_equal(g_before, g_after, "group_id stable across re-probe")

    assert_equal(table.size(), n, "no new groups from second pass")
    for k in range(n):
        ref kb = key_buffers[k]
        var g = table.lookup_or_insert(Span(kb))
        assert_equal(
            Int(table.finalize_at(g)), 2 * k, "SUM == 2*k after two passes"
        )


# =============================================================================
# §4 — multi-agg routing parity (SUM vs COUNT on same key set)
# =============================================================================


def test_byte_multi_agg_routing_parity() raises:
    """Two parallel typed byte tables fed the SAME 3000-key set; SUM and
    COUNT must scatter to their own typed state arrays and agree on groups.
    """
    var n = 3_000
    var sum_table = ByteHashAggTableI64[SumI64]()
    var count_table = ByteHashAggTableI64[CountI64]()
    var key_buffers = List[List[UInt8]]()
    for k in range(n):
        key_buffers.append(_bytes_of(String("kk_") + String(k)))

    for k in range(n):
        ref kb = key_buffers[k]
        sum_table.update_scalar(Span(kb), Int64(k))
        sum_table.update_scalar(Span(kb), Int64(k))
        count_table.update_scalar(Span(kb), Int64(k))
        count_table.update_scalar(Span(kb), Int64(k))

    assert_equal(sum_table.size(), n, "sum table sees n groups")
    assert_equal(count_table.size(), n, "count table sees n groups")

    for k in range(n):
        ref kb = key_buffers[k]
        var gs = sum_table.lookup_or_insert(Span(kb))
        var gc = count_table.lookup_or_insert(Span(kb))
        assert_equal(Int(sum_table.finalize_at(gs)), 2 * k, "SUM == 2*k")
        assert_equal(Int(count_table.finalize_at(gc)), 2, "COUNT == 2")


# =============================================================================
# §5 — MIN / MAX correctness over many groups
# =============================================================================


def test_byte_min_max_past_cap() raises:
    """MIN and MAX over 1000 byte-keyed groups must report true extrema."""
    var n = 1_000
    var min_table = ByteHashAggTableI64[MinI64]()
    var max_table = ByteHashAggTableI64[MaxI64]()
    var key_buffers = List[List[UInt8]]()
    for k in range(n):
        key_buffers.append(_bytes_of(String("g_") + String(k)))

    for k in range(n):
        ref kb = key_buffers[k]
        min_table.update_scalar(Span(kb), Int64(k * 10 + 5))
        min_table.update_scalar(Span(kb), Int64(k * 10))
        max_table.update_scalar(Span(kb), Int64(k * 10))
        max_table.update_scalar(Span(kb), Int64(k * 10 + 5))

    assert_equal(min_table.size(), n, "min table n groups")
    assert_equal(max_table.size(), n, "max table n groups")
    for k in range(n):
        ref kb = key_buffers[k]
        var gmin = min_table.lookup_or_insert(Span(kb))
        var gmax = max_table.lookup_or_insert(Span(kb))
        assert_equal(Int(min_table.finalize_at(gmin)), k * 10, "MIN == k*10")
        assert_equal(
            Int(max_table.finalize_at(gmax)), k * 10 + 5, "MAX == k*10+5"
        )


# =============================================================================
# §6 — F64-state table over many byte-keyed groups
# =============================================================================


def test_byte_f64_agg_many_groups() raises:
    """SumF64 over 3000 byte-keyed groups; each group sums two F64 values."""
    var n = 3_000
    var table = ByteHashAggTableF64[SumF64]()
    var key_buffers = List[List[UInt8]]()
    for k in range(n):
        key_buffers.append(_bytes_of(String("fg_") + String(k)))

    for k in range(n):
        ref kb = key_buffers[k]
        table.update_scalar(Span(kb), Float64(k) + 0.5)
        table.update_scalar(Span(kb), Float64(k) + 0.25)
    assert_equal(table.size(), n, "n F64 byte groups")
    for k in range(n):
        ref kb = key_buffers[k]
        var g = table.lookup_or_insert(Span(kb))
        var expected = (Float64(k) + 0.5) + (Float64(k) + 0.25)
        assert_true(
            table.finalize_at(g) == expected, "F64 SUM exact per group"
        )


# =============================================================================
# §7 — reset clears state
# =============================================================================


def test_byte_reset_clears() raises:
    """`reset` clears the dense directory + side arrays; table is re-usable."""
    var table = ByteHashAggTableI64[SumI64]()
    var key_buffers = List[List[UInt8]]()
    for k in range(100):
        key_buffers.append(_bytes_of(String("rk_") + String(k)))
    for k in range(100):
        ref kb = key_buffers[k]
        table.update_scalar(Span(kb), Int64(k))
    assert_equal(table.size(), 100, "100 byte-keyed groups before reset")

    table.reset()
    assert_equal(table.size(), 0, "0 groups after reset")

    # Re-use: fresh key set, group_ids start at 0 again.
    var fresh_key = _bytes_of(String("fresh"))
    var g = table.lookup_or_insert(Span(fresh_key))
    assert_equal(g, 0, "first post-reset insert -> group_id 0")
    table.update_scalar(Span(fresh_key), Int64(7))
    assert_equal(Int(table.finalize_at(g)), 7, "post-reset SUM correct")


# =============================================================================
# §8 — gap6 destroy-recreate stress
# =============================================================================
#
# A Movable carrier holds the byte-keyed table (the shape RuntimeBreakerState
# uses). Destroy + reconstruct the carrier in a loop; if any wildcard-origin /
# stale-byte hazard existed in the byte-slab storage, a destroy-recreate
# cycle would reinterpret freed bytes (gap6).
# =============================================================================


@fieldwise_init
struct _ByteDenseTableCarrier(Movable):
    """Minimal Movable carrier holding the byte-keyed table — mirrors the
    RuntimeBreakerState ownership shape."""

    var table: ByteHashAggTableI64[SumI64]

    @staticmethod
    def make() -> _ByteDenseTableCarrier:
        return _ByteDenseTableCarrier(table=ByteHashAggTableI64[SumI64]())


def test_byte_gap6_destroy_recreate_stress() raises:
    """Build, populate, drain, drop, and rebuild the carrier across many
    cycles. Each cycle loads >cap groups (forces resize) so the heap-owning
    Lists (keys_data + keys_offsets + cached_hash + directory + slabs) are
    allocated + freed every iteration — the destroy-recreate churn that
    surfaces gap6 stale-byte corruption."""
    var cycles = 50
    var per_cycle = 3_000  # > BYTE_DENSE_INITIAL_CAPACITY forces a grow
    for c in range(cycles):
        var carrier = _ByteDenseTableCarrier.make()
        # Per-cycle key buffers (also test gap6 across cycles).
        var key_buffers = List[List[UInt8]]()
        for k in range(per_cycle):
            key_buffers.append(_bytes_of(String("byte_g_") + String(k)))
        for k in range(per_cycle):
            ref kb = key_buffers[k]
            carrier.table.update_scalar(Span(kb), Int64(k + c))
        assert_equal(
            carrier.table.size(), per_cycle, "groups correct each cycle"
        )
        # Drain-shaped sweep + spot check.
        ref kb0 = key_buffers[0]
        ref kbl = key_buffers[per_cycle - 1]
        var g0 = carrier.table.lookup_or_insert(Span(kb0))
        var glast = carrier.table.lookup_or_insert(Span(kbl))
        assert_equal(Int(carrier.table.finalize_at(g0)), c, "SUM(key0) == c")
        assert_equal(
            Int(carrier.table.finalize_at(glast)),
            (per_cycle - 1) + c,
            "SUM(last key) == key + c",
        )
        # carrier dropped at end of scope -> Lists freed.


# =============================================================================
# §9 — the 32-bit keys_offsets ceiling ()
# =============================================================================
#
# `_DenseByteAggDirectory.keys_offsets` is a `List[UInt32]` of cumulative END
# offsets into `keys_data`, whose length is a 64-bit `Int`. Before the guard the
# append computed `prev_end + UInt32(key_len)` -- a UInt32 add that WRAPS
# silently -- so a slab past 4 GiB recorded an end offset SMALLER than the
# previous one, and `_key_length` / `_key_equal_at` then named a different
# group's bytes (or a negative length). A row-count assertion cannot see it:
# the group count is right and every read stays inside the slab.
#
# ⚠ THE SEEDED OFFSET IS A STAND-IN FOR 4 GiB OF STORED KEYS, NOT A SHORTCUT
# AROUND THE CODE UNDER TEST. The append site reads exactly one number -- the
# recorded end of the last key, `keys_offsets[n_groups]` -- and that is the
# number seeded here. Allocating the real 4 GiB slab in a unit test would
# exercise the same arithmetic at 4 GiB of RSS.


def test_byte_key_offset_ceiling_is_refused() raises:
    """An insert whose END offset would pass 2**32-1 must RAISE -- and must do
    so BEFORE it appends a byte, so the refused call leaves the table exactly
    as it found it.

    Before the guard this call RETURNED group 0 with `keys_offsets[1]`
    wrapped to 5 (0xFFFFFFF0 + 21 mod 2**32): a key whose recorded length is
    `5 - 0xFFFFFFF0`, i.e. negative.
    """
    var table = ByteHashAggTableI64[SumI64]()
    table.dir.keys_offsets[0] = UInt32(0xFFFFFFF0)
    var kb = _bytes_of(String("0123456789ghijkl_over"))  # 21 B > 16 B left
    with assert_raises():
        _ = table.lookup_or_insert(Span(kb))
    assert_equal(table.size(), 0, "a refused insert creates no group")
    assert_equal(len(table.dir.keys_data), 0, "and appends no key byte")
    assert_equal(len(table.dir.keys_offsets), 1, "and no end offset")


def test_byte_key_offset_ceiling_admits_the_last_byte() raises:
    """The guard's other edge: an insert whose end offset is EXACTLY 2**32-1
    is representable and must be admitted. A guard written `>=` would refuse
    the last addressable byte."""
    var table = ByteHashAggTableI64[SumI64]()
    table.dir.keys_offsets[0] = UInt32(0xFFFFFFF0)
    var kb = _bytes_of(String("0123456789ghijk"))  # 15 B -> end 0xFFFFFFFF
    var g = table.lookup_or_insert(Span(kb))
    assert_equal(g, 0)
    assert_equal(table.size(), 1)
    assert_equal(Int(table.dir.keys_offsets[1]), 0xFFFFFFFF)


# =============================================================================
# main
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_byte_17_group_boundary]()
    suite.test[test_byte_50k_distinct_groups]()
    suite.test[test_byte_resize_index_stability]()
    suite.test[test_byte_multi_agg_routing_parity]()
    suite.test[test_byte_min_max_past_cap]()
    suite.test[test_byte_f64_agg_many_groups]()
    suite.test[test_byte_reset_clears]()
    suite.test[test_byte_gap6_destroy_recreate_stress]()
    suite.test[test_byte_key_offset_ceiling_is_refused]()
    suite.test[test_byte_key_offset_ceiling_admits_the_last_byte]()
    suite^.run()
