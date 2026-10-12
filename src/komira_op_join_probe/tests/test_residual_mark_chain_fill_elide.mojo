# The parallel residual mark join's skipped zero fill of the chain links: the
# build writes every link, so the elision is exact (checked over poisoned
# memory), the setting changes what the PREPARE wave dispatches, the
# driver-side fill arm agrees, and SEMI / ANTI answer the serial kernel.

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
    _ResidualBuildTask,
    _ResidualMarkCtx,
    _ResidualMarkState,
)
from komira_op_join_build.join import _CHAIN_END
from komira_op_join_probe.residual_mark_counter import (
    residual_mark_prepare_morsels,
    reset_residual_mark_counters,
)


comptime I64 = DType.int64

comptime _TEST_FILL_GRAIN = 48

comptime _POISON_I64: Int = 0x7E7E7E7E7E7E7E7E

comptime _GUARD = 64


def _clear_env() raises:
    """Every setting this file drives back to its default."""
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
    """All orderkeys == 1: ONE bucket, ONE giant chain. The worst case for the
    Treiber push (maximum CAS contention) and the shape in which a self-loop
    would actually hang.
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


def _assert_build_covers_next_chain(
    nb: Int, cap: Int, var build: RecordBatch, label: String
) raises:
    """Poison `next_chain`, run the REAL `_ResidualBuildTask` over the
    production 4-worker runtime, and assert every element was written exactly
    the way a Treiber push must write it.
    """
    var ht = List[Int64]()
    ht.resize(cap, Int64(_CHAIN_END))
    var nc = List[Int64]()
    nc.resize(nb + _GUARD, Int64(_POISON_I64))
    var hp = List[UInt8]()
    hp.resize(8, UInt8(0))

    var kv = List[Int]()
    for i in range(8):
        kv.append(i)
    var pk = _i64_arr(kv)
    var bcol = build.column_at(0).as_primitive[I64]()
    var probe_small = _gen_probe(8)
    var ctx = _ResidualMarkCtx(
        probe_small^, build^, pk^, bcol^, _residual_neq()
    )

    var morsel_size = 1
    var num_build_morsels = (nb + morsel_size - 1) // morsel_size
    var state = _ResidualMarkState(
        morsel_size,          # build_morsel_size — the grain under test
        morsel_size,          # probe_morsel_size — unread by BUILD
        num_build_morsels,
        nb,
        1,                    # num_probe_morsels — unread by BUILD
        8,                    # num_probe_rows    — unread by BUILD
        _TEST_FILL_GRAIN,     # fill_morsel       — unread by BUILD
        0,                    # chain_fill_rows   — unread by BUILD
        cap,
        UInt64(cap - 1),
        ctx^,
        ht^,
        nc^,
        hp^,
    )

    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var task = _ResidualBuildTask(Int32(0))
    _ = disp.run_with_state[_ResidualMarkState, _ResidualBuildTask](
        state, task^, 4, ct.clone()
    )

    var unwritten = 0
    var first_unwritten = -1
    var self_loops = 0
    var first_self_loop = -1
    var out_of_range = 0
    for i in range(nb):
        var v = Int(state.next_chain[i])
        if v == _POISON_I64:
            unwritten += 1
            if first_unwritten < 0:
                first_unwritten = i
        if v == i:
            self_loops += 1
            if first_self_loop < 0:
                first_self_loop = i
        if v != _CHAIN_END and (v < 0 or v >= nb):
            out_of_range += 1

    var oob_writes = 0
    for i in range(nb, nb + _GUARD):
        if Int(state.next_chain[i]) != _POISON_I64:
            oob_writes += 1

    print(
        "[L1:", label, "] nb=", nb, " cap=", cap,
        " unwritten=", unwritten, " self_loops=", self_loops,
        " out_of_range=", out_of_range, " guard_writes=", oob_writes,
    )
    assert_equal(
        unwritten, 0,
        label + ": " + String(unwritten) + " of " + String(nb)
        + " next_chain elements were NOT written by the build wave (first at"
        " index " + String(first_unwritten) + "). The fill that used to cover"
        " them is deleted, so each is uninitialised memory the probe will walk"
        " as a chain link — and because a recycled allocation holds valid"
        " in-range indices, the symptom is a SILENT WRONG ANSWER, not a crash",
    )
    assert_equal(
        self_loops, 0,
        label + ": " + String(self_loops) + " SELF-LOOP link(s)"
        " next_chain[i] == i (first at index " + String(first_self_loop)
        + "). A morsel executed twice; the probe's chain walk cannot terminate",
    )
    assert_equal(
        out_of_range, 0,
        label + ": " + String(out_of_range) + " link(s) outside"
        " [0, nb) and not _CHAIN_END",
    )
    assert_equal(
        oob_writes, 0,
        label + ": " + String(oob_writes) + " OUT-OF-BOUNDS writes past"
        " num_build_rows",
    )
    _ = state^


def test_build_wave_writes_every_next_chain_element() raises:
    """The whole elision rests on one claim: the build
    writes every `next_chain` element before anything reads it. This poisons the
    buffer and checks all of it, on both the uniform and the single-bucket skew
    shape (maximum CAS retry pressure — the case where a lost race could plausibly
    skip a write).
    """
    _clear_env()
    _assert_build_covers_next_chain(
        288, 512, _gen_build(288), String("uniform")
    )
    _assert_build_covers_next_chain(
        256, 512, _gen_skew_build(256), String("skew-1-bucket")
    )
    print("test_build_wave_writes_every_next_chain_element OK")


def test_elide_gate_both_arms_are_observable() raises:
    """The setting must genuinely change WHAT THE PREPARE WAVE DISPATCHES,
    not merely be readable. `residual_mark_prepare_morsels()` is the driver's own
    flattened-index-space count, so it prices the regions directly.
    """
    _clear_env()
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var ser = _run_serial(probe, build, JOIN_SEMI)

    _clear_env()
    residual_mark_configure(force=True)
    residual_mark_configure(fill_morsel=_TEST_FILL_GRAIN)
    reset_residual_mark_counters()
    assert_true(
        residual_mark_chain_fill_elide_on(),
        "the next_chain fill elision must default ON when the switch is unset",
    )
    var on = _run_parallel(probe, build, JOIN_SEMI)
    var on_morsels = residual_mark_prepare_morsels()
    print("[L2] elide ON  (default): prepare morsels=", on_morsels)
    assert_equal(
        on_morsels, 18,
        "with the elision ON the PREPARE wave must dispatch ht(11) +"
        " has_pass(7) = 18 morsels and NOT the next_chain region — got "
        + String(on_morsels),
    )
    _assert_batches_equal(on, ser, "elide ON vs serial")

    _clear_env()
    residual_mark_configure(force=True)
    residual_mark_configure(fill_morsel=_TEST_FILL_GRAIN)
    residual_mark_configure(chain_fill_elide=False)
    reset_residual_mark_counters()
    assert_true(
        not residual_mark_chain_fill_elide_on(),
        "chain_fill_elide=False must restore the next_chain fill",
    )
    var off = _run_parallel(probe, build, JOIN_SEMI)
    var off_morsels = residual_mark_prepare_morsels()
    print("[L2] elide OFF (=0):      prepare morsels=", off_morsels)
    assert_equal(
        off_morsels, 24,
        "with the elision OFF the PREPARE wave must dispatch all three"
        " regions: ht(11) + next_chain(6) + has_pass(7) = 24 — got "
        + String(off_morsels),
    )
    _assert_batches_equal(off, ser, "elide OFF vs serial")
    _clear_env()
    print("test_elide_gate_both_arms_are_observable OK")


def test_serial_prepare_arm_also_elides() raises:
    """`prepare_parallel=False` takes the driver-side `resize(n, fill)`
    path. That arm must ALSO stop zero-filling `next_chain`, or the setting
    quietly reintroduces the benign zeros that hide a coverage gap — the arm
    everyone reaches for when the fanned arm looks wrong would then be the one
    arm that cannot fail.
    """
    _clear_env()
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var semi_ser = _run_serial(probe, build, JOIN_SEMI)
    var anti_ser = _run_serial(probe, build, JOIN_ANTI)

    for elide_off in range(2):
        _clear_env()
        residual_mark_configure(force=True)
        residual_mark_configure(prepare_parallel=False)
        if elide_off == 1:
            residual_mark_configure(chain_fill_elide=False)
        reset_residual_mark_counters()
        var semi = _run_parallel(probe, build, JOIN_SEMI)
        var anti = _run_parallel(probe, build, JOIN_ANTI)
        var m = residual_mark_prepare_morsels()
        print(
            "[L3] PREP=0 elide_off=", elide_off, " prepare morsels=", m,
            " semi_rows=", semi.num_rows(), " anti_rows=", anti.num_rows(),
        )
        assert_equal(
            m, 0,
            "with PREPARE_PARALLEL=0 the fill wave must not dispatch at all",
        )
        _assert_batches_equal(semi, semi_ser, "serial-prepare SEMI vs serial")
        _assert_batches_equal(anti, anti_ser, "serial-prepare ANTI vs serial")
    _clear_env()
    print("test_serial_prepare_arm_also_elides OK")


def test_skew_and_anti_unchanged_under_elision() raises:
    """NO-REGRESS, and NOT the oracle for this change (see the file header: the
    result batch is structurally blind to a coverage gap). It is here because
    the single-bucket skew is the shape where a chain defect would actually
    show — one bucket, one chain of length nb, every probe row walking all of
    it — so a self-loop hangs and a truncated chain drops matches.
    """
    _clear_env()
    residual_mark_configure(force=True)
    var probe = _gen_probe(297)
    var build = _gen_skew_build(256)
    var semi_par = _run_parallel(probe, build, JOIN_SEMI)
    var semi_ser = _run_serial(probe, build, JOIN_SEMI)
    _assert_batches_equal(semi_par, semi_ser, "skew SEMI under elision")
    var anti_par = _run_parallel(probe, build, JOIN_ANTI)
    var anti_ser = _run_serial(probe, build, JOIN_ANTI)
    _assert_batches_equal(anti_par, anti_ser, "skew ANTI under elision")
    assert_true(semi_ser.num_rows() > 0, "skew SEMI must keep some rows")
    assert_true(anti_ser.num_rows() > 0, "skew ANTI must keep some rows")
    _clear_env()
    print("test_skew_and_anti_unchanged_under_elision OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_build_wave_writes_every_next_chain_element]()
    suite.test[test_elide_gate_both_arms_are_observable]()
    suite.test[test_serial_prepare_arm_also_elides]()
    suite.test[test_skew_and_anti_unchanged_under_elision]()
    suite^.run()
