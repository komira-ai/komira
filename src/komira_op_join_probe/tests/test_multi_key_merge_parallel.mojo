# The merge of the parallel composite probe's per-worker matches: it runs as
# one fanned wave, keeps every (build, probe) pair together, appends after the
# caller's existing content, and handles an empty probe.

from std.sys import num_physical_cores
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import (
    SITE_JOIN_MK_MERGE,
    sched_trace_configure,
    sched_trace_reset,
    sched_trace_site,
)

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
)
from komira_op_join_probe.join_probe_settings import mk_probe_configure


comptime _MORSEL: Int = 4096

comptime _PROBE_ROWS: Int = 10 * _MORSEL

comptime _POOL_WORKERS: Int = 4


def _mk_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _mk_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    """BACKEND_MOCK: the probe + merge dispatches use only the worker-pool
    fan-out, never real IO, so no per-worker epoll fd is needed.
    """
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_mk_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _expected_merge_tasks() -> Int:
    """`task_min` / `task_max` the merge wave must record on THIS box."""
    var num_morsels = (_PROBE_ROWS + _MORSEL - 1) // _MORSEL
    var num_workers = min(num_morsels, num_physical_cores())
    return min(_POOL_WORKERS, num_workers)


def _multiplicity(p: Int) -> Int:
    """Matches probe row `p` will produce: 1..5, constant within a morsel and
    cycling across morsels.
    """
    return 1 + ((p // _MORSEL) % 5)


def _make_2col_int64(
    c0_name: String, c1_name: String,
    imm c0: List[Int64], imm c1: List[Int64],
) raises -> RecordBatch:
    var n = len(c0)
    var a0 = PrimitiveArray[DType.int64].allocate(n)
    var p0 = a0._typed_ptr_mut()
    for i in range(n):
        p0.store[width=1](i, c0[i])
    var a1 = PrimitiveArray[DType.int64].allocate(n)
    var p1 = a1._typed_ptr_mut()
    for i in range(n):
        p1.store[width=1](i, c1[i])
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.INT64, False))
    sb.add_field(Field(c1_name, ArrowType.INT64, False))
    var bldr = RecordBatchBuilder()
    bldr.add_column(Column.from_primitive(a0^))
    bldr.add_column(Column.from_primitive(a1^))
    return bldr.build(sb.build())


def _probe_keys(n_rows: Int) -> Tuple[List[Int64], List[Int64]]:
    """Probe row `p` gets the UNIQUE pair `(p, 3p + 1)`."""
    var a = List[Int64](capacity=n_rows)
    var b = List[Int64](capacity=n_rows)
    for p in range(n_rows):
        a.append(Int64(p))
        b.append(Int64(3 * p + 1))
    return (a^, b^)


def _build_keys(n_probe_rows: Int) -> Tuple[List[Int64], List[Int64]]:
    """`_multiplicity(p)` build rows carrying probe row `p`'s key, for every p."""
    var a = List[Int64]()
    var b = List[Int64]()
    for p in range(n_probe_rows):
        for _ in range(_multiplicity(p)):
            a.append(Int64(p))
            b.append(Int64(3 * p + 1))
    return (a^, b^)


def _expected_output_rows(n_probe_rows: Int) -> Int:
    var t = 0
    for p in range(n_probe_rows):
        t += _multiplicity(p)
    return t


def _assert_rows_are_paired(
    imm build_matches: List[Int],
    imm probe_matches: List[Int],
    imm build_a: List[Int64], imm build_b: List[Int64],
    imm probe_a: List[Int64], imm probe_b: List[Int64],
) raises:
    """PER-ROW key equality between the paired build and probe rows."""
    assert_equal(
        len(build_matches),
        len(probe_matches),
        "build/probe output lists must stay the same length",
    )
    var n_build = len(build_a)
    var n_probe = len(probe_a)
    var out_of_range = 0
    var mispaired = 0
    for r in range(len(build_matches)):
        var bi = build_matches[r]
        var pi = probe_matches[r]
        if bi < 0 or bi >= n_build or pi < 0 or pi >= n_probe:
            out_of_range += 1
            continue
        if build_a[bi] != probe_a[pi] or build_b[bi] != probe_b[pi]:
            mispaired += 1
    assert_equal(
        out_of_range, 0, "output row index outside its side's row range"
    )
    assert_equal(
        mispaired,
        0,
        "output rows whose build-side key != probe-side key (mis-paired merge)",
    )


def _assert_each_build_row_once(
    imm build_matches: List[Int], n_build: Int
) raises:
    """Structural leg: this fixture's join is one-to-one from the BUILD side
    (every build row's key matches exactly one probe row), so every build row
    must appear in the output exactly once.
    """
    var seen = List[Int](capacity=n_build)
    for _ in range(n_build):
        seen.append(0)
    for r in range(len(build_matches)):
        var bi = build_matches[r]
        if bi >= 0 and bi < n_build:
            seen[bi] += 1
    var wrong = 0
    for i in range(n_build):
        if seen[i] != 1:
            wrong += 1
    assert_equal(wrong, 0, "every build row must appear exactly once")


def _run_probe(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    imm build_a: List[Int64], imm build_b: List[Int64],
    imm probe_a: List[Int64], imm probe_b: List[Int64],
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
) raises:
    var build_batch = _make_2col_int64("b_a", "b_b", build_a, build_b)
    var probe_batch = _make_2col_int64("p_a", "p_b", probe_a, probe_b)
    var bk = extract_join_key_columns_serial(build_batch, ["b_a", "b_b"])
    var pk = extract_join_key_columns_serial(probe_batch, ["p_a", "p_b"])
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    ref dispatcher = rt.dispatcher()
    parallel_multi_key_inner_probe_into(
        dispatcher,
        CancellationToken.never(),
        builder,
        pk,
        build_matches,
        probe_matches,
    )


def test_merge_wave_dispatches_one_full_width_fork() raises:
    """One merge wave per probe, as wide as the workers, read from the
    scheduler trace's counters."""
    sched_trace_reset()

    var pk = _probe_keys(_PROBE_ROWS)
    var bk = _build_keys(_PROBE_ROWS)
    var rt = _mk_runtime()
    var bm = List[Int]()
    var pm = List[Int]()
    _run_probe(rt, bk[0], bk[1], pk[0], pk[1], bm, pm)

    var count = Int(sched_trace_site(SITE_JOIN_MK_MERGE, Int32(2)))
    var tmin = Int(sched_trace_site(SITE_JOIN_MK_MERGE, Int32(4)))
    var tmax = Int(sched_trace_site(SITE_JOIN_MK_MERGE, Int32(5)))
    var want = _expected_merge_tasks()
    print(
        "[fire] join_mk_merge count=", count,
        " task_min=", tmin,
        " task_max=", tmax,
        " expected_tasks=", want,
        " out_rows=", len(bm),
        " bytes_moved=", len(bm) * 16,
        sep="",
    )
    assert_equal(
        count,
        1,
        "the merge must dispatch EXACTLY one fork-join wave per probe call;"
        " 0 means it degraded to fork_join_shared's inline arm",
    )
    assert_equal(tmin, want, "merge wave task_min")
    assert_equal(tmax, want, "merge wave task_max")
    assert_true(
        want >= 2,
        "test geometry is degenerate: the merge would tile to one chunk",
    )

    assert_equal(len(bm), _expected_output_rows(_PROBE_ROWS))


def test_merge_keeps_every_row_paired_under_skewed_worker_counts() raises:
    """Every merged pair has equal keys, when the workers' segment lengths
    differ."""
    var pk = _probe_keys(_PROBE_ROWS)
    var bk = _build_keys(_PROBE_ROWS)
    var rt = _mk_runtime()
    var bm = List[Int]()
    var pm = List[Int]()
    _run_probe(rt, bk[0], bk[1], pk[0], pk[1], bm, pm)

    assert_equal(len(bm), _expected_output_rows(_PROBE_ROWS))
    _assert_rows_are_paired(bm, pm, bk[0], bk[1], pk[0], pk[1])
    _assert_each_build_row_once(bm, len(bk[0]))


def test_merge_appends_after_existing_content() raises:
    """The output lists are APPEND targets, and their two pre-existing lengths
    are not required to match — `reserve(len(x) + total)` allowed them to differ
    before this change, so the forked merge must too.
    """
    var pk = _probe_keys(_PROBE_ROWS)
    var bk = _build_keys(_PROBE_ROWS)
    var rt = _mk_runtime()

    var bm = List[Int]()
    var pm = List[Int]()
    for i in range(3):
        bm.append(-100 - i)
    for i in range(5):
        pm.append(-200 - i)

    _run_probe(rt, bk[0], bk[1], pk[0], pk[1], bm, pm)

    var n_out = _expected_output_rows(_PROBE_ROWS)
    assert_equal(len(bm), 3 + n_out)
    assert_equal(len(pm), 5 + n_out)
    for i in range(3):
        assert_equal(bm[i], -100 - i, "pre-existing build rows were clobbered")
    for i in range(5):
        assert_equal(pm[i], -200 - i, "pre-existing probe rows were clobbered")

    var tail_b = List[Int](capacity=n_out)
    var tail_p = List[Int](capacity=n_out)
    for r in range(n_out):
        tail_b.append(bm[3 + r])
        tail_p.append(pm[5 + r])
    _assert_rows_are_paired(tail_b, tail_p, bk[0], bk[1], pk[0], pk[1])
    _assert_each_build_row_once(tail_b, len(bk[0]))


def test_merge_handles_empty_probe() raises:
    """`num_workers == 0` — the wave is handed `n_chunks == 0`, the prefix scan
    is the single element `[0]`, and nothing may be published or dispatched.
    """
    var probe_a = List[Int64]()
    var probe_b = List[Int64]()
    var build_a = List[Int64]()
    var build_b = List[Int64]()
    for i in range(8):
        build_a.append(Int64(i))
        build_b.append(Int64(3 * i + 1))

    var rt = _mk_runtime()
    var bm = List[Int]()
    var pm = List[Int]()
    _run_probe(rt, build_a, build_b, probe_a, probe_b, bm, pm)
    assert_equal(len(bm), 0)
    assert_equal(len(pm), 0)


def main() raises:
    sched_trace_configure(True)
    mk_probe_configure(morsel_rows=_MORSEL)

    var suite = TestSuite()
    suite.test[test_merge_wave_dispatches_one_full_width_fork]()
    suite.test[test_merge_keeps_every_row_paired_under_skewed_worker_counts]()
    suite.test[test_merge_appends_after_existing_content]()
    suite.test[test_merge_handles_empty_probe]()
    suite^.run()
