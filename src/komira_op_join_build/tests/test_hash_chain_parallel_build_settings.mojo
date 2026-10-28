# =============================================================================
# test_hash_chain_parallel_build_settings -- the settings of the parallel
# chained-hash build decide which build serves a join and who fills the
# chain-head table, and every combination gives the serial build's answer
# =============================================================================
#
# What each test catches:
#   * `test_build_mode_eligibility`: AUTO takes the parallel build exactly at
#     `JOIN_BUILD_PARALLEL_THRESHOLD` rows; OFF never takes it; FORCE takes it
#     at one row; an empty build never does. (Making `chain_build_parallel_
#     eligible` ignore OFF turns this red.)
#   * `test_fill_fan_eligibility`: the fanned fill needs the setting on, two
#     workers and a 4 MiB table (FORCE bypasses only the size floor).
#   * `test_forced_parallel_build_matches_serial`: under FORCE, with a 16-slot
#     fill grain so the fill wave tiles a fixture-sized table into many
#     morsels, the parallel build FIRES, its recorded fork geometry has more
#     than one morsel and more than one task (the build wave, and the fill wave
#     when fanned; the driver fill records none), every chain is acyclic with
#     every row linked, and every probe answers as the serial build does, for
#     the fanned fill and for the driver's fill alike. Nothing here depends on
#     which worker claims which morsel.
#   * `test_forced_parallel_build_writes_payload_words`: a parallel
#     payload-inline build stores each row's payload in word 2 of its entry
#     (NULL-key rows included), over both fills.
#   * `test_cancelled_parallel_build_raises`: a token cancelled before the
#     build makes it raise a cancellation error and return no table, over both
#     fills.
#   * `test_contended_forced_build_matches_serial_match_sets`: 24,000 rows over
#     seven distinct keys (with NULL keys), pushed by four workers onto the same
#     few chains, six times over fresh pools: every chain is acyclic with every
#     non-NULL row linked once, and the sorted INNER, LEFT, RIGHT, FULL, SEMI
#     and ANTI result sets (probes with duplicate, unmatched and NULL keys)
#     equal the serial build's, so no push is lost, duplicated or misrouted.
#   * `test_off_takes_the_serial_build`: OFF leaves the fire counter at zero.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import (
    SITE_JOIN_HASH_BUILD,
    SITE_JOIN_HT_FILL,
)
from komira_async_api.token import CancellationToken
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_MORSELS,
    GRAIN_F_WORKERS,
    grain_geometry_calls,
    grain_geometry_field,
    grain_geometry_reset,
)

from komira_op_join_build.hash_chain_build_settings import (
    JOIN_BUILD_PARALLEL_THRESHOLD,
    JOIN_PARALLEL_BUILD_AUTO,
    JOIN_PARALLEL_BUILD_FORCE,
    JOIN_PARALLEL_BUILD_OFF,
    ht_fill_morsel_slots,
    join_ht_fill_configure,
    join_parallel_build_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_build.hash_chain_parallel_build import (
    chain_build_parallel_eligible,
    hash_join_build_parallel,
    ht_fill_fan_eligible,
)
from komira_join_assembly.join_payload_inline import JOIN_KN_WORDS_PAY
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_parallel_build_counter import (
    join_parallel_build_fire_count,
    reset_join_parallel_build,
)


comptime _POOL_WORKERS = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _keys(n: Int, stride: Int) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(i * stride)))
    return arr^


def _parallel(n: Int) raises -> HashJoinBuilder:
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    return hash_join_build_parallel(disp, ct^, _keys(n, 3))


def _assert_chains_acyclic(
    b: HashJoinBuilder, linked: Int, what: String
) raises:
    """Walk every bucket's chain at most `num_build` steps, so a cycle fails by
    name instead of spinning, and check the chains hold exactly `linked` rows."""
    var total = 0
    for s in range(b.capacity):
        var cur = b.hash_table[s]
        var steps = 0
        while cur != -1:
            steps += 1
            assert_true(
                steps <= b.num_build,
                what + ": chain cycle in bucket " + String(s),
            )
            cur = b.chain_next_at(cur)
        total += steps
    assert_equal(total, linked, what + ": rows linked into chains")


def _assert_same_answer(
    ser: HashJoinBuilder, par: HashJoinBuilder, what: String
) raises:
    _assert_chains_acyclic(par, ser.num_build, what)
    # Probe keys 0..3n-1 hit every third value: unique build keys, so each
    # probe row has at most one match and the order is fixed by probe order.
    var probe = _keys(3 * ser.num_build + 7, 1)
    var s = ser.probe_inner(probe)
    var p = par.probe_inner(probe)
    assert_equal(len(s[0]), len(p[0]), what + ": INNER pair count")
    assert_equal(len(s[0]), ser.num_build, what + ": every build row matches")
    for i in range(len(s[0])):
        assert_equal(s[0][i], p[0][i], what + ": build row " + String(i))
        assert_equal(s[1][i], p[1][i], what + ": probe row " + String(i))
    assert_equal(
        ser.probe_anti_count(probe), par.probe_anti_count(probe), what + ": ANTI"
    )


def test_build_mode_eligibility() raises:
    reset_hash_chain_build_settings()
    assert_false(chain_build_parallel_eligible(0))
    assert_false(chain_build_parallel_eligible(JOIN_BUILD_PARALLEL_THRESHOLD - 1))
    assert_true(chain_build_parallel_eligible(JOIN_BUILD_PARALLEL_THRESHOLD))
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_OFF)
    assert_false(
        chain_build_parallel_eligible(10 * JOIN_BUILD_PARALLEL_THRESHOLD),
        "OFF never takes the parallel build",
    )
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    assert_true(chain_build_parallel_eligible(1), "FORCE at one row")
    assert_false(chain_build_parallel_eligible(0), "never for an empty build")
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_AUTO)
    assert_false(chain_build_parallel_eligible(1))
    var raised = False
    try:
        join_parallel_build_configure(7)
    except:
        raised = True
    assert_true(raised, "an unknown mode is refused")


def test_fill_fan_eligibility() raises:
    reset_hash_chain_build_settings()
    comptime FOUR_MIB_SLOTS = 4 * 1024 * 1024 // 8
    assert_true(ht_fill_fan_eligible(FOUR_MIB_SLOTS, 4, False))
    assert_false(ht_fill_fan_eligible(FOUR_MIB_SLOTS - 1, 4, False), "the floor")
    assert_true(ht_fill_fan_eligible(16, 4, True), "FORCE bypasses the floor")
    assert_false(ht_fill_fan_eligible(FOUR_MIB_SLOTS, 1, True), "one worker")
    join_ht_fill_configure(False)
    assert_false(ht_fill_fan_eligible(FOUR_MIB_SLOTS, 4, True), "the driver fill")
    join_ht_fill_configure(True, 16)
    assert_equal(ht_fill_morsel_slots(), 16)
    reset_hash_chain_build_settings()
    assert_equal(ht_fill_morsel_slots(), 16_384)


def test_forced_parallel_build_matches_serial() raises:
    var n = 3000  # cap 8192: 512 fill morsels at a 16-slot grain
    var ser = HashJoinBuilder.build(_keys(n, 3), build_bloom=False)
    for fanned in range(2):
        reset_hash_chain_build_settings()
        join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
        join_ht_fill_configure(fanned == 1, 16)
        reset_join_parallel_build()
        grain_geometry_reset()
        var par = _parallel(n)
        var what = String("forced, fanned fill=") + String(fanned)
        assert_equal(join_parallel_build_fire_count(), 1, what + ": fired")
        assert_equal(
            grain_geometry_calls(SITE_JOIN_HASH_BUILD), 1, what + ": build fork"
        )
        assert_true(
            grain_geometry_field(SITE_JOIN_HASH_BUILD, GRAIN_F_MORSELS) > 1,
            what + ": build morsels",
        )
        assert_true(
            grain_geometry_field(SITE_JOIN_HASH_BUILD, GRAIN_F_WORKERS) > 1,
            what + ": build tasks",
        )
        if fanned == 1:
            assert_equal(
                grain_geometry_calls(SITE_JOIN_HT_FILL), 1, what + ": fill fork"
            )
            assert_true(
                grain_geometry_field(SITE_JOIN_HT_FILL, GRAIN_F_MORSELS) > 1,
                what + ": fill morsels",
            )
            assert_true(
                grain_geometry_field(SITE_JOIN_HT_FILL, GRAIN_F_WORKERS) > 1,
                what + ": fill tasks",
            )
        else:
            assert_equal(
                grain_geometry_calls(SITE_JOIN_HT_FILL), 0, what + ": no fill fork"
            )
        assert_false(par.uses_bloom(), what + ": the parallel build has no bloom")
        _assert_same_answer(ser, par, what)


def test_off_takes_the_serial_build() raises:
    reset_hash_chain_build_settings()
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_OFF)
    reset_join_parallel_build()
    var n = 3000
    var par = _parallel(n)
    assert_equal(join_parallel_build_fire_count(), 0, "OFF: the serial build")
    var ser = HashJoinBuilder.build(_keys(n, 3), build_bloom=False)
    _assert_same_answer(ser, par, String("off"))


def _dup_keys(
    n: Int, distinct: Int, null_every: Int
) raises -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Int64(i % distinct)
    for i in range(n):
        if i % null_every == 0:
            arr._set_null(i)
    return arr^


def _sorted_pairs(
    pairs: Tuple[List[Int], List[Int]], stride: Int
) -> List[Int]:
    """One code per (probe row, build row) pair; -1 on either side is a valid
    value (an unmatched row of an outer join), so both are shifted by one."""
    var out = List[Int]()
    for i in range(len(pairs[0])):
        out.append((pairs[1][i] + 1) * stride + pairs[0][i] + 1)
    sort(out)
    return out^


def _sorted_rows(var rows: List[Int]) -> List[Int]:
    sort(rows)
    return rows^


def _assert_same_list(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": entry " + String(i))


def _make_pool() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def test_forced_parallel_build_writes_payload_words() raises:
    # The parallel payload-inline entry is four words per row: [key, link,
    # payload, pad]. A NULL-key row still carries its key slot and payload.
    var n = 3000
    for fanned in range(2):
        reset_hash_chain_build_settings()
        join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
        join_ht_fill_configure(fanned == 1, 16)
        var what = String("payload, fanned fill=") + String(fanned)
        var pay = List[Int64]()
        for i in range(n):
            pay.append(Int64(i * 7 + 13))
        var keys = _dup_keys(n, 50, 11)
        var ct = CancellationToken.new()
        var runtime = _make_pool()
        ref disp = runtime.dispatcher()
        var par = hash_join_build_parallel(
            disp, ct^, keys^, pay_values=pay.copy(), pay_build_col=1
        )
        assert_true(par.pay_inline(), what + ": payload-inline layout")
        assert_equal(par.num_build, n)
        var linked = n - (n + 10) // 11
        _assert_chains_acyclic(par, linked, what)
        for i in range(n):
            assert_equal(
                par.chain_pay_at(i), pay[i], what + ": payload of row " + String(i)
            )
            assert_equal(
                Int(par.key_next[JOIN_KN_WORDS_PAY * i + 3]),
                0,
                what + ": pad word of row " + String(i),
            )


def test_cancelled_parallel_build_raises() raises:
    for fanned in range(2):
        reset_hash_chain_build_settings()
        join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
        join_ht_fill_configure(fanned == 1, 16)
        var ct = CancellationToken.new()
        ct.cancel(String("stop for test"))
        var runtime = _make_pool()
        ref disp = runtime.dispatcher()
        var raised = False
        var msg = String("")
        try:
            var par = hash_join_build_parallel(disp, ct^, _keys(3000, 3))
            _ = par^
        except e:
            raised = True
            msg = String(e)
        assert_true(raised, "a cancelled build raises, fanned=" + String(fanned))
        assert_true(
            "CancelledError: stop for test" in msg,
            "the error names the cancellation: " + msg,
        )


def test_contended_forced_build_matches_serial_match_sets() raises:
    # Few distinct keys over many rows: every worker pushes onto the same
    # handful of chain heads, with a NULL build key every 11th row (recorded,
    # never linked). The chain order is racy, so the oracle is the sorted set of
    # result pairs per probe kind: a push lost to a race drops a pair, a push
    # applied twice adds one, and a NULL row linked adds one. The probe has
    # duplicate keys, keys that never match and NULL keys.
    var n = 24000
    var distinct = 7
    var stride = n + 2
    var linked = n - (n + 10) // 11
    var probe = _dup_keys(40, distinct + 3, 7)
    var ser = HashJoinBuilder.build(
        _dup_keys(n, distinct, 11), build_bloom=False
    )
    var want_inner = _sorted_pairs(ser.probe_inner(probe), stride)
    var want_left = _sorted_pairs(ser.probe_left(probe), stride)
    var want_right = _sorted_pairs(ser.probe_right(probe), stride)
    var want_full = _sorted_pairs(ser.probe_full(probe), stride)
    var want_semi = _sorted_rows(ser.probe_semi(probe))
    var want_anti = _sorted_rows(ser.probe_anti(probe))
    assert_true(len(want_inner) > 0, "the fixture produces matches")
    assert_true(len(want_anti) > 0, "the fixture has unmatched probe rows")
    assert_true(len(want_right) > len(want_inner), "unmatched build rows")
    # Each round builds a fresh pool, so the build runs against freshly created
    # and then destroyed workers every time.
    for rnd in range(6):
        reset_hash_chain_build_settings()
        join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
        join_ht_fill_configure(rnd % 2 == 0, 16)
        reset_join_parallel_build()
        var ct = CancellationToken.new()
        var runtime = _make_pool()
        ref disp = runtime.dispatcher()
        var par = hash_join_build_parallel(
            disp, ct^, _dup_keys(n, distinct, 11)
        )
        var what = String("round ") + String(rnd)
        assert_equal(join_parallel_build_fire_count(), 1, what + ": fired")
        _assert_chains_acyclic(par, linked, what)
        _assert_same_list(
            _sorted_pairs(par.probe_inner(probe), stride), want_inner, what + ": INNER"
        )
        _assert_same_list(
            _sorted_pairs(par.probe_left(probe), stride), want_left, what + ": LEFT"
        )
        _assert_same_list(
            _sorted_pairs(par.probe_right(probe), stride), want_right, what + ": RIGHT"
        )
        _assert_same_list(
            _sorted_pairs(par.probe_full(probe), stride), want_full, what + ": FULL"
        )
        _assert_same_list(
            _sorted_rows(par.probe_semi(probe)), want_semi, what + ": SEMI"
        )
        _assert_same_list(
            _sorted_rows(par.probe_anti(probe)), want_anti, what + ": ANTI"
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
