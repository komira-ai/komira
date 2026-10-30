# =============================================================================
# join_probe_op_state -- what the streaming single-key join probe
# (`JoinProbeOp`) keeps between calls, and the helpers its arms share.
# =============================================================================
#
#   * the per-worker resume slots (`ColumnarProbeSharedState`, one
#     `ProbeWorkerState` per worker, shared by the workers' operators behind
#     an `ArcPointer`; worker `w` touches only slot `w`);
#   * the probe strategy tags a driver picks once, at build time;
#   * the selection-mask walks: a probe morsel may carry a reader-deferred
#     selection mask, and a masked-out probe row contributes no pair;
#   * the probe-key acquisition: the key column SHARED as an INT64 array when
#     it has no validity bitmap, else copied (the copy also rebases the
#     validity bitmap, which a share cannot);
#   * `SingleKeyCse`, the JOIN-KEY CSE latch of one operator: the output's
#     build key column may share the probe key column on an INNER join, as
#     proved by `join_key_cse_aliases` on the first morsel and re-checked
#     against each later morsel's probe-side facts.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from komira_plan_ir.logical_plan import JOIN_INNER
from komira_join_assembly.join_key_cse import (
    JoinKeyAliasMap,
    join_key_cse_aliases,
)
from komira_op_join_build.join import PROBE_CHUNK_SIZE, ProbeInnerState

from .join_probe_levers import (
    join_key_share_note_declined,
    join_key_share_note_shared,
)


comptime STRATEGY_STANDARD: UInt8 = 0
"""The chained hash table, probed in bounded chunks (resumable)."""
comptime STRATEGY_PERFECT: UInt8 = 1
"""A perfect-hash table (dense unique integer build keys): one lookup per
probe row, so a morsel's output fits in one batch."""
comptime STRATEGY_RADIX: UInt8 = 2
"""A radix-partitioned table, for build sides too large for the chained one."""


struct ProbeWorkerState(Movable):
    """One worker's resume slot.

    `pending` is the probe morsel being drained while `has_pending`;
    `probe_state` is the chained probe's cursor into it. `build_matches` and
    `probe_matches` are the worker's reusable chunk buffers, used only when
    buffer reuse is on (`join_probe_buf_reuse_configure`).
    """

    var has_pending: Bool
    var pending: RecordBatch
    var probe_state: ProbeInnerState
    var build_matches: List[Int]
    var probe_matches: List[Int]

    def __init__(out self):
        self.has_pending = False
        self.pending = RecordBatch()
        self.probe_state = ProbeInnerState()
        self.build_matches = List[Int](capacity=PROBE_CHUNK_SIZE)
        self.probe_matches = List[Int](capacity=PROBE_CHUNK_SIZE)

    def clear(mut self):
        """Ready the slot for a fresh morsel; the buffers keep their room."""
        self.has_pending = False
        self.pending = RecordBatch()
        self.probe_state = ProbeInnerState()


struct ColumnarProbeSharedState(Movable):
    """The workers' resume slots, one per worker."""

    var worker_slab: Slab[ProbeWorkerState]
    var num_slots: Int

    def __init__(out self, var worker_slab: Slab[ProbeWorkerState], num_slots: Int):
        self.worker_slab = worker_slab^
        self.num_slots = num_slots


def build_shared_probe_state(
    num_workers: Int,
) raises -> ArcPointer[ColumnarProbeSharedState]:
    """`max(num_workers, 1)` empty resume slots, to be shared by the
    workers' operators (`JoinProbeOp(shared=..., local_id=w)`)."""
    var n = max(num_workers, 1)
    var slab = Slab[ProbeWorkerState].create(n)
    for _ in range(n):
        slab.append(ProbeWorkerState())
    return ArcPointer[ColumnarProbeSharedState](
        ColumnarProbeSharedState(slab^, n)
    )


def ensure_chunk_scratch(mut lst: List[Int]) raises:
    """Make `lst` `PROBE_CHUNK_SIZE` entries long (uninitialized). Its
    capacity is already that, so this never reallocates after the first
    call."""
    if len(lst) < PROBE_CHUNK_SIZE:
        lst.resize(unsafe_uninit_length=PROBE_CHUNK_SIZE)


def sel_keep_pair(
    mut build_m: List[Int], mut probe_m: List[Int], imm batch: RecordBatch
) raises:
    """Drop the (build, probe) pairs whose probe row `batch`'s selection mask
    excludes, keeping the order. Nothing to do without a mask."""
    if not batch.has_selection_mask():
        return
    var w = 0
    var n = len(probe_m)
    for r in range(n):
        var pr = probe_m[r]
        if batch.selection_mask_get(pr):
            build_m[w] = build_m[r]
            probe_m[w] = pr
            w += 1
    build_m.resize(w, 0)
    probe_m.resize(w, 0)


def sel_keep_single(mut idx: List[Int], imm batch: RecordBatch) raises:
    """Drop the probe rows `batch`'s selection mask excludes, keeping the
    order. Nothing to do without a mask."""
    if not batch.has_selection_mask():
        return
    var w = 0
    for r in range(len(idx)):
        var v = idx[r]
        if batch.selection_mask_get(v):
            idx[w] = v
            w += 1
    idx.resize(w, 0)


def acquire_probe_key(
    imm col: Column[HeapRegion],
) raises -> PrimitiveArray[DType.int64]:
    """The probe key column as an INT64 array: shared (carrying the column's
    offset) when it admits it, else the `as_primitive` copy. Every probe
    kernel reads the array only, through offset-aware accessors. The two
    routes are counted (`join_probe_levers`)."""
    if col.can_share_as_primitive[DType.int64]():
        join_key_share_note_shared()
        return col.share_as_primitive[DType.int64]()
    join_key_share_note_declined(col.has_validity_buffer())
    return col.as_primitive[DType.int64]()


struct SingleKeyCse(Movable):
    """One operator's JOIN-KEY CSE latch (see the module header).

    `state` is 0 before the first INNER morsel, 1 when `map` holds a proved
    alias map, -1 when the proof was refused (kept for the operator's life).
    """

    var state: Int
    var map: Optional[JoinKeyAliasMap]
    var probe_key_idx: Int
    var probe_ncols: Int
    var probe_key_type: ArrowType
    var probe_key_has_bitmap: Bool

    def __init__(out self):
        self.state = 0
        self.map = Optional[JoinKeyAliasMap](None)
        self.probe_key_idx = -1
        self.probe_ncols = -1
        self.probe_key_type = ArrowType.NULL
        self.probe_key_has_bitmap = False

    def admits(
        mut self,
        imm probe_batch: RecordBatch,
        left_key_idx: Int,
        imm build_batch: RecordBatch,
        left_key_name: String,
        right_key_name: String,
        join_type: UInt8,
    ) raises -> Bool:
        """True iff this morsel's assembly may take `map`.

        Only for INNER (a LEFT join's build key is NULL exactly where the
        probe key is not). The first call proves the map; later calls
        compare the probe key's column index, the column count, the key's type
        and validity-bitmap presence, and require no NULL in it: a morsel that
        differs is gathered. `join_type` is passed to the proof as well, so
        its own join-type refusal stays an independent check.
        """
        if join_type != JOIN_INNER:
            return False
        if self.state < 0:
            return False
        if self.state == 0:
            var lk = List[String]()
            lk.append(left_key_name)
            var rk = List[String]()
            rk.append(right_key_name)
            var m = join_key_cse_aliases(
                probe_batch, build_batch, lk, rk, join_type
            )
            if len(m) == 0:
                self.state = -1
                return False
            ref pk0 = probe_batch.column_at(left_key_idx)
            self.probe_key_idx = left_key_idx
            self.probe_ncols = probe_batch.num_columns()
            self.probe_key_type = pk0.arrow_type
            self.probe_key_has_bitmap = pk0.has_validity_buffer()
            self.map = Optional[JoinKeyAliasMap](m^)
            self.state = 1
            return True
        if left_key_idx != self.probe_key_idx:
            return False
        if probe_batch.num_columns() != self.probe_ncols:
            return False
        ref pk = probe_batch.column_at(left_key_idx)
        if pk.arrow_type != self.probe_key_type:
            return False
        if pk.has_validity_buffer() != self.probe_key_has_bitmap:
            return False
        if pk.has_validity_buffer() and pk.null_count() != 0:
            return False
        return True
