# =============================================================================
# The parallel reader at declared column types (BOOL and DATE32 take the
# pair-wise concat), with stage timing on and off, in both arms (the serial
# per-worker loop and the dispatcher). Workers that decode zero rows are in
# test_csv_cov_parallel_empty_workers.
# =============================================================================
#
# Every value is checked against a closed form of the fixture's row index,
# not against the serial reader. Each docstring names its mutant.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.parallel_reader import (
    read_csv_bytes_to_batch_parallel,
    read_csv_bytes_to_batch_parallel_with_dispatcher,
)


comptime _ROWS = 20000  # about 85 bytes per row: past the 1 MiB threshold
# Long rows: fewer of them to build and check for the same byte count.
comptime _PAD = "________________________________________________"


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _typed_opts() -> CsvReadOptions:
    var o = CsvReadOptions()
    o.declared_column_types.append(ArrowType.INT64)
    o.declared_column_types.append(ArrowType.BOOL)
    o.declared_column_types.append(ArrowType.DATE32)
    o.declared_column_types.append(ArrowType.FLOAT64)
    o.declared_column_types.append(ArrowType.STRING)
    return o^


def _typed_fixture() -> List[UInt8]:
    """Row i: all empty when i % 7 == 3; unparsable in the first four
    columns (`x,maybe,2024-1-1,y,z`) when i % 11 == 5; otherwise
    `i, i even, 1970-01-02, i.5, s<i><pad>`."""
    var s = String("i,b,d,f,s\n")
    for i in range(_ROWS):
        if i % 7 == 3:
            s += ",,,,\n"
        elif i % 11 == 5:
            s += "x,maybe,2024-1-1,y,z\n"
        else:
            s += String(i) + ("," + "true" if i % 2 == 0 else ",false")
            s += ",1970-01-02," + String(i) + ".5,s" + String(i) + _PAD + "\n"
    return _b(s)


def _check_typed(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), _ROWS, label + ": rows")
    assert_equal(Int(rb.schema.field_arrow_type(1).type_id), Int(ArrowType.BOOL.type_id))
    assert_equal(Int(rb.schema.field_arrow_type(2).type_id), Int(ArrowType.DATE32.type_id))
    var ci = rb.column_at(0).as_primitive[DType.int64]()
    var cb = rb.column_at(1).as_boolean()
    var cd = rb.column_at(2).as_primitive[DType.int32]()
    var cf = rb.column_at(3).as_primitive[DType.float64]()
    var cs = rb.column_as_string(4)
    for i in range(_ROWS):
        var tag = label + " row " + String(i)
        if i % 7 == 3:
            assert_true(ci.is_null(i) and cb.is_null(i), tag)
            assert_true(cd.is_null(i) and cf.is_null(i) and cs.is_null(i), tag)
        elif i % 11 == 5:
            assert_true(ci.is_null(i) and cb.is_null(i), tag)
            assert_true(cd.is_null(i) and cf.is_null(i), tag)
            assert_equal(cs.get(i), "z", tag)
        else:
            assert_equal(ci.get(i), Int64(i), tag)
            assert_equal(cb.get(i), i % 2 == 0, tag)
            assert_equal(cd.get(i), Int32(1), tag)
            assert_equal(cf.get(i), Float64(i) + 0.5, tag)


def test_declared_types_serial_arm_untimed() raises:
    """Serial per-worker arm, no timing: every worker parses at the declared
    types; empty cells and cells that do not parse are null, including in
    the BOOL and DATE32 columns joined by the pair-wise concat. Mutant:
    ignore the declared list in the parallel reader (red: `b` infers STRING
    over `maybe`)."""
    var data = _typed_fixture()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(data), _typed_opts(), 4
    )
    _check_typed(rb, "serial")


def test_declared_types_dispatcher_arm_timed() raises:
    """Dispatcher arm with stage timing: the timed materializer attributes
    the BOOL and DATE32 build times and decodes the same values. Mutant:
    skip the timed arm's batch store (red: zero rows)."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var data = _typed_fixture()
    var rb = read_csv_bytes_to_batch_parallel_with_dispatcher[
        Rfc4180, origin_of(disp)
    ](Span(data), _typed_opts(), Pointer(to=disp), ct.clone(), 4, True)
    _check_typed(rb, "dispatcher timed")
    _ = ct^


def main() raises:
    test_declared_types_serial_arm_untimed()
    test_declared_types_dispatcher_arm_timed()
    print("test_csv_cov_parallel_typed: 2 tests PASS")
