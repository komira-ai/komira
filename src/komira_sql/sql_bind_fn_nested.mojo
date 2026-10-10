# =============================================================================
# komira_sql/sql_bind_fn_nested.mojo
#   Scalar functions over JSON, structs and maps, date arithmetic, even, the
#   float divide / mod, nullif and days_in_month.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    BIN_DIV, BIN_EQ, BIN_MUL, BIN_SUB, EXPR_ALIAS, EXPR_COL_REF, EXPR_JSON_EXTRACT,
    EXPR_LITERAL, Expr, MATH_FLOOR, WhenCaseData, parse_json_path,
)
from komira_plan_expr.scalar_desugar import (
    days_in_month_of, even_of,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_sql.sql_ast import (
    SX_DATE, SX_STRING, SqlExpr,
)
from komira_sql.sql_bind_cast import _bound_expr_is_string
from komira_sql.sql_bind_expr import (
    _bound_expr_is_float, _promote_int_literal_to_float, _bind_scalar,
)
from komira_sql.sql_bind_fn_args import _date_diff_days
from komira_sql.sql_bind_scope import (
    CteScope, _date_to_days, BindScope,
)
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import DSG_FDIV


def _bind_json_extract(
    sx: SqlExpr,
    as_text: Bool,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`json_extract(j, path)` / `json_extract_string(j, path)` and their two
    `json_extract_path*` aliases -> `EXPR_JSON_EXTRACT`.

    The operand is a plain VARCHAR column holding JSON text.

    The argument shape, as DuckDB v1.5.3 has it:

      json_extract           (json_text, path) -> JSON     (raw JSON text)
      json_extract_path      (json_text, path) -> JSON     (alias)
      json_extract_string    (json_text, path) -> VARCHAR  (leaf strings
                                                            unquoted)
      json_extract_path_text (json_text, path) -> VARCHAR  (alias)

    The path is a plan-time string literal (`EXPR_JSON_EXTRACT` holds parsed
    path segments, not an `Expr`), so a column-valued path is refused by name,
    as are DuckDB's list-of-paths and integer-index overloads.

    Two path shapes DuckDB serves are refused rather than approximated:

      * `'$'`, the whole-document extract: DuckDB minifies it
        (`json_extract('  {"a" :  1 }  ', '$')` = `{"a":1}`), and this
        engine's extract would return the bytes verbatim;
      * bracket / wildcard / filter syntax (`$.e[0]`, `$.*`, `$..a`):
        `parse_json_path` raises on each by name.

    `$."a.b"` (a quoted key segment, with `\\` and `\"` escapes) is parsed
    by `parse_json_path` as one key.

    A path with no leading `$` is one literal key: in DuckDB v1.5.3,
    `json_extract('{"a.b":5}', 'a.b')` = 5 while
    `json_extract('{"a":{"b":5}}', 'a.b')` = NULL (the bare form does not
    split on dots, where `'$.a.b'` does). It is built as a single-segment
    list through `Expr.json_extract_from_parts`, not by prefixing `$.` and
    re-parsing.
    """
    ref jargs = sx._call.value().args
    if len(jargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
            " (json_text, path) — got " + String(len(jargs))
        )
    var subject = _bind_scalar(jargs[0], schema, scope, catalog, cte_scope, prebound)
    var path_expr = _bind_scalar(jargs[1], schema, scope, catalog, cte_scope, prebound)
    if path_expr.tag != EXPR_LITERAL or not path_expr.literal_value().is_string():
        raise Error(
            "SQL not supported: " + sx.text + "() path must be a string"
            " literal — `EXPR_JSON_EXTRACT` parses the path into"
            " `JsonExtractData.path_segments` ONCE at plan time, so a"
            " column-valued path (and DuckDB's LIST-of-paths and"
            " integer-index overloads) is an operation the tag cannot"
            " express"
        )
    var path = path_expr.literal_value().string_val.copy()
    if path.byte_length() == 0:
        raise Error(
            "SQL not supported: " + sx.text + "() path must not be empty"
        )
    if path == "$":
        raise Error(
            "SQL not supported: " + sx.text + "('$') — the whole-document"
            " extract. DuckDB v1.5.3 MINIFIES it"
            " (json_extract('  {\"a\" :  1 }  ', '$') = {\"a\":1}), and the"
            " engine's JSON extract (`extract_column` in komira_json_index)"
            " returns a zero-segment path's payload bytes VERBATIM, whitespace"
            " included, so this refuses rather than answering a different"
            " string"
        )
    var segs = List[String]()
    if path.as_bytes()[0] == UInt8(0x24):  # '$'
        # `$.a.b` — the DOT-SEPARATED form. `parse_json_path` owns the
        # grammar and raises BY NAME on brackets / wildcards / an empty
        # segment, which is this function's refusal for those shapes.
        segs = parse_json_path(path)
    else:
        # The BARE form. ONE literal key, dots and all — see the docstring's
        # `{"a.b":5}` measurement.
        segs.append(path.copy())
    return Expr.json_extract_from_parts(
        subject^, segs^, ArrowType.STRING, not as_text
    )


def _bind_struct_extract(
    sx: SqlExpr,
    by_index: Bool,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`struct_extract(s, 'name')` -> `EXPR_STRUCT_FIELD` and
    `struct_extract_at(s, n)` -> `EXPR_STRUCT_FIELD_IDX`.

    In DuckDB v1.5.3:

      struct_extract({'name':'Alice','city':'NYC'}, 'city')  -> NYC
      struct_extract_at({'name':'Alice','city':'NYC'}, 1)    -> Alice
      struct_extract_at({'name':'Alice','city':'NYC'}, 2)    -> NYC

    `struct_extract_at` is 1-based and `EXPR_STRUCT_FIELD_IDX` is 0-based; the
    subtraction is done here, once.

    Both selectors are plan-time literals, refused by name otherwise: the
    expression IR stores the field name as a String and the index as an Int,
    not as an `Expr`. (`map_extract_value`'s key is an `Expr`; see
    `_bind_map_get`.)

    An out-of-range index or an absent field name is not checked here: the
    binder does not carry a STRUCT's children for an arbitrary parent
    expression, and evaluating the node raises naming the field or index.
    """
    ref sargs = sx._call.value().args
    if len(sargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
            " (struct, " + ("index" if by_index else "field_name")
            + ") — got " + String(len(sargs))
        )
    var parent = _bind_scalar(sargs[0], schema, scope, catalog, cte_scope, prebound)
    var sel = _bind_scalar(sargs[1], schema, scope, catalog, cte_scope, prebound)
    if sel.tag != EXPR_LITERAL:
        raise Error(
            "SQL not supported: " + sx.text + "() second argument must be a"
            " literal — the tag stores the selector as a plain String/Int in"
            " `StructFieldData` / `StructFieldIdxData`, not as an `Expr`, so"
            " a column-valued selector is an operation it cannot express"
        )
    if by_index:
        if not sel.literal_value().is_int():
            raise Error(
                "SQL bind error: " + sx.text + "() index must be an INTEGER"
                " literal"
            )
        var one_based = Int(sel.literal_value().int_val)
        if one_based < 1:
            raise Error(
                "SQL bind error: " + sx.text + "() index is 1-BASED on DuckDB"
                " v1.5.3 (struct_extract_at({'a':1,'b':2}, 0) is a Binder"
                " Error there) — got " + String(one_based)
            )
        return Expr.struct_field_idx(parent^, one_based - 1)
    if not sel.literal_value().is_string():
        raise Error(
            "SQL bind error: " + sx.text + "() field name must be a STRING"
            " literal"
        )
    return Expr.struct_field(parent^, sel.literal_value().string_val.copy())


def _bind_map_get(
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`map_extract_value(m, key)` -> `EXPR_MAP_GET`.

    In DuckDB v1.5.3:

      map_extract_value(map(['a','b'],['x','y']), 'a')   -> x
      map_extract_value(map(['a','b'],['x','y']), 'zz')  -> NULL
      map_extract_value(map([1,2],['x','y']), 1)         -> x

    The bare value on a hit and SQL NULL on a miss is `EXPR_MAP_GET`'s shape.
    Its siblings `map_extract` / `element_at` answer a one-element list on a
    hit and an empty list on a miss (a different value and type), which needs
    a list-cell constructor this engine does not have, so they stay refused by
    name in the function table.

    The key is an `Expr`, not a literal (a map key is a run-time value, so
    `map_extract_value(m, which_key)` over a column is a per-row lookup).
    """
    ref margs = sx._call.value().args
    if len(margs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
            " (map, key) — got " + String(len(margs))
        )
    var parent = _bind_scalar(margs[0], schema, scope, catalog, cte_scope, prebound)
    var key = _bind_scalar(margs[1], schema, scope, catalog, cte_scope, prebound)
    return Expr.map_get(parent^, key^)


def _date_sub_days(sx: SqlExpr) raises -> Int64:
    """Constant-fold `date_sub('day', DATE d0, DATE d1)` to `days(d1) -
    days(d0)`.

    A separate function from `_date_diff_days` on purpose: in DuckDB v1.5.3,
    over 2021-01-31 -> 2021-03-01, `date_diff('month', ...)` = 2 (boundaries
    crossed) and `date_sub('month', ...)` = 1 (complete periods). They agree
    only for 'day', the one unit served, so widening either fold to months
    must be done twice, deliberately.
    """
    ref args = sx._call.value().args
    if len(args) != 3:
        raise Error(
            "SQL bind error: date_sub expects 3 arguments (unit, start, end)"
        )
    ref unit = args[0]
    if unit.tag != SX_STRING or unit.text.lower() != "day":
        raise Error(
            "SQL not supported: only date_sub('day', ...) is supported."
            " ⚠ date_sub counts COMPLETE periods and date_diff counts"
            " boundaries CROSSED — in DuckDB v1.5.3 they differ for every"
            " unit above 'day' (1 vs 2 over 2021-01-31 -> 2021-03-01), so the"
            " other units are not the neighbouring function's to answer"
        )
    ref d0 = args[1]
    ref d1 = args[2]
    if d0.tag != SX_DATE or d1.tag != SX_DATE:
        # `_bind_date_sub` calls this only when both operands are `SX_DATE`;
        # the guard keeps the fold's own contract for any other caller.
        raise Error(
            "SQL not supported: date_sub('day', a, b) requires constant DATE"
            + " literal operands at this call site. ⚠ NOT A LIMIT OF date_sub:"
            + " in an ordinary projection or filter it reads DATE columns"
            + " (`_bind_date_delta`)"
        )
    return Int64(Int(_date_to_days(d1.text)) - Int(_date_to_days(d0.text)))


def _col_arrow_type_by_name(schema: Schema, name: String) -> ArrowType:
    """The Arrow type of the (case-insensitively matched) column `name`, or
    `ArrowType.NULL` if absent. Not `_col_dtype_by_name`: a DATE32 column's
    physical DType is int32, as an ordinary INTEGER column's is."""
    var t = name.lower()
    for i in range(schema.num_columns()):
        if schema.field_name(i).lower() == t:
            return schema.field_arrow_type(i)
    return ArrowType.NULL


def _bound_expr_is_date32(e: Expr, schema: Schema) -> Bool:
    """True iff the already-bound value Expr `e` produces a DATE32 over
    `schema`: a date literal, a DATE column, or an alias over either.

    A TIMESTAMP is not admitted, for two reasons: the day lowering subtracts
    day numbers, and a TIMESTAMP_US value is int64 microseconds (an answer
    ~8.64e10 times too large); and `date_diff` and `date_sub` disagree on
    `'day'` once the operands carry a time-of-day, so the lowering they share
    would answer one function's rule under the other's name."""
    if e.tag == EXPR_LITERAL:
        return e.literal_value().is_date32()
    if e.tag == EXPR_COL_REF:
        return _col_arrow_type_by_name(schema, e.col_ref_name()) == ArrowType.DATE32
    if e.tag == EXPR_ALIAS:
        return _bound_expr_is_date32(e.alias_child_ref(), schema)
    return False


def _date_delta_days_over_columns(var a: Expr, var b: Expr) -> Expr:
    """`b - a` in DAYS, as an INT64 expression, over two DATE32-typed operands.

    An Arrow DATE32 is days-since-epoch stored as an int32, so the day
    difference is the integer difference:

        CAST(b AS BIGINT) - CAST(a AS BIGINT)

    The target is BIGINT, not INT32: a DATE column may reach the evaluator
    stamped INT32 (its physical type) or DATE32, and both widen to int64,
    preserving validity, so a NULL operand gives NULL as in DuckDB. BIGINT is
    also `date_diff`'s DuckDB return type.

    Shared by `date_diff` and `date_sub`, which is safe only because both
    callers have established that the unit is `'day'` and that both operands
    are DATE32: over two DATEs the two functions agree on `'day'`, but over
    operands carrying a time-of-day they do not (`date_diff` counts boundaries
    crossed, `date_sub` complete periods), which is why
    `_bound_expr_is_date32` refuses a TIMESTAMP. Each caller raises its own
    unit message before reaching here."""
    var a_i = Expr.cast(a^, DType.int64)
    var b_i = Expr.cast(b^, DType.int64)
    return Expr.binary(BIN_SUB, b_i^, a_i^)


def _bind_date_delta(sx: SqlExpr, fname: String, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """The column arm of `date_diff('day', a, b)` / `date_sub('day', a, b)`.

    Two DATE literals fold to an INT64 at bind time in the callers; any other
    operand shape reaches here and lowers to a day subtraction over DATE32
    values (`_date_delta_days_over_columns`).

    A non-DATE operand is refused by name, not reinterpreted:
    `date_diff('day', d, <an INT32 column>)` would subtract integers and
    answer a plausible day count over whatever the column means.
    `_bound_expr_is_date32` reads the Arrow type, not the DType, under which a
    DATE32 and an ordinary int32 column are indistinguishable."""
    ref args = sx._call.value().args
    var a = _bind_scalar(args[1], schema, scope, catalog, cte_scope, prebound)
    var b = _bind_scalar(args[2], schema, scope, catalog, cte_scope, prebound)
    if not _bound_expr_is_date32(a, schema):
        raise Error(
            "SQL not supported: " + fname + "('day', a, b) requires DATE"
            " operands — argument 2 is not a DATE literal and not a DATE32"
            " column. THE MISSING PRIMITIVE IS A UNIT-AWARE, PER-FUNCTION"
            " TEMPORAL DELTA. The lowering here subtracts DAY NUMBERS, and"
            " it is refused over anything else for two separate reasons: a"
            " TIMESTAMP is int64 MICROSECONDS, so the subtraction answers a"
            " number ~8.64e10 times too large, and date_diff and date_sub"
            " DISAGREE on 'day' itself once the operands carry a"
            " time-of-day (DuckDB v1.5.3: 247 vs 246 over one pair) — so one"
            " shared lowering would answer one function's rule under the"
            " other's name. A bare integer column is refused for a third: it"
            " has no days in it, and the subtraction would answer a plausible"
            " day count anyway rather than raising"
        )
    if not _bound_expr_is_date32(b, schema):
        raise Error(
            "SQL not supported: " + fname + "('day', a, b) requires DATE"
            " operands — argument 3 is not a DATE literal and not a DATE32"
            " column. THE MISSING PRIMITIVE IS A UNIT-AWARE, PER-FUNCTION"
            " TEMPORAL DELTA. The lowering here subtracts DAY NUMBERS, and"
            " it is refused over anything else for two separate reasons: a"
            " TIMESTAMP is int64 MICROSECONDS, so the subtraction answers a"
            " number ~8.64e10 times too large, and date_diff and date_sub"
            " DISAGREE on 'day' itself once the operands carry a"
            " time-of-day (DuckDB v1.5.3: 247 vs 246 over one pair) — so one"
            " shared lowering would answer one function's rule under the"
            " other's name. A bare integer column is refused for a third: it"
            " has no days in it, and the subtraction would answer a plausible"
            " day count anyway rather than raising"
        )
    return _date_delta_days_over_columns(a^, b^)


def _bind_date_diff(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`date_diff(unit, a, b)`: the fold arm and the column arm, chosen on the
    operand shape (see `_bind_date_delta`).

    The unit check is here and not shared with `_bind_date_sub`: `date_diff`
    counts boundaries crossed and `date_sub` counts complete periods (DuckDB
    v1.5.3 over 2021-01-31 -> 2021-03-01: 2 and 1), so they agree only on
    `'day'`."""
    ref args = sx._call.value().args
    if len(args) != 3:
        raise Error("SQL bind error: date_diff expects 3 arguments (unit, start, end)")
    ref unit = args[0]
    if unit.tag != SX_STRING or unit.text.lower() != "day":
        raise Error(
            "SQL not supported: only date_diff('day', ...) is supported"
            " (got unit that is not the constant 'day'). THE MISSING PRIMITIVE"
            " IS CIVIL-CALENDAR BOUNDARY ARITHMETIC OVER A COLUMN: this"
            " function counts BOUNDARIES CROSSED, which for month/year is not"
            " expressible as the int32 day subtraction that serves 'day'"
        )
    if args[1].tag == SX_DATE and args[2].tag == SX_DATE:
        # Both operands constant -> one INT64 literal, folded at bind time.
        return Expr.literal(ScalarValue.from_int64(_date_diff_days(sx)))
    return _bind_date_delta(sx, String("date_diff"), schema, scope, catalog, cte_scope, prebound)


def _bind_date_sub(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`date_sub(unit, a, b)`: the twin of `_bind_date_diff`, with its own
    unit check and its own fold (not an alias; see `_date_sub_days`)."""
    ref args = sx._call.value().args
    if len(args) != 3:
        raise Error("SQL bind error: date_sub expects 3 arguments (unit, start, end)")
    ref unit = args[0]
    if unit.tag != SX_STRING or unit.text.lower() != "day":
        raise Error(
            "SQL not supported: only date_sub('day', ...) is supported."
            " ⚠ date_sub counts COMPLETE periods and date_diff counts"
            " boundaries CROSSED — in DuckDB v1.5.3 they differ for every"
            " unit above 'day' (1 vs 2 over 2021-01-31 -> 2021-03-01), so the"
        )
    if args[1].tag == SX_DATE and args[2].tag == SX_DATE:
        return Expr.literal(ScalarValue.from_int64(_date_sub_days(sx)))
    return _bind_date_delta(sx, String("date_sub"), schema, scope, catalog, cte_scope, prebound)


def _bind_even(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`even(x)` -> `scalar_desugar.even_of(x)`:
    `CASE WHEN x >= 0 THEN ceil(x/2)*2 ELSE floor(x/2)*2 END` over a DOUBLE
    cast of `x`.

    `even` rounds away from zero to the next even integer; it is not
    banker's rounding. DuckDB v1.5.3:

        even(0.5) = 2    even(1.0) = 2    even(2.0) = 2    even(3.0) = 4
        even(2.3) = 4    even(-2.3) = -4  even(-0.5) = -2

    A NULL x makes `x >= 0` NULL, so the ELSE arm runs and propagates it.
    """
    ref eargs = sx._call.value().args
    if len(eargs) != 1:
        raise Error(
            "SQL bind error: even() expects exactly 1 argument — got "
            + String(len(eargs))
        )
    return even_of(
        _bind_scalar(eargs[0], schema, scope, catalog, cte_scope, prebound)
    )




def _bind_fdiv_fmod(sx: SqlExpr, dsg: UInt8, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`fdiv(x, y)` -> `floor(x / y)`; `fmod(x, y)` -> `x - y * floor(x / y)`.

    The bodies are DuckDB v1.5.3's own macro definitions:
    `floor((x / y))` and `(x - (y * floor((x / y))))`.

    `fdiv` is floor division: `fdiv(7,2)` = 3.0 and `fdiv(-7,2)` = -4.0, both
    DOUBLE. `fmod` is floor modulo, not C's `fmod`: `fmod(-7,2)` = 1.0, where
    `mod(-7,3)` is -1.

    Both operands are cast to DOUBLE first: `BIN_DIV` over two INT64s is
    integer division, which would truncate toward zero before `floor` ran.
    DuckDB's overloads are DOUBLE-only. Every operator in both bodies
    propagates NULL.
    """
    ref fargs = sx._call.value().args
    if len(fargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
            " (x, y) — got " + String(len(fargs))
        )
    var fx = Expr.cast_to_arrow(
        _bind_scalar(fargs[0], schema, scope, catalog, cte_scope, prebound),
        ArrowType.FLOAT64,
    )
    var fy = Expr.cast_to_arrow(
        _bind_scalar(fargs[1], schema, scope, catalog, cte_scope, prebound),
        ArrowType.FLOAT64,
    )
    var q = Expr.math_fn(
        MATH_FLOOR, Expr.binary(BIN_DIV, fx.copy(), fy.copy())
    )
    if dsg == DSG_FDIV:
        return q^
    return Expr.binary(BIN_SUB, fx^, Expr.binary(BIN_MUL, fy^, q^))


def _bind_nullif(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`nullif(a, b)` -> `CASE WHEN a = b THEN <typed NULL> ELSE a END`, the
    body DuckDB v1.5.3 publishes for its `nullif` macro.

    The THEN is a typed NULL whose type comes from the operands: FLOAT64 when
    either is a float (the integer literal among them promoted), else INT64,
    since every arm must share one type. A string operand is refused by name:
    this IR has no string-typed NULL literal, so `nullif('a', 'a')` has no
    expressible answer.

    `nullif(NULL, 1)`: the comparison is NULL, so no branch fires and the ELSE
    returns `a`, which is NULL, as in DuckDB.
    """
    ref nargs = sx._call.value().args
    if len(nargs) != 2:
        raise Error(
            "SQL bind error: nullif() expects exactly 2 arguments — got "
            + String(len(nargs))
        )
    var na = _bind_scalar(nargs[0], schema, scope, catalog, cte_scope, prebound)
    var nb = _bind_scalar(nargs[1], schema, scope, catalog, cte_scope, prebound)
    if _bound_expr_is_string(na, schema) or _bound_expr_is_string(nb, schema):
        raise Error(
            "SQL not supported: nullif() over a STRING operand. Its THEN arm"
            " is a typed NULL and this IR has no string-typed NULL literal"
            " (`ScalarValue.null` takes a DType, and the engine's scalar"
            " broadcast, `broadcast_scalar` in komira_column_kernels, builds"
            " an all-NULL column for float64 and int64 only), so there is no"
            " value to return for the matching rows. The numeric form is"
            " served."
        )
    var is_f = _bound_expr_is_float(na, schema) or _bound_expr_is_float(nb, schema)
    if is_f:
        na = _promote_int_literal_to_float(na^)
        nb = _promote_int_literal_to_float(nb^)
    var null_dt = DType.float64 if is_f else DType.int64
    var ncases = List[WhenCaseData]()
    ncases.append(
        WhenCaseData(
            Expr.binary(BIN_EQ, na.copy(), nb^),
            Expr.literal(ScalarValue.null(null_dt)),
        )
    )
    return Expr.when(ncases^, na^)


def _bind_days_in_month(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`days_in_month(x)` -> `scalar_desugar.days_in_month_of(x)`: a CASE over
    `month(x)`, with the Gregorian leap rule as an ordered chain over
    `year(x)` (February of 1900 is 28, 2000 is 29, 2100 is 28 in DuckDB
    v1.5.3), and NULL for a NULL input. DuckDB accepts a DATE or a TIMESTAMP,
    and so does this desugar.
    """
    ref dargs = sx._call.value().args
    if len(dargs) != 1:
        raise Error(
            "SQL bind error: days_in_month() expects exactly 1 argument"
            " (a DATE or TIMESTAMP expression) — got " + String(len(dargs))
        )
    return days_in_month_of(
        _bind_scalar(dargs[0], schema, scope, catalog, cte_scope, prebound)
    )



