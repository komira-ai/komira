# =============================================================================
# SortBuffer_Untyped
# =============================================================================
#
# Covers:
#   (1) single I64 key ASC + payload (2 sub-tests minimum)
#   (2) composite-2 mixed direction (ASC + DESC) (2 sub-tests)
#   (3) sort with payload columns (1 sub-test)
#   (4) empty input (1 sub-test)
#   (5) large 1000-row stress (1 sub-test)
#
# Plus bonus coverage:
#   - All-DESC single-key sort.
#   - Stable preservation of original order on equal keys.
#
# Encapsulation: tests use ONLY the public surface — no UnsafePointer,
# no wildcard origin, no unsafe_from_address.
# =============================================================================


from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_STRING,
    ROLE_SORT_KEY,
    ROLE_PAYLOAD,
)
from komira_op_sort.sort_buffer_untyped import (
    SortBuffer_Untyped,
    SORT_ASC,
    SORT_DESC,
)
from komira_arrow.batch_view import BatchView

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.string_array import StringArray

from std.testing import TestSuite, assert_equal, assert_true, assert_false


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _single_i64_sort_key() -> List[ColDescriptor]:
    """sort_key_descriptors layout: 1 col I64 sort_key. col_idx_in_storage=0."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_SORT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _composite_2_i64_sort_keys() -> List[ColDescriptor]:
    """sort_key_descriptors layout: 2 cols I64+I64."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_SORT_KEY,
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
            role=ROLE_SORT_KEY,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return l^


def _i64_payload(n_keys: Int, n_payload: Int) -> List[ColDescriptor]:
    """payload_descriptors layout: n_payload I64 cols. col_idx_in_storage
    starts at n_keys."""
    var l = List[ColDescriptor]()
    for i in range(n_payload):
        l.append(
            ColDescriptor(
                name_id=10 + i,
                kind=COL_FIXED,
                dtype_tag=DT_I64,
                role=ROLE_PAYLOAD,
                col_idx_in_batch=n_keys + i,
                col_idx_in_storage=n_keys + i,
                validity_tracked=False,
            )
        )
    return l^


def _no_payload() -> List[ColDescriptor]:
    return List[ColDescriptor]()


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


def _build_recordbatch_i64(values: List[Int64]) raises -> RecordBatch:
    """Single-col RecordBatch helper."""
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


# =============================================================================
# Acceptance gate (1) — single I64 key ASC sort
# =============================================================================


def test_single_i64_key_asc_size() raises:
    """Feed 5 rows, expect n_slots == 5 after."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _no_payload(), 16
    )

    var keys: List[Int64] = [50, 10, 30, 20, 40]
    var rb = _build_recordbatch_i64(keys)
    sb.feed_batch(BatchView(rb))

    assert_equal(sb.n_slots(), 5, "5 rows fed")
    assert_equal(sb.n_sort_keys(), 1, "1 sort key")
    assert_equal(sb.n_payload(), 0, "no payload")


def test_single_i64_key_asc_order() raises:
    """Feed 5 keys, sort, expect ascending order."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _no_payload(), 16
    )

    var keys: List[Int64] = [50, 10, 30, 20, 40]
    var rb = _build_recordbatch_i64(keys)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    var sorted_col = sb.read_sorted_i64(0)
    assert_equal(sorted_col.__len__(), 5, "5 sorted values")
    assert_equal(Int(sorted_col[0]), 10, "smallest first")
    assert_equal(Int(sorted_col[1]), 20, "next ascending")
    assert_equal(Int(sorted_col[2]), 30, "middle")
    assert_equal(Int(sorted_col[3]), 40, "next ascending")
    assert_equal(Int(sorted_col[4]), 50, "largest last")


def test_single_i64_key_desc_order() raises:
    """Single-key DESC sort yields reversed order."""
    var dirs = List[UInt8]()
    dirs.append(SORT_DESC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _no_payload(), 16
    )

    var keys: List[Int64] = [50, 10, 30, 20, 40]
    var rb = _build_recordbatch_i64(keys)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    var sorted_col = sb.read_sorted_i64(0)
    assert_equal(Int(sorted_col[0]), 50, "largest first")
    assert_equal(Int(sorted_col[1]), 40, "next descending")
    assert_equal(Int(sorted_col[2]), 30, "middle")
    assert_equal(Int(sorted_col[3]), 20, "next descending")
    assert_equal(Int(sorted_col[4]), 10, "smallest last")


# =============================================================================
# Acceptance gate (2) — composite-2 mixed direction (ASC + DESC)
# =============================================================================


def test_composite_2_asc_asc_order() raises:
    """Two-key sort both ASC. Primary key first, then secondary."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _composite_2_i64_sort_keys(), dirs^, _no_payload(), 16
    )

    # (k0, k1) tuples: (2, 30), (1, 20), (2, 10), (1, 10), (1, 30)
    # Expected ASC ASC: (1,10), (1,20), (1,30), (2,10), (2,30)
    var k0: List[Int64] = [2, 1, 2, 1, 1]
    var k1: List[Int64] = [30, 20, 10, 10, 30]
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    var rb = _build_recordbatch_i64_n(cols)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    var s_k0 = sb.read_sorted_i64(0)
    var s_k1 = sb.read_sorted_i64(1)
    assert_equal(s_k0.__len__(), 5, "5 rows")
    # (1, 10), (1, 20), (1, 30), (2, 10), (2, 30)
    assert_equal(Int(s_k0[0]), 1, "row0 k0")
    assert_equal(Int(s_k1[0]), 10, "row0 k1")
    assert_equal(Int(s_k0[1]), 1, "row1 k0")
    assert_equal(Int(s_k1[1]), 20, "row1 k1")
    assert_equal(Int(s_k0[2]), 1, "row2 k0")
    assert_equal(Int(s_k1[2]), 30, "row2 k1")
    assert_equal(Int(s_k0[3]), 2, "row3 k0")
    assert_equal(Int(s_k1[3]), 10, "row3 k1")
    assert_equal(Int(s_k0[4]), 2, "row4 k0")
    assert_equal(Int(s_k1[4]), 30, "row4 k1")


def test_composite_2_asc_desc_order() raises:
    """Two-key sort: primary ASC, secondary DESC."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    dirs.append(SORT_DESC)
    var sb = SortBuffer_Untyped(
        _composite_2_i64_sort_keys(), dirs^, _no_payload(), 16
    )

    # (k0, k1) tuples: (2, 30), (1, 20), (2, 10), (1, 10), (1, 30)
    # Expected ASC DESC: (1,30), (1,20), (1,10), (2,30), (2,10)
    var k0: List[Int64] = [2, 1, 2, 1, 1]
    var k1: List[Int64] = [30, 20, 10, 10, 30]
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    var rb = _build_recordbatch_i64_n(cols)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    var s_k0 = sb.read_sorted_i64(0)
    var s_k1 = sb.read_sorted_i64(1)
    # (1,30), (1,20), (1,10), (2,30), (2,10)
    assert_equal(Int(s_k0[0]), 1, "row0 k0")
    assert_equal(Int(s_k1[0]), 30, "row0 k1 (DESC within k0=1)")
    assert_equal(Int(s_k0[1]), 1, "row1 k0")
    assert_equal(Int(s_k1[1]), 20, "row1 k1")
    assert_equal(Int(s_k0[2]), 1, "row2 k0")
    assert_equal(Int(s_k1[2]), 10, "row2 k1")
    assert_equal(Int(s_k0[3]), 2, "row3 k0")
    assert_equal(Int(s_k1[3]), 30, "row3 k1 (DESC within k0=2)")
    assert_equal(Int(s_k0[4]), 2, "row4 k0")
    assert_equal(Int(s_k1[4]), 10, "row4 k1")


# =============================================================================
# Acceptance gate (3) — sort with payload columns
# =============================================================================


def test_sort_with_payload_cols() raises:
    """Sort by single I64 key ASC; payload cols permute with the key."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _i64_payload(1, 2), 16
    )

    # 4 rows: keys [3, 1, 4, 2]; payloads p0 = key * 10, p1 = key * 100.
    var keys: List[Int64] = [3, 1, 4, 2]
    var p0: List[Int64] = [30, 10, 40, 20]
    var p1: List[Int64] = [300, 100, 400, 200]
    var cols = List[List[Int64]]()
    cols.append(keys^)
    cols.append(p0^)
    cols.append(p1^)
    var rb = _build_recordbatch_i64_n(cols)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    # After ASC sort: keys [1, 2, 3, 4]; p0 [10, 20, 30, 40];
    # p1 [100, 200, 300, 400].
    var s_keys = sb.read_sorted_i64(0)
    var s_p0 = sb.read_sorted_i64(1)
    var s_p1 = sb.read_sorted_i64(2)
    assert_equal(Int(s_keys[0]), 1, "sorted key 0")
    assert_equal(Int(s_p0[0]), 10, "p0 follows key 1")
    assert_equal(Int(s_p1[0]), 100, "p1 follows key 1")
    assert_equal(Int(s_keys[1]), 2, "sorted key 1")
    assert_equal(Int(s_p0[1]), 20, "p0 follows key 2")
    assert_equal(Int(s_p1[1]), 200, "p1 follows key 2")
    assert_equal(Int(s_keys[3]), 4, "sorted key 3")
    assert_equal(Int(s_p0[3]), 40, "p0 follows key 4")
    assert_equal(Int(s_p1[3]), 400, "p1 follows key 4")


# =============================================================================
# Acceptance gate (4) — empty input
# =============================================================================


def test_empty_input_finalize_noop() raises:
    """Empty input -> finalize_sort runs without error; n_slots stays 0."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _no_payload(), 16
    )

    assert_equal(sb.n_slots(), 0, "empty pre-finalize")
    sb.finalize_sort()
    assert_equal(sb.n_slots(), 0, "empty post-finalize")
    var sorted_col = sb.read_sorted_i64(0)
    assert_equal(sorted_col.__len__(), 0, "empty sorted col")


# =============================================================================
# Acceptance gate (5) — large 1000-row stress (capacity-grow path)
# =============================================================================


def test_large_1000_row_stress() raises:
    """1000-row feed + sort exercises storage capacity-grow path."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _no_payload(), 16
    )

    # 1000 keys in reverse order — sort must yield ascending [0..999].
    var keys = List[Int64]()
    for i in range(1000):
        keys.append(Int64(999 - i))
    var rb = _build_recordbatch_i64(keys)
    sb.feed_batch(BatchView(rb))

    assert_equal(sb.n_slots(), 1000, "1000 rows fed")
    assert_true(sb.capacity() >= 1000, "capacity grew past initial 16")

    sb.finalize_sort()
    var sorted_col = sb.read_sorted_i64(0)
    assert_equal(sorted_col.__len__(), 1000, "1000 sorted values")
    # Spot-check boundary positions.
    assert_equal(Int(sorted_col[0]), 0, "smallest first")
    assert_equal(Int(sorted_col[500]), 500, "middle is 500")
    assert_equal(Int(sorted_col[999]), 999, "largest last")


# =============================================================================
# Bonus — stability on equal keys
# =============================================================================


def test_stable_on_equal_keys() raises:
    """When all keys equal, post-sort payload preserves insertion order."""
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var sb = SortBuffer_Untyped(
        _single_i64_sort_key(), dirs^, _i64_payload(1, 1), 16
    )

    # 4 rows: all key=5; payloads p0 = [100, 200, 300, 400] in input
    # order. Stable sort: equal keys preserve insertion order.
    var keys: List[Int64] = [5, 5, 5, 5]
    var p0: List[Int64] = [100, 200, 300, 400]
    var cols = List[List[Int64]]()
    cols.append(keys^)
    cols.append(p0^)
    var rb = _build_recordbatch_i64_n(cols)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    var s_p0 = sb.read_sorted_i64(1)
    assert_equal(Int(s_p0[0]), 100, "stable: first stays first")
    assert_equal(Int(s_p0[1]), 200, "stable: second stays second")
    assert_equal(Int(s_p0[2]), 300, "stable: third stays third")
    assert_equal(Int(s_p0[3]), 400, "stable: fourth stays fourth")


# =============================================================================
# Varlen STRING sort coverage.
#
# Validates the byte-lexicographic comparator of the STRING key path.
# =============================================================================


def _single_string_sort_key() -> List[ColDescriptor]:
    """sort_key_descriptors layout: 1 col STRING sort_key. col_idx_in_storage=0."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_VAR_STRING,
            dtype_tag=DT_STRING,
            role=ROLE_SORT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _build_recordbatch_string(
    var values: List[String],
) raises -> RecordBatch:
    """Build a 1-col STRING RecordBatch."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var schema = sb.build()
    var arr = StringArray.from_strings(values^)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_string(arr^))
    return rbb.build(schema^)


def test_single_string_sort_asc() raises:
    """Byte-lexicographic sort, ASC.

    Input:  s = ["carol", "alice", "bob", "alice"]
    Expect: ["alice", "alice", "bob", "carol"] (stable on equal).
    """
    var keys = _single_string_sort_key()
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var payload = List[ColDescriptor]()  # no payload cols
    var sb = SortBuffer_Untyped(keys^, dirs^, payload^, 16)

    var vals = List[String]()
    vals.append(String("carol"))
    vals.append(String("alice"))
    vals.append(String("bob"))
    vals.append(String("alice"))
    var rb = _build_recordbatch_string(vals^)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    assert_equal(sb.n_slots(), 4, "4 slots fed")
    # sorted_indices should give insertion-row-index in sorted order.
    # Verify directly via SortBuffer's indices view; the sorted_indices
    # field is public.
    ref ix = sb.sorted_indices
    # "alice"@1 < "alice"@3 < "bob"@2 < "carol"@0
    assert_equal(ix[0], 1, "first sorted -> orig row 1 (alice)")
    assert_equal(ix[1], 3, "second sorted -> orig row 3 (alice stable)")
    assert_equal(ix[2], 2, "third sorted -> orig row 2 (bob)")
    assert_equal(ix[3], 0, "fourth sorted -> orig row 0 (carol)")


def test_single_string_sort_desc() raises:
    """Byte-lexicographic sort, DESC."""
    var keys = _single_string_sort_key()
    var dirs = List[UInt8]()
    dirs.append(SORT_DESC)
    var payload = List[ColDescriptor]()
    var sb = SortBuffer_Untyped(keys^, dirs^, payload^, 16)

    var vals = List[String]()
    vals.append(String("apple"))
    vals.append(String("zebra"))
    vals.append(String("mango"))
    var rb = _build_recordbatch_string(vals^)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    ref ix = sb.sorted_indices
    # DESC: zebra > mango > apple
    assert_equal(ix[0], 1, "first DESC -> zebra")
    assert_equal(ix[1], 2, "second DESC -> mango")
    assert_equal(ix[2], 0, "third DESC -> apple")


def test_single_string_sort_prefix_equal() raises:
    """A prefix sorts before its extension: 'ab' < 'abc' under ASC.
    """
    var keys = _single_string_sort_key()
    var dirs = List[UInt8]()
    dirs.append(SORT_ASC)
    var payload = List[ColDescriptor]()
    var sb = SortBuffer_Untyped(keys^, dirs^, payload^, 16)

    var vals = List[String]()
    vals.append(String("abc"))
    vals.append(String("ab"))
    vals.append(String("a"))
    var rb = _build_recordbatch_string(vals^)
    sb.feed_batch(BatchView(rb))
    sb.finalize_sort()

    ref ix = sb.sorted_indices
    # ASC: "a" < "ab" < "abc"
    assert_equal(ix[0], 2, "shortest first under ASC")
    assert_equal(ix[1], 1)
    assert_equal(ix[2], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
