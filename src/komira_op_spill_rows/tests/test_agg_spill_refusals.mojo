# =============================================================================
# RowHashAggSpillState: what it refuses
# =============================================================================
#
#   * `feed_batch` refuses a batch whose aggregate value column holds a NULL,
#     naming the column, and upserts nothing from it (the row-format hash
#     aggregate ignores validity, komira-ai/komira#1983); a batch without NULLs
#     is folded as before.
#   * a finalize refuses a spilled run whose layout fingerprint is not the
#     live table's (a run written under one layout, restored under another),
#     raising a named error and removing the spill files.
#
# Spill files go under $TEST_TMPDIR (unique per test execution).
# =============================================================================

from std.os import listdir
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.runtime.spill_prefetch import SpillPrefetcher
from komira_libc.posix import _read_env

from komira_row_format.row_block import (
    AGG_MAX_I64,
    AGG_SUM_I64,
    COL_FIXED,
    ColDescriptor,
    DT_I64,
    RowHashAggTable,
    RowLayout,
)

from komira_op_spill_rows.agg_spill import RowHashAggSpillState


def _scratch_dir(name: String) raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d + "/" + name


def _fixed(off: Int) -> ColDescriptor:
    return ColDescriptor(
        kind=COL_FIXED,
        dtype_tag=DT_I64,
        fixed_width=UInt16(8),
        offset_in_row=UInt16(off),
    )


def _layout() raises -> RowLayout:
    var l = RowLayout()
    l.add_key_col(_fixed(0))
    l.add_payload_col(_fixed(8))
    l.set_fixed_row_stride(16)
    return l^


def _table(op: UInt8) -> RowHashAggTable:
    var t = RowHashAggTable(8, 16)
    t.add_agg(op, 8)
    return t^


def _one(x: Int) -> List[Int]:
    var l = List[Int]()
    l.append(x)
    return l^


def _names(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _batch(first_key: Int, n: Int, null_row: Int) raises -> RecordBatch:
    """Keys `first_key ..`, value 1 each; row `null_row` (or none, -1) has a
    NULL value with 99999 stored under it."""
    var keys = PrimitiveArray[DType.int64].allocate_nullable(n)
    var vals = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        keys.set(i, Int64(first_key + i))
        vals.set(i, Int64(1))
    if null_row >= 0:
        vals.set(null_row, Int64(99999))
        vals._set_null(null_row)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("amount", ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](keys^))
    rbb.add_column(Column.from_primitive[DType.int64](vals^))
    return rbb.build(sb.build())


def test_agg_feed_batch_refuses_a_null_aggregate_value_by_column_name() raises:
    """A NULL in the value column is refused, the message names the column
    ('amount'), and the table holds nothing from the refused batch; the clean
    batch before it and the one after it fold normally."""
    var state = RowHashAggSpillState(0, _scratch_dir("agg_null_value"))
    var table = _table(AGG_SUM_I64)
    var layout = _layout()
    var ok = _batch(0, 4, -1)
    state.feed_batch(table, ok, _one(0), _one(1), layout)
    assert_equal(table.n_groups(), 4)

    var bad = _batch(100, 4, 2)
    var refused = False
    var msg = String("")
    try:
        state.feed_batch(table, bad, _one(0), _one(1), layout)
    except e:
        refused = True
        msg = String(e)
    assert_true(refused, "a NULL aggregate value is refused")
    assert_true("amount" in msg, "names the column: " + msg)
    assert_true("NULL" in msg, "says why: " + msg)
    assert_equal(table.n_groups(), 4, "nothing upserted from the refused batch")

    var after = _batch(4, 2, -1)
    state.feed_batch(table, after, _one(0), _one(1), layout)
    assert_equal(table.n_groups(), 6)


def test_agg_restore_refuses_a_run_written_under_another_layout() raises:
    """Runs spilled by a SUM aggregate, finalized by a table that registers MAX
    in the same cell (same row stride, different op tag): the finalize raises
    naming the layout mismatch instead of folding the SUM cells as MAX, and
    the spill root is removed."""
    var dir = _scratch_dir("agg_fingerprint")
    var state = RowHashAggSpillState(1, dir)
    var table = _table(AGG_SUM_I64)
    var layout = _layout()
    for b in range(3):
        var rb = _batch(b * 10, 5, -1)
        state.feed_batch(table, rb, _one(0), _one(1), layout)
    assert_true(state.has_spilled(), "runs spilled")

    var other = _table(AGG_MAX_I64)
    var pf = SpillPrefetcher()
    var raised = False
    var msg = String("")
    try:
        _ = state.finalize_with_spill(
            other, layout, _names("k"), _names("m"), pf
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a layout mismatch is an error")
    assert_true("different layout" in msg, "named error: " + msg)
    assert_equal(len(listdir(dir)), 0, "spill root removed on error")


def test_agg_restore_accepts_a_run_under_its_own_layout() raises:
    """The same runs finalized by a table with the layout they were written
    under restore: the fingerprint check does not refuse a match."""
    var dir = _scratch_dir("agg_fingerprint_ok")
    var state = RowHashAggSpillState(1, dir)
    var table = _table(AGG_SUM_I64)
    var layout = _layout()
    for b in range(3):
        var rb = _batch(b * 10, 5, -1)
        state.feed_batch(table, rb, _one(0), _one(1), layout)
    var pf = SpillPrefetcher()
    var out = state.finalize_with_spill(
        table, layout, _names("k"), _names("s"), pf
    )
    assert_true(Bool(out), "a result")
    assert_equal(out.value().num_rows(), 15)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
