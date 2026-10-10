# =============================================================================
# Direct tests of the parser's private helpers (sql_parser._Parser)
# =============================================================================
#
# `parse_sql` always hands the parser a token list that ends in TK_EOF and
# only calls these helpers in states the grammar reaches, so a few arms are
# reachable only by calling the helper directly. Each test below drives one
# such arm on a hand-made `_Parser`, next to a control that takes the other
# arm, so a defect in either direction goes red.
#
# What each test proves, and the defect (mutant) it catches:
#   1. `_advance` moves to the next token and then stays on the last one.
#      (mutant caught: the bound check is `pos < len(tokens)`, so the second
#      advance steps past the end)
#   2. `_position_in_form` answers False for a list that runs out of tokens
#      before any `)`, `,`, `IN` or EOF, and True when a top-level `in` comes
#      first. (mutant caught: the fall-through after the loop returns True)
#   3. `_over_follows_call` answers False for an argument list that runs out
#      of tokens before its `)`, and True for `(v) over`.
#      (mutant caught: the fall-through after the loop returns True)
#   4. `_refuse_option_for_kind` explains an Avro refusal with the Avro
#      reason, and refuses an option on a kind with no format reason (CSV)
#      with the bare sentence. (mutant caught: the Avro arm tests TVF_CSV, so
#      the Avro message loses its reason and the CSV one gains it)
#   5. `_agg_to_win_code` maps each of the five aggregates to its window code
#      and refuses any other code by name.
#      (mutant caught: the final raise returns SXWIN_SUM instead)
#   6. `_refuse_unserved_operator_word` refuses the identifier `glob` and
#      leaves a string literal whose text is `glob` alone.
#      (mutant caught: the non-identifier early return is removed)
#   7. `_is_structural_kw` is True for the identifier `from` and False for a
#      string literal whose text is `from`.
#      (mutant caught: the non-identifier early return is removed)
#   8. `_refuse_ambiguous_unnamed_subquery` skips a synthetic relation (a
#      `#` in its name) that has no alias, and refuses one whose alias is
#      also another relation's name. (mutant caught: the skip tests only the
#      `#`, so the empty alias is compared and matches the other relation's
#      empty alias)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_sql.sql_token import Token, tokenize, TK_EOF, TK_IDENT, TK_STRING
from komira_sql.sql_ast import (
    SXAGG_SUM, SXAGG_COUNT, SXAGG_MIN, SXAGG_MAX, SXAGG_AVG,
    SXWIN_SUM, SXWIN_COUNT, SXWIN_MIN, SXWIN_MAX, SXWIN_AVG,
    TVF_AVRO, TVF_CSV, FromRelation,
)
from komira_sql.sql_parser import _Parser, _refuse_ambiguous_unnamed_subquery


def _without_eof(sql: String) raises -> List[Token]:
    """The tokens of `sql` with the trailing TK_EOF removed."""
    var toks = tokenize(sql)
    var last = toks.pop()
    assert_equal(Int(last.kind), Int(TK_EOF))
    return toks^


def test_advance_stays_on_the_last_token() raises:
    var p = _Parser(tokenize("a"))
    assert_equal(p.pos, 0)
    p._advance()
    assert_equal(p.pos, 1)
    assert_equal(Int(p._kind()), Int(TK_EOF))
    p._advance()
    assert_equal(p.pos, 1)
    assert_equal(Int(p._kind()), Int(TK_EOF))


def test_position_in_form_out_of_tokens_is_not_the_form() raises:
    var p = _Parser(_without_eof("position(a"))
    assert_false(p._position_in_form(1))
    # Control: a top-level `in` before the list ends is the grammar form.
    var q = _Parser(_without_eof("position(a in"))
    assert_true(q._position_in_form(1))


def test_over_follows_call_out_of_tokens_is_false() raises:
    var p = _Parser(_without_eof("lag(v"))
    assert_false(p._over_follows_call(1))
    # Control: the closing `)` followed by `over`.
    var q = _Parser(_without_eof("lag(v) over"))
    assert_true(q._over_follows_call(1))


def _option_refusal(kind: UInt8, fname: String) raises -> String:
    var p = _Parser(tokenize(""))
    try:
        p._refuse_option_for_kind(fname, String("header"), kind, String("read_csv"))
    except e:
        return String(e)
    raise Error("no refusal for " + fname)


def test_refuse_option_avro_reason_and_no_reason() raises:
    var avro = _option_refusal(TVF_AVRO, String("read_avro"))
    assert_true(
        avro.startswith(
            "SQL not supported: read_avro option 'header' is a read_csv"
            " option and means nothing here. An Avro OCF carries its writer"
            " schema and its codec in the container header"
        ),
        avro,
    )
    var csv = _option_refusal(TVF_CSV, String("read_csv"))
    assert_true(
        csv.startswith(
            "SQL not supported: read_csv option 'header' is a read_csv"
            " option and means nothing here. It is REJECTED rather than"
            " ignored"
        ),
        csv,
    )
    assert_false("Avro" in csv, csv)


def test_agg_to_win_code_maps_five_and_refuses_the_rest() raises:
    var p = _Parser(tokenize(""))
    assert_equal(Int(p._agg_to_win_code(SXAGG_SUM)), Int(SXWIN_SUM))
    assert_equal(Int(p._agg_to_win_code(SXAGG_COUNT)), Int(SXWIN_COUNT))
    assert_equal(Int(p._agg_to_win_code(SXAGG_MIN)), Int(SXWIN_MIN))
    assert_equal(Int(p._agg_to_win_code(SXAGG_MAX)), Int(SXWIN_MAX))
    assert_equal(Int(p._agg_to_win_code(SXAGG_AVG)), Int(SXWIN_AVG))
    var msg = String("")
    try:
        _ = p._agg_to_win_code(UInt8(200))
    except e:
        msg = String(e)
    assert_equal(msg, "SQL bind error: unsupported aggregate in an OVER clause")


def test_operator_word_refusal_ignores_a_string_literal() raises:
    var lit = _Parser(tokenize("'glob'"))
    assert_equal(Int(lit._kind()), Int(TK_STRING))
    assert_equal(lit.tokens[0].text, "glob")
    lit._refuse_unserved_operator_word()  # must not raise
    # Control: the identifier `glob` is refused by name.
    var ident = _Parser(tokenize("glob"))
    assert_equal(Int(ident._kind()), Int(TK_IDENT))
    var msg = String("")
    try:
        ident._refuse_unserved_operator_word()
    except e:
        msg = String(e)
    assert_true(msg.startswith("SQL not supported: the GLOB pattern operator."), msg)


def test_structural_kw_ignores_a_string_literal() raises:
    var lit = _Parser(tokenize("'from'"))
    assert_equal(Int(lit._kind()), Int(TK_STRING))
    assert_equal(lit.tokens[0].text, "from")
    assert_false(lit._is_structural_kw())
    # Control: the identifier `from` is a clause keyword.
    var ident = _Parser(tokenize("from"))
    assert_true(ident._is_structural_kw())


def test_unnamed_subquery_check_skips_a_synthetic_relation_without_alias() raises:
    var rels = List[FromRelation]()
    rels.append(FromRelation.named(String("#derived0")))
    rels.append(FromRelation.named(String("unnamed_subquery")))
    _refuse_ambiguous_unnamed_subquery(rels)  # must not raise
    # Control: the same synthetic relation named `unnamed_subquery` collides.
    var clash = List[FromRelation]()
    clash.append(FromRelation.named(String("#derived0"), String("unnamed_subquery")))
    clash.append(FromRelation.named(String("unnamed_subquery")))
    var msg = String("")
    try:
        _refuse_ambiguous_unnamed_subquery(clash)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "SQL not supported: an unaliased derived table `(SELECT ...)` is"
            " named `unnamed_subquery`"
        ),
        msg,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
