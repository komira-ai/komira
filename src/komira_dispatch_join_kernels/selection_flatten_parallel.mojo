# =============================================================================
# selection_flatten_parallel -- the selection EGRESS, run on the worker pool
# =============================================================================
#
# WHY THIS FILE EXISTS (measured at 20 workers)
# ---------------------------------------------
# `flatten_selection_table` (komira_arrow/selection_column.mojo) is the
# engine's declared boundary for the selection layout: a selection-backed
# column may not leave the engine, so every chunk is resolved back to flat
# there. It is a SERIAL, single-threaded walk of the WHOLE result -- and it
# sits on the exit of a join whose own output assembly is a 20-way parallel
# fork. Crossing that parallelism boundary is what the egress costs, and it is
# not small:
#
#   | cell        | assemble region on the arm that gathers | on the arm that slices |
#   |-------------|----------------------------------------|------------------------|
#   | `h2o/j1`    | 15.52 ms/rep (66% forked)              | 174.50 ms/rep (2% forked) |
#   | high-card   | 336.35 ms/rep (66% forked)             | 2282.43 ms/rep (6% forked) |
#
# (scheduler trace, region `fj_output_assemble`. The BYTES are identical
# between the two arms -- `[defer-out] out_bytes_written` moves from the
# assembly to the egress, 4.80 GB -> 1.60 GB on the high-cardinality join, with
# the remaining 3.20 GB written HERE instead. Same work, one thread.)
#
# ⇒ THE EGRESS MUST BE AS PARALLEL AS THE PRODUCER, OR THE CARRIER IS A
# PESSIMISATION BY CONSTRUCTION. That is the whole content of this file: the
# chunks of a selection-backed `Table` are INDEPENDENT (a selection column
# names exactly one base, and that base is its own chunk's probe morsel), so
# resolving chunk `i` reads nothing chunk `j` writes. One task per chunk.
#
# ⚠ THIS DOES NOT MAKE THE SELECTION CARRIER A WIN, AND MUST NOT BE READ AS
# CLAIMING SO. With the egress fully parallel the carrier's CEILING is PARITY
# with the gather it replaced -- it moves the same reads and the same writes to
# a later point and adds one more pass over the codes (the flatten resolves one
# column at a time where `_gather_pair_into_range_i32` walks the match index
# once for TWO). What this file removes is a 20x serialisation artefact, so
# that a measurement of the carrier prices the CARRIER and not this function.
#
# ⛔ IT IS NOT A SECOND GATE. There is exactly one lever (the probe-side
# selection carrier); this is the unconditional egress on both arms,
# and on the arm that never produced a selection column it is the SAME identity
# `flatten_selection_table` already was -- one `is_numeric_dict()` tag read per
# column, no fork, no copy. The fork is taken only when a selection column is
# actually present AND there is more than one chunk to spread.
# =============================================================================

from komira_atomic_alias import AtomicI8
from std.memory import alloc, OwnedPointer, Pointer, UnsafePointer

from komira_collections.slab import Slab
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.selection_column import (
    batch_carries_selection,
    flatten_selection_batch,
    flatten_selection_table,
)
from komira_arrow.table import Table
from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_CONCAT


# The fork is not free: a `run_with_state` round trip costs a wake-word barrier
# plus one enqueue per worker. Below this many rows the serial walk is cheaper
# than the barrier, and a chunked result that small is not what this path is
# for. Deliberately a ROW count and not a chunk count -- 6,511 chunks of 3 rows
# is still nothing to spread.
comptime SELECTION_FLATTEN_PARALLEL_MIN_ROWS: Int = 8192


struct _SelFlattenState(KeepAlive, Movable):
    """State for the per-chunk selection-egress dispatch.

    Wildcard-free: both slabs are behind `OwnedPointer` and the schema is a
    read-only direct field written ONCE by the driver before the fork.
    """

    # OWNED input chunks, in the `Table`'s own order. Workers take
    # `chunks[][i]` BY REF and never mutate it.
    #
    # ⚠ A `Slab` because `Table.take_chunks()` hands over a `Slab` directly,
    # so there is no re-home. Nothing here needs to move an element out of
    # this side, so no such move is performed.
    var chunks: OwnedPointer[Slab[RecordBatch]]
    # OWNED output slots, PRE-FILLED to `len(chunks)` empty batches. Task `i`
    # replaces slot `i` and no other.
    var out: OwnedPointer[Slab[RecordBatch]]
    # The FLAT schema every resolved chunk must carry. Read-only, shared.
    var flat_schema: Schema

    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    def __init__(
        out self,
        var chunks: Slab[RecordBatch],
        var out: Slab[RecordBatch],
        var flat_schema: Schema,
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

        var oraw = alloc[Slab[RecordBatch]](1)
        oraw.unsafe_write(out^)
        self.out = OwnedPointer[Slab[RecordBatch]](unsafe_from_raw_pointer=oraw)

        self.flat_schema = flat_schema^

        var raw = alloc[AtomicI8](1)
        raw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(Scalar[DType.int8](0))
        self.err_flag = OwnedPointer[AtomicI8](
            unsafe_from_raw_pointer=raw
        )

        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)


@fieldwise_init
struct _SelFlattenTask(Segment):
    """POD Segment for `_SelFlattenState` -- one task per CHUNK."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the caller parameterizes `run_with_state` over
        # (_SelFlattenState, _SelFlattenTask), so the bitcast resolves to the
        # concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[_SelFlattenState]()
        if sp[].err_flag[].load() != Int8(0):
            return
        try:
            var i = Int(task_id)
            var flat = flatten_selection_batch(
                sp[].chunks[][i], sp[].flat_schema
            )
            # SAFETY: `Slab.replace` touches ONLY `t_ptr + idx` (it reads
            # `_len_t` and the base pointer, both immutable across the window)
            # and `task_id` is unique per task, so no two threads name the same
            # slot. The returned placeholder is dropped here.
            _ = sp[].out[].replace(i, flat^)
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):  # cov: unreachable False only when two tasks fail at once, a race no test can force
                sp[].err_msg[] = String(e)


def flatten_selection_table_parallel[
    disp_o: Origin[mut=True],
](
    var table: Table,
    imm flat_schema: Schema,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    num_workers: Int,
) raises -> Table:
    """`flatten_selection_table`, with the per-chunk resolve on the worker pool.

    SAME ANSWER, SAME ORDER, SAME SCHEMA as the serial spelling -- the chunk
    boundaries are the task boundaries, so chunk `i` of the result is
    `flatten_selection_batch(chunk_i, flat_schema)` on both paths and the chunk
    sequence is unchanged. The tests assert that equality against an absolute
    oracle rather than against the serial function alone.

    Args:
        table: The (possibly selection-backed) result. Consumed.
        flat_schema: The schema the FLAT result must carry -- the producer's own
            output schema, before the selection columns relabelled their fields
            to `DICTIONARY`.
        dispatcher_ptr: Borrowed substrate dispatcher (tight origin).
        cancel_token: Consumed by the dispatch.
        num_workers: Pool width, used only to bound the task count.

    Returns:
        A `Table` with no selection-backed column, chunk-for-chunk and
        row-for-row equal to `flatten_selection_table(table, flat_schema)`.

    Raises:
        Whatever `flatten_selection_batch` raises for the FIRST chunk that
        fails (first-error-wins across the fork), with the chunk's own message.
    """
    # IDENTITY, and it is the arm that matters: on every run that produced no
    # selection column this is one tag read per column of one chunk and no
    # fork. `flatten_selection_table` states the same contract; keeping the
    # test HERE means the fork is never even planned on the default arm.
    var any_sel = False
    for i in range(table.num_chunks()):
        if batch_carries_selection(table.chunks()[i]):
            any_sel = True
            break
    if not any_sel:
        _ = cancel_token^
        return table^

    var n_chunks = table.num_chunks()
    if (
        n_chunks < 2
        or num_workers < 2
        or table.num_rows() < SELECTION_FLATTEN_PARALLEL_MIN_ROWS
    ):
        # Nothing to spread, or not enough rows to pay for the barrier. The
        # serial spelling is the SAME function per chunk, so this is a cost
        # decision and never a semantic one.
        _ = cancel_token^
        return flatten_selection_table(table^, flat_schema)

    var chunk_list = table.take_chunks()
    _ = table^
    var out_slab = Slab[RecordBatch].create(n_chunks)
    for _ in range(n_chunks):
        out_slab.append(RecordBatch())

    # Parallel region: (chunk) selection egress.
    # Disjointness: task `i` READS `chunks[][i]` only and WRITES `out[][i]`
    #   only, via `Slab.replace(i, ...)` which touches exactly one slot. The
    #   chunks are independent by the carrier's own invariant -- a selection
    #   column names exactly ONE base and that base is its own chunk's probe
    #   morsel -- so no task reads a buffer another task writes. `flat_schema`
    #   is read-only across the window and shared by every task.
    # Liveness: the State owns both slabs via OwnedPointer and holds the schema
    #   by value; the driver's `var state` slot holds the State alive across
    #   `run_with_state`, whose drain barrier rejoins every worker before this
    #   function returns.
    # No-realloc: both slabs are `create(n_chunks)` + exactly `n_chunks`
    #   appends BEFORE the fork, and no task appends, reserves or resizes.
    #   `replace` is length-preserving.
    var state = _SelFlattenState(chunk_list^, out_slab^, flat_schema.copy())
    var task = _SelFlattenTask(Int32(0))
    _ = dispatcher_ptr[].run_with_state[_SelFlattenState, _SelFlattenTask](
        state, task^, n_chunks, cancel_token^, site_id=SITE_CONCAT
    )

    var raised = state.err_flag[].load() != Int8(0)
    var raised_msg = String("")
    if raised:
        raised_msg = String(state.err_msg[])

    # Move both slabs back out of the State by swapping an empty slab into
    # each `OwnedPointer`'s pointee, so `state^` drops two empty slabs.
    var done = Slab[RecordBatch]()
    swap(done, state.out[])

    var done_in = Slab[RecordBatch]()
    swap(done_in, state.chunks[])
    _ = done_in^
    _ = state^

    if raised:
        _ = done^
        raise Error(raised_msg)

    var out_chunks = List[RecordBatch](capacity=n_chunks)
    for i in range(n_chunks):
        out_chunks.append(done.replace(i, RecordBatch()))
    _ = done^
    return Table.from_chunks(out_chunks^, flat_schema.copy())
