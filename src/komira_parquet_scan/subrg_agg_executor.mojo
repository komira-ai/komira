# =============================================================================
# subrg_agg_executor — a grouped aggregate over Parquet, decoded a chunk at a
# time into fixed per-worker buffers and folded chunk by chunk
# =============================================================================
#
# `run_subrg_agg` runs a fork over the file's row groups. Each worker claims
# row groups from an atomic cursor and folds each through
# `subrg_agg_fold.fold_one_rg_subrg` into its private accumulator, the sink's
# `WorkerLocal` (`ScanChunkSink`). The fixed buffers (`SUBRG_SLOTS` codes and
# 8-byte values) are allocated once per worker and reused for every chunk and
# row group. After the join the sink combines the workers' accumulators and
# drains them to batches.
#
# A claimed row group whose statistics prove the predicate keeps no row is
# skipped. Every claim asks (the footer is read-only), so a predicate that
# prunes nothing costs no serial setup pass.
#
# A row group the cursors refuse before any chunk reached the sink (an
# encoding they do not take, a PLAIN key, an actual null in the first chunk)
# is decoded whole (`decode_columns_subset`) and handed over as one chunk.
# The run is abandoned, and comes back as an EMPTY slab, when
#   * a row group was refused after a chunk reached the sink (an aggregate
#     cannot retract the prefix, so the whole-row-group decode would count it
#     twice), or
#   * the plan has a STRING key and a row group was refused at all (the
#     whole-row-group decode would build string arrays on a worker thread).
# The caller then answers the query on its own serial route. An empty slab is
# also the answer to a file with no row group.
#
# A run that took the whole-row-group decode or was abandoned prints one line
# on stderr; a healthy run prints nothing.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.builtin.swap import swap
from std.io import FileDescriptor
from std.memory import Pointer, UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_PARQUET_AGG
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.scan_copy_trace import scan_copy_trace_dump
from komira_plan_expr.expr import Expr

from .batch_filter import filter_batch_by_predicate
from .parquet_reader import ParquetReader
from .rg_prune_counter import rg_prune_setup_record
from .scan_chunk_sink import ScanChunkSink
from .subrg_agg_fold import FOLD_DECLINED_DIRTY, FOLD_OK, fold_one_rg_subrg
from .subrg_agg_plan import SUBRG_SLOTS, SubrgAggPlan


comptime _STDERR: FileDescriptor = FileDescriptor(2)


def _is_int_key_type(t: ArrowType) -> Bool:
    return t == ArrowType.INT32 or t == ArrowType.INT64


def validate_subrg_agg_plan(plan: SubrgAggPlan) raises:
    """Refuse a plan the route cannot fold.

    Raises:
        If the plan has no group key, a key index is out of range, a key is
        neither INT32 / INT64 nor (with `has_string_key`) STRING, or a column
        that is not a key is STRING (only a key keeps its dictionary).
    """
    var n_cols = len(plan.proj_names)
    if len(plan.reader_col_idx) != n_cols or len(plan.col_arrow_types) != n_cols:
        raise Error("subrg agg: the plan's column lists differ in length")
    if len(plan.key_proj_idx) == 0:
        raise Error("subrg agg: the plan has no group key")
    for k in range(len(plan.key_proj_idx)):
        var ci = plan.key_proj_idx[k]
        if ci < 0 or ci >= n_cols:
            raise Error("subrg agg: group key index " + String(ci) + " is out of range")
        var t = plan.col_arrow_types[ci]
        if not (_is_int_key_type(t) or (t == ArrowType.STRING and plan.has_string_key)):
            raise Error(
                "subrg agg: group key " + plan.proj_names[ci] + " must be INT32 or INT64, or STRING with"
                " has_string_key, not " + String(t)
            )
    for ci in range(n_cols):
        if not plan.is_key_proj(ci) and plan.col_arrow_types[ci] == ArrowType.STRING:
            raise Error("subrg agg: column " + plan.proj_names[ci] + " is STRING but not a group key")


struct _SubrgAggCounters(Deinitable):
    """The run's shared counters (zero-filled in place: an atomic does not
    move).

    Fields:
        rg: the row group claim cursor.
        pruned: row groups the statistics skipped.
        fallback: row groups decoded whole.
        abort: refusals that abandon the run.
        dirty: of those, refusals after a chunk reached the sink.
    """

    var rg: AtomicI64
    var pruned: AtomicI64
    var fallback: AtomicI64
    var abort: AtomicI64
    var dirty: AtomicI64


struct _SubrgAggState[FS: FileSystem, SINK: ScanChunkSink](KeepAlive):
    """The fork's state. Worker `wid` writes only `worker_locals[wid]` and
    `worker_ctx[wid]`; the reader, plan, schema, filter and sink are read
    only (`consume_chunk` takes the sink immutably); counters are atomics.
    Nothing is resized while the fork runs."""

    var worker_locals: Slab[Optional[Self.SINK.WorkerLocal]]
    var worker_ctx: Slab[ColumnDecodeContext]
    var num_workers: Int
    var sink: Self.SINK
    var reader: ParquetReader[Self.FS]
    var n_rgs: Int
    var plan: SubrgAggPlan
    var chunk_schema: Schema
    var has_filter: Bool
    var filter_pred: Optional[Expr]
    var prune_on: Bool
    var counters: Slab[_SubrgAggCounters]

    def __init__(
        out self,
        var worker_locals: Slab[Optional[Self.SINK.WorkerLocal]],
        var worker_ctx: Slab[ColumnDecodeContext],
        num_workers: Int,
        var sink: Self.SINK,
        var reader: ParquetReader[Self.FS],
        var plan: SubrgAggPlan,
        var chunk_schema: Schema,
        has_filter: Bool,
        var filter_pred: Optional[Expr],
    ):
        self.n_rgs = len(reader._meta[].row_groups)
        self.worker_locals = worker_locals^
        self.worker_ctx = worker_ctx^
        self.num_workers = num_workers
        self.sink = sink^
        self.reader = reader^
        self.plan = plan^
        self.chunk_schema = chunk_schema^
        self.has_filter = has_filter
        self.prune_on = has_filter and filter_pred.__bool__()
        self.filter_pred = filter_pred^
        self.counters = Slab[_SubrgAggCounters].create_prefilled(1)


def _fold_one_rg_whole[FS: FileSystem, SINK: ScanChunkSink](
    reader: ParquetReader[FS],
    rg_idx: Int,
    plan: SubrgAggPlan,
    has_filter: Bool,
    filter_pred: Optional[Expr],
    sink: SINK,
    mut local: SINK.WorkerLocal,
) raises:
    """The whole-row-group decode of `rg_idx` (columns in projection order,
    each of its own type, NULLs kept), filtered, handed over as one chunk
    stamped `chunk_idx = 0`."""
    var batch = reader.decode_columns_subset(rg_idx, plan.reader_col_idx, False)
    if has_filter and filter_pred:
        sink.consume_chunk(local, rg_idx, 0, filter_batch_by_predicate(batch^, filter_pred.value()))
    else:
        sink.consume_chunk(local, rg_idx, 0, batch^)


def _claim_and_fold[FS: FileSystem, SINK: ScanChunkSink](mut st: _SubrgAggState[FS, SINK], wid: Int) raises:
    """Worker `wid`'s claim loop."""
    st.worker_locals[wid] = Optional[SINK.WorkerLocal](st.sink.init_worker_state())
    ref local = st.worker_locals[wid].value()
    ref ctx = st.worker_ctx[wid]
    ref ctr = st.counters[0]
    var meta_schema = st.reader._meta[].schema.copy()
    while True:
        # Once the run is abandoned, further folds are wasted.
        if Int(ctr.abort.load()) > 0:
            break
        var ridx = Int(ctr.rg.fetch_add(Int64(1)))
        if ridx >= st.n_rgs:
            break
        if st.prune_on and st.reader.can_prune_unit(ridx, st.filter_pred.value()):
            _ = ctr.pruned.fetch_add(Int64(1))
            continue
        var verdict = fold_one_rg_subrg[FS, SINK](
            st.reader, ridx, st.plan, st.chunk_schema, st.has_filter, st.filter_pred, ctx, st.sink, local,
            meta_schema,
        )
        if verdict == FOLD_OK:
            continue
        if verdict == FOLD_DECLINED_DIRTY or st.plan.has_string_key:
            if verdict == FOLD_DECLINED_DIRTY:
                _ = ctr.dirty.fetch_add(Int64(1))
            _ = ctr.abort.fetch_add(Int64(1))
            break
        _ = ctr.fallback.fetch_add(Int64(1))
        _fold_one_rg_whole[FS, SINK](st.reader, ridx, st.plan, st.has_filter, st.filter_pred, st.sink, local)


@fieldwise_init
struct _SubrgAggTask[FS: FileSystem, SINK: ScanChunkSink](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](mut self, mut state: State, worker_id: Int32, task_id: Int64) raises:
        # SAFETY: `run_subrg_agg` dispatches
        # `run_with_state[_SubrgAggState[FS, SINK], _SubrgAggTask[FS, SINK]]`
        # with the same (FS, SINK) on both, and the pool monomorphizes the
        # (State, Task) pair together, so `state` is a
        # `_SubrgAggState[Self.FS, Self.SINK]`. The pointer is to the whole
        # state and stays in this call.
        var sp = UnsafePointer(to=state).bitcast[_SubrgAggState[Self.FS, Self.SINK]]()
        var wid = Int(task_id)
        ref ctx = sp[].worker_ctx[wid]
        ctx.ensure_subrg_codes(SUBRG_SLOTS * 4)
        # The value buffer holds either int32 codes or 8-byte PLAIN values.
        ctx.ensure_subrg_value(SUBRG_SLOTS * 8)
        _claim_and_fold[Self.FS, Self.SINK](sp[], wid)


def _report_degraded[FS: FileSystem, SINK: ScanChunkSink](st: _SubrgAggState[FS, SINK]) raises:
    """One stderr line for a run that decoded row groups whole or was
    abandoned, over a file with rows; nothing otherwise."""
    ref c = st.counters[0]
    var fb = Int(c.fallback.load())
    var abort = Int(c.abort.load())
    var dirty = Int(c.dirty.load())
    var rows = 0
    for r in range(st.n_rgs):
        rows += st.reader.unit_num_rows(r)
    if (fb == 0 and abort == 0) or rows == 0:
        return
    var why = StaticString(" (row groups the cursors refused were decoded whole)")
    if dirty > 0:
        why = StaticString(" (a row group was refused after a chunk was folded; the run was abandoned)")
    elif abort > 0:
        why = StaticString(" (a STRING-key row group was refused; the run was abandoned)")
    print(
        "[subrg-agg] DEGRADED total_rgs=", st.n_rgs,
        " total_rows=", rows,
        " fallback_rgs=", fb,
        " dirty_aborts=", dirty,
        " strkey_aborts=", abort - dirty,
        why,
        sep="",
        file=_STDERR,
    )


def run_subrg_agg[FS: FileSystem, SINK: ScanChunkSink](
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var sink: SINK,
    var reader: ParquetReader[FS],
    var plan: SubrgAggPlan,
    var chunk_schema: Schema,
    has_filter: Bool,
    var filter_pred: Optional[Expr],
    var output_schema: Schema,
    num_workers: Int,
) raises -> Slab[RecordBatch]:
    """Fold every row group of `reader` into `sink` on `num_workers` workers,
    combine the workers' accumulators and drain them. `chunk_schema` is
    `subrg_agg_build_chunk_schema(plan)`. Returns an empty slab when the file
    has no row group or the run was abandoned (the caller's serial route then
    answers).

    Raises:
        If `validate_subrg_agg_plan` refuses the plan.
    """
    validate_subrg_agg_plan(plan)
    var n_rgs = len(reader._meta[].row_groups)
    if n_rgs == 0:
        _ = cancel_token^
        return Slab[RecordBatch]()
    var nw = max(num_workers, 1)
    var worker_locals = Slab[Optional[SINK.WorkerLocal]].create(nw)
    for _ in range(nw):
        worker_locals.append(Optional[SINK.WorkerLocal](None))
    var worker_ctx = Slab[ColumnDecodeContext].create(nw)
    for _ in range(nw):
        worker_ctx.append(ColumnDecodeContext())
    var state = _SubrgAggState[FS, SINK](
        worker_locals^, worker_ctx^, nw, sink^, reader^, plan^, chunk_schema^, has_filter, filter_pred^
    )
    var ct_combine = cancel_token.clone()
    var ct_drain = cancel_token.clone()
    _ = dispatcher.run_with_state[_SubrgAggState[FS, SINK], _SubrgAggTask[FS, SINK]](
        state, _SubrgAggTask[FS, SINK](0), nw, cancel_token^, site_id=SITE_PARQUET_AGG
    )
    if state.prune_on:
        rg_prune_setup_record(Int(state.counters[0].pruned.load()))
    _report_degraded(state)
    if Int(state.counters[0].abort.load()) > 0:
        _ = ct_combine^
        _ = ct_drain^
        _ = state^
        scan_copy_trace_dump(StaticString("subrg_agg/abort"))
        return Slab[RecordBatch]()
    var locals_out = Slab[Optional[SINK.WorkerLocal]]()
    swap(state.worker_locals, locals_out)
    var combined = state.sink.combine_workers(locals_out^, nw, Pointer(to=dispatcher), ct_combine^)
    var drained = state.sink.drain(combined^, output_schema^, Pointer(to=dispatcher), ct_drain^)
    _ = state^
    scan_copy_trace_dump(StaticString("subrg_agg/drain"))
    return drained^
