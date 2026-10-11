# =============================================================================
# subrg_scan_executor — the sub-row-group scan: SELECT / filter / project over
# Parquet, decoded a chunk at a time into fixed per-worker buffers
# =============================================================================
#
# Each worker claims row groups from an atomic cursor and, per row group:
#   * opens one column cursor per projected column; the first projected
#     column drives each chunk's row count and every other column fills to
#     the same count (lockstep);
#   * builds each chunk's batch in projection order, every column flat and of
#     its own type (`subrg_columns.build_one_scan_col`), so the rows equal the
#     whole-row-group decode's;
#   * applies any WHERE predicate per chunk (`batch_filter`);
#   * hands the chunk to the collect sink stamped `(rg_idx, chunk_idx)`; the
#     drain sorts the stamps back into file order.
# The fixed buffers (`SCAN_CHUNK_ROWS` rows) are reused for every chunk, row
# group and unit, so the decode allocates no scratch per row group.
#
# A row group the cursors do not take (an encoding they refuse, an actual
# null, a short fill) falls back to the whole-row-group decode for that row
# group only. A cursor can refuse mid-row-group, after chunks were handed to
# the sink: the worker first retracts that row group's chunks
# (`StreamingScanOutputBuilder.discard_rg`), so no row is emitted twice. With a
# dictionary STRING column projected there is no worker-side fallback (it
# would build a string array on a worker thread): the unit aborts and comes
# back empty, and the caller reads it on its serial path.
#
# A claimed row group whose statistics, then whose bloom filters, prove the
# predicate keeps no row is skipped.
#
# Several leaves (units) run in ONE fork: each worker drains unit 0's row
# group cursor, then unit 1's, and so on, with no barrier between units, so a
# tiny unit never leaves workers idle behind a barrier. Each unit keeps its own
# cursor, builders, combine and drain, so its output is what it would be alone.
#
# A unit that degraded (a whole-row-group fallback or a retraction) prints one
# line on stderr; a healthy run prints nothing. The process-wide route counts
# are in `komira_parquet.subrg_scan_route_trace`.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.builtin.swap import swap
from std.io import FileDescriptor
from std.memory import Pointer, UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_PARQUET_DECODE
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN
from komira_parquet.subrg_scan_route_trace import add_scan_fallback, add_scan_retracted, add_scan_streamed
from komira_parquet_api.metadata import SchemaElement
from komira_plan_expr.expr import Expr

from .batch_filter import filter_batch_by_predicate
from .parquet_reader import ParquetReader
from .rg_prune_counter import rg_prune_bloom_record
from .scan_chunk_sink import ScanCollectChunkSink, StagedStringDictCol, StreamingScanOutputBuilder
from .subrg_columns import build_int32_codes_col, build_one_scan_col
from .subrg_cursor_feed import open_subrg_cursor


comptime _STDERR: FileDescriptor = FileDescriptor(2)

comptime SCAN_CHUNK_ROWS: Int = 30_000
comptime SCAN_SUBRG_SLOTS: Int = SCAN_CHUNK_ROWS + SUBRG_MAX_RUN
# A worker's staging window: above this many (estimated) bytes it flushes.
comptime SCAN_FLUSH_BUDGET_BYTES: Int = 16 << 20


struct SubrgScanPlan(Copyable, Movable, Deinitable):
    """The read plan of one sub-row-group scan.

    Fields:
        proj_names: the projected column names, in output order.
        reader_col_idx: each projected column's footer leaf index.
        col_arrow_types: each projected column's Arrow type.
    """

    var proj_names: List[String]
    var reader_col_idx: List[Int]
    var col_arrow_types: List[ArrowType]

    def __init__(out self, var proj_names: List[String], var reader_col_idx: List[Int], var col_arrow_types: List[ArrowType]):
        self.proj_names = proj_names^
        self.reader_col_idx = reader_col_idx^
        self.col_arrow_types = col_arrow_types^


def _fill_to(mut cursor: ResumableColumnCursor, mut vbuf: OwnedAlignedBuffer, n_chunk: Int, codes: Bool) raises -> Int:
    """Fill `vbuf` with `n_chunk` rows of `cursor` (codes or flat values),
    calling the cursor until it has them or stops; the rows filled."""
    var v_total = 0
    while v_total < n_chunk:
        var want = n_chunk - v_total
        var nv: Int
        if codes:
            nv = cursor.fill_next_codes_at(vbuf, want, v_total)
        else:
            nv = cursor.fill_next_flat(vbuf, want, v_total)
        if nv == 0:
            break
        v_total += nv
    return v_total


def _scan_one_rg_subrg[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_idx: Int,
    plan: SubrgScanPlan,
    chunk_schema: Schema,
    has_filter: Bool,
    filter_pred: Optional[Expr],
    mut ctx: ColumnDecodeContext,
    sink: ScanCollectChunkSink,
    mut local: StreamingScanOutputBuilder,
    meta_schema: List[SchemaElement],
) raises -> Int:
    """Decode row group `rg_idx` through the cursors, chunk by chunk, into the
    sink. Returns the number of chunks handed over (>= 0), or -1 when a
    cursor refused the row group (chunks may already have been handed over:
    the caller retracts them)."""
    var n_cols = len(plan.proj_names)
    if n_cols == 0:
        return 0
    ref rg = reader._meta[].row_groups[rg_idx]
    var cursors = Slab[ResumableColumnCursor].create(n_cols)
    for ci in range(n_cols):
        cursors.append(open_subrg_cursor(reader._file, rg, meta_schema, plan.reader_col_idx[ci]))
    for ci in range(n_cols):
        if not cursors[ci].supported():
            return -1
    var n_total = cursors[0].num_values()

    # Each dictionary column's dictionary, copied once per row group, so a
    # chunk's column owns its values; a string dictionary as byte lists.
    var col_dicts_i = List[List[Int64]]()
    var col_dicts_f = List[List[Float64]]()
    var col_str_offsets = List[List[Int32]]()
    var col_str_bytes = List[List[UInt8]]()
    var any_string_dict = False
    for ci in range(n_cols):
        if cursors[ci].is_string_dict():
            any_string_dict = True
            col_dicts_i.append(List[Int64]())
            col_dicts_f.append(List[Float64]())
            col_str_offsets.append(cursors[ci].str_dict_offsets_copy())
            col_str_bytes.append(cursors[ci].str_dict_bytes_copy())
        else:
            col_str_offsets.append(List[Int32]())
            col_str_bytes.append(List[UInt8]())
            if cursors[ci].is_dict() and cursors[ci].value_is_float():
                col_dicts_i.append(List[Int64]())
                col_dicts_f.append(cursors[ci].dict_values_f64_copy())
            elif cursors[ci].is_dict():
                col_dicts_i.append(cursors[ci].dict_values_copy())
                col_dicts_f.append(List[Float64]())
            else:
                col_dicts_i.append(List[Int64]())
                col_dicts_f.append(List[Float64]())
    var chunk_idx = 0
    while True:
        ref codes_buf = ctx.subrg_codes_ref()
        var n_chunk: Int
        if cursors[0].is_dict():
            n_chunk = cursors[0].fill_next_codes(codes_buf, SCAN_CHUNK_ROWS)
        else:
            n_chunk = cursors[0].fill_next_flat(codes_buf, SCAN_CHUNK_ROWS, 0)
        if n_chunk == 0:
            break
        var rbb = RecordBatchBuilder.with_capacity(n_cols)
        var str_dict_cols = List[StagedStringDictCol]()
        for ci in range(n_cols):
            var is_str = cursors[ci].is_string_dict()
            if ci == 0:
                # The driver's chunk is already in the codes buffer.
                if is_str:
                    rbb.add_column(build_int32_codes_col(codes_buf, n_chunk))
                else:
                    rbb.add_column(
                        build_one_scan_col(
                            codes_buf, n_chunk, n_chunk, cursors[0].is_dict(), cursors[0].value_is_float(),
                            cursors[0].value_ptype(), col_dicts_i[0], col_dicts_f[0],
                        )
                    )
            else:
                # Lockstep: a column aligns to its own runs, so fill exactly
                # `n_chunk` rows; a short fill declines the row group.
                ref vbuf = ctx.subrg_value_ref()
                var v_total = _fill_to(cursors[ci], vbuf, n_chunk, cursors[ci].is_dict() or is_str)
                if v_total != n_chunk:
                    return -1
                if is_str:
                    rbb.add_column(build_int32_codes_col(vbuf, n_chunk))
                else:
                    rbb.add_column(
                        build_one_scan_col(
                            vbuf, n_chunk, v_total, cursors[ci].is_dict(), cursors[ci].value_is_float(),
                            cursors[ci].value_ptype(), col_dicts_i[ci], col_dicts_f[ci],
                        )
                    )
            if is_str:
                str_dict_cols.append(
                    StagedStringDictCol(ci, plan.proj_names[ci], col_str_offsets[ci].copy(), col_str_bytes[ci].copy())
                )
        var batch = rbb.build(chunk_schema.copy())
        if any_string_dict and has_filter:
            # A string chunk carries codes, so the predicate cannot be
            # evaluated on it here (the caller streams string columns only
            # without a filter): decline rather than filter codes.
            return -1
        if any_string_dict:
            sink.consume_string_dict_chunk(local, rg_idx, chunk_idx, batch^, str_dict_cols^)
        elif has_filter and filter_pred:
            sink.consume_chunk(local, rg_idx, chunk_idx, filter_batch_by_predicate(batch^, filter_pred.value()))
        else:
            sink.consume_chunk(local, rg_idx, chunk_idx, batch^)
        chunk_idx += 1
    # Completeness: every column emitted the row group's every row.
    for ci in range(n_cols):
        if cursors[ci].rows_emitted() != n_total:
            return -1
    return chunk_idx


def _scan_one_rg_whole[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_idx: Int,
    plan: SubrgScanPlan,
    has_filter: Bool,
    filter_pred: Optional[Expr],
    sink: ScanCollectChunkSink,
    mut local: StreamingScanOutputBuilder,
) raises:
    """The whole-row-group fallback: decode the projected columns of
    `rg_idx`, filter, and hand over one chunk stamped `chunk_idx = 0` (only
    one of the two decodes is ever kept for a row group)."""
    var batch = reader.decode_columns_subset(rg_idx, plan.reader_col_idx, False)
    if has_filter and filter_pred:
        sink.consume_chunk(local, rg_idx, 0, filter_batch_by_predicate(batch^, filter_pred.value()))
    else:
        sink.consume_chunk(local, rg_idx, 0, batch^)


struct SubrgScanUnit[FS: FileSystem](Movable, Deinitable):
    """One leaf of a fused scan: its reader, plan, chunk schema, filter and
    sink. Immutable while the fork runs; its counters live in the driver.

    Fields:
        has_string_dict_proj: a projected column is a dictionary string
            column; a refused row group then aborts the unit.
        rg_prune_on: the claim loop tries the statistics and bloom prunes.
    """

    var reader: ParquetReader[Self.FS]
    var n_rgs: Int
    var plan: SubrgScanPlan
    var chunk_schema: Schema
    var has_filter: Bool
    var filter_pred: Optional[Expr]
    var has_string_dict_proj: Bool
    var rg_prune_on: Bool
    var sink: ScanCollectChunkSink

    def __init__(
        out self,
        var reader: ParquetReader[Self.FS],
        var plan: SubrgScanPlan,
        var chunk_schema: Schema,
        has_filter: Bool,
        var filter_pred: Optional[Expr],
        has_string_dict_proj: Bool,
        var sink: ScanCollectChunkSink,
    ):
        self.n_rgs = len(reader._meta[].row_groups)
        self.reader = reader^
        self.plan = plan^
        self.chunk_schema = chunk_schema^
        self.has_filter = has_filter
        self.rg_prune_on = has_filter and filter_pred.__bool__()
        self.filter_pred = filter_pred^
        self.has_string_dict_proj = has_string_dict_proj
        self.sink = sink^


struct _ScanUnitCounters(Deinitable):
    """One unit's shared counters (zero-filled in place: an atomic does not
    move).

    Fields:
        rg: the row group claim cursor.
        abort: string-dictionary refusals (the unit comes back empty).
        pruned / bloom_pruned: row groups skipped by either prune / by the
            bloom filters.
        fallback / rows_whole: whole-row-group decodes and their rows.
        rows_streamed / chunks_streamed: rows and chunks of the cursor route.
        retracted: rows handed to the sink and then retracted.
    """

    var rg: AtomicI64
    var abort: AtomicI64
    var pruned: AtomicI64
    var bloom_pruned: AtomicI64
    var fallback: AtomicI64
    var rows_streamed: AtomicI64
    var rows_whole: AtomicI64
    var chunks_streamed: AtomicI64
    var retracted: AtomicI64


struct _SubrgScanState[FS: FileSystem](KeepAlive):
    """The fork's state. Worker `wid` writes only its builders
    `worker_builders[u * num_workers + wid]` and its decode buffers
    `worker_ctx[wid]`; units are read-only; counters are atomics. Nothing is
    resized while the fork runs."""

    var units: Slab[SubrgScanUnit[Self.FS]]
    var n_units: Int
    var worker_builders: Slab[Optional[StreamingScanOutputBuilder]]
    var worker_ctx: Slab[ColumnDecodeContext]
    var num_workers: Int
    var counters: Slab[_ScanUnitCounters]

    def __init__(
        out self,
        var units: Slab[SubrgScanUnit[Self.FS]],
        var worker_builders: Slab[Optional[StreamingScanOutputBuilder]],
        var worker_ctx: Slab[ColumnDecodeContext],
        num_workers: Int,
    ):
        self.n_units = len(units)
        self.units = units^
        self.worker_builders = worker_builders^
        self.worker_ctx = worker_ctx^
        self.num_workers = num_workers
        self.counters = Slab[_ScanUnitCounters].create_prefilled(self.n_units)


def _claim_and_scan[FS: FileSystem](mut st: _SubrgScanState[FS], u: Int, wid: Int) raises:
    """Worker `wid`'s claim loop over unit `u`."""
    var bslot = u * st.num_workers + wid
    ref ctx = st.worker_ctx[wid]
    st.worker_builders[bslot] = Optional[StreamingScanOutputBuilder](st.units[u].sink.init_worker_state())
    ref local = st.worker_builders[bslot].value()
    ref unit = st.units[u]
    ref ctr = st.counters[u]
    var meta_schema = unit.reader._meta[].schema.copy()
    while True:
        # Once a worker aborted this unit, stop claiming for it (its result is
        # discarded; a row group decoded meanwhile is harmless).
        if unit.has_string_dict_proj and Int(ctr.abort.load()) > 0:
            break
        var ridx = Int(ctr.rg.fetch_add(Int64(1)))
        if ridx >= unit.n_rgs:
            break
        if unit.rg_prune_on and unit.filter_pred:
            if unit.reader.can_prune_unit(ridx, unit.filter_pred.value()):
                _ = ctr.pruned.fetch_add(Int64(1))
                continue
            if unit.reader.can_prune_unit_by_bloom(ridx, unit.filter_pred.value()):
                _ = ctr.pruned.fetch_add(Int64(1))
                _ = ctr.bloom_pruned.fetch_add(Int64(1))
                continue
        var rg_rows = Int(unit.reader._meta[].row_groups[ridx].num_rows)
        var n_chunks = _scan_one_rg_subrg[FS](
            unit.reader, ridx, unit.plan, unit.chunk_schema, unit.has_filter, unit.filter_pred, ctx, unit.sink,
            local, meta_schema,
        )
        if n_chunks >= 0:
            _ = ctr.rows_streamed.fetch_add(Int64(rg_rows))
            _ = ctr.chunks_streamed.fetch_add(Int64(n_chunks))
            add_scan_streamed(rg_rows, n_chunks)
            continue
        # The row group's streamed output is abandoned: retract what it
        # handed over before any other decode of it (a no-op for a refusal
        # that published nothing).
        var retracted = local.discard_rg(ridx)
        if retracted > 0:
            add_scan_retracted(retracted)
            _ = ctr.retracted.fetch_add(Int64(retracted))
        if unit.has_string_dict_proj:
            _ = ctr.abort.fetch_add(Int64(1))
            break
        _ = ctr.fallback.fetch_add(Int64(1))
        _ = ctr.rows_whole.fetch_add(Int64(rg_rows))
        add_scan_fallback(rg_rows)
        _scan_one_rg_whole[FS](unit.reader, ridx, unit.plan, unit.has_filter, unit.filter_pred, unit.sink, local)


@fieldwise_init
struct _SubrgScanTask[FS: FileSystem](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](mut self, mut state: State, worker_id: Int32, task_id: Int64) raises:
        # SAFETY: `run_subrg_scan_multi` dispatches
        # `run_with_state[_SubrgScanState[FS], _SubrgScanTask[FS]]` with the
        # same FS on both, and the pool monomorphizes the (State, Task) pair
        # together, so `state` is a `_SubrgScanState[Self.FS]`. The pointer is
        # to the whole state and stays in this call.
        var sp = UnsafePointer(to=state).bitcast[_SubrgScanState[Self.FS]]()
        var wid = Int(task_id)
        ref ctx = sp[].worker_ctx[wid]
        ctx.ensure_subrg_codes(SCAN_SUBRG_SLOTS * 8)
        ctx.ensure_subrg_value(SCAN_SUBRG_SLOTS * 8)
        for u in range(sp[].n_units):
            _claim_and_scan[Self.FS](sp[], u, wid)


def _report_degraded[FS: FileSystem](st: _SubrgScanState[FS], u: Int) raises:
    """One stderr line for a unit that fell back or retracted; nothing for a
    healthy one."""
    ref c = st.counters[u]
    var fb = Int(c.fallback.load())
    var retr = Int(c.retracted.load())
    var bloom_pruned = Int(c.bloom_pruned.load())
    if bloom_pruned > 0:
        rg_prune_bloom_record(bloom_pruned)
    if fb == 0 and retr == 0:
        return
    var rows_s = Int(c.rows_streamed.load())
    var chunks_s = Int(c.chunks_streamed.load())
    var rows_w = Int(c.rows_whole.load())
    var why = StaticString(" (the cursor refused a chunk shape; whole row groups were decoded)")
    if fb == 0:
        why = StaticString(
            " (the cursor refused a chunk shape after handing over rows; the unit aborted and is read by the"
            " caller's serial path)"
        )
    print(
        "[subrg-scan] DEGRADED unit=", u,
        " fallback_rgs=", fb, "/", st.units[u].n_rgs - Int(c.pruned.load()),
        " grain_whole=", rows_w // fb if fb > 0 else 0,
        " grain_streamed=", rows_s // chunks_s if chunks_s > 0 else 0,
        " retracted_rows=", retr,
        why,
        sep="",
        file=_STDERR,
    )


def run_subrg_scan_multi[FS: FileSystem](
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var units: Slab[SubrgScanUnit[FS]],
    num_workers: Int,
    site_id: UInt32 = SITE_PARQUET_DECODE,
) raises -> Slab[Slab[RecordBatch]]:
    """Scan every unit in one fork over the union of their row groups, then
    combine and drain each unit's builders. Returns one slab of batches per
    unit, in input order, each in file order; a unit's slab is empty when it
    has no row group or aborted (the caller reads that unit itself).
    `site_id` names the fork in the scheduler trace."""
    var n_units = len(units)
    var out = Slab[Slab[RecordBatch]].create(n_units)
    var total_rgs = 0
    for u in range(n_units):
        total_rgs += units[u].n_rgs
    if total_rgs == 0:
        for _ in range(n_units):
            out.append(Slab[RecordBatch]())
        _ = cancel_token^
        _ = units^
        return out^
    var nw = max(num_workers, 1)
    var worker_builders = Slab[Optional[StreamingScanOutputBuilder]].create(n_units * nw)
    for _ in range(n_units * nw):
        worker_builders.append(Optional[StreamingScanOutputBuilder](None))
    var worker_ctx = Slab[ColumnDecodeContext].create(nw)
    for _ in range(nw):
        worker_ctx.append(ColumnDecodeContext())
    var state = _SubrgScanState[FS](units^, worker_builders^, worker_ctx^, nw)
    var ct_post = cancel_token.clone()
    _ = dispatcher.run_with_state[_SubrgScanState[FS], _SubrgScanTask[FS]](
        state, _SubrgScanTask[FS](0), nw, cancel_token^, site_id=site_id
    )
    for u in range(n_units):
        _report_degraded(state, u)
    var builders_out = Slab[Optional[StreamingScanOutputBuilder]]()
    swap(state.worker_builders, builders_out)
    for u in range(n_units):
        var aborted = Int(state.counters[u].abort.load()) > 0
        var per_unit = Slab[Optional[StreamingScanOutputBuilder]].create(nw)
        for w in range(nw):
            per_unit.append(builders_out.take_slot_unchecked(u * nw + w))
        # Combine even an aborted unit, so every builder drops on this thread.
        var combined = state.units[u].sink.combine_workers(per_unit^, nw, Pointer(to=dispatcher), ct_post.clone())
        if aborted:
            _ = combined^
            out.append(Slab[RecordBatch]())
            continue
        out.append(
            state.units[u].sink.drain(
                combined^, state.units[u].chunk_schema.copy(), Pointer(to=dispatcher), ct_post.clone()
            )
        )
    builders_out.set_len_unchecked(0)
    _ = ct_post^
    _ = state^
    return out^


def run_subrg_scan[FS: FileSystem](
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var sink: ScanCollectChunkSink,
    var reader: ParquetReader[FS],
    var plan: SubrgScanPlan,
    var chunk_schema: Schema,
    has_filter: Bool,
    var filter_pred: Optional[Expr],
    num_workers: Int,
    has_string_dict_proj: Bool = False,
) raises -> Slab[RecordBatch]:
    """`run_subrg_scan_multi` of one unit: the scan's batches in file order,
    or an empty slab (no row group, or a string-dictionary refusal)."""
    var units = Slab[SubrgScanUnit[FS]].create(1)
    units.append(
        SubrgScanUnit[FS](reader^, plan^, chunk_schema^, has_filter, filter_pred^, has_string_dict_proj, sink^)
    )
    var res = run_subrg_scan_multi[FS](dispatcher, cancel_token^, units^, num_workers)
    var only = res.take_slot_unchecked(0)
    res.set_len_unchecked(0)
    return only^
