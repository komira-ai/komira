# The parallel residual mark join's table capacity: the epsilon-nearest
# setting (off by default) halves the table only when the build row count
# overshoots the lower power of two by less than 1/64, the capacity stays a
# power of two in both arms, and the joined rows do not depend on it.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_NE
from komira_plan_ir.logical_plan import JOIN_SEMI, JOIN_ANTI
from komira_physical_plan.physical_plan import MorselOp

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_join_probe.join_probe_settings import (
    reset_join_probe_settings,
    residual_mark_cap_nearest_on,
    residual_mark_chain_fill_elide_on,
    residual_mark_configure,
    residual_mark_prepare_parallel_on,
)
from komira_op_join_probe.nested_loop_join import (
    execute_residual_join_probe,
)
from komira_op_join_probe.residual_semi_anti_parallel import (
    parallel_residual_semi_anti_mark,
)
from komira_op_join_probe.residual_mark_counter import (
    GEOM_BUILD_ROWS,
    GEOM_CAP,
    residual_mark_geometry_count,
    residual_mark_geometry_field,
    reset_residual_mark_counters,
)


comptime I64 = DType.int64

comptime _N_FIRES = 366
comptime _CAP_FIRES_BASELINE = 1024
comptime _CAP_FIRES_NEAREST = 512

comptime _N_HOLDS = 288
comptime _CAP_HOLDS = 512


def _clear_env() raises:
    reset_join_probe_settings()


def _i64_arr(values: List[Int]) -> PrimitiveArray[I64]:
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[I64](values[i]))
    return arr^


def _i64_batch_2(
    name0: String, vals0: List[Int], name1: String, vals1: List[Int],
) raises -> RecordBatch:
    var a0 = _i64_arr(vals0)
    var a1 = _i64_arr(vals1)
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field(name1, ArrowType.INT64, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_primitive[I64](a0^))
    rb.add_column(Column.from_primitive[I64](a1^))
    return rb.build(schema^)


def _gen_probe(n: Int) raises -> RecordBatch:
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(i % 17)
        sk.append(i % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _gen_build(n: Int) raises -> RecordBatch:
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(i % 9)
        sk.append((i * 3) % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _gen_skew_build(n: Int) raises -> RecordBatch:
    """All orderkeys == 1: one bucket, one chain of length n. The shape where a
    capacity change has the most leverage on chain-walk behaviour.
    """
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(1)
        sk.append(i % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _residual_neq() -> Expr:
    return Expr.binary(
        BIN_NE, Expr.col_ref("l_suppkey"), Expr.col_ref("l_suppkey_right")
    )


def _semi_anti_op(join_type: UInt8, var residual: Expr) -> MorselOp:
    var lk: List[String] = ["l_orderkey"]
    var rk: List[String] = ["l_orderkey"]
    var op = MorselOp.join_probe(-1, lk^, rk^, join_type)
    op.probe_residual = residual^
    return op^


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run_parallel(
    imm probe: RecordBatch, imm build: RecordBatch, join_type: UInt8,
) raises -> RecordBatch:
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    return parallel_residual_semi_anti_mark(
        disp, ct.clone(), probe, build,
        String("l_orderkey"), String("l_orderkey"), join_type, _residual_neq(),
    )


def _run_serial(
    imm probe: RecordBatch, imm build: RecordBatch, join_type: UInt8,
) raises -> RecordBatch:
    var op = _semi_anti_op(join_type, _residual_neq())
    return execute_residual_join_probe(probe, build, op, _residual_neq())


def _assert_batches_equal(
    imm got: RecordBatch, imm want: RecordBatch, msg: String
) raises:
    assert_equal(got.num_rows(), want.num_rows(), msg + " num_rows")
    assert_equal(got.num_columns(), want.num_columns(), msg + " num_columns")
    for c in range(want.num_columns()):
        var cg = got.column_at(c).as_primitive[I64]()
        var cw = want.column_at(c).as_primitive[I64]()
        for r in range(want.num_rows()):
            assert_equal(
                Int(cg.get(r)), Int(cw.get(r)),
                msg + " cell[" + String(c) + "][" + String(r) + "]",
            )


def _cap_for(nb: Int, nearest: Bool) raises -> Int:
    """Drive the real driver over an `nb`-row build and return the capacity IT
    reports (item B's geometry counter) — not a reimplementation of the rule.
    """
    _clear_env()
    residual_mark_configure(force=True)
    if nearest:
        residual_mark_configure(cap_nearest=True)
    reset_residual_mark_counters()
    var probe = _gen_probe(300)
    var build = _gen_build(nb)
    var _r = _run_parallel(probe, build, JOIN_SEMI)
    assert_equal(residual_mark_geometry_count(), 1, "one invocation recorded")
    assert_equal(
        residual_mark_geometry_field(0, GEOM_BUILD_ROWS), nb,
        "the kernel must report the build rows it was actually given",
    )
    var cap = residual_mark_geometry_field(0, GEOM_CAP)
    _clear_env()
    return cap


def test_epsilon_nearest_halves_only_a_marginal_overshoot() raises:
    """The cap halves only a marginal overshoot, and only when configured."""
    _clear_env()
    assert_true(
        not residual_mark_cap_nearest_on(),
        "the epsilon-nearest gate must default OFF: it"
        " it TRADES footprint for chain length, unlike the move/delete gates",
    )

    var fires_base = _cap_for(_N_FIRES, False)
    var fires_near = _cap_for(_N_FIRES, True)
    var holds_base = _cap_for(_N_HOLDS, False)
    var holds_near = _cap_for(_N_HOLDS, True)
    print(
        "[L1] FIRES n=", _N_FIRES, " baseline cap=", fires_base,
        " nearest cap=", fires_near,
    )
    print(
        "[L1] HOLDS n=", _N_HOLDS, " baseline cap=", holds_base,
        " nearest cap=", holds_near,
    )

    assert_equal(
        fires_base, _CAP_FIRES_BASELINE,
        "baseline: 366 rows -> min_cap 513 -> round UP to 1024",
    )
    assert_equal(
        fires_near, _CAP_FIRES_NEAREST,
        "epsilon-nearest: min_cap 513 clears 512 by 1 slot, within 1/64, so the"
        " table must NOT double",
    )
    assert_equal(
        holds_base, _CAP_HOLDS, "baseline: 288 rows -> 512"
    )
    assert_equal(
        holds_near, _CAP_HOLDS,
        "epsilon-nearest must NOT fire at a 57.8% overshoot — a rule that"
        " always rounds down would report 256 here and be an under-provisioning"
        " bug, not an optimisation",
    )

    # THE SAFETY BOUND, ASSERTED ON THE ARM THAT FIRED. `cap < rows` is the
    # regime this epsilon exists to keep unreachable, and it has never run in
    # this tree. The analytic worst case is 1.4 / (1 + 1/64) = 1.378462.
    assert_true(
        fires_near > _N_FIRES,
        "cap must stay strictly above the build row count",
    )
    assert_true(
        fires_near * 1000 >= _N_FIRES * 1378,
        "cap/rows must stay at or above the 1.378462 epsilon bound — got "
        + String(fires_near) + "/" + String(_N_FIRES),
    )
    print("test_epsilon_nearest_halves_only_a_marginal_overshoot OK")


def test_answer_is_capacity_invariant() raises:
    """Both arms return byte-identical rows. This is a NO-REGRESS leg, not the
    oracle — see the file header: the match set is capacity-invariant because
    the chain walk filters on key equality, so this would pass even if the gate
    did nothing at all. Leg 1 is what proves the gate acts.
    """
    var probe = _gen_probe(300)
    var build = _gen_build(_N_FIRES)
    var semi_ser = _run_serial(probe, build, JOIN_SEMI)
    var anti_ser = _run_serial(probe, build, JOIN_ANTI)
    var skew_probe = _gen_probe(297)
    var skew_build = _gen_skew_build(_N_FIRES)
    var skew_ser = _run_serial(skew_probe, skew_build, JOIN_SEMI)

    for nearest in range(2):
        _clear_env()
        residual_mark_configure(force=True)
        if nearest == 1:
            residual_mark_configure(cap_nearest=True)
        reset_residual_mark_counters()
        var semi = _run_parallel(probe, build, JOIN_SEMI)
        var anti = _run_parallel(probe, build, JOIN_ANTI)
        var skew = _run_parallel(skew_probe, skew_build, JOIN_SEMI)
        print(
            "[L2] nearest=", nearest,
            " cap=", residual_mark_geometry_field(0, GEOM_CAP),
            " semi_rows=", semi.num_rows(), " anti_rows=", anti.num_rows(),
            " skew_rows=", skew.num_rows(),
        )
        _assert_batches_equal(semi, semi_ser, "SEMI vs serial")
        _assert_batches_equal(anti, anti_ser, "ANTI vs serial")
        _assert_batches_equal(skew, skew_ser, "skew SEMI vs serial")
        assert_true(semi_ser.num_rows() > 0, "SEMI must keep some rows")
        assert_true(anti_ser.num_rows() > 0, "ANTI must keep some rows")
    _clear_env()
    print("test_answer_is_capacity_invariant OK")


def test_capacity_stays_a_power_of_two_in_both_arms() raises:
    """The mask is not the only thing that needs this. `_ResidualPrepareTask`
    used to reconstruct `cap = mask + 1` and the driver derives `n_prep_morsels`
    from its own `cap`; those two agree only while cap is a power of two, and
    the module header calls their disagreement a MEMORY-SAFETY failure, not a
    wrong answer. (The reconstruction is now a carried field, but the mask
    itself still requires it.)
    """
    _clear_env()
    var sizes: List[Int] = [17, 100, 200, 288, 300, 366, 370, 371, 512, 730]
    for nearest in range(2):
        for si in range(len(sizes)):
            var nb = sizes[si]
            var cap = _cap_for(nb, nearest == 1)
            assert_true(
                cap > 0 and (cap & (cap - 1)) == 0,
                "cap must be a power of two (nearest=" + String(nearest)
                + ", rows=" + String(nb) + ", cap=" + String(cap) + ")",
            )
            assert_true(
                cap > nb,
                "cap must exceed the build row count (nearest="
                + String(nearest) + ", rows=" + String(nb) + ", cap="
                + String(cap) + ")",
            )
            assert_true(
                cap * 1000 >= nb * 1378,
                "cap/rows fell below the 1.378462 epsilon bound (nearest="
                + String(nearest) + ", rows=" + String(nb) + ", cap="
                + String(cap) + ")",
            )
    print("test_capacity_stays_a_power_of_two_in_both_arms OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_epsilon_nearest_halves_only_a_marginal_overshoot]()
    suite.test[test_answer_is_capacity_invariant]()
    suite.test[test_capacity_stays_a_power_of_two_in_both_arms]()
    suite^.run()
