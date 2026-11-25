# =============================================================================
# sql/sql_bind_expr.mojo
#   Scalar expression binding (`_bind_scalar`) and CASE, and the unification
#   of integer CASE arms of different widths (`_unify_integer_arms`).
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.dtype_sentinel import DTYPE_NONE
from arrow.schema import Schema
from plan_expr.expr import (
    EXPR_ALIAS, EXPR_BINARY_OP, EXPR_CAST, EXPR_COL_REF, EXPR_LITERAL, Expr,
    WhenCaseData,
)
from plan_expr.expr_walk import (
    PlanColRefFields, walk_expr_field,
)
from plan_expr.scalar_desugar import promote_int_literal_to_float
from plan_expr.scalar_value import ScalarValue
from sql.sql_bind_interval import (
    INTERVAL_STANDALONE_REFUSAL, interval_date_fold, interval_operand_side,
)
from sql.sql_ast import (
    SX_AGG, SX_BINARY, SX_INTERVAL, SX_BOOL, SX_CALL, SX_CASE, SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT,
    SX_LIKE, SX_NULL, SX_STAR, SX_STRING, SX_SUBQUERY, SX_TIMESTAMP, SX_UNARY,
    SX_WINDOW, SqlExpr, TSLIT_AWARE,
)
from sql.sql_bind_call import _bind_scalar_call
from sql.sql_bind_decimal import (
    bind_decimal_comparison, swap_decimal_comparison,
)
from sql.sql_bind_ops import (
    _bind_sql_unary, _lower_null_safe, _bind_sql_operator, _bind_like, _BARE_NULL_REFUSAL, _sx_is_big_int,
    _big_int_literal_refusal, _big_int_cmp_serves, _bind_big_int_uint64,
    _int_cast_base_column, _int_cast_arith_cmp, _int_cast_cmp_side, _is_null_comparison,
    _null_comparison,
)
from sql.sql_bind_scope import (
    CteScope, _date_to_days, BindScope, _resolve_col,
)
from sql.sql_bind_timestamp import _timestamp_literal_micros
from sql.sql_catalog import SqlCatalog


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
    an all-float CASE). Otherwise integer arms of different widths are
    unified by `_unify_integer_arms`."""
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
            # The default NULL is INT64, so every written THEN must be INT64
            # too (a NULL arm is retyped below and is not a sibling here).
            for i in range(len(results)):
                if null_arm[i]:
                    continue
                if not _case_arm_is_int64(results[i], schema):
                    raise Error(
                        "SQL not supported: a CASE with no ELSE whose THEN"
                        " arms are neither INT64 nor FLOAT64 (a string, a"
                        " date, a boolean or a narrower integer). The omitted"
                        " ELSE is a NULL of the arms' type, the typed NULL"
                        " values this engine's plan can carry are INT64 and"
                        " FLOAT64 only, and every CASE arm must share one"
                        " type. Write an explicit ELSE of the same type."
                    )
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

    # Integer arms of different widths share INT64 (see `_unify_integer_arms`).
    var narrow_to_int32 = False
    if not any_float:
        var arms = List[Expr]()
        for i in range(len(results)):
            arms.append(results[i].copy())
        arms.append(default_expr.copy())
        var unified = _unify_integer_arms(arms^, schema, narrow_to_int32)
        default_expr = unified.pop()
        results = unified^

    var cases = List[WhenCaseData]()
    for i in range(len(results)):
        cases.append(WhenCaseData(conds[i].copy(), results[i].copy()))
    var built = Expr.when(cases^, default_expr^)
    if narrow_to_int32:
        return Expr.cast(built^, DType.int32)
    return built^


# `_arm_int_code` answers: an INT64 literal or a NULL (the binders pass an
# INT64 NULL), which add no type ...
comptime _ARM_WILDCARD = 0
# ... and an arm that is no integer this unification serves.
comptime _ARM_UNSERVED = 1


def _int_code(t: ArrowType) -> Int:
    """The integer type `t` as a code: its bit width, negated for an unsigned
    type, and `_ARM_UNSERVED` for a type that is no integer this unification
    serves (UINT64 is among them: it has no common signed type with INT64)."""
    if t == ArrowType.INT8:
        return 8
    if t == ArrowType.INT16:
        return 16
    if t == ArrowType.INT32:
        return 32
    if t == ArrowType.INT64:
        return 64
    if t == ArrowType.UINT8:
        return -8
    if t == ArrowType.UINT16:
        return -16
    if t == ArrowType.UINT32:
        return -32
    return _ARM_UNSERVED


def _arm_int_code(arm: Expr, schema: Schema) -> Int:
    """The code of the CASE arm `arm` (`_int_code`), `_ARM_WILDCARD` for an
    INT64 integer literal or a NULL, and `_ARM_UNSERVED` for an arm the walk
    cannot type."""
    if arm.tag == EXPR_LITERAL:
        var lv = arm.literal_value()
        if lv.is_null() or (lv.is_int() and lv.dtype == DType.int64):
            return _ARM_WILDCARD
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](arm, schema, missing).arrow_type
    if missing.byte_length() != 0:
        return _ARM_UNSERVED
    return _int_code(t)


def _common_int_code(a: Int, b: Int) -> Int:
    """DuckDB's common type of two integer codes: two signed types give the
    wider, two unsigned the wider, and a signed with an unsigned one the
    smallest signed type that holds both."""
    if a > 0 and b > 0:
        return max(a, b)
    if a < 0 and b < 0:
        return min(a, b)
    var signed = max(a, b)
    var unsigned = -min(a, b)
    if signed > unsigned:
        return signed
    return 2 * unsigned


def _int_literal_fits(v: Int64, code: Int) -> Bool:
    """True iff the integer `v` is a value of the integer type `code`."""
    if code > 0:
        if code == 64:
            return True
        var half = Int64(1) << Int64(code - 1)
        return v >= -half and v < half
    return v >= 0 and v < (Int64(1) << Int64(-code))


def _int_type_name(code: Int) -> String:
    """DuckDB's name of the integer type `code` (`_int_code`) that the CASE
    cannot produce: one narrower than INTEGER, or UINTEGER."""
    if code == 8:
        return "TINYINT"
    if code == 16:
        return "SMALLINT"
    if code == -8:
        return "UTINYINT"
    if code == -16:
        return "USMALLINT"
    return "UINTEGER"


def _narrow_int_refusal(code: Int) -> String:
    """The refusal of a CASE whose integer arms have DuckDB's common type
    `code`, a type this engine's CASE cannot produce."""
    return (
        "SQL not supported: a CASE, coalesce, ifnull, nullif, greatest or"
        " least whose integer arms have the common type "
        + _int_type_name(code)
        + " in DuckDB. This engine computes such a CASE in BIGINT and casts"
        " an answer back to INTEGER only, so the result would have another"
        " type than DuckDB's. CAST an argument to INTEGER or BIGINT to pick"
        " the result type."
    )


def _unify_integer_arms(
    var arms: List[Expr], schema: Schema, mut narrow_to_int32: Bool
) raises -> List[Expr]:
    """Unify the value arms of a CASE built from `coalesce`, `ifnull`,
    `nullif`, `greatest`, `least` or a written CASE when they are integers of
    different widths. The engine's CASE takes one dtype from its ELSE and
    wants every arm to share it, so each integer arm narrower than INT64 is
    cast to INT64 and the CASE is built in INT64. `arms` are the arms the
    result type is drawn from, a NULL arm among them is an INT64 NULL.

    Returns the arms, and sets `narrow_to_int32`. The arms come back as given
    and `narrow_to_int32` is False unless every arm is an integer literal, an INT64 NULL or an expression
    typed INT8, INT16, INT32, INT64, UINT8, UINT16 or UINT32, and at least
    one of the expression arms is narrower than INT64. A float, string, date,
    decimal or UINT64 arm leaves the call to the other rules.

    DuckDB's type for such a CASE is the common type of the arms: the common
    type of the expression arms (`_common_int_code`), widened by each integer
    literal that is not a value of it, which counts as INTEGER, or BIGINT when
    it is not an INTEGER value. `narrow_to_int32` is True when that type is
    INTEGER, and the caller then wraps the CASE in a CAST to INT32. When it is
    BIGINT the CASE already has the type. Any other common type (TINYINT,
    SMALLINT, UTINYINT, USMALLINT, UINTEGER) is refused by name
    (`_narrow_int_refusal`): the engine casts INT64 down to INT32 only
    (`project_cast._project_cast`), so the CASE could not have DuckDB's
    type."""
    var codes = List[Int]()
    var common = 0
    var n_typed = 0
    var n_wide = 0
    var served = True
    for i in range(len(arms)):
        var code = _arm_int_code(arms[i], schema)
        codes.append(code)
        if code == _ARM_UNSERVED:
            served = False
        elif code != _ARM_WILDCARD:
            common = code if n_typed == 0 else _common_int_code(common, code)
            n_typed += 1
            if code == 64:
                n_wide += 1
    if not served or n_typed == n_wide:
        narrow_to_int32 = False
        return arms^

    var result = common
    var out = List[Expr]()
    for i in range(len(arms)):
        if codes[i] == _ARM_WILDCARD:
            out.append(arms[i].copy())
            if not arms[i].literal_value().is_null():
                var v = arms[i].literal_value().int_val
                if not _int_literal_fits(v, common):
                    result = _common_int_code(
                        result, 32 if _int_literal_fits(v, 32) else 64
                    )
        elif codes[i] == 64:
            out.append(arms[i].copy())
        else:
            out.append(Expr.cast(arms[i].copy(), DType.int64))
    if result != 32 and result != 64:
        raise Error(_narrow_int_refusal(result))
    narrow_to_int32 = result == 32
    return out^


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
    if sx.tag == SX_INTERVAL:
        raise Error(INTERVAL_STANDALONE_REFUSAL)
    var null_safe = _lower_null_safe(sx)
    if null_safe:
        return _bind_scalar(null_safe.take(), schema, scope, catalog, cte_scope, prebound)
    if sx.tag == SX_BINARY:
        var ivl_side = interval_operand_side(sx)
        if ivl_side == 2:
            return interval_date_fold(sx, _bind_scalar(sx._binary.value().left[], schema, scope, catalog, cte_scope, prebound))
        if ivl_side == 1:
            return interval_date_fold(sx, _bind_scalar(sx._binary.value().right[], schema, scope, catalog, cte_scope, prebound))
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
        var swapped_opt = swap_decimal_comparison(sx, schema, scope)
        if swapped_opt:
            # A number constant on the left of a DECIMAL column: bind the
            # comparison with the column on the left.
            return _bind_scalar(swapped_opt.take(), schema, scope, catalog, cte_scope, prebound)
        var decimal_cmp = bind_decimal_comparison(sx, schema, scope)
        if decimal_cmp:
            return decimal_cmp.take()
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
        return _bind_sql_unary(
            sx.op,
            _bind_scalar(sx._agg.value().arg[], schema, scope, catalog, cte_scope, prebound),
            schema,
        )
    if sx.tag == SX_LIKE:
        var child = _bind_scalar(sx._agg.value().arg[], schema, scope, catalog, cte_scope, prebound)
        return _bind_like(sx, child^)
    if sx.tag == SX_CALL:
        return _bind_scalar_call(sx, schema, scope, catalog, cte_scope, prebound)
    if sx.tag == SX_CASE:
        return _bind_case(sx, schema, scope, catalog, cte_scope, prebound)
    if sx.tag == SX_SUBQUERY:
        # The caller bound the subquery body before any expression binding and
        # passed the results in `prebound`; this node carries only its index.
        # Looking it up here, rather than binding the body, keeps
        # `_bind_scalar` and the SELECT binder from being mutually recursive,
        # a shape the Mojo compiler hangs on.
        var idx = sx.subquery_index()
        if idx < 0 or idx >= len(prebound):
            raise Error("SQL bind error: dangling scalar-subquery index")
        return prebound[idx].copy()
    if sx.tag == SX_AGG:
        raise Error("SQL bind error: aggregate function not allowed in this position")
    if sx.tag == SX_WINDOW:
        # A window function is lowered only as a top-level SELECT item
        # (the window projection builds the PARTITION BY node); one nested
        # in a scalar expression (`RANK() OVER (...) + 1`) is refused.
        raise Error(
            "SQL not supported: a window function `f(...) OVER (...)` must be a"
            + " top-level SELECT item (it cannot be nested inside an expression)"
        )
    if sx.tag == SX_STAR:
        raise Error("SQL bind error: '*' not allowed in this position")
    raise Error("SQL bind error: unsupported expression")


