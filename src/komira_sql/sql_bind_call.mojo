# =============================================================================
# komira_sql/sql_bind_call.mojo
#   Scalar function calls: user functions, the function-table dispatch, the
#   n-ary string functions and the regexp family.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    BIN_ADD, BIN_DIV, BIN_SUB, EXPR_LITERAL, Expr, REGEXP_EXTRACT, REGEXP_EXTRACT_ALL,
    REGEXP_REPLACE, UN_NEGATE, string_fn_n_arity, string_fn_n_arity_ok,
)
from komira_plan_expr.expr_walk import (
    PlanColRefFields, walk_expr_field,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_sql.sql_ast import (
    SXOP_IDIV, SqlExpr, sql_call_is_aggregate,
)
from komira_sql.sql_bind_cast import _bind_cast
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_fn_args import (
    _bind_greatest_least, _bind_coalesce, _fn_arity_msg, _bind_date_part,
    _bind_date_trunc, _bind_left_right, _bind_substring, _bind_year_derived,
    _bind_nanosecond, _bind_float_class, _bind_string_split,
)
from komira_sql.sql_bind_fn_nested import (
    _bind_json_extract, _bind_struct_extract, _bind_map_get, _bind_date_diff,
    _bind_date_sub, _bind_even, _bind_fdiv_fmod, _bind_nullif, _bind_days_in_month,
)
from komira_sql.sql_bind_ops import _bind_sql_division
from komira_sql.sql_bind_scope import (
    CteScope, BindScope,
)
from komira_sql.sql_bind_timestamp import _bind_make_timestamp_epoch
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    CONST_FALSE, CONST_INT_ZERO, CONST_TRUE, CONST_USER, DSG_CAST, DSG_CENTURY,
    DSG_COALESCE, DSG_DATE_DIFF, DSG_DATE_PART, DSG_DATE_SUB, DSG_DATE_TRUNC,
    DSG_DAYS_IN_MONTH, DSG_DECADE, DSG_ERA, DSG_EVEN, DSG_FDIV, DSG_FMOD, DSG_GREATEST,
    DSG_IFNULL, DSG_ISFINITE, DSG_ISINF, DSG_ISNAN, DSG_JSON_EXTRACT,
    DSG_JSON_EXTRACT_TEXT, DSG_LEAST, DSG_LEFT, DSG_MAKE_TS_MS, DSG_MAKE_TS_NS,
    DSG_MAKE_TS_US, DSG_MAP_EXTRACT_VALUE, DSG_MILLENNIUM, DSG_NANOSECOND, DSG_NULLIF,
    DSG_PI, DSG_RIGHT, DSG_STRING_SPLIT, DSG_STRUCT_EXTRACT, DSG_STRUCT_EXTRACT_AT,
    DSG_SUBSTRING, DSG_TRY_CAST, FNK_BINARY_OP, FNK_CONST, FNK_EXTRACT_FIELD,
    FNK_MATH_FN, FNK_MATH_FN2, FNK_REFUSED, FNK_REGEXP, FNK_STRING_FN, FNK_STRING_FN_N,
    FNK_STRING_PRED, FNK_UNARY_NUM, sql_scalar_fn_spec,
)
from komira_sql.sql_udf_catalog import SqlUdfEntry


def _bind_udf_call(
    imm entry: SqlUdfEntry,
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """Bind `name(arg)` to an `EXPR_UDF_CALL` for a declared scalar UDF.

    The name has already been resolved to `entry` by `_bind_scalar_call`; this
    function makes the two checks that resolution could not (the argument
    count and the argument's type), at bind time, so the refusal names the
    function the query wrote.

    Both types on the node come from `entry`, which `SqlUdfCatalog.declare`
    filled from the declared UDF's own types: SQL text contributes a name and
    an argument and nothing else.
    """
    ref args = sx._call.value().args
    var n = len(args)

    # ---- Arity -------------------------------------------------------------
    # A declared scalar UDF is unary (`DeclaredScalarUdf` has one IN_TYPE), so
    # any other count is refused.
    if n != 1:
        raise Error(
            "SQL bind error: UDF '" + entry.display_name + "' takes exactly 1"
            " argument, got " + String(n) + ". A declared scalar UDF is unary"
            " (it has one argument type), so there is no form of this UDF that"
            " could accept " + String(n) + "."
        )

    var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)

    # ---- Argument type -----------------------------------------------------
    # `walk_expr_field` types any expression, not only a column reference, so
    # `affine(a * 2)` and `affine(CAST(b AS BIGINT))` are checked as strictly
    # as `affine(a)`. Its `missing` out-parameter is discarded: an unknown
    # column in the argument has already raised inside `_bind_scalar` above.
    var missing = String("")
    var arg_field = walk_expr_field[PlanColRefFields](arg, schema, missing)
    if arg_field.arrow_type != entry.in_type:
        raise Error(
            "SQL bind error: UDF '" + entry.display_name + "' is registered for"
            " an argument of type " + String(entry.in_type) + " but was applied"
            " to an expression of type " + String(arg_field.arrow_type) + "."
            " ⛔ REFUSED RATHER THAN COERCED: the per-batch UDF ABI is"
            " byte-oriented and carries no schema, so passing these bytes would"
            " REINTERPRET them as " + String(entry.in_type) + " rather than fail"
            " — a wrong answer with a success code. Add an explicit CAST if that"
            " is what you meant."
        )

    return Expr.udf_call(
        entry.display_name.copy(),
        Optional[Int](entry.handle),
        entry.in_type,
        entry.out_type,
        arg^,
    )


def _bind_scalar_call(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """Bind a scalar function-call node (SX_CALL) -> an IR `Expr`, through the
    name table in `sql_fn_table`.

    This function knows no function name: it knows the lowerings (`FNK_*`)
    and the desugar shapes (`DSG_*`), and which name gets which is one row in
    `sql_scalar_fn_spec`.

    The dispatch, in order:

      1. an aggregate name in a scalar position is a bind error;
      2. a name no row lowers (no row at all, or an `FNK_REFUSED` one) is
         offered to the UDF catalog first, because a row that becomes no
         `Expr` can shadow nothing;
      2b. failing that, a name with no row is the unknown-function error;
      3. an `FNK_REFUSED` row raises its own reason;
      4. the row's arity is enforced here, with the message its family states
         (`_fn_arity_msg`). A row whose `min_args` is `FN_ARITY_OWN` hands the
         check to its lowering (every desugar does, because their messages
         carry facts a generic check cannot state);
      5. the direct lowerings are one line each;
      6. `FNK_DESUGAR` routes to a `_bind_*` helper by `DSG_*`.

    The aggregate check comes first so a name's resolution never depends on
    where in the ladder it is tested; `sql_call_is_aggregate`'s names and the
    scalar table's rows are disjoint today.
    """
    if sql_call_is_aggregate(sx.text):
        raise Error(
            "SQL bind error: aggregate function '" + sx.text
            + "' is not allowed in this position"
        )
    var spec = sql_scalar_fn_spec(sx.text)
    if not spec.lowers_to_a_node:
        # The UDF resolution step. The condition is `not
        # spec.lowers_to_a_node`, not `kind == FNK_NONE`: a row exists either
        # because the binder lowers the name below or because the name is a
        # DuckDB function this engine refuses to lower, and only the first can
        # shadow a UDF. So:
        #  1. a lowering builtin wins (and `SqlUdfCatalog.declare` refuses a
        #     lowering builtin's name besides);
        #  2. a declared UDF beats a refusal row, which builds no `Expr`;
        #  3. a builtin call returns below without touching the UDF list.
        # It is not an `FNK_UDF` row: `sql_scalar_fn_spec` is a static table of
        # strings and cannot see the UDFs a catalog declares.
        var udf = catalog.udfs.resolve(sx.text)
        if udf:
            return _bind_udf_call(
                udf.value(), sx, schema, scope, catalog, cte_scope, prebound
            )
        if spec.kind == FNK_REFUSED:
            # A DuckDB function this engine does not approximate, and no UDF
            # supplies it: the row's reason, plus how to supply it.
            raise Error(
                spec.reason
                + " ⭐ YOU CAN SUPPLY THIS FUNCTION YOURSELF: this name lowers"
                " to nothing here, so it is DECLARABLE as a UDF — declare one"
                " named `" + sx.text + "` with `catalog.declare_udf(f)`, and"
                " this binder will resolve your function in place of this"
                " refusal."
            )
        # The unknown-function error names what is callable. The list is
        # omitted when empty rather than rendered as `[]`: "no UDFs are
        # declared" and "yours is not among these" are different findings.
        var known = catalog.udfs.declared_names()
        if len(known) == 0:
            raise Error(
                "SQL not supported: scalar function '" + sx.text + "'."
                " No UDFs are declared on this catalog either — declare one"
                " with `catalog.declare_udf(f)`"
            )
        var listed = String("")
        for i in range(len(known)):
            if i > 0:
                listed += ", "
            listed += known[i]
        raise Error(
            "SQL not supported: scalar function '" + sx.text + "'."
            " It is not a built-in and no UDF is declared under that name."
            " Declared UDFs: " + listed
        )
    ref args = sx._call.value().args
    var n = len(args)
    if spec.min_args >= 0:
        if n < spec.min_args or (spec.max_args >= 0 and n > spec.max_args):
            # Refused, not truncated: DuckDB's `trim(s, chars)` is a different
            # function with an explicit strip set, and binding it to the
            # one-argument op would ignore `chars`.
            raise Error(_fn_arity_msg(sx.text, spec.kind, n))

    if spec.kind == FNK_CONST:
        # A macro whose whole body is a constant (the PG-compat booleans and
        # the user-name strings). `args` is not bound: DuckDB v1.5.3 answers
        # `select pg_table_is_visible(zzz) from t` with true although `zzz`
        # names no column (a macro body that never references its parameters
        # never binds them), while `select current_user from t where zzz = 1`
        # is a Binder Error. The arity is still enforced above, from the row,
        # as DuckDB enforces it (`pg_table_is_visible(1, 2)` is a Binder
        # Error there).
        _ = args
        if spec.op == CONST_TRUE:
            return Expr.literal(ScalarValue.from_bool(True))
        if spec.op == CONST_FALSE:
            # `pg_is_other_temp_schema` alone: its published body is
            # `CAST('f' AS BOOLEAN)`; every other member of the family is
            # `CAST('t' AS BOOLEAN)` (DuckDB v1.5.3).
            return Expr.literal(ScalarValue.from_bool(False))
        if spec.op == CONST_USER:
            # DuckDB v1.5.3: `current_user`, `session_user`, `current_role` and
            # `user` all return VARCHAR 'duckdb'.
            return Expr.literal(ScalarValue.from_string(String("duckdb")))
        if spec.op == CONST_INT_ZERO:
            # `pg_my_temp_schema` alone: DuckDB v1.5.3's body is the bare
            # literal `0` and `typeof(pg_my_temp_schema())` is `INTEGER`, so
            # the literal is an int32.
            return Expr.literal(ScalarValue.from_int32(Int32(0)))
        raise Error(
            "SQL internal: the scalar-function table row for '" + sx.text
            + "' names FNK_CONST selector " + String(Int(spec.op))
            + ", which `_bind_scalar_call` has no constant for"
        )

    if spec.kind == FNK_STRING_FN:
        return Expr.string_fn(
            spec.op,
            _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound),
        )
    if spec.kind == FNK_MATH_FN:
        return Expr.math_fn(
            spec.op,
            _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound),
        )
    if spec.kind == FNK_UNARY_NUM:
        # `abs` / `sign` / `trunc` / `round` onto EXPR_UNARY_OP, which keeps
        # the operand's type.
        return Expr.unary(
            spec.op,
            _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound),
        )
    if spec.kind == FNK_BINARY_OP:
        # `add` / `subtract` / `multiply` / `divide` / `mod` onto
        # EXPR_BINARY_OP. See `FNK_BINARY_OP` for why `divide` is `//` and not
        # `/`.
        var b_left = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        if n == 1:
            # The unary overloads: only `add(x)` (x) and `subtract(x)` (-x)
            # have one. The row's `min_args` already refuses a 1-argument
            # `multiply` / `divide` / `mod`, so a third op here is a
            # table / lowering disagreement, refused by name.
            if spec.op == BIN_ADD:
                return b_left^
            if spec.op == BIN_SUB:
                return Expr.unary(UN_NEGATE, b_left^)
            raise Error(
                "SQL internal: " + sx.text + "() has no 1-argument form"
                " (binary op " + String(Int(spec.op)) + ")"
            )
        var b_right = _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound)
        if spec.op == BIN_DIV:
            # `divide(a, b)` IS `a // b` (DuckDB v1.5.3), so it takes the
            # operator's own binding -- including the float zero-divisor NULL.
            return _bind_sql_division(SXOP_IDIV, b_left^, b_right^, schema)
        return Expr.binary(spec.op, b_left^, b_right^)
    if spec.kind == FNK_EXTRACT_FIELD:
        return Expr.extract(
            spec.op,
            _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound),
        )
    if spec.kind == FNK_MATH_FN2:
        var m2_left = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        var m2_right = _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound)
        return Expr.math_fn2(spec.op, m2_left^, m2_right^)
    if spec.kind == FNK_STRING_FN_N:
        # The arity is the lowering's, not the row's (`FN_ARITY_OWN` on all
        # seven rows): `_bind_string_fn_n` checks `string_fn_n_arity_ok`, the
        # expression IR's own table.
        return _bind_string_fn_n(
            spec.op, sx, schema, scope, catalog, cte_scope, prebound
        )
    if spec.kind == FNK_REGEXP:
        # The arity is the lowering's, not the row's: the four names do not
        # share an argument shape (`regexp_replace` has a replacement at
        # position 2, `regexp_extract` a group index there).
        return _bind_regexp(
            spec.op, sx, schema, scope, catalog, cte_scope, prebound
        )
    if spec.kind == FNK_STRING_PRED:
        var p_child = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
        var p_pat = _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound)
        if p_pat.tag != EXPR_LITERAL or not p_pat.literal_value().is_string():
            # ⚠ REFUSED BY NAME RATHER THAN SILENTLY NARROWED. A column-valued
            # pattern is a DIFFERENT operation (per-row pattern) that this tag
            # cannot express at all, and answering it with the literal it is
            # not would be a wrong answer, not a limitation.
            raise Error(
                "SQL not supported: " + sx.text + "() pattern must be a string"
                " literal"
            )
        return Expr.string_op(
            spec.op, p_child^, p_pat.literal_value().string_val.copy()
        )

    # ---------------------------------------------------------------------
    # FNK_DESUGAR: each of these builds, from existing nodes, the expression
    # the function means.
    # ---------------------------------------------------------------------
    if spec.op == DSG_DATE_DIFF:
        # Not part of the temporal family: its output is an INT64 day count,
        # not an EXPR_EXTRACT. Two DATE literals fold to an INT64 at bind
        # time; anything else lowers to a day subtraction over DATE32 columns.
        return _bind_date_diff(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_COALESCE or spec.op == DSG_IFNULL:
        return _bind_coalesce(sx, spec.op, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_GREATEST or spec.op == DSG_LEAST:
        return _bind_greatest_least(sx, spec.op, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_DATE_PART:
        return _bind_date_part(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_DATE_TRUNC:
        return _bind_date_trunc(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_LEFT or spec.op == DSG_RIGHT:
        return _bind_left_right(sx, spec.op, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_SUBSTRING:
        return _bind_substring(sx, schema, scope, catalog, cte_scope, prebound)
    if (
        spec.op == DSG_CENTURY
        or spec.op == DSG_DECADE
        or spec.op == DSG_MILLENNIUM
        or spec.op == DSG_ERA
    ):
        return _bind_year_derived(sx, spec.op, schema, scope, catalog, cte_scope, prebound)
    if (
        spec.op == DSG_ISFINITE
        or spec.op == DSG_ISINF
        or spec.op == DSG_ISNAN
    ):
        return _bind_float_class(sx, spec.op, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_STRING_SPLIT:
        return _bind_string_split(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_JSON_EXTRACT or spec.op == DSG_JSON_EXTRACT_TEXT:
        # ⚠ ONE ARM, TWO SELECTORS, AND THE BOOL IS THE WHOLE DIFFERENCE.
        # `as_text` is `EXPR_JSON_EXTRACT`'s `preserve_extension_metadata`
        # INVERTED — the tag spells the flag from the `->` side and SQL names
        # it from the `->>` side — so the negation lives at the ONE call site
        # that builds the node (`_bind_json_extract`'s return) rather than
        # being restated per row.
        return _bind_json_extract(
            sx, spec.op == DSG_JSON_EXTRACT_TEXT,
            schema, scope, catalog, cte_scope, prebound,
        )
    if spec.op == DSG_STRUCT_EXTRACT or spec.op == DSG_STRUCT_EXTRACT_AT:
        # ⚠ ONE ARM, TWO SELECTORS — the by-NAME and by-INDEX variants are
        # two TAGS (`EXPR_STRUCT_FIELD` / `EXPR_STRUCT_FIELD_IDX`), and the
        # 1-based -> 0-based subtraction the index spelling needs lives at the
        # ONE call site that builds the node. See `_bind_struct_extract`.
        return _bind_struct_extract(
            sx, spec.op == DSG_STRUCT_EXTRACT_AT,
            schema, scope, catalog, cte_scope, prebound,
        )
    if spec.op == DSG_MAP_EXTRACT_VALUE:
        return _bind_map_get(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_DATE_SUB:
        # ⚠ ITS OWN FOLD AND ITS OWN UNIT CHECK, NOT `DSG_DATE_DIFF`'s. The two
        # functions agree only for the 'day' unit this engine serves; sharing
        # either would make a future widening of one silently widen the other.
        # See `_date_sub_days`. (The 'day' COLUMN lowering IS shared, and
        # `_date_delta_days_over_columns` states why that one is safe.)
        return _bind_date_sub(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_FDIV or spec.op == DSG_FMOD:
        return _bind_fdiv_fmod(sx, spec.op, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_NULLIF:
        return _bind_nullif(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_DAYS_IN_MONTH:
        return _bind_days_in_month(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_CAST or spec.op == DSG_TRY_CAST:
        return _bind_cast(sx, spec.op == DSG_TRY_CAST, schema, scope, catalog, cte_scope, prebound)
    if (
        spec.op == DSG_MAKE_TS_US
        or spec.op == DSG_MAKE_TS_MS
        or spec.op == DSG_MAKE_TS_NS
    ):
        # ⚠ ONE ARM, THREE SELECTORS — they share an argument shape and a
        # refusal, and differ only in the UNIT the count is in and the unit the
        # answer carries. See `_bind_make_timestamp_epoch`.
        return _bind_make_timestamp_epoch(
            sx, spec.op, schema, scope, catalog, cte_scope, prebound,
        )
    if spec.op == DSG_EVEN:
        return _bind_even(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_NANOSECOND:
        return _bind_nanosecond(sx, schema, scope, catalog, cte_scope, prebound)
    if spec.op == DSG_PI:
        # ⭐ THE ONLY ZERO-ARGUMENT LOWERING, AND IT READS NO COLUMN. `pi()`
        # folds to a FLOAT64 literal at BIND time, so nothing downstream —
        # optimizer, wire, evaluator — learns a new node shape.
        #
        # ⚠ THE ARITY CHECK IS HERE AND NOT ON THE ROW, because the FAMILY
        # message (`_fn_arity_msg`) has no text for "takes no arguments" and
        # inheriting one of the four it does have would tell a caller about
        # `(base, exponent)`. Refusing BY COUNT also stops `pi(x)` from
        # silently discarding `x`, which is what a lowering that ignored its
        # arguments would do.
        if len(args) != 0:
            raise Error(
                "SQL bind error: pi() takes no arguments — got "
                + String(len(args))
            )
        # MEASURED v1.5.3: `pi()` = 3.141592653589793, DOUBLE. Bit-identical
        # to CPython's `math.pi`.
        return Expr.literal(ScalarValue.from_float(3.141592653589793))

    # A ROW THAT NAMES A LOWERING THIS BINDER HAS NO ARM FOR IS AN INTERNAL
    # ERROR AND SAYS SO. The alternative — falling through to the
    # unknown-function message — would report a table/binder mismatch as a
    # missing feature, which is the one wrong answer this whole file is
    # arranged to prevent.
    raise Error(
        "SQL internal: the scalar-function table row for '" + sx.text
        + "' names lowering kind " + String(Int(spec.kind)) + " / desugar "
        + String(Int(spec.op)) + ", which `_bind_scalar_call` has no arm for"
    )


# =============================================================================
# The multi-argument string family and the regexp family.
# =============================================================================


def _bind_string_fn_n(
    op: UInt8,
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """Bind a `STRFNN_*` call -> an `EXPR_STRING_FN_N` node.

    ONE binding rule serves all seven members because every operand of every
    one of them is an ORDINARY SCALAR EXPRESSION — including the counts.
    `lpad(s, width_col, ' ')` is as legal here as `lpad(s, 5, ' ')`, and it is
    legal in DuckDB too (`lpad`'s second parameter is an INTEGER expression,
    not a constant). That is the whole reason this family needed a variadic tag
    rather than the plan-time-literal treatment `EXPR_SUBSTRING` gets.

    ⛔ THE ARITY IS CHECKED AGAINST `string_fn_n_arity`, THE ENGINE'S OWN
    TABLE, and never against a number written here. The binder, the SDK
    surface, the wire decoder and the evaluator all read that one table; a
    count spelled at this site would be a fourth opinion, and the day it drifts
    is the day a plan this binder accepts is one the evaluator refuses.

    ⚠ NO IMPLICIT CAST IS INSERTED. DuckDB's `concat` takes ANY and stringifies
    (`concat(1,'a')` = `'1a'`); here a non-STRING argument reaches the kernel
    and is refused BY NAME. That is a stated narrowing — a refusal, never a
    wrong value — and it is recorded on `STRFNN_CONCAT` in `expr.mojo`.
    """
    ref args = sx._call.value().args
    var want = string_fn_n_arity(op)
    if not string_fn_n_arity_ok(op, len(args)):
        # The message says the REQUIREMENT, not just the count, because the
        # two shapes read very differently to a caller: "expects exactly 3" is
        # a typo, "expects at least 2" is a misunderstanding of the function.
        var need: String
        if want > 0:
            need = String("exactly ") + String(want) + " arguments"
        elif want < 0:
            need = String("at least ") + String(-want) + " arguments"
        else:
            # Unreachable from SQL: `sql_scalar_fn_spec` carries only
            # `FNK_STRING_FN_N` ops that `string_fn_n_arity` declares. An op
            # with no arity row has no legal call, and answering "0 arguments"
            # would be a legal-looking one.
            need = String(
                "no declared arity — this op has no row in"
                " string_fn_n_arity and cannot be called"
            )
        raise Error(
            "SQL bind error: " + sx.text + "() expects " + need + " — got "
            + String(len(args))
        )
    var bound = List[Expr](capacity=len(args))
    for i in range(len(args)):
        bound.append(
            _bind_scalar(args[i], schema, scope, catalog, cte_scope, prebound)
        )
    return Expr.string_fn_n(op, bound^)


def _regexp_literal_string(
    var e: Expr, fn_name: String, what: String
) raises -> String:
    """Read a plan-time STRING LITERAL out of a bound argument, or raise.

    ⚠ REFUSED, NEVER NARROWED. `RegexpData.pattern` / `.replacement` /
    `.flags` are `String` fields, not `Expr` fields, so a COLUMN-VALUED pattern
    is an operation this tag cannot express AT ALL — the pattern is compiled
    once per batch, not once per row. Answering such a call with anything would
    be answering a different question; the same rule and the same reasoning
    already govern `FNK_STRING_PRED`'s pattern.
    """
    if e.tag != EXPR_LITERAL or not e.literal_value().is_string():
        raise Error(
            "SQL not supported: " + fn_name + "() " + what
            + " must be a string literal"
        )
    return e.literal_value().string_val.copy()


def _bind_regexp(
    op: UInt8,
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """Bind a `regexp_*` call -> an `EXPR_REGEXP` node.

    The argument shapes, each as DuckDB v1.5.3 has them:

      regexp_matches   (string, regex [, options])           -> BOOLEAN
      regexp_full_match(string, regex [, options])           -> BOOLEAN
      regexp_replace   (string, regex, replacement [, opts]) -> VARCHAR
      regexp_extract   (string, regex [, group] [, opts])    -> VARCHAR
      regexp_extract_all    (string, regex [, group] [, opts]) -> VARCHAR[]
      regexp_split_to_array (string, regex [, options])        -> VARCHAR[]
        (aliases `str_split_regex` / `string_split_regex` — ⛔ NOT
         `str_split` / `string_split`, which take a LITERAL separator and
         have no op on this engine at all)

    ⚠ THE SUBJECT IS AN ORDINARY BOUND EXPRESSION; the PATTERN, the
    REPLACEMENT and the OPTIONS are plan-time STRING LITERALS and the GROUP is
    a plan-time INTEGER LITERAL. That asymmetry is a property of the TAG
    (`RegexpData` stores four `String`s and an `Int`, and the NFA is compiled
    once per batch), not a shortcut taken here — see `_regexp_literal_string`.

    ⛔ THE OPTIONS ALPHABET IS NARROWER THAN DuckDB'S AND THE DIFFERENCE
    REFUSES RATHER THAN GUESSES. `parse_flags_string` accepts `i m s x g` and
    raises `regexp: unknown flag character` on anything else; DuckDB also
    accepts `c` (case-sensitive, its default) `l` (literal) `n` `p`. A caller
    who writes `'c'` gets a named error, not a silently different match.

    ⚠ `g` IS NOT A PATTERN FLAG AND IS NOT REJECTED EITHER: the evaluator's
    `split_g_flag` strips it before compiling and turns it into
    replace-ALL. That is exactly DuckDB's rule — `regexp_replace('aXbXc','X',
    '-')` = `a-bXc`, and with `'g'` = `a-b-c`.
    """
    ref args = sx._call.value().args
    var n = len(args)

    # ARITY, per op. The four messages are separate because the four SHAPES
    # are separate; a shared one would name `replacement` to a caller of
    # `regexp_extract`.
    if op == REGEXP_REPLACE:
        if n != 3 and n != 4:
            raise Error(
                "SQL bind error: regexp_replace() expects (string, regex,"
                " replacement[, options]) — got " + String(n) + " arguments"
            )
    elif op == REGEXP_EXTRACT or op == REGEXP_EXTRACT_ALL:
        if n < 2 or n > 4:
            raise Error(
                "SQL bind error: " + sx.text + "() expects (string, regex[,"
                " group][, options]) — got " + String(n) + " arguments"
            )
    else:
        if n != 2 and n != 3:
            raise Error(
                "SQL bind error: " + sx.text + "() expects (string, regex[,"
                " options]) — got " + String(n) + " arguments"
            )

    var child = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
    var pattern = _regexp_literal_string(
        _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound),
        sx.text, String("pattern"),
    )

    if op == REGEXP_REPLACE:
        var repl = _regexp_literal_string(
            _bind_scalar(args[2], schema, scope, catalog, cte_scope, prebound),
            sx.text, String("replacement"),
        )
        var rflags = String("")
        if n == 4:
            rflags = _regexp_literal_string(
                _bind_scalar(args[3], schema, scope, catalog, cte_scope, prebound),
                sx.text, String("options"),
            )
        return Expr.regexp(REGEXP_REPLACE, child^, pattern, repl, rflags, 0)

    if op == REGEXP_EXTRACT or op == REGEXP_EXTRACT_ALL:
        # ⚠ THE THIRD ARGUMENT IS OVERLOADED IN DuckDB AND ONLY ONE OVERLOAD
        # IS SERVED HERE. `regexp_extract(s, p, <int>)` selects a capture
        # GROUP; `regexp_extract(s, p, <list of names>)` returns a STRUCT.
        # This engine has no struct-returning regexp op, so a non-integer
        # third argument is refused BY NAME rather than being read as a group
        # index it is not.
        var group = 0
        var eflags = String("")
        if n >= 3:
            var g_e = _bind_scalar(args[2], schema, scope, catalog, cte_scope, prebound)
            if g_e.tag != EXPR_LITERAL or not g_e.literal_value().is_int():
                raise Error(
                    "SQL not supported: regexp_extract() group must be an"
                    " integer literal (the name-list overload, which returns a"
                    " STRUCT, is not served)"
                )
            group = Int(g_e.literal_value().int_val)
            if group < 0:
                raise Error(
                    "SQL bind error: regexp_extract() group must be"
                    " non-negative — got " + String(group)
                )
        if n == 4:
            eflags = _regexp_literal_string(
                _bind_scalar(args[3], schema, scope, catalog, cte_scope, prebound),
                sx.text, String("options"),
            )
        return Expr.regexp(op, child^, pattern, String(""), eflags, group)

    var mflags = String("")
    if n == 3:
        mflags = _regexp_literal_string(
            _bind_scalar(args[2], schema, scope, catalog, cte_scope, prebound),
            sx.text, String("options"),
        )
    # THE 2..3 SHAPE: `regexp_matches`, `regexp_full_match` and
    # `regexp_split_to_array` (+ its `str_split_regex` / `string_split_regex`
    # aliases) all take (string, regex[, options]) and differ only by OP.
    #
    # `regexp_matches` is unanchored (REGEXP_LIKE) and `regexp_full_match` is
    # anchored: two ops, not one op and a flag (`regexp_matches('abcde','bcd')`
    # is true, `regexp_full_match('abcde','bcd')` false).
    return Expr.regexp(op, child^, pattern, String(""), mflags, 0)
