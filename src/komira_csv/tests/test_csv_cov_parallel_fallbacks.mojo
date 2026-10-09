# =============================================================================
# The parallel reader's fallbacks to the serial reader and the runtime
# quote-style dispatch of both dynamic entries. (The headerless arm and the
# blank-prefix fallback are in test_csv_cov_parallel_headerless and
# test_csv_cov_parallel_blank_prefix.)
# =============================================================================
#
# Each test checks the decoded values against a closed form computed from the
# fixture, not against the serial reader. Fixtures that must reach the
# partitioner are just over the 1 MiB parallel threshold. Each docstring names
# its mutant.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.csv_options import (
    QUOTE_STYLE_TAG_RFC4180,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
)
from komira_csv.parallel_reader import (
    read_csv_bytes_to_batch_parallel,
    read_csv_bytes_to_batch_parallel_dynamic,
    read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher,
)


comptime _ROWS = 20000  # about 60 bytes per row: past the 1 MiB threshold
# Long rows: fewer of them to build and check for the same byte count.
comptime _PAD = "________________________________________________"


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _body(n: Int, quoted: Bool) -> String:
    """Rows `<i>,v<i><pad>` (or `<i>,"v<i><pad>"`)."""
    var s = String("")
    for i in range(n):
        if quoted:
            s += String(i) + ',"v' + String(i) + _PAD + '"\n'
        else:
            s += String(i) + ",v" + String(i) + _PAD + "\n"
    return s^


def _check_rows(rb: RecordBatch, n: Int, label: String) raises:
    assert_equal(rb.num_rows(), n, label + ": rows")
    var k = rb.column_at(0).as_primitive[DType.int64]()
    var v = rb.column_as_string(1)
    for i in range(n):
        assert_equal(k.get(i), Int64(i), label + ": key")
    assert_equal(v.get(0), "v0" + _PAD, label + ": first string")
    assert_equal(v.get(n - 1), String("v") + String(n - 1) + _PAD, label + ": last string")


def test_empty_and_small_inputs_use_the_serial_reader() raises:
    """Empty bytes and a small file decode through the serial reader, from the
    dispatcher-less dynamic entry too, whose runtime dispatch reaches each
    dialect and refuses an unknown tag. Mutant: route the Posix tag to
    Rfc4180 (red: the `\\"` cell is refused)."""
    var empty = List[UInt8]()
    var rb0 = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(empty), CsvReadOptions(), 4
    )
    assert_equal(rb0.num_columns(), 0)
    assert_equal(rb0.num_rows(), 0)
    var small = _b("k,v\n" + _body(3, False))
    var rb1 = read_csv_bytes_to_batch_parallel_dynamic(
        Span(small), CsvReadOptions(), 4
    )
    _check_rows(rb1, 3, "dynamic small")
    var o = CsvReadOptions()
    o.quote_style_tag = QUOTE_STYLE_TAG_EXCEL
    _check_rows(read_csv_bytes_to_batch_parallel_dynamic(Span(small), o, 4), 3, "excel")
    o.quote_style_tag = QUOTE_STYLE_TAG_POSIX
    var px = _b('k,v\n0,"a\\"b"\n')
    var rbp = read_csv_bytes_to_batch_parallel_dynamic(Span(px), o, 4)
    assert_equal(rbp.column_as_string(1).get(0), 'a"b')
    o.quote_style_tag = 5
    var msg = String("")
    try:
        _ = read_csv_bytes_to_batch_parallel_dynamic(Span(small), o, 4)
    except e:
        msg = String(e)
    assert_true(msg.find("unknown options.quote_style_tag 5") >= 0, msg)


def test_dispatcher_entry_dispatches_each_dialect() raises:
    """The dispatcher entry's runtime dispatch reaches Excel and Posix and
    refuses an unknown tag. The Posix file is over 1 MiB: Posix cannot be
    split by quote parity, so the partitioner returns one range and the read
    falls back to the serial reader. (The big Posix fixture holds no `\\"`
    escape: the phase-3 scanner that fallback uses mis-tokenizes one past 64
    bytes, filed separately.) Mutant: skip the dispatcher entry's Posix arm
    (red: tag 2 is refused as unknown)."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()

    var o = CsvReadOptions()
    o.quote_style_tag = QUOTE_STYLE_TAG_EXCEL
    var small = _b("k,v\n" + _body(2, True))
    var rbe = read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
        origin_of(disp)
    ](Span(small), o, Pointer(to=disp), ct.clone(), 4)
    _check_rows(rbe, 2, "excel")

    o.quote_style_tag = QUOTE_STYLE_TAG_POSIX
    var text = String('k,v\n0,"a,b"\n') + _body(_ROWS, False)
    var big = _b(text)
    assert_true(len(big) > 1024 * 1024, "posix fixture must pass 1 MiB")
    var rbp = read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
        origin_of(disp)
    ](Span(big), o, Pointer(to=disp), ct.clone(), 4)
    assert_equal(rbp.num_rows(), _ROWS + 1)
    assert_equal(rbp.column_as_string(1).get(0), "a,b")
    assert_equal(rbp.column_as_string(1).get(_ROWS), String("v") + String(_ROWS - 1) + _PAD)

    o.quote_style_tag = 7
    var msg = String("")
    try:
        _ = read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher[
            origin_of(disp)
        ](Span(small), o, Pointer(to=disp), ct.clone(), 4)
    except e:
        msg = String(e)
    assert_true(msg.find("unknown options.quote_style_tag 7") >= 0, msg)
    _ = ct^


def main() raises:
    test_empty_and_small_inputs_use_the_serial_reader()
    test_dispatcher_entry_dispatches_each_dialect()
    print("test_csv_cov_parallel_fallbacks: 2 tests PASS")
