# =============================================================================
# test_jsonl_key_spelling_and_index.mojo -- keys by the text they spell; an
# index that does not match its bytes; unread nested STRUCT children
# =============================================================================
#
# What each test catches:
#   - test_escaped_key_is_the_same_key: `{"\u0061":1,"a":2}` repeats key
#     `a` (RFC 8259 compares the strings the names spell). The defect: the
#     lookup compared raw bytes, so the escaped spelling missed column `a`,
#     was skipped, and the row read a=2 with the 1 lost and no duplicate
#     error; `{"\u0061":5}` read a=null; `{"a\/b":1}` never matched column
#     `a/b`. Also: a surrogate-pair key, `\u0000` inside a key (must not
#     end the key), the same inside a STRUCT, and inference naming the
#     column by the decoded text.
#   - test_unread_struct_child_nested_value_skipped: a STRUCT child the
#     schema does not declare, holding an array or object, used to raise
#     "nested ... not supported"; it is skipped like an unread top-level key.
#   - test_unterminated_string_after_backslash: `{"a":"x\` LF `{"b":1}`. The
#     defect: the line finder let the backslash escape the LF and named
#     line 2; the string is open at the end of line 1.
#   - test_mismatched_index_raises: an index built over other bytes (longer
#     than the input) must raise a contract error, not read past the input.
#     Runs last: before the fix it may read out of bounds.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_json_index.structural_index import build_structural_index
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.schema_inference import infer_jsonl_schema


def _schema_one(name: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    return sb.build()


def _schema_struct() -> Schema:
    var sb = SchemaBuilder()
    var f = Field(String("s"), ArrowType.STRUCT, True)
    f.add_child(String("a"), ArrowType.INT64, True)
    f.add_child(String("b"), ArrowType.STRING, True)
    sb.add_field(f)
    return sb.build()


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _refused(text: String, var schema: Schema) raises -> String:
    """The error reading `text` raises; raises itself when it returns rows."""
    var b = _bytes_of(text)
    var rows = -1
    try:
        var batch = materialize_jsonl_to_batch(Span(b), schema^)
        rows = batch._num_rows
    except e:
        return String(e)
    raise Error("not refused (" + String(rows) + " rows): " + text)


def _int_at(text: String, name: String, row: Int) raises -> Int:
    """Column `name` (INT64) of row `row` read from `text`, or -1 if null."""
    var b = _bytes_of(text)
    var batch = materialize_jsonl_to_batch(Span(b), _schema_one(name))
    ref col = batch.column_at(0)
    if col.is_null_at(row):
        return -1
    return Int(col.as_primitive[DType.int64]().get(row))


def test_escaped_key_is_the_same_key() raises:
    print("T1: a key is the text it spells")
    var msg = _refused(String('{"\\u0061":1,"a":2}\n'), _schema_one(String("a")))
    assert_true("line 1:" in msg and "duplicate key 'a'" in msg, msg)
    msg = _refused(String('{"a":0}\n{"a":1,"\\u0061":2}\n'), _schema_one(String("a")))
    assert_true("line 2:" in msg and "duplicate key 'a'" in msg, msg)
    assert_equal(_int_at(String('{"\\u0061":5}\n'), String("a"), 0), 5)
    assert_equal(_int_at(String('{"a\\/b":1}\n'), String("a/b"), 0), 1)
    assert_equal(_int_at(String('{"\\ud83d\\ude00":7}\n'), String("😀"), 0), 7)
    assert_equal(_int_at(String('{"caf\\u00e9":8}\n'), String("café"), 0), 8)
    # `\u0000` is a byte of the key, not its end: `a\u0000x` is not `a`.
    assert_equal(_int_at(String('{"a\\u0000x":9}\n'), String("a"), 0), -1)
    # Inside a STRUCT.
    msg = _refused(String('{"s":{"a":1,"\\u0061":2}}\n'), _schema_struct())
    assert_true("line 1:" in msg and "duplicate key 'a'" in msg, msg)
    # Inference names the column by the decoded text, so the read finds it.
    var b = _bytes_of(String('{"a\\/b":3}\n'))
    var schema = infer_jsonl_schema(Span(b))
    assert_equal(schema.num_columns(), 1)
    assert_equal(String(schema.field_name(0)), String("a/b"))
    var batch = materialize_jsonl_to_batch(Span(b), schema^)
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(0)), 3)


def test_unread_struct_child_nested_value_skipped() raises:
    print("T2: an unread STRUCT child's nested value is skipped")
    var b = _bytes_of(
        String('{"s":{"a":1,"z":[1,{"q":[2]},[]],"y":{"p":{}},"b":"x"}}\n')
    )
    var batch = materialize_jsonl_to_batch(Span(b), _schema_struct())
    assert_equal(batch._num_rows, 1)
    assert_equal(batch.column_at(0).null_count(), 0)
    # A nested value under a child the struct DOES read still raises.
    var msg = _refused(String('{"s":{"a":[1]}}\n'), _schema_struct())
    assert_true("line 1:" in msg and "not supported" in msg, msg)


def test_unterminated_string_after_backslash() raises:
    print("T3: a string open at a backslash-LF names its own line")
    var msg = _refused(String('{"a":"x\\\n{"b":1}\n'), _schema_one(String("a")))
    assert_true("line 1:" in msg and "not closed on its line" in msg, msg)


def test_mismatched_index_raises() raises:
    print("T4: an index built over other bytes is refused")
    var long = _bytes_of(String('{"a":1}\n{"a":"0123456789abcdefghij"}\n'))
    var idx = build_structural_index(Span(long))
    var short = _bytes_of(String('{"a":1}\n{"a":"0'))
    var refused = False
    var msg = String()
    try:
        var batch = materialize_jsonl_to_batch(Span(short), _schema_one(String("a")), idx)
        _ = batch^
    except e:
        refused = True
        msg = String(e)
    assert_true(refused, "a mismatched index was not refused")
    assert_true("does not match the bytes" in msg, msg)


def main() raises:
    print("test_jsonl_key_spelling_and_index")
    var failed = 0
    try:
        test_escaped_key_is_the_same_key()
    except e:
        print("FAIL T1:", e)
        failed += 1
    try:
        test_unread_struct_child_nested_value_skipped()
    except e:
        print("FAIL T2:", e)
        failed += 1
    try:
        test_unterminated_string_after_backslash()
    except e:
        print("FAIL T3:", e)
        failed += 1
    try:
        test_mismatched_index_raises()
    except e:
        print("FAIL T4:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("test_jsonl_key_spelling_and_index: PASSED")
