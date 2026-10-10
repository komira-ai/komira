# =============================================================================
# komira_sql/sql_bind_expr.mojo
#   Scalar expression binding (`_bind_scalar`) and CASE.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    EXPR_ALIAS, EXPR_BINARY_OP, EXPR_CAST, EXPR_COL_REF, EXPR_LITERAL, Expr,
    WhenCaseData,
)
from komira_plan_expr.expr_walk import (
    PlanColRefFields, walk_expr_field,
)
from komira_plan_expr.scalar_desugar import promote_int_literal_to_float
from komira_plan_expr.scalar_value import ScalarValue
from komira_sql.sql_ast import (
    SX_AGG, SX_BINARY, SX_BOOL, SX_CALL, SX_CASE, SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT,
    SX_LIKE, SX_NULL, SX_STAR, SX_STRING, SX_SUBQUERY, SX_TIMESTAMP, SX_UNARY,
    SX_WINDOW, SqlExpr, TSLIT_AWARE,
)
from komira_sql.sql_bind_call import _bind_scalar_call
from komira_sql.sql_bind_ops import (
    _map_unop, _bind_sql_operator, _bind_like, _BARE_NULL_REFUSAL, _sx_is_big_int,
    _big_int_literal_refusal, _big_int_cmp_serves, _bind_big_int_uint64,
    _int_cast_base_column, _int_cast_arith_cmp, _int_cast_cmp_side, _is_null_comparison,
    _null_comparison,
)
from komira_sql.sql_bind_scope import (
    CteScope, _date_to_days, BindScope, _resolve_col,
)
from komira_sql.sql_bind_timestamp import _timestamp_literal_micros
from komira_sql.sql_catalog import SqlCatalog


@always_inline
def _col_dtype_by_name(schema: Schema, name: String) -> DType:
    """The DType of the (case-insensitively matched) column `name` in `schema`, or
    `DTYPE_NONE` if absent."""
    var t = name.lower()
    for i in range(schema.num_columns()):
        if schema.field_name(i).lower() == t:
            return schema.field_dtype(i)
    return DTYPE_NONE


def _bound_expr_is_float(e: Expr, schema: Schema) -> Bool:
    """True iff the already-bound value Expr `e` produces a float-family result
    over `schema`: a float literal, a float column, an arithmetic with a float
    operand, an aliased float child, or a float-target CAST."""
    if e.tag == EXPR_LITERAL:
        return e.literal_value().is_float()
    if e.tag == EXPR_COL_REF:
        var dt = _col_dtype_by_name(schema, e.col_ref_name())
        return dt == DType.float64 or dt == DType.float32
    if e.tag == EXPR_ALIAS:
        return _bound_expr_is_float(e.alias_child_ref(), schema)
    if e.tag == EXPR_BINARY_OP:
        return _bound_expr_is_float(e.binary_left_ref(), schema) or _bound_expr_is_float(e.binary_right_ref(), schema)
    if e.tag == EXPR_CAST:
        var ct = e.cast_target()
        return ct == DType.float64 or ct == DType.float32
    return False


def _promote_int_literal_to_float(var e: Expr) -> Expr:
    """If `e` is an integer literal, return the equivalent float64 literal;
    otherwise return `e` unchanged: the SQL common-type rule for branch
    unification (`... THEN <float> ELSE 0 END` makes the `0` a `0.0`, since
    every arm must share one dtype)."""
    return promote_int_literal_to_float(e^)


def _bind_case(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """Bind a SX_CASE node -> an `EXPR_WHEN` IR Expr. Each WHEN condition and
    THEN result binds via `_bind_scalar` (a simple `CASE x WHEN v ...` was
    already desugared to `x = v` conditions by the parser, so only the
    searched form is seen here). An omitted ELSE binds to a typed NULL
    literal, SQL's default when no branch matches, so a non-matching row is
    NULL, never 0.

    SQL common-type rule: if any THEN result or the ELSE default is
    float-typed, every integer-literal branch is promoted to a float literal,
    so all branches share the float dtype (`then l_disc_price else 0` binds to
    an all-float CASE)."""
    ref cd = sx._case.value()
    var n = len(cd.conds)
    if n == 0:
        raise Error("SQL bind error: CASE requires at least one WHEN branch")

    # Bind conditions + results first; detect the branch family before choosing an
    # omitted-ELSE NULL's type (so the null default matches the THEN branches).
    var conds = List[Expr]()
    var results = List[Expr]()
    # A `THEN NULL` arm is typed from its siblings, as the omitted / `ELSE NULL`
    # default below is: a FLOAT64 NULL if any arm is a float, an INT64 NULL if
    # every non-NULL arm is an INT64. DuckDB unifies a NULL arm to the other
    # arms' type the same way. Beside any other type (a string, a date, a bool,
    # an INT32) it is refused by name: the typed NULL values this plan carries
    # are FLOAT64 and INT64 only.
    var null_arm = List[Bool]()
    for i in range(n):
        conds.append(_bind_scalar(cd.conds[i], schema, scope, catalog, cte_scope, prebound))
        if cd.results[i].tag == SX_NULL:
            null_arm.append(True)
            results.append(Expr.literal(ScalarValue.null(DType.int64)))
        else:
            null_arm.append(False)
            results.append(_bind_scalar(cd.results[i], schema, scope, catalog, cte_scope, prebound))

    var any_float = False
    for i in range(len(results)):
        if not null_arm[i] and _bound_expr_is_float(results[i], schema):
            any_float = True

    # An explicit `ELSE NULL` is the omitted ELSE: it binds to the same
    # branch-typed NULL below rather than refusing a bare NULL.
    var has_else = len(cd.otherwise) == 1 and cd.otherwise[0].tag != SX_NULL
    var default_expr: Expr
    if has_else:
        default_expr = _bind_scalar(cd.otherwise[0], schema, scope, catalog, cte_scope, prebound)
        if _bound_expr_is_float(default_expr, schema):
            any_float = True
    else:
        # Omitted ELSE -> a typed NULL (SQL's default when no branch matches),
        # typed to the branch family, since every CASE arm and the default must
        # share one type.
        if any_float:
            default_expr = Expr.literal(ScalarValue.null(DType.float64))
        else:
            default_expr = Expr.literal(ScalarValue.null(DType.int64))

    var any_null_arm = False
    for i in range(len(null_arm)):
        if null_arm[i]:
            any_null_arm = True
    if any_null_arm:
        # The siblings that decide the NULL's type: every non-NULL THEN, and
        # the ELSE when one was written.
        var n_typed = 0
        var all_int64 = True
        for i in range(len(results)):
            if null_arm[i]:
                continue
            n_typed += 1
            if not _case_arm_is_int64(results[i], schema):
                all_int64 = False
        if has_else:
            n_typed += 1
            if not _case_arm_is_int64(default_expr, schema):
                all_int64 = False
        if n_typed == 0:
            # Every arm NULL: DuckDB's type is "NULL", which no column here has.
            raise Error(_BARE_NULL_REFUSAL)
        if not any_float and not all_int64:
            raise Error(
                "SQL not supported: a CASE arm `THEN NULL` beside arms that are"
                " neither INT64 nor FLOAT64 (a string, a date, a boolean or a"
                " narrower integer). DuckDB types the NULL as its sibling arms;"
                " the typed NULL values this engine's plan can carry are INT64"
                " and FLOAT64 only, and every CASE arm must share one type. A"
                " NULL beside INT64 or FLOAT64 arms is served; so is an"
                " omitted ELSE."
            )
        if any_float:
            var retyped = List[Expr]()
            for i in range(len(results)):
                if null_arm[i]:
                    retyped.append(Expr.literal(ScalarValue.null(DType.float64)))
                else:
                    retyped.append(results[i].copy())
            results = retyped^

    # Common-type pass: if any value branch is float, promote int-literal branches
    # (`... THEN <float> ELSE 0 END` -> the `0` becomes `0.0`). A NULL default is
    # not an int literal, so it is left at its already-correct typed-null form.
    if any_float:
        var promoted = List[Expr]()
        for i in range(len(results)):
            promoted.append(_promote_int_literal_to_float(results[i].copy()))
        results = promoted^
        default_expr = _promote_int_literal_to_float(default_expr^)

    var cases = List[WhenCaseData]()
    for i in range(len(results)):
        cases.append(WhenCaseData(conds[i].copy(), results[i].copy()))
    return Expr.when(cases^, default_expr^)


def _case_arm_is_int64(e: Expr, schema: Schema) -> Bool:
    """The bound CASE arm `e` is provably an INT64 value (an integer literal —
    this binder's integer literals ARE int64 — or an expression the walk types
    INT64)."""
    if e.tag == EXPR_LITERAL:
        var lv = e.literal_value()
        return lv.is_int() and not lv.is_null()
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](e, schema, missing).arrow_type
    return missing.byte_length() == 0 and t == ArrowType.INT64


def _bind_scalar(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """Bind a scalar SQL expression against `schema` -> an IR `Expr`. `scope`
    resolves qualified column refs (`r.key` -> the `_right`-renamed output
    name). `catalog`, `cte_scope` and `prebound` are threaded so a scalar
    subquery operand (SX_SUBQUERY) resolves its already-bound body by index
    in `prebound`."""
    if sx.tag == SX_COLUMN:
        return Expr.col_ref(_resolve_col(sx, schema, scope))
    if sx.tag == SX_INT:
        if _sx_is_big_int(sx):
            raise Error(_big_int_literal_refusal(sx))
        return Expr.literal(ScalarValue.from_int64(sx.int_val))
    if sx.tag == SX_FLOAT:
        return Expr.literal(ScalarValue.from_float(sx.float_val))
    if sx.tag == SX_STRING:
        return Expr.literal(ScalarValue.from_string(String(sx.text)))
    if sx.tag == SX_DATE:
        return Expr.literal(ScalarValue.date32(_date_to_days(sx.text)))
    if sx.tag == SX_TIMESTAMP:
        return Expr.literal(
            ScalarValue.timestamp_micros(
                _timestamp_literal_micros(String(sx.text), sx.op == TSLIT_AWARE)
            )
        )
    if sx.tag == SX_BINARY:
        if _is_null_comparison(sx):
            if sx._binary.value().left[].tag != SX_NULL:
                return _null_comparison(sx.op, _bind_scalar(sx._binary.value().left[], schema, scope, catalog, cte_scope, prebound))
            if sx._binary.value().right[].tag != SX_NULL:
                return _null_comparison(sx.op, _bind_scalar(sx._binary.value().right[], schema, scope, catalog, cte_scope, prebound))
            raise Error(_BARE_NULL_REFUSAL)
        var moved_opt = _int_cast_arith_cmp(sx, schema, scope)
        if moved_opt:
            # The constant moved across the comparison; bind the rewritten
            # comparison, which the int-cast unwrap below then serves.
            return _bind_scalar(moved_opt.take(), schema, scope, catalog, cte_scope, prebound)
        var big_cmp = _big_int_cmp_serves(sx)
        var unwrap = _int_cast_cmp_side(sx, schema, scope)
        var lhs: Expr
        if big_cmp and _sx_is_big_int(sx._binary.value().left[]):
            lhs = _bind_big_int_uint64(sx._binary.value().left[])
        elif unwrap == 1:
            lhs = _bind_scalar(_int_cast_base_column(sx._binary.value().left[]), schema, scope, catalog, cte_scope, prebound)
        else:
            lhs = _bind_scalar(sx._binary.value().left[], schema, scope, catalog, cte_scope, prebound)
        var rhs: Expr
        if big_cmp and _sx_is_big_int(sx._binary.value().right[]):
            rhs = _bind_big_int_uint64(sx._binary.value().right[])
        elif unwrap == 2:
            rhs = _bind_scalar(_int_cast_base_column(sx._binary.value().right[]), schema, scope, catalog, cte_scope, prebound)
        else:
            rhs = _bind_scalar(sx._binary.value().right[], schema, scope, catalog, cte_scope, prebound)
        return _bind_sql_operator(sx.op, lhs^, rhs^, schema)
    if sx.tag == SX_BOOL:
        return Expr.literal(ScalarValue.from_bool(sx.int_val != Int64(0)))
    if sx.tag == SX_NULL:
        raise Error(_BARE_NULL_REFUSAL)
    if sx.tag == SX_UNARY:
        return Expr.unary(
            _map_unop(sx.op),
            _bind_scalar(sx._agg.value().arg[], schema, scope, catalog, cte_scope, prebound),
        )
    if sx.tag == SX_LIKE:
        var child = _bind_scalar(sx._agg.value().arg[], schema, scope, catalog, cte_scope, prebound)
        return _bind_like(sx, child^)
    if sx.tag == SX_CALL:
        return _bind_scalar_call(sx, schema, scope, catalog, cte_scope, prebound)
    if sx.tag == SX_CASE:
        return _bind_case(sx, schema, scope, catalog, cte_scope, prebound)
    if sx.tag == SX_SUBQUERY:
        # The subquery body was already bound (in `_bind_query`, before any
        # expression binding) into the `prebound` list; this node carries only
        # its index. Looking it up here, rather than calling `_bind_select`,
        # keeps `_bind_scalar` and `_bind_select` from being mutually
        # recursive, a shape the Mojo compiler hangs on.
        var idx = sx.subquery_index()
        if idx < 0 or idx >= len(prebound):
            raise Error("SQL bind error: dangling scalar-subquery index")
        return prebound[idx].copy()
    if sx.tag == SX_AGG:
        raise Error("SQL bind error: aggregate function not allowed in this position")
    if sx.tag == SX_WINDOW:
        # A window function is lowered only as a top-level SELECT item
        # (`_bind_window_projection` builds the PARTITION BY node); one nested
        # in a scalar expression (`RANK() OVER (...) + 1`) is refused.
        raise Error(
            "SQL not supported: a window function `f(...) OVER (...)` must be a"
            + " top-level SELECT item (it cannot be nested inside an expression)"
        )
    if sx.tag == SX_STAR:
        raise Error("SQL bind error: '*' not allowed in this position")
    raise Error("SQL bind error: unsupported expression")


