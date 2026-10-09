# =============================================================================
# _concat_csv_batches_column_parallel: a per-column failure reaches the caller.
# =============================================================================
#
# The reader's own read path hands this concat batches decoded under one
# shared schema, so from the reader a column concat fails only past the 2 GiB
# string offset limit. The concat itself does not assume that: when two
# batches disagree about a column's buffer layout the multi-way kernel raises
# `ArrowConcatLayoutDisagreement`, and the concat must record that failure in
# the column's error slot (on the worker pool and in the serial loop) and
# re-raise it naming the column. These tests call the concat directly with two
# batches whose column 1 is STRING in one and INT64 in the other, once per
# path, and check the raised text. Each docstring names its mutant.
# =============================================================================

from std.testing import assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab

from komira_csv.parallel_reader import _concat_csv_batches_column_parallel


comptime _WANT = "column-parallel concat column 1 failed: ArrowConcatLayoutDisagreement"


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _batch(second_is_string: Bool) raises -> RecordBatch:
    """Two rows: column `k` INT64, column `s` STRING or INT64."""
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list([1, 2]))
    )
    if second_is_string:
        sb.add_field(Field("s", ArrowType.STRING, True))
        var ss = List[String]()
        ss.append("x")
        ss.append("y")
        b.add_column(Column.from_string(StringArray.from_strings(ss)))
    else:
        sb.add_field(Field("s", ArrowType.INT64, True))
        b.add_column(
            Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list([3, 4]))
        )
    return b.build(sb.build())


def _disagreeing_batches() raises -> Slab[Optional[RecordBatch]]:
    var slab = Slab[Optional[RecordBatch]].create(2)
    slab.append(Optional[RecordBatch](_batch(True)))
    slab.append(Optional[RecordBatch](_batch(False)))
    return slab^


def _names() -> List[String]:
    var n = List[String]()
    n.append("k")
    n.append("s")
    return n^


def _types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.STRING)
    return t^


def test_pool_concat_reraises_the_column_failure() raises:
    """On the worker pool, column 1's layout disagreement is recorded in its
    error slot and re-raised naming column 1. Mutants: drop the worker's
    `col_errors[c] = ...` (red: the failure is lost and the output batch
    build raises `column 1 has length 0` instead); name column 0 in the
    re-raise (red: `column 0 failed`)."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var msg = String("")
    try:
        _ = _concat_csv_batches_column_parallel[
            has_dispatcher=True, disp_o=origin_of(disp)
        ](
            _disagreeing_batches(),
            2,
            2,
            _names(),
            _types(),
            Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
                Pointer(to=disp)
            ),
            CancellationToken.new(),
        )
    except e:
        msg = String(e)
    assert_true(msg.find(_WANT) >= 0, "pool concat: got '" + msg + "'")


def test_serial_concat_reraises_the_column_failure() raises:
    """Without a dispatcher the serial loop records and re-raises the same
    failure. Mutant: drop the serial loop's `col_errors[c] = ...` (red: the
    output batch build raises `column 1 has length 0` instead)."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var msg = String("")
    try:
        _ = _concat_csv_batches_column_parallel[
            has_dispatcher=False, disp_o=origin_of(disp)
        ](
            _disagreeing_batches(),
            2,
            2,
            _names(),
            _types(),
            Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](None),
            CancellationToken.new(),
        )
    except e:
        msg = String(e)
    assert_true(msg.find(_WANT) >= 0, "serial concat: got '" + msg + "'")


def main() raises:
    test_pool_concat_reraises_the_column_failure()
    test_serial_concat_reraises_the_column_failure()
    print("test_csv_cov_parallel_concat: 2 tests PASS")
