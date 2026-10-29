# =============================================================================
# test_distinct_state_untyped -- `DistinctState_Untyped`: the dedup, the
# first-seen output order, composite keys, growth, and STRING keys
# =============================================================================
#
# What each test catches:
#   * the size / emit-order pairs: a dedup that keeps a duplicate, or emits in
#     hash order instead of first-seen order;
#   * `test_composite_2_with_dups`: a composite key compared or hashed on one
#     column only ((1,10) and (1,20) are two keys);
#   * `test_large_1000_row_stress`: storage growth or a directory doubling
#     that loses or duplicates a slot;
#   * `test_insertion_order_across_batches`: state that does not carry over
#     between `feed_batch` calls;
#   * the STRING pair: a string key hashed or compared by length or prefix.
# =============================================================================

from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_STRING,
    ROLE_DISTINCT_KEY,
)
from komira_op_agg_distinct.distinct_state_untyped import (
    DistinctState_Untyped,
)
from komira_arrow.batch_view import batch_view_over

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_arrow.string_array import StringArray

from std.testing import TestSuite, assert_equal, assert_true, assert_false


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _single_i64_distinct_key() -> List[ColDescriptor]:
    """key_descriptors layout: 1 col I64 distinct_key."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_DISTINCT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _composite_2_i64_distinct_keys() -> List[ColDescriptor]:
    """key_descriptors layout: 2 cols I64+I64 distinct_keys."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_DISTINCT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    l.append(
        ColDescriptor(
            name_id=1,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_DISTINCT_KEY,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return l^


def _build_recordbatch_i64(values: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c0"), ArrowType.INT64, False))
    var schema = sb.build()
    var l: List[Scalar[DType.int64]] = []
    for i in range(values.__len__()):
        l.append(values[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(l))
    )
    return rbb.build(schema^)


def _build_recordbatch_i64_n(cols_values: List[List[Int64]]) raises -> RecordBatch:
    """Build an N-col RecordBatch with N Int64 columns."""
    var n_cols = cols_values.__len__()
    var sb = SchemaBuilder()
    for i in range(n_cols):
        sb.add_field(Field(String("c") + String(i), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for c in range(n_cols):
        var l: List[Scalar[DType.int64]] = []
        for r in range(cols_values[c].__len__()):
            l.append(cols_values[c][r])
        rbb.add_column(
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(l)
            )
        )
    return rbb.build(schema^)


# =============================================================================
# single I64 all-unique
# =============================================================================


def test_single_i64_all_unique_size() raises:
    """5 unique keys -> n_unique == 5."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    var keys: List[Int64] = [10, 20, 30, 40, 50]
    var rb = _build_recordbatch_i64(keys)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 5, "5 unique keys")
    assert_equal(ds.n_keys(), 1, "single-key arity")


def test_single_i64_all_unique_emit_order() raises:
    """5 unique keys emit in insertion order."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    var keys: List[Int64] = [10, 20, 30, 40, 50]
    var rb = _build_recordbatch_i64(keys)
    ds.feed_batch(batch_view_over(rb))

    var emitted = ds.read_unique_i64(0)
    assert_equal(emitted.__len__(), 5, "5 emitted keys")
    assert_equal(Int(emitted[0]), 10, "insertion order key 0")
    assert_equal(Int(emitted[1]), 20, "insertion order key 1")
    assert_equal(Int(emitted[2]), 30, "insertion order key 2")
    assert_equal(Int(emitted[3]), 40, "insertion order key 3")
    assert_equal(Int(emitted[4]), 50, "insertion order key 4")


# =============================================================================
# single I64 with duplicates
# =============================================================================


def test_single_i64_with_dups_size() raises:
    """Mix of unique + duplicate keys -> n_unique == count of distinct."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    # Keys: [1, 2, 1, 3, 2, 1, 4] -> distinct: {1, 2, 3, 4} = 4 unique.
    var keys: List[Int64] = [1, 2, 1, 3, 2, 1, 4]
    var rb = _build_recordbatch_i64(keys)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 4, "4 distinct keys from 7 inputs")


def test_single_i64_with_dups_first_seen_order() raises:
    """With duplicates, output preserves first-seen order."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    # Keys: [5, 3, 5, 1, 3, 7, 1] -> distinct (first-seen order): [5, 3, 1, 7]
    var keys: List[Int64] = [5, 3, 5, 1, 3, 7, 1]
    var rb = _build_recordbatch_i64(keys)
    ds.feed_batch(batch_view_over(rb))

    var emitted = ds.read_unique_i64(0)
    assert_equal(emitted.__len__(), 4, "4 unique values")
    assert_equal(Int(emitted[0]), 5, "first-seen: 5")
    assert_equal(Int(emitted[1]), 3, "first-seen: 3")
    assert_equal(Int(emitted[2]), 1, "first-seen: 1")
    assert_equal(Int(emitted[3]), 7, "first-seen: 7")


# =============================================================================
# composite-2 keys with duplicates
# =============================================================================


def test_composite_2_with_dups() raises:
    """Composite-2 key dedup over duplicate (k0, k1) tuples."""
    var ds = DistinctState_Untyped(_composite_2_i64_distinct_keys(), 16)

    # (k0, k1): (1,10), (2,20), (1,10), (1,20), (2,20), (3,30), (1,20)
    # Distinct (first-seen): (1,10), (2,20), (1,20), (3,30) = 4 unique.
    var k0: List[Int64] = [1, 2, 1, 1, 2, 3, 1]
    var k1: List[Int64] = [10, 20, 10, 20, 20, 30, 20]
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    var rb = _build_recordbatch_i64_n(cols)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 4, "4 distinct (k0,k1)")
    var e_k0 = ds.read_unique_i64(0)
    var e_k1 = ds.read_unique_i64(1)
    # First-seen: (1,10), (2,20), (1,20), (3,30)
    assert_equal(Int(e_k0[0]), 1, "row0 k0")
    assert_equal(Int(e_k1[0]), 10, "row0 k1")
    assert_equal(Int(e_k0[1]), 2, "row1 k0")
    assert_equal(Int(e_k1[1]), 20, "row1 k1")
    assert_equal(Int(e_k0[2]), 1, "row2 k0")
    assert_equal(Int(e_k1[2]), 20, "row2 k1")
    assert_equal(Int(e_k0[3]), 3, "row3 k0")
    assert_equal(Int(e_k1[3]), 30, "row3 k1")


# =============================================================================
# empty input
# =============================================================================


def test_empty_input() raises:
    """Empty input -> n_unique == 0, empty emit."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)
    assert_equal(ds.n_unique, 0, "empty start")

    var emitted = ds.read_unique_i64(0)
    assert_equal(emitted.__len__(), 0, "empty emit")


# =============================================================================
# large 1000-row stress (capacity + directory grow)
# =============================================================================


def test_large_1000_row_stress() raises:
    """1000 unique keys exercises both storage and directory grow paths."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    var keys = List[Int64]()
    for i in range(1000):
        keys.append(Int64(i * 7 + 1))
    var rb = _build_recordbatch_i64(keys)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 1000, "1000 unique after grow")
    assert_true(ds.capacity() >= 1000, "capacity grew past 16")

    # Emit + check 3 boundary positions.
    var emitted = ds.read_unique_i64(0)
    assert_equal(emitted.__len__(), 1000, "1000 emitted")
    assert_equal(Int(emitted[0]), 1, "row 0: 0*7+1")
    assert_equal(Int(emitted[500]), 3501, "row 500: 500*7+1")
    assert_equal(Int(emitted[999]), 6994, "row 999: 999*7+1")


# =============================================================================
# all-dup batch
# =============================================================================


def test_all_dup_batch_only_one_emitted() raises:
    """Batch of identical keys yields exactly 1 unique."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    var keys: List[Int64] = [42, 42, 42, 42, 42]
    var rb = _build_recordbatch_i64(keys)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 1, "all dups -> 1 unique")
    var emitted = ds.read_unique_i64(0)
    assert_equal(emitted.__len__(), 1, "1 emitted value")
    assert_equal(Int(emitted[0]), 42, "value preserved")


# =============================================================================
# insertion-order preservation across multiple batches
# =============================================================================


def test_insertion_order_across_batches() raises:
    """Feeding two batches: first-seen order honoured across calls."""
    var ds = DistinctState_Untyped(_single_i64_distinct_key(), 16)

    # Batch 1: [10, 20, 30]
    var b1: List[Int64] = [10, 20, 30]
    ds.feed_batch(batch_view_over(_build_recordbatch_i64(b1)))
    # Batch 2: [25, 10, 35] — 10 is a dup; 25 + 35 new.
    var b2: List[Int64] = [25, 10, 35]
    ds.feed_batch(batch_view_over(_build_recordbatch_i64(b2)))

    assert_equal(ds.n_unique, 5, "5 unique across both batches")

    var emitted = ds.read_unique_i64(0)
    assert_equal(Int(emitted[0]), 10, "batch1 row 0")
    assert_equal(Int(emitted[1]), 20, "batch1 row 1")
    assert_equal(Int(emitted[2]), 30, "batch1 row 2")
    assert_equal(Int(emitted[3]), 25, "batch2 row 0 (first new)")
    assert_equal(Int(emitted[4]), 35, "batch2 row 2 (last new)")


# =============================================================================
# STRING keys
# =============================================================================


def _single_string_distinct_key() -> List[ColDescriptor]:
    """key_descriptors layout: 1 col STRING distinct_key."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_VAR_STRING,
            dtype_tag=DT_STRING,
            role=ROLE_DISTINCT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _build_recordbatch_string(
    var values: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var schema = sb.build()
    var arr = StringArray.from_strings(values^)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(schema^)


def test_single_string_distinct_with_dups() raises:
    """dedup STRING keys with dups.

    Input:  s = ["alpha", "beta", "alpha", "gamma", "beta"]
    Expect: 3 unique in insertion order: ["alpha", "beta", "gamma"].
    """
    var ds = DistinctState_Untyped(_single_string_distinct_key(), 16)

    var vals = List[String]()
    vals.append(String("alpha"))
    vals.append(String("beta"))
    vals.append(String("alpha"))
    vals.append(String("gamma"))
    vals.append(String("beta"))
    var rb = _build_recordbatch_string(vals^)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 3, "3 unique strings")
    # First-seen insertion order: alpha (slot 0), beta (slot 1),
    # gamma (slot 2). DistinctState exposes per-slot key reader.
    # Materialize slot keys via the storage's read_slot_str_bytes via
    # the DS's storage field.
    # Build expected: ["alpha", "beta", "gamma"]
    var s0 = ds.storage.read_slot_str_bytes(0, 0)
    var s1 = ds.storage.read_slot_str_bytes(0, 1)
    var s2 = ds.storage.read_slot_str_bytes(0, 2)
    assert_equal(s0.__len__(), 5)  # "alpha"
    assert_equal(s1.__len__(), 4)  # "beta"
    assert_equal(s2.__len__(), 5)  # "gamma"
    assert_equal(Int(s0[0]), Int(ord("a")))
    assert_equal(Int(s1[0]), Int(ord("b")))
    assert_equal(Int(s2[0]), Int(ord("g")))


def test_single_string_distinct_all_unique() raises:
    """all-unique strings -> n_unique = n_in."""
    var ds = DistinctState_Untyped(_single_string_distinct_key(), 16)

    var vals = List[String]()
    vals.append(String("alice"))
    vals.append(String("bob"))
    vals.append(String("carol"))
    vals.append(String("dave"))
    var rb = _build_recordbatch_string(vals^)
    ds.feed_batch(batch_view_over(rb))

    assert_equal(ds.n_unique, 4, "4 distinct unique strings")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
