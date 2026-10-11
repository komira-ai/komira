# =============================================================================
# Tests for komira_json_index/json_extract_kernel.mojo — the walker's edges.
# =============================================================================
#
# test_json_extract.mojo covers the happy paths. This file holds the arms the
# walker reaches only on a refused input, a null parent row, a document that
# is not an object, a value it must skip or slice through nesting, and the
# guards of its private helpers, driven over hand-built tapes because no
# well-formed Stage 1 output reaches them.
#
# Every expectation is the answer DuckDB's json_extract / ->> gives on the
# same document (a malformed document is nulled: this kernel is LENIENT).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_json_index.json_extract_kernel import (
    extract_column,
    _extract_one_row,
    _extract_value_at,
    _find_close_for,
    _skip_value_at,
    _slice_to_string,
)
from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_COLON,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from komira_json_index.structural_index import StructuralIndex


comptime NULL = "<NULL>"


# =============================================================================
# Helpers
# =============================================================================


def _segs(path: String) -> List[String]:
    """`a.b.c` as the segments `a`, `b`, `c`; the empty string as none."""
    var out = List[String]()
    if path.byte_length() == 0:
        return out^
    for part in path.split("."):
        out.append(String(part))
    return out^


def _cell(col: Column[HeapRegion], row: Int) raises -> String:
    """Row `row` of a STRING column, or `<NULL>` when its validity bit is clear."""
    if col.is_null_at(row):
        return String(NULL)
    return col.as_string().get(row)


def _one(payload: String, path: String, arrow: Bool) raises -> String:
    """`payload -> path` (arrow) or `payload ->> path` on a one-row column."""
    var values = List[String]()
    values.append(payload)
    var col = Column.from_string(StringArray.from_strings(values))
    var out = extract_column(col, _segs(path), ArrowType.STRING, arrow)
    assert_equal(out.length(), 1)
    return _cell(out, 0)


def _both(payload: String, path: String, want: String) raises:
    """`->` and `->>` both answer `want` (true of non-string values)."""
    assert_equal(_one(payload, path, True), want, payload + " -> " + path)
    assert_equal(_one(payload, path, False), want, payload + " ->> " + path)


def _raised(f: def() raises thin -> None) -> String:
    try:
        f()
    except e:
        return String(e)
    return String("<no raise>")


def _int64_column() -> Column[HeapRegion]:
    var vals = List[Int64]()
    vals.append(Int64(1))
    return Column.from_primitive(PrimitiveArray[DType.int64].from_list(vals^))


def _tape(offsets: List[Int], tags: List[UInt8]) -> StructuralIndex:
    var o = List[UInt32]()
    for i in range(len(offsets)):
        o.append(UInt32(offsets[i]))
    return StructuralIndex(o^, tags.copy())


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


# =============================================================================
# Refused inputs (extract_column's two type checks, and their order)
# =============================================================================


def _non_string_parent() raises:
    var p = _int64_column()
    _ = extract_column(p, _segs("a"), ArrowType.STRING, True)


def _non_string_output() raises:
    var values = List[String]()
    values.append(String("{}"))
    var p = Column.from_string(StringArray.from_strings(values))
    _ = extract_column(p, _segs("a"), ArrowType.INT64, True)


def _both_wrong() raises:
    var p = _int64_column()
    _ = extract_column(p, _segs("a"), ArrowType.INT64, False)


def test_refuses_a_non_string_parent() raises:
    assert_equal(
        _raised(_non_string_parent),
        "extract_column: parent must be Arrow STRING column, got type_id=5",
    )


def test_refuses_a_non_string_output() raises:
    assert_equal(
        _raised(_non_string_output),
        "extract_column: only STRING output is supported (typed"
        " json_extract[T] is not); got output_type_id=5",
    )


def test_parent_type_is_reported_before_output_type() raises:
    """Both wrong: the parent's refusal, checked first, is the one raised."""
    assert_equal(
        _raised(_both_wrong),
        "extract_column: parent must be Arrow STRING column, got type_id=5",
    )


# =============================================================================
# Null parent rows
# =============================================================================


def test_null_parent_rows_stay_null() raises:
    """A null parent row is null in the output, for the whole-document path
    too: there, an empty payload read as a value would be VALID and empty, so
    only the null check keeps it null. Nulls sit first, in the middle and last
    so an off-by-one in the row index shows."""
    var values = List[String]()
    var valid = List[Bool]()
    values.append(String(""))
    valid.append(False)
    values.append(String("{\"a\":1}"))
    valid.append(True)
    values.append(String(""))
    valid.append(False)
    values.append(String("{\"a\":2}"))
    valid.append(True)
    values.append(String(""))
    valid.append(False)
    var paths = List[String]()
    paths.append(String(""))
    paths.append(String("a"))
    for p in range(len(paths)):
        var col = Column.from_string(
            StringArray.from_strings_with_validity(values, valid)
        )
        var out = extract_column(col, _segs(paths[p]), ArrowType.STRING, True)
        assert_equal(out.length(), 5)
        assert_equal(out.null_count(), 3, paths[p])
        assert_equal(_cell(out, 0), String(NULL))
        assert_equal(_cell(out, 2), String(NULL))
        assert_equal(_cell(out, 4), String(NULL))
        if paths[p].byte_length() == 0:
            assert_equal(_cell(out, 1), String("{\"a\":1}"))
            assert_equal(_cell(out, 3), String("{\"a\":2}"))
        else:
            assert_equal(_cell(out, 1), String("1"))
            assert_equal(_cell(out, 3), String("2"))


# =============================================================================
# Documents that are not objects
# =============================================================================


def test_a_document_that_is_not_an_object_has_no_key() raises:
    """A bare scalar (no structural at all) and an array of scalars (no brace
    anywhere) hold no key: null. The object control shows the same key is found.
    An array holding an object is not here: its first object's keys are found
    today, komira-ai/komira#1501."""
    _both(String("42"), String("a"), String(NULL))
    _both(String("  "), String("a"), String(NULL))
    _both(String("[1,2]"), String("a"), String(NULL))
    _both(String("[[1],[2]]"), String("a"), String(NULL))
    _both(String("{\"a\":42}"), String("a"), String("42"))


# =============================================================================
# Scalars: whitespace and empty values
# =============================================================================


def test_scalar_whitespace_is_trimmed_on_both_sides() raises:
    """Every JSON whitespace byte (space, tab, LF, CR) before and after a scalar
    is trimmed; whitespace inside the token never occurs in valid JSON."""
    _both(String("{\"a\": 7 ,\"b\":2}"), String("a"), String("7"))
    _both(String("{\"a\":\t-1.5e3\t}"), String("a"), String("-1.5e3"))
    _both(String("{\"a\":\ntrue\n}"), String("a"), String("true"))
    _both(String("{\"a\":\r\nfalse\r\n}"), String("a"), String("false"))
    _both(String("{\"b\":1, \"a\" : \t 0 \r}"), String("a"), String("0"))
    assert_equal(_one(String("{\"a\": null }"), String("a"), True), String("null"))
    assert_equal(_one(String("{\"a\": null }"), String("a"), False), String(NULL))


def test_an_empty_scalar_is_missing() raises:
    """A key whose value is nothing (or only whitespace) has no value: null,
    for `->` too (it is malformed, not the JSON literal `null`)."""
    _both(String("{\"a\":,\"b\":1}"), String("a"), String(NULL))
    _both(String("{\"a\": \t }"), String("a"), String(NULL))
    _both(String("{\"a\":}"), String("a"), String(NULL))
    _both(String("{\"a\":,\"b\":1}"), String("b"), String("1"))


# =============================================================================
# Skipping and slicing nested values
# =============================================================================


def test_nested_values_before_the_key_are_skipped_whole() raises:
    """A non-matching key's object or array value is skipped to its matching
    close, nesting included, so a same-named key INSIDE it never matches."""
    _both(String("{\"x\":{\"y\":[1,{\"z\":2}]},\"a\":3}"), String("a"), String("3"))
    _both(String("{\"x\":{\"a\":9},\"a\":3}"), String("a"), String("3"))
    _both(String("{\"x\":[[\"a\"],[{\"a\":8}]],\"a\":4}"), String("a"), String("4"))
    _both(String("{\"x\":{},\"y\":[],\"a\":5}"), String("a"), String("5"))
    _both(String("{\"x\":{\"a\":{\"a\":1}},\"y\":{\"b\":2}}"), String("a"), String(NULL))
    _both(String("{\"x\":{\"a\":{\"a\":1}},\"y\":{\"b\":2}}"), String("y.b"), String("2"))


def test_a_nested_value_of_the_same_kind_is_sliced_to_its_own_close() raises:
    """An object holding objects (an array holding arrays) is sliced to ITS
    closing delimiter, not the first inner one, at depth two and three.
    Same-kind nesting only: an object holding an array (or the reverse) is
    sliced to the wrong close today, komira-ai/komira#1500."""
    _both(
        String("{\"a\":{\"b\":{\"c\":1}},\"d\":2}"),
        String("a"),
        String("{\"b\":{\"c\":1}}"),
    )
    _both(
        String("{\"a\":{\"b\":{\"c\":{}},\"e\":{}}}"),
        String("a"),
        String("{\"b\":{\"c\":{}},\"e\":{}}"),
    )
    _both(String("{\"a\":[[1,2],[3]],\"d\":2}"), String("a"), String("[[1,2],[3]]"))
    _both(String("{\"a\":[[[]]]}"), String("a"), String("[[[]]]"))


def test_an_unclosed_nested_value_is_missing() raises:
    """An object or array value whose close never comes is malformed: null."""
    _both(String("{\"a\":{\"b\":1"), String("a"), String(NULL))
    _both(String("{\"a\":[1,2"), String("a"), String(NULL))
    _both(String("{\"a\":{\"b\":{}"), String("a"), String(NULL))


# =============================================================================
# Malformed objects
# =============================================================================


def test_malformed_objects_are_missing() raises:
    """Each shape is a document the walker cannot finish reading: null."""
    # A key with no colon after it (the next key must not be read as its value).
    _both(String("{\"a\" \"b\",\"c\":2}"), String("a"), String(NULL))
    _both(String("{\"a\" 1,\"b\":2}"), String("a"), String(NULL))
    # A colon that ends the document.
    _both(String("{\"a\":"), String("a"), String(NULL))
    # A document that ends after a comma, before the key is found.
    _both(String("{\"b\":1,"), String("a"), String(NULL))
    _both(String("{\"b\":\"x\""), String("a"), String(NULL))
    # A non-key structural where a key belongs, then the end of the object.
    _both(String("{]}"), String("a"), String(NULL))
    _both(String("{:}"), String("a"), String(NULL))


def test_an_escaped_key_of_the_same_decoded_length_must_match_byte_for_byte() raises:
    """The key `a\\"c` decodes to three bytes, like the target `a"b`, and
    differs only in its last byte: it is skipped, the next key matches."""
    var doc = String("{\"a\\\"c\":1,\"a\\\"b\":2}")
    var values = List[String]()
    values.append(doc)
    var segs = List[String]()
    segs.append(String("a\"b"))
    var out = extract_column(
        Column.from_string(StringArray.from_strings(values)),
        segs^,
        ArrowType.STRING,
        False,
    )
    assert_equal(_cell(out, 0), String("2"))
    # Same length, first byte differs.
    var segs2 = List[String]()
    segs2.append(String("x\"c"))
    var values2 = List[String]()
    values2.append(doc)
    var out2 = extract_column(
        Column.from_string(StringArray.from_strings(values2)),
        segs2^,
        ArrowType.STRING,
        False,
    )
    assert_equal(_cell(out2, 0), String(NULL))


def test_a_key_matches_whole_never_as_a_prefix() raises:
    """A key that starts with the target, or that the target starts with, is
    another key; so is one of the same length differing in its last byte."""
    _both(String("{\"ab\":1,\"a\":2}"), String("a"), String("2"))
    _both(String("{\"a\":1}"), String("ab"), String(NULL))
    _both(String("{\"ab\":1,\"ac\":2}"), String("ac"), String("2"))
    _both(String("{\"ab\":{\"c\":1},\"a\":{\"c\":2}}"), String("a.c"), String("2"))


# =============================================================================
# The private helpers' guards, over hand-built tapes
# =============================================================================
#
# Stage 1 never emits these tapes (an unterminated string raises there, and
# the walker never calls a helper past the tape's end), so each guard is
# driven directly: it must answer "missing" / "past the end", never read
# outside the tape.


def test_a_key_quote_with_no_closing_quote_is_missing() raises:
    var b = _bytes("{\"a\":1}")
    # `{` `"` then the tape ends.
    var t1 = _tape([0, 1], [TAG_OPEN_BRACE, TAG_QUOTE_OPEN])
    assert_false(_extract_one_row(Span(b), t1, _segs("a"), True).found)
    # `{` `"` `:` — the opening quote is followed by something else.
    var t2 = _tape([0, 1, 4, 6], [TAG_OPEN_BRACE, TAG_QUOTE_OPEN, TAG_COLON, TAG_CLOSE_BRACE])
    assert_false(_extract_one_row(Span(b), t2, _segs("a"), True).found)
    # Control: the well-formed tape finds it.
    var t3 = _tape(
        [0, 1, 3, 4, 6],
        [TAG_OPEN_BRACE, TAG_QUOTE_OPEN, TAG_QUOTE_CLOSE, TAG_COLON, TAG_CLOSE_BRACE],
    )
    var r = _extract_one_row(Span(b), t3, _segs("a"), True)
    assert_true(r.found)
    assert_equal(r^.take_value(), String("1"))


def test_extract_value_at_guards() raises:
    var b = _bytes("{\"a\":\"v\"}")
    var full = _tape(
        [0, 1, 3, 4, 5, 7, 8],
        [TAG_OPEN_BRACE, TAG_QUOTE_OPEN, TAG_QUOTE_CLOSE, TAG_COLON,
         TAG_QUOTE_OPEN, TAG_QUOTE_CLOSE, TAG_CLOSE_BRACE],
    )
    # Past the end of the tape.
    assert_false(_extract_value_at(Span(b), full, 7, True, len(b)).found)
    assert_false(_extract_value_at(Span(b), full, 8, False, len(b)).found)
    # A string value whose closing quote is the tape's end ...
    var cut = _tape([0, 5], [TAG_OPEN_BRACE, TAG_QUOTE_OPEN])
    assert_false(_extract_value_at(Span(b), cut, 1, True, len(b)).found)
    # ... or is some other structural.
    var wrong = _tape([0, 5, 8], [TAG_OPEN_BRACE, TAG_QUOTE_OPEN, TAG_CLOSE_BRACE])
    assert_false(_extract_value_at(Span(b), wrong, 1, False, len(b)).found)
    # A scalar at tape position 0 has no structural before it to start after.
    var s = _bytes("1:")
    var head = _tape([1], [TAG_COLON])
    assert_false(_extract_value_at(Span(s), head, 0, True, len(s)).found)
    # Control: the string value at position 4 is found.
    var r = _extract_value_at(Span(b), full, 4, False, len(b))
    assert_true(r.found)
    assert_equal(r^.take_value(), String("v"))


def test_skip_value_at_past_the_end() raises:
    var t = _tape([0, 1], [TAG_OPEN_BRACE, TAG_QUOTE_OPEN])
    assert_equal(_skip_value_at(t, 2, 9), 2)
    assert_equal(_skip_value_at(t, 5, 9), 5)
    # A string whose closing quote is cut off skips to the tape's end.
    assert_equal(_skip_value_at(t, 1, 9), 2)


def test_find_close_for_guards() raises:
    var t = _tape(
        [0, 1, 2, 3],
        [TAG_OPEN_BRACE, TAG_COLON, TAG_OPEN_BRACKET, TAG_CLOSE_BRACE],
    )
    assert_equal(_find_close_for(t, 4, 4), -1)
    assert_equal(_find_close_for(t, 9, 4), -1)
    # A position that is not an opening delimiter.
    assert_equal(_find_close_for(t, 1, 4), -1)
    assert_equal(_find_close_for(t, 3, 4), -1)
    # An array with no close.
    assert_equal(_find_close_for(t, 2, 4), -1)


def _inverted_slice() raises:
    var b = _bytes("abcd")
    _ = _slice_to_string(Span(b), 3, 1)


def test_slice_to_string_refuses_an_inverted_range() raises:
    assert_equal(_raised(_inverted_slice), "_slice_to_string: end < start")
    var b = _bytes("abcd")
    assert_equal(_slice_to_string(Span(b), 1, 3), String("bc"))
    assert_equal(_slice_to_string(Span(b), 2, 2), String(""))


# =============================================================================
# Runner
# =============================================================================


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    """Run one case; a failure is recorded, not fatal, so a red build names
    EVERY failing case rather than only the first."""
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_refuses_a_non_string_parent", test_refuses_a_non_string_parent, failed)
    _run("test_refuses_a_non_string_output", test_refuses_a_non_string_output, failed)
    _run("test_parent_type_is_reported_before_output_type", test_parent_type_is_reported_before_output_type, failed)
    _run("test_null_parent_rows_stay_null", test_null_parent_rows_stay_null, failed)
    _run("test_a_document_that_is_not_an_object_has_no_key", test_a_document_that_is_not_an_object_has_no_key, failed)
    _run("test_scalar_whitespace_is_trimmed_on_both_sides", test_scalar_whitespace_is_trimmed_on_both_sides, failed)
    _run("test_an_empty_scalar_is_missing", test_an_empty_scalar_is_missing, failed)
    _run("test_nested_values_before_the_key_are_skipped_whole", test_nested_values_before_the_key_are_skipped_whole, failed)
    _run("test_a_nested_value_of_the_same_kind_is_sliced_to_its_own_close", test_a_nested_value_of_the_same_kind_is_sliced_to_its_own_close, failed)
    _run("test_an_unclosed_nested_value_is_missing", test_an_unclosed_nested_value_is_missing, failed)
    _run("test_malformed_objects_are_missing", test_malformed_objects_are_missing, failed)
    _run("test_an_escaped_key_of_the_same_decoded_length_must_match_byte_for_byte", test_an_escaped_key_of_the_same_decoded_length_must_match_byte_for_byte, failed)
    _run("test_a_key_matches_whole_never_as_a_prefix", test_a_key_matches_whole_never_as_a_prefix, failed)
    _run("test_a_key_quote_with_no_closing_quote_is_missing", test_a_key_quote_with_no_closing_quote_is_missing, failed)
    _run("test_extract_value_at_guards", test_extract_value_at_guards, failed)
    _run("test_skip_value_at_past_the_end", test_skip_value_at_past_the_end, failed)
    _run("test_find_close_for_guards", test_find_close_for_guards, failed)
    _run("test_slice_to_string_refuses_an_inverted_range", test_slice_to_string_refuses_an_inverted_range, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("json_extract edges: ALL CASES PASS")

