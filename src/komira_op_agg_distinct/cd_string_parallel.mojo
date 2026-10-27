# =============================================================================
# cd_string_parallel.mojo — exact parallel COUNT(DISTINCT <STRING>) over a
#                            resident Arrow column
# =============================================================================
#
# THE DEFECT THIS EXISTS FOR. Answering `count(DISTINCT <string column>)` by
# running the FULL `SELECT DISTINCT <col>` operator and taking the row count of
# its output stacks three separate costs on one another:
#
#   1. the dedup is SERIAL — one thread inserts every row into one
#      untyped row-directory while the other workers idle;
#   2. it MATERIALISES the distinct VALUES — every canonical distinct string and a
#      whole key-only `RecordBatch` (offsets + data + validity) are built and
#      then thrown away, because the caller wants ONE Int64;
#   3. it goes through the untyped `ColumnFormatStorage` cell path, which
#      stores the key BYTES of every distinct row.
#
# Nothing about `count(DISTINCT s)` needs any of that. The answer is a COUNT,
# so no value ever has to be copied out of the Arrow buffers, and the count is
# a sum over disjoint value-hash partitions, so it parallelises exactly.
#
# THE MECHANISM (the string twin of `cd_radix_parallel.radix_distinct_count`,
# the Int64 case):
#
#   Phase 1 — SCAN (parallel over row ranges). Task `s` walks its own
#     contiguous row slice, hashes each NON-NULL value with xxHash64 straight
#     out of the column's `data` buffer (no `String`, no copy), and appends a
#     PACKED 8-byte entry `(fingerprint32 << 32) | (row + 1)` into its own
#     `matrix[s][p]` buffer, where `p` is the TOP `log2(np)` bits of the hash.
#     Equal values hash identically, so equal values always land in the SAME
#     partition regardless of which task saw them.
#
#   Phase 2 — DEDUP (parallel over partitions). Task `p` unions column
#     `matrix[*][p]` into one open-addressed table keyed by the 32-bit
#     fingerprint and VERIFIED by a byte compare of the two rows' spans.
#     Partitions are disjoint by construction, so the per-partition distinct
#     counts SUM to the exact global distinct count.
#
# ★ THE DUPLICATE PRE-FILTER IS NOT AN OPTIMISATION, IT IS WHAT MAKES THE
#   PARTITIONING VIABLE. Hash-partitioning by VALUE concentrates duplicates:
#   in a column where most rows are the EMPTY STRING, a naive scatter puts
#   most of the input into ONE partition and the dedup
#   phase degenerates to a single-threaded straggler that is SLOWER than a
#   serial fold. Each scan task therefore carries a small
#   direct-mapped "last value seen at this hash slot" cache (`_CDSTR_FILT_SIZE`
#   entries, L1/L2-resident). A row whose value is PROVEN — by fingerprint AND
#   byte compare — equal to the cache's occupant is dropped, because that value
#   has already been emitted by this task. It is a pure filter: dropping a
#   proven duplicate cannot change a DISTINCT count, and a cache MISS only
#   costs an entry that phase 2 would have deduped anyway. Correctness does not
#   depend on the cache's size, its replacement policy, or on it being hit at
#   all — which is exactly why it can be lossy and cheap.
#
# EXACTNESS. The fingerprint is a GATE, never an answer: every fingerprint
# match is confirmed with `bytes_equal` over the two spans, so a 32-bit
# collision costs one extra compare and changes no count. No probabilistic
# structure is on the answer path.
#
# NULLs. SQL says COUNT(DISTINCT x) does not count NULL, so a null row is
# skipped in phase 1 and never reaches a partition. That is strictly simpler
# than the operator this replaces, which emitted NULL as a distinct row and
# then subtracted one.
#
# ENVELOPE. STRING (Int32 offsets) and LARGE_STRING (Int64 offsets), chosen
# from the COLUMN's own `arrow_type` and carried as a comptime `OffsetType`
# parameter — never read off a declared schema field, which can disagree with
# the buffer that is actually there. Any other type RAISES; the caller owns the
# decline.
#
# Safety
# ------
# * No `UnsafePointer` in the public entry point's signature: the driver takes
#   the `RecordBatch` and a column index. Each task takes its OWN `view_ro()`
#   of the column's buffers inside `execute`, so every raw pointer is a local
#   whose borrow is pinned by the view for the duration of the row loop.
# * No wildcard origin. Each dispatch State OWNS the buffers its tasks write
#   (OwnedPointer, swapped back by the driver after the barrier) and borrows
#   the batch and the slices through `Pointer`s whose immutable origins the
#   Task type also carries, so each Task's bitcast restores the exact State
#   type (as in `cd_radix_parallel`).
# * Every `run_with_state` site carries the Disjointness / Liveness /
#   No-realloc block.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.collections import List
from std.ffi import _Global
from std.builtin.swap import swap
from std.memory import (
    OwnedPointer, Pointer, UnsafePointer, alloc, bitcast,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_CD_RADIX

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_dynamic_filter.bloom_filter import xxhash64
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_simd.byte_class.byte_equal import bytes_equal


# =============================================================================
# §1 — sizing constants
# =============================================================================

# Below this the dispatch (two fork-join waves) costs more than the serial walk
# it replaces; the caller keeps its existing serial route there.
comptime _CDSTR_MIN_ROWS: Int = 65_536

# Target INPUT rows per partition. The pre-filter typically collapses a run of
# repeats before the scatter, so the number of ENTRIES a partition actually
# receives is well under this; the target is deliberately expressed in ROWS
# because that is the only quantity known before the scan.
comptime _CDSTR_TARGET_ROWS_PER_PART: Int = 262_144

# Upper bound on partitions. `np * ns` buffers are allocated, and buffer COUNT
# (not bytes) is what a teardown costs: freeing thousands of small buffers is
# far slower than freeing a few holding the same bytes.
comptime _CDSTR_MAX_PARTS: Int = 2048

# Direct-mapped duplicate pre-filter, per scan task. 16,384 * 8 B = 128 KB:
# sized to stay resident beside the scan's streaming loads, not to hold the
# value domain (it cannot, and does not need to).
comptime _CDSTR_FILT_BITS: Int = 14
comptime _CDSTR_FILT_SIZE: Int = 1 << _CDSTR_FILT_BITS
comptime _CDSTR_FILT_MASK: UInt64 = UInt64(_CDSTR_FILT_SIZE - 1)

# A packed entry is `(fingerprint32 << 32) | (row + 1)`, so the row ordinal
# must fit in 32 bits with 0 reserved as the empty marker.
comptime _CDSTR_MAX_ROWS: Int = 0xFFFF_FFFE

# =============================================================================
# The scan slices are cut by COST, not by rows, and there are more of them
# than workers
# =============================================================================
#
# A row's scan cost is not constant: it hashes the row's BYTES, and a
# non-empty value also misses the pre-filter and scatters, while an empty or
# just-seen one costs a fixed handful of ns. With `nw` EQUAL-ROW slices on
# a column that is mostly empty strings with the non-empty rows clustered, the
# slices carry very different work and the scan fork leaves workers idle.
#
# So, by default, `tiles = _CDSTR_TILES_PER_WORKER * nw` slices whose bounds
# equalise
#     cost(R) = payload bytes before row R  +  _CDSTR_ROW_COST_BYTES * R
# (a binary search per bound over the offsets, through the SAFE typed accessor —
# never O(rows)), claimed off the dispatcher's shared cursor so the residual
# model error is absorbed by whichever worker frees first. `bytebal = False`
# cuts the `nw` equal-row slices instead.
#
# ★ WHY THE ANSWER CANNOT MOVE. Any partition of `[0, n_rows)` into slices is
# correct: each scan task emits every value of its slice that its own pre-filter
# has not PROVEN it already emitted, and phase 2 dedups the union by value.
# =============================================================================

# Slices per worker. More slices = better dynamic balance and a smaller tail,
# but `np` partition buffers PER SLICE (buffer COUNT is what allocation and
# teardown cost — see `_CDSTR_MAX_PARTS`); 4x keeps the count at 4x the old.
comptime _CDSTR_TILES_PER_WORKER: Int = 4

# A row's fixed scan cost in payload-byte units: two offset loads, a hash of
# zero-or-more bytes, a pre-filter probe. Only the BALANCE depends on it.
comptime _CDSTR_ROW_COST_BYTES: Int = 16


# =============================================================================
# §1b — ⭐ THE ROUTE WITNESS. No value assertion can see which arm answered.
# =============================================================================
#
# A caller that routes `count(DISTINCT <string>)` here and one that runs the
# serial `SELECT DISTINCT` walk return the same number, so no value oracle can
# tell which route answered; this process-wide counter can (a `_Global` atomic,
# incremented once per answer this kernel serves).


def _init_cdstr_kernel_taken() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CDSTR_KERNEL_TAKEN = _Global[
    "komira_cd_string_kernel_taken", _init_cdstr_kernel_taken,
]


@always_inline
def cd_string_kernel_taken_incr() raises:
    """Record one `count(DISTINCT <string>)` answered by THIS kernel."""
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to this helper.
    var gp = _CDSTR_KERNEL_TAKEN.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def cd_string_kernel_taken_count() raises -> Int:
    """Read the process-wide count of answers served by this kernel."""
    # SAFETY: §6 FFI carve-out (see `cd_string_kernel_taken_incr`).
    var gp = _CDSTR_KERNEL_TAKEN.get_or_create_ptr()
    return Int(gp[][].load())


def reset_cd_string_kernel_counter() raises:
    """Reset the process-wide counter to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `cd_string_kernel_taken_incr`).
    var gp = _CDSTR_KERNEL_TAKEN.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))


@always_inline
def _cdstr_pack(fp: UInt32, row: Int) -> Int64:
    """Pack `(fingerprint, row)` into one Int64. `row + 1` keeps 0 free as the
    EMPTY marker for both the pre-filter and the dedup table, so a single
    `List[Int64]` is a complete slot array — one cache line per probe instead
    of two."""
    return Int64(bitcast[DType.int64](
        (UInt64(fp) << 32) | (UInt64(row) + UInt64(1))
    ))


@always_inline
def _cdstr_fp(packed: Int64) -> UInt32:
    return UInt32(bitcast[DType.uint64](packed) >> 32)


@always_inline
def _cdstr_row(packed: Int64) -> Int:
    return Int(bitcast[DType.uint64](packed) & UInt64(0xFFFF_FFFF)) - 1


@always_inline
def _cdstr_next_pow2(n: Int) -> Int:
    var p = 1
    while p < n:
        p <<= 1
    return p


def _cdstr_partition_count(n_rows: Int, nw: Int) -> Int:
    """Partition count: a power of two, at least `nw` (so every worker has a
    dedup task), at most `_CDSTR_MAX_PARTS`, otherwise sized so each partition
    sees about `_CDSTR_TARGET_ROWS_PER_PART` input rows."""
    var by_rows = n_rows // _CDSTR_TARGET_ROWS_PER_PART
    if by_rows < nw:
        by_rows = nw
    if by_rows < 1:
        by_rows = 1
    var np = _cdstr_next_pow2(by_rows)
    if np > _CDSTR_MAX_PARTS:
        np = _CDSTR_MAX_PARTS
    return np


@fieldwise_init
struct _CdStrSlice(Copyable, Movable):
    """A contiguous `[lo, hi)` row range for one scan task."""

    var lo: Int
    var hi: Int


# =============================================================================
# §2 — phase 1: parallel scan / hash / pre-filter / scatter
# =============================================================================


struct _CDStrScanState[
    bo: Origin[mut=False],
    so: Origin[mut=False],
](KeepAlive):
    """State for the parallel scan.

    Scan task `s` reads row range `slices[s]` of column `col_idx` and MOVES its
    finished per-partition buffers into `matrix[s]` — a pre-sized outer slot no
    other task names. `batch` and `slices` are read-only borrows; `matrix` is
    owned by the State for the dispatch."""

    var batch: Pointer[RecordBatch, Self.bo]
    var slices: Pointer[List[_CdStrSlice], Self.so]
    var matrix: OwnedPointer[List[List[List[Int64]]]]
    var col_idx: Int
    var np: Int
    var shift: Int
    var has_nulls: Bool

    def __init__(
        out self,
        ref [Self.bo] batch: RecordBatch,
        ref [Self.so] slices: List[_CdStrSlice],
        var matrix: List[List[List[Int64]]],
        col_idx: Int,
        np: Int,
        shift: Int,
        has_nulls: Bool,
    ):
        self.batch = Pointer(to=batch)
        self.slices = Pointer(to=slices)
        self.matrix = OwnedPointer(matrix^)
        self.col_idx = col_idx
        self.np = np
        self.shift = shift
        self.has_nulls = has_nulls

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDStrScanTask[
    OffsetType: DType, bo: Origin[mut=False], so: Origin[mut=False]
](Segment):
    """POD discriminator; `execute` scans this task's row slice.

    `OffsetType` is the COLUMN's offsets width — Int32 for STRING, Int64 for
    LARGE_STRING. One body, two instantiations, chosen by the driver from the
    column's own `arrow_type`."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        comptime ConcreteState = _CDStrScanState[Self.bo, Self.so]
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: task `s == task_id` writes ONLY `matrix[s]` (a
        #     pre-sized outer slot, moved into once) and reads only its own
        #     `slices[s]` row range. `batch` / `slices` are immutable shared
        #     borrows. No two tasks name the same matrix slot or the same row.
        #   * Liveness: the State lives on the driver stack across
        #     `run_with_state`, whose drain barrier joins every task before the
        #     driver proceeds. The column views taken below are locals pinned
        #     for the whole row loop, rooted in the batch the State borrows.
        #   * No-realloc: `matrix`'s outer List is pre-sized to `ns` before the
        #     dispatch and is only slot-assigned here; the per-partition buffers
        #     are this task's own locals until the final move.
        # The bitcast restores the exact State type: the Task carries the
        # State's two read-only origins.
        var sp = UnsafePointer(to=state).bitcast[ConcreteState]()
        var s = Int(task_id)
        ref slc = sp[].slices[][s]
        var row_lo = slc.lo
        var row_hi = slc.hi
        var np = sp[].np
        var shift = sp[].shift
        var has_nulls = sp[].has_nulls

        var local = List[List[Int64]](capacity=np)
        for _ in range(np):
            local.append(List[Int64]())
        if row_lo >= row_hi:
            sp[].matrix[][s] = local^
            return

        ref col = sp[].batch[].column_at(sp[].col_idx)
        var data_view = col._data.view_ro()
        var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        var offs_view = col._offsets.value().view_ro()
        var offs_ptr = offs_view._unsafe_ptr().bitcast[
            Scalar[Self.OffsetType]
        ]()

        # Direct-mapped duplicate pre-filter — see the header. 0 == empty.
        var filt = List[Int64](capacity=_CDSTR_FILT_SIZE)
        for _ in range(_CDSTR_FILT_SIZE):
            filt.append(Int64(0))

        for row in range(row_lo, row_hi):
            if has_nulls and col.is_null_at(row):
                continue
            var start = Int((offs_ptr + row)[])
            var vlen = Int((offs_ptr + row + 1)[]) - start
            var h = xxhash64(data_ptr + start, vlen)
            var fp = UInt32(h & UInt64(0xFFFF_FFFF))
            var packed = _cdstr_pack(fp, row)

            var fslot = Int(h & _CDSTR_FILT_MASK)
            var cached = filt[fslot]
            if cached != Int64(0) and _cdstr_fp(cached) == fp:
                var crow = _cdstr_row(cached)
                var cstart = Int((offs_ptr + crow)[])
                var clen = Int((offs_ptr + crow + 1)[]) - cstart
                if clen == vlen and bytes_equal(
                    Span(unsafe_ptr=data_ptr + cstart, length=clen),
                    Span(unsafe_ptr=data_ptr + start, length=vlen),
                ):
                    # PROVEN duplicate of a value this task has already emitted.
                    continue
            filt[fslot] = packed
            local[Int(h >> UInt64(shift))].append(packed)

        sp[].matrix[][s] = local^
        _ = filt^

    def __keep_alive(mut self):
        pass


# =============================================================================
# §3 — phase 2: parallel per-partition dedup
# =============================================================================


struct _CDStrDedupState[
    bo: Origin[mut=False],
](KeepAlive):
    """State for the per-partition dedup.

    Dedup task `p` reads column `matrix[0..ns][p]`, unions it into ONE verified
    table and writes `counts[p]`. Value partitions are disjoint by hash, so the
    per-partition sets never overlap and their sizes SUM to the exact global
    distinct count. `matrix` and `counts` are owned by the State for the
    dispatch."""

    var batch: Pointer[RecordBatch, Self.bo]
    var matrix: OwnedPointer[List[List[List[Int64]]]]
    var counts: OwnedPointer[List[Int64]]
    var col_idx: Int
    var ns: Int

    def __init__(
        out self,
        ref [Self.bo] batch: RecordBatch,
        var matrix: List[List[List[Int64]]],
        var counts: List[Int64],
        col_idx: Int,
        ns: Int,
    ):
        self.batch = Pointer(to=batch)
        self.matrix = OwnedPointer(matrix^)
        self.counts = OwnedPointer(counts^)
        self.col_idx = col_idx
        self.ns = ns

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDStrDedupTask[OffsetType: DType, bo: Origin[mut=False]](Segment):
    """POD discriminator; `execute` dedups this task's partition column."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        comptime ConcreteState = _CDStrDedupState[Self.bo]
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: task `p == task_id` touches ONLY column
        #     `matrix[*][p]` and ONLY `counts[p]`. The column index is `p` in
        #     every access below, including the reclaim, so no two tasks reach
        #     the same slot. `batch` is an immutable shared borrow.
        #   * Liveness: the State owns `matrix` / `counts` and lives on the
        #     driver stack across the drain barrier; `batch` is the driver's.
        #   * No-realloc: `matrix`'s outer AND inner Lists are fully populated
        #     by phase 1 before this dispatch; this task only ELEMENT-ASSIGNS
        #     (a slot swap) and never appends, so no task can observe another's
        #     reallocation. `counts` is pre-sized to `np`.
        var sp = UnsafePointer(to=state).bitcast[ConcreteState]()
        var p = Int(task_id)
        var ns = sp[].ns

        var n_ent = 0
        for s in range(ns):
            n_ent += len(sp[].matrix[][s][p])
        if n_ent == 0:
            sp[].counts[][p] = Int64(0)
            return

        ref col = sp[].batch[].column_at(sp[].col_idx)
        var data_view = col._data.view_ro()
        var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        var offs_view = col._offsets.value().view_ro()
        var offs_ptr = offs_view._unsafe_ptr().bitcast[
            Scalar[Self.OffsetType]
        ]()

        # Open addressing at <= 0.5 load, sized ONCE from the exact entry count
        # this partition received — no rehash on the hot path.
        var cap = _cdstr_next_pow2(n_ent * 2)
        if cap < 16:
            cap = 16
        var mask = UInt64(cap - 1)
        var slots = List[Int64](capacity=cap)
        for _ in range(cap):
            slots.append(Int64(0))

        var distinct = 0
        for s in range(ns):
            ref buf = sp[].matrix[][s][p]
            for i in range(len(buf)):
                var packed = buf[i]
                var fp = _cdstr_fp(packed)
                var row = _cdstr_row(packed)
                var start = Int((offs_ptr + row)[])
                var vlen = Int((offs_ptr + row + 1)[]) - start
                var idx = Int(UInt64(fp) & mask)
                while True:
                    var cur = slots[idx]
                    if cur == Int64(0):
                        slots[idx] = packed
                        distinct += 1
                        break
                    if _cdstr_fp(cur) == fp:
                        # The fingerprint is a GATE, never the answer: confirm
                        # with the bytes before collapsing two values into one.
                        var crow = _cdstr_row(cur)
                        var cstart = Int((offs_ptr + crow)[])
                        var clen = Int((offs_ptr + crow + 1)[]) - cstart
                        if clen == vlen and bytes_equal(
                            Span(unsafe_ptr=data_ptr + cstart, length=clen),
                            Span(unsafe_ptr=data_ptr + start, length=vlen),
                        ):
                            break
                    idx = Int((UInt64(idx) + UInt64(1)) & mask)
            # Release this scan task's partition-p buffer the instant it has
            # been consumed, on THIS worker while the pages are hot, rather
            # than leaving all `ns * np` of them for the driver to free
            # serially. Same index `p`, so the disjointness argument above is
            # unchanged. (Freeing many small buffers serially is slow.)
            var dead = List[Int64]()
            swap(sp[].matrix[][s][p], dead)
            _ = dead^

        sp[].counts[][p] = Int64(distinct)
        _ = slots^

    def __keep_alive(mut self):
        pass


# =============================================================================
# §4 — the serial reference walk (small inputs, single worker, and the oracle)
# =============================================================================


def _cdstr_count_serial[
    OffsetType: DType,
](imm batch: RecordBatch, col_idx: Int, n_rows: Int) raises -> Int64:
    """Exact distinct count of the non-null values, serial. Same hash, same
    verify, ONE table — the small-input arm, and the independent-of-dispatch
    reference the byte-equivalence oracle drives directly."""
    if n_rows <= 0:
        return Int64(0)
    ref col = batch.column_at(col_idx)
    var has_nulls = col.null_count() != 0
    var data_view = col._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[OffsetType]]()

    var cap = _cdstr_next_pow2(n_rows * 2)
    if cap < 16:
        cap = 16
    var mask = UInt64(cap - 1)
    var slots = List[Int64](capacity=cap)
    for _ in range(cap):
        slots.append(Int64(0))

    var distinct = 0
    for row in range(n_rows):
        if has_nulls and col.is_null_at(row):
            continue
        var start = Int((offs_ptr + row)[])
        var vlen = Int((offs_ptr + row + 1)[]) - start
        var h = xxhash64(data_ptr + start, vlen)
        var fp = UInt32(h & UInt64(0xFFFF_FFFF))
        var packed = _cdstr_pack(fp, row)
        var idx = Int(UInt64(fp) & mask)
        while True:
            var cur = slots[idx]
            if cur == Int64(0):
                slots[idx] = packed
                distinct += 1
                break
            if _cdstr_fp(cur) == fp:
                var crow = _cdstr_row(cur)
                var cstart = Int((offs_ptr + crow)[])
                var clen = Int((offs_ptr + crow + 1)[]) - cstart
                if clen == vlen and bytes_equal(
                    Span(unsafe_ptr=data_ptr + cstart, length=clen),
                    Span(unsafe_ptr=data_ptr + start, length=vlen),
                ):
                    break
            idx = Int((UInt64(idx) + UInt64(1)) & mask)
    _ = slots^
    return Int64(distinct)


# =============================================================================
# §5 — the driver
# =============================================================================


def cd_string_value_hash(imm value: String) -> UInt64:
    """The kernel's own hash of one value's bytes.

    ⚠ EXPOSED FOR ONE REASON: the collision pin. The 32-bit fingerprint this
    kernel probes on is a GATE that a byte compare confirms, and the only test
    that can prove the compare is load-bearing is one driven by an ACTUAL
    fingerprint collision. A test that hard-codes a colliding pair is asserting
    a property of THIS function, so it must be able to re-derive that property
    rather than trust a comment — otherwise a change of hash silently turns the
    strongest arm in the file into two ordinary values.

    Not on any hot path: the kernel hashes Arrow buffers directly and never
    builds a `String`."""
    var b = value.as_bytes()
    # SAFETY: `b` is a Span over `value`'s own bytes, alive for this call; the
    # pointer never escapes and nothing is written through it.
    return xxhash64(b.unsafe_ptr(), len(b))


def cd_string_column_supported(at: ArrowType) -> Bool:
    """The type envelope, in ONE place, readable by the caller BEFORE it
    commits to this kernel. STRING and LARGE_STRING only — the two layouts
    whose `(offsets, data)` pair this file strides."""
    return at == ArrowType.STRING or at == ArrowType.LARGE_STRING


def cdstr_scan_slices[
    OffsetType: DType,
](
    imm batch: RecordBatch,
    col_idx: Int,
    n_rows: Int,
    nw: Int,
    bytebal: Bool,
) raises -> List[_CdStrSlice]:
    """Phase 1's row slices: `nw` equal-row slices (`bytebal=False`), or `_CDSTR_TILES_PER_WORKER *
    nw` slices of ~equal `payload + _CDSTR_ROW_COST_BYTES * rows` cost.

    Either way the slices are non-empty, contiguous, ascending and exactly
    cover `[0, n_rows)`. The offsets are read through `get_typed` at the SAME
    row index the scan task strides (`offs_ptr + row`), so the cost model and
    the scan agree on what a row's bytes are."""
    var slices = List[_CdStrSlice]()
    if n_rows <= 0:
        return slices^
    var w = nw
    if w < 1:
        w = 1
    if not bytebal:
        var chunk = (n_rows + w - 1) // w
        if chunk < 1:
            chunk = 1
        var off = 0
        while off < n_rows:
            var hi = off + chunk
            if hi > n_rows:
                hi = n_rows
            slices.append(_CdStrSlice(off, hi))
            off = hi
        return slices^

    var tiles = w * _CDSTR_TILES_PER_WORKER
    if tiles > n_rows:
        tiles = n_rows
    ref col = batch.column_at(col_idx)
    ref offs = col._offsets.value()
    var base = Int(offs.get_typed[Scalar[OffsetType]](0))
    var total = (
        Int(offs.get_typed[Scalar[OffsetType]](n_rows)) - base
        + _CDSTR_ROW_COST_BYTES * n_rows
    )
    var lo_row = 0
    for t in range(1, tiles):
        var target = (t * total) // tiles
        # Smallest R in [lo_row, n_rows] with cost(R) >= target. cost is
        # monotone in R and cost(n_rows) == total >= target, so `hi` is a
        # valid answer and the search is well-founded.
        var lo = lo_row
        var hi = n_rows
        while lo < hi:
            var mid = (lo + hi) // 2
            var c = (
                Int(offs.get_typed[Scalar[OffsetType]](mid)) - base
                + _CDSTR_ROW_COST_BYTES * mid
            )
            if c >= target:
                hi = mid
            else:
                lo = mid + 1
        if lo > lo_row and lo < n_rows:
            slices.append(_CdStrSlice(lo_row, lo))
            lo_row = lo
    slices.append(_CdStrSlice(lo_row, n_rows))
    return slices^


def _cdstr_drive[
    OffsetType: DType,
](
    imm batch: RecordBatch,
    col_idx: Int,
    n_rows: Int,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    bytebal: Bool,
) raises -> Int64:
    """Width-parameterized body. One instantiation per offsets layout."""
    var nw = dispatcher.worker_count()
    if nw < 1:
        nw = 1
    if nw == 1 or n_rows < _CDSTR_MIN_ROWS:
        _ = cancel_token^
        return _cdstr_count_serial[OffsetType](batch, col_idx, n_rows)

    var np = _cdstr_partition_count(n_rows, nw)
    var k = 0
    var tmp = np
    while tmp > 1:
        k += 1
        tmp >>= 1
    var shift = 64 - k  # top-k bits of the 64-bit hash select the partition

    # Cost-balanced slices — see the block above `_CDSTR_TILES_PER_WORKER`.
    var slices = cdstr_scan_slices[OffsetType](
        batch, col_idx, n_rows, nw, bytebal
    )
    var ns = len(slices)

    var matrix = List[List[List[Int64]]]()
    for _ in range(ns):
        matrix.append(List[List[Int64]]())

    ref col0 = batch.column_at(col_idx)
    # `!= 0`, not `> 0`: an UNCOMPUTED null count (-1) must take the
    # CHECKING arm, which is correct for a null-free column too, merely slower.
    var has_nulls = col0.null_count() != 0

    # PARALLELIZE-BOUNDARY (phase 1: scan + hash + scatter).
    # Disjointness: scan task `s` writes ONLY `matrix[s]` (pre-sized outer slot)
    #   and reads only its own row slice; `batch` / `slices` are immutable.
    # Liveness: `batch` and `slices` outlive the dispatch — `run_with_state`'s
    #   drain barrier joins every task before this frame proceeds; the State
    #   owns `matrix`.
    # No-realloc: `matrix`'s outer is pre-sized to `ns` and the task write is a
    #   slot MOVE, never an append. `slices` is built before the dispatch and
    #   is read-only inside it.
    # No-reload: the State is a KeepAlive with inline Pointers + POD scalars.
    comptime ScanT = _CDStrScanState[origin_of(batch), origin_of(slices)]
    comptime ScanTaskT = _CDStrScanTask[
        OffsetType, origin_of(batch), origin_of(slices)
    ]
    var sstate = ScanT(batch, slices, matrix^, col_idx, np, shift, has_nulls)
    var stask = ScanTaskT(_pad=Int32(0))
    var _sb = dispatcher.run_with_state[ScanT, ScanTaskT](
        sstate, stask^, ns, cancel_token.clone(), site_id=SITE_CD_RADIX
    )
    _ = _sb^
    var scanned = List[List[List[Int64]]]()
    swap(sstate.matrix[], scanned)
    _ = sstate^

    var counts = List[Int64](length=np, fill=Int64(0))

    # PARALLELIZE-BOUNDARY (phase 2: per-partition dedup).
    # Disjointness: dedup task `p` touches column `matrix[*][p]` and ONLY
    #   `counts[p]`. Equal values share a partition by hash, so no value appears
    #   in two partitions and the per-partition sets never overlap. The reclaim
    #   uses the SAME index `p`.
    # Liveness: the State owns `matrix` / `counts`; `batch` outlives the
    #   dispatch (drain barrier).
    # No-realloc: `matrix`'s outer and inner Lists are fully populated by phase
    #   1 and are only ELEMENT-ASSIGNED here (a slot swap at index `p`), never
    #   appended to. `counts` is pre-sized to `np`.
    # No-reload: the State is a KeepAlive with inline Pointers.
    comptime DedT = _CDStrDedupState[origin_of(batch)]
    comptime DedTaskT = _CDStrDedupTask[OffsetType, origin_of(batch)]
    var dstate = DedT(batch, scanned^, counts^, col_idx, ns)
    var dtask = DedTaskT(_pad=Int32(0))
    var _db = dispatcher.run_with_state[DedT, DedTaskT](
        dstate, dtask^, np, cancel_token^, site_id=SITE_CD_RADIX
    )
    _ = _db^

    var total = Int64(0)
    for p in range(np):
        total += dstate.counts[][p]
    _ = dstate^
    _ = col0.length()
    return total


def count_distinct_string_column(
    imm batch: RecordBatch,
    col_idx: Int,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    bytebal: Bool = True,
) raises -> Int64:
    """Exact `count(DISTINCT <col>)` over a resident STRING / LARGE_STRING
    column — NULLs excluded, per SQL.

    Answers with a COUNT and nothing else: no `String` is ever materialised, no
    distinct-value column is built, and the input buffers are read in place.
    Parallel over the pool when the row count justifies the two dispatches;
    otherwise the serial arm, which computes the identical number.

    RAISES on a type outside `cd_string_column_supported` — fail-closed, so a
    future detector regression is a refusal and not a wrong answer.

    `bytebal` cuts the parallel scan into cost-balanced slices (the default)
    or into one equal-row slice per worker; the count is the same."""
    var n_rows = batch.num_rows()
    ref col = batch.column_at(col_idx)
    var at = col.arrow_type
    if not cd_string_column_supported(at):
        raise Error(
            "cd_string_parallel: COUNT(DISTINCT) over a resident column"
            " requires STRING or LARGE_STRING; got type id "
            + String(at.type_id)
        )
    if n_rows > _CDSTR_MAX_ROWS:
        # The packed entry carries the row ordinal in 32 bits. Refuse rather
        # than truncate: a truncated ordinal would verify against the WRONG
        # span and could collapse two distinct values.
        raise Error(
            "cd_string_parallel: resident batch has "
            + String(n_rows)
            + " rows, above the 32-bit row ordinal this kernel packs"
        )
    # ⭐ THE ROUTE WITNESS. Incremented only once both refusals are past, so a
    # REFUSED call is never counted as an answer this kernel served.
    cd_string_kernel_taken_incr()
    if at == ArrowType.LARGE_STRING:
        return _cdstr_drive[DType.int64](
            batch, col_idx, n_rows, dispatcher, cancel_token^, bytebal
        )
    return _cdstr_drive[DType.int32](
        batch, col_idx, n_rows, dispatcher, cancel_token^, bytebal
    )


def count_distinct_string_column_serial(
    imm batch: RecordBatch, col_idx: Int
) raises -> Int64:
    """The serial arm, reachable by name. Exists for the byte-equivalence
    oracle: a differential between two implementations is only evidence if the
    test can call BOTH without going through the route that chooses between
    them."""
    var n_rows = batch.num_rows()
    ref col = batch.column_at(col_idx)
    var at = col.arrow_type
    if not cd_string_column_supported(at):
        raise Error(
            "cd_string_parallel: COUNT(DISTINCT) over a resident column"
            " requires STRING or LARGE_STRING; got type id "
            + String(at.type_id)
        )
    if at == ArrowType.LARGE_STRING:
        return _cdstr_count_serial[DType.int64](batch, col_idx, n_rows)
    return _cdstr_count_serial[DType.int32](batch, col_idx, n_rows)
