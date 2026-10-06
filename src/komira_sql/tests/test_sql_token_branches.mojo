# =============================================================================
# Branch tests of komira_sql.sql_token.tokenize
# =============================================================================
#
# Every arm of the tokenizer's ladder, and both outcomes of every lookahead
# (`i + 1 < n` false at the end of input, true with another character, true
# with the character the arm wants). test_sql_token_ast_direct holds the
# headline cases; this file reaches the rest.
#
#   1. Whitespace: space, tab, newline and carriage return are all skipped.
#      (mutant caught: one of the four dropped from _is_space)
#   2. `--` comments run to the newline or to the end of input; a lone `-`
#      (mid-input or last) is TK_MINUS.
#      (mutant caught: the comment loop not stopping at the newline)
#   3. Numbers: an INT; a FLOAT with fraction digits; `1.` and `1.x` are INT
#      then DOT; a FLOAT whose integer part is past Int64.MAX is read in
#      Float64; the overflow test's two arms (greater than MAX // 10, and
#      equal with the last digit over 7).
#      (mutants caught: `1.` lexed as a float; the past-Int64 float reading
#      the wrapped bits; the equal-prefix arm removed)
#   4. Strings: a `''` at the very end of input is an unterminated literal; a
#      quote that closes mid-input; non-ASCII bytes survive as bytes.
#      (mutant caught: the bytes rebuilt with chr(), which double-encodes)
#   5. Identifiers: upper case, underscore start, digits after the first.
#   6. Every single-character punctuation token.
#   7. Every two- and three-character operator, each also as the last
#      character of the input (the lookahead's false arm) and followed by
#      another character (the mismatch arm).
#      (mutants caught: any arm's kind or width changed; `~~*` / `!~~*`
#      flavours swapped)
#   8. The refusals: `|`, `:` and an unexpected character, each with its own
#      message, mid-input and at the end.
#      (mutant caught: a refusal message changed, or a refusal that lexes)

from std.testing import TestSuite, assert_equal, assert_true

from komira_sql.sql_token import (
    Token,
    tokenize,
    TK_EOF,
    TK_IDENT,
    TK_INT,
    TK_FLOAT,
    TK_STRING,
    TK_LPAREN,
    TK_RPAREN,
    TK_COMMA,
    TK_SEMI,
    TK_STAR,
    TK_DOT,
    TK_PLUS,
    TK_MINUS,
    TK_SLASH,
    TK_EQ,
    TK_NE,
    TK_LT,
    TK_LE,
    TK_GT,
    TK_GE,
    TK_DCOLON,
    TK_DSLASH,
    TK_PERCENT,
    TK_CARET,
    TK_CARET_AT,
    TK_AT,
    TK_DPIPE,
    TK_LIKE_SYM,
    TK_TILDE,
    TK_NTILDE,
)


def _assert_kinds(sql: String, expected: List[Int]) raises:
    var toks = tokenize(sql)
    assert_equal(len(toks), len(expected), "token count for: " + sql)
    for i in range(len(expected)):
        assert_equal(Int(toks[i].kind), expected[i], "token " + String(i) + " of: " + sql)


def _error_of(sql: String) raises -> String:
    try:
        _ = tokenize(sql)
    except e:
        return String(e)
    raise Error("tokenize accepted: " + sql)


def test_whitespace_of_every_kind_is_skipped() raises:
    _assert_kinds(" \t\r\n a \t\r\n ", [Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("", [Int(TK_EOF)])


def test_comments_and_minus() raises:
    # A comment ended by a newline, then a token on the next line.
    _assert_kinds("a -- note\nb", [Int(TK_IDENT), Int(TK_IDENT), Int(TK_EOF)])
    # A comment ended by the end of input.
    _assert_kinds("a -- note", [Int(TK_IDENT), Int(TK_EOF)])
    # `-` followed by another character, and `-` as the last character.
    _assert_kinds("1-x", [Int(TK_INT), Int(TK_MINUS), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("x -", [Int(TK_IDENT), Int(TK_MINUS), Int(TK_EOF)])


def test_numbers() raises:
    var toks = tokenize("42 3.25 0.5")
    assert_equal(Int(toks[0].kind), Int(TK_INT))
    assert_equal(toks[0].int_val, Int64(42))
    assert_equal(toks[0].text, "")
    assert_equal(Int(toks[1].kind), Int(TK_FLOAT))
    assert_equal(toks[1].float_val, 3.25)
    assert_equal(Int(toks[2].kind), Int(TK_FLOAT))
    assert_equal(toks[2].float_val, 0.5)
    # A dot with no digit after it is not a fraction: INT then DOT.
    _assert_kinds("1.", [Int(TK_INT), Int(TK_DOT), Int(TK_EOF)])
    _assert_kinds("t1.x", [Int(TK_IDENT), Int(TK_DOT), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("1.x", [Int(TK_INT), Int(TK_DOT), Int(TK_IDENT), Int(TK_EOF)])
    # A FLOAT whose integer part is past Int64.MAX: read in Float64, so the
    # value is 2^64 + 0.5 to double precision, not the wrapped -1 + 0.5.
    var big = tokenize("18446744073709551616.5")
    assert_equal(Int(big[0].kind), Int(TK_FLOAT))
    assert_equal(big[0].float_val, 18446744073709551616.5)
    # The equal-prefix arm: 922337203685477580 then a last digit of 8 (past)
    # and of 7 (Int64.MAX, in range).
    var edge = tokenize("9223372036854775808 9223372036854775807")
    assert_equal(edge[0].text, "9223372036854775808")
    assert_equal(edge[1].text, "")
    # Greater than MAX // 10 before the last digit: 9223372036854775810.
    var over = tokenize("9223372036854775810")
    assert_equal(over[0].text, "9223372036854775810")


def test_strings() raises:
    # A literal that closes mid-input, then another token.
    var toks = tokenize("'ab' c")
    assert_equal(Int(toks[0].kind), Int(TK_STRING))
    assert_equal(toks[0].text, "ab")
    assert_equal(Int(toks[1].kind), Int(TK_IDENT))
    # The empty literal, and one that closes as the last character.
    var empty = tokenize("''")
    assert_equal(Int(empty[0].kind), Int(TK_STRING))
    assert_equal(empty[0].text, "")
    # An escaped quote as the last two characters leaves the literal open.
    var open_msg = _error_of("'ab''")
    assert_equal(open_msg, "SQL syntax error: unterminated string literal")
    # Non-ASCII bytes come back as the same bytes (C3 9F is U+00DF).
    var nonascii = tokenize("'Straße'")
    assert_equal(nonascii[0].text, "Straße")
    assert_equal(len(nonascii[0].text.as_bytes()), 7)


def test_identifiers() raises:
    var toks = tokenize("ABC _x1 z9_Q")
    assert_equal(toks[0].text, "abc")
    assert_equal(toks[1].text, "_x1")
    assert_equal(toks[2].text, "z9_q")
    for i in range(3):
        assert_equal(Int(toks[i].kind), Int(TK_IDENT))


def test_single_character_punctuation() raises:
    _assert_kinds(
        "( ) , ; * . + - / % = < > ^ @ ~",
        [
            Int(TK_LPAREN), Int(TK_RPAREN), Int(TK_COMMA), Int(TK_SEMI),
            Int(TK_STAR), Int(TK_DOT), Int(TK_PLUS), Int(TK_MINUS),
            Int(TK_SLASH), Int(TK_PERCENT), Int(TK_EQ), Int(TK_LT),
            Int(TK_GT), Int(TK_CARET), Int(TK_AT), Int(TK_TILDE), Int(TK_EOF),
        ],
    )


def test_operators_at_the_end_of_input() raises:
    # Each prefix character as the LAST character: the lookahead is false.
    _assert_kinds("/", [Int(TK_SLASH), Int(TK_EOF)])
    _assert_kinds("<", [Int(TK_LT), Int(TK_EOF)])
    _assert_kinds(">", [Int(TK_GT), Int(TK_EOF)])
    _assert_kinds("^", [Int(TK_CARET), Int(TK_EOF)])
    _assert_kinds("~", [Int(TK_TILDE), Int(TK_EOF)])
    _assert_kinds("~~", [Int(TK_LIKE_SYM), Int(TK_EOF)])
    _assert_kinds("!~", [Int(TK_NTILDE), Int(TK_EOF)])
    _assert_kinds("!~~", [Int(TK_LIKE_SYM), Int(TK_EOF)])
    _assert_kinds("<=", [Int(TK_LE), Int(TK_EOF)])
    _assert_kinds(">=", [Int(TK_GE), Int(TK_EOF)])
    _assert_kinds("<>", [Int(TK_NE), Int(TK_EOF)])
    _assert_kinds("!=", [Int(TK_NE), Int(TK_EOF)])
    _assert_kinds("::", [Int(TK_DCOLON), Int(TK_EOF)])
    _assert_kinds("//", [Int(TK_DSLASH), Int(TK_EOF)])
    _assert_kinds("^@", [Int(TK_CARET_AT), Int(TK_EOF)])
    _assert_kinds("||", [Int(TK_DPIPE), Int(TK_EOF)])


def test_operators_followed_by_another_character() raises:
    # Each prefix character followed by a character its arm does not want.
    var I = Int(TK_IDENT)
    var E = Int(TK_EOF)
    _assert_kinds("/a", [Int(TK_SLASH), I, E])
    _assert_kinds("<a", [Int(TK_LT), I, E])
    _assert_kinds(">a", [Int(TK_GT), I, E])
    _assert_kinds("^a", [Int(TK_CARET), I, E])
    _assert_kinds("~a", [Int(TK_TILDE), I, E])
    _assert_kinds("~~a", [Int(TK_LIKE_SYM), I, E])
    _assert_kinds("!~a", [Int(TK_NTILDE), I, E])
    _assert_kinds("!~~a", [Int(TK_LIKE_SYM), I, E])


def test_like_family_flavours() raises:
    # One token for the LIKE family; the flavour rides int_val:
    # 0 `~~`, 1 `!~~`, 2 `~~*`, 3 `!~~*`.
    var toks = tokenize("~~ !~~ ~~* !~~*")
    var flavours: List[Int] = [0, 1, 2, 3]
    for i in range(4):
        assert_equal(Int(toks[i].kind), Int(TK_LIKE_SYM))
        assert_equal(Int(toks[i].int_val), flavours[i])
    assert_equal(Int(toks[4].kind), Int(TK_EOF))
    assert_equal(len(toks), 5)
    # A three-character operator does not swallow what follows it.
    _assert_kinds("~~*a", [Int(TK_LIKE_SYM), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("!~~*a", [Int(TK_LIKE_SYM), Int(TK_IDENT), Int(TK_EOF)])


def test_refusals_name_what_they_refuse() raises:
    var bar = _error_of("5 | 3")
    assert_true(bar.startswith("SQL not supported: the bitwise OR operator `|`"), bar)
    var bar_end = _error_of("5 |")
    assert_true(bar_end.startswith("SQL not supported: the bitwise OR operator `|`"), bar_end)
    var colon = _error_of("x:y")
    assert_true(colon.startswith("SQL syntax error: unexpected character ':'"), colon)
    assert_true("'::'" in colon, colon)
    var colon_end = _error_of("x:")
    assert_true(colon_end.startswith("SQL syntax error: unexpected character ':'"), colon_end)
    assert_equal(_error_of("a # b"), "SQL syntax error: unexpected character '#'")
    assert_equal(_error_of("!a"), "SQL syntax error: unexpected character '!'")
    assert_equal(_error_of("!"), "SQL syntax error: unexpected character '!'")


def test_token_fields() raises:
    # The fieldwise constructor and the copy keep all four fields.
    var t = Token(TK_INT, String("7"), Int64(7), Float64(0.5))
    var u = t.copy()
    assert_equal(Int(u.kind), Int(TK_INT))
    assert_equal(u.text, "7")
    assert_equal(u.int_val, Int64(7))
    assert_equal(u.float_val, 0.5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
