# =============================================================================
# RowSortSpillState: spilled runs merge back in the run sort's order
# =============================================================================
#
# `RowSortBuffer` sorts INT64 keys (ASC or DESC per key) with a stable sort.
# A spill must not change the answer: the merge of the spilled runs and the
# in-memory remainder has to give the same rows in the same order as one
# buffer sorting everything, ties included.
#
#   * order: two keys, the first ASC and the second DESC, with Int64.MIN and
#     Int64.MAX among the values and many full ties; three runs spill and one
#     stays in memory. The result is checked pair by pair against the order
#     (an oracle that does not go through the buffer), against the input rows
#     (every row once), and row for row against the same rows sorted with no
#     spill.
#   * NULL: the buffer has no validity, so a NULL key cannot be ordered there
#     at all. A NULL that reaches it after a spill is either refused by name or
#     kept as a NULL in DuckDB's default place (last, ASC); never sorted as the
#     number under it.
#
# Not here, by construction: NaN. The buffer and its layout are INT64 only
# (`RowSortBuffer.feed_batch` refuses any other key type), so no float reaches
# this spill; float keys spill through `komira_op_sort`'s ExternalSorter, whose
# merge orders NaN above +inf (its own tests pin that).
#
# Spill files go under $TEST_TMPDIR (unique per test execution).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_libc.posix import _read_env

from komira_row_format.row_block import (
    COL_FIXED,
    ColDescriptor,
    DT_I64,
    RowLayout,
)
from komira_row_format.row_sort import RowSortBuffer, SORT_ASC, SORT_DESC

from komira_op_spill_rows.sort_spill import RowSortSpillState


def _scratch_dir(name: String) raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d + "/" + name


def _desc(off: Int) -> ColDescriptor:
    return ColDescriptor(
        kind=COL_FIXED,
        dtype_tag=DT_I64,
        fixed_width=UInt16(8),
        offset_in_row=UInt16(off),
    )


def _layout() raises -> RowLayout:
    """Keys k0 (offset 0) and k1 (offset 8), payload p (offset 16)."""
    var l = RowLayout()
    l.add_key_col(_desc(0))
    l.add_key_col(_desc(8))
    l.add_payload_col(_desc(16))
    l.set_fixed_row_stride(24)
    return l^


def _buffer() -> RowSortBuffer:
    var b = RowSortBuffer(16, 24)
    b.add_key_direction(SORT_ASC)
    b.add_key_direction(SORT_DESC)
    return b^


def _directions() -> List[UInt8]:
    var l: List[UInt8] = [SORT_ASC, SORT_DESC]
    return l^


def _key_names() -> List[String]:
    var l: List[String] = ["k0", "k1"]
    return l^


def _payload_names() -> List[String]:
    var l: List[String] = ["p"]
    return l^


def _key_cols() -> List[Int]:
    var l: List[Int] = [0, 1]
    return l^


def _payload_cols() -> List[Int]:
    var l: List[Int] = [2]
    return l^


comptime _R = 16  # rows per batch
comptime _B = 7  # batches


def _k0(j: Int) -> Int64:
    var m = (j * 3) % 5
    if m == 0:
        return Int64.MIN
    if m == 1:
        return -1
    if m == 2:
        return 0
    if m == 3:
        return 5
    return Int64.MAX


def _k1(j: Int) -> Int64:
    var m = (j * 7) % 3
    if m == 0:
        return Int64.MAX
    if m == 1:
        return 3
    return Int64.MIN


def _col(var vals: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )


def _batch(b: Int) raises -> RecordBatch:
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    var p = List[Int64]()
    for i in range(_R):
        var j = b * _R + i
        k0.append(_k0(j))
        k1.append(_k1(j))
        p.append(Int64(j))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, False))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("p", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(_col(k0^))
    rbb.add_column(_col(k1^))
    rbb.add_column(_col(p^))
    return rbb.build(sb.build())


def _i64(rb: RecordBatch, col: Int, row: Int) raises -> Int64:
    return rb.column_as_primitive_int64(col).load[1](row)[0]


def _sort_all(budget: Int, dir: String) raises -> RecordBatch:
    """Feed every batch with the spill check after each, then finalize."""
    var state = RowSortSpillState(budget, dir)
    var buf = _buffer()
    var layout = _layout()
    for b in range(_B):
        var rb = _batch(b)
        buf.feed_batch(BatchView(rb), _key_cols(), _payload_cols(), layout)
        state.maybe_spill_run(buf, layout, _key_names(), _payload_names())
    if budget > 0:
        # Batches of 16 rows (~42 bytes each with the encoded keys) pass 1000
        # bytes every second batch: three runs spill, the seventh batch stays.
        assert_equal(state.num_spilled_runs(), 3, "spilled runs")
        assert_equal(buf.n_rows(), _R, "rows left in memory")
    else:
        assert_equal(state.num_spilled_runs(), 0)
    var out = state^.finalize_with_spill(
        buf, layout, _key_names(), _payload_names(), _directions()
    )
    assert_true(out, "a result")
    return out.take()


def test_sort_spill_merges_runs_in_the_run_sort_order() raises:
    """Catches a merge that puts the in-memory run before the spilled runs
    (rows with equal keys from the last batch jump ahead of earlier ones, so
    the result is no longer the stable sort) and a merge that ignores a DESC
    key (k1 comes out ascending)."""
    var got = _sort_all(1000, _scratch_dir("sort_order"))
    var n = _R * _B
    assert_equal(got.num_rows(), n, "every row")

    # Every input row exactly once, with its own keys.
    var seen = List[Bool]()
    for _ in range(n):
        seen.append(False)
    for r in range(n):
        var j = Int(_i64(got, 2, r))
        assert_true(j >= 0 and j < n, "a row the input never held")
        assert_true(not seen[j], "row " + String(j) + " emitted twice")
        seen[j] = True
        assert_equal(_i64(got, 0, r), _k0(j), "k0 of row " + String(j))
        assert_equal(_i64(got, 1, r), _k1(j), "k1 of row " + String(j))

    # The order: k0 ASC, then k1 DESC, then input order (stability).
    for r in range(1, n):
        var a0 = _i64(got, 0, r - 1)
        var b0 = _i64(got, 0, r)
        var a1 = _i64(got, 1, r - 1)
        var b1 = _i64(got, 1, r)
        var where = " at output row " + String(r)
        assert_true(a0 <= b0, "k0 ascending" + where)
        if a0 == b0:
            assert_true(a1 >= b1, "k1 descending" + where)
            if a1 == b1:
                assert_true(
                    _i64(got, 2, r - 1) < _i64(got, 2, r),
                    "equal keys keep input order" + where,
                )

    # Row for row the sort with no spill.
    var want = _sort_all(0, _scratch_dir("sort_order_unspilled"))
    for r in range(n):
        for c in range(3):
            assert_equal(_i64(got, c, r), _i64(want, c, r))


def _batch_with_null_k0() raises -> RecordBatch:
    """Rows 1000..1003; row 1 has a NULL k0 with Int64.MIN under it (where a
    sort that read the number would put it first)."""
    var a = PrimitiveArray[DType.int64].allocate_nullable(4)
    for i in range(4):
        a.set(i, Int64(i))
    a.set(1, Int64.MIN)
    a._set_null(1)
    var k1 = List[Int64]()
    var p = List[Int64]()
    for i in range(4):
        k1.append(Int64(0))
        p.append(Int64(1000 + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("p", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](a^))
    rbb.add_column(_col(k1^))
    rbb.add_column(_col(p^))
    return rbb.build(sb.build())


def test_sort_spill_null_key_after_a_spill_is_refused_or_kept() raises:
    """A NULL k0 arriving after runs have spilled: refused by name, or kept
    as NULL and placed last (DuckDB's default for ASC). Catches the NULL coming
    back as the Int64.MIN under it, first in the output."""
    var state = RowSortSpillState(1000, _scratch_dir("sort_null"))
    var buf = _buffer()
    var layout = _layout()
    for b in range(2):
        var rb = _batch(b)
        buf.feed_batch(BatchView(rb), _key_cols(), _payload_cols(), layout)
        state.maybe_spill_run(buf, layout, _key_names(), _payload_names())
    assert_equal(state.num_spilled_runs(), 1)

    var refused = False
    var msg = String("")
    var nb = _batch_with_null_k0()
    try:
        buf.feed_batch(BatchView(nb), _key_cols(), _payload_cols(), layout)
    except e:
        refused = True
        msg = String(e)
    if refused:
        assert_true("NULL" in msg, "refused by name: " + msg)
        return
    var out = state^.finalize_with_spill(
        buf, layout, _key_names(), _payload_names(), _directions()
    )
    var got = out.take()
    var last = got.num_rows() - 1
    assert_true(BatchView(got).col_is_null(0, last), "the NULL kept, last")
    assert_equal(_i64(got, 2, last), 1001, "the NULL row is row 1001")


def main() raises:
    var s = TestSuite()
    s.test[test_sort_spill_merges_runs_in_the_run_sort_order]()
    s.test[test_sort_spill_null_key_after_a_spill_is_refused_or_kept]()
    s^.run()
