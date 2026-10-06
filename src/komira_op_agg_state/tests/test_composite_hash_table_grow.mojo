# =============================================================================
# test_composite_hash_table_grow.mojo — ERR-COMPOSITE-HASH-TABLE-F64-GROW
# =============================================================================
#
# Direct unit tests for the new `_CompositeHashTableF64._grow` path.
# Pre-fix the primitive had a fixed capacity
# (DEFAULT_INITIAL_CAPACITY=16 rounded up to power-of-2) with NO grow
# path — when n_used approached capacity the linear-probe in
# `probe_or_insert` would never find an empty slot, hanging the runtime.
#
# Closes h6's `id4 × id5 → median(v3), stddev_samp(v3)` 10K-group GROUP BY
# at the substrate level. Pre-existing substrate gap that affected the
# whole composite multi-agg family (any composite GROUP BY at realistic
# cardinality > 15 groups).
#
# Coverage:
#   - 17-group boundary: the exact off-by-one past the old 16-cap.
#   - 1000-distinct stress: ensures multiple grow boundaries are traversed
#     correctly (16 → 32 → 64 → ... → 2048) without losing groups.
#   - re-update after grow: a key inserted before the grow must still
#     resolve to its accumulated state after the grow.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.composite_hash_table import (
    CompositeHashTable2F64,
)
from komira_op_agg_state.agg_state_slab import (
    SumF64, KeyHashFnv2, KeyEqElementwise2,
)
from komira_expr.composite_key import ColumnValue, KeyValue2


def _key_i64_i64(a: Int64, b: Int64) -> KeyValue2:
    """Build a 2-component (Int64, Int64) composite key."""
    return KeyValue2(ColumnValue(a), ColumnValue(b))


def test_17_group_boundary_grows_past_cap16() raises:
    """17 distinct (Int64, Int64) keys, SUM Float64 agg.

    Pre-fix: 16-cap primitive saturates at the 16th key; the 17th key
    either folds into bucket 0 (data corruption) OR (more commonly)
    triggers infinite linear-probe.

    Post-fix: grow at 75% load factor (12/16) doubles capacity to 32 at
    the 12th insert; the 17 keys all land in the 32-slot table with
    distinct sums.
    """
    var table = CompositeHashTable2F64[
        SumF64, KeyHashFnv2, KeyEqElementwise2,
    ].new(16)

    for k in range(17):
        var key = _key_i64_i64(Int64(k), Int64(k * 100))
        table.update_scalar(key, Float64(k + 1))

    # All 17 keys must be present with their distinct sums.
    assert_equal(
        table.n_used, 17,
        "17 distinct composite keys -> 17 occupied buckets (no saturation"
        " after grow)",
    )
    # Cap must have grown beyond 16.
    assert_true(
        table.capacity > 16,
        "capacity must have grown beyond 16 after crossing 75% load factor",
    )


def test_1000_distinct_keys_multi_grow() raises:
    """1000 distinct composite keys, SUM Float64 agg.

    Starting at cap=16, the grow path must fire log2(1000/16)+1 ≈ 7
    times (16 → 32 → 64 → 128 → 256 → 512 → 1024 → 2048). All keys must
    survive each rehash with their accumulated sums intact.
    """
    var table = CompositeHashTable2F64[
        SumF64, KeyHashFnv2, KeyEqElementwise2,
    ].new(16)

    for k in range(1000):
        var key = _key_i64_i64(Int64(k), Int64(k % 7))
        table.update_scalar(key, Float64(1.0))

    assert_equal(
        table.n_used, 1000,
        "1000 distinct composite keys must all be inserted after"
        " multi-grow cycle",
    )
    assert_true(
        table.capacity >= 2048,
        "capacity must reach >=2048 (next power-of-2 past 1000) after"
        " grow cycle",
    )


def test_re_update_after_grow_preserves_state() raises:
    """A key inserted BEFORE the grow boundary must still hash to a
    slot whose accumulated state survives the grow's rehash.

    Insert keys 0..30 (each with value k+1); after grow, re-feed key 5
    with value 100 and assert finalize_at returns the accumulated 5+1+100
    = 106 (the original sum + the post-grow update).
    """
    var table = CompositeHashTable2F64[
        SumF64, KeyHashFnv2, KeyEqElementwise2,
    ].new(16)

    # Insert 31 distinct keys — triggers at least one grow.
    for k in range(31):
        var key = _key_i64_i64(Int64(k), Int64(k * 10))
        table.update_scalar(key, Float64(k + 1))

    # Re-update key 5: it must resolve to the same accumulated state
    # (now at a new slot post-grow).
    var key5 = _key_i64_i64(Int64(5), Int64(50))
    table.update_scalar(key5, Float64(100.0))

    # Locate key 5's slot (probe_or_insert returns the same slot every
    # time for the same key).
    var hash5 = CompositeHashTable2F64[
        SumF64, KeyHashFnv2, KeyEqElementwise2,
    ].KS.hash_key(key5)
    var slot5 = table.probe_or_insert(key5, hash5)
    # finalize_at returns the SUM aggregate state.
    var val = table.finalize_at(slot5)
    # Expected: 5+1 (initial update_scalar inserted with value 6) + 100
    # (post-grow re-update) = 106.
    assert_equal(
        Int(val), 106,
        "key 5's accumulated SUM state must survive the grow rehash"
        " (pre-grow 6 + post-grow 100 = 106)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
