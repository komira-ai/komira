# =============================================================================
# RowSortSpillState: where the spill files go and when they are gone
# =============================================================================
#
# The spill directory the caller passes holds one sub-directory per spilling
# sort; the tests list it with the filesystem and check that a finalize that
# returns, a finalize that raises and a drop each remove it, that two sorts
# sharing a directory do not collide, and that a budget of 0 never creates the
# directory. Spill files go under $TEST_TMPDIR (unique per test execution).
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
from komira_libc.posix import _read_env

from komira_row_format.row_block import (
    COL_FIXED,
    ColDescriptor,
    DT_I64,
    RowLayout,
)
from komira_row_format.row_sort import RowSortBuffer, SORT_ASC

from komira_op_spill_rows.sort_spill import RowSortSpillState


comptime _R = 16
comptime _B = 6
comptime _BUDGET = 500


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
    var l = RowLayout()
    l.add_key_col(_desc(0))
    l.add_payload_col(_desc(8))
    l.set_fixed_row_stride(16)
    return l^


def _buffer() -> RowSortBuffer:
    var b = RowSortBuffer(8, 16)
    b.add_key_direction(SORT_ASC)
    return b^


def _names(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _cols(x: Int) -> List[Int]:
    var l = List[Int]()
    l.append(x)
    return l^


def _key(j: Int) -> Int64:
    return Int64((j * 37) % 101)


def _batch(b: Int) raises -> RecordBatch:
    var k = List[Int64]()
    var p = List[Int64]()
    for i in range(_R):
        var j = b * _R + i
        k.append(_key(j))
        p.append(Int64(j))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("p", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(k)
    ))
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(p)
    ))
    return rbb.build(sb.build())


def _feed(mut state: RowSortSpillState, mut buf: RowSortBuffer) raises:
    var layout = _layout()
    for b in range(_B):
        var rb = _batch(b)
        buf.feed_batch(BatchView(rb), _cols(0), _cols(1), layout)
        state.maybe_spill_run(buf, layout, _names("k"), _names("p"))


def _finalize(
    var state: RowSortSpillState, mut buf: RowSortBuffer
) raises -> RecordBatch:
    var layout = _layout()
    var dirs: List[UInt8] = [SORT_ASC]
    var out = state^.finalize_with_spill(
        buf, layout, _names("k"), _names("p"), dirs
    )
    assert_true(out, "a result")
    return out.take()


def _check(rb: RecordBatch) raises:
    """Sorted by key, equal keys in input order, every row once."""
    assert_equal(rb.num_rows(), _B * _R)
    for r in range(1, rb.num_rows()):
        var k0 = rb.column_as_primitive_int64(0).load[1](r - 1)[0]
        var k1 = rb.column_as_primitive_int64(0).load[1](r)[0]
        var p0 = rb.column_as_primitive_int64(1).load[1](r - 1)[0]
        var p1 = rb.column_as_primitive_int64(1).load[1](r)[0]
        assert_true(k0 <= k1, "keys ascend at row " + String(r))
        if k0 == k1:
            assert_true(p0 < p1, "equal keys keep input order at " + String(r))


def test_sort_spill_root_is_one_subdirectory_and_gone_after_finalize() raises:
    var dir = _scratch_dir("sort_files_finalize")
    var state = RowSortSpillState(_BUDGET, dir)
    var buf = _buffer()
    _feed(state, buf)
    assert_true(state.num_spilled_runs() >= 2)
    assert_equal(len(listdir(dir)), 1, "one spill root while spilled")
    _check(_finalize(state^, buf))
    assert_equal(len(listdir(dir)), 0, "spill root removed by finalize")


def test_sort_spill_drop_before_finalize_removes_the_files() raises:
    var dir = _scratch_dir("sort_files_drop")
    var state = RowSortSpillState(_BUDGET, dir)
    var buf = _buffer()
    _feed(state, buf)
    assert_true(state.has_spilled())
    _ = state^
    assert_equal(len(listdir(dir)), 0, "spill root removed by drop")


def test_sort_spill_two_states_share_a_directory() raises:
    var dir = _scratch_dir("sort_files_shared")
    var s1 = RowSortSpillState(_BUDGET, dir)
    var s2 = RowSortSpillState(_BUDGET, dir)
    var b1 = _buffer()
    var b2 = _buffer()
    _feed(s1, b1)
    _feed(s2, b2)
    assert_equal(len(listdir(dir)), 2, "one root per state")
    _check(_finalize(s1^, b1))
    assert_equal(len(listdir(dir)), 1)
    _check(_finalize(s2^, b2))
    assert_equal(len(listdir(dir)), 0)


def test_sort_spill_finalize_error_removes_the_files() raises:
    var dir = _scratch_dir("sort_files_error")
    var state = RowSortSpillState(_BUDGET, dir)
    var buf = _buffer()
    _feed(state, buf)
    var root = dir + "/" + listdir(dir)[0]
    var files = listdir(root)
    assert_true(len(files) > 0)
    for i in range(len(files)):
        remove(root + "/" + files[i])
    var raised = False
    try:
        _ = _finalize(state^, buf)
    except:
        raised = True
    assert_true(raised, "an unreadable run is an error")
    assert_equal(len(listdir(dir)), 0, "spill root removed on error")


def test_sort_spill_repeated_cycles_leave_nothing_and_agree() raises:
    var dir = _scratch_dir("sort_files_cycles")
    for cycle in range(10):
        var state = RowSortSpillState(_BUDGET, dir)
        var buf = _buffer()
        _feed(state, buf)
        if cycle % 2 == 0:
            _check(_finalize(state^, buf))
        else:
            assert_true(state.has_spilled())
            _ = state^
        assert_equal(len(listdir(dir)), 0, "cycle " + String(cycle))


def test_sort_spill_budget_zero_never_creates_the_directory() raises:
    var dir = _scratch_dir("sort_files_never")
    var state = RowSortSpillState(0, dir)
    var buf = _buffer()
    _feed(state, buf)
    assert_false(state.has_spilled())
    _check(_finalize(state^, buf))
    assert_false(exists(dir), "the spill directory is created on first spill")


def main() raises:
    var s = TestSuite()
    s.test[test_sort_spill_root_is_one_subdirectory_and_gone_after_finalize]()
    s.test[test_sort_spill_drop_before_finalize_removes_the_files]()
    s.test[test_sort_spill_two_states_share_a_directory]()
    s.test[test_sort_spill_finalize_error_removes_the_files]()
    s.test[test_sort_spill_repeated_cycles_leave_nothing_and_agree]()
    s.test[test_sort_spill_budget_zero_never_creates_the_directory]()
    s^.run()
