# =============================================================================
# parquet_source_late_mat — the morsel source's late-materialized decode
# =============================================================================
#
# A claimed row group with a filter decodes its FILTER columns first,
# evaluates the filter, and only then decodes the rest of the projection (the
# payload), for the rows that survive:
#
#   1. the mask: the decode filter's stages (the fused kernel when it takes
#      them, else each stage, ANDed in three-valued logic), then the dynamic
#      join filter's range, IN-list and bloom masks on its INT64 key, each
#      applied while its selectivity tracker says it pays;
#   2. no survivor: skip the row group; a count-only consumer: emit the count;
#   3. a projection inside the filter columns: the filter batch, gathered and
#      reordered to the projection;
#   4. else the payload: decoded for the survivors only when the payload
#      selection mode says so and fewer than half survive; else decoded whole
#      and, by share of survivors, emitted dense with its selection mask (the
#      selection pipeline), assembled then gathered once (at least half), or
#      gathered per side;
#   every emitted batch has the projection's columns in projection order.
#
# A gather drops a row whose mask bit is UNKNOWN (data 0): only rows the WHERE
# clause is TRUE for are kept.
# =============================================================================

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_arrow.copy_column_ref import copy_column_ref
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import eval_and
from komira_column_kernels.comparison import filter_to_indices
from komira_column_kernels.compiler_helpers import gather_batch
from komira_dynamic_filter.selectivity_tracker import SelectivityTracker
from komira_fs.column_set import ColumnSet
from komira_fs.file_system import FileSystem
from komira_morsel.bloom_mask import bloom_mask_int64, in_list_mask_int64, range_mask_int64
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_morsel.fused_filter import try_fused_eval
from komira_parquet.payload_sel_trace import (
    PAYLOAD_SEL_OFF,
    incr_payload_sel_decline,
    incr_payload_sel_hit,
    incr_payload_sel_policy_skip,
    incr_payload_sel_skip,
    payload_sel_decode_mode,
)
from komira_parquet.scan_copy_trace import incr_proj_copy, incr_proj_copy_other, incr_proj_share, proj_share_enabled
from komira_phase_timers.phase_timers import (
    PH_DECODE_FILTER_COLS,
    PH_DECODE_PAYLOAD,
    PH_FILTER,
    PH_GATHER,
    pt_now,
    pt_record,
)
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool

from .cursor_grain_feed import note_whole_rg_decode
from .parquet_reader import ParquetReader
from .parquet_source_arms import FilterPlan, stages_mask
from .parquet_source_emit import ClaimOutcome
from .parquet_source_options import LATE_MAT_HIGH_SEL_THRESHOLD, sel_pipe_should_defer
from .staged_filter import payload_selection_pays


def proj_column_for_reorder(col_ref: Column[HeapRegion], num_rows: Int) raises -> Column[HeapRegion]:
    """A decoded column placed in a reordered batch: shared when the
    projection-share gate is on and the column is whole and unsliced
    (`length == num_rows`, offset 0), where sharing and copying give the same
    cells; else copied, which rebases a slice to offset 0."""
    if proj_share_enabled() and col_ref.length() == num_rows and col_ref.offset() == 0:
        incr_proj_share()
        return col_ref.share()
    incr_proj_copy()
    return copy_column_ref(col_ref, num_rows)


def _index_of(xs: List[Int], v: Int) -> Int:
    for i in range(len(xs)):
        if xs[i] == v:
            return i
    return -1


comptime _MODE_SHARE: Int = 0  # share every column
comptime _MODE_REORDER: Int = 1  # `proj_column_for_reorder`
comptime _MODE_COPY: Int = 2  # copy every column


def _assemble(
    proj: List[Int],
    filter_cols: List[Int],
    filter_batch: RecordBatch,
    payload_cols: List[Int],
    payload: Optional[RecordBatch],
    mode: Int,
) raises -> RecordBatch:
    """The projection, in order, each column from the filter batch or the
    payload batch, shared, reordered or copied by `mode`.

    Raises:
        If a projected column is in neither batch.
    """
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder.with_capacity(len(proj))
    for i in range(len(proj)):
        var at = _index_of(filter_cols, proj[i])
        if at >= 0:
            sb.add_field(filter_batch.schema.field_at_unchecked(at))
            ref c = filter_batch.column_at(at)
            if mode == _MODE_SHARE:
                b.add_column(c.share())
            elif mode == _MODE_REORDER:
                b.add_column(proj_column_for_reorder(c, filter_batch.num_rows()))
            else:
                incr_proj_copy_other()
                b.add_column(copy_column_ref(c, filter_batch.num_rows()))
            continue
        var pat = _index_of(payload_cols, proj[i])
        if pat < 0 or not payload:
            raise Error("parquet source: projected column " + String(proj[i]) + " is in neither the filter nor the payload decode")
        ref pb = payload.value()
        sb.add_field(pb.schema.field_at_unchecked(pat))
        ref c2 = pb.column_at(pat)
        if mode == _MODE_SHARE:
            b.add_column(c2.share())
        elif mode == _MODE_REORDER:
            b.add_column(proj_column_for_reorder(c2, pb.num_rows()))
        else:
            incr_proj_copy_other()
            b.add_column(copy_column_ref(c2, pb.num_rows()))
    return b.build(sb.build())


def _and_into(mut mask_opt: Optional[BooleanArray], var m: BooleanArray):
    if mask_opt:
        mask_opt = Optional(eval_and(mask_opt.value(), m))
    else:
        mask_opt = Optional(m^)


def _count(mask_opt: Optional[BooleanArray], all_rows: Int) -> Int:
    return mask_opt.value().true_count() if mask_opt else all_rows


def dynamic_filter_mask(
    df: DynamicJoinFilter,
    filter_batch: RecordBatch,
    key_col: Int,
    mut mask_opt: Optional[BooleanArray],
    mut range_trk: SelectivityTracker,
    mut in_list_trk: SelectivityTracker,
    mut bloom_trk: SelectivityTracker,
) raises -> Bool:
    """AND the dynamic join filter's masks on column `key_col` (INT64) into
    `mask_opt`, each while its tracker says it pays, recording what each
    kept. False when no row survives a range or IN-list mask."""
    var key_arr = filter_batch.column_at(key_col).as_primitive[DType.int64]()
    var n = Int(key_arr.length)
    if df.has_in_list():
        if range_trk.should_apply():
            var before = _count(mask_opt, n)
            _and_into(mask_opt, range_mask_int64(key_arr, df.range_ref()))
            range_trk.record(before, mask_opt.value().true_count())
            if mask_opt.value().true_count() == 0:
                return False
        if in_list_trk.should_apply():
            var before_il = _count(mask_opt, n)
            ref il_opt = df.in_list_ref()
            _and_into(mask_opt, in_list_mask_int64(key_arr, il_opt.value()))
            in_list_trk.record(before_il, mask_opt.value().true_count())
            if mask_opt.value().true_count() == 0:
                return False
    if bloom_trk.should_apply() and df.has_bloom():
        var before_b = _count(mask_opt, n)
        _and_into(mask_opt, bloom_mask_int64(key_arr, df.bloom_ref()))
        bloom_trk.record(before_b, mask_opt.value().true_count())
    return True


def late_mat_decode[FS: FileSystem, fo: Origin[mut=True]](
    mut reader: ParquetReader[FS],
    rg_in_file: Int,
    plan: FilterPlan,
    pool: ExprPool,
    stages: List[ExprId],
    has_decode_filter: Bool,
    dyn: Optional[Pointer[DynamicJoinFilter, fo]],
    dyn_key_col: Int,
    mut range_trk: SelectivityTracker,
    mut in_list_trk: SelectivityTracker,
    mut bloom_trk: SelectivityTracker,
    var pre_batch: Optional[RecordBatch],
    var pre_mask: Optional[BooleanArray],
    fused_eval_enabled: Bool,
    projection: ColumnSet,
    preserve_dict: Bool,
    count_only: Bool,
    sel_pipe_enabled: Bool,
    decode_arena: Bool,
) raises -> ClaimOutcome:
    """Steps 1 to 4 of the module header for one row group, after the
    caller's arms. `pre_batch` / `pre_mask` are a declined staged filter's
    filter columns and mask; `dyn_key_col` is the dynamic filter key's
    position among `plan.names` (-1: no dynamic filter)."""
    var filter_batch: RecordBatch
    if pre_batch:
        filter_batch = pre_batch.take()
    else:
        var t_cols = pt_now()
        filter_batch = reader.decode_columns_subset(rg_in_file, plan.cols, preserve_dict)
        pt_record[PH_DECODE_FILTER_COLS](t_cols)
    note_whole_rg_decode(filter_batch.num_rows())
    var mask_opt: Optional[BooleanArray] = None
    if pre_mask:
        mask_opt = pre_mask^
    elif has_decode_filter:
        ref p = pool
        var t_mask = pt_now()
        var fused = False
        if fused_eval_enabled:
            var fused_opt = try_fused_eval(p, stages, filter_batch)
            if fused_opt:
                mask_opt = Optional(fused_opt.value().take_mask())
                fused = True
        if not fused:
            mask_opt = Optional(stages_mask(p, stages, filter_batch))
        pt_record[PH_FILTER](t_mask)
        if mask_opt.value().true_count() == 0:
            return ClaimOutcome.skip()
    if dyn and dyn_key_col >= 0:
        if not dynamic_filter_mask(dyn.value()[], filter_batch, dyn_key_col, mask_opt, range_trk, in_list_trk, bloom_trk):
            return ClaimOutcome.skip()
    var total = filter_batch.num_rows()
    var mask: BooleanArray
    if mask_opt:
        mask = mask_opt.take()
    else:
        mask = BooleanArray.allocate(total)
        for r in range(total):
            mask.data.set(r)
    var surviving = mask.true_count()
    if surviving == 0:
        return ClaimOutcome.skip()
    if count_only:
        return ClaimOutcome.emit_count(surviving)
    var proj = projection.projected_indices(reader.unit_num_columns(rg_in_file))
    var payload_cols = List[Int]()
    for i in range(len(proj)):
        if _index_of(plan.cols, proj[i]) < 0:
            payload_cols.append(proj[i])
    if len(payload_cols) == 0:
        var working: RecordBatch
        if surviving == total:
            working = filter_batch^
        else:
            working = gather_batch(filter_batch, filter_to_indices(mask))
        var same_order = len(plan.cols) == len(proj)
        for i in range(len(proj)):
            if not same_order:
                break
            same_order = plan.cols[i] == proj[i]
        if same_order:
            return ClaimOutcome.emit(working^)
        return ClaimOutcome.emit(_assemble(proj, plan.cols, working, List[Int](), None, _MODE_REORDER))
    var mode = payload_sel_decode_mode()
    if mode != PAYLOAD_SEL_OFF:
        if surviving * 2 < total:
            if not payload_selection_pays(reader, rg_in_file, payload_cols, preserve_dict, mode):
                incr_payload_sel_policy_skip()
            else:
                var sel = reader.decode_columns_subset_selected(rg_in_file, payload_cols, preserve_dict, mask)
                if sel:
                    incr_payload_sel_hit(surviving, total)
                    var filter_sel = gather_batch(filter_batch, filter_to_indices(mask))
                    return ClaimOutcome.emit(_assemble(proj, plan.cols, filter_sel, payload_cols, sel^, _MODE_SHARE))
                incr_payload_sel_decline()
        else:
            incr_payload_sel_skip()
    var payload_full: RecordBatch
    var t_payload = pt_now()
    if decode_arena:
        payload_full = reader.decode_columns_subset_arena(rg_in_file, payload_cols, preserve_dict)
    else:
        payload_full = reader.decode_columns_subset(rg_in_file, payload_cols, preserve_dict)
    pt_record[PH_DECODE_PAYLOAD](t_payload)
    if sel_pipe_should_defer(sel_pipe_enabled, surviving, total):
        var dense = _assemble(proj, plan.cols, filter_batch, payload_cols, Optional(payload_full^), _MODE_SHARE)
        dense.set_selection_mask(mask^)
        return ClaimOutcome.emit(dense^)
    if surviving < total and Float64(surviving) >= LATE_MAT_HIGH_SEL_THRESHOLD * Float64(total):
        var t_whole = pt_now()
        var whole = _assemble(proj, plan.cols, filter_batch, payload_cols, Optional(payload_full^), _MODE_COPY)
        var gathered = ClaimOutcome.emit(gather_batch(whole, filter_to_indices(mask)))
        pt_record[PH_GATHER](t_whole)
        return gathered^
    if surviving == total:
        return ClaimOutcome.emit(
            _assemble(proj, plan.cols, filter_batch, payload_cols, Optional(payload_full^), _MODE_REORDER)
        )
    var t_idx = pt_now()
    var idx = filter_to_indices(mask)
    var fg = gather_batch(filter_batch, idx)
    var pg = gather_batch(payload_full, idx)
    var assembled = ClaimOutcome.emit(_assemble(proj, plan.cols, fg, payload_cols, Optional(pg^), _MODE_COPY))
    pt_record[PH_GATHER](t_idx)
    return assembled^
