# =============================================================================
# The grouped COUNT(DISTINCT) driver's STRING-key encode
# =============================================================================
#
# `_encode_string_key_parallel` turns one STRING / LARGE_STRING group-key
# column into dict ids: `encoded[row]` is the id of the row's value, and ids
# are numbered in FIRST-SEEN row order (the driver's output group order, so
# every arm below must number identically). It also fills the reverse map
# (`rev_starts`, `rev_lens`, and for an arena `rev_bytes`) that the key emit
# (`agg_cd_key_emit`) reads.
#
#   Phase A (parallel): K workers hash a row-range slice each, FNV-1a 64 over
#     the value bytes plus a length mix (`_strenc_fnv_row`), into
#     `hashes[N]` (disjoint write regions per worker).
#
#   Phase B: assign dict ids over the hashes, verifying every hash hit
#     against the bytes. Three bodies, tried in order:
#     1. per row range (`agg_cd_strenc_rowdict`): one small dictionary per
#        range, merged in row order; serves a key with few distinct values
#        and declines, writing nothing, for any other;
#     2. hash-sharded (`agg_cd_strenc_parb`), for at least
#        `_PHASEB_MIN_ROWS` rows: one dictionary per hash shard, merged with
#        the first-seen numbering preserved;
#     3. serial (`_assign_dict_ids_from_hashes`, here): one open-addressed
#        (hash -> dict id) table walked in row order.
#
# The return value says whether the reverse map is SOURCE-backed: True when
# arm 1 or 2 ran (`rev_starts` index the caller's own value buffer and
# `rev_bytes` stays empty), False when the serial arm ran (an arena in
# `rev_bytes`). `_hash_string_rows_parallel` (Phase A alone) is public to the
# package because the fused string-key route hashes with it too.
#
# The offsets width is a comptime parameter (`OffsetType`): Int32 for STRING,
# Int64 for LARGE_STRING, chosen by the caller from the column's type.
#
# Safety
# ------
# * The entry points are package-private (`_`-named); `data_ptr` /
#   `offs_ptr` carry the batch's concrete origin and live across the
#   dispatch's fork-join barrier.
# * State fields are OwnedPointer-wrapped Slabs / Lists; no wildcard origin.
# * The Segment carries no captures; the State is borrowed through
#   `dispatcher.run_with_state`'s fork-join barrier.
# * Outputs are `mut` buffers filled in place (a struct of four Lists could
#   not be field-moved out at the call site).
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_STRENC
from komira_counters.keyeq_census import keyeq_record, KEYEQ_AGGCD_STRENC
from komira_atomic_alias import AtomicI8
from std.builtin.swap import swap
from std.math import min
from std.memory import alloc, OwnedPointer, UnsafePointer, unsafe_memcpy

from komira_collections.slab import Slab

from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_agg_distinct.agg_cd_strenc_parb import (
    _assign_dict_ids_parallel,
    _phaseb_shard_count,
    _strenc_ht_initial_cap,
    _strenc_ht_limit,
)
from komira_op_agg_distinct.agg_cd_strenc_rowdict import (
    _assign_dict_ids_rowdict,
    _strenc_fnv_row,
)


# =============================================================================
# Tuning constants
# =============================================================================
#
# Minimum rows-per-worker that justifies the dispatch overhead for the
# encode pass. At < ~32K rows the serial path is faster (FNV-1a is
# extremely cheap per byte; dispatch + slab init costs > saved compute).
comptime _PARALLEL_STRENC_MIN_ROWS_PER_WORKER: Int = 32_768

# Below this row count, serial is faster.
comptime _PARALLEL_STRENC_MIN_ROWS: Int = 65_536

# Cap K to bound per-worker fixed overhead.
comptime _PARALLEL_STRENC_MAX_K: Int = 32


# =============================================================================
# Hash-only Phase A state + segment
# =============================================================================


struct _ParallelStrEncState[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](KeepAlive):
    """Per-dispatch state for parallel STRING-key FNV-1a hash precompute.

    Heap-stable fields (workers borrow via `state.field[]`):
      * `hashes`: `OwnedPointer[List[Int64]]`. Pre-sized to num_rows.
        Worker `wid` writes to slice [row_starts[wid], row_starts[wid+1])
        — disjoint write regions across workers.
      * `row_starts`: List[Int] of length num_workers+1.
      * `err_flag` / `err_msg`: error short-circuit.

    Borrowed batch-origin pointers (live across the fork-join barrier):
      * `data_ptr`: byte payload of the STRING column.
      * `offs_ptr`: offsets into `data_ptr`, at the COLUMN's own width —
        `Int32` for STRING, `Int64` for LARGE_STRING (`OffsetType`).

    Disjointness: worker `wid` writes only to `hashes[row_starts[wid]..
    row_starts[wid+1])`. No cross-worker aliasing.

    Liveness: the State lives on the driver stack across
    `run_with_state`. The substrate's fork-join barrier waits for every
    worker before returning.

    No-realloc: `hashes` is pre-sized at construction; never grows.
    """

    var hashes: OwnedPointer[List[Int64]]
    var row_starts: OwnedPointer[List[Int]]

    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    var data_ptr: UnsafePointer[UInt8, Self.data_origin]
    var offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.offs_origin]

    var num_rows: Int

    def __init__(
        out self,
        var hashes: List[Int64],
        var row_starts: List[Int],
        data_ptr: UnsafePointer[UInt8, Self.data_origin],
        offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.offs_origin],
        num_rows: Int,
    ):
        var hraw = alloc[List[Int64]](1)
        hraw.unsafe_write(hashes^)
        self.hashes = OwnedPointer[List[Int64]](unsafe_from_raw_pointer=hraw)

        var rsraw = alloc[List[Int]](1)
        rsraw.unsafe_write(row_starts^)
        self.row_starts = OwnedPointer[List[Int]](
            unsafe_from_raw_pointer=rsraw
        )

        var fraw = alloc[AtomicI8](1)
        fraw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(
            Scalar[DType.int8](0)
        )
        self.err_flag = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=fraw
        )

        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)

        self.data_ptr = data_ptr
        self.offs_ptr = offs_ptr
        self.num_rows = num_rows


@fieldwise_init
struct _ParallelStrEncTask[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](Segment):
    """POD Segment for `_ParallelStrEncState[d, o]` dispatch.

    Each invocation hashes its row-range slice into `state.hashes`. The
    bitcast on `state` recovers the concrete State type at the dispatch
    boundary.
    """
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: worker `wid` writes only to
        #     `hashes[row_starts[wid]..row_starts[wid+1])`. The
        #     row_starts contract makes the writes disjoint.
        #   * Liveness: State lives on the driver stack across the
        #     fork-join barrier. data_ptr / offs_ptr are batch-rooted.
        #   * No-realloc: `hashes` pre-sized to num_rows; never grows
        #     during dispatch.
        var sp = UnsafePointer(to=state).bitcast[
            _ParallelStrEncState[
                Self.OffsetType, Self.data_origin, Self.offs_origin
            ]
        ]()

        var wid = Int(task_id)
        try:
            if sp[].err_flag[].load() != Int8(0):
                return

            var row_lo = sp[].row_starts[][wid]
            var row_hi = sp[].row_starts[][wid + 1]
            if row_lo >= row_hi:
                return

            ref hashes_list = sp[].hashes[]
            var hashes_ptr = UnsafePointer(to=hashes_list[0])

            var data_ptr = sp[].data_ptr
            var offs_ptr = sp[].offs_ptr

            # FNV-1a 64 + length-mix (matches the serial path's pre-pass).
            for row in range(row_lo, row_hi):
                (hashes_ptr + row).unsafe_write(
                    _strenc_fnv_row(data_ptr, offs_ptr, row)
                )
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
            return


# =============================================================================
# Routing helper
# =============================================================================


def _should_use_parallel_strenc(num_rows: Int, worker_count: Int) -> Bool:
    """Return True iff the parallel STRING-key encode should be used.

    Conditions:
      * Workers > 1.
      * num_rows >= _PARALLEL_STRENC_MIN_ROWS.

    Below the min-rows threshold, dispatch overhead exceeds the parallel
    savings; the caller must fall back to the serial encode.
    """
    if worker_count <= 1:
        return False
    if num_rows < _PARALLEL_STRENC_MIN_ROWS:
        return False
    return True


# =============================================================================
# Phase B — the shared dict-id assignment (ONE body, two callers)
# =============================================================================


def _assign_dict_ids_from_hashes[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](
    imm hashes: List[Int64],
    data_ptr: UnsafePointer[UInt8, data_origin],
    offs_ptr: UnsafePointer[Scalar[OffsetType], offs_origin],
    num_rows: Int,
    census_site: Int,
    mut out_encoded: List[Int],
    mut out_rev_bytes: List[UInt8],
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
) raises:
    """Phase B — assign a dict id per row from PRE-COMPUTED per-row hashes.

    ONE body, two callers: `_encode_string_key_parallel` (hashes from the
    parallel Phase A) and `agg_count_distinct_parallel`'s serial fallback
    (hashes from its own serial pre-pass). It used to be two hand-copied
    implementations of the same algorithm in two files — the shape that
    guarantees the copies drift.

    `census_site` is the `keyeq_census` site id of the CALLER, so the
    verify-on-hit census still attributes to the arm that ran.

    Fills, for dict id `d`: `out_rev_bytes[out_rev_starts[d] :
    +out_rev_lens[d]]` is `d`'s bytes; `out_encoded[r]` is row `r`'s id.
    """
    # ------------------------------------------------------------------
    # Phase B (serial): build dict-id assignment from precomputed hashes.
    #
    # ⭐ CDPHT (2026-09-20, cbq13): an OPEN-ADDRESSED (hash -> dict_idx) table
    # with linear probing, replacing the `Dict[Int64, Int64]` +
    # `Dict[String, Int64]` collision pair. Three reasons it is the right
    # container here and the `Dict` never was:
    #
    #   * The incumbent did TWO lookups on every hit (`h in hash_dict` then
    #     `hash_dict[h]`) and THREE on every miss. cbq13 is 13,172,392 rows
    #     into 6,019,102 distinct values, i.e. a ~46% miss rate — nearly every
    #     row paid the expensive arm.
    #   * The `Dict[String, Int64]` collision fallback needed a materialized
    #     `String` to key on. Linear probing subsumes it for free: a slot whose
    #     hash matches but whose BYTES do not is simply not this value's slot,
    #     so probing continues. Two distinct values sharing a 64-bit FNV-1a
    #     hash each get their own slot, found through the same chain.
    #   * The verify-on-hit compare now reads the ARENA (compact, hot) instead
    #     of chasing the row's original position in a multi-hundred-MB input
    #     data buffer.
    #
    # NUMBERING IS UNCHANGED — an id is minted exactly when a byte value is
    # first seen, so `out_encoded` is bit-identical to the incumbent's.
    # ------------------------------------------------------------------
    # Pre-grow the encoded out-buffer to num_rows. The caller must pass
    # an empty List; we own the size from here, and every slot is written
    # by the loop below before it is read.
    out_encoded.resize(unsafe_uninit_length=num_rows)

    var ht_cap = _strenc_ht_initial_cap(num_rows)
    var ht_mask = ht_cap - 1
    var ht_hash = List[Int64](length=ht_cap, fill=Int64(0))
    var ht_idx = List[Int32](length=ht_cap, fill=Int32(-1))
    var ht_live = 0
    var ht_limit = _strenc_ht_limit(ht_cap)
    var _n_rehash = 0
    var _n_miss = 0

    # Arena capacity is grown GEOMETRICALLY by this loop rather than left to
    # `resize`'s policy: a `resize` that sizes capacity exactly to the new
    # length would make the arena quadratic in the number of distinct values.
    var arena_cap = 0

    
    for row in range(num_rows):
        var h = hashes[row]
        var start = Int((offs_ptr + row)[])
        var end = Int((offs_ptr + row + 1)[])
        var str_len = end - start
        var slot = Int(h) & ht_mask
        while True:
            var gid = ht_idx[slot]
            if gid < Int32(0):
                # MISS — mint the next dict id and copy the bytes into the
                # arena ONCE. This is where a `String` used to be allocated.
                var new_idx = len(out_rev_starts)
                var abase = len(out_rev_bytes)
                if str_len > 0:
                    var need = abase + str_len
                    if need > arena_cap:
                        var nc = arena_cap * 2
                        if nc < need:
                            nc = need
                        out_rev_bytes.reserve(nc)
                        arena_cap = nc
                    out_rev_bytes.resize(unsafe_uninit_length=need)
                    # SAFETY: `out_rev_bytes` was just grown to `need`, so
                    # `[abase, need)` is in bounds and owned by this List; the
                    # pointer is taken AFTER the resize (so after any realloc)
                    # and dies at the end of this statement. `data_ptr` is
                    # batch-rooted and `[start, start+str_len)` is the row's
                    # own span, read-only. The two regions cannot alias: the
                    # arena is a fresh List allocation.
                    unsafe_memcpy(
                        dest=UnsafePointer(to=out_rev_bytes[abase]),
                        src=data_ptr + start,
                        count=str_len,
                    )
                out_rev_starts.append(abase)
                out_rev_lens.append(str_len)
                ht_hash[slot] = h
                ht_idx[slot] = Int32(new_idx)
                ht_live += 1
                _n_miss += 1
                out_encoded[row] = new_idx
                if ht_live > ht_limit:
                    # Rehash into a table twice the size. Linear probing has
                    # no tombstones (nothing is ever deleted), so a straight
                    # re-insert of every live slot rebuilds every probe chain.
                    var new_cap = ht_cap * 2
                    var new_mask = new_cap - 1
                    var nh = List[Int64](length=new_cap, fill=Int64(0))
                    var ni = List[Int32](length=new_cap, fill=Int32(-1))
                    for sx in range(ht_cap):
                        var g2 = ht_idx[sx]
                        if g2 < Int32(0):
                            continue
                        var h2 = ht_hash[sx]
                        var ns = Int(h2) & new_mask
                        while ni[ns] >= Int32(0):
                            ns = (ns + 1) & new_mask
                        nh[ns] = h2
                        ni[ns] = g2
                    ht_hash = nh^
                    ht_idx = ni^
                    ht_cap = new_cap
                    ht_mask = new_mask
                    ht_limit = _strenc_ht_limit(ht_cap)
                    _n_rehash += 1
                break
            if ht_hash[slot] == h:
                var cand_idx = Int(gid)
                # Verify-on-hit against the ARENA copy of the candidate.
                var ok = (out_rev_lens[cand_idx] == str_len)
                if ok and str_len > 0:
                    var cs = out_rev_starts[cand_idx]
                    var i = 0
                    while i < str_len:
                        if (data_ptr + start + i)[] != out_rev_bytes[cs + i]:
                            ok = False
                            break
                        i += 1
                    keyeq_record(census_site, str_len, i, ok)
                if ok:
                    out_encoded[row] = cand_idx
                    break
                # Same 64-bit hash, DIFFERENT bytes: not this value's slot.
                # Keep probing — the other value is either further along this
                # chain or absent, in which case the chain's empty slot mints
                # it. (The incumbent needed a second `Dict[String, Int64]` to
                # express this.)
            slot = (slot + 1) & ht_mask

# =============================================================================
# Phase A alone — the parallel row hash
# =============================================================================


def _strenc_task_count(num_rows: Int, max_workers: Int) -> Int:
    """K for Phase A (and the Phase-B remap/merge): the workers, capped by
    `_PARALLEL_STRENC_MIN_ROWS_PER_WORKER` rows each and `_PARALLEL_STRENC_MAX_K`,
    at least 1."""
    var by_min_rows = num_rows // _PARALLEL_STRENC_MIN_ROWS_PER_WORKER
    if by_min_rows < 1:
        by_min_rows = 1
    var k = min(max_workers, by_min_rows)
    k = min(k, _PARALLEL_STRENC_MAX_K)
    if k < 1:
        k = 1
    return k


def _hash_string_rows_parallel[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    data_ptr: UnsafePointer[UInt8, data_origin],
    offs_ptr: UnsafePointer[Scalar[OffsetType], offs_origin],
    num_rows: Int,
) raises -> List[Int64]:
    """Phase A: every row's `_strenc_fnv_row`, computed on K row ranges.

    Returns the `num_rows`-long hash vector (moved out of the dispatch State).
    Shared by `_encode_string_key_parallel` and the fused route, so both hash
    a key the same way.
    """
    var k = _strenc_task_count(num_rows, dispatcher.worker_count())

    # Pre-size hashes list to num_rows in ONE allocation + fill. (This used
    # to be a `capacity=` construction followed by `num_rows` `append`s —
    # 13.17M of them on cbq13, each re-checking capacity.)
    var hashes = List[Int64](length=num_rows, fill=Int64(0))

    # Row-range partition.
    var row_starts = List[Int](capacity=k + 1)
    row_starts.append(0)
    for w in range(1, k):
        row_starts.append((num_rows * w) // k)
    row_starts.append(num_rows)

    # Build State + dispatch.
    var state = _ParallelStrEncState[OffsetType, data_origin, offs_origin](
        hashes^,
        row_starts^,
        data_ptr,
        offs_ptr,
        num_rows,
    )
    var task = _ParallelStrEncTask[OffsetType, data_origin, offs_origin](
        Int32(0)
    )

    var task_back = dispatcher.run_with_state[
        _ParallelStrEncState[OffsetType, data_origin, offs_origin],
        _ParallelStrEncTask[OffsetType, data_origin, offs_origin],
    ](state, task^, k, cancel_token^, site_id=SITE_CD_STRENC)
    _ = task_back^

    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    var out = List[Int64]()
    swap(state.hashes[], out)
    _ = state^
    return out^


# =============================================================================
# Public entry point — Phase A (parallel hash) + Phase B
# =============================================================================


def _encode_string_key_parallel[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    data_ptr: UnsafePointer[UInt8, data_origin],
    offs_ptr: UnsafePointer[Scalar[OffsetType], offs_origin],
    num_rows: Int,
    mut out_encoded: List[Int],
    mut out_rev_bytes: List[UInt8],
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
) raises -> Bool:
    """Parallel STRING-key dictionary encode.

    Fills `encoded[i]` = dict id of row i, and a SPAN reverse map:
    `rev_starts[d]` / `rev_lens[d]` is dict id `d`'s span inside a byte buffer
    — and WHICH buffer is what the return value says:

      * **True** — CDP-ROWDICT or the SHARDED Phase B ran
        (`agg_cd_strenc_rowdict` / `agg_cd_strenc_parb`). ⭐ L3: there
        is NO arena; the spans index the buffer `data_ptr` addresses (the
        column's own value buffer) and `out_rev_bytes` is left EMPTY. The
        caller must read the key bytes there, while that buffer is alive.
      * **False** — the SERIAL Phase B ran: `out_rev_bytes` is ONE byte arena
        holding every distinct value back to back and the spans index it.

    ⭐ CDPSPAN (2026-09-20, cbq13). The reverse map used to be a
    `List[String]`, one OWNING `String` per distinct value — on
    `count(DISTINCT user_id) GROUP BY search_phrase` 6,019,102 of them, i.e.
    6.02M `malloc`s here, 6.02M copy-constructions at emit and 12M `free`s at
    teardown, for a value whose (offset, length) this very loop computes.
    (Mojo 1.0.0 `String` has NO small-string optimization.)

    The dict-id NUMBERING is the same in both arms: an id is minted exactly
    when a byte value is seen for the first time, so ids are in
    first-occurrence order and the encoded column is bit-identical to the
    `List[String]` form's.

    Algorithm:
      0. CDP-ROWDICT (`_assign_dict_ids_rowdict`): Phase A and Phase B fused
         on row ranges, for a key with few distinct values. Returns True
         (SOURCE spans) when it serves; otherwise:
      1. Phase A (parallel): `_hash_string_rows_parallel`.
      2. Phase B: sharded (`_assign_dict_ids_parallel`) when
         `_phaseb_shard_count` says so, else serial
         (`_assign_dict_ids_from_hashes`, open-addressed, verify-on-hit
         against the arena).
    """
    var max_workers = dispatcher.worker_count()
    # Remap width, and the MERGE's task cap since L2: Phase A's own K, as the
    # remap width was before. Since CDP-ROWDICT also its row-range count.
    var k = _strenc_task_count(num_rows, max_workers)

    # ⭐ CDP-ROWDICT (2026-09-25, cbq10/cbq11): one small dictionary per ROW
    # RANGE, merged in row order — TRIED FIRST. It hashes as it goes (no
    # Phase-A vector), and no value has an owner, so a heavy value cannot pin a
    # shard: on cbq10 one of CDPPARB's 16 shards probed ~5.1M of 5.56M rows.
    # It DECLINES (False, outputs untouched) once any range meets more than
    # `_ROWDICT_MAX_LOCAL` values, and the two arms below then run unchanged.
    # Same numbering as both (see `agg_cd_strenc_rowdict.mojo`); its reverse
    # map is L3's SOURCE spans, hence `return True`.
    if k > 1:
        if _assign_dict_ids_rowdict[OffsetType](
            dispatcher,
            data_ptr,
            offs_ptr,
            num_rows,
            KEYEQ_AGGCD_STRENC,
            k,
            out_encoded,
            out_rev_starts,
            out_rev_lens,
        ):
            return True

    var hashes = _hash_string_rows_parallel[OffsetType](
        dispatcher, cancel_token^, data_ptr, offs_ptr, num_rows
    )

    # ⭐ CDPPARB: Phase B in parallel when the shape earns it. The serial body
    # stays REACHABLE and is not a fallback of last resort — it is what runs
    # for one worker and for a small input, and it is the byte-equivalence
    # ORACLE the parallel form is pinned against.
    var p_shards = _phaseb_shard_count(num_rows, max_workers)
    if p_shards > 1:
        _assign_dict_ids_parallel[OffsetType](
            dispatcher,
            hashes,
            out_encoded,
            data_ptr,
            offs_ptr,
            num_rows,
            KEYEQ_AGGCD_STRENC,
            p_shards,
            k,
            out_rev_starts,
            out_rev_lens,
        )
        _ = hashes^
        return True
    _assign_dict_ids_from_hashes[OffsetType](
        hashes,
        data_ptr,
        offs_ptr,
        num_rows,
        KEYEQ_AGGCD_STRENC,
        out_encoded,
        out_rev_bytes,
        out_rev_starts,
        out_rev_lens,
    )
    _ = hashes^
    return False
