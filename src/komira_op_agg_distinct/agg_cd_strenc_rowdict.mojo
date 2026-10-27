# =============================================================================
# CDP-ROWDICT — THE STRING-KEY ENCODE ON ROW RANGES: ONE SMALL DICTIONARY
#   PER RANGE, MERGED IN ROW ORDER
# =============================================================================
#
# Companion to `agg_count_distinct_strenc.mojo` (the entry point, Phase A and
# the serial Phase B) and `agg_cd_strenc_parb.mojo` (the hash-SHARDED Phase B).
# `_encode_string_key_parallel` tries THIS arm first; it hands back (declines)
# as soon as the key turns out to have too many distinct values for it, and the
# hash-sharded arm then runs exactly as before.
#
# THE DEFECT. CDPPARB shards Phase B by the key HASH, so every row of one
# value is one shard's work. When ONE value holds ~92% of the rows, ONE of the
# P = 16 shards probes nearly every row while the other 15 finish their small
# share and idle. It is exactly the skew CDP-HEAVYSPLIT removed from
# the driver's AGG pass (`agg_cd_heavy_split.mojo`), one phase earlier.
#
# WHY NOT A HEAVY-VALUE SPLIT OF THE HASH SHARDS. It would work — a heavy
# value's rows spread by row range, its first row taken as the minimum — but it
# keeps the K x N floor this driver already paid once (every shard reads every
# row's hash to find its own), needs the Phase-A hash vector (a serial
# zero-fill and a parallel write of one word per row), and a sample to find the
# heavy values. For a key with FEW distinct values none of that is needed: a table of
# 165 values is L1-resident, so each worker can simply build its OWN dictionary
# over its OWN rows. Skew cannot pin anything, because no value has an owner.
#
# HOW, in one paragraph. Task t owns the contiguous row range
# [row_starts[t], row_starts[t+1]). It hashes each row itself (the same
# `_strenc_fnv_row` Phase A uses), probes a small private open-addressed table,
# and writes a LOCAL id into `encoded[row]`, minting ids in row order. The
# driver then walks the tasks IN ORDER, and each task's local ids in mint
# order, through one global table, numbering every value the first time it is
# met. A parallel remap rewrites local ids to global ones.
#
# WHY IT IS THE SAME NUMBERING as the serial Phase B, not merely the same set:
# the serial pass mints id g at the g-th distinct value in ROW order. The merge
# visits candidates in (task, mint) order, which is ascending FIRST-ROW order
# within each task, and every row of task t lies below every row of task t+1.
# So when the merge first meets value v (in the first task that holds it, at v's
# global first row), every value whose first row is lower has already been met,
# and no value met earlier has a higher first row. Minting on first meeting is
# therefore minting in global first-row order. The reverse map is L3's: dict id
# g's span is its MINTING row's span in the SOURCE buffer (the first task that
# holds g minted it at g's first row), so it is byte-identical in VALUE to the
# serial arena and to CDPPARB's.
#
# THE DECLINE. A task that would mint more than `max_local` values raises a
# shared flag; every task polls it every `_ROWDICT_POLL_ROWS` rows and stops, and
# the entry point returns False with its outputs untouched. The bound exists for
# the SERIAL merge, whose work is the SUM of the task dictionaries (at most
# T x max_local probes). A high-cardinality key (the high-cardinality query's `search_phrase`, 6.0M
# values) trips it within its first ~`max_local` rows per task, so declining
# wastes well under a millisecond there; the worst case is a key just above the
# bound, which wastes at most one pass of this arm.
#
# Route witness: `cd_strenc_rowdict_served_count` / `_decline_count` — a value
# oracle cannot see this arm (all three Phase B arms answer identically), only
# the route can.
#
# Safety
# ------
# * `data_ptr` / `offs_ptr` are concrete-origin pointers into the caller's
#   batch buffers, which outlive every dispatch here. They are stored in the
#   State and read by the tasks and the driver-side merge through its fields.
# * State fields are OwnedPointer-wrapped; no wildcard-origin fields.
# * Every `run_with_state` site carries the PARALLELIZE-BOUNDARY block.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_STRENC
from komira_atomic_alias import AtomicI8, AtomicI64
from std.ffi import _Global
from std.builtin.swap import swap
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_agg_distinct.agg_cd_strenc_parb import (
    _PARB_VCACHE_BYTES,
    _parb_vcache_admit,
    _parb_verify,
)


# Most values one task may mint before the arm declines. The serial merge
# probes at most T x this many entries (~164K at T = 20, a few ms); the skewed-key query /
# the second skewed-key query mint 165 per task.
comptime _ROWDICT_MAX_LOCAL: Int = 8_192

# A task's first table size (slots). Grown by doubling at half load, so a
# 165-value key never leaves it and a declining key never exceeds
# 2 x `_ROWDICT_MAX_LOCAL` slots.
comptime _ROWDICT_INIT_CAP: Int = 1_024

# Rows between two polls of the shared decline flag.
comptime _ROWDICT_POLL_ROWS: Int = 4_096

comptime _ROWDICT_MODE_DICT: Int32 = 0
comptime _ROWDICT_MODE_REMAP: Int32 = 1


# =============================================================================
# The row hash — ONE spelling, every caller
# =============================================================================


@always_inline
def _strenc_fnv_row[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](
    data_ptr: UnsafePointer[UInt8, data_origin],
    offs_ptr: UnsafePointer[Scalar[OffsetType], offs_origin],
    row: Int,
) -> Int64:
    """FNV-1a 64 over row `row`'s bytes, then a length-mix to disambiguate
    prefix-shared values. Phase A's hash, the fused route's heavy-key sample
    and this arm's per-task tables all read THIS function, so no two of them
    can disagree about a key. (It lived in `agg_count_distinct_strenc.mojo`
    until CDP-ROWDICT, which needs it without importing that module back.)"""
    comptime FNV_BASIS = Int64(-3750763034362895579)
    comptime FNV_PRIME = Int64(1099511628211)
    var start = Int((offs_ptr + row)[])
    var end = Int((offs_ptr + row + 1)[])
    var str_len = end - start
    var h = FNV_BASIS
    for b in range(str_len):
        h = (h ^ Int64((data_ptr + start + b)[])) * FNV_PRIME
    return h ^ (Int64(str_len) * FNV_PRIME)


# =============================================================================
# Route witness — process-wide: inputs SERVED, and inputs handed back
# =============================================================================


def _init_rowdict_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn for the two counters below."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CD_ROWDICT_SERVED = _Global[
    "komira_cd_strenc_rowdict_served", _init_rowdict_counter,
]
comptime _CD_ROWDICT_DECLINED = _Global[
    "komira_cd_strenc_rowdict_declined", _init_rowdict_counter,
]


def cd_strenc_rowdict_served_count() raises -> Int:
    """String-key encodes this arm has served, process-wide."""
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to these helpers.
    var g = _CD_ROWDICT_SERVED.get_or_create_ptr()
    return Int(g[][].load())


def cd_strenc_rowdict_decline_count() raises -> Int:
    """String-key encodes this arm handed back (too many values), process-wide."""
    # SAFETY: §6 FFI carve-out (see `cd_strenc_rowdict_served_count`).
    var g = _CD_ROWDICT_DECLINED.get_or_create_ptr()
    return Int(g[][].load())


def reset_cd_strenc_rowdict_counters() raises:
    """Reset both counters to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `cd_strenc_rowdict_served_count`).
    var g = _CD_ROWDICT_SERVED.get_or_create_ptr()
    g[][].store(Scalar[DType.int64](0))
    var h = _CD_ROWDICT_DECLINED.get_or_create_ptr()
    h[][].store(Scalar[DType.int64](0))


def _rowdict_note(declined: Bool) raises:
    # SAFETY: §6 FFI carve-out (see `cd_strenc_rowdict_served_count`).
    if declined:
        var h = _CD_ROWDICT_DECLINED.get_or_create_ptr()
        _ = h[][].fetch_add(Int64(1))
    else:
        var g = _CD_ROWDICT_SERVED.get_or_create_ptr()
        _ = g[][].fetch_add(Int64(1))


# =============================================================================
# Dispatch state + task
# =============================================================================


def _owned_li(var v: List[Int]) -> OwnedPointer[List[Int]]:
    """Heap-stable home for a `List[Int]` State field."""
    var raw = alloc[List[Int]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[Int]](unsafe_from_raw_pointer=raw)


def _owned_lli(var v: List[List[Int]]) -> OwnedPointer[List[List[Int]]]:
    """Heap-stable home for a `List[List[Int]]` State field."""
    var raw = alloc[List[List[Int]]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[List[Int]]](unsafe_from_raw_pointer=raw)


def _owned_llh(var v: List[List[Int64]]) -> OwnedPointer[List[List[Int64]]]:
    """Heap-stable home for a `List[List[Int64]]` State field."""
    var raw = alloc[List[List[Int64]]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[List[Int64]]](unsafe_from_raw_pointer=raw)


struct _RowDictState[
    OffsetType: DType,
    data_origin: ImmOrigin,
    offs_origin: ImmOrigin,
](KeepAlive):
    """Per-dispatch state for CDP-ROWDICT, shared by both passes.

    Disjointness:
      * MODE_DICT — task `t` writes `encoded[row]` only for its own rows
        `[row_starts[t], row_starts[t+1])` (the ranges tile `[0, num_rows)`)
        and only element `t` of each per-task out-List.
      * MODE_REMAP — task `t` rewrites only its own `encoded` rows and only
        READS `gid_of[t]`.

    Liveness: the State lives on the driver stack across both `run_with_state`
    calls, whose fork-join barrier returns only after every worker has
    finished. `data_ptr` / `offs_ptr` are batch-rooted.

    No-realloc: the OUTER per-task Lists are pre-sized to T and never appended
    to during a dispatch; each INNER List grows only in MODE_DICT and only under
    its one task. `gid_of` is built by the DRIVER between the two dispatches and
    only read in MODE_REMAP. `encoded` is sized before the first dispatch and
    written in place.
    """

    var loc_hash: OwnedPointer[List[List[Int64]]]
    var loc_start: OwnedPointer[List[List[Int]]]  # SOURCE offset of the mint row
    var loc_len: OwnedPointer[List[List[Int]]]
    var gid_of: OwnedPointer[List[List[Int]]]
    var row_starts: OwnedPointer[List[Int]]
    var encoded: OwnedPointer[List[Int]]

    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]
    var decline: OwnedPointer[AtomicI8]

    var data_ptr: UnsafePointer[UInt8, Self.data_origin]
    var offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.offs_origin]

    var max_local: Int
    var hash_and: Int64
    var census_site: Int

    def __init__(
        out self,
        n_tasks: Int,
        data_ptr: UnsafePointer[UInt8, Self.data_origin],
        offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.offs_origin],
        var row_starts: List[Int],
        var encoded: List[Int],
        max_local: Int,
        hash_and: Int64,
        census_site: Int,
    ):
        var lh = List[List[Int64]](capacity=n_tasks)
        var ls = List[List[Int]](capacity=n_tasks)
        var ll = List[List[Int]](capacity=n_tasks)
        for _ in range(n_tasks):
            lh.append(List[Int64]())
            ls.append(List[Int]())
            ll.append(List[Int]())
        self.loc_hash = _owned_llh(lh^)
        self.loc_start = _owned_lli(ls^)
        self.loc_len = _owned_lli(ll^)
        self.gid_of = _owned_lli(List[List[Int]]())
        self.row_starts = _owned_li(row_starts^)
        self.encoded = _owned_li(encoded^)

        var fraw = alloc[AtomicI8](1)
        fraw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(
            Scalar[DType.int8](0)
        )
        self.err_flag = OwnedPointer[AtomicI8](unsafe_from_raw_pointer=fraw)
        var draw = alloc[AtomicI8](1)
        draw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(
            Scalar[DType.int8](0)
        )
        self.decline = OwnedPointer[AtomicI8](unsafe_from_raw_pointer=draw)

        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)

        self.data_ptr = data_ptr
        self.offs_ptr = offs_ptr
        self.max_local = max_local
        self.hash_and = hash_and
        self.census_site = census_site


@fieldwise_init
struct _RowDictTask[
    OffsetType: DType,
    data_origin: ImmOrigin,
    offs_origin: ImmOrigin,
](Segment):
    """POD Segment for `_RowDictState`. `mode` selects the pass."""

    var mode: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: task `t` owns row range [row_starts[t],
        #     row_starts[t+1]) of `encoded` (the ranges tile the rows) and
        #     element `t` of every per-task List; MODE_REMAP only READS gid_of.
        #   * Liveness: State is on the driver stack across the fork-join
        #     barrier. `data_ptr`/`offs_ptr` are batch-rooted.
        #   * No-realloc: the OUTER per-task Lists are pre-sized to T and not
        #     appended to during a dispatch, so no inner List ever moves;
        #     `encoded` was sized before the first dispatch.
        var sp = UnsafePointer(to=state).bitcast[
            _RowDictState[Self.OffsetType, Self.data_origin, Self.offs_origin]
        ]()

        try:
            if sp[].err_flag[].load() != Int8(0):
                return
            if self.mode == _ROWDICT_MODE_REMAP:
                self._remap(sp[], Int(task_id))
            else:
                self._dict(sp[], Int(task_id))
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
            return

    def _dict(
        mut self,
        mut st: _RowDictState[
            Self.OffsetType, Self.data_origin, Self.offs_origin
        ],
        t: Int,
    ) raises:
        """Build task `t`'s local dictionary over its own rows, minting local
        ids in row order; raise the decline flag past `max_local` values."""
        ref row_starts = st.row_starts[]
        var row_lo = row_starts[t]
        var row_hi = row_starts[t + 1]
        var data_ptr = st.data_ptr
        var offs_ptr = st.offs_ptr
        var hash_and = st.hash_and
        var max_local = st.max_local
        var census_site = st.census_site
        ref enc_list = st.encoded[]
        var enc_ptr = enc_list.unsafe_ptr()

        ref lh = st.loc_hash[][t]
        ref ls = st.loc_start[][t]
        ref ll = st.loc_len[][t]

        var ht_cap = _ROWDICT_INIT_CAP
        var ht_mask = ht_cap - 1
        var ht_hash = List[Int64](length=ht_cap, fill=Int64(0))
        var ht_idx = List[Int32](length=ht_cap, fill=Int32(-1))
        var ht_limit = ht_cap >> 1
        var n_local = 0
        var vcache = List[UInt8](capacity=_PARB_VCACHE_BYTES)
        var vstart = List[Int]()

        var row = row_lo
        while row < row_hi:
            if st.decline[].load() != Int8(0):
                return
            var chunk_hi = row + _ROWDICT_POLL_ROWS
            if chunk_hi > row_hi:
                chunk_hi = row_hi
            for r in range(row, chunk_hi):
                var h = _strenc_fnv_row(data_ptr, offs_ptr, r) & hash_and
                var start = Int((offs_ptr + r)[])
                var str_len = Int((offs_ptr + r + 1)[]) - start
                var slot = Int(h) & ht_mask
                while True:
                    var lid = ht_idx[slot]
                    if lid < Int32(0):
                        if n_local >= max_local:
                            var expected = Int8(0)
                            _ = st.decline[].compare_exchange(
                                expected, Int8(1)
                            )
                            return
                        lh.append(h)
                        ls.append(start)
                        ll.append(str_len)
                        _parb_vcache_admit(
                            vcache, vstart, n_local, data_ptr, start, str_len
                        )
                        ht_hash[slot] = h
                        ht_idx[slot] = Int32(n_local)
                        # SAFETY: `r` is in this task's own row range, which
                        # lies inside `[0, num_rows) == len(encoded)`.
                        (enc_ptr + r)[] = n_local
                        n_local += 1
                        if n_local > ht_limit:
                            # Double at half load. Linear probing has no
                            # tombstones, so re-inserting every live slot
                            # rebuilds every chain.
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
                            ht_limit = ht_cap >> 1
                        break
                    if ht_hash[slot] == h:
                        var cand = Int(lid)
                        var ok = ll[cand] == str_len
                        if ok and str_len > 0:
                            ok = _parb_verify(
                                vcache,
                                vstart,
                                cand,
                                ls[cand],
                                data_ptr,
                                start,
                                str_len,
                                census_site,
                            )
                        if ok:
                            (enc_ptr + r)[] = cand
                            break
                        # Same hash, DIFFERENT bytes: keep probing.
                    slot = (slot + 1) & ht_mask
            row = chunk_hi

    def _remap(
        mut self,
        mut st: _RowDictState[
            Self.OffsetType, Self.data_origin, Self.offs_origin
        ],
        t: Int,
    ) raises:
        """Rewrite task `t`'s rows from LOCAL to GLOBAL id."""
        ref row_starts = st.row_starts[]
        var row_lo = row_starts[t]
        var row_hi = row_starts[t + 1]
        ref enc_list = st.encoded[]
        var enc_ptr = enc_list.unsafe_ptr()
        ref go = st.gid_of[][t]
        for r in range(row_lo, row_hi):
            # SAFETY: `r` is in this task's own range; `encoded[r]` is a local
            # id this task minted, so it indexes `gid_of[t]` in bounds.
            (enc_ptr + r)[] = go[(enc_ptr + r)[]]


# =============================================================================
# The merge — serial, on the driver, between the two dispatches
# =============================================================================


def _rowdict_merge[
    OffsetType: DType, data_origin: ImmOrigin, offs_origin: ImmOrigin
](
    mut st: _RowDictState[OffsetType, data_origin, offs_origin],
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
):
    """Number every value the first time the (task, mint)-ordered walk meets
    it — the global first-seen order (module header) — and fill `gid_of`.
    Fills `out_rev_starts` / `out_rev_lens` (empty on entry) with each global
    id's SOURCE span: its first task minted it at its global first row."""
    ref lh_all = st.loc_hash[]
    ref ls_all = st.loc_start[]
    ref ll_all = st.loc_len[]
    var data_ptr = st.data_ptr
    var n_tasks = len(lh_all)
    var total_local = 0
    for t in range(n_tasks):
        total_local += len(lh_all[t])
    var cap = _ROWDICT_INIT_CAP
    while cap < 2 * total_local:
        cap *= 2
    var mask = cap - 1
    var g_hash = List[Int64](length=cap, fill=Int64(0))
    var g_idx = List[Int32](length=cap, fill=Int32(-1))
    var gid_of = List[List[Int]](capacity=n_tasks)
    for t in range(n_tasks):
        ref lh = lh_all[t]
        ref ls = ls_all[t]
        ref ll = ll_all[t]
        var go = List[Int]()
        go.resize(unsafe_uninit_length=len(lh))
        for lid in range(len(lh)):
            var h = lh[lid]
            var s = ls[lid]
            var n = ll[lid]
            var slot = Int(h) & mask
            while True:
                var g = g_idx[slot]
                if g < Int32(0):
                    var ng = len(out_rev_starts)
                    out_rev_starts.append(s)
                    out_rev_lens.append(n)
                    g_hash[slot] = h
                    g_idx[slot] = Int32(ng)
                    go[lid] = ng
                    break
                if g_hash[slot] == h:
                    var gi = Int(g)
                    var ok = out_rev_lens[gi] == n
                    if ok:
                        var gs = out_rev_starts[gi]
                        var i = 0
                        while i < n:
                            if (data_ptr + s + i)[] != (data_ptr + gs + i)[]:
                                ok = False
                                break
                            i += 1
                    if ok:
                        go[lid] = gi
                        break
                slot = (slot + 1) & mask
        gid_of.append(go^)
    st.gid_of[] = gid_of^


# =============================================================================
# Entry point
# =============================================================================


def _assign_dict_ids_rowdict[
    OffsetType: DType,
    data_origin: ImmOrigin,
    offs_origin: ImmOrigin,
](
    mut dispatcher: LocalDispatcher[NoopSink],
    data_ptr: UnsafePointer[UInt8, data_origin],
    offs_ptr: UnsafePointer[Scalar[OffsetType], offs_origin],
    num_rows: Int,
    census_site: Int,
    n_tasks: Int,
    mut out_encoded: List[Int],
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
    max_local: Int = _ROWDICT_MAX_LOCAL,
    hash_and: Int64 = Int64(-1),
) raises -> Bool:
    """CDP-ROWDICT — Phase A + Phase B on `n_tasks` ROW RANGES, numbering
    PRESERVED. Returns True when it SERVED the encode, False when it DECLINED
    (some task met more than `max_local` values) — then every output is left
    exactly as it came in, and the caller runs the hash-sharded arm.

    On True: `out_encoded` holds `num_rows` dict ids, and dict id `d`'s bytes
    are `data_ptr[out_rev_starts[d] : + out_rev_lens[d]]` — L3's SOURCE-backed
    reverse map (no arena), the same contract as `_assign_dict_ids_parallel`.
    `out_rev_starts` / `out_rev_lens` must be empty on entry.

    Test hooks, the `merge_min_per_task` pattern: `max_local` lets a small
    fixture reach the decline; `hash_and` masks the row hash so a fixture can
    force distinct values onto one hash and exercise verify-on-hit (production
    passes neither).
    """
    var T = n_tasks
    if T < 1:
        T = 1
    var row_starts = List[Int](capacity=T + 1)
    row_starts.append(0)
    for t in range(1, T):
        row_starts.append((num_rows * t) // T)
    row_starts.append(num_rows)
    # UNINITIALISED on purpose: every row is written by its own task (mint or
    # hit) before anything reads it, and the tasks take the first-touch faults.
    var enc_buf = List[Int]()
    enc_buf.resize(unsafe_uninit_length=num_rows)

    var state = _RowDictState[OffsetType, data_origin, offs_origin](
        T,
        data_ptr,
        offs_ptr,
        row_starts^,
        enc_buf^,
        max_local,
        hash_and,
        census_site,
    )

    # ---- pass 1: each task's local dictionary, in parallel ----
    var dict_task = _RowDictTask[OffsetType, data_origin, offs_origin](
        _ROWDICT_MODE_DICT
    )
    var back1 = dispatcher.run_with_state[
        _RowDictState[OffsetType, data_origin, offs_origin],
        _RowDictTask[OffsetType, data_origin, offs_origin],
    ](
        state,
        dict_task^,
        T,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back1^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))
    if state.decline[].load() != Int8(0):
        _rowdict_note(True)
        _ = state^
        return False

    # ---- the merge: serial, (task, mint) order = global first-seen order ----
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    _rowdict_merge(state, rev_starts, rev_lens)

    # ---- pass 2: local id -> global id, in parallel ----
    var remap_task = _RowDictTask[OffsetType, data_origin, offs_origin](
        _ROWDICT_MODE_REMAP
    )
    var back2 = dispatcher.run_with_state[
        _RowDictState[OffsetType, data_origin, offs_origin],
        _RowDictTask[OffsetType, data_origin, offs_origin],
    ](
        state,
        remap_task^,
        T,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back2^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    swap(state.encoded[], out_encoded)
    swap(rev_starts, out_rev_starts)
    swap(rev_lens, out_rev_lens)
    _rowdict_note(False)

    _ = state^
    return True
