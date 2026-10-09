# =============================================================================
# src/komira_textproto/tests/test_textproto_describe.mojo
#   How refusals name what they expected and what they found: the name of
#   every token kind (and of an unknown kind), the description of every token
#   kind, `expect` refusing each scalar kind, and the line an empty input's
#   end-of-input refusal names.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_textproto import (
    TOKEN_COLON,
    TOKEN_LBRACE,
    TOKEN_NUMBER,
    TOKEN_RBRACE,
    TOKEN_STRING,
    TOKEN_WORD,
    Token,
    TokenCursor,
    lex,
    token_kind_name,
)


def _expect_refusal(text: String, kind: Int) raises -> String:
    # The refusal `expect(kind)` raises on the first token of `text`.
    var c = TokenCursor(lex(text))
    try:
        _ = c.expect(kind)
    except e:
        return String(e)
    return String("<no refusal>")


def test_every_kind_has_its_own_name() raises:
    assert_equal(token_kind_name(TOKEN_WORD), String("word"))
    assert_equal(token_kind_name(TOKEN_NUMBER), String("number"))
    assert_equal(token_kind_name(TOKEN_STRING), String("string"))
    assert_equal(token_kind_name(TOKEN_LBRACE), String("'{'"))
    assert_equal(token_kind_name(TOKEN_RBRACE), String("'}'"))
    assert_equal(token_kind_name(TOKEN_COLON), String("':'"))


def test_an_unknown_kind_is_named_by_its_number() raises:
    # Past the last kind and below the first: the number is kept, sign and
    # all, so a caller passing a stray int sees which one.
    assert_equal(token_kind_name(6), String("token kind 6"))
    assert_equal(token_kind_name(-1), String("token kind -1"))
    assert_equal(token_kind_name(42), String("token kind 42"))


def test_describe_quotes_scalars_and_names_structure() raises:
    assert_equal(
        Token(TOKEN_WORD, String("beta"), 1).describe(), String("word 'beta'")
    )
    assert_equal(
        Token(TOKEN_NUMBER, String("-7"), 1).describe(), String("number '-7'")
    )
    # A string is shown in double quotes with its decoded text, so a string
    # holding a quote character is not mistaken for a word.
    assert_equal(
        Token(TOKEN_STRING, String("a'b"), 1).describe(),
        String("string \"a'b\""),
    )
    assert_equal(
        Token(TOKEN_STRING, String(""), 1).describe(), String("string \"\"")
    )
    assert_equal(Token(TOKEN_LBRACE, String("{"), 1).describe(), String("'{'"))
    assert_equal(Token(TOKEN_RBRACE, String("}"), 1).describe(), String("'}'"))
    assert_equal(Token(TOKEN_COLON, String(":"), 1).describe(), String("':'"))


def test_expect_names_the_scalar_it_found() raises:
    assert_equal(
        _expect_refusal(String("\n\nbeta"), TOKEN_LBRACE),
        String("textproto: line 3: expected '{' but got word 'beta'"),
    )
    assert_equal(
        _expect_refusal(String("7"), TOKEN_COLON),
        String("textproto: line 1: expected ':' but got number '7'"),
    )
    assert_equal(
        _expect_refusal(String("\"v\""), TOKEN_WORD),
        String("textproto: line 1: expected word but got string \"v\""),
    )
    assert_equal(
        _expect_refusal(String("x"), TOKEN_NUMBER),
        String("textproto: line 1: expected number but got word 'x'"),
    )
    assert_equal(
        _expect_refusal(String("}"), TOKEN_STRING),
        String("textproto: line 1: expected string but got '}'"),
    )


def test_end_of_an_empty_input_is_line_one() raises:
    # No token: the end-of-input refusal names line 1, even when comments
    # and blank lines push the end of the text further down.
    for src in [String(""), String("# only a comment\n\n# and another\n")]:
        var c = TokenCursor(lex(src), String("widgets file"))
        assert_equal(c.last_line(), 1)
        var msg = String("<no refusal>")
        try:
            _ = c.expect(TOKEN_NUMBER)
        except e:
            msg = String(e)
        assert_equal(
            msg,
            String(
                "widgets file: line 1: expected number but reached the end"
                " of input"
            ),
        )


def test_end_of_input_names_the_last_token_line() raises:
    var c = TokenCursor(lex(String("a\n\nb # c\n\n")))
    assert_equal(c.last_line(), 3)
    _ = c.next(String("a"))
    _ = c.next(String("b"))
    var msg = String("<no refusal>")
    try:
        _ = c.expect(TOKEN_STRING)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("textproto: line 3: expected string but reached the end of input"),
    )


def test_end_of_a_single_token_input_names_its_line() raises:
    # One token on line 3: last_line() must read that token's line, not fall
    # back to the empty-input line 1.
    var c = TokenCursor(lex(String("\n\nx")))
    assert_equal(c.last_line(), 3)
    _ = c.next(String("x"))
    var msg = String("<no refusal>")
    try:
        _ = c.expect(TOKEN_STRING)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("textproto: line 3: expected string but reached the end of input"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
