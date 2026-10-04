# =============================================================================
# Regression tests
# =============================================================================
#
# Tests the arrow_row byte-lex comparator wire-in to
# `RowSortBuffer.finalize_sort` at
# `komira_row_format.row_sort`.
#
# Coverage:
#   (1) single I64 key ASC + I64 payload (5 rows)
#   (2) single I64 key DESC (5 rows)
#   (3) composite-2 I64 keys mixed ASC+DESC (5 rows)
#   (4) empty input (n_rows=0; finalize is a no-op)
#   (5) 1000-row stress: LCG-generated keys; verify monotone after sort
#
# These exercise the new code path:
#   - `_encoded_keys` field populated at feed_batch via
#     encode_row_keys_for_sort.
#   - `finalize_sort` insertion-sort comparator using
#     arrow_row_compare(_encoded_keys[a], _encoded_keys[b]).
#
# Encapsulation: tests use ONLY the public surface — no UnsafePointer,
# no wildcard origin, no unsafe_from_address.
# =============================================================================


from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, SchemaBuilder
from komira_core.collections.batch_view import BatchView

from komira_row_format.row_sort import (
    RowSortBuffer,
    SORT_ASC,
    SORT_DESC,
)
from komira_row_format.row_block import (
    RowLayout,
    ColDescriptor,
    COL_FIXED,
    DT_I64,
)


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _i64_col_desc(offset_in_row: Int) -> ColDescriptor:
    """Build a COL_FIXED DT_I64 descriptor at the given row offset."""
    return ColDescriptor(
        kind=COL_FIXED,
        dtype_tag=DT_I64,
        fixed_width=UInt16(8),
        offset_in_row=UInt16(offset_in_row),
    )


def _layout_n_keys_m_payloads(n_keys: Int, n_payloads: Int) raises -> RowLayout:
    """Build a RowLayout with n_keys I64 keys + n_payloads I64 payloads.
    Each cell is 8 bytes; running offsets follow.
    """
    var l = RowLayout()
    var off = 0
    for _ in range(n_keys):
        l.add_key_col(_i64_col_desc(off))
        off = off + 8
    for _ in range(n_payloads):
        l.add_payload_col(_i64_col_desc(off))
        off = off + 8
    l.set_fixed_row_stride(off)
    return l^


def _build_rb_i64_cols(cols: List[List[Int64]]) raises -> RecordBatch:
    """Build a multi-col Int64 RecordBatch from parallel lists."""
    var n_cols = cols.__len__()
    var sb = SchemaBuilder()
    for i in range(n_cols):
        sb.add_field(Field(String("c") + String(i), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for c in range(n_cols):
        var l: List[Scalar[DType.int64]] = []
        for r in range(cols[c].__len__()):
            l.append(cols[c][r])
        rbb.add_column(
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(l)
            )
        )
    return rbb.build(schema^)


# -----------------------------------------------------------------------------
# Acceptance gate (1) — single I64 key ASC + I64 payload
# -----------------------------------------------------------------------------


def test_single_i64_key_asc_with_payload() raises:
    """Feed 5 (key, payload) rows; expect sorted_indices in ASC order
    over the key. Payload is read out via emit_to_record_batch."""
    var layout = _layout_n_keys_m_payloads(1, 1)
    var key_stride = 8
    var buf = RowSortBuffer(key_stride, layout.fixed_row_stride)
    buf.add_key_direction(SORT_ASC)

    # (key, payload) tuples: (50, 500), (10, 100), (30, 300), (20, 200), (40, 400)
    var keys: List[Int64] = [50, 10, 30, 20, 40]
    var pays: List[Int64] = [500, 100, 300, 200, 400]
    var cols = List[List[Int64]]()
    cols.append(keys^)
    cols.append(pays^)
    var rb = _build_rb_i64_cols(cols)
    var bv = BatchView(rb)

    var key_idxs = List[Int]()
    key_idxs.append(0)
    var pay_idxs = List[Int]()
    pay_idxs.append(1)

    buf.feed_batch(bv, key_idxs, pay_idxs, layout)
    assert_equal(buf.n_rows(), 5, "5 rows fed")

    buf.finalize_sort(layout)

    var key_names = List[String]()
    key_names.append(String("k"))
    var pay_names = List[String]()
    pay_names.append(String("p"))
    var maybe_out = buf.emit_to_record_batch(layout, key_names, pay_names)
    assert_true(maybe_out, "emit returned Some")
    var out = maybe_out.take()
    # Expected ASC: keys [10, 20, 30, 40, 50] → payloads [100, 200, 300, 400, 500]
    var k_arr = out.column_as_primitive_int64(0)
    var p_arr = out.column_as_primitive_int64(1)
    assert_equal(Int(k_arr.get(0)), 10, "key[0]")
    assert_equal(Int(k_arr.get(1)), 20, "key[1]")
    assert_equal(Int(k_arr.get(2)), 30, "key[2]")
    assert_equal(Int(k_arr.get(3)), 40, "key[3]")
    assert_equal(Int(k_arr.get(4)), 50, "key[4]")
    assert_equal(Int(p_arr.get(0)), 100, "pay[0]")
    assert_equal(Int(p_arr.get(1)), 200, "pay[1]")
    assert_equal(Int(p_arr.get(2)), 300, "pay[2]")
    assert_equal(Int(p_arr.get(3)), 400, "pay[3]")
    assert_equal(Int(p_arr.get(4)), 500, "pay[4]")


# -----------------------------------------------------------------------------
# Acceptance gate (2) — single I64 key DESC
# -----------------------------------------------------------------------------


def test_single_i64_key_desc() raises:
    """5 keys, DESC sort, no payload. DESC direction is baked into the
    arrow_row encoding (per-key bit-invert); comparator stays ASC."""
    var layout = _layout_n_keys_m_payloads(1, 0)
    var buf = RowSortBuffer(8, layout.fixed_row_stride)
    buf.add_key_direction(SORT_DESC)

    var keys: List[Int64] = [50, 10, 30, 20, 40]
    var cols = List[List[Int64]]()
    cols.append(keys^)
    var rb = _build_rb_i64_cols(cols)
    var bv = BatchView(rb)

    var key_idxs = List[Int]()
    key_idxs.append(0)
    var pay_idxs = List[Int]()

    buf.feed_batch(bv, key_idxs, pay_idxs, layout)
    buf.finalize_sort(layout)

    var key_names = List[String]()
    key_names.append(String("k"))
    var pay_names = List[String]()
    var maybe_out = buf.emit_to_record_batch(layout, key_names, pay_names)
    assert_true(maybe_out, "emit returned Some")
    var out = maybe_out.take()
    var k_arr = out.column_as_primitive_int64(0)

    # Expected DESC: [50, 40, 30, 20, 10]
    assert_equal(Int(k_arr.get(0)), 50, "key[0]")
    assert_equal(Int(k_arr.get(1)), 40, "key[1]")
    assert_equal(Int(k_arr.get(2)), 30, "key[2]")
    assert_equal(Int(k_arr.get(3)), 20, "key[3]")
    assert_equal(Int(k_arr.get(4)), 10, "key[4]")


# -----------------------------------------------------------------------------
# Acceptance gate (3) — composite-2 I64 keys mixed ASC+DESC
# -----------------------------------------------------------------------------


def test_composite_2_keys_asc_desc() raises:
    """Two-key sort, key0 ASC + key1 DESC, no payload.

    (k0, k1) tuples: (2, 30), (1, 20), (2, 10), (1, 10), (1, 30)
    Expected (k0 ASC, k1 DESC): (1,30), (1,20), (1,10), (2,30), (2,10)
    """
    var layout = _layout_n_keys_m_payloads(2, 0)
    var buf = RowSortBuffer(16, layout.fixed_row_stride)
    buf.add_key_direction(SORT_ASC)
    buf.add_key_direction(SORT_DESC)

    var k0: List[Int64] = [2, 1, 2, 1, 1]
    var k1: List[Int64] = [30, 20, 10, 10, 30]
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    var rb = _build_rb_i64_cols(cols)
    var bv = BatchView(rb)

    var key_idxs = List[Int]()
    key_idxs.append(0)
    key_idxs.append(1)
    var pay_idxs = List[Int]()

    buf.feed_batch(bv, key_idxs, pay_idxs, layout)
    buf.finalize_sort(layout)

    var key_names = List[String]()
    key_names.append(String("k0"))
    key_names.append(String("k1"))
    var pay_names = List[String]()
    var maybe_out = buf.emit_to_record_batch(layout, key_names, pay_names)
    assert_true(maybe_out, "emit returned Some")
    var out = maybe_out.take()
    var s_k0 = out.column_as_primitive_int64(0)
    var s_k1 = out.column_as_primitive_int64(1)

    # Expected: (1,30), (1,20), (1,10), (2,30), (2,10)
    assert_equal(Int(s_k0.get(0)), 1, "row0 k0")
    assert_equal(Int(s_k1.get(0)), 30, "row0 k1")
    assert_equal(Int(s_k0.get(1)), 1, "row1 k0")
    assert_equal(Int(s_k1.get(1)), 20, "row1 k1")
    assert_equal(Int(s_k0.get(2)), 1, "row2 k0")
    assert_equal(Int(s_k1.get(2)), 10, "row2 k1")
    assert_equal(Int(s_k0.get(3)), 2, "row3 k0")
    assert_equal(Int(s_k1.get(3)), 30, "row3 k1")
    assert_equal(Int(s_k0.get(4)), 2, "row4 k0")
    assert_equal(Int(s_k1.get(4)), 10, "row4 k1")


# -----------------------------------------------------------------------------
# Acceptance gate (4) — empty input
# -----------------------------------------------------------------------------


def test_empty_input_finalize_noop() raises:
    """Buffer never fed; finalize_sort must not crash. emit returns None
    or Some(rb-with-0-rows). The buffer's _encoded_keys list is empty,
    so the new length-mismatch guard does NOT fire (n_rows=0 ≤ 1 fast
    path)."""
    var layout = _layout_n_keys_m_payloads(1, 0)
    var buf = RowSortBuffer(8, layout.fixed_row_stride)
    buf.add_key_direction(SORT_ASC)

    # No feed_batch call — buffer has 0 rows.
    buf.finalize_sort(layout)
    assert_equal(buf.n_rows(), 0, "n_rows=0")

    var key_names = List[String]()
    key_names.append(String("k"))
    var pay_names = List[String]()
    var maybe_out = buf.emit_to_record_batch(layout, key_names, pay_names)
    # emit_to_record_batch returns None for n_rows==0.
    assert_true(not maybe_out, "emit returned None for empty buffer")


# -----------------------------------------------------------------------------
# Acceptance gate (5) — 1000-row stress with LCG-generated keys
# -----------------------------------------------------------------------------


def test_large_1000_row_stress() raises:
    """Generate 1000 keys via LCG; sort ASC; verify monotone non-
    decreasing. Exercises the insertion-sort O(N^2) compare loop on
    the new byte-lex comparator at scale."""
    var layout = _layout_n_keys_m_payloads(1, 0)
    var buf = RowSortBuffer(8, layout.fixed_row_stride)
    buf.add_key_direction(SORT_ASC)

    var n = 1000
    var keys = List[Int64](capacity=n)
    var seed: UInt64 = UInt64(0xDEADBEEFCAFEBABE)
    for _ in range(n):
        seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        # Reinterpret high 32 bits as signed.
        keys.append(Int64(Int(seed >> 32)))

    var cols = List[List[Int64]]()
    cols.append(keys^)
    var rb = _build_rb_i64_cols(cols)
    var bv = BatchView(rb)

    var key_idxs = List[Int]()
    key_idxs.append(0)
    var pay_idxs = List[Int]()

    buf.feed_batch(bv, key_idxs, pay_idxs, layout)
    assert_equal(buf.n_rows(), n, "n rows fed")
    buf.finalize_sort(layout)

    var key_names = List[String]()
    key_names.append(String("k"))
    var pay_names = List[String]()
    var maybe_out = buf.emit_to_record_batch(layout, key_names, pay_names)
    assert_true(maybe_out, "emit returned Some")
    var out = maybe_out.take()
    var s = out.column_as_primitive_int64(0)

    # Verify monotone non-decreasing.
    var prev = Int(s.get(0))
    for i in range(1, n):
        var cur = Int(s.get(i))
        assert_true(prev <= cur, "monotone ASC at index " + String(i))
        prev = cur


# -----------------------------------------------------------------------------
# Bonus — stability check on tied composite keys
# -----------------------------------------------------------------------------


def test_stable_on_equal_keys_via_payload() raises:
    """Feed rows with all-equal sort keys + distinct payloads; verify
    that the post-sort payload order matches the input order (insertion
    sort is stable; arrow_row_compare returns 0 on equal keys so the
    insertion-sort inner-loop break preserves input order).
    """
    var layout = _layout_n_keys_m_payloads(1, 1)
    var buf = RowSortBuffer(8, layout.fixed_row_stride)
    buf.add_key_direction(SORT_ASC)

    # All keys = 7; payloads are sequential markers.
    var keys: List[Int64] = [7, 7, 7, 7, 7]
    var pays: List[Int64] = [1, 2, 3, 4, 5]
    var cols = List[List[Int64]]()
    cols.append(keys^)
    cols.append(pays^)
    var rb = _build_rb_i64_cols(cols)
    var bv = BatchView(rb)

    var key_idxs = List[Int]()
    key_idxs.append(0)
    var pay_idxs = List[Int]()
    pay_idxs.append(1)

    buf.feed_batch(bv, key_idxs, pay_idxs, layout)
    buf.finalize_sort(layout)

    var key_names = List[String]()
    key_names.append(String("k"))
    var pay_names = List[String]()
    pay_names.append(String("p"))
    var maybe_out = buf.emit_to_record_batch(layout, key_names, pay_names)
    assert_true(maybe_out, "emit returned Some")
    var out = maybe_out.take()
    var p_arr = out.column_as_primitive_int64(1)
    # Stable: input order [1,2,3,4,5] preserved.
    assert_equal(Int(p_arr.get(0)), 1, "stable pay[0]")
    assert_equal(Int(p_arr.get(1)), 2, "stable pay[1]")
    assert_equal(Int(p_arr.get(2)), 3, "stable pay[2]")
    assert_equal(Int(p_arr.get(3)), 4, "stable pay[3]")
    assert_equal(Int(p_arr.get(4)), 5, "stable pay[4]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
