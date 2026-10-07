# =============================================================================
# Integer limits and IEEE-754 edge values through JSONL and CSV: the exact
# text written, then the values read back, compared bit-exactly.
# =============================================================================
#
# Dataset: `edge_numerics.mojo`. Expected text is spelled here by hand
# (`int64_edge_text`, `int32_edge_text`, `float_edge_text`): the shortest
# decimal that reads back to the same double under round-to-nearest-even
# (17 significant digits where that is what it takes: 0.30000000000000004,
# 1.0000000000000002, 2.2250738585072014e-308, 1.7976931348623157e+308).
#
# What the specs say about the values a text format cannot hold:
#   JSON (RFC 8259 section 6): "Numeric values that cannot be represented in
#     the grammar below (such as Infinity and NaN) are not permitted." The
#     JSONL writer documents NaN/+Inf/-Inf -> `null` (json_writer.mojo,
#     write_f64_dtoa) in a nullable column. That is komira's choice, not the
#     RFC's (which only forbids the tokens). In a NOT NULL column the writer
#     refuses them instead, and the reader refuses `null` in a NOT NULL
#     field (both asserted below). The reader validates each line
#     against the RFC 8259 grammar (line_check.mojo, check_jsonl_lines)
#     before any value parser runs, so `NaN`, `Infinity`, `+1`, `01` and the
#     like are refused there with "the line is not valid JSON: ..."; each
#     refusal is asserted by that error text. (parse_float_f64 on its own is
#     more lenient than its header says -- it takes a leading `+` and
#     leading zeros -- but the validator keeps those bytes from reaching it.)
#   CSV (RFC 4180) defines no number syntax. CsvSink documents FLOAT64 as
#     Mojo `String(f)`, which spells the non-finite values `inf`, `-inf` and
#     `nan` (every NaN, whatever its sign or payload); asserted here.
#
# What each test proves, and the defect it catches:
#   * test_jsonl_edge_bytes -- the exact JSONL lines: INT64_MIN/MAX and
#     +-(2^53+1) as integers (no exponent, no `.0`), -0.0 with its sign, the
#     subnormals and DBL_MAX in exponent form, 17 significant digits where
#     they are needed, `null` for every NaN and both infinities (the column
#     declared nullable). The same values in the dataset's NOT NULL column
#     are refused at row 8 (+Inf), with the writer's message. Catches a
#     formatter that drops the 17th digit (planted, seen red), drops the sign
#     of -0.0, writes `NaN`/`Infinity` (not JSON), or writes `null` into a
#     NOT NULL column.
#   * test_jsonl_edge_readback -- materialize_jsonl_to_batch returns every
#     integer exactly (2^53+1 does not go through a double) and every finite
#     float bit-exactly; the non-finite rows come back NULL with the column
#     declared nullable, and reading the same lines with the column NOT NULL
#     is refused at line 9 (the first `null`) with the reader's message.
#   * test_jsonl_reader_spellings -- hand-written JSON the writer never
#     produces. Refused by the line validator, each with its message:
#     `NaN`, `Infinity`, `-Infinity`, `nan`, `.5`, `5.`, `1e`, `-`, `+1`,
#     `+1.5` (FLOAT64) and `+1` (INT64) as "expected a value, found 'c'";
#     `01`, `-01.5` (FLOAT64) and `01` (INT64) as "unexpected '1'". A line
#     that is accepted, or refused with another message, is a mismatch.
#     Read exactly: `-0` and `-0.0` as -0.0,
#     `1E2`, `1e+2`, `5e-1`, two 17-digit values, `4.9e-324` as the smallest
#     subnormal, DBL_MAX, `1e400`, `1e18446744073709551616` (2^64) and
#     `1e999999999` as +Inf, and `1e-400` as +0.0 (the round-to-nearest
#     results; RFC 8259 section 9 lets a parser limit range, and these are
#     the IEEE answers).
#   * test_csv_edge_bytes -- the exact CsvSink lines for the same values.
#   * test_csv_edge_readback -- read_csv_bytes_to_batch, column declared
#     FLOAT64, returns the finite floats it can parse bit-exactly (including
#     +-5e-324 and -0.0) and NULL for the `inf`/`-inf`/`nan` rows (see
#     _CSV_NONFINITE_ROWS); the integer file (types inferred as INT64)
#     returns every integer exactly, INT64_MIN included.
#
# Planted mutants seen red here on the farm (product code, reverted):
#   * JSONL write_f64_dtoa dropping the last digit of a 17-digit mantissa:
#     lines 5, 6, 7, 13, 14 differ and rows 13, 14 read back as 0.3 and
#     1.0. komira_jsonl's own test_dtoa_parity also catches it; it was
#     taken out of komira_jsonl's test_srcs for that one run only.
#   * CsvSink (FLOAT64, no NULLs) dropping the same digit: CSV lines 6, 7,
#     8, 14, 15 differ and rows 13, 14 read back as 0.3 and 1.0; no
#     komira_csv test caught it.
#   * line_check _scalar_end accepting a leading `+`: `+1`, `+1.5` (FLOAT64)
#     and `+1` (INT64) are accepted (1 row each). komira_jsonl's own
#     test_jsonl_line_check_branches also catches it; it was taken out of
#     komira_jsonl's test_srcs for that one run only.
#   * CSV reader storing 0.0 instead of NULL for an unparsable FLOAT64
#     cell: rows 8..12 read back 0x0 where NULL is pinned; no komira_csv
#     test caught it.
#
# KNOWN DEFECTS. The spec-correct expectation stays in `float_edge_text` /
# `float_edge_bits`, and the row is held out of that check by name below;
# the OBSERVED wrong output is pinned instead, under a `KNOWN-DEFECT` label,
# so any change to these rows goes red: a fix (then move the row back to the
# spec expectation) as well as a further regression.
#   _FMT_MIDPOINT_ROWS: 2^54+4 (0x4350000000000001) is written by both the
#     JSONL writer and CsvSink as `1.801439850948199e+16`, i.e.
#     18014398509481990, the exact midpoint between 2^54+4 and 2^54+8; under
#     round-half-even it reads back as 2^54+8. The shortest round-trip text
#     is `1.8014398509481988e+16`. Pinned: the line text, and the read-back
#     bits (JSONL 0x4350000000000002, CSV 0x4350000000000003).
#   _JSONL_PARSE_ROWS: only the midpoint row above (its text is the
#     writer's defect; parse_float_f64 rounds it correctly). Pinned.
#   _CSV_PARSE_ROWS: _try_parse_float64 does the same with a per-digit
#     fraction sum: the largest subnormal and DBL_MIN read as
#     0x0010000000000003, DBL_MAX as 0x7FEFFFFFFFFFFFF9. Pinned.
#   _CSV_NONFINITE_ROWS: CsvSink writes `inf`, `-inf`, `nan`; the reader
#     parses none of them, so a column declared FLOAT64 reads each as NULL
#     (asserted) and type inference makes the column STRING (not asserted).
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.csv_sink import CsvSink
from komira_csv.reader import read_csv_bytes_to_batch
from komira_fs.local_fs import LocalFs
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.json_writer import write_batch_jsonl_direct
from komira_runtime_paths import test_tmpdir

from komira_formats_e2e import (
    F_NAN,
    F_NAN_PAYLOAD,
    F_NEG_INF,
    F_NEG_NAN,
    F_POS_INF,
    Mismatches,
    bits_of,
    check_bytes,
    check_float_column_bits,
    check_int_column,
    float_edge_batch,
    float_edge_bits,
    f64_of,
    float_edge_text,
    hex_u64,
    int32_edge_text,
    int64_edge_text,
    int64_edges,
    int_edge_batch,
    is_finite_row,
)


comptime _Fs = LocalFs[NoopSink]


def _fmt_midpoint_rows() -> List[Int]:
    return [15]


def _jsonl_parse_rows() -> List[Int]:
    return [15]


def _csv_parse_rows() -> List[Int]:
    return [4, 5, 6, 7, 15]


def _pin(
    rows: List[Int], bits: List[UInt64]
) -> Tuple[List[Optional[UInt64]], List[Int]]:
    """(want, skip) for check_float_column_bits that compares only `rows`,
    each against the OBSERVED wrong bits `bits[i]` (a KNOWN-DEFECT pin)."""
    var n = len(float_edge_bits())
    var want = List[Optional[UInt64]]()
    var skip = List[Int]()
    for r in range(n):
        var k = -1
        for i in range(len(rows)):
            if rows[i] == r:
                k = i
        if k >= 0:
            want.append(Optional[UInt64](bits[k]))
        else:
            want.append(Optional[UInt64](None))
            skip.append(r)
    return (want^, skip^)


comptime _MIDPOINT_TEXT = "1.801439850948199e+16"


def _jsonl_parse_observed() -> List[UInt64]:
    """What the JSONL reader returns for _jsonl_parse_rows (same order)."""
    return [UInt64(0x4350000000000002)]


def _csv_parse_observed() -> List[UInt64]:
    """What the CSV reader returns for _csv_parse_rows (same order)."""
    return [
        UInt64(0x0010000000000003),
        UInt64(0x0010000000000003),
        UInt64(0x7FEFFFFFFFFFFFF9),
        UInt64(0xFFEFFFFFFFFFFFF9),
        UInt64(0x4350000000000003),
    ]


def _int32_as_int64() -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(-2147483648))
    out.append(Int64(2147483647))
    out.append(Int64(-1))
    out.append(Int64(0))
    out.append(Int64(16777217))
    out.append(Int64(-16777217))
    return out^


def _finite_or_null() -> List[Optional[UInt64]]:
    """Each float row's bits, or None (NULL) for the non-finite rows."""
    var bits = float_edge_bits()
    var out = List[Optional[UInt64]]()
    for r in range(len(bits)):
        if is_finite_row(r):
            out.append(Optional[UInt64](bits[r]))
        else:
            out.append(Optional[UInt64](None))
    return out^


def _lines(bs: Span[UInt8, _]) -> List[Tuple[Int, Int]]:
    """(start, end) of each LF-terminated line; a trailing fragment without
    LF is a line too."""
    var out = List[Tuple[Int, Int]]()
    var s = 0
    for i in range(len(bs)):
        if bs[i] == 0x0A:
            out.append((s, i))
            s = i + 1
    if s < len(bs):
        out.append((s, len(bs)))
    return out^


def _check_lines(
    mut m: Mismatches,
    got: Span[UInt8, _],
    want: List[String],
    skip: List[Int],
    label: String,
):
    """`got` is exactly `len(want)` LF-terminated lines; line i equals
    want[i] unless i is in `skip`."""
    var gl = _lines(got)
    if len(got) == 0 or got[len(got) - 1] != 0x0A:
        m.add(label + ": the last line is not LF-terminated")
    if len(gl) != len(want):
        m.add(label + ": " + String(len(gl)) + " lines, want " + String(len(want)))
        return
    for i in range(len(want)):
        if i in skip:
            continue
        check_bytes(
            m, got[gl[i][0] : gl[i][1]], want[i].as_bytes(),
            label + " line " + String(i),
        )


# =============================================================================
# JSONL.
# =============================================================================


def _nullable_float_edge_batch() raises -> RecordBatch:
    """The `float_edge_bits` rows in a NULLABLE FLOAT64 column `f64` (no
    NULL cell): the JSONL writer spells NaN/+-Inf `null` only there."""
    var bits = float_edge_bits()
    var f = PrimitiveArray[DType.float64].allocate_nullable(len(bits))
    for r in range(len(bits)):
        f.set(r, f64_of(bits[r]))
    var sb = SchemaBuilder()
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(Column.from_primitive[DType.float64](f^))
    return builder.build(sb.build())


comptime _NOT_NULL_WRITE_ERR = (
    "json_writer: column 'f64' is NOT NULL and row 8 holds +Inf, which JSON"
    " cannot spell (RFC 8259 section 6); only a nullable column writes it as"
    " null"
)
comptime _NOT_NULL_READ_ERR = (
    "komira_jsonl: line 9: NOT NULL field 'f64' holds JSON null"
)


def _jsonl_int_want() -> List[String]:
    var a = int64_edge_text()
    var b = int32_edge_text()
    var out = List[String]()
    for r in range(len(a)):
        out.append('{"i64":' + a[r] + ',"i32":' + b[r] + "}")
    return out^


def _jsonl_float_want() -> List[String]:
    var t = float_edge_text()
    var out = List[String]()
    for r in range(len(t)):
        var tok = String(t[r]) if is_finite_row(r) else String("null")
        out.append('{"f64":' + tok + "}")
    return out^


def test_jsonl_edge_bytes() raises:
    var m = Mismatches()
    var ib = List[UInt8]()
    write_batch_jsonl_direct(ib, int_edge_batch())
    _check_lines(m, Span(ib), _jsonl_int_want(), List[Int](), "jsonl int")
    var fb = List[UInt8]()
    write_batch_jsonl_direct(fb, _nullable_float_edge_batch())
    _check_lines(m, Span(fb), _jsonl_float_want(), _fmt_midpoint_rows(), "jsonl f64")
    # KNOWN-DEFECT pin: the midpoint row as written today.
    var pinned = _jsonl_float_want()
    var mid = _fmt_midpoint_rows()
    var others = List[Int]()
    for r in range(len(pinned)):
        if r in mid:
            pinned[r] = '{"f64":' + String(_MIDPOINT_TEXT) + "}"
        else:
            others.append(r)
    _check_lines(m, Span(fb), pinned, others, "jsonl f64 KNOWN-DEFECT")
    # The dataset's own NOT NULL column: refused at the first non-finite row.
    var nb = List[UInt8]()
    var err = String("")
    try:
        write_batch_jsonl_direct(nb, float_edge_batch())
    except e:
        err = String(e)
    if err != String(_NOT_NULL_WRITE_ERR):
        m.add("jsonl NOT NULL write: got error '" + err + "', want '" + String(_NOT_NULL_WRITE_ERR) + "'")
    m.raise_if_any("test_jsonl_edge_bytes")


def test_jsonl_edge_readback() raises:
    var m = Mismatches()
    var ib = List[UInt8]()
    write_batch_jsonl_direct(ib, int_edge_batch())
    var isb = SchemaBuilder()
    isb.add_field(Field("i64", ArrowType.INT64, True))
    isb.add_field(Field("i32", ArrowType.INT64, True))
    var ir = materialize_jsonl_to_batch(Span(ib), isb.build())
    check_int_column(m, ir, "i64", int64_edges(), "jsonl")
    check_int_column(m, ir, "i32", _int32_as_int64(), "jsonl")

    var fb = List[UInt8]()
    write_batch_jsonl_direct(fb, _nullable_float_edge_batch())
    var fsb = SchemaBuilder()
    fsb.add_field(Field("f64", ArrowType.FLOAT64, True))
    var fr = materialize_jsonl_to_batch(Span(fb), fsb.build())
    check_float_column_bits(
        m, fr, "f64", _finite_or_null(), "jsonl", _jsonl_parse_rows()
    )
    var pin = _pin(_jsonl_parse_rows(), _jsonl_parse_observed())
    check_float_column_bits(m, fr, "f64", pin[0], "jsonl KNOWN-DEFECT", pin[1])

    # The same lines read with the dataset's schema (f64 NOT NULL): the
    # first `null` (row 8, line 9) is refused, so no NOT NULL column comes
    # back holding NULLs.
    var nn = float_edge_batch().schema.copy()
    var err = String("")
    var rows = -1
    try:
        var nr = materialize_jsonl_to_batch(Span(fb), nn^)
        rows = nr.num_rows()
    except e:
        err = String(e)
    if err != String(_NOT_NULL_READ_ERR):
        m.add(
            "jsonl NOT NULL read: got error '" + err + "' (" + String(rows)
            + " rows), want '" + String(_NOT_NULL_READ_ERR) + "'"
        )
    m.raise_if_any("test_jsonl_edge_readback")


def _jsonl_one(text: String) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    return materialize_jsonl_to_batch(text.as_bytes(), sb.build())


def _expect_refused(
    mut m: Mismatches, text: String, col: String, ty: ArrowType, why: String
):
    """Reading `{"<col>":<text>}` raises an error whose text contains `why`
    (the parser's message for the grammar rule `text` breaks). Only the read
    is inside the try, so a returned batch is reported with its row count."""
    var sb = SchemaBuilder()
    sb.add_field(Field(col, ty, True))
    var line = '{"' + col + '":' + text + "}\n"
    var rows = -1
    try:
        var b = materialize_jsonl_to_batch(line.as_bytes(), sb.build())
        rows = b.num_rows()
    except e:
        var msg = String(e)
        if why not in msg:
            m.add("jsonl " + text + ": refused for another reason: " + msg)
        return
    m.add(
        "jsonl " + text + ": accepted (" + String(rows)
        + " rows); RFC 8259 grammar refuses it"
    )


def _expect_f64(mut m: Mismatches, text: String, want: UInt64, label: String):
    var b: RecordBatch
    try:
        b = _jsonl_one('{"f64":' + text + "}\n")
    except e:
        m.add(label + " " + text + ": raised " + String(e))
        return
    try:
        var c = b.column_as_primitive_float64(0)
        if b.num_rows() != 1:
            m.add(label + " " + text + ": " + String(b.num_rows()) + " rows")
        elif c.is_null(0):
            m.add(label + " " + text + ": NULL")
        elif bits_of(c.get(0)) != want:
            m.add(
                label + " " + text + ": got " + hex_u64(bits_of(c.get(0)))
                + " (" + String(c.get(0)) + ") want " + hex_u64(want)
            )
    except e:
        m.add(label + " " + text + ": column access raised " + String(e))


def test_jsonl_reader_spellings() raises:
    var m = Mismatches()
    comptime BAD = "the line is not valid JSON: "
    comptime EXP = BAD + "expected a value, found "
    comptime UNX = BAD + "unexpected '1'"
    var refused = [
        String("NaN"), String("Infinity"), String("-Infinity"), String("nan"),
        String(".5"), String("5."), String("1e"), String("-"),
        String("+1"), String("+1.5"), String("01"), String("-01.5"),
    ]
    var why = [
        String(EXP) + "'N'", String(EXP) + "'I'", String(EXP) + "'-'",
        String(EXP) + "'n'", String(EXP) + "'.'", String(EXP) + "'5'",
        String(EXP) + "'1'", String(EXP) + "'-'", String(EXP) + "'+'",
        String(EXP) + "'+'", String(UNX), String(UNX),
    ]
    for i in range(len(refused)):
        _expect_refused(m, refused[i], "f64", ArrowType.FLOAT64, why[i])
    _expect_refused(m, "+1", "i64", ArrowType.INT64, String(EXP) + "'+'")
    _expect_refused(m, "01", "i64", ArrowType.INT64, String(UNX))
    # Spellings with an exactly known double.
    var spellings = [
        String("-0"),
        String("-0.0"),
        String("1E2"),
        String("1e+2"),
        String("5e-1"),
        String("0.30000000000000004"),
        String("1.0000000000000002"),
        String("4.9e-324"),
        String("1.7976931348623157e308"),
        String("1e400"),
        String("-1e400"),
        String("1e-400"),
        String("1e18446744073709551616"),
        String("1e999999999"),
    ]
    var want = [
        UInt64(0x8000000000000000),
        UInt64(0x8000000000000000),
        UInt64(0x4059000000000000),
        UInt64(0x4059000000000000),
        UInt64(0x3FE0000000000000),
        UInt64(0x3FD3333333333334),
        UInt64(0x3FF0000000000001),
        UInt64(0x0000000000000001),
        UInt64(0x7FEFFFFFFFFFFFFF),
        UInt64(0x7FF0000000000000),
        UInt64(0xFFF0000000000000),
        UInt64(0x0000000000000000),
        UInt64(0x7FF0000000000000),
        UInt64(0x7FF0000000000000),
    ]
    for i in range(len(spellings)):
        _expect_f64(m, spellings[i], want[i], "jsonl")
    m.raise_if_any("test_jsonl_reader_spellings")


# =============================================================================
# CSV.
# =============================================================================


def _csv_write(var rb: RecordBatch, name: String) raises -> List[UInt8]:
    var path = test_tmpdir() + "/" + name
    var schema = rb.schema.copy()
    var sink = CsvSink(path)
    sink.init_sink(schema)
    sink.accept_batch(rb^)
    sink.finish()
    var fs = _Fs.new()
    var buf = fs.read_whole(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    var out = List[UInt8]()
    for i in range(len(span)):
        out.append(span[i])
    return out^


def _csv_float_token(r: Int) -> String:
    """CsvSink's documented spelling: Mojo `String(f)`."""
    if r == F_POS_INF:
        return String("inf")
    if r == F_NEG_INF:
        return String("-inf")
    if r == F_NAN or r == F_NAN_PAYLOAD or r == F_NEG_NAN:
        return String("nan")
    return String(float_edge_text()[r])


def test_csv_edge_bytes() raises:
    var m = Mismatches()
    var a = int64_edge_text()
    var b = int32_edge_text()
    var iw = List[String]()
    iw.append(String("i64,i32"))
    for r in range(len(a)):
        iw.append(a[r] + "," + b[r])
    var ib = _csv_write(int_edge_batch(), "edge_int.csv")
    _check_lines(m, Span(ib), iw, List[Int](), "csv int")

    var fw = List[String]()
    fw.append(String("f64"))
    var skip = List[Int]()
    var mid = _fmt_midpoint_rows()
    for r in range(len(float_edge_bits())):
        fw.append(_csv_float_token(r))
    for i in range(len(mid)):
        skip.append(mid[i] + 1)  # +1: the header is line 0
    var fb = _csv_write(float_edge_batch(), "edge_f64.csv")
    _check_lines(m, Span(fb), fw, skip, "csv f64")
    # KNOWN-DEFECT pin: the midpoint row as written today.
    var others = List[Int]()
    for i in range(len(fw)):
        if i in skip:
            fw[i] = String(_MIDPOINT_TEXT)
        else:
            others.append(i)
    _check_lines(m, Span(fb), fw, others, "csv f64 KNOWN-DEFECT")
    m.raise_if_any("test_csv_edge_bytes")


def test_csv_edge_readback() raises:
    var m = Mismatches()
    var ib = _csv_write(int_edge_batch(), "edge_int_rb.csv")
    var ir = read_csv_bytes_to_batch[Rfc4180](Span(ib), CsvReadOptions())
    check_int_column(m, ir, "i64", int64_edges(), "csv")
    check_int_column(m, ir, "i32", _int32_as_int64(), "csv")

    var fb = _csv_write(float_edge_batch(), "edge_f64_rb.csv")
    var opts = CsvReadOptions()
    opts.declared_column_types = [ArrowType.FLOAT64]
    var fr = read_csv_bytes_to_batch[Rfc4180](Span(fb), opts)
    # The non-finite rows are compared: _finite_or_null wants NULL there.
    check_float_column_bits(
        m, fr, "f64", _finite_or_null(), "csv", _csv_parse_rows()
    )
    var pin = _pin(_csv_parse_rows(), _csv_parse_observed())
    check_float_column_bits(m, fr, "f64", pin[0], "csv KNOWN-DEFECT", pin[1])
    m.raise_if_any("test_csv_edge_readback")


def main() raises:
    var failures = List[String]()
    try:
        test_jsonl_edge_bytes()
    except e:
        failures.append(String(e))
    try:
        test_jsonl_edge_readback()
    except e:
        failures.append(String(e))
    try:
        test_jsonl_reader_spellings()
    except e:
        failures.append(String(e))
    try:
        test_csv_edge_bytes()
    except e:
        failures.append(String(e))
    try:
        test_csv_edge_readback()
    except e:
        failures.append(String(e))
    if len(failures) > 0:
        var msg = String("test_formats_edge_text FAILED:")
        for i in range(len(failures)):
            msg += "\n" + failures[i]
        raise Error(msg)
    print("test_formats_edge_text: ALL PASS")
