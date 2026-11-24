# =============================================================================
# sql_position: where a SQL text stopped parsing
# =============================================================================
#
# What each test proves:
#   * test_position_of_*: line and column (both from 1) of a byte offset: the
#     first character, mid-line, after one and two newlines, after multi-byte
#     characters (the column counts characters, not bytes), at the end of the
#     text, and an offset past either end is clamped.
#   * test_position_writes_line_and_column: a position prints as
#     `line <L>, column <C>`.
#   * test_tokenize_starts_*: `tokenize(sql, starts)` gives each token's start
#     byte, skips whitespace and comments, ends with the byte length for TK_EOF,
#     is as long as the tokens, and on a tokenizer error ends with the start of
#     the token it was lexing.
#   * test_parse_sql_text_*: a parser error sets `stopped_at` to the token the
#     parser was looking at (mid-line, on line 2, at the end of the text), a
#     tokenizer error to the unterminated string's opening quote or the
#     unexpected character, each with the error's message unchanged; a
#     statement that parses leaves `stopped_at` as given.

from std.testing import TestSuite, assert_equal

from sql.sql_ast import STMT_QUERY
from sql.sql_position import SqlPosition, parse_sql_text, position_of
from sql.sql_token import TK_EOF, tokenize


def _at(text: String, offset: Int) -> String:
    return String(position_of(text, offset))


def _stop(text: String) raises -> String:
    """`<message> | <position>` of the error `parse_sql_text(text)` raises."""
    var at = SqlPosition(0, 0)
    try:
        _ = parse_sql_text(text, at)
    except e:
        return String(e) + " | " + String(at)
    return String("parsed")


def test_position_of_first_character_and_mid_line() raises:
    assert_equal(_at("SELECT 1", 0), "line 1, column 1")
    assert_equal(_at("SELECT 1", 7), "line 1, column 8")


def test_position_of_after_newlines() raises:
    assert_equal(_at("a\nbc", 2), "line 2, column 1")
    assert_equal(_at("a\nbc", 3), "line 2, column 2")
    assert_equal(_at("a\n\nbc d", 6), "line 3, column 4")


def test_position_of_counts_characters_not_bytes() raises:
    # `é` is two bytes, `€` three, `😀` four; `x` follows each in turn.
    assert_equal(_at("'é' x", 5), "line 1, column 5")
    assert_equal(_at("'€' x", 6), "line 1, column 5")
    assert_equal(_at("'😀' x", 7), "line 1, column 5")
    assert_equal(_at("é\n€x", 5), "line 2, column 2")


def test_position_of_end_of_text_and_clamping() raises:
    assert_equal(_at("ab", 2), "line 1, column 3")
    assert_equal(_at("ab\n", 3), "line 2, column 1")
    assert_equal(_at("ab", 99), "line 1, column 3")
    assert_equal(_at("ab", -4), "line 1, column 1")
    assert_equal(_at("", 0), "line 1, column 1")


def test_position_writes_line_and_column() raises:
    var p = SqlPosition(3, 14)
    assert_equal(p.line, 3)
    assert_equal(p.column, 14)
    assert_equal(String(p), "line 3, column 14")


def test_tokenize_starts_of_several_token_kinds() raises:
    var sql = String("SELECT a, 'x' -- c\n  >= 12 + 1.5")
    var starts = List[Int]()
    var tokens = tokenize(sql, starts)
    assert_equal(len(starts), len(tokens))
    assert_equal(Int(tokens[len(tokens) - 1].kind), Int(TK_EOF))
    var got = String("")
    for s in starts:
        got += String(s) + " "
    assert_equal(got, "0 7 8 10 21 24 27 29 32 ")
    assert_equal(starts[len(starts) - 1], sql.byte_length())


def test_tokenize_starts_of_empty_and_comment_only_text() raises:
    var starts = List[Int]()
    var tokens = tokenize("", starts)
    assert_equal(len(tokens), 1)
    assert_equal(starts[0], 0)
    var comment = List[Int]()
    _ = tokenize("  -- only\n", comment)
    assert_equal(len(comment), 1)
    assert_equal(comment[0], 10)


def test_tokenize_starts_keep_going_on_multi_byte_text() raises:
    var starts = List[Int]()
    var sql = String("'é' <> 1")
    _ = tokenize(sql, starts)
    assert_equal(len(starts), 4)
    assert_equal(starts[1], 5)
    assert_equal(starts[3], sql.byte_length())


def test_tokenize_starts_end_at_the_token_that_failed() raises:
    var starts = List[Int]()
    try:
        _ = tokenize("SELECT 'abc", starts)
    except e:
        assert_equal(String(e), "SQL syntax error: unterminated string literal")
    assert_equal(starts[len(starts) - 1], 7)
    var bad = List[Int]()
    try:
        _ = tokenize("SELECT a # b", bad)
    except e:
        assert_equal(String(e), "SQL syntax error: unexpected character '#'")
    assert_equal(bad[len(bad) - 1], 9)


def test_parse_sql_text_parser_error_mid_statement() raises:
    assert_equal(
        _stop("SELECT city, count(*) FROM weather GROUP city"),
        "SQL syntax error: expected keyword 'by' | line 1, column 42",
    )


def test_parse_sql_text_parser_error_on_line_two() raises:
    assert_equal(
        _stop("SELECT city\nFROM weather GROUP city"),
        "SQL syntax error: expected keyword 'by' | line 2, column 20",
    )


def test_parse_sql_text_parser_error_at_end_of_text() raises:
    var out = _stop("SELECT a FROM")
    assert_equal(out.split(" | ")[1], "line 1, column 14")
    var two = _stop("SELECT a FROM\n")
    assert_equal(two.split(" | ")[1], "line 2, column 1")


def test_parse_sql_text_misspelt_first_keyword() raises:
    assert_equal(
        _stop("selec 1"),
        "SQL syntax error: expected keyword 'select' | line 1, column 1",
    )


def test_parse_sql_text_tokenizer_errors() raises:
    assert_equal(
        _stop("SELECT 'abc"),
        "SQL syntax error: unterminated string literal | line 1, column 8",
    )
    assert_equal(
        _stop("SELECT 1,\n  2 # 3"),
        "SQL syntax error: unexpected character '#' | line 2, column 5",
    )
    assert_equal(
        _stop("SELECT 'é', x # 1"),
        "SQL syntax error: unexpected character '#' | line 1, column 15",
    )


def test_parse_sql_text_leaves_stopped_at_when_it_parses() raises:
    var at = SqlPosition(7, 9)
    var stmt = parse_sql_text("SELECT 1", at)
    assert_equal(at.line, 7)
    assert_equal(at.column, 9)
    assert_equal(Int(stmt.kind), Int(STMT_QUERY))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
