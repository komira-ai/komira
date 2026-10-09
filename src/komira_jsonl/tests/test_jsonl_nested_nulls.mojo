# =============================================================================
# test_jsonl_nested_nulls.mojo -- nulls inside LIST / STRUCT / MAP values, a
# scalar for a nested column, and DECIMAL128 numbers with an exponent
# =============================================================================
#
# Refs #917. Each group reads the values back from the Arrow arrays:
#   - test_list_null_elements: `[1,null,3]` (and the same for every
#     supported inner type) reads its middle element as NULL in the child
#     column, the others as their values. Before the fix the child column had
#     no validity bitmap, so the null read as a valid 0, 0.0, false, "" or
#     1970-01-01.
#   - test_struct_null_and_missing_members: a member holding JSON null, a
#     member missing from its object, and every member of a null STRUCT row
#     read NULL; present members keep their values.
#   - test_map_null_values: a MAP value of null reads NULL; its key is kept.
#   - test_scalar_for_nested_column_refused: a number or literal for a LIST,
#     STRUCT or MAP column is refused naming the column, as an unquoted value
#     for a STRING or DATE32 column is. Before the fix it read as NULL.
#   - test_decimal_exponent_*: DECIMAL128 reads JSON numbers with an
#     exponent (RFC 8259 section 6), as a number and as a string, with the
#     parser's truncation and precision rules; malformed exponents are
#     refused. Before the fix every exponent was refused.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.value_parsers.parse_decimal import parse_decimal128_unscaled


# --- helpers -----------------------------------------------------------------


def _schema(var fields: List[Field]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i])
    return sb.build()


def _nested(name: String, at: ArrowType, child: ArrowType) -> Field:
    var f = Field(name, at, True)
    f.add_child(String("item"), child, True)
    return f^


def _read(text: String, var schema: Schema) raises -> RecordBatch:
    var b = List[UInt8]()
    b.extend(Span(text.as_bytes()))
    return materialize_jsonl_to_batch(Span(b), schema^)


def _err_of(text: String, var schema: Schema) raises -> String:
    var b = List[UInt8]()
    b.extend(Span(text.as_bytes()))
    var rows = -1
    try:
        var batch = materialize_jsonl_to_batch(Span(b), schema^)
        rows = batch.num_rows()
    except e:
        return String(e)
    raise Error("not refused, " + String(rows) + " row(s): " + text)


def _dec(text: String, precision: Int, scale: Int) raises -> Int:
    var b = text.as_bytes()
    var v = parse_decimal128_unscaled(b, 0, len(b), precision, scale)
    return Int(v.cast[DType.int64]())


def _dec_err(text: String, precision: Int, scale: Int) raises -> String:
    var b = text.as_bytes()
    try:
        var v = parse_decimal128_unscaled(b, 0, len(b), precision, scale)
        raise Error(
            "not refused (" + String(Int(v.cast[DType.int64]())) + "): " + text
        )
    except e:
        var msg = String(e)
        if msg.startswith("not refused"):
            raise e^
        return msg


# --- LIST ----------------------------------------------------------------------


def test_list_null_elements() raises:
    var f = List[Field]()
    f.append(_nested(String("li"), ArrowType.LIST, ArrowType.INT64))
    f.append(_nested(String("lf"), ArrowType.LIST, ArrowType.FLOAT64))
    f.append(_nested(String("lb"), ArrowType.LIST, ArrowType.BOOL))
    f.append(_nested(String("ls"), ArrowType.LIST, ArrowType.STRING))
    f.append(_nested(String("ld"), ArrowType.LIST, ArrowType.DATE32))
    var batch = _read(
        String('{"li":[1,null,3],"lf":[1.5,null,-2.5],"lb":[true,null,true],')
        + '"ls":["a",null,"c"],"ld":["2026-09-01",null,"2026-10-08"]}\n',
        _schema(f^),
    )
    assert_equal(batch.num_rows(), 1)
    for c in range(5):
        var la = batch.column_at(c).as_list()
        assert_equal(la.null_count, 0)
        assert_equal(la.get_length(0), 3)
        assert_equal(la.child.length(), 3)
        assert_equal(la.child.null_count(), 1)
        assert_false(la.child.is_null_at(0))
        assert_true(la.child.is_null_at(1))
        assert_false(la.child.is_null_at(2))
    var li = batch.column_at(0).as_list()
    assert_equal(Int(li.child.as_primitive[DType.int64]().get(0)), 1)
    assert_equal(Int(li.child.as_primitive[DType.int64]().get(2)), 3)
    var lf = batch.column_at(1).as_list()
    assert_equal(lf.child.as_primitive[DType.float64]().get(2), -2.5)
    var lb = batch.column_at(2).as_list()
    assert_true(lb.child.as_boolean().get(2))
    var ls = batch.column_at(3).as_list()
    assert_equal(ls.child.as_string().get(0), String("a"))
    assert_equal(ls.child.as_string().get(2), String("c"))
    var ld = batch.column_at(4).as_list()
    assert_equal(Int(ld.child.as_primitive[DType.int32]().get(2)), 20734)


# --- STRUCT --------------------------------------------------------------------


def test_struct_null_and_missing_members() raises:
    var st = Field(String("s"), ArrowType.STRUCT, True)
    st.add_child(String("x"), ArrowType.INT64, True)
    st.add_child(String("y"), ArrowType.STRING, True)
    st.add_child(String("z"), ArrowType.BOOL, True)
    var f = List[Field]()
    f.append(st^)
    var batch = _read(
        String('{"s":{"x":null,"y":"a","z":false}}\n')
        + '{"s":{"y":"b"}}\n'
        + '{"s":null}\n'
        + '{"s":{"x":7,"y":null,"z":true}}\n',
        _schema(f^),
    )
    assert_equal(batch.num_rows(), 4)
    var sa = batch.column_at(0).as_struct()
    assert_equal(sa.null_count, 1)
    assert_true(sa.is_null(2))
    # x: null, missing, (null row), 7.
    ref x = sa.child_at(0)
    assert_equal(x.null_count(), 3)
    assert_true(x.is_null_at(0))
    assert_true(x.is_null_at(1))
    assert_true(x.is_null_at(2))
    assert_false(x.is_null_at(3))
    assert_equal(Int(x.as_primitive[DType.int64]().get(3)), 7)
    # y: "a", "b", (null row), null.
    ref y = sa.child_at(1)
    assert_equal(y.null_count(), 2)
    assert_false(y.is_null_at(0))
    assert_false(y.is_null_at(1))
    assert_true(y.is_null_at(2))
    assert_true(y.is_null_at(3))
    assert_equal(y.as_string().get(1), String("b"))
    # z: false, missing, (null row), true.
    ref z = sa.child_at(2)
    assert_equal(z.null_count(), 2)
    assert_false(z.is_null_at(0))
    assert_true(z.is_null_at(1))
    assert_true(z.is_null_at(2))
    assert_false(z.is_null_at(3))
    assert_false(z.as_boolean().get(0))
    assert_true(z.as_boolean().get(3))


# --- MAP -----------------------------------------------------------------------


def test_map_null_values() raises:
    var f = List[Field]()
    f.append(_nested(String("m"), ArrowType.MAP, ArrowType.FLOAT64))
    f.append(_nested(String("n"), ArrowType.MAP, ArrowType.DATE32))
    var batch = _read(
        String('{"m":{"a":null,"b":2.5},"n":{"d":"2026-09-01","e":null}}\n'),
        _schema(f^),
    )
    var m = batch.column_at(0).as_map()
    assert_equal(m.get_length(0), 2)
    assert_equal(m.keys.as_string().get(0), String("a"))
    assert_equal(m.values.null_count(), 1)
    assert_true(m.values.is_null_at(0))
    assert_false(m.values.is_null_at(1))
    assert_equal(m.values.as_primitive[DType.float64]().get(1), 2.5)
    var n = batch.column_at(1).as_map()
    assert_equal(n.keys.as_string().get(1), String("e"))
    assert_equal(n.values.null_count(), 1)
    assert_false(n.values.is_null_at(0))
    assert_true(n.values.is_null_at(1))
    assert_equal(Int(n.values.as_primitive[DType.int32]().get(0)), 20697)


# --- a scalar for a nested column ------------------------------------------------


def test_scalar_for_nested_column_refused() raises:
    var f = List[Field]()
    f.append(_nested(String("l"), ArrowType.LIST, ArrowType.INT64))
    f.append(_nested(String("t"), ArrowType.STRUCT, ArrowType.INT64))
    f.append(_nested(String("m"), ArrowType.MAP, ArrowType.INT64))
    var schema = _schema(f^)
    assert_equal(
        _err_of(String('{"l":5}\n'), schema.copy()),
        "komira_jsonl: line 1: materialize_jsonl_to_batch: LIST column 'l'"
        " expects a JSON array but value is a scalar at byte 5",
    )
    assert_equal(
        _err_of(String('{}\n{"t":true}\n'), schema.copy()),
        "komira_jsonl: line 2: materialize_jsonl_to_batch: STRUCT column 't'"
        " expects a JSON object but value is a scalar at byte 8",
    )
    assert_equal(
        _err_of(String('{"m":1.5}\n'), schema.copy()),
        "komira_jsonl: line 1: materialize_jsonl_to_batch: MAP column 'm'"
        " expects a JSON object but value is a scalar at byte 5",
    )
    # A JSON null still reads NULL.
    var batch = _read(String('{"l":null,"t":null,"m":null}\n'), schema^)
    for c in range(3):
        assert_true(batch.column_at(c).is_null_at(0))


# --- DECIMAL128 with an exponent -------------------------------------------------


def test_decimal_exponent_end_to_end() raises:
    var f = List[Field]()
    f.append(Field.decimal128(String("c"), 10, 2, True))
    var batch = _read(
        String('{"c":1e2}\n{"c":1.5E-1}\n{"c":-2e+3}\n{"c":"1.25e1"}\n')
        + '{"c":0.0e0}\n',
        _schema(f^),
    )
    var a = batch.column_at(0).as_decimal128()
    assert_equal(Int(a.get_low(0)), 10000)
    assert_equal(Int(a.get_low(1)), 15)
    assert_equal(Int(a.get_i128(2).cast[DType.int64]()), -200000)
    assert_equal(Int(a.get_low(3)), 1250)
    assert_equal(Int(a.get_low(4)), 0)


def test_decimal_exponent_values() raises:
    # The point moves by the exponent; excess fraction digits truncate.
    assert_equal(_dec(String("1e2"), 5, 0), 100)
    assert_equal(_dec(String("12.345e1"), 6, 2), 12345)
    assert_equal(_dec(String("12.345e-1"), 6, 2), 123)
    assert_equal(_dec(String("12345e-4"), 6, 3), 1234)
    assert_equal(_dec(String("0.05e1"), 5, 1), 5)
    assert_equal(_dec(String("-0.0012E+3"), 5, 2), -120)
    assert_equal(_dec(String("123e-5"), 5, 2), 0)
    assert_equal(_dec(String("0e999"), 5, 2), 0)
    # Leading zeros, before and after the point, are not digits.
    assert_equal(_dec(String("000.00123e3"), 3, 2), 123)
    # A huge negative exponent truncates to 0 and does not loop.
    assert_equal(_dec(String("7e-999999999999999999999"), 38, 10), 0)
    # Without an exponent the old reading holds.
    assert_equal(_dec(String("1.234"), 5, 2), 123)
    assert_equal(_dec(String("1.5"), 10, 4), 15000)
    assert_equal(_dec(String("0.05"), 5, 1), 0)


def test_decimal_exponent_precision_and_refusals() raises:
    # 12e17 has 19 integer digits: over DECIMAL128(18, 0).
    var msg = _dec_err(String("12e17"), 18, 0)
    assert_true(
        msg.startswith(
            "parse_decimal128_unscaled: value has 19 integer digits, which"
            " does not fit DECIMAL128(18, 0)"
        ),
        msg,
    )
    assert_equal(_dec(String("12e16"), 18, 0), 120000000000000000)
    # A huge positive exponent is over any precision.
    _ = _dec_err(String("1e999999999999999999"), 38, 0)
    var no_digits = String(
        "parse_decimal128_unscaled: exponent must have digits at position "
    )
    assert_equal(_dec_err(String("1e"), 5, 0), no_digits + "2")
    assert_equal(_dec_err(String("1E+"), 5, 0), no_digits + "3")
    assert_equal(_dec_err(String("1.5e-x"), 5, 0), no_digits + "5")
    assert_equal(
        _dec_err(String("1e2.5"), 5, 0),
        "parse_decimal128_unscaled: unexpected trailing byte at position 3",
    )
    assert_equal(
        _dec_err(String("1.e2"), 5, 0),
        "parse_decimal128_unscaled: '.' must be followed by digits at"
        " position 2",
    )


def main() raises:
    test_list_null_elements()
    test_struct_null_and_missing_members()
    test_map_null_values()
    test_scalar_for_nested_column_refused()
    test_decimal_exponent_end_to_end()
    test_decimal_exponent_values()
    test_decimal_exponent_precision_and_refusals()
    print("test_jsonl_nested_nulls: all passed")
