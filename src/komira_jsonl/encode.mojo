# =============================================================================
# encode — JSONL writer + per-type emit helpers
# =============================================================================
#
# Public surface:
#
#   - `fn write_record[T: JsonCompatible](mut buf: List[UInt8], rec: T) raises`
#       — append `rec.to_json()` + `\n` to `buf`. NEWLINE-DELIMITED JSON
#       (JSONL) framing: one record per line, trailing `\n` on EVERY line
#       (including the last record — matches yyjson / DuckDB convention;
#       simplifies append-mode). Buf is built up across many calls; flush
#       to disk via FileHandle.write at the caller's discretion.
#
#   - `fn _emit_string_escaped(s: String) -> String`
#       — RFC 8259 §7 string escaping: `"`, `\\`, control chars (< 0x20)
#       become `\\<u-escape>`. Wraps in `"..."`. Conformer `to_json`
#       bodies call this for String fields.
#
#   - `fn _emit_int(v: Int) -> String`
#   - `fn _emit_float64(v: Float64) -> String`
#       — Float64 NaN / +Inf / -Inf serialize as `null` (RFC 8259 §6
#         disallows non-finite floats).
#   - `fn check_float_column_writable[dt](arr, row_start, row_end, schema,
#     col_index) raises`, `fn not_null_nonfinite_error(column, row, v)`
#       — a NOT NULL float column cannot take that `null`: every batch
#         writer here and in `json_writer` refuses NaN / +-Inf in one,
#         naming the column, the row and the value.
#   - `fn _emit_bool(v: Bool) -> String`
#   - `fn _emit_optional_int(v: Optional[Int]) -> String`
#   - `fn _emit_optional_string(v: Optional[String]) -> String`
#   - `fn _emit_optional_float64(v: Optional[Float64]) -> String`
#   - `fn _emit_optional_bool(v: Optional[Bool]) -> String`
#       — Optional[T] is the canonical nullable-cell carrier; None -> `null`.
#
# Encapsulation: no UnsafePointer in any signature. The List[UInt8] buf
# input is mutated by append-byte; the String emit helpers return
# fresh-owned String. String is heap-backed; for very-hot per-record
# loops a variant could emit straight into a `List[UInt8]` without the
# intermediate String, but the trait body is kept simple (the CSV emitter
# has the same shape).
# =============================================================================

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_jsonl.json_compatible import JsonCompatible


# =============================================================================
# Float NaN / Inf detection
# =============================================================================
#
# RFC 8259 §6 disallows non-finite floats in JSON. The convention used by
# DuckDB, pyarrow, and yyjson is to serialize as `null`. We mirror that.
#
# The std distribution is not relied on for `math.isnan` / `math.isinf`;
# a bit-pattern check via
# IEEE 754 sign+exponent+mantissa is the portable shape.


@always_inline
def _is_nan_f64(v: Float64) -> Bool:
    """IEEE 754: NaN iff exponent = all-1 and mantissa != 0."""
    var bits = UInt64(bitcast[DType.uint64, 1](v))
    var exp = (bits >> UInt64(52)) & UInt64(0x7FF)
    var mant = bits & UInt64(0xFFFFFFFFFFFFF)
    return exp == UInt64(0x7FF) and mant != UInt64(0)


@always_inline
def _is_inf_f64(v: Float64) -> Bool:
    """IEEE 754: +/-Inf iff exponent = all-1 and mantissa == 0."""
    var bits = UInt64(bitcast[DType.uint64, 1](v))
    var exp = (bits >> UInt64(52)) & UInt64(0x7FF)
    var mant = bits & UInt64(0xFFFFFFFFFFFFF)
    return exp == UInt64(0x7FF) and mant == UInt64(0)


# =============================================================================
# NOT NULL float columns: NaN / +-Inf have no JSON spelling but `null`
# =============================================================================
#
# A nullable column writes them as `null` (above). A NOT NULL column cannot
# hold a null, so a writer that met one would write a file whose reader
# must either refuse it or return a NULL in a NOT NULL field: the writers
# refuse instead, before the cell is written.


def not_null_nonfinite_error(column: String, row: Int, v: Float64) -> Error:
    """The error for NaN / +Inf / -Inf `v` at `row` of NOT NULL `column`."""
    var what: String
    if _is_nan_f64(v):
        what = "NaN"
    elif v > 0:
        what = "+Inf"
    else:
        what = "-Inf"
    return Error(
        "json_writer: column '" + column + "' is NOT NULL and row "
        + String(row) + " holds " + what
        + ", which JSON cannot spell (RFC 8259 section 6); only a nullable"
        + " column writes it as null"
    )


def check_float_column_writable[
    dt: DType
](
    arr: PrimitiveArray[dt],
    row_start: Int,
    row_end: Int,
    schema: Schema,
    col_index: Int,
) raises:
    """Raise `not_null_nonfinite_error` for the first NaN / +-Inf in rows
    `[row_start, row_end)` of float column `col_index` when its field is
    NOT NULL; a nullable field returns at once. Row numbers are the
    batch's (not relative to `row_start`)."""
    if schema.field_nullable(col_index):
        return
    for r in range(row_start, row_end):
        if arr.is_null(r):
            continue
        var v = arr.get(r).cast[DType.float64]()
        if _is_nan_f64(v) or _is_inf_f64(v):
            raise not_null_nonfinite_error(
                String(schema.field_name(col_index)), r, v
            )


# =============================================================================
# Per-type emit helpers
# =============================================================================


def _emit_string_escaped(s: String) -> String:
    """RFC 8259 §7 string escape: wrap in `"..."`, escape `"` `\\` and
    control chars (< 0x20) via `\\u00XX`. `\\n`/`\\r`/`\\t`/`\\b`/`\\f`
    take their two-char form.

    Conformer `to_json` bodies call this for any String field.

    Operates at the BYTE level: the input String's raw UTF-8 bytes are
    iterated via `s.as_bytes()` and accumulated into a `List[UInt8]`. The
    pass-through (else) branch appends the RAW byte `b` verbatim — it does
    NOT round-trip through `s[byte=i]` (which codepoint-promotes the byte
    to U+00XX and re-UTF-8-encodes any byte >= 0x80 into 2 bytes, the
    double-encode bug). ASCII escape sequences are emitted as their
    literal bytes. Matches the already-correct byte idiom in
    `write_record` below. The final `String(unsafe_from_utf8=buf)` hands
    the accumulated bytes back unchanged.
    """
    var buf = List[UInt8]()
    buf.append(UInt8(0x22))  # opening "
    var src = s.as_bytes()
    var n = len(src)
    for i in range(n):
        var b = src[i]
        if b == UInt8(0x22):  # "  ->  \"
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x22))
        elif b == UInt8(0x5C):  # backslash  ->  \\
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x5C))
        elif b == UInt8(0x0A):  # \n
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x6E))  # 'n'
        elif b == UInt8(0x0D):  # \r
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x72))  # 'r'
        elif b == UInt8(0x09):  # \t
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x74))  # 't'
        elif b == UInt8(0x08):  # \b
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x62))  # 'b'
        elif b == UInt8(0x0C):  # \f
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x66))  # 'f'
        elif b < UInt8(0x20):
            # Other control chars -> \u00XX.
            buf.append(UInt8(0x5C))  # backslash
            buf.append(UInt8(0x75))  # 'u'
            buf.append(UInt8(0x30))  # '0'
            buf.append(UInt8(0x30))  # '0'
            buf.append(_nibble_hex_byte((b >> UInt8(4)) & UInt8(0xF)))
            buf.append(_nibble_hex_byte(b & UInt8(0xF)))
        else:
            # Pass-through: append the RAW byte verbatim. For any byte
            # >= 0x80 (every continuation / lead byte of a multi-byte
            # UTF-8 char) this preserves the encoding exactly. ASCII
            # printables (>= 0x20, not the escapes above) also fall here.
            buf.append(b)
    buf.append(UInt8(0x22))  # closing "
    return String(unsafe_from_utf8=buf)


@always_inline
def _nibble_hex_lower(n: UInt8) -> String:
    """0..15 -> "0".."9","a".."f"."""
    if n < UInt8(10):
        return chr(Int(UInt8(0x30) + n))
    return chr(Int(UInt8(0x61) + (n - UInt8(10))))


@always_inline
def _nibble_hex_byte(n: UInt8) -> UInt8:
    """0..15 -> ASCII byte '0'..'9','a'..'f' (raw byte form for the
    List[UInt8] buffer in `_emit_string_escaped`)."""
    if n < UInt8(10):
        return UInt8(0x30) + n
    return UInt8(0x61) + (n - UInt8(10))


def _emit_int(v: Int) -> String:
    """Plain integer rendering (matches `String(v)`)."""
    return String(v)


def _emit_int64(v: Int64) -> String:
    return String(v)


def _emit_float64(v: Float64) -> String:
    """Float64 rendering. NaN / +Inf / -Inf -> `null` per RFC 8259 §6."""
    if _is_nan_f64(v) or _is_inf_f64(v):
        return String("null")
    return String(v)


def _emit_bool(v: Bool) -> String:
    if v:
        return String("true")
    return String("false")


def _emit_optional_int(v: Optional[Int]) -> String:
    if v.__bool__():
        return _emit_int(v.value())
    return String("null")


def _emit_optional_int64(v: Optional[Int64]) -> String:
    if v.__bool__():
        return _emit_int64(v.value())
    return String("null")


def _emit_optional_float64(v: Optional[Float64]) -> String:
    if v.__bool__():
        return _emit_float64(v.value())
    return String("null")


def _emit_optional_bool(v: Optional[Bool]) -> String:
    if v.__bool__():
        return _emit_bool(v.value())
    return String("null")


def _emit_optional_string(v: Optional[String]) -> String:
    if v.__bool__():
        return _emit_string_escaped(v.value())
    return String("null")


# =============================================================================
# Public surface: write_record / write_record_into
# =============================================================================


def write_record[T: JsonCompatible](mut buf: List[UInt8], rec: T) raises:
    """Append `rec`'s JSONL encoding to `buf` — one line plus trailing
    `\\n`.

    JSONL framing: each record occupies one line; trailing `\\n` on
    EVERY line including the last (yyjson / DuckDB / pyarrow convention).
    A caller doing N writes builds a buffer of N JSON objects each
    followed by `\\n`; flushing this directly to a FileHandle produces a
    spec-conforming JSONL file.

    Parameters:
      - T: any conformer of `JsonCompatible`. Conformer's `to_json` body
        is the source of truth for record shape.

    Args:
      buf: target buffer; bytes appended in-place. Caller owns the buf
           lifecycle.
      rec: the record to encode. Borrowed.
    """
    var s = rec.to_json()
    buf.extend(Span(s.as_bytes()))
    buf.append(UInt8(0x0A))  # '\n'


def write_records_into[T: JsonCompatible](
    mut buf: List[UInt8], recs: List[T]
) raises:
    """Bulk-encode a list of records to `buf`. Iterates `write_record`.

    Used by the JSONL format sink after the per-row inline-struct
    materialization; the row loop hands each row to this fn.
    """
    var n = len(recs)
    for i in range(n):
        write_record[T](buf, recs[i])


# =============================================================================
# RecordBatch -> JSONL (Arrow-typed-row JSONL emission)
# =============================================================================
#
# The trait-level `write_record[T: JsonCompatible]` is for the inline-struct
# / SDK-typed-row path. The JSONL format sink operates on the more general
# `RecordBatch`-shaped flow — it receives a stream of batches from the
# executor and must emit each row as a JSON object keyed by column name.
# This mirrors the CSV sink's column-major-then-transpose shape —
# pre-materialize each column into per-row String cells, then row-emit by
# iterating those columns in transpose.
#
# Why this lives here rather than in the sink: keeping the JSON-emit logic
# in `komira_jsonl` lets the column encoder grow (e.g. INT128 / Variant /
# TimestampWithTimezone) without touching the SDK package. The sink arm is
# a short delegator.


def _format_column_cells_json(
    batch: RecordBatch, col_index: Int
) raises -> List[String]:
    """Materialize column `col_index` of `batch` into a per-row list of
    JSON-emit-ready cell strings. NULL -> `"null"` (JSON literal, NOT
    the empty string CSV uses).

    Edge cases:
      - String/LargeString/Dictionary: escape via `_emit_string_escaped`.
      - Float NaN/Inf: -> `"null"`; refused in a NOT NULL column
        (`check_float_column_writable`).
      - Bool: `"true"` / `"false"`.
      - Decimal128: emit as JSON number via `get_as_float` (lossy for >15
        sig. digits; an exact form would route through a JSON string
        literal `"<digits>"`).
      - NULL-typed column: every cell is `"null"`.

    Mirrors the CSV sink's per-column cell lattice. Uses
    `_emit_string_escaped` for the String / LargeString / Dictionary
    arms (RFC 8259 escape vs CSV RFC-4180 quoting).
    """
    var num_rows = batch.num_rows()
    var out = List[String]()
    out.reserve(num_rows)
    ref col_ref = batch.column_at(col_index)
    var at = batch.schema.field_arrow_type(col_index)

    if at == ArrowType.INT64:
        var arr = col_ref.as_primitive[DType.int64]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        var arr = col_ref.as_primitive[DType.int32]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.INT16:
        var arr = col_ref.as_primitive[DType.int16]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.INT8:
        var arr = col_ref.as_primitive[DType.int8]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT64:
        var arr = col_ref.as_primitive[DType.uint64]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT32:
        var arr = col_ref.as_primitive[DType.uint32]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT16:
        var arr = col_ref.as_primitive[DType.uint16]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.UINT8:
        var arr = col_ref.as_primitive[DType.uint8]()
        for r in range(num_rows):
            out.append(String("null") if arr.is_null(r) else String(arr.get(r)))
    elif at == ArrowType.FLOAT64:
        var arr = col_ref.as_primitive[DType.float64]()
        check_float_column_writable(arr, 0, num_rows, batch.schema, col_index)
        for r in range(num_rows):
            if arr.is_null(r):
                out.append(String("null"))
            else:
                out.append(_emit_float64(arr.get(r)))
    elif at == ArrowType.FLOAT32:
        var arr = col_ref.as_primitive[DType.float32]()
        check_float_column_writable(arr, 0, num_rows, batch.schema, col_index)
        for r in range(num_rows):
            if arr.is_null(r):
                out.append(String("null"))
            else:
                # Promote to Float64 for the NaN/Inf check; the bit
                # pattern check is the same shape.
                var v = Float64(arr.get(r))
                out.append(_emit_float64(v))
    elif at == ArrowType.BOOL:
        var arr = col_ref.as_boolean()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append(String("null"))
            else:
                out.append(_emit_bool(arr.get(r)))
    elif at == ArrowType.LARGE_STRING:
        # A separate arm from STRING: routing LARGE_STRING through
        # `column_as_string`, which has no int64-offset path, would make
        # `COPY (query) TO 'x.jsonl'` on a promoted column raise instead of
        # emitting rows. `column_as_large_string` is
        # the accessor that cannot refuse on size; `column_as_string` narrows
        # and refuses above the int32 ceiling, which is exactly the column
        # that got promoted. Escape and null handling are width-independent.
        var arr = batch.column_as_large_string(col_index)
        for r in range(num_rows):
            if arr.is_null(r):
                out.append(String("null"))
            else:
                out.append(_emit_string_escaped(arr.get(r)))
    elif at == ArrowType.STRING:
        var arr = batch.column_as_string(col_index)
        for r in range(num_rows):
            if arr.is_null(r):
                out.append(String("null"))
            else:
                out.append(_emit_string_escaped(arr.get(r)))
    elif at == ArrowType.DICTIONARY:
        var arr = col_ref.as_dictionary()
        for r in range(num_rows):
            if arr.indices.is_null(r):
                out.append(String("null"))
            else:
                out.append(_emit_string_escaped(arr.get(r)))
    elif at == ArrowType.DECIMAL128:
        var arr = col_ref.as_decimal128()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append(String("null"))
            else:
                out.append(_emit_float64(arr.get_as_float(r)))
    elif at == ArrowType.NULL:
        for _ in range(num_rows):
            out.append(String("null"))
    else:
        raise Error(
            "JSON: unsupported ArrowType '"
            + String(at)
            + "' at column index "
            + String(col_index)
            + ". Supported: INT8/16/32/64, UINT8/16/32/64, FLOAT32/64,"
            + " BOOL, STRING, LARGE_STRING, DICTIONARY, DATE32, DECIMAL128,"
            + " NULL."
        )
    return out^


def write_batch_jsonl(mut buf: List[UInt8], batch: RecordBatch) raises:
    """Emit a RecordBatch as JSONL bytes appended to `buf`.

    Each row becomes one JSON object: `{"col0":v0,"col1":v1,...}\\n`.
    Column names are the JSON object keys (escaped via
    `_emit_string_escaped`); column values are JSON-typed per the Arrow
    type (`_format_column_cells_json` lattice).

    Mirrors the CSV sink's column-major-then-transpose
    shape: pre-materialize each column to per-row cell strings then
    iterate rows in transpose.

    Args:
      buf: target byte buffer; bytes appended in-place.
      batch: borrowed RecordBatch. Columns are materialized once each.
    """
    var num_rows = batch.num_rows()
    var num_cols = batch.num_columns()
    if num_rows == 0:
        return

    # Pre-render column-name JSON-key strings (escaped) once.
    # `Schema` is not ImplicitlyCopyable — bind by `ref`
    # (origin-tracked borrow, no copy).
    ref schema = batch.schema
    var keys = List[String]()
    keys.reserve(num_cols)
    for c in range(num_cols):
        keys.append(_emit_string_escaped(schema.field_name(c)))

    # Pre-materialize each column's per-row cell strings.
    var columns = List[List[String]]()
    columns.reserve(num_cols)
    for c in range(num_cols):
        columns.append(_format_column_cells_json(batch, c))

    # Transpose to per-row JSON object emission.
    for r in range(num_rows):
        var line = String("{")
        for c in range(num_cols):
            if c > 0:
                line += String(",")
            line += keys[c]
            line += String(":")
            line += columns[c][r]
        line += String("}")
        # Append bytes of this line + \n.
        buf.extend(Span(line.as_bytes()))
        buf.append(UInt8(0x0A))
