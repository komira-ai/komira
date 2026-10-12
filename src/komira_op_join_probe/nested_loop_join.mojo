# =============================================================================
# nested_loop_join -- the join probe whose condition carries a residual
# (non-equi) predicate: candidates by one equi-key (or the cross product), the
# residual evaluated over them, INNER / LEFT / SEMI / ANTI emitted.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.primitive_array import PrimitiveArray

from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_RIGHT, JOIN_FULL, JOIN_SEMI, JOIN_ANTI,
)
from komira_physical_plan.physical_plan import MorselOp
from komira_column_kernels.compiler_helpers import (
    gather_batch, copy_batch, project_batch_by_names,
)
from komira_join_assembly.compiler_join_assembly import assemble_join_result

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_join_build.join import HashJoinBuilder
from .residual_mask_eval import _joined_schema, _compute_residual_pass_mask
from .residual_semi_anti_parallel import (
    parallel_residual_semi_anti_mark,
    _residual_mark_parallel_eligible,
)


def _equi_candidates(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_name: String,
    right_key_name: String,
    mut probe_idxs: List[Int],
    mut build_idxs: List[Int],
) raises:
    """Collect candidate matched pairs by equi-key (single Int64 key)."""
    var right_key_idx = build_batch.schema.column_index(right_key_name)
    ref right_key_col = build_batch.column_at(right_key_idx)
    var right_key_arr = right_key_col.as_primitive[DType.int64]()

    var left_key_idx = probe_batch.schema.column_index(left_key_name)
    ref left_key_col = probe_batch.column_at(left_key_idx)
    var left_key_arr = left_key_col.as_primitive[DType.int64]()

    var jb = HashJoinBuilder.build(right_key_arr)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    jb.probe_inner_into(left_key_arr, build_matches, probe_matches)
    _ = left_key_arr  # keepalive
    _ = right_key_arr  # keepalive
    for i in range(len(build_matches)):
        probe_idxs.append(probe_matches[i])
        build_idxs.append(build_matches[i])


def _cross_candidates(
    num_probe_rows: Int,
    num_build_rows: Int,
    mut probe_idxs: List[Int],
    mut build_idxs: List[Int],
):
    """Collect candidate pairs as the full cross product (NLJ fallback for a
    pure non-equi / range join with zero equi-keys). O(n*m).
    """
    for p in range(num_probe_rows):
        for b in range(num_build_rows):
            probe_idxs.append(p)
            build_idxs.append(b)


def execute_residual_join_probe_parallel(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    op: MorselOp,
    residual: Expr,
) raises -> RecordBatch:
    """The residual join probe with a dispatcher. A SEMI or ANTI join over one
    non-NULL INT64 key above the size threshold (an EXISTS / NOT EXISTS with a
    correlated non-equi condition, such as TPC-H Q21's
    `l_suppkey <> l1.l_suppkey`) runs as the parallel mark join
    (`residual_semi_anti_parallel`); every other shape runs
    `execute_residual_join_probe`. Both give the same rows; the choice is
    only a route.
    """
    var jt = op.probe_join_type
    var has_equi = len(op.probe_left_keys) == 1
    if has_equi and _residual_mark_parallel_eligible(
        probe_batch, build_batch,
        op.probe_left_keys[0], op.probe_right_keys[0], jt, has_equi,
    ):
        var kept = parallel_residual_semi_anti_mark(
            dispatcher, cancel_token^,
            probe_batch, build_batch,
            op.probe_left_keys[0], op.probe_right_keys[0], jt, residual,
        )
        return _maybe_project_probe_only(kept^, op)
    _ = cancel_token^
    return execute_residual_join_probe(probe_batch, build_batch, op, residual)


def execute_residual_join_probe(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    op: MorselOp,
    residual: Expr,
    late_mat: Bool = True,
) raises -> RecordBatch:
    """Execute a join probe whose condition carries a residual predicate
    (`residual`) besides at most one equi-key pair (`op.probe_left_keys` /
    `op.probe_right_keys`; with none, every pair of rows is a candidate).
    INNER emits the passing pairs; LEFT also emits each probe row with no
    passing pair once, NULL-filled; SEMI / ANTI keep the probe rows with /
    without a passing pair. A NULL residual does not pass. RIGHT and FULL, and
    more than one equi-key, raise. `late_mat` assembles only the columns the
    residual names (see `residual_mask_eval`).
    """
    var jt = op.probe_join_type
    if jt == JOIN_RIGHT or jt == JOIN_FULL:
        raise Error(
            "a join with a residual predicate and join_type RIGHT or FULL is "
            "not supported (INNER, LEFT, SEMI and ANTI are). "
            "Workaround: rewrite as the equivalent LEFT with sides swapped."
        )

    var num_probe_rows = probe_batch.num_rows()
    var num_build_rows = build_batch.num_rows()

    var has_equi = len(op.probe_left_keys) > 0
    if has_equi and len(op.probe_left_keys) > 1:
        raise Error(
            "a join with more than one equi-key plus a residual predicate is "
            "not supported (one equi-key plus a residual, or none, is)."
        )

    if num_probe_rows == 0:
        return RecordBatch()
    if num_build_rows == 0:
        if jt == JOIN_INNER or jt == JOIN_SEMI:
            return RecordBatch()
        if jt == JOIN_ANTI:
            var anti_all = copy_batch(probe_batch)
            return _maybe_project_probe_only(anti_all^, op)
        if jt == JOIN_LEFT:
            return _emit_left_with_nullfill(
                probe_batch, build_batch, op, List[Int](), List[Int](),
            )

    var cand_probe = List[Int]()
    var cand_build = List[Int]()
    if has_equi:
        _equi_candidates(
            probe_batch, build_batch,
            op.probe_left_keys[0], op.probe_right_keys[0],
            cand_probe, cand_build,
        )
    else:
        _cross_candidates(num_probe_rows, num_build_rows, cand_probe, cand_build)

    var pass_mask: List[Bool]
    if len(cand_probe) == 0:
        pass_mask = List[Bool]()
    else:
        pass_mask = _compute_residual_pass_mask(
            probe_batch, build_batch, cand_probe, cand_build, residual, late_mat,
        )

    if jt == JOIN_INNER:
        var keep_probe = List[Int]()
        var keep_build = List[Int]()
        for i in range(len(pass_mask)):
            if pass_mask[i]:
                keep_probe.append(cand_probe[i])
                keep_build.append(cand_build[i])
        var out_schema = _joined_schema(probe_batch.schema, build_batch.schema)
        var out = assemble_join_result(
            probe_batch, build_batch, keep_probe, keep_build, out_schema,
        )
        return _maybe_project_joined(out^, op)

    if jt == JOIN_SEMI or jt == JOIN_ANTI:
        var has_pass = List[Bool](capacity=num_probe_rows)
        for _ in range(num_probe_rows):
            has_pass.append(False)
        for i in range(len(pass_mask)):
            if pass_mask[i]:
                has_pass[cand_probe[i]] = True
        var keep = List[Int]()
        var want = jt == JOIN_SEMI
        for p in range(num_probe_rows):
            if has_pass[p] == want:
                keep.append(p)
        var probe_kept = gather_batch(probe_batch, keep)
        return _maybe_project_probe_only(probe_kept^, op)

    var lf_probe = List[Int]()
    var lf_build = List[Int]()
    for i in range(len(pass_mask)):
        if pass_mask[i]:
            lf_probe.append(cand_probe[i])
            lf_build.append(cand_build[i])
    return _emit_left_with_nullfill(probe_batch, build_batch, op, lf_probe^, lf_build^)


def _emit_left_with_nullfill(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    op: MorselOp,
    var matched_probe: List[Int],
    var matched_build: List[Int],
) raises -> RecordBatch:
    """Emit a LEFT-join result: the matched (probe_idx, build_idx) pairs that
    passed the residual, plus one (probe_idx, -1) NULL-filled row for every
    probe row that had zero passing matches.
    """
    var num_probe_rows = probe_batch.num_rows()
    var matched = List[Bool](capacity=num_probe_rows)
    for _ in range(num_probe_rows):
        matched.append(False)
    for i in range(len(matched_probe)):
        matched[matched_probe[i]] = True

    var out_probe = List[Int]()
    var out_build = List[Int]()
    for i in range(len(matched_probe)):
        out_probe.append(matched_probe[i])
        out_build.append(matched_build[i])
    for p in range(num_probe_rows):
        if not matched[p]:
            out_probe.append(p)
            out_build.append(-1)

    var out_schema = _joined_schema(
        probe_batch.schema, build_batch.schema, False, True,
    )
    var out = assemble_join_result(
        probe_batch, build_batch, out_probe, out_build, out_schema,
        right_nullable=True,
    )
    return _maybe_project_joined(out^, op)


def _maybe_project_joined(var batch: RecordBatch, op: MorselOp) raises -> RecordBatch:
    """Apply `op.probe_output_cols` to a full joined-row batch (left + right
    columns), when the operator carries it."""
    if not op.probe_output_cols:
        return batch^
    var names = List[String]()
    for i in range(len(op.probe_output_cols.value())):
        var name = op.probe_output_cols.value()[i]
        for c in range(batch.schema.num_columns()):
            if batch.schema.field_name(c) == name:
                names.append(name)
                break
    if len(names) == 0:
        return RecordBatch.count_only(batch.num_rows())
    if len(names) == batch.schema.num_columns():
        return batch^
    return project_batch_by_names(batch, names)


def _maybe_project_probe_only(var batch: RecordBatch, op: MorselOp) raises -> RecordBatch:
    """Apply `op.probe_output_cols` to a SEMI/ANTI result (probe columns
    only).
    """
    if not op.probe_output_cols:
        return batch^
    var names = List[String]()
    for i in range(len(op.probe_output_cols.value())):
        var name = op.probe_output_cols.value()[i]
        for c in range(batch.schema.num_columns()):
            if batch.schema.field_name(c) == name:
                names.append(name)
                break
    if len(names) == 0:
        return RecordBatch.count_only(batch.num_rows())
    if len(names) == batch.schema.num_columns():
        return batch^
    return project_batch_by_names(batch, names)
