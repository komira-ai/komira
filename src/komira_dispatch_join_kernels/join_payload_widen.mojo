# =============================================================================
# join_payload_widen -- the LEAF-EXIT half of join payload narrowing
# =============================================================================
#
# Split out of `join_payload_narrow_exec.mojo` for the 1000-line file rule.
# Read that file's header first: it states the whole design and why the leaf
# owns both halves. This file holds only the exit transform.
#
# WHAT IT DOES. `widen_payload_table_parallel` turns every column the narrow
# half compressed back into the `INT64` the leaf's caller was always going to
# be handed -- `Int64(stored) + base` -- and returns a `Table` carrying the
# BYTE-IDENTICAL schema the leaf would have returned had the lever never
# armed. Chunk boundaries, chunk order and row order are untouched.
#
# ⛔ IT MUST BE AS PARALLEL AS THE PRODUCER, AND THE TILING IS OVER
# (CHUNK x ROW RANGE), NOT OVER CHUNKS. `selection_flatten_parallel.mojo`
# records what the chunk-only spelling costs when the producer is a 20-way
# fork and the egress is not: on a high-cardinality join the same bytes took
# 336.35 ms at 66% forked and 2282.43 ms at 6% forked. That file could tile by
# chunk because its shipped input is ~6,511 chunks; THIS one cannot, because
# the same leaf returns ONE 100M-row chunk on the deferred/concat arms -- a
# chunk-only tiling would be a single-threaded 1.6 GB write on exactly the
# route the lever is measured on. So the row range is part of the work item and
# a one-chunk table forks just as wide as a 6,511-chunk one.
#
# ⚠ THE IDENTITY ARM IS THE ONE THAT MATTERS. An empty plan returns the table
# untouched with no fork, no copy and no schema rebuild, so every join in the
# corpus that this lever declines pays exactly one `plan.num_widened() == 0`
# test on its exit path.
# =============================================================================

from komira_atomic_alias import AtomicI8
from std.memory import alloc, OwnedPointer, Pointer, UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.table import Table
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_CONCAT

from komira_dispatch_join_kernels.join_payload_narrow_exec import (
    PayloadWidenPlan,
    _PN_MIN_PARALLEL_ROWS,
    _PnWork,
    _pn_widen_range,
    _tile_rows,
)


struct _PnWidenState(KeepAlive, Movable):
    """State for the leaf-exit widening fork.

    Wildcard-free, same shape as `_SelFlattenState`: heap values behind
    `OwnedPointer`, read-only per-plan metadata as direct `List` fields written
    ONCE before the fork."""

    # OWNED input chunks, in the Table's own order. Read-only to the workers.
    #
    # ⚠ A `Slab` (what `Table.take_chunks()` hands over), and the reason is
    # the REASSEMBLY rather than the fork. Moving a non-Copyable element OUT of
    # a `List` in INDEX order has no primitive, so `pop(0)` per chunk would be
    # O(n^2) -- 6,511 chunks on a large join's shipped arm.
    # `Slab.replace(k, ...)` moves slot k out in one in-order pass.
    var chunks: OwnedPointer[Slab[RecordBatch]]
    # OWNED destination buffers, one per (chunk x plan column), pre-sized.
    # Slot `k * nplan + p`. Task `t` writes elements
    # [row_start, row_end) of slot `work[t].slot` and nothing else.
    var out: OwnedPointer[Slab[OwnedAlignedBuffer]]
    var bases: List[Int64]
    var swid: List[UInt8]
    var ocol: List[Int]
    var work: List[_PnWork]
    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    def __init__(
        out self,
        var chunks: Slab[RecordBatch],
        var out: Slab[OwnedAlignedBuffer],
        var bases: List[Int64],
        var swid: List[UInt8],
        var ocol: List[Int],
        var work: List[_PnWork],
    ):
        # SAFETY: each `alloc` returns one uninitialised slot, owned by this
        # constructor until the `OwnedPointer` right after it takes it; the
        # `unsafe_write` (through an int8 view for an `AtomicI8`, which holds
        # one int8) initialises it first. From then on that field's
        # `OwnedPointer` owns the slot and frees it when the State drops.
        var craw = alloc[Slab[RecordBatch]](1)
        craw.unsafe_write(chunks^)
        self.chunks = OwnedPointer[Slab[RecordBatch]](
            unsafe_from_raw_pointer=craw
        )
        var oraw = alloc[Slab[OwnedAlignedBuffer]](1)
        oraw.unsafe_write(out^)
        self.out = OwnedPointer[Slab[OwnedAlignedBuffer]](
            unsafe_from_raw_pointer=oraw
        )
        self.bases = bases^
        self.swid = swid^
        self.ocol = ocol^
        self.work = work^
        var eraw = alloc[AtomicI8](1)
        eraw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=eraw
        )
        var mraw = alloc[String](1)
        mraw.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=mraw)


@fieldwise_init
struct _PnWidenTask(Segment):
    """POD Segment for `_PnWidenState` -- one task per (chunk x column x row
    range) tile."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the caller parameterizes `run_with_state` over
        # (_PnWidenState, _PnWidenTask), so the bitcast resolves to the
        # concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[_PnWidenState]()
        if sp[].err_flag[].load() != Int8(0):
            return
        try:
            ref w = sp[].work[Int(task_id)]
            var p = Int(w.col)
            # SAFETY: aliased `mut` refs to `out[][slot]` across tiles of the
            # same slot write DISJOINT element ranges -- the driver's stated
            # disjointness contract.
            ref dbuf = sp[].out[].get_mut_interior(Int(w.slot))
            _pn_widen_range(
                sp[].chunks[][Int(w.chunk)].column_at(sp[].ocol[p]),
                sp[].bases[p],
                sp[].swid[p],
                w.row_start,
                w.row_end,
                dbuf,
            )
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):  # cov: unreachable False only when two tasks fail at once, a race no test can force
                sp[].err_msg[] = String(e)


def _pn_rebuild_chunk(
    var chunk: RecordBatch,
    imm plan: PayloadWidenPlan,
    mut bufs: Slab[OwnedAlignedBuffer],
    base_slot: Int,
    imm wide_schema: Schema,
) raises -> RecordBatch:
    """Swap chunk `k`'s narrow columns for the widened buffers and re-label it
    with the leaf's own wide schema.

    ⚠ THE VALIDITY BITMAP IS MOVED, NEVER DROPPED AND NEVER REBUILT. The rule
    refuses a nullable payload and an INNER gather over a non-nullable source
    emits no bitmap, so on every shipped path this is `None` -- but "on every
    shipped path" is not "by construction", and a widen that silently dropped a
    bitmap would turn nulls into values. `Bitmap` is Movable-only, so it comes
    across via `Optional.take()` on the OLD column (the sanctioned spelling;
    `UnsafePointer(to=field).take_pointee()` is banned by the pointer rules)."""
    var rows = chunk.num_rows()
    var cols = chunk.take_columns()
    _ = chunk^
    for p in range(plan.num_widened()):
        var oc = plan.out_col[p]
        var buf = bufs.take_slot_unchecked(base_slot + p)
        var old = cols.replace(oc, Column[HeapRegion]())
        # ⛔ GUARDED. `Optional.take()` ABORTS on an empty Optional (it is not
        # a "return None" accessor), and the SHIPPED case is exactly the empty
        # one: the rule refuses a nullable payload and an INNER gather over a
        # non-nullable source emits no bitmap. An unguarded `take()` here
        # aborted every single case of this file's own suite.
        var v = Optional[Bitmap[HeapRegion]](None)
        if old._validity:
            v = old._validity.take()
        var nulls = old._null_count
        _ = old^
        _ = cols.replace(
            oc,
            Column[HeapRegion](
                arrow_type=ArrowType.INT64,
                data=buf^,
                offsets=Optional[OwnedAlignedBuffer](None),
                validity=v^,
                length=rows,
                null_count=nulls,
                offset=0,
            ),
        )
    return RecordBatch.from_typed_columns_slab(wide_schema.copy(), cols^)


def widen_payload_table_parallel[
    disp_o: Origin[mut=True],
](
    var table: Table,
    imm plan: PayloadWidenPlan,
    imm wide_schema: Schema,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    num_workers: Int,
) raises -> Table:
    """Reconstruct every narrowed column as `Int64(stored) + base`.

    Args:
        table: The joined result carrying the NARROW columns. Consumed.
        plan: What `narrow_build_batch` did. An empty plan is the identity.
        wide_schema: The schema the leaf returns -- the one derived from the
            UN-narrowed build batch, so the returned Table is indistinguishable
            from the un-levered one.
        dispatcher_ptr: Borrowed substrate dispatcher (tight origin).
        cancel_token: Consumed by the dispatch.
        num_workers: Pool width; bounds the tile count.

    Returns:
        A `Table` with the same chunk boundaries, chunk order and row order,
        every narrowed column reconstructed, carrying `wide_schema`.

    Raises:
        Whatever `_pn_widen_range` raises for the FIRST tile that fails
        (first-error-wins across the fork).
    """
    var nplan = plan.num_widened()
    if nplan == 0:
        # IDENTITY -- the arm every declined join takes. No fork, no copy, no
        # schema rebuild.
        _ = cancel_token^
        return table^

    var n_chunks = table.num_chunks()
    var total_rows = table.num_rows()
    var taken = table.take_chunks()
    _ = table^

    if n_chunks == 0:
        # A result with no chunks still has to carry the WIDE schema: a
        # downstream Project over this leaf resolves columns by name and a
        # narrow-labelled empty result would still be the wrong TYPE.
        _ = cancel_token^
        _ = taken^
        var empty = List[RecordBatch]()
        empty.append(RecordBatch.empty_from_schema(wide_schema.copy()))
        return Table.from_chunks(empty^, wide_schema.copy())

    # `take_chunks()` hands back the `Slab` the reassembly below wants.
    var chunk_list = taken^

    # ---- Size the destinations and the tiles, BEFORE the fork ---------------
    var n_slots = n_chunks * nplan
    var out_bufs = Slab[OwnedAlignedBuffer].create(n_slots)
    var work = List[_PnWork]()
    var tile = _tile_rows(total_rows, num_workers)
    for k in range(n_chunks):
        var rows = chunk_list[k].num_rows()
        for p in range(nplan):
            var buf = OwnedAlignedBuffer(max(rows * 8, 1))
            buf.set_length(Int64(rows * 8))
            out_bufs.append(buf^)
            var slot = k * nplan + p
            var r = 0
            while r < rows:
                var hi = r + tile
                if hi > rows:
                    hi = rows
                work.append(
                    _PnWork(Int32(slot), Int32(k), Int32(p), r, hi)
                )
                r = hi
    var n_tasks = len(work)

    var bases = List[Int64](capacity=nplan)
    var swid = List[UInt8](capacity=nplan)
    var ocol = List[Int](capacity=nplan)
    for p in range(nplan):
        bases.append(plan.base[p])
        swid.append(plan.src_bytes[p])
        ocol.append(plan.out_col[p])

    if (
        num_workers < 2
        or total_rows < _PN_MIN_PARALLEL_ROWS
        or n_tasks < 2  # cov: unreachable with 2+ workers and 65536+ rows, _tile_rows cuts 4+ tiles
    ):
        # SERIAL ARM -- the SAME kernel, so the two arms cannot diverge.
        _ = cancel_token^
        for t in range(n_tasks):
            ref wk = work[t]
            var p = Int(wk.col)
            ref dbuf = out_bufs.get_mut_interior(Int(wk.slot))
            _pn_widen_range(
                chunk_list[Int(wk.chunk)].column_at(ocol[p]),
                bases[p],
                swid[p],
                wk.row_start,
                wk.row_end,
                dbuf,
            )
    else:
        # Parallel region: (chunk x column x row range) leaf-exit widen.
        # Disjointness: task `t` READS `chunks[][work[t].chunk]`'s narrow
        #   column (read-only, shared with every other task) and WRITES
        #   elements [row_start, row_end) of `out[][work[t].slot]` only. The
        #   tiles of one slot PARTITION that chunk's [0, rows), and slots are
        #   distinct per (chunk, plan column), so no task writes a byte another
        #   task reads or writes. `bases`/`swid`/`ocol`/`work` are written once
        #   before the fork and only read after it.
        # Liveness: the State owns the chunk list and the buffer slab via
        #   `OwnedPointer`; the driver's `var state` slot holds it across
        #   `run_with_state`, whose drain barrier rejoins every worker before
        #   this function returns.
        # No-realloc: `out_bufs` is `create(n_slots)` + exactly `n_slots`
        #   appends BEFORE the fork; no task appends, reserves or resizes.
        var state = _PnWidenState(
            chunk_list^, out_bufs^, bases^, swid^, ocol^, work^
        )
        var task = _PnWidenTask(Int32(0))
        _ = dispatcher_ptr[].run_with_state[_PnWidenState, _PnWidenTask](
            state, task^, n_tasks, cancel_token^, site_id=SITE_CONCAT
        )
        var raised = state.err_flag[].load() != Int8(0)
        var raised_msg = String("")
        if raised:
            raised_msg = String(state.err_msg[])

        # Move both slabs back out of the State by swapping an empty slab into
        # each `OwnedPointer`'s pointee, so `state^` drops two empty slabs.
        chunk_list = Slab[RecordBatch]()
        swap(chunk_list, state.chunks[])
        out_bufs = Slab[OwnedAlignedBuffer]()
        swap(out_bufs, state.out[])
        _ = state^
        if raised:
            _ = out_bufs^
            _ = chunk_list^
            raise Error("widen_payload_table_parallel: " + raised_msg)

    # ---- Reassemble, in the Table's own chunk order -------------------------
    var out_chunks = List[RecordBatch](capacity=n_chunks)
    for k in range(n_chunks):
        var ch = chunk_list.replace(k, RecordBatch())
        out_chunks.append(
            _pn_rebuild_chunk(ch^, plan, out_bufs, k * nplan, wide_schema)
        )
    _ = chunk_list^
    out_bufs.set_len_unchecked(0)
    _ = out_bufs^
    return Table.from_chunks(out_chunks^, wide_schema.copy())
