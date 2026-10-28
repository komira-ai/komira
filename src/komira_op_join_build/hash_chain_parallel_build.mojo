# =============================================================================
# hash_chain_parallel_build -- the parallel Treiber-push chained-hash build of
# `HashJoinBuilder`
# =============================================================================
#
# The serial build inserts every build row on the driver while the pool waits.
# This one partitions the build rows into morsels; each worker writes its rows'
# key, chain link and (unless elided) row index into slots no other worker
# names, and pushes the row onto its bucket's chain with an atomic
# compare-exchange on the chain head. The kernel (`chain_build_parallel`) emits
# raw `ChainBuildBuffers`; `hash_join_build_parallel` wraps them into a
# `HashJoinBuilder`, and is always safe to call in place of
# `HashJoinBuilder.build(keys, build_bloom=False)`: below the threshold it IS
# that call.
#
# BYTE-SAFETY (why the Treiber chain order is safe):
#   * The chain ORDER within a bucket depends on which worker pushed first, so
#     the join's OUTPUT ROW ORDER can differ from the serial build's. The
#     parallel probe already has the same freedom; consumers sort or aggregate.
#   * The MATCH SET per probe key is identical: same `_hash_join_key`, same
#     capacity and mask, same key equality, same NULL rule (a NULL build key is
#     recorded but never linked).
#   * NO bloom: every caller wants `use_bloom=False`, so there is nothing to
#     populate and the probe walks every chain.
#
# SETTINGS (`hash_chain_build_settings`, set from flags): the build mode (AUTO
# above `JOIN_BUILD_PARALLEL_THRESHOLD` rows, OFF, or the FORCE test hook) and
# who fills the chain-head table (fanned by `ChainFillTask` by default, or one
# driver `memset`).
#
# Reachability witness: `join_parallel_build_counter` FIRE (+1 per parallel
# build) and SPAN (most task instances that claimed a morsel). A byte-oracle is
# blind to WHICH arm ran; the counters are the falsifier.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.io import FileDescriptor
from std.memory import memset, UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import (
    SITE_JOIN_HASH_BUILD,
    SITE_JOIN_HT_FILL,
    sched_trace_enabled,
)
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_engine_runtime.fan_out_grain import parallel_fork_grain
from komira_engine_runtime.grain_geometry import grain_geometry_record
from komira_join_assembly.join_payload_inline import (
    JOIN_KN_WORDS,
    JOIN_KN_WORDS_PAY,
    join_payload_inline_record_build,
)

from .hash_chain_build_settings import (
    JOIN_BUILD_PARALLEL_THRESHOLD,
    JOIN_PARALLEL_BUILD_FORCE,
    JOIN_PARALLEL_BUILD_OFF,
    ht_fill_morsel_slots,
    join_ht_fill_parallel_on,
    join_parallel_build_mode,
)
from .hash_chain_build_state import (
    ChainBuildBuffers,
    ChainBuildState,
    ChainFillTask,
)
from .join import HashJoinBuilder, _CHAIN_END, _hash_join_key
from .join_layout_counter import join_layout_record_build
from .join_parallel_build_counter import (
    join_parallel_build_fire_incr,
    join_parallel_build_record_worker_span,
)


# Software prefetch distance for the chain-head RMW (mirrors the serial build's
# `_PREFETCH_DISTANCE`): the random `ht[slot]` write is the dominant cache-miss
# source at these table sizes.
comptime _PF_DIST: Int = 8

# fd 2: a query's stdout is its result stream.
comptime _HCB_STDERR: FileDescriptor = FileDescriptor(2)


# THE FILL FLOOR IS ON BYTES, NOT ROWS. The gain is `cap * 8 / bandwidth`
# scaled by the pool; the cost is ONE extra fork, invariant in the data.
#
# AND IT IS VERY NEARLY VACUOUS IN PRODUCTION: the parallel build is reached
# only above 250,000 build rows, which already implies `cap = 524,288`, EXACTLY
# 4 MiB. Where it binds is under FORCE, which drives the parallel arm at
# fixture sizes, so FORCE bypasses it, or no test could observe the wave.
comptime _HT_FILL_MIN_BYTES: Int = 4 * 1024 * 1024


def ht_fill_fan_eligible(cap: Int, pool_n: Int, forced: Bool) raises -> Bool:
    """True iff the chain-head fill for a `cap`-slot table should be FANNED.

    Three terms, resolved ONCE per build by the driver:
      * the fill setting (fanned by default),
      * a pool with at least two workers (a one-worker fan is the serial fill
        plus a fork), and
      * `cap * 8 >= _HT_FILL_MIN_BYTES`, bypassed under FORCE so a
        fixture-sized table can still exercise the wave.
    """
    if not join_ht_fill_parallel_on():
        return False
    if pool_n < 2:
        return False
    if cap <= 0:
        return False
    if forced:
        return True
    return cap * 8 >= _HT_FILL_MIN_BYTES


def chain_build_parallel_eligible(num_rows: Int) raises -> Bool:
    """True iff the parallel build should serve a build of `num_rows` rows:
    the mode is not OFF, the build is non-empty, and either the mode is FORCE
    or the row count clears `JOIN_BUILD_PARALLEL_THRESHOLD`."""
    var mode = join_parallel_build_mode()
    if mode == JOIN_PARALLEL_BUILD_OFF:
        return False
    if num_rows <= 0:
        return False
    if mode == JOIN_PARALLEL_BUILD_FORCE:
        return True
    return num_rows >= JOIN_BUILD_PARALLEL_THRESHOLD


# =============================================================================
# Parallel Treiber-push chain insert
# =============================================================================


@fieldwise_init
struct _ChainBuildTask[elide_bi: Bool, fused: Bool, pay: Bool](Segment):
    """Each task claims build-row morsels, fills the disjoint `build_keys[i]` /
    `build_indices[i]` / `next_chain[i]`, and Treiber-pushes each non-null build
    row index into its hash bucket (chain order irrelevant per the module
    byte-safety argument).

    CHAIN-ENTRY LAYOUT. The layout dispositions are COMPTIME parameters,
    resolved once by the driver from its arguments and burned into the
    instantiation:

      `elide_bi` -> `build_indices` is not allocated and `(bi_ptr + i)[] = i` is
                    not emitted. On a 25M-row build that is a 200 MB allocation
                    and 200 MB of build-side write traffic deleted, and one of the probe's five
                    random dependent loads with it.
      `fused`    -> the row's key and chain link are written as ONE 16-byte
                    record into `key_next` instead of into two 200 MB arrays.
                    `build_keys` and `next_chain` are not allocated.
      `pay`      -> the record is 32 bytes instead of 16 and additionally
                    carries a copy of ONE build column in word 2 (word 3 is
                    PAD), so the probe's chain touch yields the payload and the
                    per-output-row random gather out of that column is deleted.
                    Implies `fused`. See `join_payload_inline`.

    ⚠ THE DISJOINTNESS ARGUMENT IS UNCHANGED AND MUST STAY THAT WAY: under
    `fused`, morsel-owner `i` writes exactly `key_next[2i]` and `key_next[2i+1]`,
    which no other row's owner can name. Interleaving does not introduce
    sharing; it renames two disjoint slots into one disjoint pair.

    ⭐ AND `pay` DOES NOT WEAKEN IT. Morsel-owner `i` writes exactly
    `key_next[4i .. 4i+3]` -- four CONSECUTIVE slots no other row's owner can
    name, because row ownership is by ROW INDEX and the map `i -> [4i, 4i+4)`
    is injective with disjoint images. Widening the record renames four disjoint
    slots into one disjoint quad; it introduces no sharing and no new
    cross-worker ordering. `pay_values` is READ-ONLY across the whole window.

    `[False, False, False]` is the split-layout loop, the A/B control."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: `run_with_state` erases the concrete state type; the driver
        # below is the only dispatcher of this Segment and always pairs it with
        # `ChainBuildState`. Borrowed for the fork-join window only.
        var sp = UnsafePointer(to=state).bitcast[ChainBuildState]()
        var num_morsels = sp[].num_build_morsels
        var morsel_size = sp[].morsel_size
        var n = sp[].n
        var mask = sp[].mask
        var has_nulls = sp[].has_nulls

        ref keys = sp[].keys
        var kview = keys.data.view_ro()
        # SAFETY: `keys` is owned by the borrowed state, alive across the
        # fork-join barrier. `kview` keepalive holds the buffer for the loop.
        # INT64 storage; `keys.offset` folds any array slice offset.
        var kptr = kview._unsafe_ptr().bitcast[Scalar[DType.int64]]() + keys.offset
        var bk_ptr = sp[].build_keys.unsafe_ptr()
        var bi_ptr = sp[].build_indices.unsafe_ptr()
        # Fused record view; empty and never dereferenced unless `fused`.
        var kn_ptr = sp[].key_next.unsafe_ptr()
        # PAYLOAD-INLINE. The stride is COMPTIME so the default instantiation
        # compiles to byte-for-byte the pre-lever loop -- the same reason
        # `elide_bi` and `fused` are parameters and not fields.
        comptime _KNW = JOIN_KN_WORDS_PAY if Self.pay else JOIN_KN_WORDS
        # SAFETY: read-only for the whole fork-join window; empty and never
        # dereferenced unless `pay`. Same borrow argument as `kn_ptr`.
        var pay_ptr = sp[].pay_values.unsafe_ptr()
        # SAFETY: the chain-head table is the builders' `List[Int]`; `Int` and
        # `Int64` are layout-identical, so the bitcast is a pure reinterpretation
        # that lets the aligned 64-bit chain-head slot bind
        # `AtomicI64.compare_exchange` directly. Origin is the borrowed
        # state's; the pointer never leaves this method.
        var ht_ptr = sp[].hash_table.unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var nc_ptr = sp[].next_chain.unsafe_ptr()

        var did_work = False
        while True:
            var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if morsel_idx >= num_morsels:
                break
            if not did_work:
                did_work = True
                _ = sp[].workers_active[].fetch_add(Int64(1))

            var start = morsel_idx * morsel_size
            var end = min(start + morsel_size, n)

            for i in range(start, end):
                # Prefetch the chain head this row's successor-at-distance will
                # read-modify-write. Mirrors the serial build; the random
                # `ht[slot]` RMW is the dominant miss at 8 MB+ table sizes.
                if i + _PF_DIST < end:
                    var fkey = Int64((kptr + i + _PF_DIST)[])
                    var fslot = Int(_hash_join_key(fkey) & mask)
                    prefetch[
                        params = PrefetchOptions().for_write().high_locality()
                    ](ht_ptr + fslot)

                var key = Int64((kptr + i)[])
                # `build_keys[i]=key`, `build_indices[i]=i` (disjoint writes)
                # mirror the serial build's per-row append (entry_idx == row i).
                comptime if Self.fused:
                    (kn_ptr + _KNW * i)[] = key
                    # ★ THE LEVER, written by the row's own morsel owner into
                    # its own quad. Word 3 is PAD and is written too: the cost
                    # model that chose 32 B over 24 B charges the full entry
                    # write, and leaving a word of a shipped array undefined to
                    # save traffic the model already paid for is a trade nobody
                    # asked for.
                    comptime if Self.pay:
                        (kn_ptr + _KNW * i + 2)[] = (pay_ptr + i)[]
                        (kn_ptr + _KNW * i + 3)[] = Int64(0)
                else:
                    (bk_ptr + i)[] = key
                comptime if not Self.elide_bi:
                    (bi_ptr + i)[] = i
                # SW-C: a NULL build key is recorded (build_keys/build_indices)
                # but NOT linked into a bucket (never a probe match target).
                # `next_chain[i]` is explicitly terminated so it is well-defined
                # even though no chain walk can reach it.
                if has_nulls and keys.is_null(i):
                    comptime if Self.fused:
                        (kn_ptr + _KNW * i + 1)[] = Int64(_CHAIN_END)
                    else:
                        (nc_ptr + i)[] = _CHAIN_END
                    continue

                var slot = Int(_hash_join_key(key) & mask)
                # Lock-free Treiber push. SAFETY: `ht_ptr + slot` is an
                # owned-state buffer slot; an aligned INT64 read is atomic on the
                # hardware and the CAS validates staleness (a torn/stale `old`
                # simply retries). `next_chain[i]` is a disjoint slot this worker
                # owns.
                while True:
                    var old = Int64((ht_ptr + slot)[])
                    comptime if Self.fused:
                        (kn_ptr + _KNW * i + 1)[] = old
                    else:
                        (nc_ptr + i)[] = Int(old)
                    if AtomicI64.compare_exchange(
                        ht_ptr + slot, old, Int64(i)
                    ):
                        break

        _ = kview
        _ = sp[].pay_values


# =============================================================================
# Driver
# =============================================================================


def chain_build_parallel(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var keys: PrimitiveArray[DType.int64],
    elide_bi: Bool = False,
    fused: Bool = False,
    var pay_values: List[Int64] = List[Int64](),
    pay_build_col: Int = -1,
) raises -> ChainBuildBuffers:
    """Parallel Treiber-push chained-hash build over a single INT64 build key
    column. The caller MUST have checked `chain_build_parallel_eligible` — this
    entry unconditionally takes the parallel path (the eligibility split lives at
    the adapter so each builder type keeps its own serial fallback).

    `cancel_token` is consumed by the dispatch. `keys` is moved into the
    fork-join state (the caller's copy is already private — `Column.as_primitive`
    copies — so this is free).

    `elide_bi` / `fused` ARE PARAMETERS, NOT SETTINGS, AND THAT IS THE POINT.
    The kernel emits raw buffers for whichever builder wraps them, and each
    builder states what its own probes can consume: a layout its probes do not
    read would be a chain walk over an empty `List`, a silent wrong answer.
    """
    join_parallel_build_fire_incr()

    var n = keys.length
    var has_nulls = keys.null_count != 0

    # Capacity: >= 1.4x rows, power of 2, min 16 — identical to the serial
    # `HashJoinBuilder.build`, so the bucket distribution (hence the match set)
    # is identical.
    var min_cap = max(Int(Float64(n) * 1.4) + 1, 16)
    var cap = 1
    while cap < min_cap:
        cap *= 2
    var mask = UInt64(cap - 1)

    # The REAL pool width, not `num_physical_cores()`; it keys the TASK COUNT.
    var pool_n = dispatcher.worker_count()
    if pool_n < 1:
        pool_n = 1

    var forced = join_parallel_build_mode() == JOIN_PARALLEL_BUILD_FORCE

    # -------------------------------------------------------------------------
    # WHICH ARM FILLS THE CHAIN-HEAD TABLE. Resolved ONCE here, per build, and
    # carried on the state; never per row and never per morsel.
    #
    # FANNED (the default): `ht` is left UNINITIALISED here and the bytes are
    # written by `ChainFillTask` across the pool, as its own preceding
    # dispatch. `cap * 8` bytes of single-threaded first-touch is 67 MB at
    # cap = 2^23 and 268 MB at 2^25 with the whole pool parked; fanning it
    # puts that traffic on every worker.
    #
    # DRIVER (`join_ht_fill_configure(False)`): the single `memset` below.
    # `_CHAIN_END` is -1 == all-ones, so one 0xFF byte fill materialises it
    # exactly, far cheaper than `List.resize(cap, _CHAIN_END)`'s scalar fill.
    # KEEP THIS ARM: it is the A/B baseline and the differential oracle.
    # -------------------------------------------------------------------------
    var fill_morsel = ht_fill_morsel_slots()
    var fan_fill = ht_fill_fan_eligible(cap, pool_n, forced)
    var num_fill_morsels = 0
    if fan_fill:
        num_fill_morsels = (cap + fill_morsel - 1) // fill_morsel

    # All LIVE arrays are pre-sized UNINITIALISED; the per-row arrays that the
    # chosen layout keeps are written in full by the BUILD dispatch (every row
    # writes its key and its chain link, null rows included).
    var ht = List[Int]()
    ht.resize(unsafe_uninit_length=cap)
    if not fan_fill:
        # SAFETY: `cap` 64-bit slots owned by this frame; the pointer does not
        # escape.
        memset(ht.unsafe_ptr().bitcast[UInt8](), UInt8(0xFF), cap * 8)
    # CHAIN-ENTRY LAYOUT: an elided array is NOT ALLOCATED AT ALL -- that is
    # where the 200 MB and the 200 MB of first-touch write traffic go on a
    # 25M-row build, and why the lever is not merely "skip a load".
    var build_keys = List[Int64]()
    if not fused:
        build_keys.resize(unsafe_uninit_length=n)
    var build_indices = List[Int]()
    if not elide_bi:
        build_indices.resize(unsafe_uninit_length=n)
    var next_chain = List[Int]()
    if not fused:
        next_chain.resize(unsafe_uninit_length=n)
    # PAYLOAD-INLINE. The entry width is decided ONCE here, from the argument,
    # and every downstream fact -- the allocation, the comptime stride the tasks
    # burn in, and the flag `take_buffers` infers -- is derived from this one
    # value. A second literal anywhere would be a write/read stride that agrees
    # only by coincidence, and the serial builder's tests caught exactly that
    # defect: it cost keys from other rows.
    var pay = fused and len(pay_values) > 0
    if len(pay_values) > 0:
        if not fused:
            raise Error(
                "hash_join_build_parallel: pay_values requires the fused"
                " chain-entry layout"
            )
        if len(pay_values) != n:
            raise Error(
                "hash_join_build_parallel: pay_values length "
                + String(len(pay_values))
                + " != build key count "
                + String(n)
            )
    var kn_words = JOIN_KN_WORDS_PAY if pay else JOIN_KN_WORDS
    var key_next = List[Int64]()
    if fused:
        key_next.resize(unsafe_uninit_length=kn_words * n)

    # A ROUTE THAT DECLINES SILENTLY CANNOT BE READ FROM A FIRE SET.
    # `SCHED_SITE id=55 count>0` witnesses the fanned arm, but its ABSENCE is
    # ambiguous (setting off, floor not cleared, one-worker pool, or the wave
    # never reached). This line states the arm and every term that chose it,
    # on BOTH arms, only under the trace, and to stderr: a query's stdout is
    # its result stream.
    if sched_trace_enabled():
        print(
            "[JOIN_HT_FILL] kernel=chain arm=",
            # `arm=` is the DECIDING value (`fan_fill`); `gate=` is a second,
            # diagnostic read that says WHY a `serial` arm declined (setting
            # off vs floor vs pool). `arm=` is the one that ran.
            "fanned" if fan_fill else "serial",
            " gate=", Int(join_ht_fill_parallel_on()),
            " rows=", n,
            " cap=", cap,
            " fill_bytes=", cap * 8,
            " min_bytes=", _HT_FILL_MIN_BYTES,
            " grain=", fill_morsel,
            " morsels=", num_fill_morsels,
            " pool=", pool_n,
            " forced=", Int(forced),
            file=_HCB_STDERR,
        )
    # WAVE-SNAP over the BUILD row count (`fan_out_grain.parallel_fork_grain`);
    # FORCE takes a one-row grain so a fixture fans across every worker.
    var morsel_size = 1 if forced else parallel_fork_grain(n, pool_n)
    var num_build_morsels = (n + morsel_size - 1) // morsel_size

    var state = ChainBuildState(
        num_build_morsels,
        morsel_size,
        n,
        mask,
        has_nulls,
        cap,
        fill_morsel,
        num_fill_morsels,
        keys^,
        build_keys^,
        build_indices^,
        ht^,
        next_chain^,
        key_next^,
        elide_bi,
        fused,
        pay_values^,
    )

    # -------------------------------------------------------------------------
    # PARALLELIZE-BOUNDARY 0 (gate ON only): the chain-head table FILL.
    # Disjointness: morsel `m` owns the half-open slot range
    #   `[m*M, min((m+1)*M, cap))` of `ht`; the ranges partition `[0, cap)`.
    #   Nothing is read, so the result is claim-order-independent and BYTE-
    #   IDENTICAL to the driver `memset` in the OFF arm above.
    # Liveness: `state` (owning `ht`) is borrowed for the dispatch window; the
    #   pool fork-join barrier outlives all workers.
    # No-realloc: `ht` is pre-sized above and never grows.
    #
    # ⚠ AND THIS WAVE IS A MEMORY-SAFETY PRECONDITION, not merely a perf one.
    # Under this gate `ht` was allocated `unsafe_uninit_length`, so the BUILD
    # wave below reads whatever this wave has not written. Do not weaken the
    # barrier predicate.
    # -------------------------------------------------------------------------
    if fan_fill:
        var fill_n = min(num_fill_morsels, pool_n)
        if fill_n < 1:
            fill_n = 1
        var fill_task = ChainFillTask(Int32(0))
        _ = dispatcher.run_with_state[ChainBuildState, ChainFillTask](
            state, fill_task^, fill_n, cancel_token.clone(),
            site_id=SITE_JOIN_HT_FILL,
        )
        # Barrier reached: every FILL worker has finished and the driver is the
        # sole writer, so the shared morsel counter can be rewound for the BUILD
        # wave. Same mechanic as `_ResidualMarkState.reset_phase()`.
        state.reset_phase()

    # PARALLELIZE-BOUNDARY: parallel chained-hash build (lock-free Treiber push).
    # Disjointness: build_keys[i]/build_indices[i]/next_chain[i] written by the
    #   single worker owning build row i; the ONLY shared location is the `ht`
    #   chain head, updated via atomic compare-exchange. The morsel counter
    #   serialises claims.
    # Liveness: `state` (owning keys / ht / next_chain / build_*) borrowed for the
    #   dispatch window; the pool fork-join barrier outlives all workers.
    # No-realloc: ht/build_keys/build_indices/next_chain pre-sized before the
    #   dispatch, never grow during the build; the key column is read-only.
    var build_n_tasks = min(num_build_morsels, pool_n)
    if build_n_tasks < 1:
        build_n_tasks = 1
    grain_geometry_record(
        SITE_JOIN_HASH_BUILD, n, morsel_size, num_build_morsels, build_n_tasks
    )
    # SIX-WAY COMPTIME LAYOUT DISPATCH. `cancel_token` is CLONED into each arm
    # and the original consumed after, rather than moved in six exclusive
    # branches -- one refcount, and it does not depend on how the ownership
    # checker treats a conditional move.
    #
    # ⚠ `pay` IMPLIES `fused` (refused above), so the two payload arms are the
    # COMPLETE set: there is no `[*, False, True]` instantiation to write and
    # the extra dimension costs two instantiations, not four.
    if elide_bi:
        if fused:
            if pay:
                _ = dispatcher.run_with_state[
                    ChainBuildState, _ChainBuildTask[True, True, True]
                ](
                    state, _ChainBuildTask[True, True, True](Int32(0)),
                    build_n_tasks,
                    cancel_token.clone(), site_id=SITE_JOIN_HASH_BUILD,
                )
            else:
                _ = dispatcher.run_with_state[
                    ChainBuildState, _ChainBuildTask[True, True, False]
                ](
                    state, _ChainBuildTask[True, True, False](Int32(0)),
                    build_n_tasks,
                    cancel_token.clone(), site_id=SITE_JOIN_HASH_BUILD,
                )
        else:
            _ = dispatcher.run_with_state[
                ChainBuildState, _ChainBuildTask[True, False, False]
            ](
                state, _ChainBuildTask[True, False, False](Int32(0)),
                build_n_tasks,
                cancel_token.clone(), site_id=SITE_JOIN_HASH_BUILD,
            )
    else:
        if fused:
            if pay:
                _ = dispatcher.run_with_state[
                    ChainBuildState, _ChainBuildTask[False, True, True]
                ](
                    state, _ChainBuildTask[False, True, True](Int32(0)),
                    build_n_tasks,
                    cancel_token.clone(), site_id=SITE_JOIN_HASH_BUILD,
                )
            else:
                _ = dispatcher.run_with_state[
                    ChainBuildState, _ChainBuildTask[False, True, False]
                ](
                    state, _ChainBuildTask[False, True, False](Int32(0)),
                    build_n_tasks,
                    cancel_token.clone(), site_id=SITE_JOIN_HASH_BUILD,
                )
        else:
            _ = dispatcher.run_with_state[
                ChainBuildState, _ChainBuildTask[False, False, False]
            ](
                state, _ChainBuildTask[False, False, False](Int32(0)),
                build_n_tasks,
                cancel_token.clone(), site_id=SITE_JOIN_HASH_BUILD,
            )
    _ = cancel_token^
    join_layout_record_build(
        "chain", elide_bi, fused, n, sched_trace_enabled()
    )
    if pay:
        join_payload_inline_record_build(n, pay_build_col)
    join_parallel_build_record_worker_span(Int(state.workers_active[].load()))

    var out = state.take_buffers()
    _ = state^
    return out^


# =============================================================================
# Adapter -- `HashJoinBuilder`
# =============================================================================


def hash_join_build_parallel(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var keys: PrimitiveArray[DType.int64],
    nobi: Bool = True,
    fused: Bool = True,
    var pay_values: List[Int64] = List[Int64](),
    pay_build_col: Int = -1,
) raises -> HashJoinBuilder:
    """Bloom-free hash-join build of a `HashJoinBuilder`, parallel above the
    threshold and serial below it, so this entry is ALWAYS safe to call in
    place of `HashJoinBuilder.build(keys, build_bloom=False)`.

    Exactly equivalent to that call: the returned builder carries
    `use_bloom=False` on BOTH arms, so the probe's bloom pre-check is bypassed
    identically. The only observable difference above the gate is the per-bucket
    chain ORDER (see the module byte-safety note).

    THE DEFAULTS MATCH `HashJoinBuilder.build`'s, AND THE SERIAL FALLBACK
    PASSES THEM EXPLICITLY. A build under the threshold has to produce the
    SAME layout as one over it, or a probe would be handed a layout that
    depends on the build side's SIZE.

    Args:
        dispatcher: The local dispatcher for the parallel arm.
        cancel_token: Cancellation token, consumed either way.
        keys: The build-side key column, consumed.
        nobi: Chain-entry layout, the shipped default. See
            `HashJoinBuilder.build`.
        fused: Chain-entry layout, the shipped default. See
            `HashJoinBuilder.build`.
        pay_values: PAYLOAD-INLINE, one Int64 per build row, or
            EMPTY for the shipped 16-byte entry. See `HashJoinBuilder.build`.
        pay_build_col: The build-batch column `pay_values` copies, or -1.
    """
    if not chain_build_parallel_eligible(keys.length):
        _ = cancel_token^
        # ⚠ THE PAYLOAD MUST CROSS THE THRESHOLD TOO. A build under the gate has
        # to produce the SAME layout as one over it -- the invariant the
        # `nobi`/`fused` note above already states -- and a payload dropped here
        # would hand the probe a layout that depends on the build side's SIZE.
        # That failure is invisible: the small build simply gathers.
        return HashJoinBuilder.build(
            keys,
            build_bloom=False,
            nobi=nobi,
            fused=fused,
            pay_values=pay_values^,
            pay_build_col=pay_build_col,
        )

    var bufs = chain_build_parallel(
        dispatcher,
        cancel_token^,
        keys^,
        elide_bi=nobi,
        fused=fused,
        pay_values=pay_values^,
        pay_build_col=pay_build_col,
    )
    var n_rows = bufs.num_build
    var bi_elided = bufs.bi_elided
    var kn_fused = bufs.fused
    var kn_pay = bufs.pay_inline
    var builder = HashJoinBuilder(
        build_keys=bufs.take_build_keys(),
        build_indices=bufs.take_build_indices(),
        hash_table=bufs.take_hash_table(),
        next_chain=bufs.take_next_chain(),
        capacity=bufs.capacity,
        bloom=BloomFilter(),
        use_bloom=False,
        key_next=bufs.take_key_next(),
        num_build=n_rows,
        bi_elided=bi_elided,
        fused=kn_fused,
        pay_inline=kn_pay,
        pay_build_col=pay_build_col,
    )
    _ = bufs^
    return builder^
