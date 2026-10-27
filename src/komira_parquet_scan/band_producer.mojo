# =============================================================================
# band_producer — a grouped aggregate over Parquet folded band by band from
# reused decode buffers
# =============================================================================
#
# The sub-row-group aggregate builds a batch per chunk and folds it. This
# producer skips the batch: each worker decodes a row group's columns, one
# BAND of rows at a time, into its own reused per-column band buffers
# (`ColumnDecodeContext` band slots), and the sink folds a `BandView` over
# those buffers (`BandSink.consume_band`) before they are reused. Per band:
#   * the driver (the first group key) fills its codes and sets the band's
#     row count (the last band of a row group is short);
#   * every other column fills exactly that many rows: a string key its
#     codes, a numeric dictionary column its codes resolved to values, a PLAIN
#     column its values (or, with `zero_copy`, the band reads the PLAIN
#     column's page window in place);
#   * each row group's string dictionaries are copied once and borrowed by
#     every band;
#   * an optional `col <= cutoff` INT32 filter rides on the band and the fold
#     applies it inline.
#
# Scope: the group keys must be dictionary STRING columns (the plan's
# `has_string_key`); `run_band_agg` refuses any other plan. A row group the
# cursors refuse (a key that is not a dictionary string, a PLAIN column of
# another width than its output, an actual null, a short fill) aborts the
# whole run: there is no worker-side fallback (it would build string arrays on
# a worker thread), and `run_band_agg` returns an empty slab so the caller
# runs its default route. The refusals of the cursor route apply: a column
# whose annotation re-labels its type (a timestamp, an unsigned or narrow
# integer, a DATE, a DECIMAL), a non-flat footer, a row group with fewer chunks
# than the schema has leaves, and a footer row count that disagrees with a
# column's values; a dictionary offset of 0 is no dictionary page.
#
# Band width: every worker holds one live band, so the bands of all workers
# together stay within half the L3 cache; also no wider than the aggregate
# tier of the host's morsel policy; at least 1,024 rows. It is a function of
# the host profile the caller passes, so equal profiles give equal bands.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.builtin.swap import swap
from std.memory import UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.band_view import BandView
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.sched_trace import SITE_PARQUET_AGG
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_engine_runtime.band_sink import BandSink
from komira_engine_runtime.hardware import DEFAULT_L3_BYTES
from komira_engine_runtime.host_profile import HostProfile
from komira_engine_runtime.morsel_sizing_policy import MorselSizingPolicy
from komira_fs.file_system import FileSystem
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN
from komira_parquet_api.metadata import ColumnMetaData, SchemaElement
from komira_parquet_api.types import ParquetType

from .parquet_reader import ParquetReader
from .subrg_agg_plan import SubrgAggPlan
from .subrg_cursor_feed import open_subrg_cursor


comptime BAND_MIN_ROWS: Int = 1024


@always_inline
def _band_out_width(arrow_type: ArrowType) -> Int:
    """A numeric output column's band slot element width in bytes."""
    if arrow_type == ArrowType.FLOAT64 or arrow_type == ArrowType.INT64:
        return 8
    return 4


@always_inline
def _ptype_width(ptype: ParquetType) -> Int:
    if ptype == ParquetType.INT64 or ptype == ParquetType.DOUBLE:
        return 8
    return 4


def band_row_width(plan: SubrgAggPlan) -> Int:
    """The bytes one band row occupies: 4 per key (its codes) plus each
    other column's output width."""
    var row_w = 0
    for c in range(len(plan.proj_names)):
        row_w += 4 if plan.is_key_proj(c) else _band_out_width(plan.col_arrow_types[c])
    return row_w if row_w > 0 else 1


def _band_schema(plan: SubrgAggPlan) raises -> Schema:
    """A schema of the band layout (keys as INT32 codes), for the policy."""
    var sb = SchemaBuilder()
    for c in range(len(plan.proj_names)):
        var at = ArrowType.INT32 if plan.is_key_proj(c) else plan.col_arrow_types[c]
        sb.add_field(Field(plan.proj_names[c], at, False))
    return sb.build()


def compute_band_rows(plan: SubrgAggPlan, num_workers: Int, host: HostProfile) raises -> Int:
    """The band width under `host`: `min((L3 / 2) / num_workers / row width,
    the policy's aggregate tier)`, at least `BAND_MIN_ROWS`."""
    var row_w = band_row_width(plan)
    var policy = MorselSizingPolicy.for_host(host)
    var l3 = policy.profile.l3_cache_bytes
    if l3 <= 0:
        l3 = DEFAULT_L3_BYTES
    var nw = num_workers if num_workers > 0 else 1
    var residency_rows = ((l3 // 2) // nw) // row_w
    var band_rows = min(residency_rows, policy.agg_morsel_rows(_band_schema(plan)))
    return max(band_rows, BAND_MIN_ROWS)


def _has_dictionary_page(cm: ColumnMetaData) -> Bool:
    """True when the footer places a dictionary page: a positive offset below
    the first data page's (a writer with no dictionary may store 0)."""
    if not cm.dictionary_page_offset:
        return False
    var dpo = cm.dictionary_page_offset.value()
    return dpo > 0 and dpo < cm.data_page_offset


def band_rg_metadata_supported[FS: FileSystem](reader: ParquetReader[FS], rg_idx: Int, plan: SubrgAggPlan) -> Bool:
    """From the footer alone: row group `rg_idx` has a chunk for every leaf of
    the schema, every projected chunk is of a cursor type, every key a
    dictionary BYTE_ARRAY chunk, and every PLAIN non-key chunk of its output
    width."""
    ref rg = reader._meta[].row_groups[rg_idx]
    if len(rg.columns) < len(reader._meta[].schema) - 1:
        return False
    for c in range(len(plan.proj_names)):
        var reader_ci = plan.reader_col_idx[c]
        if reader_ci < 0 or reader_ci >= len(rg.columns):
            return False
        ref cm = rg.columns[reader_ci].meta_data
        var ptype = cm.type
        if (
            ptype != ParquetType.INT32 and ptype != ParquetType.INT64 and ptype != ParquetType.FLOAT
            and ptype != ParquetType.DOUBLE and ptype != ParquetType.BYTE_ARRAY
        ):
            return False
        if plan.is_key_proj(c):
            if ptype != ParquetType.BYTE_ARRAY or not _has_dictionary_page(cm):
                return False
        elif not _has_dictionary_page(cm):
            if _ptype_width(ptype) != _band_out_width(plan.col_arrow_types[c]):
                return False
    return True


def _fill_codes_lockstep(mut ctx: ColumnDecodeContext, c: Int, n_band: Int, into_value_slot: Bool) raises -> Bool:
    """Fill column `c`'s next `n_band` codes into its value slot (a string
    key) or the shared codes buffer (a numeric dictionary); False on a short
    fill."""
    var tot = 0
    while tot < n_band:
        var got = ctx.band_fill_codes_at(c, n_band - tot, tot, into_value_slot)
        if got == 0:
            break
        tot += got
    return tot == n_band


def _fill_band_columns(
    mut ctx: ColumnDecodeContext, plan: SubrgAggPlan, driver_ci: Int, n_band: Int, zc: List[Bool]
) raises -> Bool:
    """Fill or commit every column but the driver to exactly `n_band` rows;
    False on a short fill."""
    for c in range(len(plan.proj_names)):
        if c == driver_ci:
            continue
        if zc[c]:
            ctx.band_commit_grain(c, n_band)
        elif plan.is_key_proj(c):
            if not _fill_codes_lockstep(ctx, c, n_band, True):
                return False
        elif ctx.band_cursor_read(c).is_dict():
            if not _fill_codes_lockstep(ctx, c, n_band, False):
                return False
            if ctx.band_cursor_read(c).value_is_float():
                ctx.band_resolve_dict_f64(c, n_band, ctx.band_cursor_read(c).dict_values_f64_copy())
            else:
                ctx.band_resolve_dict_int(
                    c, n_band, _band_out_width(plan.col_arrow_types[c]), ctx.band_cursor_read(c).dict_values_copy()
                )
        else:
            var tot = 0
            while tot < n_band:
                var got = ctx.band_fill_flat(c, n_band - tot, tot)
                if got == 0:
                    break
                tot += got
            if tot != n_band:
                return False
    return True


def _emit_band[SINK: BandSink](
    ctx: ColumnDecodeContext,
    n_band: Int,
    plan: SubrgAggPlan,
    filter_col_idx: Int,
    filter_cutoff_i32: Int32,
    zc: List[Bool],
    sink: SINK,
    mut local: SINK.WorkerLocal,
) raises:
    """Fold one band: a `BandView` over this worker's buffers (all of one
    origin, `ctx`, borrowed for this call only)."""
    var n_cols = len(plan.proj_names)
    var band = BandView[origin_of(ctx)](n_band, n_cols)
    for c in range(n_cols):
        if plan.is_key_proj(c):
            band.push_dict_string_col(
                ctx.band_col_view(c, n_band * 4), ctx.band_dict_off_view2(c), ctx.band_dict_bytes_view2(c)
            )
        elif zc[c]:
            var w = _band_out_width(plan.col_arrow_types[c])
            band.push_flat_col_page_view(ctx.band_agg_page_view(c, n_band * w), w)
        else:
            band.push_flat_col(ctx.band_col_view(c, n_band * _band_out_width(plan.col_arrow_types[c])))
    if filter_col_idx >= 0:
        band.set_inline_filter_i32_le(filter_col_idx, filter_cutoff_i32)
    sink.consume_band(local, band)


def _fold_one_rg_band[FS: FileSystem, SINK: BandSink](
    reader: ParquetReader[FS],
    rg_idx: Int,
    plan: SubrgAggPlan,
    filter_col_idx: Int,
    filter_cutoff_i32: Int32,
    band_rows: Int,
    zero_copy: Bool,
    mut ctx: ColumnDecodeContext,
    sink: SINK,
    mut local: SINK.WorkerLocal,
    meta_schema: List[SchemaElement],
) raises -> Bool:
    """Fold row group `rg_idx` band by band; False when the cursors refuse
    it (before a band was folded, or after: the caller aborts either way)."""
    if not band_rg_metadata_supported[FS](reader, rg_idx, plan):
        return False
    var n_cols = len(plan.proj_names)
    ref rg = reader._meta[].row_groups[rg_idx]
    var cursors = Slab[ResumableColumnCursor].create(n_cols)
    for ci in range(n_cols):
        cursors.append(open_subrg_cursor(reader._file, rg, meta_schema, plan.reader_col_idx[ci]))
    for ci in range(n_cols):
        if not cursors[ci].supported():
            return False
    for ci in range(n_cols):
        # A footer row count that disagrees with a column's values is not
        # streamed.
        if cursors[ci].num_values() != Int(rg.num_rows):
            return False
    for k in range(len(plan.key_proj_idx)):
        if not cursors[plan.key_proj_idx[k]].is_string_dict():
            return False
    for c in range(n_cols):
        if not plan.is_key_proj(c) and not cursors[c].is_dict():
            if _ptype_width(cursors[c].value_ptype()) != _band_out_width(plan.col_arrow_types[c]):
                return False
    var value_sizes = List[Int](capacity=n_cols)
    for c in range(n_cols):
        var w = 4 if plan.is_key_proj(c) else _band_out_width(plan.col_arrow_types[c])
        value_sizes.append((band_rows + SUBRG_MAX_RUN) * w)
    ctx.ensure_band_slots(n_cols, value_sizes)
    ctx.ensure_band_codes((band_rows + SUBRG_MAX_RUN) * 4)
    for c in range(n_cols):
        if plan.is_key_proj(c):
            ctx.set_rg_dict(c, cursors[c].str_dict_offsets_copy(), cursors[c].str_dict_bytes_copy())
    var driver_ci = plan.key_proj_idx[0]
    var n_key_total = cursors[driver_ci].num_values()
    var zc = List[Bool](capacity=n_cols)
    for c in range(n_cols):
        zc.append(zero_copy and not plan.is_key_proj(c) and not cursors[c].is_dict())
    ctx.set_band_cursors(cursors^)
    while True:
        # A zero-copy column's band cannot cross its page: cap the band at the
        # rows left in the shortest current page.
        var cap = band_rows
        var any_drained = False
        for c in range(n_cols):
            if zc[c]:
                var pr = ctx.band_ensure_page(c)
                if pr == 0:
                    any_drained = True
                elif pr < cap:
                    cap = pr
        if any_drained:
            cap = 0
        var n_band = ctx.band_fill_driver_codes(driver_ci, cap)
        if n_band == 0:
            break
        if not _fill_band_columns(ctx, plan, driver_ci, n_band, zc):
            return False
        _emit_band(ctx, n_band, plan, filter_col_idx, filter_cutoff_i32, zc, sink, local)
    for k in range(len(plan.key_proj_idx)):
        if ctx.band_cursor_read(plan.key_proj_idx[k]).rows_emitted() != n_key_total:
            return False
    return True


struct _BandAggState[FS: FileSystem, SINK: BandSink](KeepAlive):
    """The fork's state: per-worker partials and decode buffers (worker
    `wid` touches only slot `wid`), the read-only sink, reader and plan, and
    the shared row group cursor and abort count."""

    var worker_locals: Slab[Optional[Self.SINK.WorkerLocal]]
    var worker_ctx: Slab[ColumnDecodeContext]
    var num_workers: Int
    var sink: Self.SINK
    var reader: ParquetReader[Self.FS]
    var n_rgs: Int
    var plan: SubrgAggPlan
    var filter_col_idx: Int
    var filter_cutoff_i32: Int32
    var band_rows: Int
    var zero_copy: Bool
    var counters: Slab[_BandCounters]

    def __init__(
        out self,
        var sink: Self.SINK,
        var reader: ParquetReader[Self.FS],
        var plan: SubrgAggPlan,
        num_workers: Int,
        filter_col_idx: Int,
        filter_cutoff_i32: Int32,
        band_rows: Int,
        zero_copy: Bool,
    ):
        self.worker_locals = Slab[Optional[Self.SINK.WorkerLocal]].create(num_workers)
        for _ in range(num_workers):
            self.worker_locals.append(Optional[Self.SINK.WorkerLocal](None))
        self.worker_ctx = Slab[ColumnDecodeContext].create(num_workers)
        for _ in range(num_workers):
            self.worker_ctx.append(ColumnDecodeContext())
        self.num_workers = num_workers
        self.sink = sink^
        self.n_rgs = len(reader._meta[].row_groups)
        self.reader = reader^
        self.plan = plan^
        self.filter_col_idx = filter_col_idx
        self.filter_cutoff_i32 = filter_cutoff_i32
        self.band_rows = band_rows
        self.zero_copy = zero_copy
        self.counters = Slab[_BandCounters].create_prefilled(1)


struct _BandCounters(Deinitable):
    """The row group claim cursor and the abort count (zero-filled in
    place)."""

    var rg: AtomicI64
    var abort: AtomicI64


@fieldwise_init
struct _BandAggTask[FS: FileSystem, SINK: BandSink](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](mut self, mut state: State, worker_id: Int32, task_id: Int64) raises:
        # SAFETY: `run_band_agg` dispatches
        # `run_with_state[_BandAggState[FS, SINK], _BandAggTask[FS, SINK]]`
        # with the same parameters on both, and the pool monomorphizes the
        # pair together, so `state` is a `_BandAggState[Self.FS, Self.SINK]`.
        # The pointer is to the whole state and stays in this call.
        var sp = UnsafePointer(to=state).bitcast[_BandAggState[Self.FS, Self.SINK]]()
        var wid = Int(task_id)
        sp[].worker_locals[wid] = Optional[Self.SINK.WorkerLocal](sp[].sink.init_worker_state())
        ref local = sp[].worker_locals[wid].value()
        ref ctx = sp[].worker_ctx[wid]
        ref ctr = sp[].counters[0]
        var meta_schema = sp[].reader._meta[].schema.copy()
        while True:
            if Int(ctr.abort.load()) > 0:
                break
            var ridx = Int(ctr.rg.fetch_add(Int64(1)))
            if ridx >= sp[].n_rgs:
                break
            var ok = _fold_one_rg_band[Self.FS, Self.SINK](
                sp[].reader, ridx, sp[].plan, sp[].filter_col_idx, sp[].filter_cutoff_i32, sp[].band_rows,
                sp[].zero_copy, ctx, sp[].sink, local, meta_schema,
            )
            if not ok:
                _ = ctr.abort.fetch_add(Int64(1))
                break


def run_band_agg[FS: FileSystem, SINK: BandSink](
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var sink: SINK,
    var reader: ParquetReader[FS],
    var plan: SubrgAggPlan,
    var output_schema: Schema,
    num_workers: Int,
    filter_col_idx: Int,
    filter_cutoff_i32: Int32,
    host: HostProfile,
    zero_copy: Bool = False,
) raises -> Slab[RecordBatch]:
    """Fold every row group of `reader` band by band into `sink`, combine the
    workers' partials and drain them. `filter_col_idx` (-1 for none) is the
    projection index of an INT32 column the fold keeps where
    `value <= filter_cutoff_i32`. Returns an empty slab when a row group was
    refused (the caller runs its default route) or there is no row group.

    Raises:
        If the plan's group keys are not dictionary string columns.
    """
    if not plan.has_string_key or len(plan.key_proj_idx) == 0:
        raise Error("band producer: the plan's group keys must be dictionary string columns")
    var n_rgs = len(reader._meta[].row_groups)
    if n_rgs == 0:
        _ = cancel_token^
        return Slab[RecordBatch]()
    var nw = max(num_workers, 1)
    var band_rows = compute_band_rows(plan, nw, host)
    var state = _BandAggState[FS, SINK](
        sink^, reader^, plan^, nw, filter_col_idx, filter_cutoff_i32, band_rows, zero_copy
    )
    _ = dispatcher.run_with_state[_BandAggState[FS, SINK], _BandAggTask[FS, SINK]](
        state, _BandAggTask[FS, SINK](0), nw, cancel_token^, site_id=SITE_PARQUET_AGG
    )
    if Int(state.counters[0].abort.load()) > 0:
        return Slab[RecordBatch]()
    var locals_out = Slab[Optional[SINK.WorkerLocal]]()
    swap(state.worker_locals, locals_out)
    var combined = state.sink.combine_workers(locals_out^, nw)
    return state.sink.drain(combined^, output_schema^)
