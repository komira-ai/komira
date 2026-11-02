# The parallel residual mark join against the serial residual join, cell for
# cell: SEMI, ANTI, their partition of the probe rows, a one-bucket skew, the
# routing wrapper, the fire and decline witnesses, the eligibility gate, every
# element of the three buffers written by the PREPARE wave, and its geometry.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_NE
from komira_plan_ir.logical_plan import JOIN_SEMI, JOIN_ANTI, JOIN_INNER
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
    execute_residual_join_probe_parallel,
)
from komira_op_join_probe.residual_semi_anti_parallel import (
    parallel_residual_semi_anti_mark,
    _residual_mark_parallel_eligible,
    _ResidualMarkCtx,
    _ResidualMarkState,
    _ResidualPrepareTask,
)
from komira_op_join_build.join import _CHAIN_END
from komira_op_join_probe.residual_mark_counter import (
    residual_mark_fire_count,
    residual_mark_worker_span,
    residual_mark_prepare_morsels,
    residual_mark_prepare_worker_span,
    reset_residual_mark_counters,
)


comptime I64 = DType.int64

comptime _TEST_FILL_GRAIN = 48

comptime _POISON_I64: Int = 0x7E7E7E7E7E7E7E7E
comptime _POISON_U8: Int = 0x7E

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


def _gen_probe(n: Int) raises -> RecordBatch:
    """`n`-row probe [l_orderkey, l_suppkey] with duplicated orderkeys + a mix of
    matching / non-matching suppkeys.
    """
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(i % 17)
        sk.append(i % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _gen_build(n: Int) raises -> RecordBatch:
    """`n`-row build [l_orderkey, l_suppkey]. Orderkeys 0..8 only (a SUBSET of the
    probe's 0..16), varied suppkeys: probe orderkeys 9..16 have NO build match
    (SEMI drops them) while 0..8 match a build row with a differing suppkey (residual
    passes -> SEMI keeps) — a genuine mix so SEMI and ANTI are both non-trivial.
    """
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(i % 9)
        sk.append((i * 3) % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _gen_skew_build(n: Int) raises -> RecordBatch:
    """`n`-row build with ALL orderkeys == 1 (one giant chain / one bucket) — the
    b1-style skew: heavy CAS contention on a single `ht` slot during the parallel
    build. suppkeys vary so the residual still discriminates.
    """
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(1)
        sk.append(i % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _gen_skew_probe(n: Int) raises -> RecordBatch:
    """`n`-row probe where ~1/3 of orderkeys == 1 (match the skewed build) and the
    rest miss entirely.
    """
    var ok = List[Int]()
    var sk = List[Int]()
    for i in range(n):
        ok.append(1 if (i % 3 == 0) else (100 + i))
        sk.append(i % 5)
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _assert_batches_equal(
    imm got: RecordBatch, imm want: RecordBatch, msg: String
) raises:
    """Byte-oracle: identical shape + every cell equal IN ORDER (both kernels emit
    probe rows in ascending probe-row order).
    """
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


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run_parallel(
    imm probe: RecordBatch, imm build: RecordBatch, join_type: UInt8,
) raises -> RecordBatch:
    """Drive the PARALLEL kernel over a fresh 4-worker runtime (FORCE grain so the
    tiny fixture fans across every worker).
    """
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


def _run_wrapper(
    imm probe: RecordBatch, imm build: RecordBatch, join_type: UInt8,
) raises -> RecordBatch:
    """Drive the ROUTING wrapper `execute_residual_join_probe_parallel` (the real
    integration door) over a fresh 4-worker runtime.
    """
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var op = _semi_anti_op(join_type, _residual_neq())
    return execute_residual_join_probe_parallel(
        disp, ct.clone(), probe, build, op, _residual_neq()
    )


def _run_serial(
    imm probe: RecordBatch, imm build: RecordBatch, join_type: UInt8,
) raises -> RecordBatch:
    var op = _semi_anti_op(join_type, _residual_neq())
    return execute_residual_join_probe(probe, build, op, _residual_neq())


def test_semi_byte_equiv() raises:
    """SEMI: parallel kernel == serial kernel, cell-for-cell, over a 300-row fixture
    fanned across 4 workers.
    """
    residual_mark_configure(force=True)
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var par = _run_parallel(probe, build, JOIN_SEMI)
    var ser = _run_serial(probe, build, JOIN_SEMI)
    _assert_batches_equal(par, ser, "SEMI parallel-vs-serial")
    assert_true(ser.num_rows() > 0, "SEMI must keep some rows")
    assert_true(ser.num_rows() < 300, "SEMI must drop some rows")
    residual_mark_configure(force=False)


def test_anti_byte_equiv() raises:
    """ANTI: parallel kernel == serial kernel, cell-for-cell."""
    residual_mark_configure(force=True)
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var par = _run_parallel(probe, build, JOIN_ANTI)
    var ser = _run_serial(probe, build, JOIN_ANTI)
    _assert_batches_equal(par, ser, "ANTI parallel-vs-serial")
    assert_true(ser.num_rows() > 0, "ANTI must keep some rows")
    assert_true(ser.num_rows() < 300, "ANTI must drop some rows")
    residual_mark_configure(force=False)


def test_semi_anti_complement() raises:
    """SEMI ∪ ANTI == every probe row (partition): a cross-check independent of the
    serial oracle. |SEMI| + |ANTI| == num_probe_rows.
    """
    residual_mark_configure(force=True)
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var semi = _run_parallel(probe, build, JOIN_SEMI)
    var anti = _run_parallel(probe, build, JOIN_ANTI)
    assert_equal(
        semi.num_rows() + anti.num_rows(), 300,
        "SEMI + ANTI must partition the probe rows",
    )
    residual_mark_configure(force=False)


def test_skew_byte_equiv() raises:
    """Skew guard: all build keys == 1 (one bucket, one long chain, heavy
    CAS contention). Parallel == serial for BOTH SEMI and ANTI — no corruption, no
    deadlock.
    """
    residual_mark_configure(force=True)
    var probe = _gen_skew_probe(297)
    var build = _gen_skew_build(256)
    var semi_par = _run_parallel(probe, build, JOIN_SEMI)
    var semi_ser = _run_serial(probe, build, JOIN_SEMI)
    _assert_batches_equal(semi_par, semi_ser, "SKEW SEMI parallel-vs-serial")
    var anti_par = _run_parallel(probe, build, JOIN_ANTI)
    var anti_ser = _run_serial(probe, build, JOIN_ANTI)
    _assert_batches_equal(anti_par, anti_ser, "SKEW ANTI parallel-vs-serial")
    residual_mark_configure(force=False)


def test_wrapper_routes_and_matches_serial() raises:
    """The routing wrapper `execute_residual_join_probe_parallel` (the real door
    `_residual_probe_over_resident` calls) routes SEMI/ANTI to the parallel kernel
    and returns byte-identical rows to the serial kernel.
    """
    residual_mark_configure(force=True)
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var wrapped = _run_wrapper(probe, build, JOIN_SEMI)
    var ser = _run_serial(probe, build, JOIN_SEMI)
    _assert_batches_equal(wrapped, ser, "wrapper SEMI vs serial")
    residual_mark_configure(force=False)


def test_parallel_fire_and_worker_span() raises:
    """Reachability + parallel-fire witness: the parallel kernel FIRES (fire >= 1)
    and genuinely partitions build+probe across > 1 worker (span >= 2). Without the
    counter a byte-oracle is BLIND to which kernel ran / how many workers did work.
    """
    residual_mark_configure(force=True)
    reset_residual_mark_counters()
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var _par = _run_parallel(probe, build, JOIN_SEMI)
    assert_true(
        residual_mark_fire_count() >= 1,
        "parallel mark-join must FIRE at least once",
    )
    assert_true(
        residual_mark_worker_span() >= 2,
        "build/probe must partition across > 1 worker",
    )
    residual_mark_configure(force=False)


def test_declined_route_matches_serial() raises:
    """The DECLINE half of the route pin, flag-free. With FORCE off the
    588-row fixture is far below `_MARK_PARALLEL_THRESHOLD`, so the eligibility
    gate declines and the routing wrapper tail-calls the serial kernel — and the
    wrapper's result must still equal the DIRECTLY-called serial kernel.
    """
    residual_mark_configure(force=False)
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var elig = _residual_mark_parallel_eligible(
        probe, build, String("l_orderkey"), String("l_orderkey"),
        JOIN_SEMI, True,
    )
    assert_true(not elig, "sub-threshold shape must make the gate decline")
    var wrapped = _run_wrapper(probe, build, JOIN_SEMI)
    var ser = _run_serial(probe, build, JOIN_SEMI)
    _assert_batches_equal(wrapped, ser, "declined wrapper vs serial")


def test_eligibility_gate_shapes() raises:
    """The eligibility gate is a pure ROUTE decision: SEMI/ANTI over a single INT64
    non-null equi-key qualifies (FORCE bypasses the 100K row threshold); INNER,
    no-equi, and sub-threshold (FORCE unset) decline.
    """
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    residual_mark_configure(force=True)
    assert_true(
        _residual_mark_parallel_eligible(
            probe, build, String("l_orderkey"), String("l_orderkey"),
            JOIN_SEMI, True,
        ),
        "SEMI single-int64-key must qualify (FORCE)",
    )
    assert_true(
        _residual_mark_parallel_eligible(
            probe, build, String("l_orderkey"), String("l_orderkey"),
            JOIN_ANTI, True,
        ),
        "ANTI single-int64-key must qualify (FORCE)",
    )
    assert_true(
        not _residual_mark_parallel_eligible(
            probe, build, String("l_orderkey"), String("l_orderkey"),
            JOIN_INNER, True,
        ),
        "INNER must decline",
    )
    assert_true(
        not _residual_mark_parallel_eligible(
            probe, build, String("l_orderkey"), String("l_orderkey"),
            JOIN_SEMI, False,
        ),
        "no-equi-key must decline",
    )
    residual_mark_configure(force=False)
    assert_true(
        not _residual_mark_parallel_eligible(
            probe, build, String("l_orderkey"), String("l_orderkey"),
            JOIN_SEMI, True,
        ),
        "sub-threshold (588 rows << 100K) must decline (FORCE unset)",
    )


def test_prepare_fill_covers_every_element() raises:
    """PRIMARY: every element of all three buffers is written by the fill wave,
    and nothing outside them is.
    """
    _clear_env()
    comptime CAP = 512
    comptime NB = 300
    comptime NP = 200
    var grain = _TEST_FILL_GRAIN

    var n_ht = (CAP + grain - 1) // grain
    var n_nc = (NB + grain - 1) // grain
    var n_hp = (NP + grain - 1) // grain
    var n_total = n_ht + n_nc + n_hp
    print(
        "[T1] PREPARE geometry: grain=", grain, " cap=", CAP, " nb=", NB,
        " np=", NP, " -> n_ht=", n_ht, " n_nc=", n_nc, " n_hp=", n_hp,
        " n_total=", n_total,
    )
    assert_true(
        n_total > 3,
        "fixture must produce > 3 fill morsels or the offset arithmetic is"
        " only ever evaluated at zero (got " + String(n_total) + ")",
    )

    var ht = List[Int64]()
    ht.resize(CAP + _GUARD, Int64(_POISON_I64))
    var nc = List[Int64]()
    nc.resize(NB + _GUARD, Int64(_POISON_I64))
    var hp = List[UInt8]()
    hp.resize(NP + _GUARD, UInt8(_POISON_U8))

    var probe = _gen_probe(8)
    var build = _gen_build(8)
    var kv = List[Int]()
    for i in range(8):
        kv.append(i)
    var pk = _i64_arr(kv)
    var bk = _i64_arr(kv)
    var ctx = _ResidualMarkCtx(probe^, build^, pk^, bk^, _residual_neq())

    var state = _ResidualMarkState(
        1,      # build_morsel_size  — unread by PREPARE
        1,      # probe_morsel_size  — unread by PREPARE
        1,      # num_build_morsels  — unread by PREPARE
        NB,
        1,      # num_probe_morsels  — unread by PREPARE
        NP,
        grain,  # fill_morsel        — the grain under test
        NB,
        CAP,    # cap — carried explicitly (no longer reconstructed as mask+1)
        UInt64(CAP - 1),
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
    var n_workers = min(n_total, 4)
    var task = _ResidualPrepareTask(Int32(0))
    _ = disp.run_with_state[_ResidualMarkState, _ResidualPrepareTask](
        state, task^, n_workers, ct.clone()
    )
    var span = Int(state.workers_active[].load())
    print("[T1] PREPARE dispatched ", n_workers, " workers, span=", span)

    var bad_ht = 0
    var first_ht = -1
    for i in range(CAP):
        if Int(state.ht[i]) != _CHAIN_END:
            bad_ht += 1
            if first_ht < 0:
                first_ht = i
    var bad_nc = 0
    var first_nc = -1
    for i in range(NB):
        if Int(state.next_chain[i]) != 0:
            bad_nc += 1
            if first_nc < 0:
                first_nc = i
    var bad_hp = 0
    var first_hp = -1
    for i in range(NP):
        if Int(state.has_pass[i]) != 0:
            bad_hp += 1
            if first_hp < 0:
                first_hp = i
    var oob_ht = 0
    for i in range(CAP, CAP + _GUARD):
        if Int(state.ht[i]) != _POISON_I64:
            oob_ht += 1
    var oob_nc = 0
    for i in range(NB, NB + _GUARD):
        if Int(state.next_chain[i]) != _POISON_I64:
            oob_nc += 1
    var oob_hp = 0
    for i in range(NP, NP + _GUARD):
        if Int(state.has_pass[i]) != _POISON_U8:
            oob_hp += 1

    print(
        "[T1] unfilled ht/nc/hp= ", bad_ht, " / ", bad_nc, " / ", bad_hp,
        "   oob writes ht/nc/hp= ", oob_ht, " / ", oob_nc, " / ", oob_hp,
    )

    assert_equal(
        bad_ht, 0,
        "ht: " + String(bad_ht) + " of " + String(CAP) + " slots left"
        " UNINITIALISED by the fill wave (first at index "
        + String(first_ht) + ") — on the live path each is a garbage chain"
        " head and an unbounded OOB read in the probe",
    )
    assert_equal(
        bad_nc, 0,
        "next_chain: " + String(bad_nc) + " of " + String(NB) + " slots left"
        " UNINITIALISED (first at index " + String(first_nc) + ")",
    )
    assert_equal(
        bad_hp, 0,
        "has_pass: " + String(bad_hp) + " of " + String(NP) + " bytes left"
        " UNINITIALISED (first at index " + String(first_hp) + ")",
    )
    assert_equal(
        oob_ht, 0,
        "ht: " + String(oob_ht) + " OUT-OF-BOUNDS writes past cap",
    )
    assert_equal(
        oob_nc, 0,
        "next_chain: " + String(oob_nc) + " OUT-OF-BOUNDS writes past"
        " num_build_rows",
    )
    assert_equal(
        oob_hp, 0,
        "has_pass: " + String(oob_hp) + " OUT-OF-BOUNDS writes past"
        " num_probe_rows",
    )
    _ = state^


def test_prepare_fan_geometry_and_span() raises:
    """GEOMETRY witness: the real driver genuinely produces a > 3-morsel fill
    geometry and fans it across > 1 worker.
    """
    _clear_env()
    residual_mark_configure(force=True)
    residual_mark_configure(fill_morsel=_TEST_FILL_GRAIN)
    reset_residual_mark_counters()
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var par = _run_parallel(probe, build, JOIN_SEMI)

    comptime FAN_ATTEMPTS = 8
    for _ in range(FAN_ATTEMPTS - 1):
        var _r = _run_parallel(probe, build, JOIN_SEMI)
    var morsels = residual_mark_prepare_morsels()
    var span = residual_mark_prepare_worker_span()
    print(
        "[T2] PREPARE morsels=", morsels, " max worker span over ",
        FAN_ATTEMPTS, " invocations=", span,
    )

    assert_true(
        morsels >= 4,
        "the fill wave must dispatch > 3 morsels or the offset arithmetic is"
        " evaluated only at zero — got " + String(morsels)
        + " (grain override not in effect?)",
    )
    assert_true(
        span >= 2,
        "the fill wave must fan across > 1 worker in at least one of "
        + String(FAN_ATTEMPTS) + " invocations (the parallelism the"
        " memory-safety argument depends on) — got " + String(span),
    )
    var ser = _run_serial(probe, build, JOIN_SEMI)
    _assert_batches_equal(par, ser, "fine-grain PREPARE parallel-vs-serial")

    _clear_env()
    residual_mark_configure(force=True)
    reset_residual_mark_counters()
    var _d = _run_parallel(probe, build, JOIN_SEMI)
    var default_morsels = residual_mark_prepare_morsels()
    print("[T2] override UNSET -> prepare morsels=", default_morsels)
    assert_equal(
        default_morsels, 2,
        "with the override unset the grain must be the production"
        " RESIDUAL_MARK_FILL_MORSEL_DEFAULT (262,144) — one morsel each for ht and has_pass"
        " (next_chain is elided by default). Got " + String(default_morsels),
    )

    _clear_env()
    var refused = False
    try:
        residual_mark_configure(fill_morsel=-1)
    except:
        refused = True
    assert_true(refused, "a negative fill grain must be refused")
    _clear_env()


def test_prepare_gate_both_arms() raises:
    """The PREPARE-fan setting, whose OFF arm its own docstring calls "the
    A/B baseline AND the differential ORACLE" — and which nothing executed.
    """
    _clear_env()
    var probe = _gen_probe(300)
    var build = _gen_build(288)
    var ser = _run_serial(probe, build, JOIN_SEMI)

    _clear_env()
    residual_mark_configure(force=True)
    residual_mark_configure(prepare_parallel=False)
    reset_residual_mark_counters()
    assert_true(
        not residual_mark_prepare_parallel_on(),
        "prepare_parallel=False must disable the PREPARE fan",
    )
    var off = _run_parallel(probe, build, JOIN_SEMI)
    var off_morsels = residual_mark_prepare_morsels()
    print("[T3] gate OFF: prepare morsels=", off_morsels)
    _assert_batches_equal(off, ser, "PREPARE gate OFF vs serial")
    assert_equal(
        off_morsels, 0,
        "with the gate OFF the fill wave must not dispatch at all — got "
        + String(off_morsels) + " morsels",
    )

    _clear_env()
    residual_mark_configure(force=True)
    residual_mark_configure(fill_morsel=_TEST_FILL_GRAIN)
    reset_residual_mark_counters()
    assert_true(
        residual_mark_prepare_parallel_on(),
        "the PREPARE fan must default ON when unconfigured",
    )
    var on = _run_parallel(probe, build, JOIN_SEMI)
    var on_morsels = residual_mark_prepare_morsels()
    print("[T3] gate ON (default): prepare morsels=", on_morsels)
    _assert_batches_equal(on, ser, "PREPARE gate ON vs serial")
    assert_true(
        on_morsels > 3,
        "with the gate ON (default) the fill wave must dispatch — got "
        + String(on_morsels) + " morsels",
    )
    _clear_env()


def main() raises:
    var suite = TestSuite()
    suite.test[test_semi_byte_equiv]()
    suite.test[test_anti_byte_equiv]()
    suite.test[test_semi_anti_complement]()
    suite.test[test_skew_byte_equiv]()
    suite.test[test_wrapper_routes_and_matches_serial]()
    suite.test[test_parallel_fire_and_worker_span]()
    suite.test[test_declined_route_matches_serial]()
    suite.test[test_eligibility_gate_shapes]()
    suite.test[test_prepare_fill_covers_every_element]()
    suite.test[test_prepare_fan_geometry_and_span]()
    suite.test[test_prepare_gate_both_arms]()
    suite^.run()
