# =============================================================================
# parallel_inner_probe -- the single-INT64-key INNER probes, forked over the
# engine's dispatcher
# =============================================================================
#
# Two entry points, both appending (build row, probe row) pairs to the
# caller's lists:
#
#   * `parallel_inner_join_probe_into` -- probes a chained `HashJoinBuilder`.
#   * `parallel_perfect_inner_probe_into` -- probes a `PerfectHashJoin` (one
#     array read per probe row).
#
# Each splits the probe rows into morsels of `parallel_fork_grain(rows, pool)`
# rows, dispatches one task per worker through `run_with_state`, and each task
# claims morsels from an atomic counter and appends its matches to its own
# pair of lists. The lists are then moved, in worker order, onto the caller's.
# The set of pairs equals the serial probe's; their order depends on which
# worker claimed which morsel.
#
# A NULL probe key matches nothing: both task bodies skip a row the caller's
# `ProbeNullMask` flags, and the one-morsel arm calls the serial probe, which
# reads the key column's own validity.
#
# Pointers in this file live in the private State structs and in method
# bodies, at the origin of the value they point into; no public function takes
# or returns one.
# =============================================================================

from std.memory import alloc, OwnedPointer, UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_JOIN_PROBE
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_engine_runtime.fan_out_grain import parallel_fork_grain
from komira_engine_runtime.grain_geometry import grain_geometry_record
from komira_op_join_build.join import HashJoinBuilder, _hash_join_key, _CHAIN_END
from komira_op_join_build.join_layout_counter import join_layout_record_probe
from komira_op_join_build.join_perfect_hash import PerfectHashJoin, _PERFECT_EMPTY
from komira_op_join_build.join_probe_null_mask import ProbeNullMask


# Rows ahead of the current probe row whose hash bucket is prefetched.
comptime _PROBE_PF_DIST: Int = 8


def _new_morsel_counter() -> OwnedPointer[AtomicI64]:
    """A heap-allocated atomic counter starting at 0.

    `Atomic` is not movable, so it is constructed in place in the allocation
    `OwnedPointer` then owns and frees."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _pool_width(mut dispatcher: LocalDispatcher[NoopSink]) -> Int:
    """The dispatcher's worker count, at least 1. The grain and the task count
    are both sized from the pool the fork runs on, never from the host's core
    count."""
    var n = dispatcher.worker_count()
    if n < 1:
        return 1
    return n


def _check_probe_rows(
    keys: PrimitiveArray[DType.int64], num_probe_rows: Int
) raises:
    """Raise unless `num_probe_rows` lies in `[0, keys.length]`."""
    if num_probe_rows < 0 or num_probe_rows > keys.length:
        raise Error(
            "parallel inner probe: num_probe_rows "
            + String(num_probe_rows)
            + " is outside the key array of "
            + String(keys.length)
            + " rows"
        )


def _move_worker_pairs(
    mut worker_build: Slab[List[Int]],
    mut worker_probe: Slab[List[Int]],
    num_workers: Int,
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
):
    """Append every worker's pairs to the caller's lists, worker 0 first.

    One `reserve` for the total, then each worker's `List[Int]` is moved out
    of its slot and appended with `extend`, a bulk copy. The slots are then
    marked empty so the slabs' destructors do not touch the moved-from
    lists."""
    var total = 0
    for w in range(num_workers):
        total += len(worker_build[w])
    build_matches.reserve(len(build_matches) + total)
    probe_matches.reserve(len(probe_matches) + total)
    for w in range(num_workers):
        var wb = worker_build.take_slot_unchecked(w)
        var wp = worker_probe.take_slot_unchecked(w)
        build_matches.extend(wb^)
        probe_matches.extend(wp^)
    worker_build.set_len_unchecked(0)
    worker_probe.set_len_unchecked(0)


def _worker_lists(num_workers: Int, per_worker: Int) -> Slab[List[Int]]:
    var s = Slab[List[Int]].create(num_workers)
    for _ in range(num_workers):
        s.append(List[Int](capacity=per_worker))
    return s^


# =============================================================================
# Chained hash-join probe
# =============================================================================


struct _InnerProbeState[
    probe_origin: ImmOrigin,
    builder_origin: ImmOrigin,
](KeepAlive):
    """What every task of `parallel_inner_join_probe_into` reads.

    Task `t` appends only to `worker_build[t]` and `worker_probe[t]`; the
    builder and the probe keys are read-only for the whole fork; the morsel
    counter is the only shared write."""

    var num_morsels: Int
    var morsel_size: Int
    var num_probe_rows: Int
    var mask: UInt64
    var probe_nulls: ProbeNullMask
    var worker_build: Slab[List[Int]]
    var worker_probe: Slab[List[Int]]
    # SAFETY: the probe key column's values, valid while the caller's
    # `PrimitiveArray` borrow (`probe_origin`) is live, which spans the fork.
    var probe_key_ptr: UnsafePointer[Scalar[DType.int64], Self.probe_origin]
    var builder: Pointer[HashJoinBuilder, Self.builder_origin]
    var morsel_counter: OwnedPointer[AtomicI64]

    def __init__(
        out self,
        num_morsels: Int,
        morsel_size: Int,
        num_probe_rows: Int,
        mask: UInt64,
        var probe_nulls: ProbeNullMask,
        var worker_build: Slab[List[Int]],
        var worker_probe: Slab[List[Int]],
        probe_key_ptr: UnsafePointer[Scalar[DType.int64], Self.probe_origin],
        builder: Pointer[HashJoinBuilder, Self.builder_origin],
    ):
        self.num_morsels = num_morsels
        self.morsel_size = morsel_size
        self.num_probe_rows = num_probe_rows
        self.mask = mask
        self.probe_nulls = probe_nulls^
        self.worker_build = worker_build^
        self.worker_probe = worker_probe^
        self.probe_key_ptr = probe_key_ptr
        self.builder = builder
        self.morsel_counter = _new_morsel_counter()


@fieldwise_init
struct _InnerProbeTask[
    probe_origin: ImmOrigin,
    builder_origin: ImmOrigin,
    fused: Bool,
    nobi: Bool,
](Segment):
    """One worker of the chained INNER probe.

    Two-stage software prefetch: the hash bucket of the row `_PROBE_PF_DIST`
    ahead, then the chain head's key of the row half that distance ahead.

    `fused` and `nobi` are the builder's chain-entry layout, resolved once by
    the driver so the row loop tests no runtime flag:

      `nobi`  -> `build_indices` is not stored; the chain index is the build
                 row.
      `fused` -> each chain entry's key and next link are one 16-byte record
                 in `key_next` (`[2i]` key, `[2i + 1]` next) instead of two
                 arrays.

    In every arm the chain link is read after the key compare."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: `run_with_state` erases the state type; the only dispatcher
        # of this Segment is `parallel_inner_join_probe_into`, which always
        # pairs it with `_InnerProbeState` of the same origins.
        var sp = UnsafePointer(to=state).bitcast[
            _InnerProbeState[Self.probe_origin, Self.builder_origin]
        ]()
        var wid = Int(task_id)
        var num_morsels = sp[].num_morsels
        var morsel_size = sp[].morsel_size
        var num_probe_rows = sp[].num_probe_rows
        var mask = sp[].mask
        var probe_key_ptr = sp[].probe_key_ptr
        # Hoisted: False for an all-valid probe, so the per-row guard is one
        # compare against a register and the (empty) flag list is never read.
        var probe_has_nulls = sp[].probe_nulls.has_nulls

        # SAFETY: the builder is read-only for the fork; each pointer is into
        # one of its lists, at the list's origin through the builder borrow.
        ref b = sp[].builder[]
        var ht_ptr = b.hash_table.unsafe_ptr()
        var bk_ptr = b.build_keys.unsafe_ptr()
        var bi_ptr = b.build_indices.unsafe_ptr()
        var nc_ptr = b.next_chain.unsafe_ptr()
        # Empty, and never dereferenced, unless `fused`.
        var kn_ptr = b.key_next.unsafe_ptr()
        # A builder built without a bloom filter carries a zero-block
        # placeholder whose buffer is NULL; checking a key against it reads
        # through that NULL. Every probe-side bloom call is gated on this flag.
        var use_bloom = b._use_bloom

        while True:
            var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if morsel_idx >= num_morsels:
                break
            var start = morsel_idx * morsel_size
            var end = min(start + morsel_size, num_probe_rows)

            for probe_idx in range(start, end):
                if probe_idx + _PROBE_PF_DIST < end:
                    var fk = Int64((probe_key_ptr + probe_idx + _PROBE_PF_DIST)[])
                    var fslot = Int(_hash_join_key(fk) & mask)
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (ht_ptr + fslot).bitcast[Scalar[DType.int64]]()
                    )
                if probe_idx + _PROBE_PF_DIST // 2 < end:
                    var mk = Int64((probe_key_ptr + probe_idx + _PROBE_PF_DIST // 2)[])
                    var mc = (ht_ptr + Int(_hash_join_key(mk) & mask))[]
                    if mc != _CHAIN_END:
                        comptime if Self.fused:
                            prefetch[params = PrefetchOptions().for_read().high_locality()](
                                (kn_ptr + 2 * mc).bitcast[Scalar[DType.int64]]()
                            )
                        else:
                            prefetch[params = PrefetchOptions().for_read().high_locality()](
                                (bk_ptr + mc).bitcast[Scalar[DType.int64]]()
                            )

                var probe_key = Int64((probe_key_ptr + probe_idx)[])
                # A NULL probe key matches nothing. The value under a cleared
                # validity bit is unspecified (in practice 0), so without this
                # a NULL row would match a real build key 0.
                if probe_has_nulls and sp[].probe_nulls.is_null_at(probe_idx):
                    continue
                var h = _hash_join_key(probe_key)
                if use_bloom and not b.bloom.might_contain_join_key(probe_key, h):
                    continue

                var chain_idx = (ht_ptr + Int(h & mask))[]
                while chain_idx != _CHAIN_END:
                    var chain_key: Int64
                    comptime if Self.fused:
                        chain_key = (kn_ptr + 2 * chain_idx)[]
                    else:
                        chain_key = (bk_ptr + chain_idx)[]
                    if chain_key == probe_key:
                        comptime if Self.nobi:
                            sp[].worker_build[wid].append(chain_idx)
                        else:
                            sp[].worker_build[wid].append((bi_ptr + chain_idx)[])
                        sp[].worker_probe[wid].append(probe_idx)
                    comptime if Self.fused:
                        chain_idx = Int((kn_ptr + 2 * chain_idx + 1)[])
                    else:
                        chain_idx = (nc_ptr + chain_idx)[]


def _estimated_pairs_per_worker(
    join_builder: HashJoinBuilder, num_probe_rows: Int, num_workers: Int
) -> Int:
    """The initial capacity of each worker's output lists.

    PERF-CRITICAL: sizing for a 1:1 join makes a high fan-out join (each probe
    row matching ~100 build rows) re-grow every worker list several times.
    The expected match count is `num_probe * build_rows / distinct_keys`; the
    count of non-empty buckets stands in for the distinct keys. Counting them
    is a serial scan of all `capacity` buckets on the calling thread before the
    fork (capacity is the build row count times ~1.4 rounded up to a power of
    two). The result is padded by 10%, never below one pair per probe row, and
    never below 1024 per worker."""
    var non_empty = 0
    var ht = join_builder.hash_table.unsafe_ptr()
    for b in range(join_builder.capacity):
        if (ht + b)[] != _CHAIN_END:
            non_empty += 1
    var per_probe = 1
    if non_empty > 0 and join_builder.num_build > 0:
        var avg_chain = join_builder.num_build // non_empty
        if avg_chain > 0:
            per_probe = avg_chain
    var total = Int(Float64(num_probe_rows) * Float64(per_probe) * 1.1)
    if total < num_probe_rows:
        total = num_probe_rows
    return max(total // max(num_workers, 1), 1024)


def parallel_inner_join_probe_into(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    join_builder: HashJoinBuilder,
    left_key_arr: PrimitiveArray[DType.int64],
    num_probe_rows: Int,
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
    var probe_nulls: ProbeNullMask,
) raises:
    """INNER probe of `join_builder` by the first `num_probe_rows` keys of
    `left_key_arr`, forked over `dispatcher`, appending each match's build
    row to `build_matches` and probe row to `probe_matches`.

    With one morsel (`num_probe_rows` at or below the fork grain) this is the
    serial `HashJoinBuilder.probe_inner_into`, which reads the key column's
    own validity; `probe_nulls` is then unused.

    Args:
        dispatcher: The pool the probe forks over; its worker count sizes the
            grain and the task count.
        cancel_token: Cancels the fork.
        join_builder: The built table; read-only during the probe.
        left_key_arr: The probe key column.
        num_probe_rows: Probe rows to read from `left_key_arr`.
        build_matches: Build row of each match, appended.
        probe_matches: Probe row of each match, appended.
        probe_nulls: Which probe rows hold a NULL key, built once by the caller
            from `left_key_arr`.
    """
    _check_probe_rows(left_key_arr, num_probe_rows)
    var pool_n = _pool_width(dispatcher)
    var morsel_size = parallel_fork_grain(num_probe_rows, pool_n)
    var num_morsels = (num_probe_rows + morsel_size - 1) // morsel_size
    var num_workers = min(num_morsels, pool_n)
    grain_geometry_record(
        SITE_JOIN_PROBE, num_probe_rows, morsel_size, num_morsels, num_workers
    )

    if num_morsels <= 1:
        join_builder.probe_inner_into(
            left_key_arr.slice(0, num_probe_rows), build_matches, probe_matches
        )
        return

    var per_worker = _estimated_pairs_per_worker(
        join_builder, num_probe_rows, num_workers
    )

    comptime probe_o = origin_of(left_key_arr.data)
    comptime builder_o = origin_of(join_builder)
    var probe_key_view = left_key_arr.data.view_ro()
    # SAFETY: restated at `probe_o`, the origin of the array's data buffer,
    # which the caller's borrow of `left_key_arr` keeps alive through the fork.
    var probe_key_ptr = (
        probe_key_view._unsafe_ptr()
        .bitcast[Scalar[DType.int64]]()
        .unsafe_origin_cast[probe_o]()
        + left_key_arr.offset
    )

    var state = _InnerProbeState[probe_o, builder_o](
        num_morsels,
        morsel_size,
        num_probe_rows,
        UInt64(join_builder.capacity - 1),
        probe_nulls^,
        _worker_lists(num_workers, per_worker),
        _worker_lists(num_workers, per_worker),
        probe_key_ptr,
        Pointer(to=join_builder),
    )

    # The layout arm is read off the builder, which resolved it at build time.
    join_layout_record_probe(
        "parallel_inner_join_probe_into",
        join_builder._bi_elided,
        join_builder._fused,
    )
    if join_builder._fused:
        if join_builder._bi_elided:
            _ = dispatcher.run_with_state[
                _InnerProbeState[probe_o, builder_o],
                _InnerProbeTask[probe_o, builder_o, True, True],
            ](
                state,
                _InnerProbeTask[probe_o, builder_o, True, True](Int32(0)),
                num_workers,
                cancel_token.clone(),
                site_id=SITE_JOIN_PROBE,
            )
        else:
            _ = dispatcher.run_with_state[
                _InnerProbeState[probe_o, builder_o],
                _InnerProbeTask[probe_o, builder_o, True, False],
            ](
                state,
                _InnerProbeTask[probe_o, builder_o, True, False](Int32(0)),
                num_workers,
                cancel_token.clone(),
                site_id=SITE_JOIN_PROBE,
            )
    else:
        if join_builder._bi_elided:
            _ = dispatcher.run_with_state[
                _InnerProbeState[probe_o, builder_o],
                _InnerProbeTask[probe_o, builder_o, False, True],
            ](
                state,
                _InnerProbeTask[probe_o, builder_o, False, True](Int32(0)),
                num_workers,
                cancel_token.clone(),
                site_id=SITE_JOIN_PROBE,
            )
        else:
            _ = dispatcher.run_with_state[
                _InnerProbeState[probe_o, builder_o],
                _InnerProbeTask[probe_o, builder_o, False, False],
            ](
                state,
                _InnerProbeTask[probe_o, builder_o, False, False](Int32(0)),
                num_workers,
                cancel_token.clone(),
                site_id=SITE_JOIN_PROBE,
            )
    _ = cancel_token^

    _move_worker_pairs(
        state.worker_build,
        state.worker_probe,
        num_workers,
        build_matches,
        probe_matches,
    )
    _ = probe_key_view
    _ = state^


# =============================================================================
# Perfect-hash probe
# =============================================================================


struct _PerfectProbeState[
    probe_origin: ImmOrigin,
    perfect_origin: ImmOrigin,
](KeepAlive):
    """What every task of `parallel_perfect_inner_probe_into` reads. Same
    ownership as `_InnerProbeState`; the entries array is read-only."""

    var num_morsels: Int
    var morsel_size: Int
    var num_probe_rows: Int
    var min_key: Int
    var range_size: Int
    var probe_nulls: ProbeNullMask
    var worker_build: Slab[List[Int]]
    var worker_probe: Slab[List[Int]]
    # SAFETY: as `_InnerProbeState.probe_key_ptr`.
    var probe_key_ptr: UnsafePointer[Scalar[DType.int64], Self.probe_origin]
    # SAFETY: the perfect table's entries, at the origin of the caller's
    # borrow of the table, which spans the fork; not written during the probe.
    var entries_ptr: UnsafePointer[Int, Self.perfect_origin]
    var morsel_counter: OwnedPointer[AtomicI64]

    def __init__(
        out self,
        num_morsels: Int,
        morsel_size: Int,
        num_probe_rows: Int,
        min_key: Int,
        range_size: Int,
        var probe_nulls: ProbeNullMask,
        var worker_build: Slab[List[Int]],
        var worker_probe: Slab[List[Int]],
        probe_key_ptr: UnsafePointer[Scalar[DType.int64], Self.probe_origin],
        entries_ptr: UnsafePointer[Int, Self.perfect_origin],
    ):
        self.num_morsels = num_morsels
        self.morsel_size = morsel_size
        self.num_probe_rows = num_probe_rows
        self.min_key = min_key
        self.range_size = range_size
        self.probe_nulls = probe_nulls^
        self.worker_build = worker_build^
        self.worker_probe = worker_probe^
        self.probe_key_ptr = probe_key_ptr
        self.entries_ptr = entries_ptr
        self.morsel_counter = _new_morsel_counter()


@fieldwise_init
struct _PerfectProbeTask[
    probe_origin: ImmOrigin,
    perfect_origin: ImmOrigin,
](Segment):
    """One worker of the perfect-hash INNER probe: `entries[key - min_key]`
    is the build row, or `_PERFECT_EMPTY`."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: the only dispatcher of this Segment is
        # `parallel_perfect_inner_probe_into`, which always pairs it with
        # `_PerfectProbeState` of the same origins.
        var sp = UnsafePointer(to=state).bitcast[
            _PerfectProbeState[Self.probe_origin, Self.perfect_origin]
        ]()
        var wid = Int(task_id)
        var num_morsels = sp[].num_morsels
        var morsel_size = sp[].morsel_size
        var num_probe_rows = sp[].num_probe_rows
        var mn = sp[].min_key
        var rng = sp[].range_size
        var probe_key_ptr = sp[].probe_key_ptr
        var entries_ptr = sp[].entries_ptr
        var probe_has_nulls = sp[].probe_nulls.has_nulls

        while True:
            var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if morsel_idx >= num_morsels:
                break
            var start = morsel_idx * morsel_size
            var end = min(start + morsel_size, num_probe_rows)
            for probe_idx in range(start, end):
                # A NULL probe key matches nothing; its value (in practice 0)
                # would otherwise land on slot `0 - min_key`.
                if probe_has_nulls and sp[].probe_nulls.is_null_at(probe_idx):
                    continue
                var idx = Int((probe_key_ptr + probe_idx)[]) - mn
                if idx >= 0 and idx < rng:
                    var build_row = (entries_ptr + idx)[]
                    if build_row != _PERFECT_EMPTY:
                        sp[].worker_build[wid].append(build_row)
                        sp[].worker_probe[wid].append(probe_idx)


def parallel_perfect_inner_probe_into(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    mut perfect: PerfectHashJoin,
    left_key_arr: PrimitiveArray[DType.int64],
    num_probe_rows: Int,
    mut build_matches: List[Int],
    mut probe_matches: List[Int],
    var probe_nulls: ProbeNullMask,
) raises:
    """INNER probe of a `PerfectHashJoin`, forked over `dispatcher`; the
    arguments are those of `parallel_inner_join_probe_into`.

    With one morsel this is the serial `PerfectHashJoin.probe_inner_into`,
    which reads the key column's own validity."""
    _check_probe_rows(left_key_arr, num_probe_rows)
    var pool_n = _pool_width(dispatcher)
    var morsel_size = parallel_fork_grain(num_probe_rows, pool_n)
    var num_morsels = (num_probe_rows + morsel_size - 1) // morsel_size
    var num_workers = min(num_morsels, pool_n)
    grain_geometry_record(
        SITE_JOIN_PROBE, num_probe_rows, morsel_size, num_morsels, num_workers
    )

    if num_morsels <= 1:
        perfect.probe_inner_into(
            left_key_arr.slice(0, num_probe_rows), build_matches, probe_matches
        )
        return

    var per_worker = max((num_probe_rows + num_workers - 1) // num_workers, 1024)

    comptime probe_o = origin_of(left_key_arr.data)
    comptime perfect_o = origin_of(perfect._entries)
    var probe_key_view = left_key_arr.data.view_ro()
    # SAFETY: as in `parallel_inner_join_probe_into`.
    var probe_key_ptr = (
        probe_key_view._unsafe_ptr()
        .bitcast[Scalar[DType.int64]]()
        .unsafe_origin_cast[probe_o]()
        + left_key_arr.offset
    )
    var state = _PerfectProbeState[probe_o, perfect_o](
        num_morsels,
        morsel_size,
        num_probe_rows,
        perfect.min_key,
        perfect.range_size,
        probe_nulls^,
        _worker_lists(num_workers, per_worker),
        _worker_lists(num_workers, per_worker),
        probe_key_ptr,
        perfect._entries.unsafe_ptr(),
    )
    _ = dispatcher.run_with_state[
        _PerfectProbeState[probe_o, perfect_o],
        _PerfectProbeTask[probe_o, perfect_o],
    ](
        state,
        _PerfectProbeTask[probe_o, perfect_o](Int32(0)),
        num_workers,
        cancel_token^,
        site_id=SITE_JOIN_PROBE,
    )
    _move_worker_pairs(
        state.worker_build,
        state.worker_probe,
        num_workers,
        build_matches,
        probe_matches,
    )
    _ = probe_key_view
    _ = state^
