# `execute_multi_key_join_probe`, the composite join probe operator, over a
# physical plan's `MorselOp`: INNER (both sides of the build-side choice, the
# full and the projected output), LEFT (with and without build rows), SEMI and
# ANTI (with and without build rows, projected), and the refusal of a join type
# it does not run. Every answer is checked row by row, not by count.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import MorselOp
from komira_plan_ir.logical_plan import (
    JOIN_ANTI,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
)

from komira_op_join_probe.join_probe_multi_key import (
    execute_multi_key_join_probe,
    should_flip_multi_key_inner_join,
)


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _i64(values: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _batch3(
    n0: String, a: List[Int64], n1: String, b: List[Int64], n2: String,
    c: List[Int64],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(n0, ArrowType.INT64, False))
    sb.add_field(Field(n1, ArrowType.INT64, False))
    sb.add_field(Field(n2, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(a))
    rb.add_column(_i64(b))
    rb.add_column(_i64(c))
    return rb.build(sb.build())


def _probe() raises -> RecordBatch:
    """Probe (a, b, pv): (1,10,100) (1,20,101) (2,10,102) (3,30,103)."""
    return _batch3("a", [1, 1, 2, 3], "b", [10, 20, 10, 30], "pv", [100, 101, 102, 103])


def _build() raises -> RecordBatch:
    """Build (x, y, bv): (1,10,500) (1,10,501) (2,10,502) (9,9,509)."""
    return _batch3("x", [1, 1, 2, 9], "y", [10, 10, 10, 9], "bv", [500, 501, 502, 509])


def _empty_build() raises -> RecordBatch:
    return _batch3("x", List[Int64](), "y", List[Int64](), "bv", List[Int64]())


def _op(join_type: UInt8) -> MorselOp:
    return MorselOp.join_probe(0, ["a", "b"], ["x", "y"], join_type)


def _op_projected(join_type: UInt8, var cols: List[String]) -> MorselOp:
    return MorselOp.join_probe_projected(
        0, ["a", "b"], ["x", "y"], join_type, cols^
    )


def _col(imm batch: RecordBatch, name: String) raises -> List[Int64]:
    var a = batch.column_at(batch.column_by_name(name)).as_primitive[DType.int64]()
    var out = List[Int64]()
    for i in range(a.length):
        out.append(a.get(i) if not a.is_null(i) else Int64(-1))
    return out^


def _rows(imm batch: RecordBatch, n0: String, n1: String) raises -> List[Int64]:
    """Rows of two columns encoded `v0 * 1000 + v1` (NULL as -1), sorted."""
    var c0 = _col(batch, n0)
    var c1 = _col(batch, n1)
    var out = List[Int64]()
    for i in range(len(c0)):
        out.append(c0[i] * 1000 + c1[i])
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            var t = out[j - 1]
            out[j - 1] = out[j]
            out[j] = t
            j -= 1
    return out^


def _assert_rows(imm got: List[Int64], imm want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _run(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    imm probe: RecordBatch,
    imm op: MorselOp,
    imm build: RecordBatch,
) raises -> RecordBatch:
    ref d = rt.dispatcher()
    return execute_multi_key_join_probe(
        d, CancellationToken.never(), probe, op, build
    )


def test_inner_full_and_projected() raises:
    """(1,10) matches build rows 500 and 501; (2,10) matches 502."""
    var rt = _runtime()
    var out = _run(rt, _probe(), _op(JOIN_INNER), _build())
    assert_equal(out.schema.num_columns(), 6, "probe columns then build columns")
    _assert_rows(_rows(out, "pv", "bv"), [100500, 100501, 102502], "INNER")
    var proj = _run(rt, _probe(), _op_projected(JOIN_INNER, ["pv", "bv"]), _build())
    assert_equal(proj.schema.num_columns(), 2, "projected INNER")
    _assert_rows(_rows(proj, "pv", "bv"), [100500, 100501, 102502], "INNER proj")


def test_inner_build_side_choice_keeps_the_rows() raises:
    """A build side more than twice the probe's is indexed on the probe side;
    the joined rows are the same."""
    assert_true(should_flip_multi_key_inner_join(9, 4), "9 > 2 * 4")
    assert_true(not should_flip_multi_key_inner_join(8, 4), "8 = 2 * 4")
    assert_true(not should_flip_multi_key_inner_join(9, 0), "empty probe")
    var big = _batch3(
        "x", [1, 1, 2, 9, 7, 7, 7, 7, 7], "y", [10, 10, 10, 9, 7, 7, 7, 7, 7],
        "bv", [500, 501, 502, 509, 600, 601, 602, 603, 604],
    )
    var rt = _runtime()
    var out = _run(rt, _probe(), _op(JOIN_INNER), big)
    _assert_rows(_rows(out, "pv", "bv"), [100500, 100501, 102502], "flipped INNER")


def test_left_keeps_unmatched_probe_rows() raises:
    var rt = _runtime()
    var out = _run(rt, _probe(), _op(JOIN_LEFT), _build())
    _assert_rows(
        _rows(out, "pv", "bv"), [100500, 100501, 101000 - 1, 102502, 103000 - 1],
        "LEFT",
    )
    var empty = _run(rt, _probe(), _op(JOIN_LEFT), _empty_build())
    _assert_rows(
        _rows(empty, "pv", "bv"),
        [100000 - 1, 101000 - 1, 102000 - 1, 103000 - 1],
        "LEFT, no build rows",
    )


def test_semi_and_anti() raises:
    var rt = _runtime()
    var semi = _run(rt, _probe(), _op(JOIN_SEMI), _build())
    assert_equal(semi.schema.num_columns(), 3, "SEMI keeps probe columns only")
    _assert_rows(_rows(semi, "a", "pv"), [1100, 2102], "SEMI")
    var anti = _run(rt, _probe(), _op_projected(JOIN_ANTI, ["pv"]), _build())
    assert_equal(anti.schema.num_columns(), 1, "projected ANTI")
    _assert_rows(_rows(anti, "pv", "pv"), [101101, 103103], "ANTI")
    var semi0 = _run(rt, _probe(), _op(JOIN_SEMI), _empty_build())
    assert_equal(semi0.num_rows(), 0, "SEMI, no build rows")
    var anti0 = _run(rt, _probe(), _op(JOIN_ANTI), _empty_build())
    _assert_rows(
        _rows(anti0, "a", "pv"), [1100, 1101, 2102, 3103], "ANTI, no build rows"
    )


def test_unsupported_join_type_raises() raises:
    var rt = _runtime()
    var raised = False
    try:
        _ = _run(rt, _probe(), _op(JOIN_FULL), _build())
    except:
        raised = True
    assert_true(raised, "FULL is not this operator's to run")


def main() raises:
    var suite = TestSuite()
    suite.test[test_inner_full_and_projected]()
    suite.test[test_inner_build_side_choice_keeps_the_rows]()
    suite.test[test_left_keeps_unmatched_probe_rows]()
    suite.test[test_semi_and_anti]()
    suite.test[test_unsupported_join_type_raises]()
    suite^.run()
