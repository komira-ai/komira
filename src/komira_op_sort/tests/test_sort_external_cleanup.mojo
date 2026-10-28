# =============================================================================
# ExternalSorter: spill files are removed when the sort succeeds, fails or is
# dropped before `finish`; the spill directory is created only when something
# spills, under a name that no other live sorter or existing directory has
# =============================================================================
#
# Each case spills at least one run into a directory the test owns, checks the
# spill is on disk while the sorter lives (so an empty directory afterwards
# means something removed it), then checks nothing is left.
# =============================================================================

from std.os import listdir, mkdir, remove, rmdir
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_collections.slab import Slab
from komira_libc.posix import _read_env
from komira_op_sort.sort_external import ExternalSorter, create_spill_root


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


def _sorter_budget(dir: String, budget: Int, out_rows: Int = 8192) raises -> ExternalSorter:
    var names: List[String] = ["k"]
    var dirs: List[Bool] = [False]
    return ExternalSorter.create(
        memory_budget=budget,
        key_names=names^,
        descending=dirs^,
        spill_dir=dir,
        output_batch_size=out_rows,
    )


def test_budget_zero_never_creates_a_spill_directory() raises:
    """Budget 0 means never spill: many batches later, and after `finish`,
    the spill directory does not exist."""
    var dir = _scratch_dir() + "/budget_zero"
    var s = _sorter_budget(dir, 0)
    for i in range(20):
        s.absorb(_batch([Int64(20 - i), Int64(i)]))
    assert_true(not exists(dir))
    var out = s^.finish()
    assert_equal(len(_keys(out^)), 40)
    assert_true(not exists(dir))


def test_in_memory_tail_alone_does_not_touch_the_directory() raises:
    """A budget the input never exceeds: nothing spills, nothing is created."""
    var dir = _scratch_dir() + "/tail_only"
    var s = _sorter_budget(dir, 1 << 30)
    _absorb_three(s)
    assert_true(not exists(dir))
    _ = s^.finish()
    assert_true(not exists(dir))


def test_two_live_sorters_use_different_roots() raises:
    """Two sorters spilling under one directory at the same time each get a
    root of their own and each returns its own rows."""
    var dir = _scratch_dir() + "/two_live"
    var a = _sorter(dir)
    var b = _sorter(dir)
    a.absorb(_batch([Int64(9), Int64(2)]))
    b.absorb(_batch([Int64(90), Int64(20)]))
    a.absorb(_batch([Int64(4), Int64(1)]))
    b.absorb(_batch([Int64(40), Int64(10)]))
    assert_equal(len(listdir(dir)), 2)
    var ra = a^.finish()
    # `a`'s cleanup must leave `b`'s files alone.
    assert_equal(len(listdir(dir)), 1)
    var rb = b^.finish()
    assert_equal(len(listdir(dir)), 0)
    var ka = _keys(ra^)
    var kb = _keys(rb^)
    var want_a: List[Int64] = [1, 2, 4, 9]
    var want_b: List[Int64] = [10, 20, 40, 90]
    assert_equal(len(ka), 4)
    assert_equal(len(kb), 4)
    for i in range(4):
        assert_equal(ka[i], want_a[i])
        assert_equal(kb[i], want_b[i])


def _keys(var batches: Slab[RecordBatch]) raises -> List[Int64]:
    var out = List[Int64]()
    for b in range(len(batches)):
        var p = batches[b].column_at(0).as_primitive[DType.int64]()
        for i in range(p.length):
            out.append(p.get_typed[Scalar[DType.int64]](i))
    return out^


def _counter_of(root: String) raises -> Int:
    """The trailing counter of a `.../thsplc_sort_<pid>_<counter>` path."""
    var parts = root.split("_")
    return Int(parts[len(parts) - 1])


def test_existing_directory_with_the_next_name_is_skipped() raises:
    """A directory already sitting on the name a sorter would take is not
    reused: the sorter takes the following name, and the existing directory
    keeps exactly what it had."""
    var dir = _scratch_dir() + "/stale_name"
    var probe = create_spill_root(dir)
    var n = _counter_of(probe)
    rmdir(probe)
    var stale = probe[byte=0 : probe.byte_length() - String(n).byte_length()] + String(n + 1)
    mkdir(stale, 0o755)
    with open(stale + "/marker", "w") as marker:
        marker.write("x")

    var s = _sorter(dir)
    _absorb_three(s)
    var roots = listdir(dir)
    assert_equal(len(roots), 2)
    assert_equal(len(listdir(stale)), 1)
    var out = s^.finish()
    assert_true(len(out) > 0)
    assert_equal(len(listdir(stale)), 1)
    assert_equal(len(listdir(dir)), 1)


def _drop(var s: ExternalSorter):
    pass


def test_failed_spill_write_raises_and_drops_cleanly() raises:
    """When the spill root disappears between two spills, the second spill
    raises; the sorter is then only dropped, which neither crashes nor leaves
    files. The failing run is three batches of 1000 rows (large buffers, so a
    batch released twice would corrupt the allocator); it fails on its first
    write with two batches still to be released."""
    var dir = _scratch_dir() + "/write_fails"
    var s = _sorter_budget(dir, 1, 1000)
    s.absorb(_batch([Int64(1)]))
    var roots = listdir(dir)
    assert_equal(len(roots), 1)
    var root = dir + "/" + roots[0]
    var files = listdir(root)
    for i in range(len(files)):
        remove(root + "/" + files[i])
    rmdir(root)
    # A regular file where the spill root was: no chunk can be written there.
    with open(root, "w") as blocker:
        blocker.write("x")
    var raised = False
    try:
        var rows = List[Int64]()
        for i in range(3000):
            rows.append(Int64((i * 7919) % 3001))
        s.absorb(_batch(rows^))
    except:
        raised = True
    assert_true(raised)
    # The sorter is dropped here, after the failed spill. Its cleanup does not
    # remove the blocker (not a directory); nothing else is left under `dir`.
    _drop(s^)
    var left = listdir(dir)
    assert_equal(len(left), 1)
    remove(dir + "/" + left[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
