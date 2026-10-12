# =============================================================================
# komira_sql/sql_bind_agg_expr.mojo
#   Aggregate calls, aggregate de-duplication and the scalars above an
#   aggregate.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.agg_expr import (
    AGG_ANY_VALUE, AGG_BOOL_AND, AGG_BOOL_OR, AGG_CORR, AGG_COUNT, AGG_COUNT_DISTINCT,
    AGG_COUNT_IF, AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_FIRST, AGG_KAHAN_AVG,
    AGG_KAHAN_SUM, AGG_KURTOSIS, AGG_KURTOSIS_POP, AGG_LAST, AGG_MEDIAN, AGG_PRODUCT,
    AGG_REGR_AVGX, AGG_REGR_AVGY, AGG_REGR_COUNT, AGG_REGR_INTERCEPT, AGG_REGR_R2,
    AGG_REGR_SLOPE, AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY, AGG_SEM, AGG_SKEWNESS,
    AGG_STDDEV_POP, AGG_STDDEV_SAMP, AGG_VAR_POP, AGG_VAR_SAMP, AggExpr,
)
from komira_plan_expr.expr import (
    EXPR_ALIAS, EXPR_BINARY_OP, EXPR_CAST, EXPR_COL_REF, EXPR_LITERAL, EXPR_UNARY_OP,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import AggExprArray
from komira_plan_ir.plan_helpers import _expr_fingerprint
from komira_sql.sql_ast import (
    SXAGG_COUNT, SXLIKE_ILIKE, SXOP_DIV, SXOP_IDIV, SXOP_MOD, SXUN_NEGATE, SX_AGG,
    SX_BINARY, SX_BOOL, SX_CALL, SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT, SX_LIKE, SX_NULL,
    SX_STAR, SX_STRING, SX_TIMESTAMP, SX_UNARY, SqlExpr, TSLIT_AWARE,
    sql_call_is_aggregate,
)
from komira_sql.sql_bind_call import _bind_scalar_call
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_fn_args import _fn_arity_msg
from komira_sql.sql_bind_names import _group_has
from komira_sql.sql_bind_ops import (
    _map_unop, _bind_sql_operator, _bind_like, _post_agg_typing_schema,
    _BARE_NULL_REFUSAL, _sx_is_big_int, _big_int_literal_refusal, _is_null_comparison,
    _null_comparison, _map_aggfunc,
)
from komira_sql.sql_bind_scope import (
    CteScope, _date_to_days, BindScope, _resolve_col,
)
from komira_sql.sql_bind_timestamp import _timestamp_literal_micros
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    FNK_MATH_FN, FNK_MATH_FN2, FNK_UNARY_NUM, sql_scalar_fn_spec,
)


def _bind_agg_from_sx(sx: SqlExpr, schema: Schema, scope: BindScope, out_name: String, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> AggExpr:
    """Bind a SX_AGG node -> an `AggExpr`, forcing its output column name to
    `out_name` (so the post-aggregate Project can reference it deterministically).
    The agg ARGUMENT binds against `schema` (the pre-aggregate input schema)."""
    var func = _map_aggfunc(sx.op)
    var out_alias: Optional[String] = String(out_name)
    # COUNT(*) — no argument.
    if sx.op == SXAGG_COUNT and not sx.agg_has_arg():
        if sx.agg_distinct:
            raise Error("SQL bind error: COUNT(DISTINCT *) is not valid")
        var none_arg: Optional[Expr] = None
        return AggExpr(AGG_COUNT, none_arg^, out_alias^)
    if not sx.agg_has_arg():
        raise Error("SQL bind error: aggregate requires an argument")
    var arg = _bind_scalar(sx._agg.value().arg[], schema, scope, catalog, cte_scope, prebound)
    # DISTINCT is supported on COUNT only.
    if sx.agg_distinct:
        if sx.op != SXAGG_COUNT:
            raise Error("SQL not supported: DISTINCT is only supported on COUNT")
        return AggExpr(AGG_COUNT_DISTINCT, Optional(arg^), out_alias^)
    return AggExpr(func, Optional(arg^), out_alias^)


comptime _NO_BIVARIATE_AGG: UInt8 = 255
"""Sentinel for `_bivariate_agg_tag`, not a plan tag: 255 is outside the
`AGG_*` tag space."""


@always_inline
def _bivariate_agg_tag(name: String) -> UInt8:
    """The `AGG_*` tag for a BIVARIATE `regr_*` / `covar_*` name, or
    `_NO_BIVARIATE_AGG`.

    This ladder and `sql_ast.sql_call_is_aggregate` must name the same eleven.
    A name admitted there and missing here falls through to the trailing
    `unsupported statistical aggregate` raise; a name here and missing there
    never reaches this function (the parser routes it to the scalar-call
    branch)."""
    if name == "covar_pop":
        return AGG_COVAR_POP
    if name == "covar_samp":
        return AGG_COVAR_SAMP
    if name == "regr_avgx":
        return AGG_REGR_AVGX
    if name == "regr_avgy":
        return AGG_REGR_AVGY
    if name == "regr_count":
        return AGG_REGR_COUNT
    if name == "regr_intercept":
        return AGG_REGR_INTERCEPT
    if name == "regr_r2":
        return AGG_REGR_R2
    if name == "regr_slope":
        return AGG_REGR_SLOPE
    if name == "regr_sxx":
        return AGG_REGR_SXX
    if name == "regr_sxy":
        return AGG_REGR_SXY
    if name == "regr_syy":
        return AGG_REGR_SYY
    return _NO_BIVARIATE_AGG


def _bind_agg_from_sx_call(sx: SqlExpr, schema: Schema, scope: BindScope, out_name: String, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> AggExpr:
    """Bind a statistical-aggregate SX_CALL node (median, stddev, var_pop,
    corr, regr_*, ...) -> an `AggExpr`, forcing its output name to `out_name`
    (so the post-aggregate Project can reference it deterministically). The
    argument(s) bind against `schema` (the pre-aggregate input schema). Only
    reached for a name where `sql_call_is_aggregate` is True."""
    var out_alias: Optional[String] = String(out_name)
    ref args = sx._call.value().args
    # Every arity refusal below names `sx.text`, the spelling the query wrote,
    # not the canonical name an arm folds it onto (`stddev` / `stddev_samp`
    # share AGG_STDDEV_SAMP, `variance` / `var_samp` share AGG_VAR_SAMP).
    # `sx.text` is also what `_duckdb_expr_text` names this call's output
    # column with.
    if sx.text == "median":
        if len(args) != 1:
            raise Error("SQL bind error: median() expects exactly 1 argument")
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_MEDIAN, Optional(arg^), out_alias^)
    if sx.text == "stddev" or sx.text == "stddev_samp":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_STDDEV_SAMP, Optional(arg^), out_alias^)
    # `var_samp` / `variance`: two spellings of one statistic in DuckDB and
    # PostgreSQL, so one tag.
    if sx.text == "var_samp" or sx.text == "variance":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_VAR_SAMP, Optional(arg^), out_alias^)
    # The population-finalize family. These are not aliases of the arms
    # above: `var_pop` divides `m2` by `n`, `var_samp` by `n - 1` (DuckDB
    # v1.5.3 over one group: `var_samp(x)` = 7.0, `var_pop(x)` =
    # 4.666666666666667). They are univariate (one argument, no swap).
    if sx.text == "var_pop":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_VAR_POP, Optional(arg^), out_alias^)
    if sx.text == "stddev_pop":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_STDDEV_POP, Optional(arg^), out_alias^)
    if sx.text == "sem":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_SEM, Optional(arg^), out_alias^)
    # The monoid folds and `count_star`. `count_star()` is not `count(x)`,
    # and `count_if(b)` is neither: in DuckDB v1.5.3, over a group of one row
    # whose every column is NULL, `count_star()` = 1, `count(b)` = 0 and
    # `count_if(b)` = NULL.
    if sx.text == "count_star":
        if len(args) != 0:
            raise Error(
                "SQL bind error: count_star() expects exactly 0 arguments"
            )
        # The node `COUNT(*)` produces: `AGG_COUNT` with an empty child slot.
        var none_child: Optional[Expr] = None
        return AggExpr(AGG_COUNT, none_child^, out_alias^)
    if sx.text == "count_if" or sx.text == "countif":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_COUNT_IF, Optional(arg^), out_alias^)
    if sx.text == "bool_and":
        if len(args) != 1:
            raise Error(
                "SQL bind error: bool_and() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_BOOL_AND, Optional(arg^), out_alias^)
    if sx.text == "bool_or":
        if len(args) != 1:
            raise Error(
                "SQL bind error: bool_or() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_BOOL_OR, Optional(arg^), out_alias^)
    if sx.text == "product":
        if len(args) != 1:
            raise Error(
                "SQL bind error: product() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_PRODUCT, Optional(arg^), out_alias^)
    # The arrival-order picks: four names, three tags. DuckDB v1.5.3 over a
    # group whose x is {NULL, 4.0}:
    #
    #     first(x) = arbitrary(x) = NULL        last(x) = any_value(x) = 4.0
    #
    # and over a group whose x is {NULL, 7.0, NULL, 9.0, NULL}:
    #
    #     first(x) = arbitrary(x) = last(x) = NULL        any_value(x) = 7.0
    #
    # So `first` / `arbitrary` pick the value at the first row and `last` the
    # value at the last row, NULL included, while `any_value` picks the first
    # non-NULL value. `arbitrary` is `first` because DuckDB's catalog records
    # its `alias_of` as `first`.
    if sx.text == "first" or sx.text == "arbitrary":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_FIRST, Optional(arg^), out_alias^)
    if sx.text == "last":
        if len(args) != 1:
            raise Error(
                "SQL bind error: last() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_LAST, Optional(arg^), out_alias^)
    if sx.text == "any_value":
        if len(args) != 1:
            raise Error(
                "SQL bind error: any_value() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_ANY_VALUE, Optional(arg^), out_alias^)
    # The compensated sums and the higher central moments: seven names, five
    # tags. They are not aliases of the plain ones. DuckDB v1.5.3:
    #
    #   over x = {0.1 repeated ten times}
    #       sum(x)  = 0.9999999999999999      fsum(x) = 1.0
    #       avg(x)  = 0.09999999999999999     favg(x) = 0.1
    #   over x = {1e16, 1, 1, 1, -1e16}
    #       sum(x)  = 0.0                     fsum(x) = 4.0
    #       avg(x)  = 0.0                     favg(x) = 0.8
    #   over x = {1, 2, 3, 4, 10}
    #       kurtosis(x) = 3.151999999999994   kurtosis_pop(x) = -0.212000000...
    #
    # `fsum` and `sumkahan` share `AGG_KAHAN_SUM` because DuckDB's catalog
    # records both as aliases of `kahan_sum`; `favg` is its own tag.
    if sx.text == "fsum" or sx.text == "kahan_sum" or sx.text == "sumkahan":
        if len(args) != 1:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_KAHAN_SUM, Optional(arg^), out_alias^)
    if sx.text == "favg":
        if len(args) != 1:
            raise Error("SQL bind error: favg() expects exactly 1 argument")
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_KAHAN_AVG, Optional(arg^), out_alias^)
    if sx.text == "skewness":
        if len(args) != 1:
            raise Error("SQL bind error: skewness() expects exactly 1 argument")
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_SKEWNESS, Optional(arg^), out_alias^)
    if sx.text == "kurtosis":
        if len(args) != 1:
            raise Error("SQL bind error: kurtosis() expects exactly 1 argument")
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_KURTOSIS, Optional(arg^), out_alias^)
    if sx.text == "kurtosis_pop":
        if len(args) != 1:
            raise Error(
                "SQL bind error: kurtosis_pop() expects exactly 1 argument"
            )
        var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        return AggExpr(AGG_KURTOSIS_POP, Optional(arg^), out_alias^)
    if sx.text == "corr":
        if len(args) != 2:
            raise Error("SQL bind error: corr() expects exactly 2 arguments")
        var a0 = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        var a1 = _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound)
        var a0o: Optional[Expr] = a0^
        var a1o: Optional[Expr] = a1^
        return AggExpr(AGG_CORR, a0o^, a1o^, out_alias^)
    # The eleven bivariate names, and the argument swap they turn on. SQL
    # spells this family `regr_slope(y, x)`: dependent first, independent
    # second (SQL:2016; DuckDB v1.5.3 follows it). The aggregate's `x` is its
    # child slot 0, so slot 0 is bound from `args[1]` and slot 1 from
    # `args[0]`. Pearson `corr` is symmetric and cannot show a mistake here;
    # `regr_slope(y, x)` is `C / Sx` and the unswapped reading `C / Sy`.
    # `covar_pop` / `covar_samp` are symmetric too and are bound the same way,
    # so the family has one convention.
    var biv_tag = _bivariate_agg_tag(sx.text)
    if biv_tag != _NO_BIVARIATE_AGG:
        if len(args) != 2:
            raise Error(
                "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
                + " — the SQL spelling is " + sx.text + "(y, x), the DEPENDENT"
                + " variable first"
            )
        # args[1] = the INDEPENDENT variable -> child slot 0 (the state's `x`).
        var bx = _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound)
        var by = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        var bxo: Optional[Expr] = bx^
        var byo: Optional[Expr] = by^
        return AggExpr(biv_tag, bxo^, byo^, out_alias^)
    raise Error("SQL bind error: unsupported statistical aggregate '" + sx.text + "'")


# =============================================================================
# One accumulator per distinct aggregate
# =============================================================================
#
# A hoisted aggregate (in HAVING, or inside an expression over aggregates) is
# looked up against the aggregates already bound into `agg_exprs` before a new
# one is appended under a fresh hidden name `_agg_x<n>`, so
#
#     SELECT ... sum(l_quantity) ... GROUP BY ... HAVING sum(l_quantity) > 300
#
# binds one SUM, as DuckDB's plan carries `Aggregates: sum(#1)`, not two
# identical accumulators.
#
# The alias is excluded from identity: two `AggExpr`s that differ only in
# `alias_name` (`sum_qty` vs `_agg_x0`) compute the same thing. Every other
# field is identity: `func` (which also separates `count` from
# `count_distinct`, a distinct `AGG_*` tag) and the four child slots,
# occupied or not (`count(*)` is `AGG_COUNT` with no children, `count(v)` has
# slot 0; collapsing them would answer COUNT(*) for COUNT(v)).
#
# Scope: hoisted aggregates only. A bare aggregate SELECT item needs one
# output column per item (`SELECT sum(v) AS a, sum(v) AS b` emits two named
# columns).


def _agg_dedup_expr_is_keyable(e: Expr) -> Bool:
    """Can `_expr_fingerprint(e)` + `String(e)` TOGETHER distinguish `e` from
    every expression that computes something different?  ALLOWLIST — anything
    not named here answers `False` and is never deduplicated.

    ⛔ AN ALLOWLIST, NOT A DENYLIST, AND THE DIRECTION IS THE SAFETY ARGUMENT.
    A false `True` here is a SILENT WRONG ANSWER (two different aggregates share
    one accumulator); a false `False` costs one redundant fold. So a tag this
    ladder has never heard of — including every tag added after this was
    written — declines, exactly as `_expr_fingerprint`'s own `else` arm is built
    to degrade to "never deduped".

    ⚠ THE LITERAL ARM IS THE ONE WITH TEETH, AND `NULL` IS WHY IT EXISTS.
    `ScalarValue.null(dtype)` records its logical type in `null_dtype`, NOT in
    `dtype` (BUG-SCALARVALUE-TYPED-NULL-FOOTGUN, scalar_value.mojo) — and
    NEITHER `_expr_fingerprint` (which returns a value-LESS `"L:?"`) NOR
    `ScalarValue.write_to` (which writes a bare `ScalarValue(null)`) emits it.
    Two typed NULLs of DIFFERENT types are therefore byte-identical to both
    keys. Same hole for `binary` (rendered as a BYTE COUNT, never the bytes) and
    for decimal / interval / time / duration (a value-less `"L:?"` from the
    fingerprint). Only the six kinds the fingerprint gives a VALUE to are
    accepted; the rest decline.

    ⚠ `is_int()` DROPS THE DTYPE (`"L:i5"` for an int32 5 and an int64 5),
    which is why the caller conjoins `String(e)` — `ScalarValue.write_to`'s int
    arm writes `ScalarValue(<dtype>, 5)`. Neither key is sufficient alone; the
    pair is."""
    if e.tag == EXPR_COL_REF:
        return True
    if e.tag == EXPR_LITERAL:
        var sv = e.literal_value()
        return (
            sv.is_int() or sv.is_float() or sv.is_bool() or sv.is_string()
            or sv.is_date32() or sv.is_timestamp()
        )
    if e.tag == EXPR_BINARY_OP:
        return (
            _agg_dedup_expr_is_keyable(e.binary_left_ref())
            and _agg_dedup_expr_is_keyable(e.binary_right_ref())
        )
    if e.tag == EXPR_UNARY_OP:
        return _agg_dedup_expr_is_keyable(e.unary_child_ref())
    if e.tag == EXPR_CAST:
        return _agg_dedup_expr_is_keyable(e.cast_child_ref())
    if e.tag == EXPR_ALIAS:
        # `_expr_fingerprint` looks THROUGH an alias (an alias renames, it does
        # not compute), so `sum(x)` and `sum(x AS y)` are one accumulator. The
        # aggregate's own output name is `AggExpr.alias_name`, untouched here.
        return _agg_dedup_expr_is_keyable(e.alias_child_ref())
    return False


def _agg_dedup_append_slot(mut key: String, slot: Optional[Expr]) -> Bool:
    """Append one child slot's contribution to `key`; `False` means REFUSE.

    ⚠ LENGTH-PREFIXED AT BOTH LEVELS, because a fingerprint may itself contain
    any byte this could otherwise use as a separator (`B:5(C:a,C:b)` holds the
    comma; a string literal can hold anything at all). A plain join is not
    injective over strings that can contain the separator, and the entire value
    of this key is that equal keys mean equal aggregates."""
    if not slot:
        key += "|-"
        return True
    if not _agg_dedup_expr_is_keyable(slot.value()):
        return False
    # BOTH keys. The fingerprint is the structural one and is blind to a
    # literal's DTYPE; the Writable render carries the dtype and is blind to
    # nothing this allowlist admits. A false match needs BOTH to collide.
    var fp = _expr_fingerprint(slot.value())
    var rendered = String(slot.value())
    var part = String(fp.byte_length()) + ":" + fp + ":" + rendered
    key += "|" + String(part.byte_length()) + ":" + part
    return True


def _agg_expr_dedup_key(agg: AggExpr) -> Optional[String]:
    """Structural identity of an aggregate MODULO its output alias, or `None`
    when it cannot be keyed injectively (see `_agg_dedup_expr_is_keyable`).

    Two `AggExpr`s with EQUAL keys compute the identical value for every group
    and differ only in what their output column is CALLED, so one may reference
    the other's output. A `None` key NEVER matches anything, itself included."""
    var key = String("A:") + String(Int(agg.func))
    if not _agg_dedup_append_slot(key, agg.child):
        return None
    if not _agg_dedup_append_slot(key, agg.child1):
        return None
    if not _agg_dedup_append_slot(key, agg.child2):
        return None
    if not _agg_dedup_append_slot(key, agg.child3):
        return None
    return Optional(key^)


def _find_equivalent_agg_out_name(
    agg_exprs: AggExprArray, candidate: AggExpr
) -> Optional[String]:
    """The OUTPUT NAME of an already-bound aggregate equivalent to `candidate`,
    or `None`.

    An entry with no `alias_name` is skipped even when it matches (the caller
    replaces the aggregate with a col_ref to this name). First match wins, in
    bind order: SELECT-list aggregates first, then the hidden ones, so a
    HAVING aggregate binds onto the query's own named column when there is
    one."""
    var want = _agg_expr_dedup_key(candidate)
    if not want:
        return None
    for i in range(len(agg_exprs)):
        ref existing = agg_exprs[i]
        if not existing.alias_name:
            continue
        var got = _agg_expr_dedup_key(existing)
        if not got:
            continue
        if got.value() == want.value():
            return Optional(String(existing.alias_name.value()))
    return None


def _post_agg_unlowered(what: String, example: String, served: String) -> String:
    """The named refusal for an operator the post-aggregate projection does
    not lower: `%`, unary minus and ILIKE over an aggregate result
    (`sum(v) % 3`, `-sum(v)`, `HAVING s ILIKE 'B%'`). DuckDB v1.5.3 answers
    each; this binder refuses them by name rather than build a plan whose
    post-aggregate projection the engine does not evaluate."""
    return (
        String("SQL not supported: ") + what + " over a GROUP BY / aggregate"
        + " result (" + example + "). The engine does not lower " + what
        + " above an aggregate yet; " + served + "."
    )


def _extract_and_bind_post_agg(
    sx: SqlExpr,
    input_schema: Schema,
    scope: BindScope,
    group_names: List[String],
    agg_out_names: List[String],
    mut agg_exprs: AggExprArray,
    mut agg_counter: Int,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """Bind a scalar expression that may contain aggregates. Each SX_AGG
    subnode is extracted: bound into `agg_exprs` under a synthesized hidden
    name (`_agg_x<n>`) and replaced by a col_ref to that name. A non-agg
    column leaf must be a GROUP BY column (they survive into the aggregate
    output) or, for a HAVING predicate, an already-produced aggregate output
    alias (`agg_out_names`, e.g. `HAVING total > 100`). The returned `Expr` is
    the post-aggregate scalar over {group keys, agg outputs}. SELECT items pass
    an empty `agg_out_names` (a SELECT item cannot reference a sibling
    alias)."""
    if sx.tag == SX_AGG:
        var nm = String("_agg_x") + String(agg_counter)
        var bound = _bind_agg_from_sx(sx, input_schema, scope, nm, catalog, cte_scope, prebound)
        # Bind first (so a malformed aggregate raises its own message), then
        # look for an accumulator computing exactly this; if one exists,
        # reference its output and drop the duplicate. `agg_counter` is
        # consumed only when a hidden aggregate is appended.
        var already = _find_equivalent_agg_out_name(agg_exprs, bound)
        if already:
            _ = bound^
            return Expr.col_ref(already.value())
        agg_counter += 1
        agg_exprs.append(bound^)
        return Expr.col_ref(nm)
    if sx.tag == SX_COLUMN:
        # A qualified post-agg column (`t.g`) resolves to its output name first;
        # then it must be a GROUP BY key or an already-produced aggregate output.
        var cn = _resolve_col(sx, input_schema, scope) if sx.qualifier != "" else String(sx.text)
        if _group_has(group_names, cn) or _group_has(agg_out_names, cn):
            return Expr.col_ref(cn)
        raise Error(
            "SQL bind error: column '" + cn
            + "' must be a GROUP BY column or an aggregate output"
        )
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
    if sx.tag == SX_NULL:
        raise Error(_BARE_NULL_REFUSAL)
    if sx.tag == SX_BINARY:
        if _is_null_comparison(sx):
            if sx._binary.value().left[].tag != SX_NULL:
                return _null_comparison(sx.op, _extract_and_bind_post_agg(
                    sx._binary.value().left[], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
                ))
            if sx._binary.value().right[].tag != SX_NULL:
                return _null_comparison(sx.op, _extract_and_bind_post_agg(
                    sx._binary.value().right[], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
                ))
            raise Error(_BARE_NULL_REFUSAL)
        if sx.op == SXOP_MOD:
            raise Error(_post_agg_unlowered(
                String("`%` (modulo)"), String("`sum(v) % 3`, `HAVING g % 2 = 1`"),
                String(
                    "the same refusal as `mod(sum(v), 3)`. For INTEGER operands"
                    " `x - x // n * n` is the same value and is served"
                ),
            ))
        var lhs = _extract_and_bind_post_agg(
            sx._binary.value().left[], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
        )
        var rhs = _extract_and_bind_post_agg(
            sx._binary.value().right[], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
        )
        if sx.op == SXOP_DIV or sx.op == SXOP_IDIV:
            # Typed after both operands are bound: binding them appended their
            # aggregates to `agg_exprs`, so `sum(a) / count(*)` finds two
            # int64 outputs (cast) and `sum(f) / sum(g)` two float64s (no cast).
            return _bind_sql_operator(
                sx.op, lhs^, rhs^, _post_agg_typing_schema(input_schema, agg_exprs)
            )
        return _bind_sql_operator(sx.op, lhs^, rhs^, input_schema)
    if sx.tag == SX_BOOL:
        return Expr.literal(ScalarValue.from_bool(sx.int_val != Int64(0)))
    if sx.tag == SX_UNARY:
        # Recurses through the post-agg extractor, not `_bind_scalar`: in the
        # HAVING / post-GROUP-BY position `sum(x) IS NULL` must hoist `sum(x)`
        # into a hidden aggregate output and reference it by name.
        if sx.op == SXUN_NEGATE:
            raise Error(_post_agg_unlowered(
                String("unary minus"), String("`-sum(v)`, `ORDER BY -count(*)`"),
                String("`sum(v) * -1` is served"),
            ))
        return Expr.unary(
            _map_unop(sx.op),
            _extract_and_bind_post_agg(
                sx._agg.value().arg[], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
            ),
        )
    if sx.tag == SX_LIKE:
        if sx.op == SXLIKE_ILIKE:
            raise Error(_post_agg_unlowered(
                String("ILIKE"), String("`HAVING s ILIKE 'a%'`, `min(s) ILIKE 'a%'`"),
                String("LIKE is served in this position"),
            ))
        var child = _extract_and_bind_post_agg(
            sx._agg.value().arg[], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
        )
        return _bind_like(sx, child^)
    if sx.tag == SX_CALL:
        # A statistical aggregate on the SX_CALL grammar (median, stddev,
        # corr, ...): extract it into a hidden aggregate output and replace it
        # with a col_ref, as the SX_AGG arm does.
        if sql_call_is_aggregate(sx.text):
            var nm = String("_agg_x") + String(agg_counter)
            var bound_call = _bind_agg_from_sx_call(sx, input_schema, scope, nm, catalog, cte_scope, prebound)
            # One accumulator per distinct aggregate, as in the SX_AGG arm. The
            # key compares the child slots in order, so `regr_slope(y, x)` and
            # `regr_slope(x, y)` are two accumulators.
            var already_call = _find_equivalent_agg_out_name(agg_exprs, bound_call)
            if already_call:
                _ = bound_call^
                return Expr.col_ref(already_call.value())
            agg_counter += 1
            agg_exprs.append(bound_call^)
            return Expr.col_ref(nm)
        # A math call may wrap aggregates (`pow(corr(v1, v2), 2)`,
        # `exp(avg(ln(x)))`, `abs(sum(x) - sum(y))`): recurse into each
        # argument so a nested aggregate is hoisted into a hidden output, then
        # build the node over the extracted arguments. Keyed on the lowering
        # kind (`FNK_MATH_FN`, `FNK_UNARY_NUM`, `FNK_MATH_FN2`), not on names,
        # so every row of those families gets it. The two unary families are
        # different nodes: `EXPR_MATH_FN` is FLOAT64 and `EXPR_UNARY_OP` keeps
        # the operand's type (`abs(sum(BIGINT))` stays BIGINT).
        var pa_spec = sql_scalar_fn_spec(sx.text)
        if pa_spec.kind == FNK_MATH_FN or pa_spec.kind == FNK_UNARY_NUM:
            ref uargs = sx._call.value().args
            if len(uargs) != 1:
                raise Error(_fn_arity_msg(sx.text, pa_spec.kind, len(uargs)))
            var uchild = _extract_and_bind_post_agg(
                uargs[0], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
            )
            if pa_spec.kind == FNK_MATH_FN:
                return Expr.math_fn(pa_spec.op, uchild^)
            return Expr.unary(pa_spec.op, uchild^)
        if pa_spec.kind == FNK_MATH_FN2:
            ref pargs = sx._call.value().args
            if len(pargs) != 2:
                raise Error(_fn_arity_msg(sx.text, pa_spec.kind, len(pargs)))
            var base = _extract_and_bind_post_agg(
                pargs[0], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
            )
            var expo = _extract_and_bind_post_agg(
                pargs[1], input_schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
            )
            return Expr.math_fn2(pa_spec.op, base^, expo^)
        # A call wrapping an aggregate, outside the families hoisted above, is
        # refused by name. The fall-through below binds against the
        # pre-aggregate schema, where the aggregate argument would raise
        # "aggregate function not allowed in this position", which is false
        # about this query (`HAVING SUM(v) > 10` binds): what is unsupported is
        # the call wrapping it. `contains_aggregate()` is the detector
        # `_bind_aggregate` uses to route the SELECT item here.
        if sx.contains_aggregate():
            raise Error(
                "SQL not supported: scalar function '" + sx.text
                + "' applied to an aggregate result. The aggregate itself is"
                + " allowed in this position — `HAVING SUM(v) > 10` binds; what"
                + " this engine cannot lower yet is a call WRAPPING one, outside"
                + " the math families whose aggregate arguments it hoists"
            )
        # date_diff folds to a constant (no aggregate); any other scalar call
        # binds via `_bind_scalar_call` (its non-agg args resolve as scalars).
        return _bind_scalar_call(sx, input_schema, scope, catalog, cte_scope, prebound)
    if sx.tag == SX_STAR:
        raise Error("SQL bind error: '*' not allowed in this position")
    raise Error("SQL bind error: unsupported expression")


