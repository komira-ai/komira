# The parallel composite build against the serial build: the same matched
# pairs, the same rows in every bucket's chain, byte-identical blooms, on
# duplicate and partially colliding keys, negative and extreme keys, every row
# in one bucket (maximal compare-exchange contention), NULL-keyed rows (an
# entry, no chain), empty / single-row / zero-match shapes, one and three keys,
# and the inline (no pool) arm; plus that the wave really dispatches, the
# atomic bloom insert, and the gate and tiling (AUTO, OFF, FORCE).

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_buffer.heap_region import HeapRegion
from komira_async_api.parallel_dispatch import NoDispatch

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import (
    SITE_MK_JOIN_BUILD,
    sched_trace_configure,
    sched_trace_enabled,
    sched_trace_reset,
    sched_trace_site,
)

from komira_op_join_build.hash_chain_build_settings import (
    JOIN_PARALLEL_BUILD_AUTO,
    JOIN_PARALLEL_BUILD_FORCE,
    JOIN_PARALLEL_BUILD_OFF,
    join_parallel_build_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_probe.join_multi_key import (
    MultiKeyColumns,
    _CHAIN_END,
    _COMPOSITE_HASH_SEED,
    _NAN_SENTINEL_BITS,
    _composite_hash_step,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_parallel_build import (
    _MK_BUILD_PARALLEL_THRESHOLD,
    _MK_MIN_CHUNK_ROWS,
    mk_build_chunk_bounds,
    mk_chain_build_parallel_eligible,
    multi_key_hash_join_build_parallel,
)


comptime I64 = DType.int64
comptime _POOL_WORKERS = 4


comptime _F_FORK_NS: Int32 = 0
comptime _F_COUNT: Int32 = 2
comptime _F_TASK_MIN: Int32 = 4
comptime _F_TASK_MAX: Int32 = 5


def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return arr^


def _mk_columns(imm cols: List[List[Int64]]) raises -> MultiKeyColumns:
    """A pure-INT64 `MultiKeyColumns` over N key columns."""
    var n_keys = len(cols)
    var ik = Slab[PrimitiveArray[I64]].create(n_keys)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(n_keys)
    var dk = Slab[Optional[StringDictionaryArray]].create(n_keys)
    var fps = List[UInt64]()
    for k in range(n_keys):
        ik.append(_i64_arr(cols[k]))
        sk.append(Optional[StringArray[HeapRegion]](None))
        dk.append(Optional[StringDictionaryArray](None))
        fps.append(UInt64(0))
    return MultiKeyColumns(ik^, sk^, dk^, fps^, n_keys)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _build_serial(imm cols: List[List[Int64]]) raises -> MultiKeyHashJoinBuilder:
    return MultiKeyHashJoinBuilder.build(_mk_columns(cols))


def _build_parallel(
    imm cols: List[List[Int64]], force_serial: Bool = False
) raises -> MultiKeyHashJoinBuilder:
    """Drive the PRODUCTION `PerCoreAsyncRuntime` dispatcher through the
    PRODUCTION entry point.
    """
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    comptime do = origin_of(disp)
    return multi_key_hash_join_build_parallel[
        True, LocalDispatcher[NoopSink], do
    ](
        _mk_columns(cols),
        Optional[Pointer[LocalDispatcher[NoopSink], do]](Pointer(to=disp)),
        force_serial,
    )


def _build_wave_inline(
    imm cols: List[List[Int64]],
) raises -> MultiKeyHashJoinBuilder:
    """The SAME wave with `has_pool=False` — `fork_join_shared` runs every chunk
    inline. Distinct from `_build_serial`, which never enters the wave at all:
    this leg exercises the chunk bodies over a MULTI-chunk tiling with no
    dispatch, which is what a nested-dispatch degradation looks like.
    """
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return multi_key_hash_join_build_parallel[False, NoDispatch, nd_o](
        _mk_columns(cols), Optional[Pointer[NoDispatch, nd_o]](None)
    )


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def _probe_pairs(
    imm builder: MultiKeyHashJoinBuilder, imm probe: List[List[Int64]]
) raises -> List[Int]:
    """The SORTED encoded (build_idx, probe_idx) multiset `probe_inner_into`
    emits — the actual matched pairs, order-independent.
    """
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(_mk_columns(probe), bm, pm)
    var enc = List[Int]()
    for i in range(len(bm)):
        enc.append(bm[i] * 1_000_000 + pm[i])
    return _sorted(enc^)


def _chain_membership(
    imm builder: MultiKeyHashJoinBuilder,
) raises -> List[Int]:
    """For every bucket, the SORTED rows reachable from its chain head, encoded
    as `slot * 1_000_000 + row` and sorted globally.
    """
    var out = List[Int]()
    for slot in range(builder._capacity):
        var cur = builder._hash_table[slot]
        var guard = 0
        while cur != _CHAIN_END:
            out.append(slot * 1_000_000 + cur)
            cur = builder._next_chain[cur]
            guard += 1
            if guard > builder.num_rows() + 1:
                raise Error(
                    "_chain_membership: cycle in bucket " + String(slot)
                )
    return _sorted(out^)


def _bloom_bytes_equal(
    imm a: BloomFilter, imm b: BloomFilter
) raises -> Bool:
    if a.num_bytes != b.num_bytes:
        return False
    for i in range(a.num_bytes):
        if a.data.get_typed[UInt8](i) != b.data.get_typed[UInt8](i):
            return False
    return True


def _assert_lists_equal(
    imm a: List[Int], imm b: List[Int], msg: String
) raises:
    assert_equal(len(a), len(b), msg + " length")
    for i in range(len(a)):
        assert_equal(a[i], b[i], msg + " [" + String(i) + "]")


def _assert_builds_agree(
    imm cols: List[List[Int64]],
    imm probe: List[List[Int64]],
    msg: String,
) raises:
    """The full oracle set for one fixture: matched PAIRS, bucket MEMBERSHIP,
    the row-indexed entry space, `next_chain` extent, capacity, inserted count,
    and the bloom BYTES.
    """
    var ser = _build_serial(cols)
    var par = _build_parallel(cols)

    _assert_lists_equal(
        _probe_pairs(ser, probe), _probe_pairs(par, probe), msg + " pairs"
    )
    _assert_lists_equal(
        _chain_membership(ser), _chain_membership(par), msg + " chains"
    )
    assert_equal(ser._capacity, par._capacity, msg + " capacity")
    assert_equal(ser.num_rows(), par.num_rows(), msg + " entry-space extent")
    assert_equal(len(par._next_chain), len(cols[0]), msg + " next_chain extent")
    assert_equal(
        ser._num_inserted, par._num_inserted, msg + " num_inserted"
    )
    assert_equal(
        ser.num_rows(), len(cols[0]), msg + " serial entry space is row-indexed"
    )
    assert_equal(
        par.num_rows(), len(cols[0]), msg + " parallel entry space is row-indexed"
    )
    assert_true(
        _bloom_bytes_equal(ser._bloom, par._bloom), msg + " bloom bytes"
    )
    _ = ser^
    _ = par^


def test_bloom_insert_atomic_is_byte_identical_and_order_free() raises:
    """`insert_hash_atomic` must set exactly the bits `insert_hash` sets."""
    var hashes = List[UInt64]()
    var x = UInt64(0x243F6A8885A308D3)
    for _ in range(4096):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        hashes.append(x)

    var plain = BloomFilter.with_ndv_fpp(4096, 0.01)
    var atomic = BloomFilter.with_ndv_fpp(4096, 0.01)
    var reversed = BloomFilter.with_ndv_fpp(4096, 0.01)
    for i in range(len(hashes)):
        plain.insert_hash(hashes[i])
        atomic.insert_hash_atomic(hashes[i])
    for i in range(len(hashes) - 1, -1, -1):
        reversed.insert_hash_atomic(hashes[i])

    assert_true(
        _bloom_bytes_equal(plain, atomic), "atomic insert != plain insert"
    )
    assert_true(
        _bloom_bytes_equal(plain, reversed), "atomic insert is order-sensitive"
    )
    for i in range(len(hashes)):
        assert_true(atomic.check_hash(hashes[i]), "atomic-inserted hash missing")
    _ = plain^
    _ = atomic^
    _ = reversed^


def test_dispatch_witness_and_byte_identical_mutant() raises:
    """Under FORCE the build dispatches a wave as wide as the pool (read from
    the scheduler trace), and `force_serial` dispatches none yet gives the same
    pairs, chains and bloom bytes, so a build that silently fell back to serial
    would be caught by the dispatch counters and not by the values."""
    sched_trace_configure(True)
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    assert_true(
        sched_trace_enabled(),
        "the scheduler trace is not enabled, so every dispatch assertion below"
        " would be measuring nothing",
    )

    var cols = List[List[Int64]]()
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for i in range(400):
        k0.append(Int64(i % 37))
        k1.append(Int64((i * 7) % 11))
    cols.append(k0^)
    cols.append(k1^)

    var probe = List[List[Int64]]()
    var p0 = List[Int64]()
    var p1 = List[Int64]()
    for i in range(120):
        p0.append(Int64(i % 41))
        p1.append(Int64((i * 5) % 13))
    probe.append(p0^)
    probe.append(p1^)

    sched_trace_reset()
    var par = _build_parallel(cols)
    var real_count = sched_trace_site(SITE_MK_JOIN_BUILD, _F_COUNT)
    var real_fork = sched_trace_site(SITE_MK_JOIN_BUILD, _F_FORK_NS)
    var real_tmin = sched_trace_site(SITE_MK_JOIN_BUILD, _F_TASK_MIN)
    var real_tmax = sched_trace_site(SITE_MK_JOIN_BUILD, _F_TASK_MAX)
    print(
        "MK_BUILD_DISPATCH real: site=", SITE_MK_JOIN_BUILD,
        " count=", real_count,
        " fork_ns=", real_fork,
        " task_min=", real_tmin,
        " task_max=", real_tmax,
    )
    assert_true(real_count >= UInt64(1), "parallel arm did not dispatch")
    assert_true(real_fork > UInt64(0), "dispatched fork span is zero")
    assert_equal(
        Int(real_tmin), _POOL_WORKERS, "task_min != pool width"
    )
    assert_equal(
        Int(real_tmax), _POOL_WORKERS, "task_max != pool width"
    )

    sched_trace_reset()
    var mut_build = _build_parallel(cols, force_serial=True)
    var mut_count = sched_trace_site(SITE_MK_JOIN_BUILD, _F_COUNT)
    var mut_fork = sched_trace_site(SITE_MK_JOIN_BUILD, _F_FORK_NS)
    print(
        "MK_BUILD_DISPATCH mutant(force_serial): site=", SITE_MK_JOIN_BUILD,
        " count=", mut_count,
        " fork_ns=", mut_fork,
    )

    _assert_lists_equal(
        _probe_pairs(par, probe),
        _probe_pairs(mut_build, probe),
        "mutant pairs differ (it was supposed to be byte-identical)",
    )
    _assert_lists_equal(
        _chain_membership(par),
        _chain_membership(mut_build),
        "mutant chains differ",
    )
    assert_true(
        _bloom_bytes_equal(par._bloom, mut_build._bloom),
        "mutant bloom differs",
    )
    assert_equal(Int(mut_count), 0, "force_serial still dispatched")
    assert_equal(Int(mut_fork), 0, "force_serial still forked")

    _ = par^
    _ = mut_build^
    reset_hash_chain_build_settings()


def test_varied_two_key_fixture() raises:
    """Duplicate composite keys, partial-key collisions (same k0 different k1),
    and probe rows that miss entirely.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var cols = List[List[Int64]]()
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for i in range(500):
        k0.append(Int64(i % 23))
        k1.append(Int64(i % 5))
    cols.append(k0^)
    cols.append(k1^)

    var probe = List[List[Int64]]()
    var p0 = List[Int64]()
    var p1 = List[Int64]()
    for i in range(200):
        p0.append(Int64(i % 29))   # 23..28 never appear on the build side
        p1.append(Int64(i % 7))    # 5, 6 never appear
    probe.append(p0^)
    probe.append(p1^)

    _assert_builds_agree(cols, probe, "varied 2-key")
    reset_hash_chain_build_settings()


def test_negative_and_extreme_keys() raises:
    """Negative narrow-int keys — a join returning 0 of 80 rows on negative keys
    was found this week and NO corpus cell uses them, so the corpus cannot see
    this. Includes INT64 min/max and 0/-0 boundaries.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for i in range(-150, 150):
        k0.append(Int64(i))
        k1.append(Int64(-i))
    k0.append(Int64.MIN)
    k1.append(Int64.MAX)
    k0.append(Int64.MAX)
    k1.append(Int64.MIN)
    k0.append(Int64(0))
    k1.append(Int64(0))
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)

    var p0 = List[Int64]()
    var p1 = List[Int64]()
    for i in range(-200, 200):
        p0.append(Int64(i))
        p1.append(Int64(-i))
    p0.append(Int64.MIN)
    p1.append(Int64.MAX)
    var probe = List[List[Int64]]()
    probe.append(p0^)
    probe.append(p1^)

    var ser = _build_serial(cols)
    var par = _build_parallel(cols)
    var ser_pairs = _probe_pairs(ser, probe)
    var par_pairs = _probe_pairs(par, probe)
    assert_true(len(ser_pairs) > 0, "serial found no negative-key matches")
    _assert_lists_equal(ser_pairs, par_pairs, "negative keys pairs")
    _assert_lists_equal(
        _chain_membership(ser), _chain_membership(par), "negative keys chains"
    )
    _ = ser^
    _ = par^
    reset_hash_chain_build_settings()


def test_skew_all_keys_equal() raises:
    """Every build row in ONE bucket: maximal compare-exchange contention on a
    single chain head. Guards against a lost or duplicated Treiber push, which a
    spread fixture would almost never expose.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for _ in range(600):
        k0.append(Int64(7))
        k1.append(Int64(-3))
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)

    var probe = List[List[Int64]]()
    var p0 = List[Int64]()
    var p1 = List[Int64]()
    p0.append(Int64(7))
    p1.append(Int64(-3))
    p0.append(Int64(7))
    p1.append(Int64(-4))   # partial-key miss
    probe.append(p0^)
    probe.append(p1^)

    var par = _build_parallel(cols)
    var mem = _chain_membership(par)
    assert_equal(len(mem), 600, "skew: rows reachable from the chain")
    var seen = List[Int]()
    for i in range(len(mem)):
        seen.append(mem[i] % 1_000_000)
    var sorted_seen = _sorted(seen^)
    for r in range(600):
        assert_equal(sorted_seen[r], r, "skew: row missing/duplicated in chain")
    assert_equal(par._num_inserted, 600, "skew: num_inserted")

    var pairs = _probe_pairs(par, probe)
    assert_equal(len(pairs), 600, "skew: probe row 0 must match all 600")
    for i in range(len(pairs)):
        assert_equal(pairs[i] % 1_000_000, 0, "skew: unexpected probe index")
    _ = par^
    reset_hash_chain_build_settings()


def test_sentinel_rows_are_recorded_but_unreachable() raises:
    """`_NAN_SENTINEL_BITS` (FLOAT64 NaN / STRING-DICT NULL) in ANY key: the row
    matches nothing but STILL consumes an entry.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for i in range(300):
        if i % 7 == 0:
            k0.append(_NAN_SENTINEL_BITS)   # sentinel in key 0
            k1.append(Int64(i))
        elif i % 7 == 3:
            k0.append(Int64(i))
            k1.append(_NAN_SENTINEL_BITS)   # sentinel in the LATER key
        else:
            k0.append(Int64(i % 11))
            k1.append(Int64(i % 4))
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)

    var probe = List[List[Int64]]()
    var p0 = List[Int64]()
    var p1 = List[Int64]()
    for i in range(60):
        p0.append(Int64(i % 11))
        p1.append(Int64(i % 4))
    p0.append(_NAN_SENTINEL_BITS)
    p1.append(Int64(0))
    probe.append(p0^)
    probe.append(p1^)

    _assert_builds_agree(cols, probe, "sentinel rows")

    var par = _build_parallel(cols)
    assert_equal(par.num_rows(), 300, "sentinel: entry space extent")
    var mem = _chain_membership(par)
    var reachable = List[Bool]()
    for _ in range(300):
        reachable.append(False)
    for i in range(len(mem)):
        reachable[mem[i] % 1_000_000] = True
    var n_sentinel = 0
    for i in range(300):
        var is_sentinel = (i % 7 == 0) or (i % 7 == 3)
        if is_sentinel:
            n_sentinel += 1
            assert_false(reachable[i], "sentinel row is chain-reachable")
            assert_equal(
                par._next_chain[i], _CHAIN_END, "sentinel link not terminated"
            )
        else:
            assert_true(reachable[i], "non-sentinel row is unreachable")
    assert_equal(
        par._num_inserted, 300 - n_sentinel, "sentinel: num_inserted"
    )
    _ = par^
    reset_hash_chain_build_settings()


def test_all_sentinel_build_side() raises:
    """Every build row is sentinel-keyed: nothing is inserted, every probe misses,
    and the entry space is still full width.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for i in range(64):
        k0.append(_NAN_SENTINEL_BITS)
        k1.append(Int64(i))
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    var probe = List[List[Int64]]()
    var p0 = List[Int64]()
    var p1 = List[Int64]()
    p0.append(_NAN_SENTINEL_BITS)
    p1.append(Int64(0))
    p0.append(Int64(5))
    p1.append(Int64(5))
    probe.append(p0^)
    probe.append(p1^)

    var par = _build_parallel(cols)
    assert_equal(par.num_rows(), 64, "all-sentinel: entry space extent")
    assert_equal(par._num_inserted, 0, "all-sentinel: nothing inserted")
    assert_equal(len(_chain_membership(par)), 0, "all-sentinel: chains not empty")
    assert_equal(len(_probe_pairs(par, probe)), 0, "all-sentinel: probe matched")
    _ = par^
    reset_hash_chain_build_settings()


def test_edge_shapes_empty_single_and_zero_match() raises:
    """Empty build side, single-row build side, and a probe with no matches at
    all. An empty INNER JOIN was found RAISING this week.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)

    var empty_cols = List[List[Int64]]()
    empty_cols.append(List[Int64]())
    empty_cols.append(List[Int64]())
    var probe = List[List[Int64]]()
    var p0 = List[Int64]()
    var p1 = List[Int64]()
    p0.append(Int64(1))
    p1.append(Int64(2))
    probe.append(p0^)
    probe.append(p1^)
    assert_false(
        mk_chain_build_parallel_eligible(0), "empty build must not be eligible"
    )
    var empty_par = _build_parallel(empty_cols)
    assert_equal(empty_par.num_rows(), 0, "empty: entry space")
    assert_equal(len(_probe_pairs(empty_par, probe)), 0, "empty: probe matched")
    _ = empty_par^

    var one_cols = List[List[Int64]]()
    var o0 = List[Int64]()
    var o1 = List[Int64]()
    o0.append(Int64(-9))
    o1.append(Int64(4))
    one_cols.append(o0^)
    one_cols.append(o1^)
    var one_probe = List[List[Int64]]()
    var q0 = List[Int64]()
    var q1 = List[Int64]()
    q0.append(Int64(-9))
    q1.append(Int64(4))
    q0.append(Int64(-9))
    q1.append(Int64(5))
    one_probe.append(q0^)
    one_probe.append(q1^)
    _assert_builds_agree(one_cols, one_probe, "single row")
    var one_par = _build_parallel(one_cols)
    var one_pairs = _probe_pairs(one_par, one_probe)
    assert_equal(len(one_pairs), 1, "single row: exactly one match")
    assert_equal(one_pairs[0], 0, "single row: (build 0, probe 0)")
    _ = one_par^

    var zc = List[List[Int64]]()
    var z0 = List[Int64]()
    var z1 = List[Int64]()
    for i in range(128):
        z0.append(Int64(i))
        z1.append(Int64(i))
    zc.append(z0^)
    zc.append(z1^)
    var zp = List[List[Int64]]()
    var y0 = List[Int64]()
    var y1 = List[Int64]()
    for i in range(64):
        y0.append(Int64(1000 + i))
        y1.append(Int64(2000 + i))
    zp.append(y0^)
    zp.append(y1^)
    _assert_builds_agree(zc, zp, "zero match")
    var z_par = _build_parallel(zc)
    assert_equal(len(_probe_pairs(z_par, zp)), 0, "zero match: probe matched")
    _ = z_par^

    reset_hash_chain_build_settings()


def test_key_arity_one_three_and_ragged_delegation() raises:
    """Arity 1 and 3 (the fold is arity-generic), and the two shapes that MUST
    delegate to the serial build so the canonical errors are raised.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)

    var one = List[List[Int64]]()
    var a0 = List[Int64]()
    for i in range(256):
        a0.append(Int64(i % 17))
    one.append(a0^)
    var one_probe = List[List[Int64]]()
    var b0 = List[Int64]()
    for i in range(64):
        b0.append(Int64(i % 19))
    one_probe.append(b0^)
    _assert_builds_agree(one, one_probe, "arity 1")

    var three = List[List[Int64]]()
    var c0 = List[Int64]()
    var c1 = List[Int64]()
    var c2 = List[Int64]()
    for i in range(256):
        c0.append(Int64(i % 13))
        c1.append(Int64(i % 7))
        c2.append(Int64(-(i % 3)))
    three.append(c0^)
    three.append(c1^)
    three.append(c2^)
    var three_probe = List[List[Int64]]()
    var d0 = List[Int64]()
    var d1 = List[Int64]()
    var d2 = List[Int64]()
    for i in range(96):
        d0.append(Int64(i % 13))
        d1.append(Int64(i % 7))
        d2.append(Int64(-(i % 4)))
    three_probe.append(d0^)
    three_probe.append(d1^)
    three_probe.append(d2^)
    _assert_builds_agree(three, three_probe, "arity 3")

    var ragged = List[List[Int64]]()
    var r0 = List[Int64]()
    var r1 = List[Int64]()
    for i in range(16):
        r0.append(Int64(i))
    for i in range(8):
        r1.append(Int64(i))
    ragged.append(r0^)
    ragged.append(r1^)
    var raised = False
    try:
        var b = _build_parallel(ragged)
        _ = b^
    except e:
        raised = True
        assert_true(
            String(e).find("has length") >= 0,
            "ragged: not the canonical length-mismatch error: " + String(e),
        )
    assert_true(raised, "ragged key columns did not raise")

    reset_hash_chain_build_settings()


def test_wave_inline_arm_matches_serial_build() raises:
    """`has_pool=False` — the wave's chunk bodies over a MULTI-chunk tiling with
    no dispatch. This is the nested-dispatch degradation path in production, and
    because chunks then run in order over ascending rows, a Treiber push
    reproduces the serial builder's chain order EXACTLY: the tables must be
    identical link for link, not merely equivalent as sets.
    """
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var cols = List[List[Int64]]()
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    for i in range(300):
        k0.append(Int64(i % 19))
        k1.append(Int64(i % 6))
    cols.append(k0^)
    cols.append(k1^)

    var ser = _build_serial(cols)
    var inl = _build_wave_inline(cols)
    var bounds = mk_build_chunk_bounds(300)
    assert_true(
        len(bounds) - 1 > 1, "inline leg must run a MULTI-chunk tiling"
    )
    assert_equal(ser._capacity, inl._capacity, "inline: capacity")
    assert_equal(ser.num_rows(), inl.num_rows(), "inline: entry space")
    assert_equal(ser._num_inserted, inl._num_inserted, "inline: num_inserted")
    for s in range(ser._capacity):
        assert_equal(
            ser._hash_table[s], inl._hash_table[s],
            "inline: chain head differs at bucket " + String(s),
        )
    for r in range(ser.num_rows()):
        assert_equal(
            ser._next_chain[r], inl._next_chain[r],
            "inline: next_chain differs at row " + String(r),
        )
    assert_true(_bloom_bytes_equal(ser._bloom, inl._bloom), "inline: bloom")
    _ = ser^
    _ = inl^
    reset_hash_chain_build_settings()


def test_gate_and_tiling() raises:
    """The gate + the tiling, so a future edit cannot silently move either: AUTO
    at the threshold, OFF never, FORCE at any size with one-row chunks."""
    reset_hash_chain_build_settings()
    assert_false(mk_chain_build_parallel_eligible(0), "0 rows eligible")
    assert_false(mk_chain_build_parallel_eligible(1000), "1000 rows eligible")
    assert_true(
        mk_chain_build_parallel_eligible(250_000), "250K rows not eligible"
    )
    assert_false(
        mk_chain_build_parallel_eligible(1_000_000, force_serial=True),
        "force_serial ignored",
    )
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_OFF)
    assert_false(
        mk_chain_build_parallel_eligible(1_000_000), "the OFF mode ignored"
    )
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_AUTO)
    assert_true(
        mk_chain_build_parallel_eligible(1_000_000), "AUTO above the threshold"
    )
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    assert_true(mk_chain_build_parallel_eligible(4), "FORCE ignored")
    var bounds = mk_build_chunk_bounds(7)
    assert_equal(len(bounds), 8, "FORCE tiling is not one row per chunk")
    assert_equal(bounds[0], 0, "tiling does not start at 0")
    assert_equal(bounds[7], 7, "tiling does not end at n")
    reset_hash_chain_build_settings()
    var big = mk_build_chunk_bounds(1_000_000)
    assert_equal(big[0], 0, "prod tiling does not start at 0")
    assert_equal(big[len(big) - 1], 1_000_000, "prod tiling does not end at n")
    for i in range(1, len(big)):
        assert_true(big[i] > big[i - 1], "prod tiling is not monotone")
    assert_true(
        big[1] - big[0] >= _MK_MIN_CHUNK_ROWS,
        "prod tiling rows-per-chunk=" + String(big[1] - big[0])
        + " is below the _MK_MIN_CHUNK_ROWS floor of "
        + String(_MK_MIN_CHUNK_ROWS),
    )
    var prod_50k = mk_build_chunk_bounds(50_000)
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    var forced_50k = mk_build_chunk_bounds(50_000)
    reset_hash_chain_build_settings()
    assert_equal(
        forced_50k[1] - forced_50k[0], 1,
        "FORCE tiling is not one row per chunk at production row counts",
    )
    assert_true(
        len(forced_50k) > len(prod_50k),
        "FORCE and production produce the SAME tiling",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_bloom_insert_atomic_is_byte_identical_and_order_free]()
    suite.test[test_dispatch_witness_and_byte_identical_mutant]()
    suite.test[test_varied_two_key_fixture]()
    suite.test[test_negative_and_extreme_keys]()
    suite.test[test_skew_all_keys_equal]()
    suite.test[test_sentinel_rows_are_recorded_but_unreachable]()
    suite.test[test_all_sentinel_build_side]()
    suite.test[test_edge_shapes_empty_single_and_zero_match]()
    suite.test[test_key_arity_one_three_and_ragged_delegation]()
    suite.test[test_wave_inline_arm_matches_serial_build]()
    suite.test[test_gate_and_tiling]()
    suite^.run()
