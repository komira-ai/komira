# =============================================================================
# Direct tests of komira_sql's tokenizer (sql_token) and parsed AST (sql_ast)
# =============================================================================
#
# What each test proves, and the defect (mutant) it catches:
#   1. tokenize() emits the exact kind sequence for one statement that uses
#      every two-character operator (<= >= <> != :: // ^@ || !~ ~~) and ends
#      in TK_EOF.
#      (mutant caught: TK_LE and TK_GE swapped in the `<=` / `>=` arms)
#   2. Unquoted identifiers are lower-folded; a quoted literal keeps its case
#      and `''` inside it is one quote.
#      (mutant caught: the identifier arm appends `word` instead of
#      `word.lower()`)
#   3. An integer past Int64.MAX keeps its decimal digits in Token.text (and
#      int_val keeps the wrapped bits); Int64.MAX itself carries no text.
#      (mutant caught: the past-Int64 text dropped, or the overflow check off
#      by one)
#   4. An unterminated string and a lone `!` raise an Error that starts with
#      "SQL syntax error", never a crash and never a token.
#      (mutant caught: the lone `!` falls through to a token instead of
#      raising)
#   5. sql_call_is_aggregate / sql_agg_code classify sum, count, median and
#      corr as aggregates (each in its own half) and upper as scalar.
#      (mutant caught: a name dropped from either table, or the halves no
#      longer disjoint)
#   6. SqlExpr.binary(+, int_lit, agg(sum)).contains_aggregate() is True, a
#      scalar tree is False, and copy() keeps both answers and the children.
#      (mutant caught: contains_aggregate() stops walking the right child of
#      a binary node)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_sql.sql_token import (
    Token,
    tokenize,
    TK_EOF,
    TK_IDENT,
    TK_INT,
    TK_STRING,
    TK_COMMA,
    TK_LE,
    TK_GE,
    TK_NE,
    TK_DCOLON,
    TK_DSLASH,
    TK_CARET_AT,
    TK_DPIPE,
    TK_NTILDE,
    TK_LIKE_SYM,
)
from komira_sql.sql_ast import (
    SqlExpr,
    sql_agg_code,
    sql_call_is_aggregate,
    SXAGG_SUM,
    SXAGG_COUNT,
    SXOP_ADD,
    SXOP_MUL,
    SX_BINARY,
    SX_INT,
    SX_AGG,
    SX_COLUMN,
)


def _kinds(toks: List[Token]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(toks)):
        out.append(Int(toks[i].kind))
    return out^


def _assert_kinds(sql: String, expected: List[Int]) raises:
    var got = _kinds(tokenize(sql))
    assert_equal(len(got), len(expected), "token count for: " + sql)
    for i in range(len(expected)):
        assert_equal(got[i], expected[i], "token " + String(i) + " of: " + sql)


def _syntax_error(sql: String) raises -> String:
    try:
        _ = tokenize(sql)
    except e:
        return String(e)
    raise Error("tokenize accepted: " + sql)


def test_every_two_character_operator_lexes_to_its_kind() raises:
    var sql = String(
        "a <= b, c >= d, e <> f, g != h, x::bigint, p // q, s ^@ t, u || v,"
        " w !~ y, z ~~ k"
    )
    var I = Int(TK_IDENT)
    var C = Int(TK_COMMA)
    var expected: List[Int] = [
        I, Int(TK_LE), I, C,
        I, Int(TK_GE), I, C,
        I, Int(TK_NE), I, C,
        I, Int(TK_NE), I, C,
        I, Int(TK_DCOLON), I, C,
        I, Int(TK_DSLASH), I, C,
        I, Int(TK_CARET_AT), I, C,
        I, Int(TK_DPIPE), I, C,
        I, Int(TK_NTILDE), I, C,
        I, Int(TK_LIKE_SYM), I,
        Int(TK_EOF),
    ]
    _assert_kinds(sql, expected)
    # `~~` is the LIKE flavour 0 (its flavour rides int_val).
    var toks = tokenize(sql)
    assert_equal(toks[len(toks) - 3].int_val, Int64(0))


def test_identifiers_fold_and_literals_keep_case() raises:
    var toks = tokenize("SELECT MyCol FROM T_1 WHERE s = 'It''s MiXed'")
    var words: List[String] = ["select", "mycol", "from", "t_1", "where", "s"]
    for i in range(len(words)):
        assert_equal(Int(toks[i].kind), Int(TK_IDENT))
        assert_equal(toks[i].text, words[i])
    assert_equal(Int(toks[7].kind), Int(TK_STRING))
    assert_equal(toks[7].text, "It's MiXed")
    assert_equal(Int(toks[8].kind), Int(TK_EOF))
    assert_equal(len(toks), 9)


def test_an_integer_past_int64_keeps_its_digits() raises:
    var toks = tokenize("18446744073709551615 9223372036854775807 9223372036854775808")
    assert_equal(Int(toks[0].kind), Int(TK_INT))
    assert_equal(toks[0].text, "18446744073709551615")
    assert_equal(toks[0].int_val, Int64(-1))  # the wrapped bits
    # Int64.MAX itself is in range: no digits text, the exact value.
    assert_equal(Int(toks[1].kind), Int(TK_INT))
    assert_equal(toks[1].text, "")
    assert_equal(toks[1].int_val, Int64.MAX)
    # One past it is the one magnitude a unary minus makes legal.
    assert_equal(toks[2].text, "9223372036854775808")
    assert_equal(toks[2].int_val, Int64.MIN)


def test_bad_input_raises_a_syntax_error_not_a_crash() raises:
    var unterminated = _syntax_error("SELECT 'abc")
    assert_true(unterminated.startswith("SQL syntax error"), unterminated)
    var bang = _syntax_error("a ! b")
    assert_true(bang.startswith("SQL syntax error"), bang)
    var bang_at_end = _syntax_error("a !")
    assert_true(bang_at_end.startswith("SQL syntax error"), bang_at_end)


def test_aggregate_classifiers() raises:
    # The fast-path half: sum and count are SX_AGG codes, not call aggregates.
    assert_equal(sql_agg_code("sum"), Int(SXAGG_SUM))
    assert_equal(sql_agg_code("count"), Int(SXAGG_COUNT))
    assert_false(sql_call_is_aggregate("sum"))
    assert_false(sql_call_is_aggregate("count"))
    # The statistical half: median and corr ride the call grammar.
    assert_true(sql_call_is_aggregate("median"))
    assert_true(sql_call_is_aggregate("corr"))
    assert_equal(sql_agg_code("median"), -1)
    assert_equal(sql_agg_code("corr"), -1)
    # A scalar is in neither half.
    assert_false(sql_call_is_aggregate("upper"))
    assert_equal(sql_agg_code("upper"), -1)


def test_contains_aggregate_through_a_binary_node_and_copy() raises:
    # 1 + sum(x): the aggregate is the RIGHT child.
    var tree = SqlExpr.binary(
        SXOP_ADD, SqlExpr.int_lit(1), SqlExpr.agg(SXAGG_SUM, SqlExpr.column("x"))
    )
    assert_true(tree.contains_aggregate())
    assert_false(tree.is_aggregate())
    # x * 2: no aggregate anywhere.
    var scalar = SqlExpr.binary(SXOP_MUL, SqlExpr.column("x"), SqlExpr.int_lit(2))
    assert_false(scalar.contains_aggregate())

    var tree2 = tree.copy()
    assert_true(tree2.contains_aggregate())
    assert_equal(Int(tree2.tag), Int(SX_BINARY))
    assert_equal(Int(tree2.op), Int(SXOP_ADD))
    assert_equal(Int(tree2._binary.value().left[].tag), Int(SX_INT))
    assert_equal(tree2._binary.value().left[].int_val, Int64(1))
    assert_equal(Int(tree2._binary.value().right[].tag), Int(SX_AGG))
    assert_equal(Int(tree2._binary.value().right[]._agg.value().arg[].tag), Int(SX_COLUMN))
    assert_equal(tree2._binary.value().right[]._agg.value().arg[].text, "x")
    var scalar2 = scalar.copy()
    assert_false(scalar2.contains_aggregate())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
