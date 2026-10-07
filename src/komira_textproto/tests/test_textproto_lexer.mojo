# =============================================================================
# src/komira_textproto/tests/test_textproto_lexer.mojo
#   Each token kind, each escape, comments, line tracking, the cursor, and
#   each refusal asserted by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

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
)


def _assert_contains(haystack: String, needle: String) raises:
    if needle not in haystack:
        raise Error(
            String("expected '") + needle + String("' in: ") + haystack
        )


def _texts(text: String) raises -> List[String]:
    var typed = lex(text)
    var out = List[String]()
    for i in range(len(typed)):
        out.append(typed[i].text.copy())
    return out^


def _refusal(text: String) -> String:
    try:
        _ = lex(text)
    except e:
        return String(e)
    return String("<no refusal>")


def test_structural_tokens_and_barewords() raises:
    var t = lex(String("item { name: beta }"))
    assert_equal(len(t), 6)
    assert_equal(t[0].kind, TOKEN_WORD)
    assert_equal(t[0].text, String("item"))
    assert_equal(t[1].kind, TOKEN_LBRACE)
    assert_equal(t[2].kind, TOKEN_WORD)
    assert_equal(t[2].text, String("name"))
    assert_equal(t[3].kind, TOKEN_COLON)
    assert_equal(t[4].kind, TOKEN_WORD)
    assert_equal(t[4].text, String("beta"))
    assert_equal(t[5].kind, TOKEN_RBRACE)


def test_structure_needs_no_whitespace() raises:
    var t = _texts(String("a{b:c}d"))
    assert_equal(len(t), 7)
    assert_equal(t[0], String("a"))
    assert_equal(t[1], String("{"))
    assert_equal(t[3], String(":"))
    assert_equal(t[5], String("}"))
    assert_equal(t[6], String("d"))


def test_a_quoted_string_is_one_token_and_keeps_structure() raises:
    var t = lex(String("location: \"registry.example.invalid/a:b {x}\""))
    assert_equal(len(t), 3)
    assert_equal(t[2].kind, TOKEN_STRING)
    assert_equal(t[2].text, String("registry.example.invalid/a:b {x}"))


def test_single_quoted_and_empty_strings() raises:
    var t = lex(String("a: 'it\"s' b: \"\""))
    assert_equal(t[2].kind, TOKEN_STRING)
    assert_equal(t[2].text, String("it\"s"))
    assert_equal(t[5].kind, TOKEN_STRING)
    assert_equal(t[5].text, String(""))


def test_escapes_are_decoded() raises:
    var t = lex(String("s: \"q\\\"b\\\\s\\'n\\nt\\tr\\r.\""))
    assert_equal(t[2].text, String("q\"b\\s'n\nt\tr\r."))


def test_comments_are_dropped() raises:
    var src = String("# leading\nname: x # trailing { : }\n# last")
    var t = _texts(src)
    assert_equal(len(t), 3)
    assert_equal(t[2], String("x"))


def test_a_hash_inside_a_string_is_not_a_comment() raises:
    var t = lex(String("s: \"a#b\""))
    assert_equal(t[2].text, String("a#b"))


def test_numbers_are_classified() raises:
    var t = lex(String("42 -7 +3 0.5 .25 -.5 1e3 - word2 x1 ..5 .-.5 -x"))
    assert_equal(len(t), 13)
    for i in range(7):
        assert_equal(t[i].kind, TOKEN_NUMBER, String("index ") + String(i))
    assert_equal(t[1].text, String("-7"))
    assert_equal(t[6].text, String("1e3"))
    for i in range(7, 13):
        assert_equal(t[i].kind, TOKEN_WORD, String("index ") + String(i))
    assert_equal(t[10].text, String("..5"))


def test_lines_are_tracked() raises:
    var t = lex(String("a\n\n  b: \"x\"\n# c\n}"))
    assert_equal(t[0].line, 1)
    assert_equal(t[1].line, 3)
    assert_equal(t[3].line, 3)
    assert_equal(t[4].line, 5)


def test_empty_and_comment_only_input_lex_to_nothing() raises:
    assert_equal(len(lex(String(""))), 0)
    assert_equal(len(lex(String("  # only a comment\n\t\r\n"))), 0)


def test_unterminated_string_is_refused() raises:
    _assert_contains(
        _refusal(String("a: 1\nb: \"open")),
        String("textproto: line 2: unterminated string"),
    )


def test_a_string_may_not_span_a_line() raises:
    _assert_contains(
        _refusal(String("b: \"open\nclose\"")),
        String("textproto: line 1: unterminated string"),
    )


def test_a_trailing_backslash_is_unterminated() raises:
    _assert_contains(
        _refusal(String("b: \"x\\")), String("unterminated string")
    )


def test_unknown_escape_is_refused() raises:
    _assert_contains(
        _refusal(String("b: \"x\\q\"")),
        String("textproto: line 1: unknown escape '\\q' in a string"),
    )


def test_a_non_ascii_unknown_escape_is_refused_not_split() raises:
    # The escaped characters are two and three bytes in UTF-8; each refusal
    # names the whole character rather than splitting it.
    _assert_contains(
        _refusal(String("b: \"x\\é\"")),
        String("textproto: line 1: unknown escape '\\é' in a string"),
    )
    _assert_contains(
        _refusal(String("b: \"\\€\"")),
        String("unknown escape '\\€'"),
    )


def test_a_source_label_prefixes_every_refusal() raises:
    var msg = String("")
    try:
        _ = lex(String("a: \"open"), String("widgets file"))
    except e:
        msg = String(e)
    _assert_contains(msg, String("widgets file: line 1: unterminated string"))
    var c = TokenCursor(lex(String("a")), String("widgets file"))
    _ = c.next(String("a field name"))
    var msg2 = String("")
    try:
        _ = c.expect(TOKEN_COLON)
    except e:
        msg2 = String(e)
    _assert_contains(
        msg2, String("widgets file: line 1: expected ':' but reached the end")
    )


def test_unsupported_characters_are_refused() raises:
    _assert_contains(
        _refusal(String("a: [1, 2]")),
        String("textproto: line 1: unsupported character '['"),
    )
    _assert_contains(
        _refusal(String("a: 1;")), String("unsupported character ';'")
    )
    _assert_contains(
        _refusal(String("a <\n>")), String("unsupported character '<'")
    )


def test_cursor_reads_and_refuses() raises:
    var c = TokenCursor(lex(String("name: \"x\"\n{")))
    assert_true(c.is_kind(TOKEN_WORD))
    assert_equal(c.expect(TOKEN_WORD).text, String("name"))
    _ = c.expect(TOKEN_COLON)
    var s = c.next(String("a value"))
    assert_equal(s.kind, TOKEN_STRING)
    assert_false(c.at_end())
    var msg = String("")
    try:
        _ = c.expect(TOKEN_RBRACE)
    except e:
        msg = String(e)
    _assert_contains(msg, String("textproto: line 2: expected '}' but got '{'"))
    assert_true(c.at_end())
    var msg2 = String("")
    try:
        _ = c.next(String("a field name"))
    except e:
        msg2 = String(e)
    _assert_contains(
        msg2,
        String("line 2: expected a field name but reached the end of input"),
    )


def test_is_kind_is_false_for_every_other_kind_and_at_end() raises:
    # is_kind must answer for the kind asked, not just "a token exists":
    # each position is True for its own kind and False for the other five,
    # and False for every kind once the input is used up.
    var kinds = List[Int]()
    kinds.append(TOKEN_WORD)
    kinds.append(TOKEN_LBRACE)
    kinds.append(TOKEN_RBRACE)
    kinds.append(TOKEN_COLON)
    kinds.append(TOKEN_STRING)
    kinds.append(TOKEN_NUMBER)
    var c = TokenCursor(lex(String("name { k: \"v\" 7 }")))
    var expected = List[Int]()
    expected.append(TOKEN_WORD)
    expected.append(TOKEN_LBRACE)
    expected.append(TOKEN_WORD)
    expected.append(TOKEN_COLON)
    expected.append(TOKEN_STRING)
    expected.append(TOKEN_NUMBER)
    expected.append(TOKEN_RBRACE)
    for i in range(len(expected)):
        for j in range(len(kinds)):
            var want = kinds[j] == expected[i]
            assert_equal(
                c.is_kind(kinds[j]),
                want,
                String("token ") + String(i) + String(" kind ") + String(j),
            )
        _ = c.next(String("a token"))
    assert_true(c.at_end())
    for j in range(len(kinds)):
        assert_false(c.is_kind(kinds[j]), String("at end, kind ") + String(j))


def _parse_fields(mut c: TokenCursor, depth: Int) raises -> String:
    # A hand-written reader of the shape the cursor is for: it branches on
    # is_kind to stop at a closing brace and to tell a nested message from a
    # scalar value. It renders what it read as `name=value` / `name{...}`.
    var out = String("")
    while not c.at_end() and not c.is_kind(TOKEN_RBRACE):
        var name = c.expect(TOKEN_WORD).text.copy()
        if c.is_kind(TOKEN_LBRACE):
            _ = c.expect(TOKEN_LBRACE)
            out += name + String("{") + _parse_fields(c, depth + 1)
            _ = c.expect(TOKEN_RBRACE)
            out += String("}")
        else:
            _ = c.expect(TOKEN_COLON)
            var v = c.next(String("a value"))
            out += name + String("=") + v.text
        out += String(";")
    if depth == 0 and not c.at_end():
        raise Error(String("trailing tokens"))
    return out^


def test_a_parser_branching_on_is_kind_reads_nested_messages() raises:
    var c = TokenCursor(
        lex(String("a: 1\nm { b: \"x\" n { } }\nc: word"))
    )
    assert_equal(_parse_fields(c, 0), String("a=1;m{b=x;n{};};c=word;"))
    assert_true(c.at_end())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
