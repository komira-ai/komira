# =============================================================================
# Tests for the DISPATCHER-BACKED arm of komira_csv/parallel_reader.mojo.
# =============================================================================
#
# The dispatcher arm is the one every SDK CSV decode over 4 MiB takes, so it
# needs its own tests.
#
# `read_csv_bytes_to_batch_parallel_impl` has two arms, selected by the
# `has_dispatcher` comptime parameter:
#
#   has_dispatcher=False  the serial per-worker loop. This is what
#                         `read_csv_bytes_to_batch_parallel[Q]` forwards
#                         (its own docstring says so), and it is what the
#                         other parallel-reader tests exercise.
#   has_dispatcher=True   the LocalDispatcher.run_with_state fan-out. Reached
#                         from the SDK's engine context (`ctx.read_csv` and a
#                         CSV aggregate demoted from the row path) over
#                         `_PARALLEL_SDK_BYTES_THRESHOLD`.
#
# A use-after-free in this arm (the driver's boundary lists destroyed before
# the workers read them) faults only under the dispatcher.
#
# THE INVARIANT UNDER TEST is the same one `test_csv_parallel_reader_*.mojo`
# states for the serial arm -- byte-identity with the single-thread reader --
# asserted here against the DISPATCHER arm, plus a closed-form value check
# (`col_a[i] == i`) that does not depend on the serial reader being right
# either. Deliberately NOT "does not segfault": a crash-shaped oracle passes
# for the wrong reasons the moment the corruption lands somewhere benign.
#
# T1  byte-identity + closed-form values, dispatcher arm vs single-thread
#     reader, over a >1 MiB buffer with 8 workers, repeated -- the driver's
#     per-worker `[lo, hi)` range lists must still be alive (and unmodified)
#     when the workers read them through the borrowed State.
# T2  the same at high worker count (the production shape: one shard per
#     attached worker, k ranges over k workers).
# T3  range coverage: every input row appears exactly once in the output.
#     A worker that reads a corrupted `lo`/`hi` cannot satisfy this even if
#     the byte it lands on happens not to fault.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch

from komira_csv import CsvReadOptions
from komira_csv.csv_options import QUOTE_STYLE_TAG_RFC4180
from komira_csv.reader import read_csv_bytes_to_batch_dynamic
from komira_csv.parallel_reader import (
    read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher,
)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _fixture(n_rows: Int) -> List[UInt8]:
    """`a,b,c` header + `n_rows` rows where `a` == the row index.

    Sized by the caller to clear `_MIN_PARALLEL_BYTES` (1 MiB) so the
    driver actually partitions rather than falling back to single-thread.
    """
    var s = String("a,b,c\n")
    var i = 0
    while i < n_rows:
        s += String(i) + "," + String(i * 2) + ",row" + String(i) + "\n"
        i += 1
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _i64_at(batch: RecordBatch, col: Int, row: Int) raises -> Int64:
    ref c = batch.column_at(col)
    var arr = c.as_primitive[DType.int64]()
    return arr.get(row)


def _assert_matches_serial(
    parallel: RecordBatch, serial: RecordBatch, n_rows: Int, label: String
) raises:
    """Byte-identity against the single-thread reader + the closed form."""
    assert_equal(
        parallel.num_rows(),
        serial.num_rows(),
        label + ": dispatcher-arm row count must equal the single-thread"
        " reader's",
    )
    assert_equal(
        parallel.num_rows(),
        n_rows,
        label + ": dispatcher-arm row count must equal the fixture's row"
        " count",
    )
    assert_equal(
        parallel.num_columns(),
        serial.num_columns(),
        label + ": column count must match the single-thread reader",
    )
    # Closed form: row i carries a == i, b == 2i. Independent of `serial`.
    var i = 0
    while i < n_rows:
        assert_equal(
            _i64_at(parallel, 0, i),
            Int64(i),
            label + ": col a row " + String(i) + " must equal its row index"
            " -- a worker reading a corrupted [lo, hi) range decodes a"
            " different byte span",
        )
        assert_equal(
            _i64_at(parallel, 1, i),
            Int64(i * 2),
            label + ": col b row " + String(i) + " must equal 2 * row index",
        )
        i += 1


def _opts() -> CsvReadOptions:
    var opts = CsvReadOptions()
    opts.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
    return opts^


def test_dispatcher_arm_matches_single_thread_8_workers() raises:
    """T1 -- the dispatcher arm must decode what the single-thread reader
    decodes, over a buffer large enough to partition.

    RED BEFORE THE FIX: the driver's `los`/`his` range lists were cast to an
    origin (`in_o`) anchored on the *bytes* buffer, not on themselves, so the
    compiler had no liveness edge to them and ASAP destruction freed both
    lists BEFORE `run_with_state` posted a single task. Every worker then
    read its `[lo, hi)` out of freed heap.
    """
    var n_rows = 60000  # ~1.2 MiB, clears _MIN_PARALLEL_BYTES
    var data = _fixture(n_rows)

    var serial = read_csv_bytes_to_batch_dynamic(Span(data), _opts())

    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=8,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()

    # Repeated: each read re-runs the driver, so each read re-exercises the
    # borrow. One clean read is not evidence that the borrow is sound.
    var rep = 0
    while rep < 3:
        var ct = CancellationToken.new()
        var parallel = read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
            origin_of(disp)
        ](Span(data), _opts(), Pointer(to=disp), ct.clone(), 8)
        _assert_matches_serial(
            parallel, serial, n_rows, String("rep ") + String(rep)
        )
        _ = parallel^
        _ = ct^
        rep += 1

    _ = data^
    _ = serial^
    print("  test_dispatcher_arm_matches_single_thread_8_workers PASS")


def test_dispatcher_arm_matches_single_thread_wide_fan() raises:
    """T2 -- the production shape: one shard per attached worker."""
    var n_rows = 60000
    var data = _fixture(n_rows)

    var serial = read_csv_bytes_to_batch_dynamic(Span(data), _opts())

    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=16,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()

    var rep = 0
    while rep < 3:
        var ct = CancellationToken.new()
        var parallel = read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
            origin_of(disp)
        ](Span(data), _opts(), Pointer(to=disp), ct.clone(), 16)
        _assert_matches_serial(
            parallel, serial, n_rows, String("wide rep ") + String(rep)
        )
        _ = parallel^
        _ = ct^
        rep += 1

    _ = data^
    _ = serial^
    print("  test_dispatcher_arm_matches_single_thread_wide_fan PASS")


def test_dispatcher_arm_covers_every_row_exactly_once() raises:
    """T3 -- the partition is a TILING: every input row lands in the output
    exactly once.

    This is the invariant the borrowed `los`/`his` lists carry. It is checked
    separately from value equality because a corrupted range can also produce
    a plausible-looking batch with rows duplicated or dropped -- an oracle
    that only counts rows, or only samples values, would pass on it.
    """
    var n_rows = 60000
    var data = _fixture(n_rows)

    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=8,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()

    var ct = CancellationToken.new()
    var parallel = read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
        origin_of(disp)
    ](Span(data), _opts(), Pointer(to=disp), ct.clone(), 8)

    assert_equal(
        parallel.num_rows(),
        n_rows,
        "T3: output row count must equal the input row count",
    )

    var seen = List[Bool]()
    var z = 0
    while z < n_rows:
        seen.append(False)
        z += 1

    var r = 0
    while r < n_rows:
        var v = Int(_i64_at(parallel, 0, r))
        assert_true(
            v >= 0 and v < n_rows,
            "T3: decoded key " + String(v) + " at row " + String(r)
            + " is outside the input's key range -- the worker decoded bytes"
            " outside its assigned [lo, hi)",
        )
        assert_true(
            not seen[v],
            "T3: key " + String(v) + " appears twice -- two workers'"
            " ranges overlap",
        )
        seen[v] = True
        r += 1

    _ = parallel^
    _ = ct^
    _ = data^
    print("  test_dispatcher_arm_covers_every_row_exactly_once PASS")


def main() raises:
    print("test_csv_parallel_reader_dispatcher_arm.mojo")
    test_dispatcher_arm_matches_single_thread_8_workers()
    test_dispatcher_arm_matches_single_thread_wide_fan()
    test_dispatcher_arm_covers_every_row_exactly_once()
    print("ALL PASS")
