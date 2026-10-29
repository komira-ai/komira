# =============================================================================
# join_multi_key_parallel_build -- the parallel build of a
# `MultiKeyHashJoinBuilder` over the engine's dispatcher.
# =============================================================================
#
# Two fanned waves, each over disjoint chunks: (1) the chain-head FILL writes
# `_CHAIN_END` into the table's slots (or the driver's one `memset`, the
# single-key build's fill settings decide); (2) the BUILD folds each chunk's
# composite hashes KEY-OUTER (one key column at a time, with the same
# `_composite_hash_step` the probes use), then pushes every row onto its
# bucket's chain with an atomic compare-exchange (a lock-free Treiber push) and
# inserts its hash into the bloom atomically. A row with a NULL key gets its
# entry (`_CHAIN_END`) and no push. The entry space is row-indexed exactly as
# in the serial build, the same rows reach the same buckets, and only the order
# within a chain differs, so every probe returns the same pairs.
#
# AUTO serves a build of `_MK_BUILD_PARALLEL_THRESHOLD` rows or more; the
# hash join's OFF mode keeps it serial, and its FORCE test hook takes it at
# any size with one-row chunks.
# =============================================================================

from std.atomic import Ordering
from std.io import FileDescriptor
from std.memory import alloc, memset, OwnedPointer, UnsafePointer
from std.sys import num_physical_cores, size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_atomic_alias import AtomicI64
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_async_api.fork_join_shared import fork_join_shared
from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.shared_chunk_work import SharedChunkWork

from komira_async.runtime.sched_trace import (
    FORKTAG_MK_BUILD,
    FORKTAG_MK_HT_FILL,
    SITE_JOIN_HT_FILL,
    SITE_MK_JOIN_BUILD,
    sched_trace_enabled,
    sched_trace_set_fork_note,
)

from .join_multi_key import (
    MAX_JOIN_KEYS,
    MultiKeyColumns,
    _CHAIN_END,
    _COMPOSITE_HASH_SEED,
    _NAN_SENTINEL_BITS,
    _composite_hash_step,
)
from komira_op_join_build.hash_chain_build_settings import (
    JOIN_BUILD_PARALLEL_THRESHOLD,
    JOIN_PARALLEL_BUILD_FORCE,
    JOIN_PARALLEL_BUILD_OFF,
    ht_fill_morsel_slots,
    join_ht_fill_parallel_on,
    join_parallel_build_mode,
)
from komira_op_join_build.hash_chain_parallel_build import (
    _HT_FILL_MIN_BYTES,
    ht_fill_fan_eligible,
)
from .join_multi_key_builder import MultiKeyHashJoinBuilder


comptime _MK_BUILD_PARALLEL_THRESHOLD: Int = JOIN_BUILD_PARALLEL_THRESHOLD
"""Below this many build rows AUTO takes the serial build (the same threshold
as the single-key build's)."""

# fd 2: a query's stdout is its result stream.
comptime _MKB_STDERR: FileDescriptor = FileDescriptor(2)

comptime _MK_CHUNKS_PER_CORE: Int = 4

comptime _MK_MIN_CHUNK_ROWS: Int = 16_384


def mk_chain_build_parallel_eligible(
    num_rows: Int, force_serial: Bool = False
) raises -> Bool:
    """True iff the parallel composite build should serve a build of `num_rows`
    rows: `force_serial` not requested, the build mode not OFF, non-empty, and
    either the mode is FORCE or the row count clears
    `_MK_BUILD_PARALLEL_THRESHOLD`. The mode is the hash join's
    (`join_parallel_build_configure`), so one flag governs both builds.
    """
    if force_serial:
        return False
    if num_rows <= 0:
        return False
    var mode = join_parallel_build_mode()
    if mode == JOIN_PARALLEL_BUILD_OFF:
        return False
    if mode == JOIN_PARALLEL_BUILD_FORCE:
        return True
    return num_rows >= _MK_BUILD_PARALLEL_THRESHOLD


def mk_build_chunk_bounds(n: Int, chunk_rows: Int = 0) raises -> List[Int]:
    """The chunk tiling for a composite build over `n` rows: `n_chunks + 1`
    monotone bounds starting at 0 and ending at `n`. A positive `chunk_rows`
    sets the rows per chunk; 0 takes the default (one row under FORCE,
    otherwise sized to the cores with a floor of `_MK_MIN_CHUNK_ROWS`).
    """
    var bounds = List[Int]()
    bounds.append(0)
    if n <= 0:
        return bounds^
    var rows_per = chunk_rows
    if rows_per > 0:
        pass
    elif join_parallel_build_mode() == JOIN_PARALLEL_BUILD_FORCE:
        rows_per = 1
    else:
        var nw = num_physical_cores()
        if nw < 1:
            nw = 1
        var target = nw * _MK_CHUNKS_PER_CORE
        rows_per = (n + target - 1) // target
        if rows_per < _MK_MIN_CHUNK_ROWS:
            rows_per = _MK_MIN_CHUNK_ROWS
    var lo = 0
    while lo < n:
        var hi = lo + rows_per
        if hi > n:
            hi = n
        bounds.append(hi)
        lo = hi
    return bounds^


def mk_fill_chunk_bounds(cap: Int) raises -> List[Int]:
    """The SLOT tiling for the chain-head fill over a `cap`-slot table:
    `n_chunks + 1` monotone bounds starting at 0 and ending at `cap`.
    """
    var bounds = List[Int]()
    bounds.append(0)
    if cap <= 0:
        return bounds^
    var chunk = ht_fill_morsel_slots()
    var lo = 0
    while lo < cap:
        var hi = lo + chunk
        if hi > cap:
            hi = cap
        bounds.append(hi)
        lo = hi
    return bounds^


struct _MkFillSlots(Movable, Deinitable):
    """Shared payload for the FILL wave: the chain-head table alone."""

    var hash_table: Optional[List[Int]]

    def __init__(out self, var hash_table: List[Int]):
        self.hash_table = Optional[List[Int]](hash_table^)


@fieldwise_init
struct _MkFillWork(SharedChunkWork):
    """Chunk `c` fills chain-head slots `[chunk_lo[c], chunk_lo[c+1])` with
    `_CHAIN_END`.
    """

    var chunk_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver below instantiates `fork_join_shared` with
        # P=_MkFillSlots; the bitcast recovers that concrete type and the
        # pointer never escapes this function. `input` is not read at all.
        var bp = UnsafePointer(to=payload).bitcast[_MkFillSlots]()
        var lo = self.chunk_lo[chunk_id]
        var hi = self.chunk_lo[chunk_id + 1]
        if hi <= lo:
            return
        # SAFETY: `[lo, hi)` is this chunk's disjoint slot range inside the
        # owned, pre-sized table. `_CHAIN_END` is -1 == all-ones, so a 0xFF byte
        # fill materialises it exactly — the identical bytes the driver's single
        # `memset` writes in the gate-OFF arm.
        var ht_ptr = bp[].hash_table.value().unsafe_ptr()
        memset(
            (ht_ptr + lo).bitcast[UInt8](),
            UInt8(0xFF),
            (hi - lo) * size_of[Int](),
        )


struct _MkBuildSlots(Movable, Deinitable):
    """Shared payload: the four index arrays plus the bloom and the inserted
    counter.
    """

    var next_chain: Optional[List[Int]]
    var hash_table: Optional[List[Int]]
    var bloom: Optional[BloomFilter]
    var num_inserted: OwnedPointer[AtomicI64]

    def __init__(
        out self,
        var next_chain: List[Int],
        var hash_table: List[Int],
        var bloom: BloomFilter,
    ):
        self.next_chain = Optional[List[Int]](next_chain^)
        self.hash_table = Optional[List[Int]](hash_table^)
        self.bloom = Optional[BloomFilter](bloom^)
        var raw = alloc[AtomicI64](1)
        # SAFETY: `raw` is a fresh one-element allocation this frame owns; the
        # assignment initialises it and ownership moves to the `OwnedPointer`,
        # which frees it. The chunks only `fetch_add` through the payload.
        raw[] = AtomicI64(Int64(0))
        self.num_inserted = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw
        )


@fieldwise_init
struct _MkBuildWork(SharedChunkWork):
    """Chunk `c` builds rows `[chunk_lo[c], chunk_lo[c+1])` into the shared
    index.
    """

    var chunk_lo: List[Int]
    var n_keys: Int
    var mask: UInt64

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver below instantiates `fork_join_shared` with
        # In=Slab[PrimitiveArray[DType.int64]] and P=_MkBuildSlots; the bitcasts
        # recover those concrete types. Neither pointer escapes this function.
        var sp = UnsafePointer(to=input).bitcast[
            Slab[PrimitiveArray[DType.int64]]
        ]()
        var bp = UnsafePointer(to=payload).bitcast[_MkBuildSlots]()

        var lo = self.chunk_lo[chunk_id]
        var hi = self.chunk_lo[chunk_id + 1]
        var rows = hi - lo
        if rows <= 0:
            return
        var n_keys = self.n_keys
        var mask = self.mask

        var hbuf = List[UInt64]()
        hbuf.resize(rows, _COMPOSITE_HASH_SEED)
        var skip = List[Bool]()
        skip.resize(rows, False)
        for k in range(n_keys):
            ref kcol = sp[][k]
            # SAFETY: `view_ro()` is already offset-adjusted (it spans
            # `self.length` elements starting at `self.offset`), which is
            # exactly what `MultiKeyHashJoinBuilder.build` and every probe
            # variant read — reading a DIFFERENT window here than the probe
            # reads is precisely how a build silently mismatches. The view local
            # holds the borrow across the loop; the pointer never escapes.
            var kview = kcol.view_ro()
            var kptr = kview._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            for j in range(rows):
                # SAFETY: `lo + j < hi <= n`, and every key column has `n`
                # rows (the driver refuses ragged columns before dispatch).
                var v = Int64((kptr + lo + j)[])
                if v == _NAN_SENTINEL_BITS:
                    skip[j] = True
                hbuf[j] = _composite_hash_step(hbuf[j], v)
            _ = kview
            _ = kcol

        # ---- Pass B: chain insert + bloom ----
        # SAFETY: `hash_table` is the builder's own `List[Int]`; `Int` and
        # `Int64` are layout-identical on every supported target, so the bitcast
        # is a pure reinterpretation that lets the aligned 64-bit chain-head slot
        # bind `Atomic[DType.int64].compare_exchange` directly. Same shape as the
        # single-key `hash_chain_parallel_build`. Origin is the borrowed
        # payload's; the pointers never leave this method.
        var ht_ptr = bp[].hash_table.value().unsafe_ptr().bitcast[
            Scalar[DType.int64]
        ]()
        var nc_ptr = bp[].next_chain.value().unsafe_ptr()

        var inserted = 0
        for j in range(rows):
            var r = lo + j
            if skip[j]:
                # SAFETY: `r` is in this chunk's own `[lo, hi)` of `next_chain`.
                (nc_ptr + r)[] = _CHAIN_END
                continue
            var h = hbuf[j]
            var slot = Int(h & mask)
            # Lock-free Treiber push. SAFETY: `ht_ptr + slot` is a slot of the
            # payload's pre-sized table (`slot <= mask < cap`), aligned for a
            # 64-bit atomic and owned across the barrier. The head is read with
            # a relaxed atomic load because it races with the other chunks'
            # compare-exchange; the compare-exchange validates staleness (a
            # stale `old` simply retries). `nc_ptr + r` is a slot of the
            # `n`-entry `next_chain` that only this chunk writes (`r` is in its
            # `[lo, hi)`), and no reader walks a chain during the build.
            while True:
                var old = AtomicI64.load[ordering=Ordering.RELAXED](
                    ht_ptr + slot
                )
                (nc_ptr + r)[] = Int(old)
                if AtomicI64.compare_exchange(ht_ptr + slot, old, Int64(r)):
                    break
            bp[].bloom.value().insert_hash_atomic(h)
            inserted += 1

        _ = bp[].num_inserted[].fetch_add(Int64(inserted))
        _ = hbuf^
        _ = skip^


def _run_mk_build_wave[
    in_o: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    ref [in_o] int_keys: Slab[PrimitiveArray[DType.int64]],
    var work: _MkBuildWork,
    var slots: _MkBuildSlots,
    n_chunks: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> _MkBuildSlots:
    """Thin `fork_join_shared` binding whose only job is to let `in_o` be
    INFERRED from the borrowed key Slab (the caller holds it inside an
    `Optional`, so its origin cannot be spelled at the construction site). Same
    idiom as `join_key_extract.hash_string_keys`.
    """
    return fork_join_shared[
        _MkBuildWork,
        Slab[PrimitiveArray[DType.int64]],
        _MkBuildSlots,
        in_o,
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        int_keys,
        slots^,
        n_chunks,
        2,
        0,
        dispatcher_ptr,
        cancel_token^,
        SITE_MK_JOIN_BUILD,
    )


def _run_mk_fill_wave[
    in_o: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    ref [in_o] int_keys: Slab[PrimitiveArray[DType.int64]],
    var work: _MkFillWork,
    var slots: _MkFillSlots,
    n_chunks: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> _MkFillSlots:
    """Thin `fork_join_shared` binding for the FILL wave. Same idiom (and same
    reason) as `_run_mk_build_wave` above: `in_o` must be INFERRED from the
    borrowed key Slab, whose origin the construction site cannot spell.
    """
    return fork_join_shared[
        _MkFillWork,
        Slab[PrimitiveArray[DType.int64]],
        _MkFillSlots,
        in_o,
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        int_keys,
        slots^,
        n_chunks,
        2,
        0,
        dispatcher_ptr,
        cancel_token^,
        SITE_JOIN_HT_FILL,
    )


def multi_key_hash_join_build_parallel[
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var keys: MultiKeyColumns,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
    force_serial: Bool = False,
    chunk_rows: Int = 0,
) raises -> MultiKeyHashJoinBuilder:
    """Composite-key hash-join build, parallel above the gate and serial below
    it — so this entry is ALWAYS safe to call in place of
    `MultiKeyHashJoinBuilder.build(keys^)`.

    Args:
        keys: The N build-side key columns; moved into the returned builder.
        dispatcher_ptr: The caller's pool, borrowed for the fork-join window.
        cancel_token: Consumed. A token cancelled before or during a pooled
            wave makes the build raise and return no table (the half-built
            index is dropped with the wave's payload).
        force_serial: Take the serial build unconditionally: the differential
            tests' reference arm (the process-wide OFF mode is the rollback).
        chunk_rows: Rows per chunk; 0 takes the default tiling
            (`mk_build_chunk_bounds`).
    """
    var n_keys = keys.num_keys
    if n_keys < 1 or n_keys > MAX_JOIN_KEYS:
        _ = cancel_token^
        return MultiKeyHashJoinBuilder.build(keys^)

    var n = keys.int_keys.value()[0].length
    var ragged = False
    for k in range(1, n_keys):
        if keys.int_keys.value()[k].length != n:
            ragged = True
            break
    if ragged:
        _ = cancel_token^
        return MultiKeyHashJoinBuilder.build(keys^)

    if not mk_chain_build_parallel_eligible(n, force_serial):
        _ = cancel_token^
        return MultiKeyHashJoinBuilder.build(keys^)

    var bounds = mk_build_chunk_bounds(n, chunk_rows)
    var n_chunks = len(bounds) - 1
    if n_chunks < 1:
        _ = cancel_token^
        return MultiKeyHashJoinBuilder.build(keys^)

    var min_cap = max(Int(Float64(n) * 1.4) + 1, 16)
    var cap = 1
    while cap < min_cap:
        cap *= 2
    var mask = UInt64(cap - 1)

    var pool_n = 1
    comptime if has_pool:
        if dispatcher_ptr:
            pool_n = dispatcher_ptr.value()[].worker_count()
            if pool_n < 1:
                pool_n = 1
    var forced = join_parallel_build_mode() == JOIN_PARALLEL_BUILD_FORCE
    var fan_fill = ht_fill_fan_eligible(cap, pool_n, forced)
    var fill_bounds = List[Int]()
    var n_fill_chunks = 0
    if fan_fill:
        fill_bounds = mk_fill_chunk_bounds(cap)
        n_fill_chunks = len(fill_bounds) - 1
        if n_fill_chunks < 2:
            fan_fill = False
            n_fill_chunks = 0

    var ht = List[Int]()
    ht.resize(unsafe_uninit_length=cap)
    if not fan_fill:
        # SAFETY: `cap` Int slots owned by this frame; the pointer does not
        # escape.
        memset(
            ht.unsafe_ptr().bitcast[UInt8](), UInt8(0xFF), cap * size_of[Int]()
        )

    var _fk_on = sched_trace_enabled()
    if _fk_on:
        print(
            "[JOIN_HT_FILL] kernel=multikey arm=",
            "fanned" if fan_fill else "serial",
            " gate=", Int(join_ht_fill_parallel_on()),
            " rows=", n,
            " cap=", cap,
            " fill_bytes=", cap * size_of[Int](),
            " min_bytes=", _HT_FILL_MIN_BYTES,
            " grain=", ht_fill_morsel_slots(),
            " chunks=", n_fill_chunks,
            " pool=", pool_n,
            " forced=", Int(forced),
            file=_MKB_STDERR,
        )

    if fan_fill:
        var fill_work = _MkFillWork(fill_bounds.copy())
        var fill_slots = _MkFillSlots(ht^)
        if _fk_on:
            sched_trace_set_fork_note(
                FORKTAG_MK_HT_FILL, SITE_JOIN_HT_FILL,
                UInt64(n_fill_chunks), UInt64(n),
            )
        var filled = _run_mk_fill_wave[
            has_pool=has_pool, D=D, disp_o=disp_o
        ](
            keys.int_keys.value(), fill_work^, fill_slots^, n_fill_chunks,
            dispatcher_ptr, cancel_token.clone(),
        )
        ht = filled.hash_table.take()
        _ = filled^

    var next_chain = List[Int]()
    next_chain.resize(unsafe_uninit_length=n)

    var bloom = BloomFilter.with_ndv_fpp(max(n, 1), 0.01)

    var work = _MkBuildWork(bounds^, n_keys, mask)
    var slots = _MkBuildSlots(next_chain^, ht^, bloom^)
    if _fk_on:
        sched_trace_set_fork_note(
            FORKTAG_MK_BUILD, SITE_MK_JOIN_BUILD, UInt64(n_chunks), UInt64(n),
        )
    var done = _run_mk_build_wave[
        has_pool=has_pool, D=D, disp_o=disp_o
    ](
        keys.int_keys.value(), work^, slots^, n_chunks, dispatcher_ptr,
        cancel_token^,
    )

    var out_nc = done.next_chain.take()
    var out_ht = done.hash_table.take()
    var out_bloom = done.bloom.take()
    var num_inserted = Int(done.num_inserted[].load())
    _ = done^

    if len(out_nc) != n:
        raise Error(
            "multi_key_hash_join_build_parallel: entry space is not row-indexed"
            " (next_chain="
            + String(len(out_nc))
            + ", build rows="
            + String(n)
            + ") — RIGHT/FULL would silently drop preserved-side rows"
        )

    return MultiKeyHashJoinBuilder(
        keys_bundle=keys^,
        hash_table=out_ht^,
        next_chain=out_nc^,
        capacity=cap,
        bloom=out_bloom^,
        num_inserted=num_inserted,
    )
