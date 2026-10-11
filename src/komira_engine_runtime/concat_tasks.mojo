# =============================================================================
# concat_tasks: the dispatch states and tasks of the parallel concat.
# =============================================================================
#
# `_ConcatColumnsState` / `_ConcatColumnsTask`: one task per output column.
# `_ConcatTiledState` / `_ConcatWork` / `_ConcatTiledTask`: one task per
# `(column, row range)` tile. Each state owns its per-dispatch allocations
# (the input batches are moved in before the dispatch) through `OwnedPointer`;
# no state holds a borrowed pointer or a wildcard origin. Each task is a POD
# `Segment` that reaches its state through the concrete-type restore the
# dispatcher's `run_with_state` contract defines.
# =============================================================================

from std.collections.optional import Optional
from std.memory import (
    alloc,
    OwnedPointer,
    UnsafePointer,
)
from komira_atomic_alias import AtomicI8
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_arrow.column import Column
from komira_collections.slab import Slab
from komira_arrow.streaming_concat import (
    _concat_fixed_columns_multi,
    _concat_string_columns_multi,
    _concat_slow_column_pairwise,
    _concat_fixed_column_into_range,
    _concat_string_column_into_range,
    _build_fixed_validity,
    _sum_fixed_null_count,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_async_api.worker_pool_traits import (
    KeepAlive,
    Segment,
)
from komira_buffer.heap_region import HeapRegion

# =============================================================================
# _ConcatColumnsState — per-dispatch state (KeepAlive)
# =============================================================================


struct _ConcatColumnsState(KeepAlive, Movable):
    """State for column-parallel `RecordBatch` concat dispatch.

    Owned by the driver (`concat_record_batches_column_parallel`) for
    the lifetime of a single `run_with_state` dispatch and destroyed
    at function exit. Movable — every field is itself Movable
    (`OwnedPointer`).

    No wildcard-origin fields. The input `Slab[Optional[RecordBatch]]`
    is MOVED INTO the State before dispatch, so the State owns it
    outright; per-dispatch heap allocations live on the State as
    `OwnedPointer`-wrapped values.
    """
    # OWNED input slab on the heap. Workers read `sp[].input_batches[]
    # [batch_idx]` (an Optional[RecordBatch] ref). They never mutate
    # this slab during the dispatch window — only the driver pulls
    # batches out via `_take_slab` afterwards (defensively, the
    # slab's destructor drops any remaining batches).
    var input_batches: OwnedPointer[Slab[Optional[RecordBatch]]]

    # OWNED output `Slab[Column]` on the heap. Pre-sized to num_cols
    # and pre-filled with empty `Column()` placeholders. Workers
    # mutate `sp[].columns[][col_idx] = concatted^` via `__setitem__`
    # (destroy-then-init semantics on a live slot). No length change
    # across the dispatch window. The driver pulls the Slab back out
    # of the OwnedPointer's heap slot via `_take_slab` (a swap against an
    # empty slab).
    var columns: OwnedPointer[Slab[Column[HeapRegion]]]

    # OWNED heap Atomic[int8] error flag. Atomic is non-Movable, so it is
    # constructed in place (`init_pointee_move(Scalar(0))`).
    var err_flag: OwnedPointer[AtomicI8]

    # OWNED heap String carrying the captured error message.
    var err_msg: OwnedPointer[String]

    def __init__(
        out self,
        var input_batches: Slab[Optional[RecordBatch]],
        var columns: Slab[Column[HeapRegion]],
    ):
        # OwnedPointer[Slab[Optional[RecordBatch]]]: Slab is Movable;
        # construct on the heap via init_pointee_move.
        var iraw = alloc[Slab[Optional[RecordBatch]]](1)
        iraw.unsafe_write(input_batches^)
        self.input_batches = OwnedPointer[Slab[Optional[RecordBatch]]](
            unsafe_from_raw_pointer=iraw
        )

        # OwnedPointer[Slab[Column]]: Slab is Movable; same pattern.
        var craw = alloc[Slab[Column[HeapRegion]]](1)
        craw.unsafe_write(columns^)
        self.columns = OwnedPointer[Slab[Column[HeapRegion]]](
            unsafe_from_raw_pointer=craw
        )

        # OwnedPointer[Atomic[...]]: Atomic is non-Movable; construct
        # in place via init_pointee_move on the inner `.value` slot.
        var raw = alloc[AtomicI8](1)
        raw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=raw
        )

        # OwnedPointer[String]: String is Movable; init via
        # init_pointee_move(String("")).
        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)


# =============================================================================
# _ConcatColumnsTask — POD Segment, one task per output column
# =============================================================================


@fieldwise_init
struct _ConcatColumnsTask(Segment):
    """POD Segment for `_ConcatColumnsState` dispatch — one task per
    column. Carries only an Int32 pad; the heavy state is on the
    borrowed State.
    """
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the caller parameterizes run_with_state over
        # (_ConcatColumnsState, _ConcatColumnsTask), so the bitcast
        # resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[_ConcatColumnsState]()
        var col_idx = Int(task_id)

        # Short-circuit: another task already failed.
        if sp[].err_flag[].load() != Int8(0):
            return

        try:
            # Acquire a typed pointer into the State-owned input slab.
            # SAFETY: `sp[].input_batches` is a live OwnedPointer; its
            # pointee is a live Slab[Optional[RecordBatch]] populated by
            # the driver before dispatch. `get_mut_interior(0)` returns
            # a ref into the slab's interior buffer; `UnsafePointer(to=
            # ref)` lifts the ref to a pointer with a concrete origin
            # rooted at the slab. The pointer is valid for the full
            # dispatch window (the slab's heap allocation cannot move
            # during the barrier).
            ref input_slab = sp[].input_batches[]
            var num_b = len(input_slab)
            if num_b == 0:
                return

            ref slot0 = input_slab.get_mut_interior(0)
            var staging_ptr = UnsafePointer(to=slot0)

            # Find the first non-empty batch to read the type from.
            var schema_idx = -1
            for i in range(num_b):
                if (staging_ptr + i)[]:
                    schema_idx = i
                    break
            if schema_idx < 0:
                return

            var at = (staging_ptr + schema_idx)[].value().column_at(col_idx).arrow_type
            var concatted: Column[HeapRegion]
            # ★ THE SLOW ARM IS WHAT LETS THIS TASK RUN AT ALL FOR A BATCH
            # CARRYING A DICTIONARY. Before
            # it, the driver's admission gate carried `not any_slow`, so ONE
            # BOOL/DICTIONARY column made the WHOLE batch serial and no worker
            # was ever dispatched. The gate is relaxed per column now; without
            # this arm a dictionary column would reach the fixed-width kernel,
            # which reports width 0 and raises "unsupported type".
            if at == ArrowType.BOOL or at == ArrowType.DICTIONARY:
                concatted = _concat_slow_column_pairwise(
                    staging_ptr, num_b, col_idx
                )
            elif at == ArrowType.STRING or at == ArrowType.BINARY:
                concatted = _concat_string_columns_multi(
                    staging_ptr, num_b, col_idx
                )
            else:
                concatted = _concat_fixed_columns_multi(
                    staging_ptr, num_b, col_idx, at
                )

            # Write into the disjoint slot through the OwnedPointer
            # dereference. `state.columns[]` returns a mutable ref to
            # the heap-owned Slab; `[col_idx] =` goes through Slab
            # __setitem__ (destroy-then-init on a live slot). No
            # length change — the slab was pre-sized in the driver.
            sp[].columns[][col_idx] = concatted^
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                # In-place move-assign through the OwnedPointer: the
                # pointee's old String is destroyed and the new one is
                # moved into the same heap slot.
                sp[].err_msg[] = String(e)


# =============================================================================
# Row-range tiled concat — State / work-item / Task / driver
# =============================================================================


@fieldwise_init
struct _ConcatWork(Copyable, Movable):
    """One tiled-concat work item.

    `kind == 0` → fixed-width row-range tile (copy OUTPUT rows
    [row_start, row_end) of column `col_idx` into the pre-sized
    `fixed_bufs[col_idx]` slice).
    `kind == 1` → STRING/BINARY WHOLE-COLUMN concat (build the Column, write it
    into `out_columns[col_idx]`). Retained as the `ConcatOptions.string_tiling=False`
    arm and as the byte-equivalence oracle for kind 3.
    `kind == 2` → column `col_idx`'s VALIDITY bitmap + null count (write
    `out_validity[col_idx]` / `out_nulls[col_idx]`).
    `kind == 3` → STRING/BINARY row-range tile (LEVER A): copy OUTPUT rows
    [row_start, row_end) of column `col_idx` into the pre-sized
    `fixed_bufs[col_idx]` (payload) + `str_off_bufs[col_idx]` (int32 offsets).

    ★ KIND 2 IS TYPE-AGNOSTIC AND IS REUSED FOR STRING COLUMNS UNCHANGED — this
    is why LEVER A needs no validity design of its own. `_build_fixed_validity`
    reads only `_validity` / `_offset` / `_length`, none of which is layout-
    specific, and it produces the SAME BYTES as the string helper's own pass:
    both seed all-valid (`create_all_valid`'s memset-0xFF-then-mask-trailing vs
    `create`-zero-then-set-every-bit — identical over [0, num_bytes), trailing
    padding bits included), both overwrite only from batches that carry a
    bitmap, and both leave rows from bitmap-less batches valid.
    `_sum_fixed_null_count` likewise just sums `_null_count`. Guarded by T5/T8
    of `test_concat_rowrange_tile_byte_equiv`, which are the first tests in the
    tree to compare the two constructions against each other.

    ★ WHY KIND 2 EXISTS, AND IT IS THE WHOLE REASON THIS PATH USED TO LOSE.
    The validity/null-count pass used to run SERIALLY on the driver after the
    barrier, on the argument that a 1-bit-per-row buffer is "not worth
    parallelizing". MEASURED on q21 (`KOMIRA_SCHED_TRACE=1`, 6 reps): the
    resulting `concat_tiled_assemble` bracket read **117.66 ms over 14 calls
    with `fork_ns=0`** — 8.79% of worker wall, entirely serial — against
    `concat_cols_assemble`'s **0.81 ms** of serial for 20 calls of the incumbent
    path, which does the same work INSIDE its per-column worker task. Tiling the
    data copy while serializing the validity pass moved work from parallel to
    serial, and the net was a MEASURED +4.65% REGRESSION on q21 (0 of 15 rounds,
    exact paired permutation p = 6.1e-05).

    ⚠ THIS ALSO RE-READS THE "MEASURED FLAT, BANDWIDTH-BOUND"
    VERDICT. That A/B ran on this same shape, and the brackets that show the
    serialization did not exist — so the flatness it attributed
    to DRAM bandwidth was at least partly this. A mechanism inferred from a flat
    wall, on a path with an unmeasured serial window in it, was never tested.

    A kind-2 item is independent of every kind-0 tile of the same column: it
    reads the input batches (read-only) and writes a DIFFERENT destination (the
    validity slot, never the value buffer), so it needs no ordering against
    them and lives in the SAME fork rather than in a second wave."""
    var col_idx: Int32
    var kind: UInt8
    var row_start: Int
    var row_end: Int


struct _ConcatTiledState(KeepAlive, Movable):
    """State for the row-range TILED `RecordBatch` concat dispatch.

    Same wildcard-free shape as `_ConcatColumnsState` (heap-owning values via
    `OwnedPointer`, input slab MOVED in so the State owns it outright). The
    read-only tiling metadata (`work_items` / `batch_row_offset` / `col_width`)
    lives as direct `List` fields — they are written ONCE by the driver before
    dispatch and only READ by workers (via the bitcast-to-concrete pointer), so
    no per-dispatch heap indirection is needed.
    """
    # OWNED input slab (workers read `input_batches[][batch][col]` refs).
    var input_batches: OwnedPointer[Slab[Optional[RecordBatch]]]

    # OWNED output Column slab — STRING/BINARY whole-column tasks write their
    # built Column into `out_columns[][col]` via __setitem__ (disjoint slot);
    # fixed-width columns leave the placeholder untouched (assembled from
    # `fixed_bufs` on the driver).
    var out_columns: OwnedPointer[Slab[Column[HeapRegion]]]

    # OWNED per-column destination VALUE buffers, pre-sized to total_rows*width
    # (fixed) or to the column's total payload bytes (STRING/BINARY under LEVER
    # A). Row-range tiles write DISJOINT byte slices of the SAME buffer (no
    # realloc, no metadata mutation during dispatch). A STRING column on the
    # whole-column route (`ConcatOptions.string_tiling=False`) gets a length-0
    # placeholder here — its Column is built entire by the kind-1 task.
    var fixed_bufs: OwnedPointer[Slab[OwnedAlignedBuffer]]

    # OWNED per-STRING/BINARY-column destination OFFSETS buffers, pre-sized to
    # (total_rows + 1) * 4 bytes, with slot 0 written by the DRIVER before
    # dispatch. A kind-3 tile writes slots [row_start+1, row_end] only; the tile
    # ranges partition [1, total_rows], so no two tiles share a slot. Fixed and
    # whole-column-string columns get a length-0 placeholder.
    var str_off_bufs: OwnedPointer[Slab[OwnedAlignedBuffer]]

    # OWNED per-fixed-width-column VALIDITY bitmaps + null counts, written by
    # the kind-2 work items (one per fixed column, disjoint slot each) and read
    # by the driver after the barrier. Pre-sized to num_cols and pre-filled with
    # `None` / 0; STRING columns' slots are never touched (their Column carries
    # its own validity, built inside the kind-1 task).
    var out_validity: OwnedPointer[Slab[Optional[Bitmap[HeapRegion]]]]
    var out_nulls: OwnedPointer[Slab[Int]]

    # Read-only tiling metadata (driver-written before dispatch).
    var work_items: List[_ConcatWork]
    var batch_row_offset: List[Int]
    var col_width: List[Int]
    # Per-column per-batch destination BYTE prefix for STRING/BINARY columns on
    # the kind-3 route (`num_batches + 1` entries, last = the column total);
    # EMPTY for every other column. Built once on the driver in O(num_batches)
    # from the two Int32 per batch that scan 1 of the whole-column helper
    # already reads — see `_string_batch_byte_prefix`.
    var str_byte_prefix: List[List[Int]]

    # OWNED heap error channel (mirrors `_ConcatColumnsState`).
    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    def __init__(
        out self,
        var input_batches: Slab[Optional[RecordBatch]],
        var out_columns: Slab[Column[HeapRegion]],
        var fixed_bufs: Slab[OwnedAlignedBuffer],
        var str_off_bufs: Slab[OwnedAlignedBuffer],
        var out_validity: Slab[Optional[Bitmap[HeapRegion]]],
        var out_nulls: Slab[Int],
        var work_items: List[_ConcatWork],
        var batch_row_offset: List[Int],
        var col_width: List[Int],
        var str_byte_prefix: List[List[Int]],
    ):
        var iraw = alloc[Slab[Optional[RecordBatch]]](1)
        iraw.unsafe_write(input_batches^)
        self.input_batches = OwnedPointer[Slab[Optional[RecordBatch]]](
            unsafe_from_raw_pointer=iraw
        )

        var oraw = alloc[Slab[Column[HeapRegion]]](1)
        oraw.unsafe_write(out_columns^)
        self.out_columns = OwnedPointer[Slab[Column[HeapRegion]]](
            unsafe_from_raw_pointer=oraw
        )

        var fraw = alloc[Slab[OwnedAlignedBuffer]](1)
        fraw.unsafe_write(fixed_bufs^)
        self.fixed_bufs = OwnedPointer[Slab[OwnedAlignedBuffer]](
            unsafe_from_raw_pointer=fraw
        )

        var sraw = alloc[Slab[OwnedAlignedBuffer]](1)
        sraw.unsafe_write(str_off_bufs^)
        self.str_off_bufs = OwnedPointer[Slab[OwnedAlignedBuffer]](
            unsafe_from_raw_pointer=sraw
        )

        var vraw = alloc[Slab[Optional[Bitmap[HeapRegion]]]](1)
        vraw.unsafe_write(out_validity^)
        self.out_validity = OwnedPointer[Slab[Optional[Bitmap[HeapRegion]]]](
            unsafe_from_raw_pointer=vraw
        )

        var nraw = alloc[Slab[Int]](1)
        nraw.unsafe_write(out_nulls^)
        self.out_nulls = OwnedPointer[Slab[Int]](unsafe_from_raw_pointer=nraw)

        self.work_items = work_items^
        self.batch_row_offset = batch_row_offset^
        self.col_width = col_width^
        self.str_byte_prefix = str_byte_prefix^

        var raw = alloc[AtomicI8](1)
        raw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=raw
        )

        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)


@fieldwise_init
struct _ConcatTiledTask(Segment):
    """POD Segment for `_ConcatTiledState` dispatch — one task per work item
    (a fixed-width row-range tile OR a whole STRING/BINARY column)."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the caller parameterizes run_with_state over
        # (_ConcatTiledState, _ConcatTiledTask), so the bitcast resolves to the
        # concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[_ConcatTiledState]()

        # Short-circuit: another task already failed.
        if sp[].err_flag[].load() != Int8(0):
            return

        try:
            ref w = sp[].work_items[Int(task_id)]
            var col = Int(w.col_idx)

            ref input_slab = sp[].input_batches[]
            var num_b = len(input_slab)
            if num_b == 0:
                return

            # SAFETY: `input_batches` is a live OwnedPointer; its pointee is the
            # driver-populated Slab. `get_mut_interior(0)` returns a ref into the
            # slab's interior buffer; `UnsafePointer(to=ref)` lifts it to a
            # concrete-origin pointer rooted at the slab, valid for the whole
            # dispatch window (the heap allocation cannot move during the
            # barrier). Read-only use here (the concat helpers only read).
            ref slot0 = input_slab.get_mut_interior(0)
            var staging_ptr = UnsafePointer(to=slot0)

            if w.kind == UInt8(1):
                # STRING / BINARY whole-column concat → disjoint output slot.
                var concatted = _concat_string_columns_multi(
                    staging_ptr, num_b, col
                )
                sp[].out_columns[][col] = concatted^
            elif w.kind == UInt8(3):
                # STRING/BINARY ROW-RANGE TILE (LEVER A) → disjoint dst byte
                # slice of the payload buffer AND a disjoint run of int32
                # offset slots. Same disjointness contract as kind 0; the
                # aliased `mut` refs through the bitcast pointer are the same
                # shape and the same argument.
                ref sdbuf = sp[].fixed_bufs[].get_mut_interior(col)
                ref sobuf = sp[].str_off_bufs[].get_mut_interior(col)
                _concat_string_column_into_range(
                    staging_ptr,
                    num_b,
                    col,
                    sp[].batch_row_offset,
                    sp[].str_byte_prefix[col],
                    w.row_start,
                    w.row_end,
                    sdbuf,
                    sobuf,
                )
            elif w.kind == UInt8(2):
                # VALIDITY + NULL COUNT for column `col` (fixed-width OR
                # STRING/BINARY on the kind-3 route — the helpers are
                # type-agnostic, see the `_ConcatWork` note). Reads the
                # input batches (read-only, shared with every other task) and
                # writes ONLY `out_validity[col]` / `out_nulls[col]` — slots no
                # other work item of any kind touches. Byte-identical to the
                # driver-serial version it replaces: the SAME helpers, the same
                # arguments, in a different thread.
                sp[].out_validity[][col] = _build_fixed_validity(
                    staging_ptr,
                    num_b,
                    col,
                    w.row_end,   # total_rows (carried on the work item)
                    sp[].batch_row_offset,
                )
                sp[].out_nulls[][col] = _sum_fixed_null_count(
                    staging_ptr, num_b, col
                )
            else:
                # Fixed-width row-range tile → disjoint dst byte slice.
                var width = sp[].col_width[col]
                # SAFETY: two tiles of the same column receive an aliased `mut`
                # ref to `fixed_bufs[][col]` (through the bitcast pointer,
                # invisible to the borrow checker) but write DISJOINT byte slices
                # [row_start*width, row_end*width) — the PARALLELIZE-BOUNDARY
                # disjointness contract documented on the driver below.
                ref dbuf = sp[].fixed_bufs[].get_mut_interior(col)
                _concat_fixed_column_into_range(
                    staging_ptr,
                    num_b,
                    col,
                    width,
                    sp[].batch_row_offset,
                    w.row_start,
                    w.row_end,
                    dbuf,
                )
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
