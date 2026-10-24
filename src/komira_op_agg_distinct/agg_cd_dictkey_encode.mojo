# =============================================================================
# ⭐ CD-SCAN (2026-09-25, cbq10 / cbq11) — THE DICTIONARY-KEY ENCODE: codes
#   renumbered in FIRST-SEEN order, on ROW RANGES, with no string hashed per row
# =============================================================================
#
# Companion to `agg_count_distinct_parallel._execute_count_distinct_agg_
# parallel`, whose DICTIONARY key arm this is. The grouped COUNT(DISTINCT)
# resident-collect route now keeps a dictionary-encoded parquet string key as
# CODES (`materialize_parquet_collect(preserve_dict=True)` + the unified-
# dictionary concat in `komira_engine_runtime/concat_dict_unify.mojo`), so the
# key reaches this driver as ONE `DICTIONARY` column instead of a dense
# `STRING` column the scan had to build row by row (`_dict_to_string_array`)
# and this driver then had to re-hash row by row (CDP-ROWDICT).
#
# ★ THE NUMBERING IS THE CONTRACT. The dict ids this returns become the
# driver's group ids, and the group ids ARE the emit order (and the Top-K tie
# order). The STRING arms (serial Phase B, CDPPARB, CDP-ROWDICT) all number a
# value the FIRST time it is met in ROW order. This arm numbers the same way,
# so a DICTIONARY key and the dense STRING form of the same rows produce the
# SAME group ids, the same partition hashes, the same owners and therefore the
# same output batch, byte for byte. The arm it replaces numbered groups by the
# raw dictionary CODE — a different emit order for the same answer, and a
# WRONG answer if a dictionary ever repeats a value (two codes, one string,
# two groups). Both are closed here: the numbering interns each referenced
# code's BYTES, so a repeated dictionary value collapses onto one id.
#
# HOW, in one paragraph. Task t owns rows [row_starts[t], row_starts[t+1]). It
# walks its codes once and records, in order, each code the first time it
# meets it (a `d_size`-byte seen table — cbq10's unified dictionary has a few
# hundred entries, so it is L1-resident). The driver walks the tasks in order,
# and each task's list in order, and interns each code's dictionary BYTES into
# a `DictInterner` the first time the code is met: the interner's ordinal is
# the global first-seen rank of the STRING, i.e. the dict id. A parallel remap
# writes `encoded[row] = gid_of_code[code[row]]`. The same (task, order) merge
# argument as CDP-ROWDICT (`agg_cd_strenc_rowdict.mojo` header) makes it the
# global first-seen order.
#
# The reverse map is the interner's arena: dict id g's bytes are
# `rev_bytes[rev_starts[g] : + rev_lens[g]]` (an ARENA, so the driver's
# `key_rev_on_src` is False for this arm, as it always was).
#
# NULLS are read as their raw code, exactly as the arm this replaces did: the
# resident-collect admission (`distinct_node_exec._build_grouped_cd_parallel_
# sink_data`) only hands this driver null-free keys. A code outside
# [0, d_size) is a corrupt column and RAISES a named error, never an
# out-of-bounds read.
#
# Route witness: `cd_dictkey_encode_count` — no value oracle can see which
# encode ran (the STRING arm answers identically), only the route can.
#
# Safety
# ------
# * `codes_ptr` is a concrete-origin pointer into the caller's batch buffer
#   (already advanced by the column's `_offset`), which outlives both
#   dispatches here. It is stored in the State and read by the tasks.
# * State fields are OwnedPointer-wrapped; no wildcard-origin fields.
# * Every `run_with_state` site carries the PARALLELIZE-BOUNDARY block.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_STRENC
from komira_atomic_alias import AtomicI8, AtomicI64
from std.ffi import _Global
from std.builtin.swap import swap
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_arrow.column import Column
from komira_arrow.dict_interner import DictInterner
from komira_arrow.varlen_width_guard import dict_offset_width_bytes
from komira_buffer.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher


# Rows per task below which another task is not worth a fork slot.
comptime _DICTKEY_MIN_ROWS_PER_TASK: Int = 16_384

# Largest dictionary the per-task seen tables are allocated for. Above it the
# encode runs as ONE task (one seen table), which is still O(rows) with no
# per-row hashing; T x d_size bytes of seen tables would otherwise dominate.
comptime _DICTKEY_MAX_PARALLEL_DSIZE: Int = 1 << 20

comptime _DICTKEY_MODE_SEEN: Int32 = 0
comptime _DICTKEY_MODE_REMAP: Int32 = 1


# =============================================================================
# Route witness — process-wide count of dictionary-key encodes served
# =============================================================================


def _init_dictkey_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn for the counter below."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CD_DICTKEY_SERVED = _Global[
    "komira_cd_dictkey_encode_served", _init_dictkey_counter,
]


def cd_dictkey_encode_count() raises -> Int:
    """DICTIONARY-key encodes served, process-wide."""
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to these helpers.
    var g = _CD_DICTKEY_SERVED.get_or_create_ptr()
    return Int(g[][].load())


def reset_cd_dictkey_encode_count() raises:
    """Reset the counter to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `cd_dictkey_encode_count`).
    var g = _CD_DICTKEY_SERVED.get_or_create_ptr()
    g[][].store(Scalar[DType.int64](0))


def _dictkey_note() raises:
    # SAFETY: §6 FFI carve-out (see `cd_dictkey_encode_count`).
    var g = _CD_DICTKEY_SERVED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(1))


# =============================================================================
# Dispatch state + task
# =============================================================================


def _owned_li(var v: List[Int]) -> OwnedPointer[List[Int]]:
    """Heap-stable home for a `List[Int]` State field."""
    var raw = alloc[List[Int]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[Int]](unsafe_from_raw_pointer=raw)


def _owned_lli32(var v: List[List[Int32]]) -> OwnedPointer[List[List[Int32]]]:
    """Heap-stable home for a `List[List[Int32]]` State field."""
    var raw = alloc[List[List[Int32]]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[List[Int32]]](unsafe_from_raw_pointer=raw)


def _owned_i8() -> OwnedPointer[AtomicI8]:
    var raw = alloc[AtomicI8](1)
    raw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
    return OwnedPointer[AtomicI8](unsafe_from_raw_pointer=raw)


struct _DictKeyState[codes_origin: ImmOrigin](KeepAlive):
    """Per-dispatch state for the dictionary-key encode, shared by both passes.

    Disjointness:
      * MODE_SEEN — task `t` reads only its own rows' codes and writes only
        element `t` of `first_seen`.
      * MODE_REMAP — task `t` writes `encoded[row]` only for its own rows
        `[row_starts[t], row_starts[t+1])` (the ranges tile `[0, num_rows)`)
        and only READS `gid_of_code`.

    Liveness: the State lives on the driver stack across both `run_with_state`
    calls, whose fork-join barrier returns only after every worker has
    finished. `codes_ptr` is batch-rooted.

    No-realloc: the OUTER `first_seen` List is pre-sized to T and never
    appended to during a dispatch; each INNER List grows only in MODE_SEEN and
    only under its one task. `gid_of_code` is built by the DRIVER between the
    two dispatches and only read in MODE_REMAP. `encoded` is sized before the
    first dispatch and written in place.
    """

    var first_seen: OwnedPointer[List[List[Int32]]]
    var gid_of_code: OwnedPointer[List[Int]]
    var row_starts: OwnedPointer[List[Int]]
    var encoded: OwnedPointer[List[Int]]

    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]
    var bad_code: OwnedPointer[AtomicI8]

    var codes_ptr: UnsafePointer[Scalar[DType.int32], Self.codes_origin]
    var d_size: Int

    def __init__(
        out self,
        n_tasks: Int,
        codes_ptr: UnsafePointer[Scalar[DType.int32], Self.codes_origin],
        d_size: Int,
        var row_starts: List[Int],
        var encoded: List[Int],
    ):
        var fs = List[List[Int32]](capacity=n_tasks)
        for _ in range(n_tasks):
            fs.append(List[Int32]())
        self.first_seen = _owned_lli32(fs^)
        self.gid_of_code = _owned_li(List[Int]())
        self.row_starts = _owned_li(row_starts^)
        self.encoded = _owned_li(encoded^)
        self.err_flag = _owned_i8()
        self.bad_code = _owned_i8()
        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)
        self.codes_ptr = codes_ptr
        self.d_size = d_size


@fieldwise_init
struct _DictKeyTask[codes_origin: ImmOrigin](Segment):
    """POD Segment for `_DictKeyState`. `mode` selects the pass."""

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
        #     element `t` of `first_seen`; MODE_REMAP only READS gid_of_code.
        #   * Liveness: State is on the driver stack across the fork-join
        #     barrier. `codes_ptr` is batch-rooted.
        #   * No-realloc: the OUTER `first_seen` List is pre-sized to T and not
        #     appended to during a dispatch, so no inner List ever moves;
        #     `encoded` was sized before the first dispatch.
        var sp = UnsafePointer(to=state).bitcast[
            _DictKeyState[Self.codes_origin]
        ]()
        try:
            if sp[].err_flag[].load() != Int8(0):
                return
            if self.mode == _DICTKEY_MODE_REMAP:
                self._remap(sp[], Int(task_id))
            else:
                self._seen(sp[], Int(task_id))
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
            return

    def _seen(
        mut self, mut st: _DictKeyState[Self.codes_origin], t: Int
    ) raises:
        """Record, in row order, each code task `t` meets for the first time.
        A code outside [0, d_size) raises the shared `bad_code` flag."""
        ref row_starts = st.row_starts[]
        var row_lo = row_starts[t]
        var row_hi = row_starts[t + 1]
        var codes = st.codes_ptr
        var d_size = st.d_size
        ref out = st.first_seen[][t]
        var seen = List[UInt8](length=max(d_size, 1), fill=UInt8(0))
        var seen_ptr = seen.unsafe_ptr()
        for r in range(row_lo, row_hi):
            # SAFETY: `r` is in this task's own range, inside the column's
            # `[0, num_rows)` window that `codes_ptr` addresses.
            var c = Int((codes + r)[])
            if c < 0 or c >= d_size:
                var expected = Int8(0)
                _ = st.bad_code[].compare_exchange(expected, Int8(1))
                return
            # SAFETY: `c` was bounds-checked against `d_size == len(seen)`.
            if (seen_ptr + c)[] == UInt8(0):
                (seen_ptr + c)[] = UInt8(1)
                out.append(Int32(c))

    def _remap(
        mut self, mut st: _DictKeyState[Self.codes_origin], t: Int
    ) raises:
        """Write task `t`'s rows' GLOBAL dict ids."""
        ref row_starts = st.row_starts[]
        var row_lo = row_starts[t]
        var row_hi = row_starts[t + 1]
        var codes = st.codes_ptr
        ref enc_list = st.encoded[]
        var enc_ptr = enc_list.unsafe_ptr()
        ref gmap = st.gid_of_code[]
        var gmap_ptr = gmap.unsafe_ptr()
        for r in range(row_lo, row_hi):
            # SAFETY: `r` is in this task's own range; MODE_SEEN already proved
            # every code of every row is in [0, d_size) == len(gid_of_code).
            (enc_ptr + r)[] = (gmap_ptr + Int((codes + r)[]))[]


# =============================================================================
# Entry point
# =============================================================================


def dictkey_encode_task_count(num_rows: Int, workers: Int, d_size: Int) -> Int:
    """How many row ranges the encode cuts `num_rows` into: one per worker,
    at least `_DICTKEY_MIN_ROWS_PER_TASK` rows each, and ONE when the
    dictionary is too large for a seen table per task."""
    if d_size > _DICTKEY_MAX_PARALLEL_DSIZE:
        return 1
    var t = num_rows // _DICTKEY_MIN_ROWS_PER_TASK
    if t > workers:
        t = workers
    if t < 1:
        t = 1
    return t


def encode_dict_key_first_seen(
    mut dispatcher: LocalDispatcher[NoopSink],
    col: Column[HeapRegion],
    num_rows: Int,
    mut out_encoded: List[Int],
    mut out_rev_bytes: List[UInt8],
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
    n_tasks_override: Int = 0,
) raises:
    """Encode a STRING-dictionary key column into first-seen dict ids.

    On return `out_encoded` holds `num_rows` dict ids numbered in the order
    each distinct VALUE first appears in row order — the numbering every
    STRING arm of the driver produces — and dict id `g`'s bytes are
    `out_rev_bytes[out_rev_starts[g] : + out_rev_lens[g]]`. The three reverse
    lists must be empty on entry.

    `n_tasks_override` (> 0) pins the task count — the test hook that proves
    the numbering does not depend on it. Production passes 0.
    """
    if not col.is_string_dict():
        raise Error(
            "agg_cd_dictkey_encode: the key is not a STRING dictionary column"
        )
    if dict_offset_width_bytes() != 4:
        raise Error(
            "agg_cd_dictkey_encode: dictionary-value offsets are no longer"
            " Int32; this read site strides them at 4 bytes and must be"
            " re-parameterized"
        )
    if col._dict_index_byte_width != 4:
        raise Error(
            "agg_cd_dictkey_encode: dictionary codes are "
            + String(col._dict_index_byte_width)
            + " bytes wide; this encode reads Int32 codes"
        )
    if col._length < num_rows:
        raise Error(
            "agg_cd_dictkey_encode: the key column holds "
            + String(col._length) + " rows, fewer than the "
            + String(num_rows) + " requested"
        )
    # SAFETY: the view pins `col`'s code buffer for this function's body, and
    # `col` is borrowed from the caller's batch, which outlives both
    # dispatches. The pointer is advanced to the column's `_offset`, so row r
    # of the window is `codes_ptr[r]`.
    var idx_view = col._data.view_ro()
    var codes_ptr = (
        idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]() + col._offset
    )
    _encode_codes(
        dispatcher,
        codes_ptr,
        col,
        num_rows,
        out_encoded,
        out_rev_bytes,
        out_rev_starts,
        out_rev_lens,
        n_tasks_override,
    )
    _ = idx_view^


def _encode_codes[
    codes_origin: ImmOrigin
](
    mut dispatcher: LocalDispatcher[NoopSink],
    codes_ptr: UnsafePointer[Scalar[DType.int32], codes_origin],
    col: Column[HeapRegion],
    num_rows: Int,
    mut out_encoded: List[Int],
    mut out_rev_bytes: List[UInt8],
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
    n_tasks_override: Int,
) raises:
    """The body of `encode_dict_key_first_seen`, generic over the code
    buffer's origin (`codes_ptr` is `col`'s window, already offset)."""
    var d_size = col._dict_size

    var T = n_tasks_override
    if T <= 0:
        T = dictkey_encode_task_count(
            num_rows, dispatcher.worker_count(), d_size
        )
    var row_starts = List[Int](capacity=T + 1)
    row_starts.append(0)
    for t in range(1, T):
        row_starts.append((num_rows * t) // T)
    row_starts.append(num_rows)
    # UNINITIALISED on purpose: every row is written by its own task in the
    # remap pass before anything reads it, and the tasks take the first-touch
    # faults.
    var enc_buf = List[Int]()
    enc_buf.resize(unsafe_uninit_length=num_rows)

    var state = _DictKeyState[codes_origin](
        T, codes_ptr, d_size, row_starts^, enc_buf^
    )

    # ---- pass 1: each task's first-seen code list, in parallel ----
    # PARALLELIZE-BOUNDARY: see `_DictKeyTask.execute` (disjoint row ranges,
    # State on this stack across the barrier, no reallocation of the outer
    # per-task List).
    var seen_task = _DictKeyTask[codes_origin](_DICTKEY_MODE_SEEN)
    var back1 = dispatcher.run_with_state[
        _DictKeyState[codes_origin], _DictKeyTask[codes_origin]
    ](
        state,
        seen_task^,
        T,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back1^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))
    if state.bad_code[].load() != Int8(0):
        raise Error(
            "agg_cd_dictkey_encode: a dictionary code lies outside the"
            " column's dictionary (size " + String(d_size) + ")"
        )

    # ---- the merge: serial, (task, order) = global first-seen order ----
    # Intern each code's BYTES the first time the walk meets the code: the
    # interner's ordinal is the first-seen rank of the STRING, so a repeated
    # dictionary value (two codes, one string) lands on ONE id.
    var offs_view = col._offsets.value().view_ro()
    var offs_src = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    ref dict_buf = col._dict_data.value()
    var gid_of_code = List[Int](length=max(d_size, 1), fill=-1)
    var n_local = 0
    for t in range(T):
        n_local += len(state.first_seen[][t])
    var interner = DictInterner(expected_entries=n_local)
    for t in range(T):
        ref fs = state.first_seen[][t]
        for i in range(len(fs)):
            var c = Int(fs[i])
            if gid_of_code[c] >= 0:
                continue
            # SAFETY: `c` is in [0, d_size) (pass 1 proved it), and the
            # offsets buffer holds d_size + 1 Int32 entries.
            var s = Int((offs_src + c)[])
            var e = Int((offs_src + c + 1)[])
            gid_of_code[c] = Int(
                interner.find_or_insert(dict_buf.view_ro().sub(s, e - s))
            )
    state.gid_of_code[] = gid_of_code^

    # ---- pass 2: code -> global id, in parallel ----
    # PARALLELIZE-BOUNDARY: as pass 1; `gid_of_code` is only read.
    var remap_task = _DictKeyTask[codes_origin](_DICTKEY_MODE_REMAP)
    var back2 = dispatcher.run_with_state[
        _DictKeyState[codes_origin], _DictKeyTask[codes_origin]
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

    # ---- the reverse map: the interner's arena ----
    var n_ids = interner.size()
    ref ioffs = interner.offsets()
    out_rev_starts.reserve(n_ids)
    out_rev_lens.reserve(n_ids)
    for g in range(n_ids):
        var s = Int(ioffs[g])
        out_rev_starts.append(s)
        out_rev_lens.append(Int(ioffs[g + 1]) - s)
    out_rev_bytes = interner.bytes().copy()
    swap(state.encoded[], out_encoded)
    _dictkey_note()

    _ = offs_view^
    _ = state^
