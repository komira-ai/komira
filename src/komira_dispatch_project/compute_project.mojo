# =============================================================================
# compute_project.mojo: the computed-projection evaluator over a resident batch
# =============================================================================
#
# Evaluates a projection (an `ExprArray` in output order and the declared
# output `Schema`, the payload of a physical plan's project operator) over a
# `RecordBatch` already in memory, and returns the projected batch.
#
# Each output expression takes one route (`compute_project_routes`):
#   * a column reference, or an alias of one, is copied;
#   * a literal is broadcast to the batch's row count;
#   * CASE goes to `komira_batch_eval._eval_when_expr`;
#   * REGEXP, SUBSTRING, the string functions, the type-preserving numeric
#     functions, an expression that calls a UDF anywhere, EXTRACT, the null
#     tests, the nested extracts and CAST go to the column evaluator
#     `komira_batch_eval._eval_column_expr`;
#   * a strict arithmetic expression over an input that holds a NULL, or one
#     that holds a math op whose domain is checked, goes to the column
#     evaluator too;
#   * everything else is translated by `lower_untyped_expr` and evaluated by
#     the per-DType `komira_eval.ExpressionExecutor` walkers on the I64, F64
#     or I32 channel (a FLOAT64 result first tries the dense evaluator,
#     `project_dense_f64`).
#
# The contract: the output batch matches the declared schema, or the
# evaluator returns None (a decline). It never returns a column whose type
# or length differs from what the schema declares, because a downstream
# kernel reads the column at the declared width. An integer overflow is not
# a decline: it raises (the value does not exist in the output type, and no
# other route can answer it). Any other error out of the column evaluator
# raises too.
#
# The two switches `dense_f64` and `dense_par` are flags the caller passes
# (both default on): `dense_f64 = False` runs the walker for every FLOAT64
# computed column, and `dense_par = False` keeps the dense evaluator on the
# calling thread.
# =============================================================================

from std.collections import Optional, Dict, List

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, Field, SchemaBuilder
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_batch_eval.eval_case import _eval_when_expr
from komira_batch_eval.eval_column import _eval_column_expr
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import (
    broadcast_scalar,
    copy_column,
    materialize_selection_if_present,
)
from komira_eval.expression_executor import ExpressionExecutor, DecimalSpec
from komira_kernels.runtime_expr import RuntimeExpr
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_CAST,
    EXPR_EXTRACT,
    EXPR_LITERAL,
    EXPR_REGEXP,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_SUBSTRING,
    EXPR_UNARY_OP,
    EXPR_WHEN,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.expr_udf_sites import expr_carries_udf_call
from komira_plan_ir.logical_plan import ExprArray
from komira_scalar_arithmetic.int_overflow import is_int_overflow_error

from .compute_project_routes import (
    _build_col_maps,
    _expr_has_domain_checked_math,
    _expr_is_strict_null_propagating,
    _is_cast_output,
    _is_extract_output,
    _is_nested_extract_output,
    _is_null_test_output,
    _is_num_typepres_output,
    _is_regexp_output,
    _is_string_fn_output,
    _is_substring_output,
    _passthrough_col_index,
    _passthrough_storage_compatible,
    _strict_overlay_input_scan,
    _varlen_offset_width_alias,
    _when_expr_ref,
    is_literal_output_expr,
)
from .lower_untyped_expr import (
    translate_expr,
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I32,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_UNSUPPORTED,
)
from .lower_untyped_expr_dtype import _infer_runtime_dtype
from .project_dense_f64 import try_eval_dense_f64_pooled


def _infer_computed_family(
    imm e: Expr, imm name_to_dtype: Dict[String, Int]
) -> Int:
    """The runtime family of the computed expression `e` (the walker channel
    that evaluates it), UNSUPPORTED when it has none. `_infer_runtime_dtype`
    is declared `raises` but does not raise; an error would read as
    UNSUPPORTED."""
    try:
        return _infer_runtime_dtype(e, name_to_dtype)
    except:
        return RUNTIME_DTYPE_UNSUPPORTED  # cov: unreachable every Dict read in _infer_runtime_dtype is guarded by a membership test


def _column_conforms(
    imm col: Column[HeapRegion], declared_at: ArrowType, n_rows: Int
) -> Bool:
    """True iff `col` has the declared type and one value per row of the
    batch: the condition for an evaluated column to enter the output. Every
    evaluator this module calls answers one value per input row, so in
    practice the type is the half that can fail; the length is checked so
    that a column of another length could never reach a consumer."""
    return col.arrow_type == declared_at and col.length() == n_rows


def _eval_computed_column[
    has_pool: Bool, disp_o: Origin[mut=True], //, dtype: DType
](
    imm batch: RecordBatch,
    imm e: Expr,
    imm name_to_idx: Dict[String, Int],
    imm name_to_dtype: Dict[String, Int],
    fam: Int,
    pool_h: SharedForkJoinHandle[has_pool, disp_o],
    dense_f64: Bool,
    dense_par: Bool,
) raises -> Optional[Column[HeapRegion]]:
    """Evaluate one computed output expression over every row of `batch` into
    a `Column[dtype]`, or None when the translator or the walker cannot
    (the caller declines).

    Translates `e` into a `RuntimeExpr` pool, runs the `dtype` walker of
    `ExpressionExecutor` over an identity selection, and builds the column.
    `fam` is the family `_infer_computed_family` chose for `dtype`. For
    FLOAT64 with `dense_f64` set, the dense evaluator runs first and serves
    the column when it admits the expression; `dense_par` lets it fan out
    over `pool_h`."""
    var pool = List[RuntimeExpr]()
    var string_pool = List[String]()
    var decimal_pool = List[DecimalSpec]()
    var in_list_pool = List[List[ScalarValue]]()
    var when_pool = List[List[Int]]()
    var root_idx: Int
    try:
        root_idx = translate_expr(
            e,
            pool,
            name_to_idx,
            name_to_dtype,
            string_pool,
            decimal_pool,
            in_list_pool,
            when_pool,
        )
    except:
        return None
    if len(pool) == 0:
        return None  # cov: unreachable translate_expr appends at least one node or raises

    # The executor resolves a column leaf by NAME, so the name table lists
    # the batch's columns in position order (the order `name_to_idx` holds).
    var col_names = List[String]()
    var ncols = batch.schema.num_columns()
    for i in range(ncols):
        col_names.append(batch.schema.field_name(i))

    comptime if dtype == DType.float64:
        if dense_f64:
            var dense = try_eval_dense_f64_pooled(
                pool_h, pool, root_idx, col_names, batch, dense_par
            )
            if dense:
                return dense^

    var exec_ = ExpressionExecutor(
        pool^,
        root_idx,
        col_names^,
        string_pool^,
        decimal_pool^,
        in_list_pool^,
        when_pool^,
    )

    # The identity selection, sized to the row count: `append` checks its
    # capacity only in a debug build, so a selection of the default size
    # would be written past its end on a large batch.
    var nrows = batch.num_rows()
    var sel = RowSelectionVector(nrows)
    for i in range(nrows):
        sel.append(UInt32(i))

    var view = batch_view_over(batch)
    var out = List[Scalar[dtype]]()

    # Every walker error but one means "this route cannot evaluate this
    # shape", and the caller declines. An integer overflow means the value
    # does not exist in the output type, so it propagates with its message
    # (`is_int_overflow_error` recognises it).
    comptime if dtype == DType.int64:
        try:
            exec_.eval_to_list_i64_from_view(
                view, root_idx, sel, rebind[List[Scalar[DType.int64]]](out)
            )
        except e:
            if is_int_overflow_error(String(e)):
                raise e^
            return None
    elif dtype == DType.float64:
        try:
            exec_.eval_to_list_f64_from_view(
                view, root_idx, sel, rebind[List[Scalar[DType.float64]]](out)
            )
        except e:
            if is_int_overflow_error(String(e)):
                raise e^
            return None
    else:  # DType.int32
        # The translator has no I32-family node: an I32-family expression is
        # a bare INT32 column (served by the passthrough arm) or I32
        # arithmetic (refused by `_translate_binary`), so no translated pool
        # reaches this channel.
        try:
            exec_.eval_to_list_i32_from_view(  # cov: unreachable no translated pool has an I32 root (see above)
                view, root_idx, sel, rebind[List[Scalar[DType.int32]]](out)
            )
        except e:  # cov: unreachable no translated pool has an I32 root (see above)
            if is_int_overflow_error(String(e)):  # cov: unreachable no translated pool has an I32 root (see above)
                raise e^  # cov: unreachable no translated pool has an I32 root (see above)
            return None  # cov: unreachable no translated pool has an I32 root (see above)

    var arr = PrimitiveArray[dtype].from_list(out^)
    return Optional[Column[HeapRegion]](Column.from_primitive[dtype](arr^))


def eval_project_exprs_over_batch_on_dispatcher(
    mut dispatcher: LocalDispatcher[NoopSink],
    var batch: RecordBatch,
    imm exprs: ExprArray,
    imm out_schema: Schema,
    dense_f64: Bool = True,
    dense_par: Bool = True,
) raises -> Optional[RecordBatch]:
    """`eval_project_exprs_over_batch` for a caller that holds a dispatcher:
    the same answer, with the dense FLOAT64 evaluator able to fan a column
    out over the dispatcher's workers.

    The handle points at `dispatcher` at its concrete origin. Its one
    consumer is `SharedForkJoinHandle.run`, a fork-join wave that joins every
    task before it returns, so nothing holds the handle after this call."""
    return _eval_project_exprs_impl[True, origin_of(dispatcher)](
        batch^,
        exprs,
        out_schema,
        SharedForkJoinHandle[True, origin_of(dispatcher)](
            Optional[Pointer[LocalDispatcher[NoopSink], origin_of(dispatcher)]](
                Pointer(to=dispatcher)
            )
        ),
        dense_f64,
        dense_par,
    )


def eval_project_exprs_over_batch(
    var batch: RecordBatch,
    imm exprs: ExprArray,
    imm out_schema: Schema,
    dense_f64: Bool = True,
    dense_par: Bool = True,
) raises -> Optional[RecordBatch]:
    """Evaluate the projection on the calling thread. See
    `_eval_project_exprs_impl` for the contract.

    The serial handle carries no dispatcher. Its origin parameter is the
    origin of a local it never reads (`serial_anchor`), so no wildcard origin
    is named; with `has_pool = False` the handle's pointer is compiled out of
    every wave."""
    var serial_anchor = 0
    return _eval_project_exprs_impl[False, origin_of(serial_anchor)](
        batch^,
        exprs,
        out_schema,
        SharedForkJoinHandle[False, origin_of(serial_anchor)](
            Optional[Pointer[LocalDispatcher[NoopSink], origin_of(serial_anchor)]](
                None
            )
        ),
        dense_f64,
        dense_par,
    )


def _eval_project_exprs_impl[
    has_pool: Bool, disp_o: Origin[mut=True]
](
    var batch: RecordBatch,
    imm exprs: ExprArray,
    imm out_schema: Schema,
    pool_h: SharedForkJoinHandle[has_pool, disp_o],
    dense_f64: Bool,
    dense_par: Bool,
) raises -> Optional[RecordBatch]:
    """Evaluate `exprs`, in output order, against `out_schema` over the rows
    of `batch`, one output column per expression.

    Returns:
      * `Some(out_batch)` when every output expression was served, each
        column of the declared type and of `batch`'s row count.
      * `None` when any output is outside the evaluator's reach: an empty
        expression list, a schema whose column count differs, a column type
        that would differ from the declared one, a translator refusal, a
        column the batch lacks. The caller declines.

    Raises on an integer overflow and on an error the column evaluator
    raises."""
    var n_exprs = len(exprs)
    if n_exprs == 0:
        return None

    # A batch that still carries an unapplied selection mask holds the rows
    # its predicate rejected. This evaluator neither reads nor forwards the
    # mask, so the selection is applied first: a rejected row could otherwise
    # raise in a kernel with a row precondition, and would reach the caller
    # as a live row.
    batch = materialize_selection_if_present(batch^)

    # Every downstream consumer reads the output against `out_schema`, so the
    # output must have exactly one column per expression, each of the
    # declared type.
    if out_schema.num_columns() != n_exprs:
        return None

    var n_rows = batch.num_rows()
    var name_to_idx = Dict[String, Int]()
    var name_to_dtype = Dict[String, Int]()
    _ = _build_col_maps(batch, name_to_idx, name_to_dtype)

    var rbb = RecordBatchBuilder.with_capacity(n_exprs)
    var sb = SchemaBuilder()

    for i in range(n_exprs):
        ref e = exprs[i]
        var out_name = out_schema.field_name(i)
        var declared_at = out_schema.field_arrow_type(i)

        # A column reference: copy the source column. Its type must share
        # storage with the declared type (`_passthrough_storage_compatible`:
        # a temporal column decoded as its storage integer), or be the same
        # variable-length type at the other offset width
        # (`_varlen_offset_width_alias`); anything else declines.
        var pass_idx = _passthrough_col_index(batch, e)
        if pass_idx >= 0:
            var src_at = batch.schema.field_arrow_type(pass_idx)
            if not (
                _passthrough_storage_compatible(src_at, declared_at)
                or _varlen_offset_width_alias(src_at, declared_at)
            ):
                return None
            var src_nullable = batch.schema.field_nullable(pass_idx)
            rbb.add_column(copy_column(batch, pass_idx))
            # The field is carried whole, never rebuilt with the three-argument
            # `Field(name, type, nullable)`, which zeroes the decimal precision
            # and scale, the time zone and the dictionary index type. The same
            # type as declared takes the plan's field; a storage alias takes
            # the source column's field, so the output field states the type
            # the copied column has.
            var pass_field: Field
            if src_at == declared_at:
                pass_field = out_schema.field_at(i)
            else:
                pass_field = batch.schema.field_at(pass_idx)
            pass_field.name = out_name
            pass_field.nullable = src_nullable
            sb.add_field(pass_field^)
            continue

        # A literal: broadcast to this batch's row count (read here, per
        # batch, never cached across the batches one projection is applied
        # to). A NULL literal declines. The broadcast column must have the
        # declared type; a literal type `broadcast_scalar` has no arm for
        # falls to a zero INT64 column, which then declines. The field is
        # carried from `out_schema` (a TIMESTAMP literal keeps its time
        # zone); nullability follows the broadcast column, which has no
        # validity bitmap.
        if is_literal_output_expr(e):
            var lit_sv: ScalarValue
            if e.tag == EXPR_LITERAL:
                lit_sv = e.literal_value()
            else:
                lit_sv = e.alias_child_ref().literal_value()
            if lit_sv.is_null():
                return None
            var lit_col = broadcast_scalar(lit_sv, n_rows)
            if not _column_conforms(lit_col, declared_at, n_rows):
                return None
            var lit_field = out_schema.field_at(i)
            lit_field.name = out_name
            lit_field.nullable = Bool(lit_col._validity)
            rbb.add_column(lit_col^)
            sb.add_field(lit_field^)
            continue

        # CASE: `_eval_when_expr` keeps validity, builds STRING results and
        # raises on a THEN/ELSE type mismatch (that raise propagates).
        if _when_expr_ref(e):
            var case_col: Column[HeapRegion]
            if e.tag == EXPR_WHEN:
                case_col = _eval_when_expr(e, batch)
            else:
                case_col = _eval_when_expr(e.alias_child_ref(), batch)
            if not _column_conforms(case_col, declared_at, n_rows):
                return None
            var case_nullable = Bool(case_col._validity)
            rbb.add_column(case_col^)
            sb.add_field(Field(out_name, declared_at, case_nullable))
            continue

        # REGEXP: BOOL for `regexp_like`, STRING for the value forms. An
        # evaluation error (an unknown named group) propagates.
        if _is_regexp_output(e):
            var rx_col: Column[HeapRegion]
            if e.tag == EXPR_REGEXP:
                rx_col = _eval_column_expr(e, batch)
            else:
                rx_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(rx_col, declared_at, n_rows):
                return None
            var rx_nullable = Bool(rx_col._validity)
            rbb.add_column(rx_col^)
            sb.add_field(Field(out_name, declared_at, rx_nullable))
            continue

        if _is_substring_output(e):
            var sub_col: Column[HeapRegion]
            if e.tag == EXPR_SUBSTRING:
                sub_col = _eval_column_expr(e, batch)
            else:
                sub_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(sub_col, declared_at, n_rows):
                return None
            var sub_nullable = Bool(sub_col._validity)
            rbb.add_column(sub_col^)
            sb.add_field(Field(out_name, declared_at, sub_nullable))
            continue

        # The string functions: the result type is per op, so the column is
        # checked against whatever the projection declared.
        if _is_string_fn_output(e):
            var sfn_col: Column[HeapRegion]
            if e.tag == EXPR_STRING_FN or e.tag == EXPR_STRING_FN_N:
                sfn_col = _eval_column_expr(e, batch)
            else:
                sfn_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(sfn_col, declared_at, n_rows):
                return None
            var sfn_nullable = Bool(sfn_col._validity)
            rbb.add_column(sfn_col^)
            sb.add_field(Field(out_name, declared_at, sfn_nullable))
            continue

        # abs / sign / trunc / round / bit_count: the result type varies per
        # op and per operand, so the declared-type check is what stops a
        # kernel result of another width from reaching a consumer.
        if _is_num_typepres_output(e):
            var num_col: Column[HeapRegion]
            if e.tag == EXPR_UNARY_OP:
                num_col = _eval_column_expr(e, batch)
            else:
                num_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(num_col, declared_at, n_rows):
                return None
            var num_nullable = Bool(num_col._validity)
            rbb.add_column(num_col^)
            sb.add_field(Field(out_name, declared_at, num_nullable))
            continue

        # A UDF call anywhere in the tree (`f(x) * 2`, `f(g(x))`), since a UDF
        # is an ordinary expression and the walkers have no node for one. The
        # column evaluator reads the call's output column off `batch`; it
        # calls nothing, and a batch without that column raises by name.
        if expr_carries_udf_call(e):
            var udf_col: Column[HeapRegion]
            if e.tag == EXPR_ALIAS:
                udf_col = _eval_column_expr(e.alias_child_ref(), batch)
            else:
                udf_col = _eval_column_expr(e, batch)
            if not _column_conforms(udf_col, declared_at, n_rows):
                return None
            var udf_nullable = Bool(udf_col._validity)
            rbb.add_column(udf_col^)
            sb.add_field(Field(out_name, declared_at, udf_nullable))
            continue

        # EXTRACT and date_trunc. The output can be a TIMESTAMP, so the field
        # is carried from `out_schema` (the three-argument ctor would drop the
        # time zone); nullability follows the produced column, whose kernel
        # keeps the operand's validity.
        if _is_extract_output(e):
            var tm_col: Column[HeapRegion]
            if e.tag == EXPR_EXTRACT:
                tm_col = _eval_column_expr(e, batch)
            else:
                tm_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(tm_col, declared_at, n_rows):
                return None
            var tm_field = out_schema.field_at(i)
            tm_field.name = out_name
            tm_field.nullable = Bool(tm_col._validity)
            rbb.add_column(tm_col^)
            sb.add_field(tm_field^)
            continue

        # IS [NOT] NULL over any operand type. The produced column carries a
        # validity bitmap, so the field's nullability is read off it: the
        # schema then describes the buffer that was produced.
        if _is_null_test_output(e):
            var nt_col: Column[HeapRegion]
            if e.tag == EXPR_UNARY_OP:
                nt_col = _eval_column_expr(e, batch)
            else:
                nt_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(nt_col, declared_at, n_rows):
                return None
            var nt_nullable = Bool(nt_col._validity)
            rbb.add_column(nt_col^)
            sb.add_field(Field(out_name, declared_at, nt_nullable))
            continue

        # The nested extracts. The output can itself be nested, so the field
        # is carried from `out_schema` (the three-argument ctor would drop its
        # children); nullability follows the produced column (a missing map
        # key is NULL).
        if _is_nested_extract_output(e):
            var ne_col: Column[HeapRegion]
            if e.tag == EXPR_ALIAS:
                ne_col = _eval_column_expr(e.alias_child_ref(), batch)
            else:
                ne_col = _eval_column_expr(e, batch)
            if not _column_conforms(ne_col, declared_at, n_rows):
                return None
            var ne_field = out_schema.field_at(i)
            ne_field.name = out_name
            ne_field.nullable = Bool(ne_col._validity)
            rbb.add_column(ne_col^)
            sb.add_field(ne_field^)
            continue

        # CAST. The field is carried from `out_schema`: a cast to
        # DECIMAL(p, s) keeps p and s, which the three-argument ctor zeroes.
        if _is_cast_output(e):
            var cast_col: Column[HeapRegion]
            if e.tag == EXPR_CAST:
                cast_col = _eval_column_expr(e, batch)
            else:
                cast_col = _eval_column_expr(e.alias_child_ref(), batch)
            if not _column_conforms(cast_col, declared_at, n_rows):
                return None
            var cast_field = out_schema.field_at(i)
            cast_field.name = out_name
            cast_field.nullable = Bool(cast_col._validity)
            rbb.add_column(cast_col^)
            sb.add_field(cast_field^)
            continue

        # A strict arithmetic expression over an input holding a NULL, or one
        # holding a domain-checked math op (see `compute_project_routes`).
        # The tag walk runs first: it is cheaper than the schema scan.
        var nz_saw_null = False
        var nz_inputs_ok = _expr_is_strict_null_propagating(
            e
        ) and _strict_overlay_input_scan(e, batch, nz_saw_null)
        if nz_inputs_ok and (nz_saw_null or _expr_has_domain_checked_math(e)):
            var nz_col = _eval_column_expr(e, batch)
            # A type or length divergence declines rather than falling back to
            # the walkers, whose answer here is the one this arm exists to
            # avoid. A unary math node's declared type is FLOAT64, which is
            # what the math kernel returns.
            if not _column_conforms(nz_col, declared_at, n_rows):
                return None
            var nz_nullable = Bool(nz_col._validity)
            rbb.add_column(nz_col^)
            sb.add_field(Field(out_name, declared_at, nz_nullable))
            continue

        # Everything else: the walker channel of the inferred family.
        var fam = _infer_computed_family(e, name_to_dtype)
        var col_opt: Optional[Column[HeapRegion]]
        if fam == RUNTIME_DTYPE_I64:
            col_opt = _eval_computed_column[DType.int64](
                batch, e, name_to_idx, name_to_dtype, fam, pool_h,
                dense_f64, dense_par,
            )
        elif fam == RUNTIME_DTYPE_F64:
            col_opt = _eval_computed_column[DType.float64](
                batch, e, name_to_idx, name_to_dtype, fam, pool_h,
                dense_f64, dense_par,
            )
        elif fam == RUNTIME_DTYPE_I32:
            col_opt = _eval_computed_column[DType.int32](
                batch, e, name_to_idx, name_to_dtype, fam, pool_h,
                dense_f64, dense_par,
            )
        else:
            return None
        if not col_opt:
            return None
        # The channel's type must be the declared type. (The relaxation to
        # storage-compatible types belongs to the passthrough arm only.)
        var built_col = col_opt.take()
        if not _column_conforms(built_col, declared_at, n_rows):
            return None
        rbb.add_column(built_col^)
        sb.add_field(Field(out_name, declared_at, True))

    var schema = sb.build()
    var out_batch = rbb.build(schema^)
    _ = batch^
    return Optional[RecordBatch](out_batch^)
