# `execute_multi_key_join_probe`, the composite join probe operator, over a
# physical plan's `MorselOp`: INNER (both sides of the build-side choice, the
# full and the projected output), LEFT (with and without build rows), SEMI and
# ANTI (with and without build rows, projected), the refusal of a join type, a
# residual predicate or a probe algorithm it does not run, the no-row results
# with their schema, the `_right` rename of colliding names, and the parallel
# probe (a probe above the threshold, with the build side indexed or not). Every
# answer is checked row by row, not by count.

from std.collections import Set
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
from komira_async.runtime.sched_trace import SITE_JOIN_MULTIKEY
from komira_async_api.token import CancellationToken
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_ROWS,
    grain_geometry_field,
    grain_geometry_reset,
)
from komira_physical_plan.physical_plan import MorselOp
from komira_plan_expr.expr import BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    JOIN_ANTI,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_ALGO_SORT_MERGE,
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


def _refusal(
    imm probe: RecordBatch, imm op: MorselOp, imm build: RecordBatch,
    what: String,
) raises:
    """The operator raises with `what` in its message."""
    var rt = _runtime()
    var message = String("")
    var raised = False
    try:
        _ = _run(rt, probe, op, build)
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "the operator returned instead of raising: " + what)
    assert_true(what in message, "the error does not say '" + what + "': " + message)


def test_residual_predicate_is_refused_not_ignored() raises:
    """A residual that keeps no row must not come back as the unfiltered join:
    the operator names the residual and raises, for a probe with rows and for
    an empty one."""
    var residual = Expr.binary(
        BIN_GT, Expr.col_ref(String("a")),
        Expr.literal(ScalarValue.from_int64(1000)),
    )
    var op = MorselOp.join_probe_with_residual(
        0, ["a", "b"], ["x", "y"], JOIN_INNER, residual^, None
    )
    _refusal(_probe(), op, _build(), "residual predicate")
    _refusal(_empty_build(), op, _build(), "residual predicate")


def test_other_probe_algorithm_is_refused() raises:
    """A sort-merge operator is not run as a hash join, with rows or with an
    empty probe or build side."""
    var op = MorselOp.join_probe(
        0, ["a", "b"], ["x", "y"], JOIN_INNER, JOIN_ALGO_SORT_MERGE
    )
    _refusal(_probe(), op, _build(), "probe_algo=2")
    _refusal(_empty_build(), op, _build(), "probe_algo=2")
    _refusal(_probe(), op, _empty_build(), "probe_algo=2")


def test_unsupported_join_type_is_refused_for_empty_inputs_too() raises:
    """FULL raises with an empty probe or build side as it does with rows."""
    _refusal(_probe(), _op(JOIN_FULL), _build(), "unsupported join_type")
    _refusal(_empty_build(), _op(JOIN_FULL), _build(), "unsupported join_type")
    _refusal(_probe(), _op(JOIN_FULL), _empty_build(), "unsupported join_type")


def _names(imm batch: RecordBatch) -> List[String]:
    var out = List[String]()
    for i in range(batch.schema.num_columns()):
        out.append(batch.schema.field_name(i))
    return out^


def _assert_schema(imm batch: RecordBatch, imm want: List[String], what: String) raises:
    var got = _names(batch)
    assert_equal(len(got), len(want), what + ": column count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": column " + String(i))
    assert_equal(batch.num_rows(), 0, what + ": rows")


def test_empty_probe_returns_no_rows_with_the_output_schema() raises:
    """An empty probe side gives no rows and the schema the join would have:
    probe columns then build columns for INNER and LEFT, probe columns for SEMI
    and ANTI, and only the projected columns when the operator projects."""
    var rt = _runtime()
    var empty = _batch3("a", List[Int64](), "b", List[Int64](), "pv", List[Int64]())
    var full: List[String] = ["a", "b", "pv", "x", "y", "bv"]
    var probe_cols: List[String] = ["a", "b", "pv"]
    _assert_schema(_run(rt, empty, _op(JOIN_INNER), _build()), full, "INNER")
    _assert_schema(_run(rt, empty, _op(JOIN_LEFT), _build()), full, "LEFT")
    _assert_schema(_run(rt, empty, _op(JOIN_SEMI), _build()), probe_cols, "SEMI")
    _assert_schema(_run(rt, empty, _op(JOIN_ANTI), _build()), probe_cols, "ANTI")
    var cut: List[String] = ["pv", "bv"]
    _assert_schema(
        _run(rt, empty, _op_projected(JOIN_INNER, ["pv", "bv"]), _build()),
        cut, "INNER projected",
    )
    _assert_schema(
        _run(rt, empty, _op_projected(JOIN_LEFT, ["pv", "bv"]), _build()),
        cut, "LEFT projected",
    )
    # An empty probe against an empty build too.
    _assert_schema(_run(rt, empty, _op(JOIN_INNER), _empty_build()), full, "INNER, both empty")


def test_empty_build_returns_no_rows_with_the_output_schema() raises:
    """An empty build side of an INNER or SEMI join: no rows, the output schema."""
    var rt = _runtime()
    var full: List[String] = ["a", "b", "pv", "x", "y", "bv"]
    var probe_cols: List[String] = ["a", "b", "pv"]
    _assert_schema(_run(rt, _probe(), _op(JOIN_INNER), _empty_build()), full, "INNER")
    _assert_schema(_run(rt, _probe(), _op(JOIN_SEMI), _empty_build()), probe_cols, "SEMI")
    var cut: List[String] = ["bv"]
    _assert_schema(
        _run(rt, _probe(), _op_projected(JOIN_INNER, ["bv"]), _empty_build()),
        cut, "INNER projected",
    )


def test_empty_input_semi_and_anti_honour_the_projection() raises:
    """SEMI and ANTI with an empty probe or an empty build side, projected to
    one probe column: the output schema is that column; ANTI with no build rows
    keeps every probe row, SEMI keeps none."""
    var rt = _runtime()
    var empty = _batch3("a", List[Int64](), "b", List[Int64](), "pv", List[Int64]())
    var cut: List[String] = ["pv"]
    for t in [JOIN_SEMI, JOIN_ANTI]:
        _assert_schema(
            _run(rt, empty, _op_projected(t, ["pv"]), _build()), cut, "empty probe"
        )
    _assert_schema(
        _run(rt, _probe(), _op_projected(JOIN_SEMI, ["pv"]), _empty_build()),
        cut, "SEMI, empty build",
    )
    var anti = _run(rt, _probe(), _op_projected(JOIN_ANTI, ["pv"]), _empty_build())
    assert_equal(anti.schema.num_columns(), 1, "ANTI, empty build: columns")
    assert_equal(anti.schema.field_name(0), "pv", "ANTI, empty build: column")
    _assert_rows(_rows(anti, "pv", "pv"), [100100, 101101, 102102, 103103], "ANTI, empty build")


def test_colliding_names_get_the_right_suffix() raises:
    """Build columns named like probe columns come out as `<name>_right`, for
    INNER and LEFT, with the values of the right side under the new name."""
    var probe = _batch3("a", [1, 2], "b", [10, 10], "v", [100, 101])
    var build = _batch3("a", [1, 2], "b", [10, 10], "v", [500, 502])
    var op = MorselOp.join_probe(0, ["a", "b"], ["a", "b"], JOIN_INNER)
    var rt = _runtime()
    var out = _run(rt, probe, op, build)
    var want: List[String] = ["a", "b", "v", "a_right", "b_right", "v_right"]
    assert_equal(out.num_rows(), 2)
    var got = _names(out)
    for i in range(6):
        assert_equal(got[i], want[i], "INNER column " + String(i))
    _assert_rows(_rows(out, "v", "v_right"), [100500, 101502], "INNER values")
    var op_left = MorselOp.join_probe(0, ["a", "b"], ["a", "b"], JOIN_LEFT)
    var left = _run(rt, probe, op_left, build)
    var left_names = _names(left)
    for i in range(6):
        assert_equal(left_names[i], want[i], "LEFT column " + String(i))


def test_flipped_inner_with_projection_keeps_the_pairs() raises:
    """The build side is more than twice the probe's, so the join indexes the
    probe side; the projected output still pairs each probe row with its own
    build rows."""
    var big = _batch3(
        "x", [1, 1, 2, 9, 7, 7, 7, 7, 7], "y", [10, 10, 10, 9, 7, 7, 7, 7, 7],
        "bv", [500, 501, 502, 509, 600, 601, 602, 603, 604],
    )
    var rt = _runtime()
    var out = _run(rt, _probe(), _op_projected(JOIN_INNER, ["pv", "bv"]), big)
    assert_equal(out.schema.num_columns(), 2)
    _assert_rows(_rows(out, "pv", "bv"), [100500, 100501, 102502], "flipped projected")


def _wide(
    n: Int, shift: Int, c0: String, c1: String, cv: String
) raises -> RecordBatch:
    """Row i: (key0, key1, i) where the keys are those of row i + `shift`:
    ((i + shift) % 997, (i + shift) % 991)."""
    var a = List[Int64](capacity=n)
    var b = List[Int64](capacity=n)
    var v = List[Int64](capacity=n)
    for i in range(n):
        a.append(Int64((i + shift) % 997))
        b.append(Int64((i + shift) % 991))
        v.append(Int64(i))
    return _batch3(c0, a, c1, b, cv, v)


comptime _SHIFT: Int = 7


def _parallel_case(np: Int, nb: Int) raises:
    """Row by row. Build row j carries the key pair of row j + 7, and the pairs
    (row % 997, row % 991) are unique among fewer than 988,000 rows, so probe
    row i meets exactly build row i - 7 (when it exists): the output has
    min(np, nb + 7) - 7 pairs, none repeats, and every pair has probe value
    minus build value equal to 7. The pairs sit off the diagonal, so output
    lists swapped between the probe and build sides show up as a different
    difference. The probe's recorded split shows that the parallel branch ran,
    over the side the join indexes: the probe rows, or the build rows when the
    join flips."""
    var probe = _wide(np, 0, "a", "b", "pv")
    var build = _wide(nb, _SHIFT, "x", "y", "bv")
    var rt = _runtime()
    grain_geometry_reset()
    var out = _run(rt, probe, _op(JOIN_INNER), build)
    var want = min(np, nb + _SHIFT) - _SHIFT
    assert_equal(out.num_rows(), want, "pair count")
    var pv = _col(out, "pv")
    var bv = _col(out, "bv")
    var seen = Set[Int]()
    for r in range(out.num_rows()):
        var i = Int(pv[r])
        var j = Int(bv[r])
        assert_true(i >= 0 and i < np and j >= 0 and j < nb, "row index out of range")
        assert_equal(i - j, _SHIFT, "probe row minus build row")
        seen.add(i * 1_000_000 + j)
    assert_equal(len(seen), want, "a pair repeats")
    var parallel_rows = nb if should_flip_multi_key_inner_join(nb, np) else np
    assert_equal(
        grain_geometry_field(SITE_JOIN_MULTIKEY, GRAIN_F_ROWS),
        parallel_rows,
        "rows of the parallel probe",
    )


def test_parallel_probe_off_the_diagonal_not_flipped() raises:
    """120,000 probe rows against 1,000 build rows: the parallel probe over the
    probe rows, build side indexed; probe row i pairs with build row i - 7."""
    assert_true(not should_flip_multi_key_inner_join(1_000, 120_000), "not flipped")
    _parallel_case(120_000, 1_000)


def test_parallel_probe_off_the_diagonal_flipped() raises:
    """40,000 probe rows against 130,000 build rows: the join indexes the probe
    side and the 130,000 build rows run through the parallel probe; each pair
    keeps its probe row and its build row on the right sides."""
    assert_true(should_flip_multi_key_inner_join(130_000, 40_000), "flipped")
    _parallel_case(40_000, 130_000)


def main() raises:
    var suite = TestSuite()
    suite.test[test_inner_full_and_projected]()
    suite.test[test_inner_build_side_choice_keeps_the_rows]()
    suite.test[test_left_keeps_unmatched_probe_rows]()
    suite.test[test_semi_and_anti]()
    suite.test[test_unsupported_join_type_raises]()
    suite.test[test_residual_predicate_is_refused_not_ignored]()
    suite.test[test_other_probe_algorithm_is_refused]()
    suite.test[test_unsupported_join_type_is_refused_for_empty_inputs_too]()
    suite.test[test_empty_probe_returns_no_rows_with_the_output_schema]()
    suite.test[test_empty_build_returns_no_rows_with_the_output_schema]()
    suite.test[test_empty_input_semi_and_anti_honour_the_projection]()
    suite.test[test_colliding_names_get_the_right_suffix]()
    suite.test[test_flipped_inner_with_projection_keeps_the_pairs]()
    suite.test[test_parallel_probe_off_the_diagonal_not_flipped]()
    suite.test[test_parallel_probe_off_the_diagonal_flipped]()
    suite^.run()
