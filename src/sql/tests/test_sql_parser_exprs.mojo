# =============================================================================
# sql_parser: the expression grammar
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. Precedence: OR < AND < NOT < comparison < `||` / `^@` < `+ -` <
#      `* / // %` < `^` (left-associative) < unary minus < `::`; prefix `@`
#      takes a whole sum. (catches: `^` made right-associative; `//` read
#      as `/`; `||` bound tighter than `+`)
#   2. A prefix NOT negates the whole predicate, leaves `NOT EXISTS` to the
#      subquery arm, and re-marks ONE desugared IN list `not in` but not a
#      user-written OR. (catches: the mark descending into a user OR)
#   3. [NOT] IN lists desugar to OR-of-EQ / AND-of-NE carrying the `in` /
#      `not in` mark; [NOT] IN (SELECT ...) and [NOT] EXISTS park the body
#      in the subquery table with the left column's name and qualifier.
#      (catches: NOT IN desugared with OR; the qualifier dropped)
#   4. [NOT] BETWEEN, [NOT] LIKE / ILIKE, [NOT] SIMILAR TO, the `~~` family,
#      `~` / `!~`, and every postfix NULL test (also after a comparison and
#      after a pattern test). (catches: ILIKE built with the LIKE flavour;
#      the `!~~*` code read as LIKE)
#   5. Literals: integers (with the past-BIGINT digits), negative literals
#      and their folding, floats, strings, TRUE / FALSE / NULL only where a
#      column cannot continue, DATE / TIMESTAMP / TIMESTAMPTZ.
#      (catches: `-9223372036854775808` refused or wrapped)
#   6. EXTRACT, POSITION(... IN ...), CAST / TRY_CAST, `::` with type names
#      and parameters, and their malformed spellings. (catches: CAST's type
#      parameters dropped from the type name)
#   7. Aggregates, DISTINCT in calls, scalar calls, ranking-function misuse,
#      qualified columns, CASE (searched and simple), scalar subqueries.
#      (catches: a simple CASE not desugared to `operand = value`)
#   8. Words DuckDB reads as an operator after an expression are refused by
#      name in the SELECT list, and are ordinary aliases elsewhere.
#      (catches: `count(*) EXPORT_STATE` answered as an alias)
#   9. A double-quoted identifier is a name and never a keyword: a column or an
#      alias spelled like a keyword, a quoted word where the bare one opens a
#      literal (`"date" '...'`, `"true"`, `"null"`), a predicate word
#      (`NOT "exists"`, `NOT "in"`, `SIMILAR "to"`), an `IS NOT "null"` pair,
#      CAST / EXTRACT / POSITION / SUBSTRING / `DOUBLE "precision"` and
#      `OVER`; a quoted word keeps its case, a qualified name takes either
#      part quoted, and `"SUM"(x)` is the aggregate `sum` (a function name
#      resolves case-insensitively).
#      (catches: a quoted word taken as the keyword it spells)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from sql.sql_token import tokenize
from sql.sql_ast import (
    SqlExpr,
    SqlStatement,
    SX_COLUMN, SX_INT, SX_FLOAT, SX_STRING, SX_BINARY, SX_AGG, SX_STAR,
    SX_DATE, SX_LIKE, SX_CALL, SX_SUBQUERY, SX_CASE, SX_UNARY, SX_BOOL,
    SX_TIMESTAMP, SX_NULL, SX_INTERVAL, SX_WINDOW,
    TSLIT_NAIVE, TSLIT_AWARE,
    SXOP_EQ, SXOP_NE, SXOP_LT, SXOP_LE, SXOP_GT, SXOP_GE, SXOP_AND, SXOP_OR,
    SXOP_ADD, SXOP_SUB, SXOP_MUL, SXOP_DIV, SXOP_IDIV, SXOP_MOD, SXOP_POW,
    SXOP_CONCAT, SXOP_STARTS_WITH,
    SXUN_NOT, SXUN_IS_NULL, SXUN_IS_NOT_NULL, SXUN_NEGATE, SXUN_ABS,
    SXUN_IS_TRUE, SXUN_IS_NOT_TRUE, SXUN_IS_FALSE, SXUN_IS_NOT_FALSE,
    SXOP_DISTINCT, SXOP_NOT_DISTINCT,
    SXLIKE_LIKE, SXLIKE_ILIKE,
    SXAGG_COUNT, SXAGG_AVG, SXAGG_SUM,
    SUBQ_SCALAR, SUBQ_EXISTS, SUBQ_NOT_EXISTS, SUBQ_IN, SUBQ_NOT_IN,
)
from sql.sql_fn_table import (
    CAST_DESUGAR_NAME,
    TRY_CAST_DESUGAR_NAME,
    POSITION_IN_DESUGAR_NAME,
)
from sql.sql_parser import parse_sql


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _e(expr: String) raises -> SqlExpr:
    """The first select item of `SELECT <expr> FROM t`."""
    var st = _parse("SELECT " + expr + " FROM t")
    return st.query.select_items[0].expr.copy()


def _w(pred: String) raises -> SqlExpr:
    """The WHERE predicate of `SELECT * FROM t WHERE <pred>`."""
    var st = _parse("SELECT * FROM t WHERE " + pred)
    return st.query.where_pred.value().copy()


def _err(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _refuses(expr: String, needle: String) raises:
    var m = _err("SELECT " + expr + " FROM t")
    assert_true(needle in m, "`" + expr + "` raised: " + m)


def _l(e: SqlExpr) -> SqlExpr:
    return e._binary.value().left[].copy()


def _r(e: SqlExpr) -> SqlExpr:
    return e._binary.value().right[].copy()


def _child(e: SqlExpr) -> SqlExpr:
    return e._agg.value().arg[].copy()


def _arg(e: SqlExpr, i: Int) -> SqlExpr:
    return e._call.value().args[i].copy()


def _is_bin(e: SqlExpr, op: UInt8) raises:
    assert_equal(Int(e.tag), Int(SX_BINARY))
    assert_equal(Int(e.op), Int(op))


def _is_un(e: SqlExpr, op: UInt8) raises:
    assert_equal(Int(e.tag), Int(SX_UNARY))
    assert_equal(Int(e.op), Int(op))


def _is_col(e: SqlExpr, name: String) raises:
    assert_equal(Int(e.tag), Int(SX_COLUMN))
    assert_equal(e.text, name)


def _is_int(e: SqlExpr, v: Int64) raises:
    assert_equal(Int(e.tag), Int(SX_INT))
    assert_equal(e.int_val, v)


def test_boolean_and_comparison_precedence() raises:
    var e = _w("a OR b AND NOT c = d")
    _is_bin(e, SXOP_OR)
    _is_col(_l(e), "a")
    _is_bin(_r(e), SXOP_AND)
    _is_un(_r(_r(e)), SXUN_NOT)
    _is_bin(_child(_r(_r(e))), SXOP_EQ)
    var nn = _w("NOT NOT a")
    _is_un(_child(nn), SXUN_NOT)
    var ops: List[String] = ["=", "<>", "!=", "<", "<=", ">", ">="]
    var codes: List[Int] = [
        Int(SXOP_EQ), Int(SXOP_NE), Int(SXOP_NE), Int(SXOP_LT), Int(SXOP_LE),
        Int(SXOP_GT), Int(SXOP_GE),
    ]
    for i in range(len(ops)):
        var c = _w("a " + ops[i] + " 1")
        assert_equal(Int(c.op), codes[i], ops[i])


def test_arithmetic_precedence_and_associativity() raises:
    var cat = _e("'a' || 1 + 2")
    _is_bin(cat, SXOP_CONCAT)
    _is_bin(_r(cat), SXOP_ADD)
    var sw = _e("a || 'b' ^@ 'a'")
    _is_bin(sw, SXOP_STARTS_WITH)
    _is_bin(_l(sw), SXOP_CONCAT)
    var mix = _e("7 + 5 // 2 - 8 / 2 % 3")
    _is_bin(mix, SXOP_SUB)
    _is_bin(_l(mix), SXOP_ADD)
    _is_bin(_r(_l(mix)), SXOP_IDIV)
    _is_bin(_r(mix), SXOP_MOD)
    _is_bin(_l(_r(mix)), SXOP_DIV)
    var pw = _e("2 * 3 ^ 2 ^ 4")
    _is_bin(pw, SXOP_MUL)
    _is_bin(_r(pw), SXOP_POW)
    _is_bin(_l(_r(pw)), SXOP_POW)
    _is_int(_r(_r(pw)), 4)
    var ab = _e("@ -3 + 1")
    _is_un(ab, SXUN_ABS)
    _is_bin(_child(ab), SXOP_ADD)
    _is_int(_l(_child(ab)), -3)


def test_unary_minus_and_literals() raises:
    _is_int(_e("-3"), -3)
    var f = _e("-2.5")
    assert_equal(Int(f.tag), Int(SX_FLOAT))
    assert_equal(f.float_val, -2.5)
    var mn = _e("-9223372036854775808")
    _is_int(mn, Int64.MIN)
    assert_equal(mn.text, "")
    var big = _e("-18446744073709551616")
    _is_un(big, SXUN_NEGATE)
    assert_equal(_child(big).text, "18446744073709551616")
    _is_int(_e("- -3"), 3)
    var ff = _e("- -2.5")
    assert_equal(ff.float_val, 2.5)
    _is_un(_e("-a"), SXUN_NEGATE)
    _is_un(_e("- -9223372036854775808"), SXUN_NEGATE)
    _is_un(_e("- (18446744073709551616)"), SXUN_NEGATE)
    var pos = _e("18446744073709551616")
    assert_equal(pos.text, "18446744073709551616")
    var fl = _e("1.5")
    assert_equal(fl.float_val, 1.5)
    var s = _e("'it''s'")
    assert_equal(Int(s.tag), Int(SX_STRING))
    assert_equal(s.text, "it's")
    var tr = _e("TRUE")
    assert_equal(Int(tr.tag), Int(SX_BOOL))
    assert_equal(tr.int_val, 1)
    assert_equal(_e("false").int_val, 0)
    assert_equal(Int(_e("NULL").tag), Int(SX_NULL))
    # `.` or `(` after the word keeps the column / call reading.
    var tq = _e("true.x")
    _is_col(tq, "x")
    assert_equal(tq.qualifier, "true")
    assert_equal(Int(_e("false(1)").tag), Int(SX_CALL))
    _is_col(_e("null.x"), "x")
    assert_equal(Int(_e("null(1)").tag), Int(SX_CALL))
    var d = _e("date '2026-09-15'")
    assert_equal(Int(d.tag), Int(SX_DATE))
    assert_equal(d.text, "2026-09-15")
    _is_col(_e("date"), "date")
    var ts = _e("timestamp '2026-09-15 10:00:00'")
    assert_equal(Int(ts.tag), Int(SX_TIMESTAMP))
    assert_equal(Int(ts.op), Int(TSLIT_NAIVE))
    var tz = _e("timestamptz '2026-09-15 10:00:00+00'")
    assert_equal(Int(tz.op), Int(TSLIT_AWARE))
    _is_col(_e("timestamp"), "timestamp")
    _refuses("~5", "the bitwise NOT operator `~`")
    _refuses(")", "unexpected token in expression")


def test_prefix_not_and_in_list_marks() raises:
    var n = _w("NOT a IN (1, 2)")
    _is_un(n, SXUN_NOT)
    var inner = _child(n)
    _is_bin(inner, SXOP_OR)
    assert_equal(inner.text, "not in")
    assert_equal(_l(inner).text, "not in")
    assert_equal(_r(inner).text, "not in")
    # A user-written OR is not descended.
    var u = _w("NOT (a IN (5) OR a = 7)")
    var o = _child(u)
    assert_equal(o.text, "")
    assert_equal(_l(o).text, "in")
    # NOT over a one-element list re-marks its one comparison.
    var single = _w("NOT a IN (1)")
    _is_bin(_child(single), SXOP_EQ)
    assert_equal(_child(single).text, "not in")
    # NOT over a column: nothing to mark.
    _is_col(_child(_w("NOT a")), "a")
    var lst = _w("a IN (1, 2, 3)")
    _is_bin(lst, SXOP_OR)
    assert_equal(lst.text, "in")
    _is_bin(_l(lst), SXOP_OR)
    _is_bin(_r(lst), SXOP_EQ)
    assert_equal(_r(lst).text, "in")
    var one = _w("a IN (1)")
    _is_bin(one, SXOP_EQ)
    var nin = _w("a NOT IN (1, 2)")
    _is_bin(nin, SXOP_AND)
    assert_equal(nin.text, "not in")
    _is_bin(_l(nin), SXOP_NE)
    assert_equal(_l(nin).text, "not in")


def test_subquery_predicates() raises:
    var st = _parse(
        "SELECT (SELECT 1) FROM t WHERE EXISTS (SELECT 1 FROM u)"
        " AND NOT EXISTS (SELECT 2 FROM v) AND a IN (SELECT b FROM w)"
        " AND z.c NOT IN (SELECT d FROM x)"
    )
    assert_equal(len(st.query.subqueries), 5)
    assert_equal(Int(st.query.subqueries[0].kind), Int(SUBQ_SCALAR))
    assert_equal(Int(st.query.subqueries[1].kind), Int(SUBQ_EXISTS))
    assert_equal(Int(st.query.subqueries[2].kind), Int(SUBQ_NOT_EXISTS))
    assert_equal(Int(st.query.subqueries[3].kind), Int(SUBQ_IN))
    assert_equal(st.query.subqueries[3].in_lhs_col, "a")
    assert_equal(st.query.subqueries[3].in_lhs_qualifier, "")
    assert_equal(Int(st.query.subqueries[4].kind), Int(SUBQ_NOT_IN))
    assert_equal(st.query.subqueries[4].in_lhs_col, "c")
    assert_equal(st.query.subqueries[4].in_lhs_qualifier, "z")
    assert_equal(st.query.select_items[0].expr.subquery_index(), 0)
    assert_equal(Int(st.query.select_items[0].expr.tag), Int(SX_SUBQUERY))
    _refuses("1 IN (SELECT b FROM u)", "`IN (subquery)` requires a column on the left")
    _refuses("a IN 1", "SQL syntax error: expected '('")
    _refuses("a IN (SELECT b FROM u", "')' to close IN subquery")
    _refuses("a IN (1, 2", "SQL syntax error: expected ')'")
    _refuses("EXISTS 1", "'(' after EXISTS")
    _refuses("EXISTS (1)", "EXISTS expects a subquery `(SELECT ...)`")
    _refuses("EXISTS (SELECT 1", "')' to close EXISTS subquery")
    _refuses("(SELECT 1", "')' to close subquery")
    _refuses("(a", "SQL syntax error: expected ')'")


def test_between_like_similar_and_regex() raises:
    var b = _w("a BETWEEN 1 AND 2")
    _is_bin(b, SXOP_AND)
    _is_bin(_l(b), SXOP_GE)
    _is_bin(_r(b), SXOP_LE)
    var nb = _w("a NOT BETWEEN 1 AND 2")
    _is_bin(nb, SXOP_OR)
    _is_bin(_l(nb), SXOP_LT)
    _is_bin(_r(nb), SXOP_GT)
    _refuses("a BETWEEN 1 2", "expected keyword 'and'")
    var lk = _w("a LIKE 'x%'")
    assert_equal(Int(lk.tag), Int(SX_LIKE))
    assert_equal(lk.text, "x%")
    assert_false(lk.like_negate)
    assert_equal(Int(lk.op), Int(SXLIKE_LIKE))
    var nlk = _w("a NOT ILIKE 'x%'")
    assert_true(nlk.like_negate)
    assert_equal(Int(nlk.op), Int(SXLIKE_ILIKE))
    assert_equal(Int(_w("a ILIKE 'x'").op), Int(SXLIKE_ILIKE))
    _refuses("a LIKE b", "LIKE expects a string pattern")
    _refuses("a ILIKE 1", "ILIKE expects a string pattern")
    var sim = _w("a SIMILAR TO 'a.*'")
    assert_equal(Int(sim.tag), Int(SX_CALL))
    assert_equal(sim.text, "regexp_full_match")
    _is_col(_arg(sim, 0), "a")
    var nsim = _w("a NOT SIMILAR TO 'a.*'")
    _is_un(nsim, SXUN_NOT)
    assert_equal(_child(nsim).text, "regexp_full_match")
    _is_col(_e("similar"), "similar")
    var syms: List[String] = ["~~", "!~~", "~~*", "!~~*"]
    var negs: List[Bool] = [False, True, False, True]
    var flav: List[Int] = [Int(SXLIKE_LIKE), Int(SXLIKE_LIKE), Int(SXLIKE_ILIKE), Int(SXLIKE_ILIKE)]
    for i in range(len(syms)):
        var s = _w("a " + syms[i] + " 'p'")
        assert_equal(Int(s.tag), Int(SX_LIKE), syms[i])
        assert_equal(s.like_negate, negs[i], syms[i])
        assert_equal(Int(s.op), flav[i], syms[i])
        _refuses("a " + syms[i] + " b", syms[i] + " expects a string pattern")
    var tl = _w("a ~ 'p'")
    assert_equal(tl.text, "regexp_full_match")
    var ntl = _w("a !~ 'p'")
    _is_un(ntl, SXUN_NOT)


def test_null_tests() raises:
    _is_un(_w("a IS NULL"), SXUN_IS_NULL)
    _is_un(_w("a IS NOT NULL"), SXUN_IS_NOT_NULL)
    _is_un(_w("a ISNULL"), SXUN_IS_NULL)
    _is_un(_w("a NOTNULL"), SXUN_IS_NOT_NULL)
    _is_un(_w("a NOT NULL"), SXUN_IS_NOT_NULL)
    var chain = _w("a ISNULL IS NULL")
    _is_un(chain, SXUN_IS_NULL)
    _is_un(_child(chain), SXUN_IS_NULL)
    var cmp = _w("a = 1 IS NULL")
    _is_un(cmp, SXUN_IS_NULL)
    _is_bin(_child(cmp), SXOP_EQ)
    var pat = _w("a LIKE 'x' IS NOT NULL")
    _is_un(pat, SXUN_IS_NOT_NULL)
    assert_equal(Int(_child(pat).tag), Int(SX_LIKE))
    _is_un(_w("a ~ 'x' ISNULL"), SXUN_IS_NULL)
    _is_un(_w("a !~ 'x' ISNULL"), SXUN_IS_NULL)
    _is_un(_w("a ~~ 'x' ISNULL"), SXUN_IS_NULL)
    _is_un(_w("a NOT LIKE 'x' ISNULL"), SXUN_IS_NULL)
    assert_equal(
        _err("SELECT a IS 5 FROM t"),
        "SQL syntax error: expected NULL, TRUE, FALSE or DISTINCT FROM after IS",
    )
    assert_equal(
        _err("SELECT a IS NOT 5 FROM t"),
        "SQL syntax error: expected NULL, TRUE, FALSE or DISTINCT FROM after IS NOT",
    )


def test_boolean_tests() raises:
    _is_un(_w("a IS TRUE"), SXUN_IS_TRUE)
    _is_un(_w("a IS NOT TRUE"), SXUN_IS_NOT_TRUE)
    _is_un(_w("a IS FALSE"), SXUN_IS_FALSE)
    _is_un(_w("a IS NOT FALSE"), SXUN_IS_NOT_FALSE)
    _is_col(_child(_w("a is true")), "a")
    # A test after a comparison tests the comparison; chains nest outward.
    var cmp = _w("a = 1 IS TRUE")
    _is_un(cmp, SXUN_IS_TRUE)
    _is_bin(_child(cmp), SXOP_EQ)
    var chain = _w("a IS TRUE IS NOT NULL")
    _is_un(chain, SXUN_IS_NOT_NULL)
    _is_un(_child(chain), SXUN_IS_TRUE)
    # NOT is looser than IS: `NOT a IS TRUE` is `NOT (a IS TRUE)`.
    var neg = _w("NOT a IS FALSE")
    _is_un(neg, SXUN_NOT)
    _is_un(_child(neg), SXUN_IS_FALSE)
    # `IS` stays an ordinary identifier where no test follows.
    _is_col(_e("is"), "is")


def test_is_distinct_from() raises:
    var d = _w("a IS DISTINCT FROM b")
    _is_bin(d, SXOP_DISTINCT)
    _is_col(_l(d), "a")
    _is_col(_r(d), "b")
    var nd = _w("a IS NOT DISTINCT FROM NULL")
    _is_bin(nd, SXOP_NOT_DISTINCT)
    assert_equal(Int(_r(nd).tag), Int(SX_NULL))
    # Arithmetic binds tighter than the test, on both sides.
    var sum = _w("a + 1 IS DISTINCT FROM b * 2")
    _is_bin(sum, SXOP_DISTINCT)
    _is_bin(_l(sum), SXOP_ADD)
    _is_bin(_r(sum), SXOP_MUL)
    # A comparison on the left is the test's left operand (`IS` is looser
    # than `=`), and AND is looser than the test.
    var eq = _w("a = 1 IS DISTINCT FROM b")
    _is_bin(eq, SXOP_DISTINCT)
    _is_bin(_l(eq), SXOP_EQ)
    var conj = _w("a IS DISTINCT FROM 1 AND b IS NOT DISTINCT FROM 2")
    _is_bin(conj, SXOP_AND)
    _is_bin(_l(conj), SXOP_DISTINCT)
    _is_bin(_r(conj), SXOP_NOT_DISTINCT)
    # The right operand is a comparison-level expression, as in DuckDB:
    # `a IS DISTINCT FROM b = 2` is `a IS DISTINCT FROM (b = 2)`, and an IN or
    # BETWEEN there is the right operand too.
    var rcmp = _w("a IS DISTINCT FROM b = 2")
    _is_bin(rcmp, SXOP_DISTINCT)
    _is_col(_l(rcmp), "a")
    _is_bin(_r(rcmp), SXOP_EQ)
    var rbetween = _w("a IS NOT DISTINCT FROM b BETWEEN 1 AND 3")
    _is_bin(rbetween, SXOP_NOT_DISTINCT)
    _is_bin(_r(rbetween), SXOP_AND)
    # A parenthesized test is a right operand like any other.
    var rparen = _w("a IS DISTINCT FROM (b IS TRUE)")
    _is_bin(rparen, SXOP_DISTINCT)
    _is_un(_r(rparen), SXUN_IS_TRUE)
    # Any test after the right operand is refused, as DuckDB refuses it.
    var after = String(
        "SQL syntax error: a test after IS [NOT] DISTINCT FROM <operand>"
        " needs parentheses around the DISTINCT test"
    )
    assert_equal(_err("SELECT a IS DISTINCT FROM 1 IS TRUE FROM t"), after)
    assert_equal(_err("SELECT a IS DISTINCT FROM b = 2 IS NULL FROM t"), after)
    assert_equal(_err("SELECT a IS NOT DISTINCT FROM 1 ISNULL FROM t"), after)
    assert_equal(_err("SELECT a IS DISTINCT FROM 1 NOTNULL FROM t"), after)
    assert_equal(_err("SELECT a IS DISTINCT FROM 1 NOT NULL FROM t"), after)
    # A parenthesized DISTINCT test takes a test after it.
    var wrapped = _w("(a IS DISTINCT FROM 1) IS TRUE")
    _is_un(wrapped, SXUN_IS_TRUE)
    _is_bin(_child(wrapped), SXOP_DISTINCT)
    # `NOT` after the operand that is not `NOT NULL` is left to the caller.
    _refuses("a IS DISTINCT FROM 1 NOT 2", "")
    # Two comparisons on the right are refused as trailing tokens, as DuckDB
    # refuses them.
    _refuses("a IS DISTINCT FROM 2 = 2 = 3", "")
    _refuses("a IS DISTINCT b", "expected keyword 'from'")
    _refuses("(a IS NOT DISTINCT)", "expected keyword 'from'")


def test_extract_position_and_casts() raises:
    var ex = _e("EXTRACT(year FROM d)")
    assert_equal(ex.text, "date_part")
    assert_equal(_arg(ex, 0).text, "year")
    _is_col(_arg(ex, 1), "d")
    assert_equal(_arg(_e("EXTRACT('dow' FROM d)"), 0).text, "dow")
    _is_col(_e("extract"), "extract")
    _refuses("EXTRACT(5 FROM d)", "EXTRACT expects a field name")
    _refuses("EXTRACT(year d)", "EXTRACT(year ...) is missing the FROM keyword")
    _refuses("EXTRACT(year FROM d", "')' to close EXTRACT(...)")
    var p = _e("POSITION('b' IN s)")
    assert_equal(p.text, String(POSITION_IN_DESUGAR_NAME))
    _is_col(_arg(p, 0), "s")
    assert_equal(_arg(p, 1).text, "b")
    var comma = _e("position(a, b)")
    assert_equal(comma.text, "position")
    assert_equal(_e("position((1), 2)").text, "position")
    assert_equal(_e("position(a)").text, "position")
    _refuses("POSITION(a IS NULL IN s)", "expected keyword 'in'")
    _refuses("POSITION((1, 2) IN s)", "SQL syntax error: expected ')'")
    _refuses("POSITION(a IN s", "')' to close POSITION(... IN ...)")
    _refuses("position(a", "SQL syntax error: expected ')'")
    var c = _e("CAST(a AS decimal(18, 4))")
    assert_equal(c.text, String(CAST_DESUGAR_NAME))
    assert_equal(_arg(c, 1).text, "decimal(18,4)")
    var tc = _e("TRY_CAST(a AS double precision)")
    assert_equal(tc.text, String(TRY_CAST_DESUGAR_NAME))
    assert_equal(_arg(tc, 1).text, "double precision")
    _is_col(_e("cast"), "cast")
    _refuses("CAST(a)", "CAST is missing the AS keyword — the spelling is CAST(<expr> AS <type>)")
    _refuses("TRY_CAST(a)", "TRY_CAST is missing the AS keyword")
    _refuses("CAST(a AS bigint", "')' to close CAST(...)")
    _refuses("CAST(a AS 5)", "CAST expects a type name")
    var dc = _e("a::bigint::double")
    assert_equal(dc.text, String(CAST_DESUGAR_NAME))
    assert_equal(_arg(dc, 1).text, "double")
    assert_equal(_arg(_arg(dc, 0), 1).text, "bigint")
    var neg = _e("-1::double")
    _is_int(_arg(neg, 0), -1)
    assert_equal(_arg(_e("-1.5::double"), 0).float_val, -1.5)
    assert_equal(_arg(_e("a::varchar()"), 1).text, "varchar()")
    assert_equal(_arg(_e("CAST(a AS double)"), 1).text, "double")
    var st = _parse("SELECT a::double x FROM t")
    assert_equal(st.query.select_items[0].out_alias.value(), "x")
    assert_equal(_arg(st.query.select_items[0].expr, 1).text, "double")
    _refuses("a::5", "the '::' cast operator expects a type name")
    _refuses("a::decimal(18 4)", "')' to close the type parameters")
    _refuses("a::decimal(99999999999999999999)", "the type parameter 99999999999999999999 is out of range for BIGINT (DuckDB v1.5.3 refuses it too")


def test_calls_aggregates_and_columns() raises:
    var cnt = _e("count(*)")
    assert_equal(Int(cnt.tag), Int(SX_AGG))
    assert_equal(Int(cnt.op), Int(SXAGG_COUNT))
    assert_equal(Int(_child(cnt).tag), Int(SX_STAR))
    var cd = _e("count(DISTINCT a)")
    assert_true(cd.agg_distinct)
    assert_equal(cd.text, "count")
    var mean = _e("MEAN(v)")
    assert_equal(Int(mean.op), Int(SXAGG_AVG))
    assert_equal(mean.text, "mean")
    assert_equal(Int(_e("sum(a + 1)").op), Int(SXAGG_SUM))
    _refuses("sum(a", "SQL syntax error: expected ')'")
    var up = _e("upper(a)")
    assert_equal(Int(up.tag), Int(SX_CALL))
    assert_equal(len(up._call.value().args), 1)
    assert_equal(len(_e("now()")._call.value().args), 0)
    assert_equal(len(_e("f(a, b, 1)")._call.value().args), 3)
    _is_col(_arg(_e("f(distinct)"), 0), "distinct")
    assert_equal(Int(_arg(_e("f(*)"), 0).tag), Int(SX_STAR))
    _is_col(_arg(_e("f(distinct, x)"), 0), "distinct")
    _refuses("median(DISTINCT q)", "DISTINCT inside 'median(...)'. DISTINCT is only supported on COUNT")
    _refuses("upper(DISTINCT q)", "DISTINCT is not valid inside the scalar function 'upper(...)'")
    _refuses("f(a, b", "SQL syntax error: expected ')'")
    _refuses("rank()", "the ranking window function 'rank' requires an OVER (...) clause")
    _refuses("rank(1)", "')' (ranking window functions take no arguments)")
    # Without OVER a value / distribution window name is an ordinary call.
    assert_equal(_e("lag(x)").text, "lag")
    assert_equal(_e("ntile(4)").text, "ntile")
    var q = _e("t.a")
    _is_col(q, "a")
    assert_equal(q.qualifier, "t")
    _refuses("t.*", "expected column after '.'")


def test_case_expressions() raises:
    var s = _e("CASE WHEN a > 1 THEN 'x' WHEN a > 2 THEN 'y' ELSE 'z' END")
    assert_equal(Int(s.tag), Int(SX_CASE))
    assert_equal(len(s._case.value().conds), 2)
    assert_equal(len(s._case.value().results), 2)
    assert_equal(len(s._case.value().otherwise), 1)
    _is_bin(s._case.value().conds[0], SXOP_GT)
    var simple = _e("CASE a WHEN 1 THEN 'x' WHEN 2 THEN 'y' END")
    assert_equal(len(simple._case.value().otherwise), 0)
    _is_bin(simple._case.value().conds[1], SXOP_EQ)
    _is_col(_l(simple._case.value().conds[1]), "a")
    _is_int(_r(simple._case.value().conds[1]), 2)
    _refuses("CASE END", "CASE requires at least one WHEN clause")
    _refuses("CASE WHEN a 1 END", "expected keyword 'then'")
    _refuses("CASE WHEN a THEN 1", "expected keyword 'end'")


def test_select_list_aliases_and_operator_words() raises:
    var st = _parse("SELECT a AS x, b y, *, c FROM t")
    assert_equal(st.query.select_items[0].out_alias.value(), "x")
    assert_equal(st.query.select_items[1].out_alias.value(), "y")
    assert_true(st.query.select_items[2].is_star)
    assert_false(Bool(st.query.select_items[3].out_alias))
    _refuses("a AS 5", "expected alias after AS")
    _refuses("count(*) EXPORT_STATE", "EXPORT_STATE on `count(...)` (an aggregate's internal STATE")
    _refuses("upper(a) export_state", "EXPORT_STATE on `upper(...)`")
    _refuses("a export_state", "SQL not supported: EXPORT_STATE (an aggregate's")
    _refuses("a COLLATE nocase", "COLLATE (a collation on the expression before it)")
    _refuses("a GLOB 'x*'", "the GLOB pattern operator")
    _refuses("a LIKE 'x' ESCAPE '!'", "a LIKE pattern's ESCAPE character")
    _refuses("count(*) FILTER (WHERE a > 1)", "an aggregate's FILTER (WHERE ...) clause on `count(...)`")
    _refuses("ts AT TIME ZONE 'UTC'", "AT TIME ZONE")
    _refuses("list(a) WITHIN GROUP (ORDER BY a)", "WITHIN GROUP (ORDER BY ...) on `list(...)`")
    # Away from the operator's shape, the same words are aliases.
    var w = _parse("SELECT a filter, b at, c within FROM t")
    assert_equal(w.query.select_items[0].out_alias.value(), "filter")
    assert_equal(w.query.select_items[1].out_alias.value(), "at")
    assert_equal(w.query.select_items[2].out_alias.value(), "within")


def _wrefuses(pred: String, needle: String) raises:
    var m = _err("SELECT * FROM t WHERE " + pred)
    assert_true(needle in m, "WHERE `" + pred + "` raised: " + m)


def test_quoted_keywords_are_columns_and_aliases() raises:
    var st = _parse('SELECT "order", "select" AS "From", "Mixed Case" FROM t')
    _is_col(st.query.select_items[0].expr, "order")
    assert_false(Bool(st.query.select_items[0].out_alias))
    _is_col(st.query.select_items[1].expr, "select")
    assert_equal(st.query.select_items[1].out_alias.value(), "From")
    # A quoted word keeps its case; the bare spelling is folded.
    _is_col(st.query.select_items[2].expr, "Mixed Case")
    _is_col(_e("Total"), "total")
    # The words a bare column reading is guarded for stay names when quoted.
    _is_col(_e('"true"'), "true")
    _is_col(_e('"false"'), "false")
    _is_col(_e('"null"'), "null")
    _is_col(_e('"case"'), "case")
    _is_col(_e('"date"'), "date")
    _is_col(_e('"timestamp"'), "timestamp")
    _is_col(_e('"interval"'), "interval")
    _is_col(_e('"exists"'), "exists")
    _is_col(_e('"extract"'), "extract")
    _is_col(_e('"cast"'), "cast")
    _is_col(_e('"position"'), "position")
    _is_col(_e('"substring"'), "substring")
    _is_col(_e('"sum"'), "sum")
    _is_col(_e('"rank"'), "rank")
    # Where the bare word opens a literal, the quoted one is a column and the
    # string after it is a stray token.
    assert_equal(Int(_e("date '2020-01-01'").tag), Int(SX_DATE))
    _refuses("\"date\" '2020-01-01'", "expected keyword 'from'")
    _refuses("\"timestamp\" '2020-01-01'", "expected keyword 'from'")
    _refuses("\"timestamptz\" '2020-01-01'", "expected keyword 'from'")
    assert_equal(Int(_e("interval '1' day").tag), Int(SX_INTERVAL))
    _refuses("\"interval\" '1' day", "expected keyword 'from'")
    # Bare `true` is the literal; a quoted `"true"` followed by `.` is a
    # qualifier.
    assert_equal(Int(_e("true").tag), Int(SX_BOOL))
    var qual = _e('"true"."x"')
    assert_equal(qual.qualifier, "true")
    assert_equal(qual.text, "x")


def test_a_quoted_word_beside_a_predicate_keyword_is_a_name() raises:
    # Bare `NOT EXISTS (...)` is a subquery predicate; `NOT "exists"` negates
    # the column called exists.
    var neg = _w('NOT "exists"')
    _is_un(neg, SXUN_NOT)
    _is_col(_child(neg), "exists")
    _is_col(_w('"exists"'), "exists")
    _is_bin(_w('"exists" = 1'), SXOP_EQ)
    # `a NOT <word>` is the postfix predicate only for the bare words; with a
    # quoted word the NOT is no operator here and the statement is refused.
    _ = _w("a NOT IN (1)")
    _ = _w("a NOT LIKE 'x'")
    _ = _w("a NOT BETWEEN 1 AND 2")
    _ = _w("a NOT ILIKE 'x'")
    _ = _w("a NOT SIMILAR TO 'x'")
    _wrefuses("a NOT \"in\" (1)", "unexpected trailing tokens after query")
    _wrefuses("a NOT \"like\" 'x'", "unexpected trailing tokens after query")
    _wrefuses("a NOT SIMILAR \"to\" 'x'", "unexpected trailing tokens after query")
    _wrefuses("a NOT \"similar\" TO 'x'", "unexpected trailing tokens after query")
    # `NOT NULL` as a postfix test, and its quoted lookalike.
    var nn = _e("a NOT NULL")
    _is_un(nn, SXUN_IS_NOT_NULL)
    _refuses("a NOT \"null\"", "SQL syntax error")
    # `ISNULL` / `NOTNULL` are postfix tests bare and aliases quoted.
    var st = _parse('SELECT a "isnull", b "notnull" FROM t')
    assert_equal(st.query.select_items[0].out_alias.value(), "isnull")
    assert_equal(st.query.select_items[1].out_alias.value(), "notnull")
    _is_un(_e("a ISNULL"), SXUN_IS_NULL)


def test_quoted_words_in_the_special_call_grammars_are_plain_names() raises:
    # Bare, each of these is its own grammar; quoted, it is an ordinary call
    # (or, where no call can follow, a syntax error at the word).
    _refuses("cast(a)", "CAST is missing the AS keyword")
    var c = _e('"cast"(a)')
    assert_equal(Int(c.tag), Int(SX_CALL))
    assert_equal(c.text, "cast")
    _refuses("\"extract\"(year FROM a)", "expected ')'")
    _refuses("position('a' \"in\" b)", "expected ')'")
    _refuses("substring(a \"from\" 1)", "expected ')'")
    _refuses("cast(a AS double \"precision\")", "')' to close CAST(...)")
    _ = _e("cast(a AS double precision)")
    # A quoted TYPE name resolves case-insensitively, as in DuckDB: it reaches
    # the binder lower-folded, in both cast spellings.
    assert_equal(_arg(_e('CAST(a AS "INTEGER")'), 1).text, "integer")
    assert_equal(_arg(_e('a::"BigInt"'), 1).text, "bigint")
    # A quoted `"over"` after a call is an alias, not the window clause.
    var lag = _parse('SELECT lag(a) "over" FROM t')
    assert_equal(Int(lag.query.select_items[0].expr.tag), Int(SX_CALL))
    assert_equal(lag.query.select_items[0].out_alias.value(), "over")
    var win = _e("lag(a) OVER (ORDER BY b)")
    assert_equal(Int(win.tag), Int(SX_WINDOW))


def test_a_quoted_function_name_resolves_case_insensitively() raises:
    var s = _e('"SUM"(a)')
    assert_equal(Int(s.tag), Int(SX_AGG))
    assert_equal(s.text, "sum")
    var agg = _e('"sum"(a)')
    assert_equal(Int(agg.tag), Int(SX_AGG))
    var c = _e('"Abs"(a)')
    assert_equal(Int(c.tag), Int(SX_CALL))
    assert_equal(c.text, "abs")
    # A quoted aggregate name without a call is a column.
    _is_col(_e('"SUM"'), "SUM")


def test_quoted_qualified_names_and_aliases() raises:
    var a = _e('"t"."c"')
    assert_equal(a.qualifier, "t")
    assert_equal(a.text, "c")
    var b = _e('t."C"')
    assert_equal(b.qualifier, "t")
    assert_equal(b.text, "C")
    var c = _e('"T".c')
    assert_equal(c.qualifier, "T")
    assert_equal(c.text, "c")
    var st = _parse('SELECT a AS "X""y", b "Two Words", c AS "select" FROM t')
    assert_equal(st.query.select_items[0].out_alias.value(), 'X"y')
    assert_equal(st.query.select_items[1].out_alias.value(), "Two Words")
    assert_equal(st.query.select_items[2].out_alias.value(), "select")
    # A quoted word is an implicit alias even where the bare word is an
    # operator this grammar refuses by name, or a clause word.
    var words: List[String] = [
        "export_state", "collate", "glob", "escape", "filter", "at", "within",
        "not", "from", "where", "group", "order", "limit", "having", "union",
        "qualify", "window", "isnull", "notnull",
    ]
    for i in range(len(words)):
        var w = _parse('SELECT a "' + words[i] + '", b FROM t')
        assert_equal(w.query.select_items[0].out_alias.value(), words[i])
        _is_col(w.query.select_items[1].expr, "b")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
