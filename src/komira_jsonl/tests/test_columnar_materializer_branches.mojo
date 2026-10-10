# =============================================================================
# test_columnar_materializer_branches.mojo -- every line and branch arm of
# columnar_materializer.mojo
# =============================================================================
#
# Each group reads the values back from the Arrow arrays, not only the row
# count, so a value pushed to the wrong accumulator, a dropped null or a
# wrong child type fails. Refusals assert the whole message, or its fixed
# prefix and the words that name the branch. Groups:
#   - accumulators: LIST, STRUCT and MAP of every supported inner type
#     (values, offsets, child types, validity, null counts), an unsupported
#     inner type refused when the column is built (and not labelled with a
#     line: the rows are read by then);
#   - every column kind holding JSON null and a missing key; DECIMAL128 from
#     a string and a number, and its precision and scale defaults;
#   - schema refusals: a LIST or MAP without exactly one child, a STRUCT
#     without children, an unsupported column type;
#   - value refusals: an unquoted STRING or DATE32 value, a nested value for
#     a column of the other nested kind or a scalar kind; a scalar for a
#     LIST, STRUCT or MAP column (refused; #917);
#   - tab and CR around a scalar (RFC 8259 section 2), and `_is_ws` itself;
#   - the cell budget at its boundary (equal passes, one over refuses);
#   - JSONTestSuite (nst/JSONTestSuite) y_object_* cases, byte for byte;
#   - the row walk's own guards, reached by calling `_walk_jsonl_rows` on
#     the Stage 1 tape of JSONTestSuite n_ cases (or a truncated or retagged
#     tape of a y_ case) without the line check that refuses them first;
#   - line ranges and the parallel entries: one worker, worker count
#     defaults, the cap of 32 (seen through the range a cell-budget
#     refusal names), a 4 MiB input of one line, partition lists that
#     disagree or do not fit the input, and the dispatcher entries on a
#     one-worker runtime;
#   - ColumnarMaterializer.init_for_schema.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_json_index.simd_primitives import (
    TAG_CLOSE_BRACE,
    TAG_COLON,
)
from komira_json_index.structural_index import (
    build_structural_index,
    JsonlPartitions,
    StructuralIndex,
)
from komira_jsonl.columnar_materializer import (
    ColumnarMaterializer,
    materialize_jsonl_to_batch,
    materialize_jsonl_to_batch_parallel,
    materialize_jsonl_to_batch_parallel_with_dispatcher,
    materialize_jsonl_to_batch_parallel_with_partitions,
    materialize_jsonl_to_batch_parallel_with_partitions_with_dispatcher,
    _compute_jsonl_line_ranges,
    _is_ws,
    _walk_jsonl_rows,
)


# --- helpers -----------------------------------------------------------------


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _schema(var fields: List[Field]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i])
    return sb.build()


def _one(name: String, at: ArrowType) -> Schema:
    var f = List[Field]()
    f.append(Field(name, at, True))
    return _schema(f^)


def _nested(name: String, at: ArrowType, child: ArrowType) -> Field:
    var f = Field(name, at, True)
    f.add_child(String("item"), child, True)
    return f^


def _read(text: String, var schema: Schema) raises -> RecordBatch:
    var b = _bytes_of(text)
    return materialize_jsonl_to_batch(Span(b), schema^)


def _err_of(text: String, var schema: Schema) raises -> String:
    var b = _bytes_of(text)
    var rows = -1
    try:
        var batch = materialize_jsonl_to_batch(Span(b), schema^)
        rows = batch.num_rows()
    except e:
        return String(e)
    raise Error("not refused, " + String(rows) + " row(s): " + text)


def _starts(msg: String, want: String) raises:
    if not msg.startswith(want):
        raise Error("want prefix '" + want + "', got: " + msg)


def _has(msg: String, words: String) raises:
    if words not in msg:
        raise Error("want '" + words + "' in: " + msg)


# --- accumulators: LIST / STRUCT / MAP of each inner type ---------------------


def test_list_of_float_bool_date() raises:
    var f = List[Field]()
    f.append(_nested(String("lf"), ArrowType.LIST, ArrowType.FLOAT64))
    f.append(_nested(String("lb"), ArrowType.LIST, ArrowType.BOOL))
    f.append(_nested(String("ld"), ArrowType.LIST, ArrowType.DATE32))
    var batch = _read(
        String('{"lf":[1.5,-2.25],"lb":[true,false],"ld":["2026-09-01","2026-10-08"]}\n')
        + '{"lf":null,"lb":null,"ld":null}\n'
        + "{}\n"
        + '{"lf":[],"lb":[true],"ld":[]}\n',
        _schema(f^),
    )
    assert_equal(batch.num_rows(), 4)
    for c in range(3):
        var la = batch.column_at(c).as_list()
        assert_equal(la.null_count, 2)
        assert_false(la.is_null(0))
        assert_true(la.is_null(1))
        assert_true(la.is_null(2))
        assert_false(la.is_null(3))
        assert_equal(la.get_offset(1), 2)
        assert_equal(la.get_length(1), 0)
        assert_equal(la.get_length(2), 0)
    var lf = batch.column_at(0).as_list()
    assert_true(lf.child.arrow_type == ArrowType.FLOAT64)
    assert_equal(lf.child.length(), 2)
    var fv = lf.child.as_primitive[DType.float64]()
    assert_equal(fv.get(0), 1.5)
    assert_equal(fv.get(1), -2.25)
    var lb = batch.column_at(1).as_list()
    assert_true(lb.child.arrow_type == ArrowType.BOOL)
    assert_equal(lb.child.length(), 3)
    var bv = lb.child.as_boolean()
    assert_true(bv.get(0))
    assert_false(bv.get(1))
    assert_true(bv.get(2))
    assert_equal(lb.get_offset(3), 2)
    assert_equal(lb.get_length(3), 1)
    var ld = batch.column_at(2).as_list()
    assert_true(ld.child.arrow_type == ArrowType.DATE32)
    var dv = ld.child.as_primitive[DType.int32]()
    assert_equal(Int(dv.get(0)), 20697)
    assert_equal(Int(dv.get(1)), 20734)


def test_struct_of_every_type_null_and_missing() raises:
    var st = Field(String("s"), ArrowType.STRUCT, True)
    st.add_child(String("f"), ArrowType.FLOAT64, True)
    st.add_child(String("b"), ArrowType.BOOL, True)
    st.add_child(String("t"), ArrowType.STRING, True)
    st.add_child(String("d"), ArrowType.DATE32, True)
    st.add_child(String("i"), ArrowType.INT64, True)
    var f = List[Field]()
    f.append(st^)
    var batch = _read(
        String('{"s":{"f":0.5,"b":true,"t":"x","d":"2026-10-08","i":3}}\n')
        + '{"s":null}\n'
        + "{}\n",
        _schema(f^),
    )
    assert_equal(batch.num_rows(), 3)
    var sa = batch.column_at(0).as_struct()
    assert_equal(sa.null_count, 2)
    assert_false(sa.is_null(0))
    assert_true(sa.is_null(1))
    assert_true(sa.is_null(2))
    # A null row appends one slot to every child, whatever its type.
    for c in range(5):
        assert_equal(sa.child_at(c).length(), 3)
    assert_true(sa.child_at(0).arrow_type == ArrowType.FLOAT64)
    assert_equal(sa.child_at(0).as_primitive[DType.float64]().get(0), 0.5)
    assert_true(sa.child_at(1).arrow_type == ArrowType.BOOL)
    assert_true(sa.child_at(1).as_boolean().get(0))
    assert_true(sa.child_at(2).arrow_type == ArrowType.STRING)
    assert_equal(sa.child_at(2).as_string().get(0), String("x"))
    assert_true(sa.child_at(3).arrow_type == ArrowType.DATE32)
    assert_equal(Int(sa.child_at(3).as_primitive[DType.int32]().get(0)), 20734)
    assert_equal(Int(sa.child_at(4).as_primitive[DType.int64]().get(0)), 3)


def test_map_of_float_bool_string_date() raises:
    var f = List[Field]()
    f.append(_nested(String("mf"), ArrowType.MAP, ArrowType.FLOAT64))
    f.append(_nested(String("mb"), ArrowType.MAP, ArrowType.BOOL))
    f.append(_nested(String("ms"), ArrowType.MAP, ArrowType.STRING))
    f.append(_nested(String("md"), ArrowType.MAP, ArrowType.DATE32))
    var batch = _read(
        String('{"mf":{"x":1.25},"mb":{"y":false,"z":true},"ms":{"k":"v"},')
        + '"md":{"d":"2026-09-01"}}\n'
        + '{"mf":null,"mb":null,"ms":null,"md":null}\n'
        + "{}\n",
        _schema(f^),
    )
    assert_equal(batch.num_rows(), 3)
    for c in range(4):
        var ma = batch.column_at(c).as_map()
        assert_equal(ma.null_count, 2)
        assert_false(ma.is_null(0))
        assert_true(ma.is_null(1))
        assert_true(ma.is_null(2))
        assert_equal(ma.get_length(1), 0)
        assert_equal(ma.get_length(2), 0)
    var mf = batch.column_at(0).as_map()
    assert_equal(mf.keys.as_string().get(0), String("x"))
    assert_true(mf.values.arrow_type == ArrowType.FLOAT64)
    assert_equal(mf.values.as_primitive[DType.float64]().get(0), 1.25)
    var mb = batch.column_at(1).as_map()
    assert_equal(mb.get_length(0), 2)
    assert_equal(mb.keys.as_string().get(1), String("z"))
    assert_true(mb.values.arrow_type == ArrowType.BOOL)
    assert_false(mb.values.as_boolean().get(0))
    assert_true(mb.values.as_boolean().get(1))
    var ms = batch.column_at(2).as_map()
    assert_true(ms.values.arrow_type == ArrowType.STRING)
    assert_equal(ms.values.as_string().get(0), String("v"))
    var md = batch.column_at(3).as_map()
    assert_true(md.values.arrow_type == ArrowType.DATE32)
    assert_equal(Int(md.values.as_primitive[DType.int32]().get(0)), 20697)


def test_unsupported_inner_type_refused_at_build() raises:
    # Every row null or missing, so no parser sees the inner type: the
    # accumulator refuses it when it builds the column, after the rows, so
    # the error names no line.
    var dec = ArrowType.DECIMAL128
    var tid = String(Int(dec.type_id))
    var lf = List[Field]()
    lf.append(_nested(String("l"), ArrowType.LIST, dec))
    var msg = _err_of(String('{"l":null}\n{}\n'), _schema(lf^))
    assert_equal(msg, "_ListAcc.build_column: unsupported inner arrow_type " + tid)
    var st = Field(String("s"), ArrowType.STRUCT, True)
    st.add_child(String("x"), dec, True)
    var sf = List[Field]()
    sf.append(st^)
    msg = _err_of(String('{"s":null}\n{}\n'), _schema(sf^))
    assert_equal(msg, "_StructAcc.build_column: unsupported child arrow_type " + tid)
    var mf = List[Field]()
    mf.append(_nested(String("m"), ArrowType.MAP, dec))
    msg = _err_of(String("{}\n"), _schema(mf^))
    assert_equal(msg, "_MapAcc.build_column: unsupported value arrow_type " + tid)


# --- every column kind: null, missing, valid ----------------------------------


def _all_kinds() raises -> Schema:
    var f = List[Field]()
    f.append(Field(String("i"), ArrowType.INT64, True))
    f.append(Field(String("b"), ArrowType.BOOL, True))
    f.append(Field(String("s"), ArrowType.STRING, True))
    f.append(Field(String("f"), ArrowType.FLOAT64, True))
    f.append(Field(String("d"), ArrowType.DATE32, True))
    f.append(Field.decimal128(String("c"), 10, 2, True))
    f.append(_nested(String("l"), ArrowType.LIST, ArrowType.INT64))
    f.append(_nested(String("t"), ArrowType.STRUCT, ArrowType.INT64))
    f.append(_nested(String("m"), ArrowType.MAP, ArrowType.INT64))
    return _schema(f^)


def test_every_kind_null_missing_valid() raises:
    var batch = _read(
        String('{"i":null,"b":null,"s":null,"f":null,"d":null,"c":null,')
        + '"l":null,"t":null,"m":null}\n'
        + "{}\n"
        + '{"i":1,"b":true,"s":"x","f":2.5,"d":"2026-12-31","c":"12.34",'
        + '"l":[7],"t":{"item":8},"m":{"k":9}}\n',
        _all_kinds(),
    )
    assert_equal(batch.num_rows(), 3)
    assert_equal(batch.num_columns(), 9)
    for c in range(9):
        ref col = batch.column_at(c)
        assert_equal(col.length(), 3)
        assert_equal(col.null_count(), 2)
        assert_true(col.is_null_at(0))
        assert_true(col.is_null_at(1))
        assert_false(col.is_null_at(2))
    assert_equal(Int(batch.column_at(4).as_primitive[DType.int32]().get(2)), 20818)
    assert_equal(Int(batch.column_at(5).as_decimal128().get_low(2)), 1234)
    var t = batch.column_at(7).as_struct()
    assert_equal(Int(t.child_at(0).as_primitive[DType.int64]().get(2)), 8)
    var m = batch.column_at(8).as_map()
    assert_equal(Int(m.values.as_primitive[DType.int64]().get(0)), 9)


def test_decimal_string_number_and_defaults() raises:
    var f = List[Field]()
    f.append(Field.decimal128(String("c"), 10, 2, True))
    var batch = _read(String('{"c":"12.34"}\n{"c":5.5}\n'), _schema(f^))
    var a = batch.column_at(0).as_decimal128()
    assert_equal(Int(a.get_low(0)), 1234)
    assert_equal(Int(a.get_low(1)), 550)
    assert_equal(a.precision, 10)
    assert_equal(a.scale, 2)
    # No precision on the field: 18. A negative scale on the field: 4.
    var p0 = Field(String("p"), ArrowType.DECIMAL128, True)
    var sneg = Field(String("q"), ArrowType.DECIMAL128, True)
    sneg.decimal_precision = 9
    sneg.decimal_scale = -1
    var g = List[Field]()
    g.append(p0^)
    g.append(sneg^)
    var b2 = _read(String('{"p":"123456789012345678","q":"1.5"}\n'), _schema(g^))
    var p = b2.column_at(0).as_decimal128()
    assert_equal(p.precision, 18)
    assert_equal(p.scale, 0)
    assert_equal(Int(p.get_low(0)), 123456789012345678)
    var q = b2.column_at(1).as_decimal128()
    assert_equal(q.precision, 9)
    assert_equal(q.scale, 4)
    assert_equal(Int(q.get_low(0)), 15000)
    # 19 digits overflow the default precision of 18.
    var h = List[Field]()
    h.append(Field(String("p"), ArrowType.DECIMAL128, True))
    var msg = _err_of(String('{"p":"1234567890123456789"}\n'), _schema(h^))
    assert_equal(
        msg,
        "komira_jsonl: line 1: parse_decimal128_unscaled: value has 19"
        + " integer digits, which does not fit DECIMAL128(18, 0) — at most"
        + " 18 integer digits are representable. Past ~38 significant digits"
        + " the i128 accumulator wraps and would store an arbitrary wrong"
        + " value.",
    )


# --- schema refusals -----------------------------------------------------------


def test_schema_refusals() raises:
    var l0 = List[Field]()
    l0.append(Field(String("l"), ArrowType.LIST, True))
    assert_equal(
        _err_of(String("{}\n"), _schema(l0^)),
        "materialize_jsonl_to_batch: LIST column 'l' must have exactly 1 child"
        " Field for the inner type (got 0). Use Field.list_of_string or"
        " add_child to declare it.",
    )
    var two = _nested(String("l"), ArrowType.LIST, ArrowType.INT64)
    two.add_child(String("x"), ArrowType.INT64, True)
    var l2 = List[Field]()
    l2.append(two^)
    _has(_err_of(String("{}\n"), _schema(l2^)), "inner type (got 2)")
    var s0 = List[Field]()
    s0.append(Field(String("s"), ArrowType.STRUCT, True))
    assert_equal(
        _err_of(String("{}\n"), _schema(s0^)),
        "materialize_jsonl_to_batch: STRUCT column 's' must have at least 1"
        " child Field",
    )
    var m0 = List[Field]()
    m0.append(Field(String("m"), ArrowType.MAP, True))
    assert_equal(
        _err_of(String("{}\n"), _schema(m0^)),
        "materialize_jsonl_to_batch: MAP column 'm' must have exactly 1 child"
        " Field for the value type (got 0)",
    )
    var mtwo = _nested(String("m"), ArrowType.MAP, ArrowType.INT64)
    mtwo.add_child(String("x"), ArrowType.INT64, True)
    var m2 = List[Field]()
    m2.append(mtwo^)
    _has(_err_of(String("{}\n"), _schema(m2^)), "value type (got 2)")
    var msg = _err_of(String("{}\n"), _one(String("n"), ArrowType.INT32))
    _starts(
        msg,
        "materialize_jsonl_to_batch: column 'n' has Arrow type "
        + String(Int(ArrowType.INT32.type_id)) + " not supported",
    )


# --- value refusals and mismatches ----------------------------------------------


def test_unquoted_string_and_date_refused() raises:
    assert_equal(
        _err_of(String('{"s":12}\n'), _one(String("s"), ArrowType.STRING)),
        "komira_jsonl: line 1: materialize_jsonl_to_batch: STRING column 's'"
        " but value is unquoted scalar at byte 5",
    )
    assert_equal(
        _err_of(String('{}\n{"d":20697}\n'), _one(String("d"), ArrowType.DATE32)),
        "komira_jsonl: line 2: materialize_jsonl_to_batch: DATE32 column 'd'"
        ' expects a quoted ISO 8601 string "YYYY-MM-DD" but value is unquoted'
        " at byte 8",
    )


def test_nested_value_for_other_kind_refused() raises:
    var cases = List[String]()
    cases.append(String('{"i":[1]}'))
    cases.append(String('{"l":{}}'))
    cases.append(String('{"t":[]}'))
    cases.append(String('{"m":[]}'))
    var kinds = List[String]()
    kinds.append(String("'i' got a nested JSON value but the schema's Arrow type (kind 0)"))
    kinds.append(String("'l' got a nested JSON value but the schema's Arrow type (kind 6)"))
    kinds.append(String("'t' got a nested JSON value but the schema's Arrow type (kind 7)"))
    kinds.append(String("'m' got a nested JSON value but the schema's Arrow type (kind 8)"))
    for k in range(len(cases)):
        var msg = _err_of(cases[k] + "\n", _all_kinds())
        _starts(msg, "komira_jsonl: line 1: materialize_jsonl_to_batch: key ")
        _has(msg, kinds[k])


def test_scalar_for_nested_column_refused() raises:
    # A number or literal for a LIST, STRUCT or MAP column is refused, as an
    # unquoted value for a STRING or DATE32 column is. It read as NULL
    # before #917 was fixed; test_jsonl_nested_nulls.mojo pins each message.
    var cases = List[String]()
    cases.append(String('{"l":5}'))
    cases.append(String('{"t":true}'))
    cases.append(String('{"m":1.5}'))
    var words = List[String]()
    words.append(String("LIST column 'l' expects a JSON array"))
    words.append(String("STRUCT column 't' expects a JSON object"))
    words.append(String("MAP column 'm' expects a JSON object"))
    for k in range(len(cases)):
        var msg = _err_of(cases[k] + "\n", _all_kinds())
        _starts(msg, "komira_jsonl: line 1: materialize_jsonl_to_batch: ")
        _has(msg, words[k])


def test_tab_and_cr_around_scalar() raises:
    var f = List[Field]()
    f.append(Field(String("i"), ArrowType.INT64, True))
    f.append(Field(String("j"), ArrowType.INT64, True))
    var batch = _read(String('{"i":\t7\r,"j": 8 }\n'), _schema(f^))
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(0)), 7)
    assert_equal(Int(batch.column_at(1).as_primitive[DType.int64]().get(0)), 8)


def test_is_ws_is_rfc8259_whitespace() raises:
    # RFC 8259 section 2: ws = space, horizontal tab, line feed, carriage
    # return. JSONTestSuite n_structure_whitespace_formfeed (`[\x0c]`):
    # form feed is not whitespace.
    assert_true(_is_ws(UInt8(0x20)))
    assert_true(_is_ws(UInt8(0x09)))
    assert_true(_is_ws(UInt8(0x0A)))
    assert_true(_is_ws(UInt8(0x0D)))
    assert_false(_is_ws(UInt8(0x0C)))
    assert_false(_is_ws(UInt8(0x0B)))
    assert_false(_is_ws(UInt8(0x00)))


def _wide(n: Int) -> Schema:
    var f = List[Field]()
    for i in range(n):
        f.append(Field(String("c") + String(i), ArrowType.INT64, True))
    return _schema(f^)


def test_cell_budget_boundary() raises:
    # 256 cells per input byte, budget 256 * (len + 1) // columns rows:
    # `{}` is 2 bytes, 768 // 700 = 1 row (one row passes), 768 // 1000 = 0
    # rows (the first row is refused, naming its line).
    var ok = _read(String("{}"), _wide(700))
    assert_equal(ok.num_rows(), 1)
    var msg = _err_of(String("{}"), _wide(1000))
    _starts(msg, "komira_jsonl: line 1: JSON reader: materializing 1 rows x 1000 columns")


# --- JSONTestSuite y_object_* cases (byte for byte) ------------------------------


def test_jsontestsuite_y_objects() raises:
    # y_object_basic.json
    var b = _read(String('{"asd":"sdf"}'), _one(String("asd"), ArrowType.STRING))
    assert_equal(b.column_at(0).as_string().get(0), String("sdf"))
    # y_object.json
    var f = List[Field]()
    f.append(Field(String("dfg"), ArrowType.STRING, True))
    f.append(Field(String("asd"), ArrowType.STRING, True))
    var b2 = _read(String('{"asd":"sdf", "dfg":"fgh"}'), _schema(f^))
    assert_equal(b2.column_at(0).as_string().get(0), String("fgh"))
    assert_equal(b2.column_at(1).as_string().get(0), String("sdf"))
    # y_object_empty_key.json
    var b3 = _read(String('{"":0}'), _one(String(""), ArrowType.INT64))
    assert_false(b3.column_at(0).is_null_at(0))
    assert_equal(Int(b3.column_at(0).as_primitive[DType.int64]().get(0)), 0)
    # y_object_escaped_null_in_key.json: the key decodes to f o o NUL b a r.
    var nul_key = String("foo") + chr(0) + "bar"
    var b4 = _read(String('{"foo\\u0000bar": 42}'), _one(nul_key, ArrowType.INT64))
    assert_equal(Int(b4.column_at(0).as_primitive[DType.int64]().get(0)), 42)
    var b4u = _read(String('{"foo\\u0000bar": 42}'), _one(String("foobar"), ArrowType.INT64))
    assert_true(b4u.column_at(0).is_null_at(0))
    # y_object_extreme_numbers.json
    var g = List[Field]()
    g.append(Field(String("min"), ArrowType.FLOAT64, True))
    g.append(Field(String("max"), ArrowType.FLOAT64, True))
    var b5 = _read(String('{ "min": -1.0e+28, "max": 1.0e+28 }'), _schema(g^))
    assert_equal(b5.column_at(0).as_primitive[DType.float64]().get(0), -1.0e28)
    assert_equal(b5.column_at(1).as_primitive[DType.float64]().get(0), 1.0e28)
    # y_object_simple.json: an empty list, valid.
    var h = List[Field]()
    h.append(_nested(String("a"), ArrowType.LIST, ArrowType.INT64))
    var b6 = _read(String('{"a":[]}'), _schema(h^))
    var la = b6.column_at(0).as_list()
    assert_false(la.is_null(0))
    assert_equal(la.get_length(0), 0)
    # y_object_duplicated_key.json: refused for a key the schema reads,
    # skipped when the schema does not read it.
    var dup = String('{"a":"b","a":"c"}')
    _starts(
        _err_of(dup, _one(String("a"), ArrowType.STRING)),
        "komira_jsonl: line 1: duplicate key 'a' in one object",
    )
    var b7 = _read(dup, _one(String("z"), ArrowType.STRING))
    assert_equal(b7.num_rows(), 1)
    assert_true(b7.column_at(0).is_null_at(0))


# --- the row walk's own guards (no line check in front) --------------------------


def _walk_err(text: String, idx: StructuralIndex, var schema: Schema) raises -> String:
    var b = _bytes_of(text)
    var row_start = -1
    try:
        var batch = _walk_jsonl_rows(Span(b), schema^, idx, row_start)
        _ = batch^
    except e:
        return String(e)
    raise Error("walk did not refuse: " + text)


def _tape(text: String) raises -> StructuralIndex:
    var b = _bytes_of(text)
    return build_structural_index(Span(b))


def _first(idx: StructuralIndex, k: Int) -> StructuralIndex:
    var o = List[UInt32]()
    var t = List[UInt8]()
    for i in range(k):
        o.append(idx.offsets[i])
        t.append(idx.tags[i])
    return StructuralIndex(o^, t^)


def test_walk_guards_on_jsontestsuite_tapes() raises:
    var w = String("materialize_jsonl_to_batch: ")
    var a = _one(String("a"), ArrowType.INT64)
    # n_object_non_string_key.json `{1:1}`: the token after `{` is `:`.
    var t1 = String("{1:1}")
    assert_equal(
        _walk_err(t1, _tape(t1), a.copy()),
        w + "expected TAG_QUOTE_OPEN at tape position 1, got tag="
        + String(Int(TAG_COLON)),
    )
    # n_object_no-colon.json `{"a"`: the tape ends after the key.
    var t2 = String('{"a"')
    assert_equal(
        _walk_err(t2, _tape(t2), a.copy()),
        w + "expected TAG_COLON after key at byte 1",
    )
    # n_object_missing_colon.json `{"a" b}`: `}` follows the key.
    var t3 = String('{"a" b}')
    assert_equal(
        _walk_err(t3, _tape(t3), a.copy()),
        w + "expected TAG_COLON after key at byte 1",
    )
    # n_object_missing_value.json `{"a":`: the tape ends after the colon.
    var t4 = String('{"a":')
    assert_equal(
        _walk_err(t4, _tape(t4), a.copy()),
        w + "truncated input (expected value after colon)",
    )
    # n_object_double_colon.json `{"x"::"b"}`: nothing between the colons.
    var t5 = String('{"x"::"b"}')
    assert_equal(
        _walk_err(t5, _tape(t5), a.copy()),
        w + "empty scalar value after key at byte 1",
    )


def test_walk_guards_on_cut_tapes() raises:
    var w = String("materialize_jsonl_to_batch: ")
    var a = _one(String("asd"), ArrowType.STRING)
    # y_object_basic.json `{"asd":"sdf"}`: tape { " " : " " } at 0 1 5 6 7 11 12.
    var text = String('{"asd":"sdf"}')
    var full = _tape(text)
    assert_equal(full.size(), 7)
    var key_msg = w + "missing TAG_QUOTE_CLOSE for key at byte 1"
    assert_equal(_walk_err(text, _first(full, 2), a.copy()), key_msg)
    var retag = full.copy()
    retag.tags[2] = TAG_COLON
    assert_equal(_walk_err(text, retag, a.copy()), key_msg)
    var val_msg = w + "missing TAG_QUOTE_CLOSE for string value at byte 7"
    assert_equal(_walk_err(text, _first(full, 5), a.copy()), val_msg)
    var retag2 = full.copy()
    retag2.tags[5] = TAG_CLOSE_BRACE
    assert_equal(_walk_err(text, retag2, a.copy()), val_msg)


def test_walk_skips_what_it_does_not_understand() raises:
    var z = _one(String("z"), ArrowType.INT64)
    # n_structure_open_array_open_object.json `[{`: the `[` is skipped, the
    # `{` opens a row the tape never closes; the row reads z as NULL.
    var t1 = String("[{")
    var b1 = _bytes_of(t1)
    var rs = -1
    var batch = _walk_jsonl_rows(Span(b1), z.copy(), _tape(t1), rs)
    assert_equal(batch.num_rows(), 1)
    assert_true(batch.column_at(0).is_null_at(0))
    assert_equal(rs, -1)
    # y_object_simple.json `{"a":[]}` with the tape cut after `[`: the skip
    # of the unread nested value stops at the end of the tape.
    var t2 = String('{"a":[]}')
    var b2 = _bytes_of(t2)
    var batch2 = _walk_jsonl_rows(Span(b2), z.copy(), _first(_tape(t2), 5), rs)
    assert_equal(batch2.num_rows(), 1)
    assert_true(batch2.column_at(0).is_null_at(0))
    # RFC 8259 section 2 allows LF around a value: `{"a":1<LF>}` is one JSON
    # text on two lines. The line check refuses it as JSONL, so only the
    # walk without it trims an LF after a scalar.
    var t3 = String('{"a":1\n}')
    var b3 = _bytes_of(t3)
    var batch3 = _walk_jsonl_rows(Span(b3), _ab_schema(), _tape(t3), rs)
    assert_equal(_i64(batch3, 0), 1)


# --- line ranges and the parallel entries ----------------------------------------


def test_line_ranges_degenerate() raises:
    var b = _bytes_of(String('{"a":1}\n{"a":22222222}'))
    var los = List[Int]()
    var his = List[Int]()
    los.append(9)
    his.append(9)
    # One worker: the whole input, the lists cleared first.
    _compute_jsonl_line_ranges(Span(b), len(b), 1, los, his)
    assert_equal(len(los), 1)
    assert_equal(los[0], 0)
    assert_equal(his[0], len(b))
    # An empty input: one empty range.
    _compute_jsonl_line_ranges(Span(b), 0, 4, los, his)
    assert_equal(len(los), 1)
    assert_equal(los[0], 0)
    assert_equal(his[0], 0)
    # Two workers, the midpoint past the last LF: no boundary, one range.
    _compute_jsonl_line_ranges(Span(b), len(b), 2, los, his)
    assert_equal(len(los), 1)
    assert_equal(his[0], len(b))


def _ab_schema() -> Schema:
    return _one(String("a"), ArrowType.INT64)


def _i64(batch: RecordBatch, row: Int) raises -> Int:
    return Int(batch.column_at(0).as_primitive[DType.int64]().get(row))


def test_parallel_small_input_worker_counts() raises:
    var b = _bytes_of(String('{"a":1}\n{"a":2}\n'))
    # 0 workers: the core count; 33: capped at 32; below 4 MiB both read
    # serially, so these rows do not see the cap (the next test does).
    var r0 = materialize_jsonl_to_batch_parallel(Span(b), _ab_schema())
    assert_equal(r0.num_rows(), 2)
    assert_equal(_i64(r0, 1), 2)
    var r33 = materialize_jsonl_to_batch_parallel(Span(b), _ab_schema(), 33)
    assert_equal(r33.num_rows(), 2)
    assert_equal(_i64(r33, 0), 1)


def _pad_line(mut out: List[UInt8], lf_at: Int):
    # `{`, spaces, `}`, LF: one record whose LF lands at byte `lf_at`.
    out.append(UInt8(0x7B))
    while len(out) < lf_at - 1:
        out.append(UInt8(0x20))
    out.append(UInt8(0x7D))
    out.append(UInt8(0x0A))


comptime _CAP_SPAN = 131200  # n / 32, with n = 32 * 131200 past 4 MiB


def _cap_input() -> List[UInt8]:
    # A padding line whose LF is the first at or past n*w/32 for w < 16,
    # 101 `{}` lines whose last LF is the first past 16n/32, a padding line
    # to the end. 32 ranges: the `{}` lines are a 303-byte range of their
    # own. 33 ranges: 16n/33 and 17n/33 fall before and after them, so they
    # share a 2 MiB range with the second padding line.
    var s = _CAP_SPAN
    var out = List[UInt8](capacity=32 * s)
    _pad_line(out, 16 * s - 301)
    for _ in range(101):
        out.append(UInt8(0x7B))
        out.append(UInt8(0x7D))
        out.append(UInt8(0x0A))
    _pad_line(out, 32 * s - 1)
    return out^


def test_parallel_worker_cap_decides_the_ranges() raises:
    var b = _cap_input()
    var los = List[Int]()
    var his = List[Int]()
    _compute_jsonl_line_ranges(Span(b), len(b), 32, los, his)
    assert_equal(len(los), 3)
    assert_equal(los[1], 16 * _CAP_SPAN - 300)
    assert_equal(his[1] - los[1], 303)
    _compute_jsonl_line_ranges(Span(b), len(b), 33, los, his)
    assert_equal(len(los), 2)
    # Each range has its own cell budget, 256 * (bytes + 1) // columns rows.
    # 1000 columns: the 303-byte range fits 77 rows and refuses the 78th
    # (line 79, after the first padding line); a 2 MiB range fits every
    # row. 33 workers asked, capped at 32: the 303-byte range is read on its
    # own and refused, naming its own byte count. A cap above 32 reads it
    # inside a 2 MiB range and returns 103 rows.
    var msg = String()
    var rows = -1
    try:
        var r = materialize_jsonl_to_batch_parallel(Span(b), _wide(1000), 33)
        rows = r.num_rows()
    except e:
        msg = String(e)
    assert_equal(rows, -1)
    _starts(
        msg,
        "komira_jsonl: line 79: JSON reader: materializing 78 rows x 1000"
        + " columns = 78000 accumulator cells from a 303-byte input,"
        + " exceeding the budget of 256 cells per input byte.",
    )


def _big_one_line() -> List[UInt8]:
    # `{`, 4 MiB of spaces, `}`: one JSONL record and no LF.
    var n = 4 * 1024 * 1024 + 2
    var out = List[UInt8](capacity=n)
    out.append(UInt8(0x7B))
    for _ in range(n - 2):
        out.append(UInt8(0x20))
    out.append(UInt8(0x7D))
    return out^


def test_parallel_4mib_one_line() raises:
    var b = _big_one_line()
    # One worker asked for: serial.
    var r1 = materialize_jsonl_to_batch_parallel(Span(b), _ab_schema(), 1)
    assert_equal(r1.num_rows(), 1)
    assert_true(r1.column_at(0).is_null_at(0))
    # Two workers, but no LF to split at: one range, serial.
    var r2 = materialize_jsonl_to_batch_parallel(Span(b), _ab_schema(), 2)
    assert_equal(r2.num_rows(), 1)
    assert_true(r2.column_at(0).is_null_at(0))


def _parts(var los: List[Int], var his: List[Int], n_idx: Int, b: List[UInt8]) raises -> JsonlPartitions:
    var ix = List[StructuralIndex]()
    for _ in range(n_idx):
        ix.append(build_structural_index(Span(b)))
    return JsonlPartitions(los^, his^, ix^)


def test_partitions_that_disagree_fall_back() raises:
    var b = _bytes_of(String('{"a":1}\n{"a":2}\n'))
    var n = len(b)
    var one = List[Int]()
    one.append(0)
    var end = List[Int]()
    end.append(n)
    # No partition; his shorter than los; indices shorter than los.
    for c in range(3):
        var lo = List[Int]() if c == 0 else one.copy()
        var hi = end.copy() if c == 2 else List[Int]()
        var r = materialize_jsonl_to_batch_parallel_with_partitions(
            Span(b), _ab_schema(), _parts(lo^, hi^, 1 if c == 1 else 0, b)
        )
        assert_equal(r.num_rows(), 2)
        assert_equal(_i64(r, 1), 2)


def test_partitions_outside_the_input_refused() raises:
    var b = _bytes_of(String('{"a":1}\n{"a":2}\n'))
    var n = len(b)
    var bad_lo = List[Int]()
    bad_lo.append(-1)
    bad_lo.append(5)
    bad_lo.append(0)
    var bad_hi = List[Int]()
    bad_hi.append(n)
    bad_hi.append(3)
    bad_hi.append(n + 1)
    for k in range(3):
        var lo = List[Int]()
        lo.append(bad_lo[k])
        var hi = List[Int]()
        hi.append(bad_hi[k])
        var msg = String()
        try:
            _ = materialize_jsonl_to_batch_parallel_with_partitions(
                Span(b), _ab_schema(), _parts(lo^, hi^, 1, b)
            )
        except e:
            msg = String(e)
        _starts(
            msg,
            "materialize_jsonl_to_batch_parallel_with_partitions: partition 0"
            " has byte range [" + String(bad_lo[k]) + ", " + String(bad_hi[k])
            + ") which is not a valid sub-range of the " + String(n)
            + "-byte input.",
        )


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _big_lines(mut rows: Int) -> List[UInt8]:
    # Lines `{` + 1000 spaces + `"a":<line index>}` LF, past 4 MiB: each
    # row holds its own index, so parts joined out of order fail.
    var out = List[UInt8]()
    var pad = String("{")
    for _ in range(1000):
        pad += " "
    rows = 0
    while len(out) <= 4 * 1024 * 1024:
        var line = pad + '"a":' + String(rows) + "}\n"
        out.extend(Span(line.as_bytes()))
        rows += 1
    return out^


def test_dispatcher_entries() raises:
    # One worker: the dispatcher path runs, and the chunks run one at a
    # time, so the instrumented branch counters are not raced.
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var small = _bytes_of(String('{"a":1}\n{"a":2}\n'))
    # Two partitions, each with its own tape, read on the dispatcher.
    var los = List[Int]()
    los.append(0)
    los.append(8)
    var his = List[Int]()
    his.append(8)
    his.append(16)
    var ix = List[StructuralIndex]()
    ix.append(build_structural_index(Span(small)[0:8]))
    ix.append(build_structural_index(Span(small)[8:16]))
    var r = materialize_jsonl_to_batch_parallel_with_partitions_with_dispatcher[
        origin_of(disp)
    ](
        Span(small), _ab_schema(), JsonlPartitions(los^, his^, ix^),
        Pointer(to=disp), CancellationToken.never(),
    )
    assert_equal(r.num_rows(), 2)
    assert_equal(_i64(r, 0), 1)
    assert_equal(_i64(r, 1), 2)
    # No partitions: the dispatcher's own parallel read (serial below 4 MiB).
    var r2 = materialize_jsonl_to_batch_parallel_with_partitions_with_dispatcher[
        origin_of(disp)
    ](
        Span(small), _ab_schema(), _parts(List[Int](), List[Int](), 0, small),
        Pointer(to=disp), CancellationToken.never(),
    )
    assert_equal(r2.num_rows(), 2)
    assert_equal(_i64(r2, 1), 2)
    # Past 4 MiB, two line ranges: each read on the dispatcher, joined
    # in order.
    var rows = 0
    var big = _big_lines(rows)
    var r3 = materialize_jsonl_to_batch_parallel_with_dispatcher[origin_of(disp)](
        Span(big), _ab_schema(), Pointer(to=disp), CancellationToken.never(), 2
    )
    assert_equal(r3.num_rows(), rows)
    var col = r3.column_at(0).as_primitive[DType.int64]()
    for i in range(rows):
        assert_equal(Int(col.get(i)), i)
    _ = rt^


# --- ColumnarMaterializer.init_for_schema ----------------------------------------


def test_struct_driver_init() raises:
    var f = List[Field]()
    f.append(Field(String("i"), ArrowType.INT64, True))
    f.append(Field(String("b"), ArrowType.BOOL, True))
    f.append(Field(String("s"), ArrowType.STRING, True))
    var m = ColumnarMaterializer.init_for_schema(_schema(f^))
    assert_equal(len(m.col_kinds), 3)
    assert_equal(Int(m.col_kinds[0]), 0)
    assert_equal(Int(m.col_kinds[1]), 1)
    assert_equal(Int(m.col_kinds[2]), 2)
    assert_equal(m.row_count, 0)
    var key_s = String("s")
    assert_equal(m.key_table.lookup(key_s.as_bytes()), 2)
    var msg = String()
    try:
        _ = ColumnarMaterializer.init_for_schema(_one(String("x"), ArrowType.FLOAT64))
    except e:
        msg = String(e)
    _starts(
        msg,
        "ColumnarMaterializer.init_for_schema: column 'x' has Arrow type "
        + String(Int(ArrowType.FLOAT64.type_id)) + " which is not supported",
    )


def main() raises:
    test_list_of_float_bool_date()
    test_struct_of_every_type_null_and_missing()
    test_map_of_float_bool_string_date()
    test_unsupported_inner_type_refused_at_build()
    test_every_kind_null_missing_valid()
    test_decimal_string_number_and_defaults()
    test_schema_refusals()
    test_unquoted_string_and_date_refused()
    test_nested_value_for_other_kind_refused()
    test_scalar_for_nested_column_refused()
    test_tab_and_cr_around_scalar()
    test_is_ws_is_rfc8259_whitespace()
    test_cell_budget_boundary()
    test_jsontestsuite_y_objects()
    test_walk_guards_on_jsontestsuite_tapes()
    test_walk_guards_on_cut_tapes()
    test_walk_skips_what_it_does_not_understand()
    test_line_ranges_degenerate()
    test_parallel_small_input_worker_counts()
    test_parallel_worker_cap_decides_the_ranges()
    test_parallel_4mib_one_line()
    test_partitions_that_disagree_fall_back()
    test_partitions_outside_the_input_refused()
    test_dispatcher_entries()
    test_struct_driver_init()
    print("test_columnar_materializer_branches: all passed")
