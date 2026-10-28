# =============================================================================
# RowHashAggSpillState: where the spill files go and when they are gone
# =============================================================================
#
# The spill directory the caller passes holds one sub-directory per spilling
# aggregate. These tests list it with the filesystem (not through the state)
# and check:
#
#   * spilling creates exactly one root under the passed directory, and a
#     finalize that returns removes it;
#   * a state dropped before finalize removes it;
#   * two spilled states sharing one directory get two roots and both
#     aggregates are right;
#   * a finalize that raises (a chunk file gone) still removes the root;
#   * a state created, spilled, finalized and dropped again and again in one
#     directory gives the same answer every cycle and leaves nothing behind;
#   * a budget of 0 never creates the directory.
#
# Spill files go under $TEST_TMPDIR (unique per test execution).
# =============================================================================

from std.os import listdir, remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.runtime.spill_prefetch import SpillPrefetcher
from komira_libc.posix import _read_env

from komira_row_format.row_block import (
    AGG_SUM_I64,
    COL_FIXED,
    ColDescriptor,
    DT_I64,
    RowHashAggTable,
    RowLayout,
)

from komira_op_spill_rows.agg_spill import RowHashAggSpillState


comptime _G = 100  # distinct keys
comptime _R = 50  # rows per batch
comptime _B = 20  # batches
comptime _BUDGET = 1024


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


def _table() -> RowHashAggTable:
    var t = RowHashAggTable(8, 16)
    t.add_agg(AGG_SUM_I64, 8)
    return t^


def _row_group(j: Int) -> Int:
    return (j * 7) % _G


def _row_value(j: Int) -> Int64:
    return Int64(j % 13) - 6


def _batch(b: Int) raises -> RecordBatch:
    var keys = List[Int64]()
    var vals = List[Int64]()
    for i in range(_R):
        var j = b * _R + i
        keys.append(Int64(_row_group(j)))
        vals.append(_row_value(j))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(keys)
    ))
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    ))
    return rbb.build(sb.build())


def _names(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _one(x: Int) -> List[Int]:
    var l = List[Int]()
    l.append(x)
    return l^


def _feed(mut table: RowHashAggTable, mut state: RowHashAggSpillState) raises:
    var layout = _layout()
    for b in range(_B):
        var rb = _batch(b)
        table.upsert_batch(BatchView(rb), _one(0), _one(1), layout)
        state.maybe_spill_run(table)


def _check(out: Optional[RecordBatch]) raises:
    """Every group once, with the SUM the rows give."""
    assert_true(Bool(out), "a result")
    ref rb = out.value()
    var want = List[Int64]()
    for _ in range(_G):
        want.append(0)
    for j in range(_B * _R):
        want[_row_group(j)] += _row_value(j)
    assert_equal(rb.num_rows(), _G)
    var seen = List[Bool]()
    for _ in range(_G):
        seen.append(False)
    for r in range(rb.num_rows()):
        var g = Int(rb.column_as_primitive_int64(0).load[1](r)[0])
        assert_false(seen[g], "group emitted twice")
        seen[g] = True
        assert_equal(
            rb.column_as_primitive_int64(1).load[1](r)[0],
            want[g],
            "SUM of group " + String(g),
        )


def _finalize(
    mut state: RowHashAggSpillState, mut table: RowHashAggTable
) raises -> Optional[RecordBatch]:
    var layout = _layout()
    var pf = SpillPrefetcher()
    return state.finalize_with_spill(
        table, layout, _names("k"), _names("s"), pf
    )


def test_agg_spill_root_is_one_subdirectory_and_gone_after_finalize() raises:
    """Spilling puts one sub-directory under the passed directory; a finalize
    that returns removes it, and the answer is the in-memory one."""
    var dir = _scratch_dir("agg_files_finalize")
    var state = RowHashAggSpillState(_BUDGET, dir)
    var table = _table()
    _feed(table, state)
    assert_true(state.num_spilled_runs() >= 2)
    assert_equal(len(listdir(dir)), 1, "one spill root while spilled")
    _check(_finalize(state, table))
    assert_equal(len(listdir(dir)), 0, "spill root removed by finalize")


def test_agg_spill_drop_before_finalize_removes_the_files() raises:
    """A state dropped with spilled runs (a cancelled query) leaves no files."""
    var dir = _scratch_dir("agg_files_drop")
    var table = _table()
    var state = RowHashAggSpillState(_BUDGET, dir)
    _feed(table, state)
    assert_true(state.has_spilled())
    assert_equal(len(listdir(dir)), 1)
    _ = state^
    assert_equal(len(listdir(dir)), 0, "spill root removed by drop")


def test_agg_spill_two_states_share_a_directory() raises:
    """Two spilled states over one directory use two roots (their chunk files
    do not collide), and each aggregate is right."""
    var dir = _scratch_dir("agg_files_shared")
    var t1 = _table()
    var t2 = _table()
    var s1 = RowHashAggSpillState(_BUDGET, dir)
    var s2 = RowHashAggSpillState(_BUDGET, dir)
    _feed(t1, s1)
    _feed(t2, s2)
    assert_equal(len(listdir(dir)), 2, "one root per state")
    _check(_finalize(s1, t1))
    assert_equal(len(listdir(dir)), 1, "the other state's root is untouched")
    _check(_finalize(s2, t2))
    assert_equal(len(listdir(dir)), 0)


def test_agg_spill_finalize_error_removes_the_files() raises:
    """A finalize whose run cannot be read raises, and the root is removed
    anyway."""
    var dir = _scratch_dir("agg_files_error")
    var state = RowHashAggSpillState(_BUDGET, dir)
    var table = _table()
    _feed(table, state)
    var root = dir + "/" + listdir(dir)[0]
    var files = listdir(root)
    assert_true(len(files) > 0)
    for i in range(len(files)):
        remove(root + "/" + files[i])
    var raised = False
    try:
        _ = _finalize(state, table)
    except:
        raised = True
    assert_true(raised, "an unreadable run is an error")
    assert_equal(len(listdir(dir)), 0, "spill root removed on error")


def test_agg_spill_repeated_create_spill_finalize_drop_cycles() raises:
    """Twelve fresh states over one directory, alternating finalize and drop:
    each finalizing cycle returns the same answer and none leaves a file."""
    var dir = _scratch_dir("agg_files_cycles")
    for cycle in range(12):
        var table = _table()
        var state = RowHashAggSpillState(_BUDGET, dir)
        _feed(table, state)
        if cycle % 2 == 0:
            _check(_finalize(state, table))
        else:
            assert_true(state.has_spilled())
        _ = state^
        assert_equal(len(listdir(dir)), 0, "cycle " + String(cycle))


def test_agg_spill_budget_zero_never_creates_the_directory() raises:
    var dir = _scratch_dir("agg_files_never")
    var state = RowHashAggSpillState(0, dir)
    var table = _table()
    _feed(table, state)
    assert_false(state.has_spilled())
    _check(_finalize(state, table))
    assert_false(exists(dir), "the spill directory is created on first spill")


def main() raises:
    var s = TestSuite()
    s.test[test_agg_spill_root_is_one_subdirectory_and_gone_after_finalize]()
    s.test[test_agg_spill_drop_before_finalize_removes_the_files]()
    s.test[test_agg_spill_two_states_share_a_directory]()
    s.test[test_agg_spill_finalize_error_removes_the_files]()
    s.test[test_agg_spill_repeated_create_spill_finalize_drop_cycles]()
    s.test[test_agg_spill_budget_zero_never_creates_the_directory]()
    s^.run()
