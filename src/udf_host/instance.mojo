# =============================================================================
# instance -- one UDF in one context: the calls of one engine worker
# =============================================================================
#
# `UdfInstance` is what one worker of an operator calls: a context of its own
# (komira/python: one worker process forked from the zygote) and the UDF's
# instance in it, opened when it is made and closed when it is dropped. Two
# workers never share a context, so their calls run at once.
#
# `call(args, rows)` is one batch of a column-kind call (SCALAR or
# MAP_BATCHES_COLUMN) through `call_batch`, with what the host owes the call
# and checks of it (docs/design/udf_runtime_interface.md sections 3.4, 4.4
# and 4.5):
#
#   - each argument column is of the type its `arg_types` entry declares
#     (`OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`, naming the argument);
#   - NULL_PROPAGATE: a row with a NULL argument is not passed to the
#     runtime, and its result is NULL; the runtime sees the other rows only,
#     in order (compaction, and the scatter back). With no NULL argument the
#     columns are passed as they are. (A result type the scatter cannot place
#     was refused when the UDF was bound.) MANUAL passes every row;
#   - the call is bounded: its deadline is the session's per-batch bound
#     after the call starts, read against the clock the host gives the
#     runtime, and a runtime that cannot stop its user code by then stops it
#     by force (komira/python: SIGKILL after its grace) and returns
#     ERR_DEADLINE or ERR_KILLED;
#   - a ceiling on rows per call (`UdfResources.max_batch_rows`, 0 for none)
#     cuts the batch into calls of at most that many rows, in order;
#   - the output is the runtime's array, validated (device, layout) and
#     copied at the return type, then: `rows` rows
#     (`UDF_BATCH_LENGTH_MISMATCH`), and no NULL in a non-nullable return
#     type (`UDF_RETURN_TYPE_MISMATCH`);
#   - a failure is the status's code (`status.mojo`) with the UDF's name and
#     the runtime's message, the row it names in this batch's numbering
#     (mapped back through the compaction), and the user's trace on the
#     lines after. A worker that died or was stopped, or a context already
#     lost, loses the instance: every later call refuses with
#     `UDF_WORKER_CRASHED` and runs nothing. Nothing is retried.
#
# Not here yet: bisecting a raise that names no row to its first failing row
# (section 4.5), and the host's cancel flag (a call is bounded by its
# deadline only).
# =============================================================================

from std.memory import ArcPointer

from arrow.arrow_types import ArrowType
from arrow.bitmap import Bitmap
from arrow.column import Column
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from byte_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from column_kernels.cross_batch_gather import _fixed_elem_size, cross_batch_gather
from containers.slab import Slab
from plan_expr.udf_data import UDF_NULL_MANUAL

from ._abi import (
    CallOutcome,
    Handle,
    call_batch,
    close_context,
    close_instance,
    now_ns,
    open_context,
    open_instance,
)
from .runtime import UdfBinding, arg_schema, result_field
from .status import (
    OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH,
    UDF_BATCH_LENGTH_MISMATCH,
    UDF_RETURN_TYPE_MISMATCH,
    UDF_RUNTIME_FAULT,
    UDF_WORKER_CRASHED,
    loses_context,
    status_code,
    status_name,
)


def _one_null_row(at: ArrowType) raises -> Column[HeapRegion]:
    """A column of one NULL row of type `at` (a type `cross_batch_gather`
    places): the source a NULL_PROPAGATE scatter takes its NULL rows from."""
    if at == ArrowType.NULL:
        var d = OwnedAlignedBuffer(1)
        d.set_length(0)
        return Column[HeapRegion](
            arrow_type=at, data=d^, offsets=None, validity=None,
            length=1, null_count=1, offset=0,
        )
    var data = OwnedAlignedBuffer(16)
    data.zero()
    var offsets = Optional[OwnedAlignedBuffer](None)
    if at == ArrowType.STRING or at == ArrowType.BINARY or at == ArrowType.LARGE_STRING:
        data.set_length(0)
        var o = OwnedAlignedBuffer(16)
        o.zero()
        o.set_length(16 if at == ArrowType.LARGE_STRING else 8)
        offsets = Optional(o^)
    elif at == ArrowType.BOOL:
        data.set_length(1)
    else:
        data.set_length(Int64(_fixed_elem_size(at)))
    return Column[HeapRegion](
        arrow_type=at, data=data^, offsets=offsets^, validity=Optional(Bitmap.create(1)),
        length=1, null_count=1, offset=0,
    )


def _batch_of(var columns: List[Column[HeapRegion]], schema: Schema, rows: Int) raises -> RecordBatch:
    """A batch of `columns` at `schema`, or of `rows` rows and no column."""
    if len(columns) == 0:
        return RecordBatch.count_only(rows)
    var b = RecordBatchBuilder.with_capacity(len(columns))
    for i in range(len(columns)):
        b.add_column(columns[i].share())
    return b.build(schema.copy())


def _share_batch(ref batch: RecordBatch) raises -> RecordBatch:
    """A batch sharing `batch`'s columns (an Arc count each, no copy)."""
    if batch.num_columns() == 0:
        return RecordBatch.count_only(batch.num_rows())
    var b = RecordBatchBuilder.with_capacity(batch.num_columns())
    for i in range(batch.num_columns()):
        b.add_column(batch.column_at(i).share())
    return b.build(batch.schema.copy())


def _gather(ref batch: RecordBatch, rows: List[Int]) raises -> RecordBatch:
    """The rows `rows` of `batch`, in that order; a batch with no column
    gives `len(rows)` rows and no column."""
    if batch.num_columns() == 0:
        return RecordBatch.count_only(len(rows))
    var sources = Slab[RecordBatch]()
    sources.append(_share_batch(batch))
    var idx = List[Tuple[Int, Int]](capacity=len(rows))
    for i in range(len(rows)):
        idx.append((0, rows[i]))
    return cross_batch_gather(sources, idx)


struct UdfInstance(Movable):
    """UDF `index` of a binding in a context of its own; closed when dropped."""

    var _binding: ArcPointer[UdfBinding]
    var _index: Int
    var _ctx: Handle
    var _inst: Handle
    var _lost: String
    """Why the instance is lost ("" while it is not)."""
    var _calls: Int64
    var _slot: Int

    def __init__(out self, binding: ArcPointer[UdfBinding], index: Int, slot: Int) raises:
        """Open a context in slot `slot` (the worker's number) and UDF
        `index`'s instance in it.

        Raises:
            The status's code (`status.mojo`) naming the UDF and the entry
            that refused; a context opened before an instance refusal is
            closed.
        """
        self._binding = binding
        self._index = index
        self._ctx = Handle.null()
        self._inst = Handle.null()
        self._lost = String("")
        self._calls = 0
        self._slot = slot
        ref b = binding[]
        var rt = b.runtime()
        var ctx = open_context(rt[].table(), rt[].rt(), UInt32(slot))
        if ctx.code != 0:
            raise Error(
                status_code(ctx.code) + ": " + b.name_of(index) + ": open_context refused ("
                + status_name(ctx.code) + "): " + ctx.error.message
            )
        self._ctx = ctx.made
        var inst = open_instance(rt[].table(), self._ctx, b.udf_handle(index))
        if inst.code != 0:
            # The context closes in __del__, which runs for the raise.
            raise Error(
                status_code(inst.code) + ": " + b.name_of(index) + ": open_instance refused ("
                + status_name(inst.code) + "): " + inst.error.message
            )
        self._inst = inst.made

    def __del__(deinit self):
        var rt = self._binding[].runtime()
        if not self._inst.is_null():
            close_instance(rt[].table(), self._inst)
        if not self._ctx.is_null():
            close_context(rt[].table(), self._ctx)

    def lost(self) -> String:
        """Why the instance is lost; "" while calls may be made."""
        return self._lost.copy()

    def call(mut self, ref args: List[Column[HeapRegion]], rows: Int) raises -> Column[HeapRegion]:
        """The UDF's column over `rows` rows of the argument columns `args`
        (in call order). See the module header for the checks and errors."""
        ref b = self._binding[]
        ref u = b.ref_at(self._index)
        var name = b.name_of(self._index)
        if self._lost != "":
            raise Error(
                String(UDF_WORKER_CRASHED) + ": " + name + ": the worker of this call is lost ("
                + self._lost + "); no call runs on it again"
            )
        if len(args) != len(u.arg_types):
            raise Error(
                String(OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH) + ": " + name + " takes "
                + String(len(u.arg_types)) + " arguments, and the call passes " + String(len(args))
            )
        for i in range(len(args)):
            var want = u.arg_types[i].arrow_type
            if args[i].arrow_type != want:
                raise Error(
                    String(OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH) + ": " + name + ": argument " + String(i)
                    + " is " + String(args[i].arrow_type) + ", and the UDF declares " + String(want)
                )
        var want = result_field(u)
        var cols = List[Column[HeapRegion]](capacity=len(args))
        for i in range(len(args)):
            cols.append(args[i].share())
        var batch = _batch_of(cols^, arg_schema(u), rows)
        # The rows the runtime is given: all of them, or under PROPAGATE those
        # with no NULL argument.
        var keep = List[Int]()
        var any_null = False
        if u.null_mode != UDF_NULL_MANUAL:
            for r in range(rows):
                var valid = True
                for i in range(len(args)):
                    if args[i].is_null_at(r):
                        valid = False
                        break
                if valid:
                    keep.append(r)
                else:
                    any_null = True
        if not any_null:
            return self._call_all(batch, want, name, List[Int]())
        var compact_rows = len(keep)
        var result: Column[HeapRegion]
        if compact_rows > 0:
            var compact = _gather(batch, keep)
            result = self._call_all(compact, want, name, keep)
        else:
            result = _one_null_row(want.arrow_type).slice(0, 0)
        # Scatter: row r is the next result row when it was kept, else NULL.
        var sources = Slab[RecordBatch]()
        var sb = SchemaBuilder()
        sb.add_field(want.copy())
        var out_schema = sb.build()
        var rb = RecordBatchBuilder.with_capacity(1)
        rb.add_column(result^)
        sources.append(rb.build(out_schema.copy()))
        var nb = RecordBatchBuilder.with_capacity(1)
        nb.add_column(_one_null_row(want.arrow_type))
        sources.append(nb.build(out_schema.copy()))
        var idx = List[Tuple[Int, Int]](capacity=rows)
        var next = 0
        for r in range(rows):
            if next < compact_rows and keep[next] == r:
                idx.append((0, next))
                next += 1
            else:
                idx.append((1, 0))
        var placed = cross_batch_gather(sources, idx)
        return placed.column_at(0).share()

    def _call_all(
        mut self, ref batch: RecordBatch, want: Field, name: String, rows_of: List[Int]
    ) raises -> Column[HeapRegion]:
        """`batch` through call_batch, cut by the UDF's row ceiling; `rows_of[k]`
        is the caller's row of batch row k (empty: the same row)."""
        ref u = self._binding[].ref_at(self._index)
        var n = batch.num_rows()
        var ceiling = Int(u.resources.max_batch_rows)
        if ceiling <= 0 or n <= ceiling:
            return self._call_one(batch, want, name, rows_of, 0)
        var parts = Slab[RecordBatch]()
        var idx = List[Tuple[Int, Int]](capacity=n)
        var start = 0
        while start < n:
            var count = min(ceiling, n - start)
            var piece_rows = List[Int](capacity=count)
            for k in range(count):
                piece_rows.append(start + k)
            var piece = _gather(batch, piece_rows)
            var col = self._call_one(piece, want, name, rows_of, start)
            var sb = SchemaBuilder()
            sb.add_field(want.copy())
            var rb = RecordBatchBuilder.with_capacity(1)
            rb.add_column(col^)
            parts.append(rb.build(sb.build()))
            for k in range(count):
                idx.append((len(parts) - 1, k))
            start += count
        var joined = cross_batch_gather(parts, idx)
        return joined.column_at(0).share()

    def _call_one(
        mut self, ref batch: RecordBatch, want: Field, name: String, rows_of: List[Int], first: Int
    ) raises -> Column[HeapRegion]:
        """One call_batch of `batch`, whose row k is the caller's row
        `rows_of[first + k]` (or `first + k`)."""
        var b = self._binding
        var rt = b[].runtime()
        var deadline = now_ns() + Int64(rt[].config.deadline_ms()) * 1000000
        self._calls += 1
        var call_id = Int64(self._slot) * 1000000000 + self._calls
        var got = call_batch(rt[].table(), self._inst, batch, deadline, call_id, want)
        var n = batch.num_rows()
        if got.code != 0:
            if loses_context(got.code):
                self._lost = status_name(got.code) + ": " + got.error.message
            var text = status_code(got.code) + ": " + name + " (" + status_name(got.code) + "): " + got.error.message
            var row = got.error.row
            if row >= 0 and row < Int64(n):
                var at = Int(row) + first
                var caller_row = rows_of[at] if at < len(rows_of) else at
                text += " (row " + String(caller_row) + " of the batch)"
            if got.error.trace != "":
                text += "\n" + got.error.trace
            if got.fault != "":
                text += "; and " + got.fault
            raise Error(text^)
        if got.fault != "":
            raise Error(String(UDF_RUNTIME_FAULT) + ": " + name + ": " + got.fault)
        var col = got.column.take()
        if col.length() != n:
            raise Error(
                String(UDF_BATCH_LENGTH_MISMATCH) + ": " + name + " returned " + String(col.length())
                + " rows for a batch of " + String(n)
            )
        if not want.nullable and col.null_count() > 0:
            raise Error(
                String(UDF_RETURN_TYPE_MISMATCH) + ": " + name + " returned " + String(col.null_count())
                + " NULL rows, and its return type " + String(want.arrow_type) + " is not nullable"
            )
        return col^
