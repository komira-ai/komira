# A composite-key join through `execute_join_probe` on both sides of the
# runtime build-side choice. An INNER join whose build side has more than
# twice the probe side's rows builds its table on the probe side; the output
# is the same rows, in probe-then-build column order. LEFT, SEMI and ANTI never
# switch sides. Each fixture is a 1:1 overlap of distinct (a, b) pairs, so the
# expected rows are exact: every output row's probe keys equal its build keys,
# and every probe pair appears once.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import MorselOp
from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI

from komira_op_join_probe.join_probe import execute_join_probe
from komira_op_join_probe.join_probe_multi_key import (
    should_flip_multi_key_inner_join,
)


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _synthetic(n: Int, a: String, b: String) raises -> RecordBatch:
    """`n` rows of distinct pairs (i // 8, i % 8)."""
    var c1 = List[Int64](capacity=n)
    var c2 = List[Int64](capacity=n)
    for i in range(n):
        c1.append(Int64(i // 8))
        c2.append(Int64(i % 8))
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, False))
    sb.add_field(Field(b, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(c1)))
    rb.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(c2)))
    return rb.build(sb.build())


def _run(n_probe: Int, n_build: Int, join_type: UInt8) raises -> RecordBatch:
    var probe = _synthetic(n_probe, "l_a", "l_b")
    var build = _synthetic(n_build, "r_a", "r_b")
    var op = MorselOp.join_probe(0, ["l_a", "l_b"], ["r_a", "r_b"], join_type)
    var rt = _runtime()
    ref d = rt.dispatcher()
    return execute_join_probe(d, CancellationToken.never(), probe, op, build)


def _assert_one_to_one(imm out: RecordBatch, n_probe: Int, what: String) raises:
    """Columns l_a, l_b, r_a, r_b; each row's probe keys equal its build
    keys; each probe pair exactly once."""
    assert_equal(out.num_rows(), n_probe, what + ": rows")
    assert_equal(out.num_columns(), 4, what + ": columns")
    assert_equal(out.schema.field_name(0), "l_a", what)
    assert_equal(out.schema.field_name(1), "l_b", what)
    assert_equal(out.schema.field_name(2), "r_a", what)
    assert_equal(out.schema.field_name(3), "r_b", what)
    var la = out.column_at(0).as_primitive[DType.int64]()
    var lb = out.column_at(1).as_primitive[DType.int64]()
    var ra = out.column_at(2).as_primitive[DType.int64]()
    var rbk = out.column_at(3).as_primitive[DType.int64]()
    var seen = List[Bool](length=n_probe, fill=False)
    for i in range(out.num_rows()):
        assert_equal(la.get(i), ra.get(i), what + ": a keys agree")
        assert_equal(lb.get(i), rbk.get(i), what + ": b keys agree")
        var row = Int(la.get(i)) * 8 + Int(lb.get(i))
        assert_false(seen[row], what + ": a probe pair twice")
        seen[row] = True


def test_flip_predicate_boundaries() raises:
    assert_true(should_flip_multi_key_inner_join(300, 100), "3x flips")
    assert_true(should_flip_multi_key_inner_join(201, 100), "2.01x flips")
    assert_false(should_flip_multi_key_inner_join(200, 100), "2x does not")
    assert_false(should_flip_multi_key_inner_join(150, 100), "1.5x does not")
    assert_false(should_flip_multi_key_inner_join(50, 100), "smaller build")
    assert_false(should_flip_multi_key_inner_join(1000, 0), "empty probe")
    assert_false(should_flip_multi_key_inner_join(0, 0), "both empty")


def test_inner_when_the_build_side_is_switched() raises:
    """Build 200,000 rows, probe 50,000: the table goes on the probe side."""
    assert_true(should_flip_multi_key_inner_join(200_000, 50_000))
    _assert_one_to_one(_run(50_000, 200_000, JOIN_INNER), 50_000, "switched")


def test_inner_below_the_switch() raises:
    """Build 11,000 rows, probe 10,000: the table stays on the build side."""
    assert_false(should_flip_multi_key_inner_join(11_000, 10_000))
    _assert_one_to_one(_run(10_000, 11_000, JOIN_INNER), 10_000, "unswitched")


def test_left_semi_anti_never_switch() raises:
    _assert_one_to_one(_run(50_000, 200_000, JOIN_LEFT), 50_000, "LEFT")
    var semi = _run(50_000, 200_000, JOIN_SEMI)
    assert_equal(semi.num_rows(), 50_000, "SEMI keeps every probe row once")
    assert_equal(semi.num_columns(), 2, "SEMI keeps probe columns only")
    var anti = _run(50_000, 200_000, JOIN_ANTI)
    assert_equal(anti.num_rows(), 0, "ANTI: every probe row matched")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
