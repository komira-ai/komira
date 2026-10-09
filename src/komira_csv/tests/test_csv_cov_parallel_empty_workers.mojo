# =============================================================================
# The parallel reader with workers that decode zero rows, at declared BOOL and
# DATE32 types (the pair-wise concat), with stage timing on, in both arms.
# =============================================================================
#
# Split from test_csv_cov_parallel_typed so each test binary stays well under
# the coverage run's time limit. Values are checked against a closed form.
# =============================================================================

from std.testing import assert_equal

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


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _tail_blank_body() -> List[UInt8]:
    """Header, 2000 rows `<i even>,1970-01-02`, then 1.1 MB of blank lines:
    the workers past the first decode zero rows (blank lines are not
    records in a two-column file)."""
    var s = String("b,d\n")
    for i in range(2000):
        s += ("true" if i % 2 == 0 else "false") + ",1970-01-02\n"
    for _ in range(1100000):
        s += "\n"
    return _b(s)



def _bool_date_opts() -> CsvReadOptions:
    var o = CsvReadOptions()
    o.declared_column_types.append(ArrowType.BOOL)
    o.declared_column_types.append(ArrowType.DATE32)
    return o^



def _check_tail(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), 2000, label + ": rows")
    assert_equal(Int(rb.schema.field_arrow_type(0).type_id), Int(ArrowType.BOOL.type_id))
    assert_equal(Int(rb.schema.field_arrow_type(1).type_id), Int(ArrowType.DATE32.type_id))
    var cb = rb.column_at(0).as_boolean()
    var cd = rb.column_at(1).as_primitive[DType.int32]()
    for i in range(2000):
        assert_equal(cb.get(i), i % 2 == 0, label)
        assert_equal(cd.get(i), Int32(1), label)



def test_empty_workers_both_arms_timed() raises:
    """The blank tail leaves every worker but the first with zero rows; with
    stage timing on, both arms record the empty workers' scan time and the
    pair-wise concat skips their empty slots. Mutant: stop skipping blank
    lines in a file of two or more columns (red: a blank line is refused as
    a one-field record). Materializing an empty worker instead of leaving
    its slot None is equivalent (a zero-row batch adds no row)."""
    var data = _tail_blank_body()
    var rs = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(data), _bool_date_opts(), 4, True
    )
    _check_tail(rs, "serial")
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var rd = read_csv_bytes_to_batch_parallel_with_dispatcher[
        Rfc4180, origin_of(disp)
    ](Span(data), _bool_date_opts(), Pointer(to=disp), ct.clone(), 4, True)
    _check_tail(rd, "dispatcher")
    _ = ct^


def main() raises:
    test_empty_workers_both_arms_timed()
    print("test_csv_cov_parallel_empty_workers: 1 tests PASS")
