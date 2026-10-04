# =============================================================================
# col_expr_bind — re-deciding the unbound `ColExpr` choices once a SCHEMA is
# in hand
# =============================================================================
#
# `ColExpr` is UNBOUND: `col("v")` does not know what `v` is. Three of its
# spellings nevertheless have a DuckDB answer that depends on the operand
# TYPES, and the builder had to guess (`col_expr_division`, `_unify_case_args`):
#
#   spelling                  DuckDB v1.5.3 (MEASURED)            the guess
#   f32 / 3, 120 / f32        FLOAT                               DOUBLE / refused
#   x / y  (both DOUBLE)      DOUBLE                              + identity CAST
#   d // 4 (DECIMAL)          DOUBLE 0.375 (`//` on a non-int IS `/`) unnamed raise
#   x // 0 (DOUBLE)           NULL (0.0 // 0 too)                 +-inf / NaN
#   f32 // 2                  FLOAT 3.75                          unnamed raise
#   coalesce(x, 0) (DOUBLE)   DOUBLE                              CASE mismatch
#   coalesce(f32, 0)          FLOAT                               CASE mismatch
#
# `PlanCarrier`'s expression verbs call `bind_unbound_expr` with their input
# schema, and it rebuilds exactly those nodes as DuckDB types them:
#
#   * a `BIN_DIV` an unbound builder made (`division_intent != 0`, see
#     `col_expr_division`) is re-decided from the operands the user WROTE
#     (the builder's own CAST is peeled back off first);
#   * a CASE whose branches mix a float column with a numeric LITERAL gets
#     the literal in the float's type (DuckDB's CASE unification — the rule
#     the SQL binder already applies from the schema, `_bind_coalesce`).
#
# ⛔ A NODE THIS CANNOT TYPE IS LEFT EXACTLY AS BUILT. An operand whose type
# the walk cannot see (a missing column, a window output declared `null`, a
# string) keeps the builder's tree — the answer it gave before this module.
#
# ⚠ THE FLOAT (`float32`) ANSWER IS PRODUCED ONLY AS AN OUTPUT COLUMN'S VALUE.
# The engine has no float32 ARITHMETIC kernels (`_eval_binary_col_scalar:
# unsupported type 11`) and its predicate ladder refuses
# a float32 column against a literal. So the FLOAT quotient is
# computed in DOUBLE over DuckDB's FLOAT operands and narrowed ONCE, and only
# where the quotient IS the column (`narrow_float` at the top of a `select` /
# `with_columns` expression, through an alias). For FLOAT, INTEGER and
# LITERAL operands that is bit-exact: both operands are then exactly the
# binary32 values DuckDB divides, and a double-precision quotient of two
# binary32 values rounded to binary32 is the binary32 quotient (53 >= 2*24 +
# 2 — double rounding is innocuous for `/`). ⚠ NOT for a DECIMAL operand:
# `_as_binary32_in_double` rounds it through DOUBLE (`f32(f64(d))`), and
# DuckDB 1.5.3's DECIMAL -> FLOAT cast rounds large magnitudes differently
# (MEASURED: 504 of 20,000 random decimal(12,2) values
# differ, e.g. -725934112.91 -> DuckDB -725934080 vs -725934144 here; 0 of
# 20,003 BIGINTs and 0 with |d| < 1000). Nested in
# further arithmetic (`(f / 3) * 2`), or inside a predicate, the quotient
# stays DOUBLE — the builder's answer before this module, and a residual:
# DuckDB computes that one in FLOAT.
#
# ⚠ `//` IS NOT POLARS' `//` HERE EITHER: over integers it truncates (the
# engine's `BIN_DIV`), over anything else it is `/` with a zero divisor NULL —
# DuckDB's, measured. The python skins floor, like their libraries.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr, WhenCaseData, OVER_REFUSED_PREFIX,
    EXPR_LITERAL, EXPR_CAST, EXPR_BINARY_OP, EXPR_UNARY_OP, EXPR_ALIAS,
    EXPR_WHEN, EXPR_MATH_FN, EXPR_MATH_FN2, EXPR_AGG_FN,
    BIN_DIV, BIN_EQ,
)
from komira_plan_expr.expr_walk import (
    walk_expr_field, PlanColRefFields, walk_expr_column_refs, ordered_name_sink,
)
from komira_plan_expr.col_expr_division import DIVISION_TRUE_CAST_LEFT, DIVISION_INTEGER


# What an operand IS, for the division / CASE rules.
comptime _K_OTHER: Int = 0  # not visible, or not numeric: leave the node as built
comptime _K_INT: Int = 1  # an integer COLUMN (any width, signed or not)
comptime _K_F32: Int = 2  # a FLOAT (binary32) value
comptime _K_F64: Int = 3  # a DOUBLE value
comptime _K_DEC: Int = 4  # a DECIMAL value
comptime _K_LIT_INT: Int = 5  # an integer LITERAL
comptime _K_LIT_FLOAT: Int = 6  # a float64 LITERAL (DuckDB's untyped numeric literal)


def _kind(e: Expr, schema: Schema) -> Int:
    if e.tag == EXPR_LITERAL:
        var v = e.literal_value()
        if v.is_null():
            return _K_OTHER
        if v.is_int():
            return _K_LIT_INT
        if v.is_float():
            if v.dtype == DType.float32:
                return _K_F32
            return _K_LIT_FLOAT
        return _K_OTHER
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](e, schema, missing).arrow_type
    if missing.byte_length() > 0:
        return _K_OTHER
    if t.is_integer():
        return _K_INT
    if t == ArrowType.FLOAT32:
        return _K_F32
    if t == ArrowType.FLOAT64:
        return _K_F64
    if t == ArrowType.DECIMAL128:
        return _K_DEC
    return _K_OTHER


def _is_literal(k: Int) -> Bool:
    return k == _K_LIT_INT or k == _K_LIT_FLOAT


def _literal_as_f64(e: Expr) -> Float64:
    var v = e.literal_value()
    if v.is_int():
        return Float64(v.int_val)
    return v.float_val


def _as_double(e: Expr, k: Int) -> Expr:
    """`e` as a DOUBLE operand: a DOUBLE or a float64 literal as written,
    anything else under `CAST(... AS DOUBLE)` — an integer literal included,
    so an integer `/`'s plan stays byte-identical to what the builder made."""
    if k == _K_F64 or k == _K_LIT_FLOAT:
        return e.copy()
    return Expr.cast(e.copy(), DType.float64)


def _as_binary32_in_double(e: Expr, k: Int) -> Expr:
    """`e` as DuckDB's FLOAT operand, carried in a DOUBLE: the binary32
    value DuckDB divides (an integer or a literal is ROUNDED to binary32
    first, as DuckDB's implicit cast to FLOAT does). ⚠ Exact for a FLOAT, an
    integer or a literal; a DECIMAL is rounded through DOUBLE, which differs
    from DuckDB's DECIMAL -> FLOAT cast at large magnitudes (module header)."""
    if k == _K_F32:
        if e.tag == EXPR_LITERAL:
            return Expr.literal(ScalarValue.from_float(e.literal_value().float_val))
        return Expr.cast(e.copy(), DType.float64)
    if _is_literal(k):
        return Expr.literal(
            ScalarValue.from_float(Float64(Float32(_literal_as_f64(e))))
        )
    if k == _K_DEC:
        return Expr.cast(
            Expr.cast(Expr.cast(e.copy(), DType.float64), DType.float32),
            DType.float64,
        )
    # _K_INT
    return Expr.cast(Expr.cast(e.copy(), DType.float32), DType.float64)


def _is_zero_literal(e: Expr, k: Int) -> Bool:
    return _is_literal(k) and _literal_as_f64(e) == 0.0


def _needs_zero_guard(r: Expr, rk: Int) -> Bool:
    """A non-zero LITERAL divisor cannot be zero; anything else can."""
    return not _is_literal(rk) or _is_zero_literal(r, rk)


def _zero_divisor_null(r64: Expr) -> Expr:
    """DuckDB's `//` over a non-integer: a ZERO divisor is NULL, not +-inf /
    NaN (`7.5 // 0`, `0.0 // 0`, `d // 0` all NULL, measured). `r64` is the
    divisor already as a DOUBLE; the answer is `NULLIF(r64, 0)` as a CASE,
    kept INSIDE the division so the column's generated name, type and
    nullability are the division's. The column-by-column kernel honours the
    CASE's NULLs. ⚠ NOT a NULL LITERAL divisor: MEASURED,
    `BIN_DIV(col, NULL)` answered +-inf / NaN (the column-by-scalar kernel
    reads the NULL scalar's zero payload). A zero LITERAL divisor takes this
    same CASE — its condition is literal-against-literal, the shape the SQL
    binder's `//` guard already runs."""
    var guard = List[WhenCaseData]()
    guard.append(
        WhenCaseData(
            Expr.binary(
                BIN_EQ, r64.copy(), Expr.literal(ScalarValue.from_float(0.0))
            ),
            Expr.literal(ScalarValue.null(DType.float64)),
        )
    )
    return Expr.when(guard^, r64.copy())


def _bind_division(
    intent: UInt8, built: Expr, schema: Schema, narrow_float: Bool
) -> Expr:
    """Re-decide one unbound `BIN_DIV` (`built`, children already bound)."""
    ref built_left = built.binary_left_ref()
    var left = built_left.copy()
    if intent == DIVISION_TRUE_CAST_LEFT and built_left.tag == EXPR_CAST:
        left = built_left.cast_child_ref().copy()
    var right = built.binary_right_ref().copy()
    var lk = _kind(left, schema)
    var rk = _kind(right, schema)
    if lk == _K_OTHER or rk == _K_OTHER:
        return built.copy()
    var l_int = lk == _K_INT or lk == _K_LIT_INT
    var r_int = rk == _K_INT or rk == _K_LIT_INT
    var is_idiv = intent == DIVISION_INTEGER
    if is_idiv and l_int and r_int:
        # DuckDB's integer `//`: the engine's truncating BIN_DIV, `x // 0`
        # NULL. Exactly the builder's node.
        return Expr.binary(BIN_DIV, left^, right^)
    var has_f64 = lk == _K_F64 or rk == _K_F64
    var has_f32 = lk == _K_F32 or rk == _K_F32
    if has_f32 and not has_f64:
        if not narrow_float:
            # A FLOAT quotient that is not a column's value (nested in more
            # arithmetic, or in a predicate): the builder's tree, and its
            # answer before this module (DOUBLE, or the engine's refusal) —
            # never a NEW different answer. See the module header.
            return built.copy()
        # FLOAT: the binary32 quotient, computed in DOUBLE and narrowed once
        # (bit-exact; see the module header).
        var l32 = _as_binary32_in_double(left, lk)
        var r32 = _as_binary32_in_double(right, rk)
        if is_idiv and _needs_zero_guard(right, rk):
            r32 = _zero_divisor_null(r32)
        return Expr.cast(Expr.binary(BIN_DIV, l32^, r32^), DType.float32)
    # DOUBLE. The left operand is cast unless it already IS a double; the
    # right one only where the engine would otherwise refuse the pair (a
    # FLOAT against a DOUBLE) or where `//` needs it guarded.
    var l64 = _as_double(left, lk)
    var r64: Expr
    if rk == _K_F32 or (is_idiv and not (rk == _K_F64 or _is_literal(rk))):
        r64 = Expr.cast(right.copy(), DType.float64)
    else:
        r64 = right.copy()
    if is_idiv and _needs_zero_guard(right, rk):
        if rk == _K_LIT_INT:
            r64 = Expr.literal(ScalarValue.from_float(_literal_as_f64(right)))
        r64 = _zero_divisor_null(r64)
    return Expr.binary(BIN_DIV, l64^, r64^)


def _float_target(e: Expr, schema: Schema) -> Int:
    """The float kind a CASE's branches unify to: `_K_F64` if any branch is a
    DOUBLE, else `_K_F32` if any is a FLOAT, else `_K_OTHER` (nothing to do)."""
    var target = _K_OTHER
    for i in range(e.when_num_cases()):
        var k = _kind(e.when_case_result_ref(i), schema)
        if k == _K_F64:
            return _K_F64
        if k == _K_F32:
            target = _K_F32
    var dk = _kind(e.when_default_ref(), schema)
    if dk == _K_F64:
        return _K_F64
    if dk == _K_F32:
        target = _K_F32
    return target


def _unify_branch(var branch: Expr, target: Int, schema: Schema) -> Expr:
    """One CASE branch in the CASE's float domain. `_K_F64`: a numeric LITERAL
    becomes the equal float64 literal. `_K_F32` (only reached for an OUTPUT
    column): the CASE is computed in DOUBLE over DuckDB's FLOAT branch values
    and narrowed by the caller — a FLOAT branch is widened (exact), a literal
    is ROUNDED to binary32 first. Any other branch is unchanged: a
    non-literal of another type is the engine's to refuse."""
    var k = _kind(branch, schema)
    if target == _K_F32 and k == _K_F32 and branch.tag != EXPR_LITERAL:
        return Expr.cast(branch^, DType.float64)
    if branch.tag != EXPR_LITERAL:
        return branch^
    var v = branch.literal_value()
    if v.is_null() or not (v.is_int() or v.is_float()):
        return branch^
    if target == _K_F64:
        if v.is_float() and v.dtype == DType.float64:
            return branch^
        return Expr.literal(ScalarValue.from_float(_literal_as_f64(branch)))
    return Expr.literal(
        ScalarValue.from_float(Float64(Float32(_literal_as_f64(branch))))
    )


def _bind_when(e: Expr, schema: Schema, narrow_float: Bool) -> Expr:
    """Rebuild a CASE with its children bound and its branches in the CASE's
    float type (DuckDB's CASE unification: `coalesce(x, 0)` over a DOUBLE is
    DOUBLE, over a FLOAT is FLOAT).

    ⚠ THE CASE EXECUTOR HAS NO FLOAT32 OUTPUT ("CASE/WHEN only supports
    INT64, FLOAT64, and STRING output", measured), so a FLOAT CASE
    is computed in DOUBLE and narrowed once — exact, because every branch
    value is a binary32 value — and only where the CASE IS the column's
    value. Nested, it is left as built (the engine refuses it by name, as it
    did before this module)."""
    var cases = List[WhenCaseData]()
    for i in range(e.when_num_cases()):
        cases.append(
            WhenCaseData(
                bind_unbound_expr(e.when_case_condition_ref(i), schema, False),
                bind_unbound_expr(e.when_case_result_ref(i), schema, False),
            )
        )
    var default = bind_unbound_expr(e.when_default_ref(), schema, False)
    var rebuilt = Expr.when(cases^, default^)
    var target = _float_target(rebuilt, schema)
    if target == _K_OTHER or (target == _K_F32 and not narrow_float):
        return rebuilt^
    var unified = List[WhenCaseData]()
    for i in range(rebuilt.when_num_cases()):
        unified.append(
            WhenCaseData(
                rebuilt.when_case_condition_ref(i).copy(),
                _unify_branch(
                    rebuilt.when_case_result_ref(i).copy(), target, schema
                ),
            )
        )
    var out = Expr.when(
        unified^,
        _unify_branch(rebuilt.when_default_ref().copy(), target, schema),
    )
    if target == _K_F32:
        return Expr.cast(out^, DType.float32)
    return out^


def bind_unbound_expr(e: Expr, schema: Schema, narrow_float: Bool) -> Expr:
    """`e` with every unbound `ColExpr` choice re-decided over `schema` (the
    INPUT of the verb `e` belongs to). See the module header.

    `narrow_float` is True only where `e` IS an output column's value (the
    top of a `select` / `with_columns` expression); it passes through an
    alias and nowhere else. Non-raising: a node this cannot type is returned
    as built."""
    if e.tag == EXPR_ALIAS:
        return Expr.alias(
            bind_unbound_expr(e.alias_child_ref(), schema, narrow_float),
            e.alias_name(),
        )
    if e.tag == EXPR_BINARY_OP:
        var op = e.binary_op()
        var intent = e.binary_division_intent()
        var built = Expr.binary_with_division_intent(
            op,
            bind_unbound_expr(e.binary_left_ref(), schema, False),
            bind_unbound_expr(e.binary_right_ref(), schema, False),
            intent,
        )
        if op == BIN_DIV and intent != 0:
            return _bind_division(intent, built, schema, narrow_float)
        return built^
    if e.tag == EXPR_UNARY_OP:
        return Expr.unary(
            e.unary_op(), bind_unbound_expr(e.unary_child_ref(), schema, False)
        )
    if e.tag == EXPR_CAST:
        return Expr.cast_preserving_arrow(
            bind_unbound_expr(e.cast_child_ref(), schema, False), e
        )
    if e.tag == EXPR_WHEN:
        return _bind_when(e, schema, narrow_float)
    if e.tag == EXPR_MATH_FN:
        return Expr.math_fn(
            e.math_fn_op(), bind_unbound_expr(e.math_fn_child_ref(), schema, False)
        )
    if e.tag == EXPR_MATH_FN2:
        return Expr.math_fn2(
            e.math_fn2_op(),
            bind_unbound_expr(e.math_fn2_left_ref(), schema, False),
            bind_unbound_expr(e.math_fn2_right_ref(), schema, False),
        )
    if e.tag == EXPR_AGG_FN:
        return Expr.agg_fn(
            e.agg_fn_op(), bind_unbound_expr(e.agg_fn_child_ref(), schema, False)
        )
    return e.copy()


def bind_unbound_exprs(
    exprs: Slab[Expr], schema: Schema, narrow_float: Bool
) -> Slab[Expr]:
    """`bind_unbound_expr` over each expression of a projection list."""
    var out = Slab[Expr]()
    for i in range(len(exprs)):
        out.append(bind_unbound_expr(exprs[i], schema, narrow_float))
    return out^


def over_refusal(e: Expr) -> String:
    """The reason a refused `.over()` ANYWHERE in `e` carries, or "".

    A refused window carries its reason in its ARGUMENT-COLUMN slot
    (`expr._refused_over`: `OVER_REFUSED_PREFIX` + why), and
    `walk_expr_column_refs` — the ONE column-reference walk — emits every
    window's `arg_col`, so this sees a refusal under a MathFn / MathFn2 /
    When / InList / StringOp / AggFn as well as under an alias / cast /
    unary / binary operator.

    ⛔ MEASURED: a walk over alias / cast / unary / binary only lets
    `filter(sqrt(<refused over>) > 1)` and `filter(when(k > 0,
    <refused over>, 0) > 3)` answer EVERY row (6 of 6; DuckDB answers 4)
    — the engine drops a filter over an unknown column — and
    `with_columns([sqrt(<refused over>)])` would not raise at the verb."""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(e, sink)
    for i in range(len(names)):
        if names[i].startswith(OVER_REFUSED_PREFIX):
            return names[i].copy()
    return String("")
