# =============================================================================
# test_rule_scan.mojo -- what each kind of rule finds in a text.
# =============================================================================
#
#   tokens      whitespace splits, a fixed set of brackets, quotes and sentence
#               marks is trimmed from the ends, and a run that trims away is
#               kept empty so positions hold.
#   word list   matches whole tokens ignoring ASCII case, keeps the text's own
#               spelling, and does not match inside a longer token.
#   verb prefix needs a listed verb and a next token that starts with a letter.
#   pattern     matches a trimmed token whole.
#   delimited   cuts between the delimiters on one line, skips an empty span,
#               refuses a span over the limit, pairs delimiters left to right,
#               and keeps multi-byte text whole.
#   email       accepts an address with a dotted domain and refuses the shapes
#               that only look like one.
#   url         accepts any scheme followed by `://` and something, trims the
#               sentence mark after it, and refuses the near misses.
#   refusals    a rule that could never match is refused when it is built.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_kg import RULE_MAX_SPAN_BYTES, Rule, scan_rule, tokens_of


def _names(rule: Rule, text: String) -> String:
    """The names a rule finds, joined with `|`, so a test states them in one line."""
    var found = scan_rule(rule, text)
    var out = String("")
    for i in range(len(found)):
        if i > 0:
            out += "|"
        out += found[i]
    return out^


def _words(a: String, b: String = "", c: String = "") -> List[String]:
    var w = List[String]()
    w.append(a)
    if len(b.as_bytes()) > 0:
        w.append(b)
    if len(c.as_bytes()) > 0:
        w.append(c)
    return w^


def test_tokens_are_trimmed_and_empty_runs_are_kept() raises:
    var t = tokens_of('  (alpha), [beta]; "gamma"!  ...  d.e\tf\ng ')
    assert_equal(len(t), 7)
    assert_equal(t[0], "alpha")
    assert_equal(t[1], "beta")
    assert_equal(t[2], "gamma")
    assert_equal(t[3], "")
    assert_equal(t[4], "d.e")
    assert_equal(t[5], "f")
    assert_equal(t[6], "g")
    assert_equal(len(tokens_of("")), 0)
    assert_equal(len(tokens_of(" \n\t ")), 0)


def test_a_word_list_matches_whole_tokens_ignoring_case() raises:
    var r = Rule.word_list("flag", _words("Alpha", "beta"))
    assert_equal(_names(r, "alpha, BETA and Alphabet; beta!"), "alpha|BETA|beta")
    assert_equal(_names(r, "no match here"), "")
    assert_equal(_names(r, ""), "")


def test_a_verb_prefix_needs_a_word_that_starts_with_a_letter() raises:
    var r = Rule.verb_prefix("action", _words("open", "Close"))
    assert_equal(_names(r, "please open door then CLOSE window."), "open door|CLOSE window")
    assert_equal(_names(r, "open 42 and open"), "")
    assert_equal(_names(r, "open ( x"), "")
    assert_equal(_names(r, "reopen door"), "")


def test_a_token_pattern_matches_the_trimmed_token_whole() raises:
    var r = Rule.token_pattern("ref", "[A-Z]+-\\d+")
    assert_equal(_names(r, "see (AB-12), CD-7. and xAB-12 and AB-12x"), "AB-12|CD-7")


def test_a_delimited_rule_cuts_between_the_delimiters() raises:
    var r = Rule.delimited("span", "<<", ">>")
    assert_equal(_names(r, "a <<one>> b <<two words>> c"), "one|two words")
    assert_equal(_names(r, "a <<unclosed and <<one>>"), "unclosed and <<one")
    assert_equal(_names(r, "<<>> <<x>>"), "x")
    assert_equal(_names(r, "<<broken\nline>> <<ok>>"), "ok")
    assert_equal(_names(r, "no delimiters"), "")


def test_quoted_pairs_quotes_left_to_right() raises:
    var r = Rule.quoted("quote")
    assert_equal(_names(r, 'say "hello there" and "bye" now'), "hello there|bye")
    assert_equal(_names(r, '"" foo "bar"'), "bar")


def test_a_delimited_span_is_bounded() raises:
    var r = Rule.delimited("span", "[[", "]]")
    var fits = String("")
    for _ in range(RULE_MAX_SPAN_BYTES):
        fits += "x"
    assert_equal(_names(r, "[[" + fits + "]]"), fits)
    assert_equal(_names(r, "[[" + fits + "x]]"), "")


def test_delimited_text_keeps_multibyte_characters_whole() raises:
    var r = Rule.delimited("span", "«", "»")
    assert_equal(_names(r, "voir «naïve café» ici et «日本»"), "naïve café|日本")


def test_an_email_rule_accepts_addresses_and_refuses_lookalikes() raises:
    var r = Rule.email("addr")
    assert_equal(
        _names(r, "write to ann.lee+tag@host.example.org, or bo_b@x-y.example."),
        "ann.lee+tag@host.example.org|bo_b@x-y.example",
    )
    assert_equal(_names(r, "a@b"), "")
    assert_equal(_names(r, "a@b."), "")
    assert_equal(_names(r, "a@.b"), "")
    assert_equal(_names(r, "a@b..c"), "")
    assert_equal(_names(r, "@b.c"), "")
    assert_equal(_names(r, "a@-b.c"), "")
    assert_equal(_names(r, "write me at ..a@b.example"), "a@b.example")
    assert_equal(_names(r, "x@y.example."), "x@y.example")


def test_a_url_rule_wants_a_scheme_and_something_after_it() raises:
    var r = Rule.url("link")
    assert_equal(
        _names(r, "go to https://host.example/p?q=1, or ftp://localhost/x. and (git+ssh://a)"),
        "https://host.example/p?q=1|ftp://localhost/x|git+ssh://a",
    )
    assert_equal(_names(r, "http:// ://x mailto:a 1http://localhost"), "")


def test_rules_that_can_never_match_are_refused() raises:
    with assert_raises(contains="word list is empty"):
        _ = Rule.word_list("t", List[String]())
    with assert_raises(contains="word list is empty"):
        _ = Rule.verb_prefix("t", List[String]())
    with assert_raises(contains="holds whitespace"):
        _ = Rule.word_list("t", _words("two words"))
    var with_empty = List[String]()
    with_empty.append("ok")
    with_empty.append("")
    with assert_raises(contains="word 1 is empty"):
        _ = Rule.word_list("t", with_empty)
    with assert_raises(contains="delimiter is empty"):
        _ = Rule.delimited("t", "", ">")
    with assert_raises(contains="delimiter is empty"):
        _ = Rule.delimited("t", "<", "")
    with assert_raises(contains="newline"):
        _ = Rule.delimited("t", "<\n", ">")
    with assert_raises(contains="unterminated class"):
        _ = Rule.token_pattern("t", "[ab")
    with assert_raises(contains="ends with a byte a token loses"):
        _ = Rule.word_list("t", _words("foo."))
    with assert_raises(contains="starts with a byte a token loses"):
        _ = Rule.word_list("t", _words("ok", "(foo"))
    with assert_raises(contains="ends with a byte a token loses"):
        _ = Rule.verb_prefix("t", _words("open,"))
    with assert_raises(contains="starts with a byte a token loses"):
        _ = Rule.verb_prefix("t", _words("'open"))
    with assert_raises(contains="holds whitespace"):
        _ = Rule.verb_prefix("t", _words("two words"))
    with assert_raises(contains="can only match whitespace"):
        _ = Rule.token_pattern("t", "a b")
    with assert_raises(contains="trimmed from the end"):
        _ = Rule.token_pattern("t", "[a-z]+\\.")


def test_a_word_with_trimmed_punctuation_inside_still_matches() raises:
    # Only the ends are trimmed, so a word may start with a closing mark and end
    # with an opening one, and may hold any of them inside.
    var r = Rule.word_list("w", _words(".x", "y(", "a.b"))
    assert_equal(_names(r, "see .x and y( or a.b."), ".x|y(|a.b")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
