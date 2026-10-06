# =============================================================================
# NOT NULL columns and the values JSON cannot hold: NaN, +Inf, -Inf, null.
# =============================================================================
#
# RFC 8259 section 6 has no token for NaN or an infinity. The writers spell
# them `null` in a nullable column; in a NOT NULL column that would write a
# null the column cannot hold, so every writer refuses it, naming the
# column, the row and the value. The reader refuses a JSON `null`, and an
# object with no key for the field (which reads as NULL in a nullable
# field), for a NOT NULL field, naming the field and the line.
#
# What each test proves, and the defect it catches:
#   * test_writers_refuse_nonfinite_in_not_null -- NaN, +Inf and -Inf in a
#     NOT NULL FLOAT64 column, and NaN in a NOT NULL FLOAT32 column, raise
#     the exact message from all six writers (write_batch_jsonl_direct,
#     write_batch_json_pretty, write_batch_jsonl_fused,
#     write_batch_jsonl_fused_range, encode.write_batch_jsonl,
#     write_row_output_jsonl). Catches a writer that emits `null` into a
#     NOT NULL column (the defect), or one path that lacks the check.
#   * test_writers_nullable_unchanged -- in a nullable column NaN/+-Inf and
#     a NULL cell are still written as `null` by every writer, and a NOT
#     NULL column of finite values is written as before. Catches a check
#     that refuses too much.
#   * test_reader_refuses_null_in_not_null -- `null` in a NOT NULL FLOAT64,
#     INT64 or STRING field, and an object without the field's key, raise
#     the exact message with the line (blank lines counted). Catches a
#     reader that materializes NULL into a NOT NULL field (the defect).
#   * test_reader_nullable_unchanged -- the same inputs read into nullable
#     fields give NULLs, and NOT NULL fields with every value present read
#     without NULLs and stay NOT NULL.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.collections.slab import Slab
from komira_row_format.row_block import DT_F64, RowBlock
from komira_row_format.row_output import RowOutput, RowOutputLayout

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.encode import write_batch_jsonl
from komira_jsonl.json_writer import (
    write_batch_json_pretty,
    write_batch_jsonl_direct,
    write_batch_jsonl_fused,
    write_batch_jsonl_fused_range,
    write_row_output_jsonl,
)


comptime _NAN64: UInt64 = 0x7FF8000000000000
comptime _INF64: UInt64 = 0x7FF0000000000000


def _f(bits: UInt64) -> Float64:
    return bitcast[DType.float64, 1](bits)


def _l(a: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    return out^


def _l(a: Float64, b: Float64) -> List[Float64]:
    var out = _l(a)
    out.append(b)
    return out^


def _l(a: Float64, b: Float64, c: Float64) -> List[Float64]:
    var out = _l(a, b)
    out.append(c)
    return out^


def _l(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var out = _l(a, b, c)
    out.append(d)
    return out^


def _text(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def _f64_batch(values: List[Float64], nullable: Bool) raises -> RecordBatch:
    """One FLOAT64 column `f` holding `values`."""
    var arr: PrimitiveArray[DType.float64]
    if nullable:
        arr = PrimitiveArray[DType.float64].allocate_nullable(len(values))
    else:
        arr = PrimitiveArray[DType.float64].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, nullable))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def _f32_not_null_batch(values: List[Float32]) raises -> RecordBatch:
    """An INT64 column `i` (0, 1, ...) then a NOT NULL FLOAT32 column `g`."""
    var ia = PrimitiveArray[DType.int64].allocate(len(values))
    var fa = PrimitiveArray[DType.float32].allocate(len(values))
    for i in range(len(values)):
        ia.set(i, Int64(i))
        fa.set(i, values[i])
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("g", ArrowType.FLOAT32, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](ia^))
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.float32](fa^, ArrowType.FLOAT32)
    )
    return rbb.build(sb.build())


def _row_output(values: List[Float64], nullable: Bool) raises -> RowOutput:
    """One FLOAT64 column `f` as a RowOutput of one block, no validity."""
    var blk = RowBlock.with_capacity(len(values), 0, 8)
    for i in range(len(values)):
        blk.write_fixed[DType.float64](i, 0, values[i])
    blk.set_n_rows(len(values))
    var blocks = Slab[RowBlock]()
    blocks.append(blk^)
    var offsets = List[Int]()
    offsets.append(0)
    var tags = List[UInt8]()
    tags.append(DT_F64)
    var layout = RowOutputLayout(offsets^, tags^, 0, False)
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, nullable))
    return RowOutput(blocks^, layout^, sb.build())


comptime _W = "json_writer: column '"


def _want_writer(col: String, row: Int, what: String) -> String:
    return (
        String(_W) + col + "' is NOT NULL and row " + String(row) + " holds "
        + what + ", which JSON cannot spell (RFC 8259 section 6); only a"
        + " nullable column writes it as null"
    )


def _writer_errors(batch: RecordBatch) -> List[String]:
    """The error text of each columnar writer over `batch` ("" = no error),
    in the order direct, pretty, fused, fused_range, encode."""
    var out = List[String]()
    var buf = List[UInt8]()
    try:
        write_batch_jsonl_direct(buf, batch)
        out.append(String(""))
    except e:
        out.append(String(e))
    try:
        write_batch_json_pretty(buf, batch)
        out.append(String(""))
    except e:
        out.append(String(e))
    try:
        write_batch_jsonl_fused(buf, batch)
        out.append(String(""))
    except e:
        out.append(String(e))
    try:
        write_batch_jsonl_fused_range(buf, batch, 0, batch.num_rows())
        out.append(String(""))
    except e:
        out.append(String(e))
    try:
        write_batch_jsonl(buf, batch)
        out.append(String(""))
    except e:
        out.append(String(e))
    return out^


def _row_writer_error(ro: RowOutput) -> String:
    var buf = List[UInt8]()
    try:
        write_row_output_jsonl(buf, ro)
    except e:
        return String(e)
    return String("")


def _assert_all(errs: List[String], want: String, label: String) raises:
    var names = [
        String("direct"), String("pretty"), String("fused"),
        String("fused_range"), String("encode"),
    ]
    assert_equal(len(errs), 5)
    for i in range(len(errs)):
        assert_equal(errs[i], want, label + " via " + names[i])


def test_writers_refuse_nonfinite_in_not_null() raises:
    print("test_writers_refuse_nonfinite_in_not_null")
    var nan64 = _f(_NAN64)
    var inf64 = _f(_INF64)
    _assert_all(
        _writer_errors(_f64_batch(_l(1.5, nan64, 2.0), False)),
        _want_writer("f", 1, "NaN"), "NaN",
    )
    _assert_all(
        _writer_errors(_f64_batch(_l(1.5, 2.0, inf64), False)),
        _want_writer("f", 2, "+Inf"), "+Inf",
    )
    _assert_all(
        _writer_errors(_f64_batch(_l(-inf64), False)),
        _want_writer("f", 0, "-Inf"), "-Inf",
    )
    # A FLOAT32 column (second column) with NaN in row 3.
    var f32s = List[Float32]()
    f32s.append(Float32(1.0))
    f32s.append(Float32(2.0))
    f32s.append(Float32(3.0))
    f32s.append(Float32(nan64))
    _assert_all(
        _writer_errors(_f32_not_null_batch(f32s)),
        _want_writer("g", 3, "NaN"), "f32 NaN",
    )
    # The fused range writer counts rows from the start of the batch.
    var buf = List[UInt8]()
    var msg = String("")
    try:
        write_batch_jsonl_fused_range(buf, _f64_batch(_l(1.0, 2.0, nan64), False), 1, 3)
    except e:
        msg = String(e)
    assert_equal(msg, _want_writer("f", 2, "NaN"), "fused_range [1, 3)")
    # Row output.
    assert_equal(
        _row_writer_error(_row_output(_l(0.5, 0.25, -inf64), False)),
        _want_writer("f", 2, "-Inf"), "row output",
    )


def test_writers_nullable_unchanged() raises:
    print("test_writers_nullable_unchanged")
    var nan64 = _f(_NAN64)
    var inf64 = _f(_INF64)
    var vals = _l(nan64, inf64, -inf64, 1.5)
    var b = _f64_batch(vals, True)
    var want = String('{"f":null}\n{"f":null}\n{"f":null}\n{"f":1.5}\n')
    var buf = List[UInt8]()
    write_batch_jsonl_direct(buf, b)
    assert_equal(_text(buf), want, "direct")
    buf.clear()
    write_batch_jsonl_fused(buf, b)
    assert_equal(_text(buf), want, "fused")
    buf.clear()
    write_batch_jsonl(buf, b)
    assert_equal(_text(buf), want, "encode")
    buf.clear()
    write_row_output_jsonl(buf, _row_output(vals, True))
    assert_equal(_text(buf), want, "row output")
    buf.clear()
    write_batch_json_pretty(buf, _f64_batch(_l(nan64), True))
    assert_equal(_text(buf), String('[\n  {\n    "f": null\n  }\n]'), "pretty")
    # NOT NULL with finite values only: written, no error.
    var errs = _writer_errors(_f64_batch(_l(1.5, _f(0x8000000000000000), _f(0x0000000000000001)), False))
    _assert_all(errs, String(""), "finite NOT NULL")
    buf.clear()
    write_batch_jsonl_direct(buf, _f64_batch(_l(1.5, _f(0x8000000000000000), _f(0x0000000000000001)), False))
    assert_equal(_text(buf), String('{"f":1.5}\n{"f":-0.0}\n{"f":5e-324}\n'))


def _schema1(name: String, ty: ArrowType, nullable: Bool) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ty, nullable))
    return sb.build()


def _read_error(text: String, var schema: Schema) -> String:
    try:
        var b = materialize_jsonl_to_batch(text.as_bytes(), schema^)
        return String("no error: ") + String(b.num_rows()) + " rows"
    except e:
        return String(e)


def test_reader_refuses_null_in_not_null() raises:
    print("test_reader_refuses_null_in_not_null")
    assert_equal(
        _read_error('{"f":1.5}\n{"f":null}\n', _schema1("f", ArrowType.FLOAT64, False)),
        String("komira_jsonl: line 2: NOT NULL field 'f' holds JSON null"),
    )
    assert_equal(
        _read_error('{"f":1.5}\n\n{"g":2}\n', _schema1("f", ArrowType.FLOAT64, False)),
        String("komira_jsonl: line 3: NOT NULL field 'f' has no key in the object"),
    )
    assert_equal(
        _read_error('{}\n', _schema1("f", ArrowType.FLOAT64, False)),
        String("komira_jsonl: line 1: NOT NULL field 'f' has no key in the object"),
    )
    assert_equal(
        _read_error('{"i":1}\n{"i":2}\n{"i": null }\n', _schema1("i", ArrowType.INT64, False)),
        String("komira_jsonl: line 3: NOT NULL field 'i' holds JSON null"),
    )
    assert_equal(
        _read_error('{"s":null}\n', _schema1("s", ArrowType.STRING, False)),
        String("komira_jsonl: line 1: NOT NULL field 's' holds JSON null"),
    )


def test_reader_nullable_unchanged() raises:
    print("test_reader_nullable_unchanged")
    var text = String('{"f":1.5}\n{"f":null}\n{"g":2}\n')
    var b = materialize_jsonl_to_batch(text.as_bytes(), _schema1("f", ArrowType.FLOAT64, True))
    assert_equal(b.num_rows(), 3)
    var c = b.column_as_primitive_float64(0)
    assert_false(c.is_null(0))
    assert_equal(c.get(0), 1.5)
    assert_true(c.is_null(1))
    assert_true(c.is_null(2))
    # NOT NULL with every value present: no NULLs, the field stays NOT NULL.
    var t2 = String('{"f":1.5}\n{"f":-2.0,"g":null}\n')
    var b2 = materialize_jsonl_to_batch(t2.as_bytes(), _schema1("f", ArrowType.FLOAT64, False))
    assert_equal(b2.num_rows(), 2)
    assert_false(b2.schema.field_nullable(0))
    var c2 = b2.column_as_primitive_float64(0)
    assert_false(c2.is_null(0))
    assert_false(c2.is_null(1))
    assert_equal(c2.get(1), -2.0)


def main() raises:
    test_writers_refuse_nonfinite_in_not_null()
    test_writers_nullable_unchanged()
    test_reader_refuses_null_in_not_null()
    test_reader_nullable_unchanged()
    print("test_not_null_nonfinite: ALL PASS")
