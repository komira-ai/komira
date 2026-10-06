# =============================================================================
# test_jsonl_line_validation.mojo -- every JSONL line is one JSON object
# =============================================================================
#
# The JSONL reader (`materialize_jsonl_to_batch` and the paths built on it:
# the parallel materializer and the streaming source) returns rows only for
# input in which every line is blank or holds exactly one RFC 8259 JSON
# object. Anything else is refused with an error naming the 1-based line;
# no batch is returned, so no row is kept from a refused input (the rows
# before the bad line are not returned either).
#
# What each test catches:
#   - test_non_object_line_mid_file: a `[3]` line between objects. The
#     defect it guards: the walker skipped to the next `{` and returned the
#     other three rows, dropping the line without a word.
#   - test_top_level_scalar_lines: `1`, `"s"`, `null`, `true`, `[]`, a
#     number with an exponent. Same defect for values with no `{` at all.
#   - test_invalid_json_lines: lines that are not JSON (trailing commas,
#     missing colon or comma, bad literals and numbers, raw control bytes
#     and bad escapes in strings, lone surrogates, ill-formed UTF-8, a BOM,
#     two values on one line, an object spread over two lines, an unclosed
#     object, a string left open on its line). Most sit under a key the schema does not read, where the
#     walker skipped them unread. The defect: rows made from text that is
#     not JSON.
#   - test_duplicate_key_refused: a key the schema reads, repeated in one
#     object (top level and inside a STRUCT). The defect: both values were
#     pushed into the column, so the column had more values than the row
#     count and every later row was shifted.
#   - test_valid_objects_still_read (control): blank and whitespace-only
#     lines, CRLF endings, escapes, surrogate pairs, nested values under
#     unread keys, every number form, and a repeated key the schema does
#     not read (documented: skipped unread) all read as before.
#   - test_parallel_reports_absolute_line: the bad line sits in a later
#     partition of a >4 MiB input; the error names its line in the file,
#     not in the partition.
#   - test_streaming_reports_absolute_line: the same through the chunked
#     file reader, with a bad line in a later chunk and a bad final line
#     with no trailing newline.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import (
    materialize_jsonl_to_batch,
    materialize_jsonl_to_batch_parallel,
)
from komira_jsonl.streaming_source import read_jsonl_streamed_to_one_batch
from komira_runtime_paths import test_tmpdir


def _schema_a() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    return sb.build()


def _schema_ab() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    sb.add_field(Field(String("b"), ArrowType.INT64, True))
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


def _expect_refused_bytes(
    label: String, b: List[UInt8], var schema: Schema, line: Int, word: String
) raises:
    """`b` must be refused with an error naming `line` and containing `word`."""
    var refused = False
    var msg = String()
    var rows = -1
    try:
        var batch = materialize_jsonl_to_batch(Span(b), schema^)
        rows = batch._num_rows
    except e:
        refused = True
        msg = String(e)
    if not refused:
        raise Error(
            label + ": expected an error naming line " + String(line)
            + ", got " + String(rows) + " row(s) and no error"
        )
    var want = String("line ") + String(line) + ":"
    if want not in msg:
        raise Error(label + ": error does not name '" + want + "': " + msg)
    if word not in msg:
        raise Error(label + ": error does not say '" + word + "': " + msg)
    print("  refused", label, "->", msg)


def _expect_refused(
    label: String, text: String, var schema: Schema, line: Int, word: String
) raises:
    _expect_refused_bytes(label, _bytes_of(text), schema^, line, word)


comptime _NOT_OBJECT = "not a JSON object"
comptime _NOT_JSON = "not valid JSON"


def test_non_object_line_mid_file() raises:
    print("T1: a non-object line between objects is refused, naming it")
    _expect_refused(
        "array line 3",
        String('{"a":1}\n{"a":2}\n[3]\n{"a":4}\n'),
        _schema_a(), 3, _NOT_OBJECT,
    )


def test_top_level_scalar_lines() raises:
    print("T2: a top-level scalar (or array) line is refused")
    _expect_refused("number", String("1\n"), _schema_a(), 1, _NOT_OBJECT)
    _expect_refused("string", String('"s"\n'), _schema_a(), 1, _NOT_OBJECT)
    _expect_refused("null", String("null\n"), _schema_a(), 1, _NOT_OBJECT)
    _expect_refused("true", String("true"), _schema_a(), 1, _NOT_OBJECT)
    _expect_refused("empty array", String("[]\n"), _schema_a(), 1, _NOT_OBJECT)
    _expect_refused(
        "padded false on line 2",
        String('{"a":1}\n  false  \n'),
        _schema_a(), 2, _NOT_OBJECT,
    )
    _expect_refused(
        "exponent on line 2", String('{"a":1}\n-0.5e3\n'), _schema_a(), 2,
        _NOT_OBJECT,
    )


def test_invalid_json_lines() raises:
    print("T3: a line that is not JSON is refused, naming it")
    var first = String('{"a":1}\n')
    var cases = List[String]()
    cases.append(String('{"a":2,}'))           # trailing comma
    cases.append(String('{"a":2}}'))           # extra close
    cases.append(String('{"a" 2}'))            # missing colon
    cases.append(String('{"a":02}'))           # leading zero
    cases.append(String('{"a":NaN}'))          # not a JSON literal
    cases.append(String("{'a':2}"))            # single quotes
    cases.append(String('{"z":tru}'))          # bad literal, unread key
    cases.append(String('{"z":1.}'))           # bad number, unread key
    cases.append(String('{"z":-}'))            # bad number, unread key
    cases.append(String('{"z":[1,]}'))         # trailing comma in a skipped array
    cases.append(String('{"z":[1 2]}'))        # missing comma in a skipped array
    cases.append(String('{"z":{"y":1,}}'))     # trailing comma in a skipped object
    cases.append(String('{"z":{"y" 1}}'))      # missing colon in a skipped object
    cases.append(String('{"z":[}'))            # mismatched close
    cases.append(String('{"z":"a\tb"}'))       # raw tab inside a string
    cases.append(String('{"z":"\\x"}'))        # unknown escape
    cases.append(String('{"z":"\\u12"}'))      # short \u escape
    cases.append(String('{"z":"\\ud800"}'))    # lone high surrogate
    cases.append(String('{"z":"\\udc00"}'))    # lone low surrogate
    cases.append(String('{"a":2} {"a":3}'))    # two values on one line
    cases.append(String('{"a":2},'))           # a comma after the object
    cases.append(String('{"a":2}x'))           # junk after the object
    cases.append(String('{"a":2'))             # object not closed at EOF
    cases.append(String('{"a":2,"z":1 1}'))    # two scalars in one value slot
    for i in range(len(cases)):
        var line2 = cases[i]
        _expect_refused(
            String("case ") + String(i) + " " + line2,
            first + line2 + "\n",
            _schema_a(), 2, _NOT_JSON,
        )
    # An object spread over two lines: the record must end on its line.
    _expect_refused(
        "object over two lines", first + '{"a":\n2}\n', _schema_a(), 2,
        _NOT_JSON,
    )
    # A string left open on its line (an odd number of quotes in the
    # input, which Stage 1 refuses for the whole input): the error names
    # the line the string opens on.
    _expect_refused(
        "string not closed on its line",
        first + '{"z":"abc}\n{"a":2}\n', _schema_a(), 2, _NOT_JSON,
    )
    # Ill-formed UTF-8 inside a string (a lone continuation byte, an
    # overlong encoding, an encoded surrogate): built as bytes.
    var bad_utf8 = List[List[UInt8]]()
    bad_utf8.append([UInt8(0x80)])
    bad_utf8.append([UInt8(0xC0), UInt8(0xAF)])
    bad_utf8.append([UInt8(0xED), UInt8(0xA0), UInt8(0x80)])
    bad_utf8.append([UInt8(0xE9)])
    for i in range(len(bad_utf8)):
        var b = _bytes_of(first + '{"z":"')
        b.extend(Span(bad_utf8[i]))
        b.extend(Span(String('"}\n').as_bytes()))
        _expect_refused_bytes(
            String("bad utf-8 ") + String(i), b, _schema_a(), 2, _NOT_JSON
        )
    # A non-ASCII byte outside a string.
    var stray = _bytes_of(first + '{"a":2}')
    stray.append(UInt8(0xC3))
    stray.append(UInt8(0xA9))
    stray.append(UInt8(0x0A))
    _expect_refused_bytes("non-ASCII outside a string", stray, _schema_a(), 2, _NOT_JSON)
    # A UTF-8 byte-order mark before the first object.
    var bom = List[UInt8]()
    bom.append(UInt8(0xEF))
    bom.append(UInt8(0xBB))
    bom.append(UInt8(0xBF))
    bom.extend(Span(String('{"a":1}\n').as_bytes()))
    _expect_refused_bytes("byte-order mark", bom, _schema_a(), 1, _NOT_OBJECT)


def test_duplicate_key_refused() raises:
    print("T4: a key the schema reads, repeated in one object, is refused")
    _expect_refused(
        "duplicate a", String('{"a":1,"a":2}\n'), _schema_a(), 1, "duplicate key"
    )
    _expect_refused(
        "duplicate b on line 2",
        String('{"a":1,"b":2}\n{"b":3,"a":4,"b":5}\n{"a":6}\n'),
        _schema_ab(), 2, "duplicate key",
    )
    _expect_refused(
        "duplicate same value",
        String('{"a":1}\n{"a":7,"a":7}\n'),
        _schema_a(), 2, "duplicate key",
    )
    _expect_refused(
        "duplicate struct child",
        String('{"s":{"a":1,"b":"x"}}\n{"s":{"a":1,"a":2}}\n'),
        _schema_struct(), 2, "duplicate key",
    )


def test_valid_objects_still_read() raises:
    print("T5 (control): valid JSONL still reads, blank lines skipped")
    var text = String(
        '{"a":1}\n'
        "\n"
        "   \t \n"
        '{ "a" : 2 , "z" : [ 1 , -0.5e+3 , { "q" : null } , [] , {} ] ,'
        ' "y" : "\\u00e9\\ud83d\\ude00\\n\\"\\\\\\/\\b\\f\\r\\t" ,'
        ' "x" : true , "w" : false , "v" : 0 , "u" : 1E2 }\r\n'
        "{}\n"
        '{"a":3,"t":"café € 😀"}\n'
        '{"a":4,"z":1,"z":2}'
    )
    var b = _bytes_of(text)
    var batch = materialize_jsonl_to_batch(Span(b), _schema_a())
    assert_equal(batch._num_rows, 5)
    ref col = batch.column_at(0)
    assert_equal(col.null_count(), 1)
    var a = col.as_primitive[DType.int64]()
    assert_equal(Int(a.get(0)), 1)
    assert_equal(Int(a.get(1)), 2)
    assert_true(col.is_null_at(2))
    assert_equal(Int(a.get(3)), 3)
    assert_equal(Int(a.get(4)), 4)
    # Empty and whitespace-only inputs: no rows, no error.
    assert_equal(materialize_jsonl_to_batch(Span(_bytes_of(String(""))), _schema_a())._num_rows, 0)
    assert_equal(materialize_jsonl_to_batch(Span(_bytes_of(String("\n \r\n\n"))), _schema_a())._num_rows, 0)
    print("  OK 5 rows")


def _big_input(n_rows: Int, bad_row: Int, bad: String) -> String:
    var b = String("")
    for i in range(n_rows):
        if i == bad_row:
            b += bad + "\n"
        else:
            b += '{"a":' + String(i) + ',"pad":"' + String(i * 7919) + '"}\n'
    return b^


def test_parallel_reports_absolute_line() raises:
    print("T6: the parallel materializer names the line in the file")
    var n_rows = 150000
    var bad_row = 140000
    var text = _big_input(n_rows, bad_row, String("[140000]"))
    var b = _bytes_of(text)
    assert_true(len(b) > 4 * 1024 * 1024)
    var refused = False
    var msg = String()
    try:
        var batch = materialize_jsonl_to_batch_parallel(Span(b), _schema_a(), 8)
        _ = batch^
    except e:
        refused = True
        msg = String(e)
    assert_true(refused, "parallel: a non-object line was not refused")
    var want = String("line ") + String(bad_row + 1) + ":"
    assert_true(want in msg, "parallel: wrong line: " + msg)
    print("  refused ->", msg)
    # Control: the same file without the bad line reads every row.
    var ok = _bytes_of(_big_input(n_rows, -1, String("")))
    var batch = materialize_jsonl_to_batch_parallel(Span(ok), _schema_a(), 8)
    assert_equal(batch._num_rows, n_rows)


def _write_file(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _expect_stream_refused(label: String, path: String, line: Int) raises:
    var refused = False
    var msg = String()
    try:
        var batch = read_jsonl_streamed_to_one_batch(path, _schema_a(), 256)
        _ = batch^
    except e:
        refused = True
        msg = String(e)
    assert_true(refused, label + ": not refused")
    var want = String("line ") + String(line) + ":"
    assert_true(want in msg, label + ": wrong line: " + msg)
    print("  refused", label, "->", msg)


def test_streaming_reports_absolute_line() raises:
    print("T7: the streaming reader names the line in the file")
    var dir = test_tmpdir()
    var p1 = dir + "/bad_mid.jsonl"
    _write_file(p1, _big_input(1000, 776, String("null")))
    _expect_stream_refused("bad line 777 of 1000", p1, 777)
    var p2 = dir + "/bad_tail.jsonl"
    _write_file(p2, _big_input(300, -1, String("")) + '{"a":1,}')
    _expect_stream_refused("bad unterminated last line 301", p2, 301)
    # Control: a good file streams every row.
    var p3 = dir + "/good.jsonl"
    _write_file(p3, _big_input(1000, -1, String("")))
    var batch = read_jsonl_streamed_to_one_batch(p3, _schema_a(), 256)
    assert_equal(batch._num_rows, 1000)


def main() raises:
    print("test_jsonl_line_validation")
    # Every test runs, so one red build shows each failing case.
    var failed = 0
    try:
        test_non_object_line_mid_file()
    except e:
        print("FAIL T1:", e)
        failed += 1
    try:
        test_top_level_scalar_lines()
    except e:
        print("FAIL T2:", e)
        failed += 1
    try:
        test_invalid_json_lines()
    except e:
        print("FAIL T3:", e)
        failed += 1
    try:
        test_duplicate_key_refused()
    except e:
        print("FAIL T4:", e)
        failed += 1
    try:
        test_valid_objects_still_read()
    except e:
        print("FAIL T5:", e)
        failed += 1
    try:
        test_parallel_reports_absolute_line()
    except e:
        print("FAIL T6:", e)
        failed += 1
    try:
        test_streaming_reports_absolute_line()
    except e:
        print("FAIL T7:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("test_jsonl_line_validation: PASSED")
