# =============================================================================
# parquet_source_arms — the morsel source's filtered decodes that finish a
# claimed row group early
# =============================================================================
#
# A claimed row group with a decode filter (the pushed WHERE stages) or a
# dynamic join filter, or a count-only consumer, goes through the
# late-materialized decode (`parquet_source_late_mat`). Before it, these arms
# try cheaper answers, in this order; each returns a `ClaimOutcome` and falls
# through when it does not apply:
#
#   1. count-only with no filter: the footer's row count;
#   2. count-only, one stage, statistics prove every row passes: the
#      footer's row count (`rg_allmatch`);
#   3. count-only, one `column <cmp> integer` stage over a numeric
#      dictionary chunk: the count from the codes and the dictionary;
#   4. one such stage whose column is not projected, the selection pipeline
#      off: the survivors from the codes, the projection gathered;
#   5. late materialization off: decode projection and filter columns
#      together, filter, project;
#   6. the staged filter (`staged_filter`) when it is on and worth it.
#
# A filter column absent from this file (a multi-file scan whose schemas
# differ) is read as NULL, as SQL reads a missing column of a union by name:
# `filter_by_name` decodes the columns by name and filters them.
#
# Every mask is three-valued: `evaluate_predicate` gives UNKNOWN as data 0, so
# counting and gathering data bits keeps only rows the WHERE clause is TRUE
# for.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_batch_eval.evaluate import evaluate_predicate
from komira_column_kernels.arithmetic import eval_and
from komira_column_kernels.comparison import filter_to_indices
from komira_column_kernels.compiler_helpers import collect_expr_cols, gather_batch
from komira_fs.column_set import ColumnSet
from komira_fs.file_system import FileSystem
from komira_parquet.payload_sel_trace import PAYLOAD_SEL_ALL, payload_sel_decode_mode
from komira_parquet.staged_filter_trace import (
    incr_staged_filter_declined,
    incr_staged_filter_rg,
    staged_filter_enabled,
)
from komira_plan_expr.expr import Expr
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool

from .cursor_grain_feed import note_whole_rg_decode
from .parquet_reader import ParquetReader
from .parquet_source_emit import ClaimOutcome
from .parquet_source_options import ParquetScanOptions, dict_count_comparison_op
from .staged_filter import (
    SelectionPlan,
    resolve_conjunct_columns,
    run_staged_filter,
    selection_plan_for,
    split_and_conjuncts,
    staged_emit_batch,
    staged_filter_worthwhile,
    staged_handoff,
)


struct FilterPlan(Movable):
    """The filter columns of one claimed row group.

    Fields:
        names: the distinct filter column names, in first-use order (the
            decode filter's columns, then the dynamic filter's key).
        cols: their leaf indices in this file, in the same order; empty when
            `resolved` is False.
        resolved: every name is a column of this file.
    """

    var names: List[String]
    var cols: List[Int]
    var resolved: Bool

    def __init__(out self, var names: List[String], var cols: List[Int], resolved: Bool):
        self.names = names^
        self.cols = cols^
        self.resolved = resolved


def resolve_filter_plan[FS: FileSystem](
    reader: ParquetReader[FS],
    pool: ExprPool,
    stages: List[ExprId],
    has_decode_filter: Bool,
    dyn_key_name: String,
    has_dyn_filter: Bool,
) raises -> FilterPlan:
    """The filter columns of a claimed row group and their indices here."""
    var all_names = List[String]()
    if has_decode_filter:
        for i in range(len(stages)):
            collect_expr_cols(pool.resolve(stages[i]), all_names)
    if has_dyn_filter:
        all_names.append(dyn_key_name)
    var names = List[String]()
    for i in range(len(all_names)):
        var seen = False
        for j in range(len(names)):
            if names[j] == all_names[i]:
                seen = True
                break
        if not seen:
            names.append(all_names[i])
    var cols = List[Int]()
    for i in range(len(names)):
        var ci = reader.column_name_to_idx_for_file(names[i])
        if ci < 0:
            return FilterPlan(names^, List[Int](), False)
        cols.append(ci)
    return FilterPlan(names^, cols^, True)


def stages_mask(pool: ExprPool, stages: List[ExprId], batch: RecordBatch) raises -> BooleanArray:
    """The AND of every stage over `batch` (every row passes when there is
    no stage); it stops early once no row passes."""
    var mask_opt: Optional[BooleanArray] = None
    for i in range(len(stages)):
        var m = evaluate_predicate(pool.resolve(stages[i]), batch)
        if mask_opt:
            mask_opt = Optional(eval_and(mask_opt.value(), m))
        else:
            mask_opt = Optional(m^)
        if mask_opt.value().true_count() == 0:
            break
    if not mask_opt:
        var all = BooleanArray.allocate(batch.num_rows())
        for r in range(batch.num_rows()):
            all.data.set(r)
        return all^
    return mask_opt.take()


def _contains(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _first_cols(var batch: RecordBatch, n: Int) raises -> RecordBatch:
    """The first `n` columns of `batch`, shared."""
    if n == batch.num_columns():
        return batch^
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder.with_capacity(n)
    for i in range(n):
        sb.add_field(batch.schema.field_at_unchecked(i))
        b.add_column(batch.column_at(i).share())
    return b.build(sb.build())


def arm_allmatch[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_in_file: Int,
    pool: ExprPool,
    stages: List[ExprId],
) raises -> ClaimOutcome:
    """Count-only, one stage: the footer's row count when the statistics
    prove every row passes."""
    if len(stages) != 1:
        return ClaimOutcome.fall_through()
    if reader.unit_all_match(rg_in_file, pool.resolve(stages[0])):
        return ClaimOutcome.emit_count(reader.unit_num_rows(rg_in_file), allmatch=True)
    return ClaimOutcome.fall_through()


def arm_fused_dict_count[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_in_file: Int,
    pool: ExprPool,
    stages: List[ExprId],
    filter_cols: List[Int],
) raises -> ClaimOutcome:
    """Count-only, one `column <cmp> integer` stage over one column: the
    count from a numeric dictionary chunk's codes (skip when 0)."""
    if len(filter_cols) != 1 or len(stages) != 1:
        return ClaimOutcome.fall_through()
    ref stg = pool.resolve(stages[0])
    var op = dict_count_comparison_op(stg)
    if op == 0xFF:
        return ClaimOutcome.fall_through()
    var surv = reader.fused_dict_count(rg_in_file, filter_cols[0], op, stg.binary_right_ref().literal_value().int_val)
    if not surv:
        return ClaimOutcome.fall_through()
    if surv.value() == 0:
        return ClaimOutcome.skip()
    return ClaimOutcome.emit_count(surv.value())


def arm_dict_survivors[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_in_file: Int,
    pool: ExprPool,
    stages: List[ExprId],
    filter_cols: List[Int],
    projection: ColumnSet,
    preserve_dict: Bool,
) raises -> ClaimOutcome:
    """One `column <cmp> integer` stage whose column is not projected: the
    survivors from a numeric dictionary chunk's codes (no null in the row
    group), and the projection decoded and gathered."""
    if len(filter_cols) != 1 or len(stages) != 1:
        return ClaimOutcome.fall_through()
    var proj = projection.projected_indices(reader.unit_num_columns(rg_in_file))
    if _contains(proj, filter_cols[0]):
        return ClaimOutcome.fall_through()
    ref stg = pool.resolve(stages[0])
    var op = dict_count_comparison_op(stg)
    if op == 0xFF:
        return ClaimOutcome.fall_through()
    var surv = reader.fused_dict_survivors(rg_in_file, filter_cols[0], op, stg.binary_right_ref().literal_value().int_val)
    if not surv:
        return ClaimOutcome.fall_through()
    var idx = surv.take()
    if len(idx) == 0:
        return ClaimOutcome.skip()
    var payload = reader.decode_columns_subset(rg_in_file, proj, preserve_dict)
    if len(idx) == payload.num_rows():
        return ClaimOutcome.emit(payload^)
    return ClaimOutcome.emit(gather_batch(payload, idx))


def _filter_then_project(
    var batch: RecordBatch, n_proj: Int, pool: ExprPool, stages: List[ExprId], count_only: Bool
) raises -> ClaimOutcome:
    """Filter `batch` (projection columns first, then the other filter
    columns) by the stages and keep its first `n_proj` columns."""
    var mask = stages_mask(pool, stages, batch)
    var surv = mask.true_count()
    if surv == 0:
        return ClaimOutcome.skip()
    if count_only:
        return ClaimOutcome.emit_count(surv)
    var kept: RecordBatch
    if surv == batch.num_rows():
        kept = batch^
    else:
        kept = gather_batch(batch, filter_to_indices(mask))
    return ClaimOutcome.emit(_first_cols(kept^, n_proj))


def arm_decode_all_then_filter[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_in_file: Int,
    pool: ExprPool,
    stages: List[ExprId],
    filter_cols: List[Int],
    projection: ColumnSet,
    preserve_dict: Bool,
    count_only: Bool,
) raises -> ClaimOutcome:
    """Late materialization off: the projection and the filter columns in
    one decode, filtered, projected."""
    var proj = projection.projected_indices(reader.unit_num_columns(rg_in_file))
    var n_proj = len(proj)
    for i in range(len(filter_cols)):
        if not _contains(proj, filter_cols[i]):
            proj.append(filter_cols[i])
    var batch = reader.decode_columns_subset(rg_in_file, proj, preserve_dict)
    note_whole_rg_decode(batch.num_rows())
    return _filter_then_project(batch^, n_proj, pool, stages, count_only)


def filter_by_name[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_in_file: Int,
    pool: ExprPool,
    stages: List[ExprId],
    result_names: List[String],
    result_types: List[ArrowType],
    filter_names: List[String],
    filter_types: List[ArrowType],
    preserve_dict: Bool,
    count_only: Bool,
) raises -> ClaimOutcome:
    """A row group of a file that lacks a filter column: the result columns
    and the filter columns decoded by name (a column the file lacks as typed
    NULLs), filtered, projected."""
    var names = result_names.copy()
    var types = result_types.copy()
    for i in range(len(filter_names)):
        var seen = False
        for j in range(len(names)):
            if names[j] == filter_names[i]:
                seen = True
                break
        if not seen:
            names.append(filter_names[i])
            types.append(filter_types[i])
    var batch = reader.decode_columns_by_name_remap(rg_in_file, names, types, preserve_dict)
    note_whole_rg_decode(batch.num_rows())
    return _filter_then_project(batch^, len(result_names), pool, stages, count_only)


struct StagedArmResult(Movable):
    """The staged filter's result: an outcome, or (when its lead declined)
    the filter columns and mask the one-shot path continues with.

    Fields:
        outcome: the outcome (`fall_through` when the one-shot path goes on).
        filter_batch / mask: set when the lead declined.
    """

    var outcome: ClaimOutcome
    var filter_batch: Optional[RecordBatch]
    var mask: Optional[BooleanArray]

    def __init__(out self, var outcome: ClaimOutcome):
        self.outcome = outcome^
        self.filter_batch = None
        self.mask = None


def arm_staged_filter[FS: FileSystem](
    reader: ParquetReader[FS],
    rg_in_file: Int,
    pool: ExprPool,
    stages: List[ExprId],
    filter_cols: List[Int],
    projection: ColumnSet,
    preserve_dict: Bool,
    count_only: Bool,
) raises -> StagedArmResult:
    """The staged filter (`staged_filter`), when on and worth it: the
    survivors' projection, or their count; a declined lead hands its columns
    and mask on."""
    if not staged_filter_enabled():
        return StagedArmResult(ClaimOutcome.fall_through())
    var conj = List[Expr]()
    for i in range(len(stages)):
        split_and_conjuncts(pool.resolve(stages[i]), conj)
    var conj_cols = List[List[Int]]()
    var all_cols = List[Int]()
    var mode = payload_sel_decode_mode()
    var proj = projection.projected_indices(reader.unit_num_columns(rg_in_file))
    if not ((len(proj) > 0 or count_only) and resolve_conjunct_columns(reader, conj, conj_cols, all_cols)):
        return StagedArmResult(ClaimOutcome.fall_through())
    var plan = selection_plan_for(reader, rg_in_file, all_cols, preserve_dict, mode == PAYLOAD_SEL_ALL)
    if not staged_filter_worthwhile(conj_cols, plan):
        return StagedArmResult(ClaimOutcome.fall_through())
    incr_staged_filter_rg()
    note_whole_rg_decode(reader.unit_num_rows(rg_in_file))
    var res = run_staged_filter(reader, rg_in_file, conj, conj_cols, plan, preserve_dict)
    if res.rows == 0:
        return StagedArmResult(ClaimOutcome.skip())
    if res.declined:
        incr_staged_filter_declined()
        var out = StagedArmResult(ClaimOutcome.fall_through())
        staged_handoff(reader, rg_in_file, res, filter_cols, conj, preserve_dict, out.filter_batch, out.mask)
        return out^
    if count_only:
        return StagedArmResult(ClaimOutcome.emit_count(res.rows))
    return StagedArmResult(ClaimOutcome.emit(staged_emit_batch(reader, rg_in_file, res, proj, mode, preserve_dict)))
