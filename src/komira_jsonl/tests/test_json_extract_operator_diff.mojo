# =============================================================================
# Tests for `->` vs `->>` operator-mode diff at the extract_column kernel.
# =============================================================================
#
# Apply BOTH `->` (preserve_extension_metadata=True) and `->>` (False) to
# the same input and assert:
#
#   (a) For NUMERIC scalar values, byte content is IDENTICAL.
#       ⛔ AND NOT FOR THE JSON LITERAL `null`. "Scalar" does not
#       generalise from numbers to every untagged value: `->>` over a JSON
#       null is **SQL NULL** on DuckDB v1.5.3, where `->` keeps the
#       three-byte text. See
#       `test_diff_json_null_arrow_keeps_text_text_mode_is_SQL_NULL`, with a
#       string-valued `"null"` CONTROL beside it.
#   (b) For STRING values, `->` returns RAW JSON text (quotes included);
#       `->>` returns the unquoted, unescaped string.
#   (c) For OBJECT / ARRAY values, byte content is IDENTICAL (raw JSON
#       text including delimiters).
#   (d) Field-level extension metadata (the `ARROW:extension:name =
#       "komira.ext.json"` bit is the SDK layer's
#       responsibility — it's NOT exercised at this kernel-level test
#       (the kernel returns the bytes-correct Column; the SDK plumbs the
#       Field metadata as key-value metadata). The mode
#       discriminator at this layer is the byte-content unquote step.
#
# These tests do NOT depend on the full pipeline (no LogicalPlan, no
# EngineContext) — they exercise the kernel directly to lock in the
# operator-mode contract before SDK / engine wiring.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import parse_json_path

from komira_jsonl.json_extract_kernel import extract_column
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Helpers
# =============================================================================


def _string_column(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


# =============================================================================
# Scalar-value diff (numeric, bool, null) — IDENTICAL bytes either mode.
# =============================================================================


def test_diff_numeric_scalar_identical_bytes() raises:
    # {"x": 42} — `->` and `->>` return identical bytes ("42").
    var values = List[String]()
    values.append(String("{\"x\":42}"))
    var col_arrow = _string_column(values)
    var values2 = List[String]()
    values2.append(String("{\"x\":42}"))
    var col_text = _string_column(values2)
    var path_a = parse_json_path(String("$.x"))
    var path_b = parse_json_path(String("$.x"))
    var out_arrow = extract_column(col_arrow, path_a^, ArrowType.STRING, True)
    var out_text = extract_column(col_text, path_b^, ArrowType.STRING, False)
    assert_equal(out_arrow.as_string().get(0), String("42"))
    assert_equal(out_text.as_string().get(0), String("42"))


def test_diff_bool_scalar_identical_bytes() raises:
    var values = List[String]()
    values.append(String("{\"flag\":true}"))
    var col_arrow = _string_column(values)
    var values2 = List[String]()
    values2.append(String("{\"flag\":true}"))
    var col_text = _string_column(values2)
    var path_a = parse_json_path(String("$.flag"))
    var path_b = parse_json_path(String("$.flag"))
    var out_arrow = extract_column(col_arrow, path_a^, ArrowType.STRING, True)
    var out_text = extract_column(col_text, path_b^, ArrowType.STRING, False)
    assert_equal(out_arrow.as_string().get(0), String("true"))
    assert_equal(out_text.as_string().get(0), String("true"))


def test_diff_json_null_arrow_keeps_text_text_mode_is_SQL_NULL() raises:
    """★ THE ONE SCALAR SHAPE WHERE THE TWO MODES DIVERGE.

    DuckDB v1.5.3:
    `->` (`json_extract`) over a JSON `null` returns the JSON value `null` —
    the three-byte text — while `->>` (`json_extract_string`) returns **SQL
    NULL**, because `->>` converts the JSON value to VARCHAR and a JSON null
    has no VARCHAR form. Postgres `jsonb ->>` is the same.

    ⛔ A test that asserts the two modes return identical bytes here would
    pin the wrong answer green. A defect asserted by a passing test is
    invisible to every sweep that runs it.

    ⚠ THE DISCRIMINATOR IS THE JSON **TYPE**, NEVER THE BYTES. The string
    value `"null"` and the literal `null` have the same three-byte payload
    after unquoting, and `test_diff_string_value_null_TEXT_is_not_SQL_NULL`
    below is the arm that proves this fix keyed on the type: it lives on the
    `TAG_QUOTE_OPEN` branch and must still answer the string `null`.
    """
    var values = List[String]()
    values.append(String("{\"k\":null}"))
    var col_arrow = _string_column(values)
    var values2 = List[String]()
    values2.append(String("{\"k\":null}"))
    var col_text = _string_column(values2)
    var path_a = parse_json_path(String("$.k"))
    var path_b = parse_json_path(String("$.k"))
    var out_arrow = extract_column(col_arrow, path_a^, ArrowType.STRING, True)
    var out_text = extract_column(col_text, path_b^, ArrowType.STRING, False)

    # `->` — the JSON value `null`, as JSON text. Row is VALID.
    assert_equal(out_arrow.as_string().get(0), String("null"))
    assert_equal(out_arrow.null_count(), 0)
    assert_false(out_arrow.is_null_at(0))

    # `->>` — SQL NULL. The row's validity bit is CLEAR.
    assert_equal(out_text.null_count(), 1)
    assert_true(out_text.is_null_at(0))


def test_diff_string_value_null_TEXT_is_not_SQL_NULL() raises:
    """THE CONTROL FOR THE TEST ABOVE, and the assertion that cannot be
    satisfied by a fix that keys on BYTES instead of on the JSON type.

    `{"k":"null"}` holds a STRING whose content is `null`. DuckDB's `->>`
    answers the four-character VARCHAR `null` with the row VALID; only the
    JSON literal `null` becomes SQL NULL. A fix that tested the extracted
    text for equality with `"null"` after unquoting would null this row too,
    and would be wrong in a way no bytes comparison can see.
    """
    var values = List[String]()
    values.append(String("{\"k\":\"null\"}"))
    var col_arrow = _string_column(values)
    var values2 = List[String]()
    values2.append(String("{\"k\":\"null\"}"))
    var col_text = _string_column(values2)
    var path_a = parse_json_path(String("$.k"))
    var path_b = parse_json_path(String("$.k"))
    var out_arrow = extract_column(col_arrow, path_a^, ArrowType.STRING, True)
    var out_text = extract_column(col_text, path_b^, ArrowType.STRING, False)

    # `->` keeps the raw JSON text, quotes included.
    assert_equal(out_arrow.as_string().get(0), String("\"null\""))
    assert_false(out_arrow.is_null_at(0))

    # `->>` unquotes to the four-character string `null` — NOT SQL NULL.
    assert_equal(out_text.as_string().get(0), String("null"))
    assert_equal(out_text.null_count(), 0)
    assert_false(out_text.is_null_at(0))


def test_diff_json_null_does_not_null_its_NEIGHBOURS() raises:
    """A three-row column where only the MIDDLE row holds a JSON `null`.

    ⚠ The arm this fix touches is the SCALAR arm, which is also the arm that
    serves numbers and booleans, and it reads its byte range by walking BACK
    one tape entry. A fix that widened the range, or that returned a miss for
    any scalar, would show up here and nowhere in a single-row test: rows 0
    and 2 must keep their own values and stay VALID, and exactly ONE row may
    be null.
    """
    var values = List[String]()
    values.append(String("{\"k\":7}"))
    values.append(String("{\"k\":null}"))
    values.append(String("{\"k\":false}"))
    var col_text = _string_column(values)
    var path = parse_json_path(String("$.k"))
    var out = extract_column(col_text, path^, ArrowType.STRING, False)

    assert_equal(out.length(), 3)
    assert_equal(out.null_count(), 1)
    assert_false(out.is_null_at(0))
    assert_equal(out.as_string().get(0), String("7"))
    assert_true(out.is_null_at(1))
    assert_false(out.is_null_at(2))
    assert_equal(out.as_string().get(2), String("false"))


# =============================================================================
# String-value diff — RAW JSON for `->`, unquoted for `->>`.
# =============================================================================


def test_diff_string_value_arrow_returns_quoted() raises:
    # `->` on {"name":"alice"} -> returns raw JSON text including quotes.
    var values = List[String]()
    values.append(String("{\"name\":\"alice\"}"))
    var col = _string_column(values)
    var path = parse_json_path(String("$.name"))
    var out = extract_column(col, path^, ArrowType.STRING, True)
    var got = out.as_string().get(0)
    assert_equal(got, String("\"alice\""))


def test_diff_string_value_text_returns_unquoted() raises:
    # `->>` on {"name":"alice"} -> returns "alice" without quotes.
    var values = List[String]()
    values.append(String("{\"name\":\"alice\"}"))
    var col = _string_column(values)
    var path = parse_json_path(String("$.name"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    var got = out.as_string().get(0)
    assert_equal(got, String("alice"))


def test_diff_string_value_with_escape_text_mode() raises:
    # `->>` unescapes — "line1\nline2" -> "line1\nline2" (literal newline).
    var values = List[String]()
    values.append(String("{\"k\":\"line1\\nline2\"}"))
    var col = _string_column(values)
    var path = parse_json_path(String("$.k"))
    var out = extract_column(col, path^, ArrowType.STRING, False)
    var got = out.as_string().get(0)
    # Result should contain an actual newline (0x0A).
    var got_bytes = got.as_bytes()
    var found_nl = False
    for i in range(len(got_bytes)):
        if got_bytes[i] == UInt8(0x0A):
            found_nl = True
            break
    assert_true(found_nl)


# =============================================================================
# Object / array value diff — IDENTICAL raw bytes either mode.
# =============================================================================


def test_diff_object_value_identical_raw_bytes() raises:
    # Nested object at the path -> both modes return the raw JSON text.
    var values = List[String]()
    values.append(String("{\"meta\":{\"a\":1,\"b\":2}}"))
    var col_arrow = _string_column(values)
    var values2 = List[String]()
    values2.append(String("{\"meta\":{\"a\":1,\"b\":2}}"))
    var col_text = _string_column(values2)
    var path_a = parse_json_path(String("$.meta"))
    var path_b = parse_json_path(String("$.meta"))
    var out_arrow = extract_column(col_arrow, path_a^, ArrowType.STRING, True)
    var out_text = extract_column(col_text, path_b^, ArrowType.STRING, False)
    var got_a = out_arrow.as_string().get(0)
    var got_t = out_text.as_string().get(0)
    assert_equal(got_a, String("{\"a\":1,\"b\":2}"))
    assert_equal(got_t, String("{\"a\":1,\"b\":2}"))


def test_diff_array_value_identical_raw_bytes() raises:
    # Array at the path -> both modes return raw JSON text incl. brackets.
    var values = List[String]()
    values.append(String("{\"xs\":[1,2,3]}"))
    var col_arrow = _string_column(values)
    var values2 = List[String]()
    values2.append(String("{\"xs\":[1,2,3]}"))
    var col_text = _string_column(values2)
    var path_a = parse_json_path(String("$.xs"))
    var path_b = parse_json_path(String("$.xs"))
    var out_arrow = extract_column(col_arrow, path_a^, ArrowType.STRING, True)
    var out_text = extract_column(col_text, path_b^, ArrowType.STRING, False)
    assert_equal(out_arrow.as_string().get(0), String("[1,2,3]"))
    assert_equal(out_text.as_string().get(0), String("[1,2,3]"))


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("test_json_extract_operator_diff — `->` vs `->>` suite")

    # Scalar — identical bytes
    test_diff_numeric_scalar_identical_bytes()
    test_diff_bool_scalar_identical_bytes()
    test_diff_json_null_arrow_keeps_text_text_mode_is_SQL_NULL()
    test_diff_string_value_null_TEXT_is_not_SQL_NULL()
    test_diff_json_null_does_not_null_its_NEIGHBOURS()

    # String — diff
    test_diff_string_value_arrow_returns_quoted()
    test_diff_string_value_text_returns_unquoted()
    test_diff_string_value_with_escape_text_mode()

    # Object / array — identical
    test_diff_object_value_identical_raw_bytes()
    test_diff_array_value_identical_raw_bytes()

    print("test_json_extract_operator_diff — all tests PASSED")
