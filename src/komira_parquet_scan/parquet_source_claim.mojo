# =============================================================================
# parquet_source_claim — the filtered decode of one claimed row group
# =============================================================================
#
# `decode_claim` decides what the morsel source does with a claimed row group
# that has a decode filter, a dynamic join filter (whose key is in this
# file), or a count-only consumer: it runs the arms of `parquet_source_arms`
# in order and then the late-materialized decode (`parquet_source_late_mat`),
# and returns the outcome. With none of the three it falls through to the
# source's plain decode.
#
# A filter column this file lacks (a multi-file scan whose schemas differ)
# reads as NULL: the row group is decoded by name and filtered
# (`filter_by_name`), so its rows survive exactly when the predicate holds for
# the NULL, as for a missing column of a union by name.
# =============================================================================

from std.builtin.swap import swap

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch
from komira_dynamic_filter.selectivity_tracker import SelectivityTracker
from komira_fs.column_set import ColumnSet
from komira_fs.file_system import FileSystem
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_phase_timers.phase_timers import PH_LATE_MAT, PH_STAGED, pt_now, pt_record
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_scan_planning.source_capability_config import SourceCapabilityConfig

from .parquet_reader import ParquetReader
from .parquet_source_arms import (
    arm_allmatch,
    arm_decode_all_then_filter,
    arm_dict_survivors,
    arm_fused_dict_count,
    arm_staged_filter,
    filter_by_name,
    resolve_filter_plan,
)
from .parquet_source_emit import OUTCOME_FALL_THROUGH, ClaimOutcome
from .parquet_source_late_mat import late_mat_decode
from .parquet_source_options import ParquetScanOptions


def _types_of(names: List[String], union_names: List[String], union_types: List[ArrowType]) raises -> List[ArrowType]:
    """The union schema's type of each of `names`.

    Raises:
        If a name is a column of no file of the scan.
    """
    var out = List[ArrowType]()
    for i in range(len(names)):
        var found = False
        for j in range(len(union_names)):
            if union_names[j] == names[i]:
                out.append(union_types[j])
                found = True
                break
        if not found:
            raise Error("parquet source: filter column '" + names[i] + "' is in no file of the scan")
    return out^


def decode_claim[FS: FileSystem, po: Origin[mut=True], fo: Origin[mut=True]](
    mut reader: ParquetReader[FS],
    rg_in_file: Int,
    caps: SourceCapabilityConfig,
    options: ParquetScanOptions,
    pool: Optional[Pointer[ExprPool, po]],
    dyn: Optional[Pointer[DynamicJoinFilter, fo]],
    projection: ColumnSet,
    preserve_dict: Bool,
    result_names: List[String],
    result_types: List[ArrowType],
    union_names: List[String],
    union_types: List[ArrowType],
    mut range_trk: SelectivityTracker,
    mut in_list_trk: SelectivityTracker,
    mut bloom_trk: SelectivityTracker,
) raises -> ClaimOutcome:
    """The outcome of the filtered decode of row group `rg_in_file` (see the
    module header); `OUTCOME_FALL_THROUGH` for the plain decode. A decode
    filter counts only with an expression pool to resolve it in."""
    var has_dyn = dyn.__bool__() and reader.column_name_to_idx_for_file(caps.dynamic_filter_key_name) >= 0
    var has_decode = caps.decode_filter_stages.__bool__() and pool.__bool__()
    if has_decode:
        has_decode = len(caps.decode_filter_stages.value()) > 0
    if not (has_dyn or caps.count_only or has_decode):
        return ClaimOutcome.fall_through()
    if not has_dyn and not has_decode:
        return ClaimOutcome.emit_count(reader.unit_num_rows(rg_in_file))
    if has_decode:
        return _decode_filtered[FS, fo](
            reader, rg_in_file, caps, options, pool.value()[], caps.decode_filter_stages.value(), has_dyn, dyn,
            projection, preserve_dict, result_names, result_types, union_names, union_types, range_trk,
            in_list_trk, bloom_trk,
        )
    var empty_pool = ExprPool()
    return _decode_filtered[FS, fo](
        reader, rg_in_file, caps, options, empty_pool, List[ExprId](), has_dyn, dyn, projection, preserve_dict,
        result_names, result_types, union_names, union_types, range_trk, in_list_trk, bloom_trk,
    )


def _decode_filtered[FS: FileSystem, fo: Origin[mut=True]](
    mut reader: ParquetReader[FS],
    rg_in_file: Int,
    caps: SourceCapabilityConfig,
    options: ParquetScanOptions,
    p: ExprPool,
    stages: List[ExprId],
    has_dyn: Bool,
    dyn: Optional[Pointer[DynamicJoinFilter, fo]],
    projection: ColumnSet,
    preserve_dict: Bool,
    result_names: List[String],
    result_types: List[ArrowType],
    union_names: List[String],
    union_types: List[ArrowType],
    mut range_trk: SelectivityTracker,
    mut in_list_trk: SelectivityTracker,
    mut bloom_trk: SelectivityTracker,
) raises -> ClaimOutcome:
    """`decode_claim` with its filters known: `stages` (empty: no decode
    filter) and the dynamic filter (`has_dyn`)."""
    var has_decode = len(stages) > 0
    var count_only = caps.count_only
    var plan = resolve_filter_plan(reader, p, stages, has_decode, caps.dynamic_filter_key_name, has_dyn)
    if not plan.resolved:
        return filter_by_name(
            reader, rg_in_file, p, stages, result_names, result_types, plan.names,
            _types_of(plan.names, union_names, union_types), preserve_dict, count_only,
        )
    if has_decode and not has_dyn:
        if count_only and options.rg_allmatch:
            var am = arm_allmatch(reader, rg_in_file, p, stages)
            if am.kind != OUTCOME_FALL_THROUGH:
                return am^
        if count_only:
            var fc = arm_fused_dict_count(reader, rg_in_file, p, stages, plan.cols)
            if fc.kind != OUTCOME_FALL_THROUGH:
                return fc^
        if not options.sel_pipe_enabled and not count_only:
            var ds = arm_dict_survivors(reader, rg_in_file, p, stages, plan.cols, projection, preserve_dict)
            if ds.kind != OUTCOME_FALL_THROUGH:
                return ds^
        if options.late_mat_disabled:
            return arm_decode_all_then_filter(
                reader, rg_in_file, p, stages, plan.cols, projection, preserve_dict, count_only
            )
    var pre_batch: Optional[RecordBatch] = None
    var pre_mask: Optional[BooleanArray] = None
    if has_decode and not has_dyn:
        var t_staged = pt_now()
        var sf = arm_staged_filter(reader, rg_in_file, p, stages, plan.cols, projection, preserve_dict, count_only)
        pt_record[PH_STAGED](t_staged)
        if sf.outcome.kind != OUTCOME_FALL_THROUGH:
            var out = ClaimOutcome.fall_through()
            swap(out, sf.outcome)
            return out^
        swap(pre_batch, sf.filter_batch)
        swap(pre_mask, sf.mask)
    var dyn_key_col = -1
    if has_dyn:
        for i in range(len(plan.names)):
            if plan.names[i] == caps.dynamic_filter_key_name:
                dyn_key_col = i
                break
    var t_late = pt_now()
    var late = late_mat_decode[FS, fo](
        reader, rg_in_file, plan, p, stages, has_decode, dyn, dyn_key_col, range_trk, in_list_trk, bloom_trk,
        pre_batch^, pre_mask^, caps.fused_eval_enabled, projection, preserve_dict, count_only,
        options.sel_pipe_enabled, options.decode_arena,
    )
    pt_record[PH_LATE_MAT](t_late)
    return late^
