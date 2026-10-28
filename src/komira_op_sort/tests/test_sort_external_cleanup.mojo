# =============================================================================
# ExternalSorter: spill files are removed when the sort succeeds, fails or is
# dropped before `finish`
# =============================================================================
#
# Each case spills at least one run into a directory the test owns, checks the
# spill is on disk while the sorter lives (so an empty directory afterwards
# means something removed it), then checks nothing is left.
# =============================================================================

from std.os import listdir, remove
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_libc.posix import _read_env
from komira_op_sort.sort_external import ExternalSorter


def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _batch(var values: List[Int64]) raises -> RecordBatch:
    var col = Column.from_primitive(PrimitiveArray[DType.int64].from_list(values^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


def _sorter(dir: String) raises -> ExternalSorter:
    var names: List[String] = ["k"]
    var dirs: List[Bool] = [False]
    return ExternalSorter.create(
        memory_budget=1,
        key_names=names^,
        descending=dirs^,
        spill_dir=dir,
    )


def _absorb_three(mut s: ExternalSorter) raises:
    s.absorb(_batch([Int64(9), Int64(2)]))
    s.absorb(_batch([Int64(4), Int64(1)]))
    s.absorb(_batch([Int64(3), Int64(5)]))


def test_spill_removed_after_finish() raises:
    var dir = _scratch_dir() + "/cleanup_finish"
    var s = _sorter(dir)
    _absorb_three(s)
    assert_equal(len(listdir(dir)), 1)
    var out = s^.finish()
    assert_true(len(out) > 0)
    assert_equal(len(listdir(dir)), 0)


def _absorb_and_drop(dir: String) raises:
    var s = _sorter(dir)
    _absorb_three(s)
    assert_equal(len(listdir(dir)), 1)
    # The sorter is still in use here, so it is dropped at the end of this
    # function and not before the check above.
    s.absorb(_batch([Int64(7)]))


def test_spill_removed_when_dropped_before_finish() raises:
    var dir = _scratch_dir() + "/cleanup_drop"
    _absorb_and_drop(dir)
    assert_equal(len(listdir(dir)), 0)


def test_spill_removed_when_finish_fails() raises:
    var dir = _scratch_dir() + "/cleanup_fail"
    var s = _sorter(dir)
    _absorb_three(s)
    var roots = listdir(dir)
    assert_equal(len(roots), 1)
    var root = dir + "/" + roots[0]
    var chunks = listdir(root)
    assert_true(len(chunks) > 1)
    # Lose one chunk: restoring the run must fail.
    remove(root + "/" + chunks[0])
    var failed = False
    try:
        _ = s^.finish()
    except:
        failed = True
    assert_true(failed)
    assert_equal(len(listdir(dir)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
