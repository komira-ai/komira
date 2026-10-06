# =============================================================================
# Record-shape refusals in the PARALLEL CSV reader (komira-ai/komira#449).
# =============================================================================
#
# The parallel reader splits the input at quote-safe row boundaries and each
# worker scans and materializes only its own slice, so a check that lives in
# the single-thread entry alone would miss every malformed record outside the
# first slice. These cases put one malformed record into a ~1.2 MiB input,
# once in worker 0's slice (just after the header) and once deep in a later
# slice, and read it through both arms of the driver: the dispatcher-less
# per-worker loop (`read_csv_bytes_to_batch_parallel`) and the
# `LocalDispatcher.run_with_state` fan-out.
#
# The refusal must name the record by its number IN THE FILE. A worker only
# sees its slice, so a number computed from the slice alone would be off by
# every record before it; `record 50002` in the message is what catches that.
# The `parallel_reader: worker` prefix proves the read really went parallel
# (an input under 1 MiB falls back to the single-thread reader).
#
# Mutants that turn this red: delete the `check_csv_record_shape` call from
# either arm of `read_csv_bytes_to_batch_parallel_impl` (the read succeeds,
# dropping or padding the record), or number records from the slice start
# (`record 2` instead of `record 50002`).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)

from komira_core.arrow.schema import RecordBatch

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.parallel_reader import (
    read_csv_bytes_to_batch_parallel,
    read_csv_bytes_to_batch_parallel_with_dispatcher,
)


comptime _N_ROWS = 60000  # ~1.2 MiB, clears _MIN_PARALLEL_BYTES (1 MiB)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


@fieldwise_init
struct _Fixture(Movable):
    var data: List[UInt8]
    var bad_offset: Int  # byte offset of the malformed record's first byte


def _fixture(bad_row: Int, bad: String) -> _Fixture:
    """`a,b,c` header + `_N_ROWS` rows; data row `bad_row` (0-based, so
    record `bad_row + 2`) is replaced by `bad`."""
    var s = String("a,b,c\n")
    var bad_offset = -1
    for i in range(_N_ROWS):
        if i == bad_row:
            bad_offset = s.byte_length()
            s += bad
        else:
            s += String(i) + "," + String(i * 2) + ",row" + String(i) + "\n"
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return _Fixture(out^, bad_offset)


def _assert_has(msg: String, part: String) raises:
    assert_true(
        msg.find(part) >= 0,
        "refusal must contain `" + part + "`; got: " + msg,
    )


def _check(msg: String, fx: _Fixture, bad_row: Int, problem: String) raises:
    var rec = bad_row + 2
    _assert_has(msg, "komira_csv.parallel_reader: worker ")
    _assert_has(
        msg,
        "record "
        + String(rec)
        + " (line "
        + String(rec)
        + ", byte offset "
        + String(fx.bad_offset)
        + ")",
    )
    _assert_has(msg, problem)


def _serial_arm_refusal(fx: _Fixture) raises -> String:
    try:
        _ = read_csv_bytes_to_batch_parallel[Rfc4180](
            Span(fx.data), CsvReadOptions(), 4
        )
    except e:
        return String(e)
    assert_true(False, "parallel reader (serial arm) accepted a bad record")
    return String("")


def _dispatcher_arm_refusal(fx: _Fixture) raises -> String:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var msg = String("")
    try:
        _ = read_csv_bytes_to_batch_parallel_with_dispatcher[
            Rfc4180, origin_of(disp)
        ](Span(fx.data), CsvReadOptions(), Pointer(to=disp), ct.clone(), 4)
    except e:
        msg = String(e)
    _ = ct^
    assert_true(
        msg.byte_length() > 0,
        "parallel reader (dispatcher arm) accepted a bad record",
    )
    return msg


def _both_arms(bad_row: Int, bad: String, problem: String) raises:
    var fx = _fixture(bad_row, bad)
    _check(_serial_arm_refusal(fx), fx, bad_row, problem)
    _check(_dispatcher_arm_refusal(fx), fx, bad_row, problem)


def test_extra_field_late_slice() raises:
    _both_arms(50000, String("50000,1,row,extra\n"), "has 4 fields but the header has 3")
    print("  test_extra_field_late_slice PASS")


def test_short_record_late_slice() raises:
    _both_arms(50000, String("50000,1\n"), "field 3 ('c') is missing")
    print("  test_short_record_late_slice PASS")


def test_bad_quote_late_slice() raises:
    _both_arms(50000, String("50000,1,\"row\"x\n"), "field 3 ('c')")
    print("  test_bad_quote_late_slice PASS")


def test_extra_field_worker0_slice() raises:
    _both_arms(10, String("10,1,row,extra\n"), "has 4 fields but the header has 3")
    print("  test_extra_field_worker0_slice PASS")


def test_bad_quote_worker0_slice() raises:
    _both_arms(10, String("10,1,\"row\"x\n"), "follows the field's closing quote")
    print("  test_bad_quote_worker0_slice PASS")


def _blank_fixture(var tail: String) -> List[UInt8]:
    """`_N_ROWS` good rows with blank lines (LF and CRLF) after the header,
    every 10000 rows and at the end, then `tail`."""
    var s = String("a,b,c\n\n")
    for i in range(_N_ROWS):
        if i > 0 and i % 10000 == 0:
            s += "\n\r\n\n"
        s += String(i) + "," + String(i * 2) + ",row" + String(i) + "\n"
    s += tail
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _check_rows(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), _N_ROWS, label + ": blank lines are not rows")
    ref c = rb.column_at(0)
    var arr = c.as_primitive[DType.int64]()
    for i in range(_N_ROWS):
        assert_equal(Int(arr.get(i)), i, label + ": a[" + String(i) + "]")


def test_blank_lines_skipped_in_every_slice() raises:
    var data = _blank_fixture(String("\n\n"))
    _check_rows(
        read_csv_bytes_to_batch_parallel[Rfc4180](
            Span(data), CsvReadOptions(), 4
        ),
        String("serial arm"),
    )
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var rb = read_csv_bytes_to_batch_parallel_with_dispatcher[
        Rfc4180, origin_of(disp)
    ](Span(data), CsvReadOptions(), Pointer(to=disp), ct.clone(), 4)
    _ = ct^
    _check_rows(rb, String("dispatcher arm"))
    print("  test_blank_lines_skipped_in_every_slice PASS")


def test_refusal_after_blank_lines_late_slice() raises:
    """A short record at the very end, after 1 + 5 * 3 + 2 blank lines: it is
    record _N_ROWS + 2 (blank lines are not records) but its line counts
    every blank line."""
    var data = _blank_fixture(String("\n\nshort\n"))
    var bad_offset = len(data) - 6
    var rec = _N_ROWS + 2
    var line = rec + 1 + 5 * 3 + 2
    var fx = _Fixture(data^, bad_offset)
    var want = (
        String("record ")
        + String(rec)
        + " (line "
        + String(line)
        + ", byte offset "
        + String(bad_offset)
        + ") has 1 field but the header has 3"
    )
    _assert_has(_serial_arm_refusal(fx), want)
    _assert_has(_dispatcher_arm_refusal(fx), want)
    print("  test_refusal_after_blank_lines_late_slice PASS")


def main() raises:
    print("test_csv_record_shape_parallel.mojo")
    test_extra_field_late_slice()
    test_short_record_late_slice()
    test_bad_quote_late_slice()
    test_extra_field_worker0_slice()
    test_bad_quote_worker0_slice()
    test_blank_lines_skipped_in_every_slice()
    test_refusal_after_blank_lines_late_slice()
    print("test_csv_record_shape_parallel: 7/7 PASS")
