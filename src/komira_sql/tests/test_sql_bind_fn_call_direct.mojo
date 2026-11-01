# =============================================================================
# Tests of scalar-function binding through the function table, the n-ary string
# family and the regexp family (sql_bind_call)
# =============================================================================
#
# Each query is parsed and its select items and WHERE predicate are bound with
# `_bind_scalar` against one table's schema; the test compares the bound
# expression text, or the binder's message.
#   1. Each direct lowering kind builds its node: string / math functions,
#      the type-keeping unary numerics, the operator names (`add(x)` is x,
#      `subtract(x)` is -x, `divide` is `//`), date fields, two-argument
#      math, string predicates over a literal pattern (a column pattern is
#      refused), and the constant macros (arguments unbound, arity kept).
#   2. The family arity messages, the refused rows, and the unknown-function
#      message.
#   3. The n-ary string family and the regexp family: argument shapes,
#      options, group index bounds, literal-only patterns.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr

from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import CteScope, _build_bind_scope
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _two(
    mut cat: SqlCatalog,
    name: String,
    c0: String,
    t0: ArrowType,
    c1: String,
    t1: ArrowType,
):
    """Register parquet table `name`(c0 NOT NULL, c1 NULL)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, t0, False))
    sb.add_field(Field(c1, t1, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """t(k, v, s, g, d, ts, i32, dc, b, f32, u64, j), u(k, w, s), kk(k, a),
    mm(k, b), up(K, B), kk2(k, k_right): parquet tables with given schemas
    (no file is opened)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("j"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    _two(cat, "kk2", "k", ArrowType.INT64, "k_right", ArrowType.INT64)
    return cat^


def _got(sql: String) raises -> String:
    """Parse `sql` (one SELECT over one table), bind every select item and
    the WHERE predicate with `_bind_scalar` against the table's schema, and
    return the Project / Filter / Scan text of the result, or `ERR: ` and the
    binder's message."""
    var cat = _catalog()
    try:
        var st = parse_sql(tokenize(sql))
        var scope = _build_bind_scope(
            st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
        )
        var prebound = List[Expr]()
        var items = String("")
        for i in range(len(st.query.select_items)):
            ref item = st.query.select_items[i]
            var e = _bind_scalar(
                item.expr, scope.out_schema, scope, cat, CteScope(ParquetFacts()), prebound
            )
            if item.out_alias:
                e = Expr.alias(e^, item.out_alias.value())
            if i > 0:
                items += ", "
            items += String(e)
        var out = "Project(exprs=[" + items + "])\n"
        var pad = String("  ")
        if st.query.where_pred:
            var p = _bind_scalar(
                st.query.where_pred.value(), scope.out_schema, scope, cat,
                CteScope(ParquetFacts()), prebound,
            )
            out += pad + "Filter(predicate=" + String(p) + ")\n"
            pad += "  "
        return out + pad + "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def test_direct_lowerings() raises:
    _check(
        "SELECT upper(s) AS a, sqrt(v) AS b, abs(k) AS c, add(k) AS d, subtract(k) AS e, add(k, 1) AS f, divide(k, 2) AS g, divide(v, 2) AS h, year(d) AS i, pow(v, 2) AS j FROM t",
        "Project(exprs=[Alias(StringFn(op=0, ColRef(s)), \"a\"), Alias(MathFn(op=2, ColRef(v)), \"b\"), Alias(UnaryOp(ABS, ColRef(k)), \"c\"), Alias(ColRef(k), \"d\"), Alias(UnaryOp(NEGATE, ColRef(k)), \"e\"), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"f\"), Alias(BinaryOp(DIV, ColRef(k), Literal(ScalarValue(int64, 2))), \"g\"), Alias(When(WHEN BinaryOp(EQ, Literal(ScalarValue(int64, 2)), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(null, float64)), ELSE BinaryOp(DIV, ColRef(v), Literal(ScalarValue(int64, 2)))), \"h\"), Alias(Extract(unit=0, ColRef(d)), \"i\"), Alias(MathFn2(op=1, ColRef(v), Literal(ScalarValue(int64, 2))), \"j\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT multiply(k) FROM t",
        "ERR: SQL bind error: multiply() is the function spelling of an arithmetic operator and takes 2 arguments (add() and subtract() also take 1) — got 1"
    )
    _check(
        "SELECT contains(s, 'a') AS c1, starts_with(s, 'a') AS c2 FROM t",
        "Project(exprs=[Alias(StringOp(CONTAINS, ColRef(s), \"a\"), \"c1\"), Alias(StringOp(STARTS_WITH, ColRef(s), \"a\"), \"c2\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT contains(s, s) FROM t",
        "ERR: SQL not supported: contains() pattern must be a string literal"
    )
    _check(
        "SELECT pg_table_is_visible(zzz) AS a, pg_is_other_temp_schema(1) AS b, current_user() AS c, pg_my_temp_schema() AS d FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(bool, true)), \"a\"), Alias(Literal(ScalarValue(bool, false)), \"b\"), Alias(Literal(ScalarValue(utf8, \"duckdb\")), \"c\"), Alias(Literal(ScalarValue(int32, 0)), \"d\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT pg_table_is_visible(1, 2) FROM t",
        "ERR: SQL bind error: pg_table_is_visible() is a PostgreSQL compatibility constant — its DuckDB v1.5.3 body is a fixed value that IGNORES the arguments, but the declared argument COUNT is still enforced (DuckDB refuses a miscounted call by name, and so does this engine) — got 2. See the row in `sql_fn_table.mojo` for the count this name declares."
    )
    _check(
        "SELECT pi() AS p FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(float64, 3.141592653589793)), \"p\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT pi(k) FROM t",
        "ERR: SQL bind error: pi() takes no arguments — got 1"
    )


def test_arity_refused_and_unknown_functions() raises:
    _check(
        "SELECT upper(s, s) FROM t",
        "ERR: SQL bind error: upper() expects exactly 1 argument — got 2"
    )
    _check(
        "SELECT nosuchfn(k) FROM t",
        "ERR: SQL not supported: scalar function 'nosuchfn'. No UDFs are declared on this catalog either — declare one with `catalog.declare_udf(f)`"
    )
    _check(
        "SELECT nextafter(v, 1.0) FROM t",
        "ERR: SQL not supported: `nextafter` is a real DuckDB v1.5.3 SCALAR function — TWO overloads, `DOUBLE(DOUBLE, DOUBLE)` and `FLOAT(FLOAT, FLOAT)` — and THE MISSING PRIMITIVE IS A `MATH2_` OP. `EXPR_MATH_FN2` carries exactly TWO members on this engine's wire, `MATH2_ATAN2` (engine 0) and `MATH2_POW` (engine 1), pinned by `MATH_FN2_WIRE_MEMBERS = 2` in `plan_wire_vocabulary.mojo`, and neither computes a next-representable step. ⚠ THE COST IS WHY THIS IS A REFUSAL AND NOT A ONE-LINE ROW: a new `MATH2_` member reaches `scalar_math.eval_math_binary`, the wire vocabulary's member COUNT and its engine/wire MIN and MAX as well as its to_wire/from_wire pair, `plan.proto` + `plan_vocabulary.proto`, `expr.mojo`, `lower_untyped_expr`, `xl_scalar_numeric` and this table — a strictly wider surface than a `STRFN_` tag, and the wire codec REFUSES an op it does not carry rather than silently dropping it. ⚠ `compiler_eval_column` is NOT on that list: it reaches a `MATH2_` op ONLY through `eval_math_binary` and therefore needs no per-member edit at all. ⛔ AND NO EXISTING OP IS NEAR ENOUGH TO BORROW, WHICH IS THE PART A NEAREST-MATCH FIX WOULD GET WRONG. MEASURED v1.5.3 through `printf('%.17g')` (a bare `duckdb -csv` does not round-trip a double): `nextafter(1.0, 2.0)` = 1.0000000000000002 but `nextafter(1.0, 0.0)` = 0.99999999999999989 — the two steps have DIFFERENT magnitudes because the binade changes below 1.0; `nextafter(0.0, 1.0)` = 4.9406564584124654e-324, the smallest SUBNORMAL and not an epsilon; and `nextafter(1.0, 1.0)` = 1.0, so equal operands are the IDENTITY and not a step. Every one of those is a property of the IEEE-754 bit pattern rather than of arithmetic over the operands, so any approximation would be wrong at exactly the call sites that ask for this function. YOU CAN SUPPLY THIS FUNCTION YOURSELF: this name lowers to nothing here, so it is DECLARABLE as a UDF — declare one named `nextafter` with `catalog.declare_udf(f)`, and this binder will resolve your function in place of this refusal."
    )
    _check(
        "SELECT round(v, 2) FROM t",
        "ERR: SQL bind error: round() takes exactly 1 argument here — got 2. DuckDB also has a 2-argument round(x, digits) / trunc(x, digits); this engine lowers the 1-argument form onto a UNARY node that has no slot for a digit count, so the 2-argument form is REFUSED rather than rounded to zero digits."
    )
    _check(
        "SELECT trim(s, 'x') FROM t",
        "ERR: SQL bind error: trim() expects exactly 1 argument — got 2"
    )
    _check(
        "SELECT median(v) FROM t WHERE upper(median(v)) = 'x'",
        "ERR: SQL bind error: aggregate function 'median' is not allowed in this position"
    )


def test_string_fn_n_family() raises:
    _check(
        "SELECT concat(s, 'x', s) AS c1, lpad(s, 5, '*') AS c2, replace(s, 'a', 'b') AS c3 FROM t",
        "Project(exprs=[Alias(StringFnN(op=0, n=3, ColRef(s), Literal(ScalarValue(utf8, \"x\")), ColRef(s)), \"c1\"), Alias(StringFnN(op=3, n=3, ColRef(s), Literal(ScalarValue(int64, 5)), Literal(ScalarValue(utf8, \"*\"))), \"c2\"), Alias(StringFnN(op=2, n=3, ColRef(s), Literal(ScalarValue(utf8, \"a\")), Literal(ScalarValue(utf8, \"b\"))), \"c3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT lpad(s) FROM t",
        "ERR: SQL bind error: lpad() expects exactly 3 arguments — got 1"
    )
    _check(
        "SELECT concat() FROM t",
        "ERR: SQL bind error: concat() expects at least 1 arguments — got 0"
    )


def test_regexp_family() raises:
    _check(
        "SELECT regexp_matches(s, 'a.c') AS r1, regexp_full_match(s, 'abc') AS r2, regexp_replace(s, 'b', 'X') AS r3, regexp_extract(s, '(a)(b)', 1) AS r4, regexp_extract_all(s, 'a') AS r5, regexp_split_to_array(s, ',') AS r6 FROM t",
        "Project(exprs=[Alias(Regexp(op=0, ColRef(s), pattern=\"a.c\"), \"r1\"), Alias(Regexp(op=9, ColRef(s), pattern=\"abc\"), \"r2\"), Alias(Regexp(op=2, ColRef(s), pattern=\"b\", replacement=\"X\"), \"r3\"), Alias(Regexp(op=3, ColRef(s), pattern=\"(a)(b)\", group=1), \"r4\"), Alias(Regexp(op=5, ColRef(s), pattern=\"a\", group=0), \"r5\"), Alias(Regexp(op=4, ColRef(s), pattern=\",\"), \"r6\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s, 'a', 'i') AS r1, regexp_replace(s, 'b', 'X', 'g') AS r2, regexp_extract(s, 'a', 0, 'i') AS r3 FROM t",
        "Project(exprs=[Alias(Regexp(op=0, ColRef(s), pattern=\"a\", flags=\"i\"), \"r1\"), Alias(Regexp(op=2, ColRef(s), pattern=\"b\", flags=\"g\", replacement=\"X\"), \"r2\"), Alias(Regexp(op=3, ColRef(s), pattern=\"a\", flags=\"i\", group=0), \"r3\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s) FROM t",
        "ERR: SQL bind error: regexp_matches() expects (string, regex[, options]) — got 1 arguments"
    )
    _check(
        "SELECT regexp_replace(s) FROM t",
        "ERR: SQL bind error: regexp_replace() expects (string, regex, replacement[, options]) — got 1 arguments"
    )
    _check(
        "SELECT regexp_extract(s, '(a)(b)', -1) FROM t",
        "ERR: SQL bind error: regexp_extract() group must be non-negative — got -1"
    )
    _check(
        "SELECT regexp_extract(s, '(a)', 10) FROM t",
        "Project(exprs=[Regexp(op=3, ColRef(s), pattern=\"(a)\", group=10)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s, s) FROM t",
        "ERR: SQL not supported: regexp_matches() pattern must be a string literal"
    )
    _check(
        "SELECT regexp_matches(s, 'a', 'zz') FROM t",
        "Project(exprs=[Regexp(op=0, ColRef(s), pattern=\"a\", flags=\"zz\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT regexp_matches(s, 'a', s) FROM t",
        "ERR: SQL not supported: regexp_matches() options must be a string literal"
    )
    _check(
        "SELECT regexp_replace(s, 'a', s) FROM t",
        "ERR: SQL not supported: regexp_replace() replacement must be a string literal"
    )
    _check(
        "SELECT regexp_extract(s, 'a', s) FROM t",
        "ERR: SQL not supported: regexp_extract() group must be an integer literal (the name-list overload, which returns a STRUCT, is not served)"
    )
    _check(
        "SELECT regexp_extract(s, 'a', 1, 2, 3) FROM t",
        "ERR: SQL bind error: regexp_extract() expects (string, regex[, group][, options]) — got 5 arguments"
    )
    _check(
        "SELECT regexp_extract_all(s, 'a', 1) FROM t",
        "Project(exprs=[Regexp(op=5, ColRef(s), pattern=\"a\", group=1)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_family_arity_messages() raises:
    _check(
        "SELECT contains(s) FROM t",
        "ERR: SQL bind error: contains() expects exactly 2 arguments (string, pattern) — got 1"
    )
    _check(
        "SELECT year(d, d) FROM t",
        "ERR: SQL bind error: year() expects exactly 1 argument (a DATE or TIMESTAMP expression) — got 2"
    )
    _check(
        "SELECT pow(v) FROM t",
        "ERR: SQL bind error: pow() expects exactly 2 arguments (base, exponent)"
    )
    _check(
        "SELECT add(k, 1, 2) FROM t",
        "ERR: SQL bind error: add() is the function spelling of an arithmetic operator and takes 2 arguments (add() and subtract() also take 1) — got 3"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
