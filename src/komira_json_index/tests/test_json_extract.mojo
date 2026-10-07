# =============================================================================
# Tests for komira_json_index/json_extract_kernel.mojo — the json_extract walker.
# =============================================================================
#
# Covers the stage-2-skip walker driving
# EXPR_JSON_EXTRACT (tag 19) and the `->` / `->>` operators.
#
# Coverage (inline fixtures, no Parquet/fs dependency):
#   T1  Basic depth-1 path extract (`$.name`).
#   T2  Depth-2 path extract (`$.user.id`).
#   T3  Missing key → null row.
#   T4  Numeric leaf via `->` semantics — returns raw scalar bytes.
#   T5  Deeply-nested path (`$.a.b.c.d`).
#   T6  Whole-document extract — empty path returns the payload verbatim.
#   T7  Mixed-row schema: some rows have key, some don't (mix of hit + null).
#   T8  parse_json_path: well-formed cases.
#   T9  parse_json_path: malformed cases raise.
#   T10 Malformed JSON payload → null row (LENIENT semantics).
#   T11 `->` returns raw JSON text including quotes for strings.
#   T12 `->>` returns unquoted strings.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import (
    Expr,
    EXPR_JSON_EXTRACT,
    parse_json_path,
)

from komira_json_index.json_extract_kernel import extract_column
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Helpers
# =============================================================================


def _string_column(values: List[String]) raises -> Column[HeapRegion]:
    """Build a STRING Column[HeapRegion] from a List[String]."""
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _make_payloads(*lines: String) -> List[String]:
    """Pack a variadic into List[String] for the input column."""
    var out = List[String]()
    for s in lines:
        out.append(s.copy())
    return out^


# =============================================================================
# parse_json_path direct tests
# =============================================================================


def test_parse_json_path_root_only() raises:
    var segs = parse_json_path(String("$"))
    assert_equal(len(segs), 0)


def test_parse_json_path_empty_string() raises:
    # Empty string == "$", returns no segments.
    var segs = parse_json_path(String(""))
    assert_equal(len(segs), 0)


def test_parse_json_path_depth1() raises:
    var segs = parse_json_path(String("$.name"))
    assert_equal(len(segs), 1)
    assert_equal(segs[0], String("name"))


def test_parse_json_path_depth4() raises:
    var segs = parse_json_path(String("$.a.b.c.d"))
    assert_equal(len(segs), 4)
    assert_equal(segs[0], String("a"))
    assert_equal(segs[1], String("b"))
    assert_equal(segs[2], String("c"))
    assert_equal(segs[3], String("d"))


def test_parse_json_path_missing_dollar_raises() raises:
    with assert_raises():
        _ = parse_json_path(String("foo"))


def test_parse_json_path_empty_segment_raises() raises:
    with assert_raises():
        _ = parse_json_path(String("$..foo"))


def test_parse_json_path_bracket_raises() raises:
    with assert_raises():
        _ = parse_json_path(String("$.items[0]"))


def test_parse_json_path_QUOTED_segment_keeps_its_dots() raises:
    """A quoted segment is ONE key, dots included — DuckDB v1.5.3 grammar.

    A parser that splits on `.` with NO quote handling returns `$."a.b"` as
    the TWO segments `<QT>a` and `b<QT>`, and the kernel matches neither.
    Nothing raises: the caller gets a plausible SQL NULL where DuckDB
    answers the value. Writing
    `<QT>` for one double quote and `<BS>` for one backslash below, since a
    Mojo docstring unescapes its own source.

    MEASURED v1.5.3 (2026-09-15):
      json_extract('{"a.b":5}',      '$."a.b"')    = 5
      json_extract('{"a":1}',        '$."a"')      = 1
      json_extract('{"a":{"b.c":2}}','$.a."b.c"')  = 2
      json_extract('{"a b":3}',      '$."a b"')    = 3
      json_extract('{"a[0]":7}',     '$."a[0]"')   = 7   brackets are LITERAL
                                                         inside quotes
      json_extract('{"a*":8}',       '$."a*"')     = 8   and so are wildcards
    """
    var one = parse_json_path(String('$."a.b"'))
    assert_equal(len(one), 1)
    assert_equal(one[0], String("a.b"))

    var plain = parse_json_path(String('$."a"'))
    assert_equal(len(plain), 1)
    assert_equal(plain[0], String("a"))

    var mixed = parse_json_path(String('$.a."b.c"'))
    assert_equal(len(mixed), 2)
    assert_equal(mixed[0], String("a"))
    assert_equal(mixed[1], String("b.c"))

    var spaced = parse_json_path(String('$."a b"'))
    assert_equal(len(spaced), 1)
    assert_equal(spaced[0], String("a b"))

    # ⚠ Bracket and wildcard bytes are REJECTED in an unquoted segment and
    # LITERAL in a quoted one. Both halves are measured above; an
    # implementation that ran the unquoted rejection inside quotes would
    # raise on two paths DuckDB answers.
    var brk = parse_json_path(String('$."a[0]"'))
    assert_equal(len(brk), 1)
    assert_equal(brk[0], String("a[0]"))

    var star = parse_json_path(String('$."a*"'))
    assert_equal(len(star), 1)
    assert_equal(star[0], String("a*"))


def test_parse_json_path_UNQUOTED_segment_still_splits_on_dots() raises:
    """The other half: opening the quoted form must not change the bare one.

    MEASURED v1.5.3: `json_extract('{"a.b":5}', '$.a.b')` = NULL — the
    unquoted form DESCENDS. A fix that stopped splitting would pass every
    cell of the test above and be wrong about every nested path.

    Also measured: a `"` that is NOT the first byte of a segment is a
    LITERAL byte of the key — `json_extract('{"a\"b":4}', '$.a"b')` = 4 —
    so quoted mode keys off the FIRST byte only.
    """
    var two = parse_json_path(String("$.a.b"))
    assert_equal(len(two), 2)
    assert_equal(two[0], String("a"))
    assert_equal(two[1], String("b"))

    var midq = parse_json_path(String('$.a"b'))
    assert_equal(len(midq), 1)
    assert_equal(midq[0], String('a"b'))


def test_parse_json_path_QUOTED_escapes_are_ONLY_backslash_and_quote() raises:
    """Inside quotes, the only two escapes are a doubled backslash and an
    escaped quote.

    MEASURED v1.5.3 (2026-09-15) against a document whose keys are `a<QT>b`
    and `a<BS>tb`:
      $.<QT>a<BS><QT>b<QT>   -> the key `a<QT>b`
      $.<QT>a<BS><BS>tb<QT>  -> the key `a<BS>tb`
      $.<QT>a<BS>tb<QT>      -> ALSO the key `a<BS>tb`, because `<BS>t` is
                                NEITHER a tab NOR a bare `t`

    ⇒ the third line is the discriminating one and it is a POSITIVE claim. A
    JSON-style unescaper would make it the key `a<TAB>b`; a
    drop-the-backslash rule would make it `atb`. DuckDB answers the same
    value for lines two and three, which only this rule reproduces.
    """
    var q = parse_json_path(String('$."a\\"b"'))
    assert_equal(len(q), 1)
    assert_equal(q[0], String('a"b'))

    var bs = parse_json_path(String('$."a\\\\tb"'))
    assert_equal(len(bs), 1)
    assert_equal(bs[0], String("a\\tb"))

    var lone = parse_json_path(String('$."a\\tb"'))
    assert_equal(len(lone), 1)
    assert_equal(lone[0], String("a\\tb"))

    # ⚠ UNQUOTED segments do NO unescaping at all — measured:
    # `json_extract('{"a\\tb":1}', '$.a\\tb')` = NULL, where the quoted
    # spelling on the same document = 1.
    var raw = parse_json_path(String("$.a\\\\tb"))
    assert_equal(len(raw), 1)
    assert_equal(raw[0], String("a\\\\tb"))


def test_parse_json_path_EMPTY_or_UNTERMINATED_quote_raises() raises:
    """Both are a Binder Error on DuckDB v1.5.3, so both raise here.

    ⛔ NEITHER MAY BECOME A SEGMENT. A path this grammar cannot express has
    to reach the caller as a raise at plan time; parsing it into nonsense
    and answering NULL is the defect these tests were written for.

      json_extract('{"a":1}', '$.""')   -> Binder Error: JSON path error
      json_extract('{"a":1}', '$."a')   -> Binder Error: JSON path error
      json_extract('{"a":1}', '$."a"x') -> Binder Error: JSON path error
    """
    with assert_raises():
        _ = parse_json_path(String('$.""'))
    with assert_raises():
        _ = parse_json_path(String('$."a'))
    with assert_raises():
        _ = parse_json_path(String('$."a"x'))


def test_parse_json_path_wildcard_raises() raises:
    with assert_raises():
        _ = parse_json_path(String("$.*"))


# =============================================================================
# extract_column tests
# =============================================================================


def test_extract_basic_depth1() raises:
    # T1: $.name over [{"name":"alice"},{"name":"bob"}]
    var col = _string_column(_make_payloads(
        String("{\"name\":\"alice\"}"),
        String("{\"name\":\"bob\"}"),
    ))
    var path = parse_json_path(String("$.name"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    assert_equal(out.length(), 2)
    var out_sa = out.as_string()
    # ->> unquotes, so we get "alice" / "bob" directly.
    assert_equal(out_sa.get(0), String("alice"))
    assert_equal(out_sa.get(1), String("bob"))


def test_extract_depth2() raises:
    # T2: $.user.id over [{"user":{"id":"1"}},{"user":{"id":"2"}}]
    var col = _string_column(_make_payloads(
        String("{\"user\":{\"id\":\"1\"}}"),
        String("{\"user\":{\"id\":\"2\"}}"),
    ))
    var path = parse_json_path(String("$.user.id"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    assert_equal(out.length(), 2)
    var out_sa = out.as_string()
    assert_equal(out_sa.get(0), String("1"))
    assert_equal(out_sa.get(1), String("2"))


def test_extract_missing_key_becomes_null() raises:
    # T3: $.missing on [{"a":1},{"missing":"found"}]
    var col = _string_column(_make_payloads(
        String("{\"a\":1}"),
        String("{\"missing\":\"found\"}"),
    ))
    var path = parse_json_path(String("$.missing"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    assert_equal(out.length(), 2)
    # Row 0: missing -> null.
    assert_true(out._validity)
    assert_false(out._validity.value().test(0))
    # Row 1: present -> "found".
    assert_true(out._validity.value().test(1))
    var out_sa = out.as_string()
    assert_equal(out_sa.get(1), String("found"))


def test_extract_numeric_leaf_unquoted_via_arrow() raises:
    # T4: $.x on {"x":42} via -> semantics (preserve_extension_metadata=True).
    # Scalars don't have quotes to strip, so both modes return "42".
    var col = _string_column(_make_payloads(
        String("{\"x\":42}"),
    ))
    var path = parse_json_path(String("$.x"))
    var out = extract_column(col, path^, ArrowType.STRING, True)
    var out_sa = out.as_string()
    assert_equal(out_sa.get(0), String("42"))


def test_extract_deeply_nested_path() raises:
    # T5: $.a.b.c.d over [{"a":{"b":{"c":{"d":"deep"}}}}]
    var col = _string_column(_make_payloads(
        String("{\"a\":{\"b\":{\"c\":{\"d\":\"deep\"}}}}"),
    ))
    var path = parse_json_path(String("$.a.b.c.d"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    var out_sa = out.as_string()
    assert_equal(out_sa.get(0), String("deep"))


def test_extract_whole_document() raises:
    # T6: empty path returns the payload verbatim.
    var col = _string_column(_make_payloads(
        String("{\"a\":1,\"b\":\"x\"}"),
    ))
    var empty_path = List[String]()
    var out = extract_column(col, empty_path^, ArrowType.STRING, False)
    var out_sa = out.as_string()
    assert_equal(out_sa.get(0), String("{\"a\":1,\"b\":\"x\"}"))


def test_extract_mixed_hit_and_null() raises:
    # T7: $.name over [present, absent, present]
    var col = _string_column(_make_payloads(
        String("{\"name\":\"alice\"}"),
        String("{\"other\":\"x\"}"),
        String("{\"name\":\"carol\"}"),
    ))
    var path = parse_json_path(String("$.name"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    assert_equal(out.length(), 3)
    assert_true(out._validity)
    ref v = out._validity.value()
    assert_true(v.test(0))
    assert_false(v.test(1))
    assert_true(v.test(2))
    var out_sa = out.as_string()
    assert_equal(out_sa.get(0), String("alice"))
    assert_equal(out_sa.get(2), String("carol"))


def test_extract_matches_a_key_that_CARRIES_AN_ESCAPE() raises:
    """⛔ A SECOND SILENT WRONG ANSWER, IN THE KERNEL RATHER THAN THE PARSER.

    A walker that compares the RAW key bytes off the tape to the path
    segment is wrong. A JSON key stores its escapes exactly as written — the
    document key below occupies the FOUR bytes `a`, backslash, quote, `b` —
    while a path segment is already decoded (`a` quote `b`, three bytes). So
    NO key containing an escape could ever match, and the miss would be
    reported the same way an absent key is: SQL NULL, no raise, no
    diagnostic.

    MEASURED DuckDB v1.5.3 (2026-09-15) — it matches on the DECODED key:
      json_extract('{"a\"b":4}',  '$.a"b')     = 4
      json_extract('{"a\\tb":1}', '$."a\\tb"') = 1

    ⚠ THE SECOND DOCUMENT IS THE ONE THAT PINS THE RULE. Its key is a
    BACKSLASH followed by `t`, not a tab, so a comparator that decoded the
    key but not consistently — or that compared encoded-to-encoded — answers
    differently on it than on the first.
    """
    # {"a\"b":4}  — key = a, quote, b
    var c1 = _string_column(_make_payloads(
        String("{\"a\\\"b\":4}"),
        String("{\"zz\":0}"),
    ))
    var p1 = parse_json_path(String('$."a\\"b"'))
    var o1 = extract_column(c1, p1^, ArrowType.STRING, False)
    assert_equal(o1.length(), 2)
    assert_equal(o1.as_string().get(0), String("4"))
    assert_true(o1.as_string().is_null(1), "row 2 has no such key")

    # {"a\\tb":1} — key = a, backslash, t, b
    var c2 = _string_column(_make_payloads(
        String("{\"a\\\\tb\":1}"),
        String("{\"zz\":0}"),
    ))
    var p2 = parse_json_path(String('$."a\\\\tb"'))
    var o2 = extract_column(c2, p2^, ArrowType.STRING, False)
    assert_equal(o2.length(), 2)
    assert_equal(o2.as_string().get(0), String("1"))

    # ⚠ THE CONTROL, WITHOUT WHICH THE TWO ABOVE ARE NOT EVIDENCE: a key with
    # NO escape must still match on the untouched fast path, and a key whose
    # DECODED form differs from the segment must still MISS. An "always
    # decode and hope" comparator passes the two cells above and fails here.
    var c3 = _string_column(_make_payloads(
        String("{\"a\\\"b\":4}"),
        String("{\"plain\":9}"),
    ))
    var p3 = parse_json_path(String("$.plain"))
    var o3 = extract_column(c3, p3^, ArrowType.STRING, False)
    assert_true(
        o3.as_string().is_null(0),
        "the escaped key `a\"b` must NOT match the segment `plain`",
    )
    assert_equal(o3.as_string().get(1), String("9"), "unescaped key still hits")


def test_extract_malformed_json_row_null() raises:
    # T10: unterminated string in payload -> row becomes null (LENIENT).
    var col = _string_column(_make_payloads(
        String("{\"name\":\"unterminated"),  # missing closing quote + brace
        String("{\"name\":\"ok\"}"),
    ))
    var path = parse_json_path(String("$.name"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    assert_equal(out.length(), 2)
    # Row 0: malformed -> null.
    assert_true(out._validity)
    assert_false(out._validity.value().test(0))
    # Row 1: ok -> "ok".
    assert_true(out._validity.value().test(1))
    var out_sa = out.as_string()
    assert_equal(out_sa.get(1), String("ok"))


def test_extract_descend_through_scalar_returns_null() raises:
    # Path descends past a scalar value -> NULL (DuckDB semantics).
    # $.user.id over [{"user":42}] — user is a number, not an object,
    # so we can't descend into it.
    var col = _string_column(_make_payloads(
        String("{\"user\":42}"),
    ))
    var path = parse_json_path(String("$.user.id"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    assert_equal(out.length(), 1)
    assert_true(out._validity)
    assert_false(out._validity.value().test(0))


# =============================================================================
# Expr factory smoke test
# =============================================================================


def test_expr_json_extract_json_factory_smoke() raises:
    # Build EXPR_JSON_EXTRACT via the public factory; verify accessors.
    var parent = Expr.col_ref(String("payload"))
    var e = Expr.json_extract_json(parent^, String("$.name"))
    assert_equal(Int(e.tag), Int(EXPR_JSON_EXTRACT))
    assert_true(e.is_json_extract())
    var segs = e.json_extract_path_segments()
    assert_equal(len(segs), 1)
    assert_equal(segs[0], String("name"))
    assert_true(e.json_extract_preserve_extension_metadata())  # `->` mode


def test_expr_json_extract_string_factory_smoke() raises:
    var parent = Expr.col_ref(String("payload"))
    var e = Expr.json_extract_string(parent^, String("$.user.id"))
    assert_equal(Int(e.tag), Int(EXPR_JSON_EXTRACT))
    var segs = e.json_extract_path_segments()
    assert_equal(len(segs), 2)
    assert_equal(segs[0], String("user"))
    assert_equal(segs[1], String("id"))
    assert_false(e.json_extract_preserve_extension_metadata())  # `->>` mode


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("test_json_extract — json_extract suite")

    # parse_json_path direct
    test_parse_json_path_root_only()
    test_parse_json_path_empty_string()
    test_parse_json_path_depth1()
    test_parse_json_path_depth4()
    test_parse_json_path_missing_dollar_raises()
    test_parse_json_path_empty_segment_raises()
    test_parse_json_path_bracket_raises()
    test_parse_json_path_wildcard_raises()
    test_parse_json_path_QUOTED_segment_keeps_its_dots()
    test_parse_json_path_UNQUOTED_segment_still_splits_on_dots()
    test_parse_json_path_QUOTED_escapes_are_ONLY_backslash_and_quote()
    test_parse_json_path_EMPTY_or_UNTERMINATED_quote_raises()

    # extract_column kernel
    test_extract_basic_depth1()
    test_extract_depth2()
    test_extract_missing_key_becomes_null()
    test_extract_numeric_leaf_unquoted_via_arrow()
    test_extract_deeply_nested_path()
    test_extract_whole_document()
    test_extract_mixed_hit_and_null()
    test_extract_matches_a_key_that_CARRIES_AN_ESCAPE()
    test_extract_malformed_json_row_null()
    test_extract_descend_through_scalar_returns_null()

    # Expr factory smoke
    test_expr_json_extract_json_factory_smoke()
    test_expr_json_extract_string_factory_smoke()

    print("test_json_extract — all tests PASSED")
