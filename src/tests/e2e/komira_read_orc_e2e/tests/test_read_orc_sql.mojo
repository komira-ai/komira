# =============================================================================
# read_orc through run_sql, by value
# =============================================================================
#
# The six input files were written by pyarrow's ORC C++ writer
# (komira_formats_e2e's tests/fixtures/orc; gen_pyarrow_orc_fixtures.py there
# is their provenance). Every expected value below is recomputed from the
# generator's rules, never from a komira read:
#
#   pyarrow_nullable_mixed.orc and pyarrow_nullable_codec_<codec>.orc, 1200
#   rows: id BIGINT = row; label VARCHAR NULL when row%3==0, else
#   ["x","y","z","w"][row%4]; nint BIGINT NULL when row%5==0, else row*10;
#   nflt DOUBLE NULL when row%7==0, else row+0.5.
#   pyarrow_multistripe_nullable.orc, 3000 rows in three stripes: id BIGINT =
#   row; label VARCHAR NULL when row%4==0, else ["x","y","z","w"][row%4]; flag
#   BOOLEAN NULL when row%6==0, else row%2==0.
#
# What each test proves:
#   * test_<codec>_file_reads_every_row_and_null (none, zlib, snappy, zstd,
#     lz4): `SELECT * ... ORDER BY id` gives the columns id, label, nint, nflt
#     in file order at BIGINT, VARCHAR, BIGINT, DOUBLE, and every value and
#     NULL of all 1200 rows. Catches a codec the SQL path cannot read (the
#     footer is compressed in four of the five), a column bound at another
#     type, and NULLs dropped or shifted.
#   * test_a_file_of_three_stripes_reads_every_row: every row of the
#     three-stripe file, with its BOOLEAN column, once. Catches rows lost at a
#     stripe boundary.
#   * test_a_projection_is_only_its_columns_in_query_order: `SELECT nflt,
#     label` gives exactly those two columns, in that order (DuckDB's
#     select-list order, not file order).
#   * test_a_filter_keeps_its_rows: `SELECT id, nint ... WHERE id > 3`, the
#     filter on a projected column.
#   * test_a_filter_on_a_column_left_out_keeps_its_rows: `SELECT label ...
#     WHERE nint > 11000`, the filter on a column the select list leaves out.
#   * test_count_star_and_count_of_a_column: count(*) is 1200 and
#     count(label) 800 (the NULLs not counted).
#   * test_a_grouped_aggregate_has_a_null_group: count(*) and sum(nint) by
#     label, the NULL label a group of its own.
#   * test_the_other_column_types_read_by_value: a file written here with
#     BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT, FLOAT, DOUBLE, VARCHAR and
#     DATE columns reads back at those types and values.
#   * test_a_missing_file_is_refused_naming_it,
#     test_a_file_that_is_not_orc_is_refused_by_name,
#     test_an_option_is_refused, test_a_glob_is_refused,
#     test_a_struct_column_is_refused, test_a_list_column_is_refused and
#     test_a_timestamp_column_is_refused: each is a refusal (never a crash or
#     rows) whose step and text name what was refused.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from async_rt.ops.waker_sink import NoopSink
from fs.file_system import WriteMode
from fs.local_fs import LocalFs
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from orc import (
    ORC_COMPRESSION_NONE,
    ORC_KIND_INT,
    ORC_KIND_LIST,
    ORC_KIND_LONG,
    ORC_KIND_STRING,
    ORC_KIND_STRUCT,
    ORC_KIND_TIMESTAMP,
    OrcWriterOptions,
    encode_footer,
    encode_post_script,
    encode_type_node,
    write_orc_file,
)
from runtime_paths import data_path, test_tmpdir
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_PARSE, run_sql

comptime _MIXED_ROWS = 1200
comptime _MULTI_ROWS = 3000


# ---- the generator's rules ------------------------------------------------


def _cat(r: Int) -> String:
    var c: List[String] = ["x", "y", "z", "w"]
    return c[r % 4]


def _label_mixed(r: Int) -> Optional[String]:
    if r % 3 == 0:
        return None
    return _cat(r)


def _nint(r: Int) -> Optional[Int64]:
    if r % 5 == 0:
        return None
    return Int64(r * 10)


def _nflt(r: Int) -> Optional[Float64]:
    if r % 7 == 0:
        return None
    return Float64(r) + 0.5


def _label_multi(r: Int) -> Optional[String]:
    if r % 4 == 0:
        return None
    return _cat(r)


def _flag(r: Int) -> Optional[Bool]:
    if r % 6 == 0:
        return None
    return r % 2 == 0


# ---- running a query --------------------------------------------------------


def _ctx() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _q(path: String) -> String:
    """`path` as a SQL string literal."""
    return "'" + path.replace("'", "''") + "'"


def _rows(sql: String) raises -> RecordBatch:
    var ctx = _ctx()
    var outcome = run_sql(ctx, sql)
    if outcome.refusal:
        ref r = outcome.refusal.value()
        raise Error(sql + ": refused at " + r.step + ": " + r.reason)
    assert_equal(len(outcome.batches), 1, sql + ": one batch")
    return outcome.batches.pop()


def _refusal(sql: String, step: String) raises -> String:
    """The reason `sql` is refused with, after checking it is refused at
    `step`."""
    var ctx = _ctx()
    var outcome = run_sql(ctx, sql)
    assert_true(Bool(outcome.refusal), sql + ": expected a refusal")
    ref r = outcome.refusal.value()
    assert_equal(r.step, step, sql + ": " + r.reason)
    return r.reason


def _columns(schema: Schema) -> String:
    var out = String("")
    for i in range(schema.num_columns()):
        if i > 0:
            out += ", "
        out += schema.field_name(i) + ":" + String(schema.field_arrow_type(i))
    return out^


def _check_i64(
    b: RecordBatch, col: Int, row: Int, want: Optional[Int64], what: String
) raises:
    var a = b.column_as_primitive_int64(col)
    if want:
        assert_true(not a.is_null(row), what + ": NULL, want a value")
        assert_equal(a.get(row), want.value(), what)
    else:
        assert_true(a.is_null(row), what + ": want NULL")


def _check_f64(
    b: RecordBatch, col: Int, row: Int, want: Optional[Float64], what: String
) raises:
    var a = b.column_as_primitive_float64(col)
    if want:
        assert_true(not a.is_null(row), what + ": NULL, want a value")
        assert_true(a.get(row) == want.value(), what + ": " + String(a.get(row)))
    else:
        assert_true(a.is_null(row), what + ": want NULL")


def _check_str(
    b: RecordBatch, col: Int, row: Int, want: Optional[String], what: String
) raises:
    var a = b.column_as_string(col)
    if want:
        assert_true(not a.is_null(row), what + ": NULL, want a value")
        assert_equal(String(a.get(row)), want.value(), what)
    else:
        assert_true(a.is_null(row), what + ": want NULL")


def _check_mixed(name: String) raises:
    var b = _rows(
        "SELECT * FROM read_orc(" + _q(data_path(name)) + ") ORDER BY id"
    )
    assert_equal(
        _columns(b.schema),
        "id:"
        + String(ArrowType.INT64)
        + ", label:"
        + String(ArrowType.STRING)
        + ", nint:"
        + String(ArrowType.INT64)
        + ", nflt:"
        + String(ArrowType.FLOAT64),
        name,
    )
    assert_equal(b.num_rows(), _MIXED_ROWS, name)
    for r in range(_MIXED_ROWS):
        var at = name + " row " + String(r)
        _check_i64(b, 0, r, Optional(Int64(r)), at + " id")
        _check_str(b, 1, r, _label_mixed(r), at + " label")
        _check_i64(b, 2, r, _nint(r), at + " nint")
        _check_f64(b, 3, r, _nflt(r), at + " nflt")


def test_none_file_reads_every_row_and_null() raises:
    _check_mixed("pyarrow_nullable_mixed.orc")


def test_zlib_file_reads_every_row_and_null() raises:
    _check_mixed("pyarrow_nullable_codec_zlib.orc")


def test_snappy_file_reads_every_row_and_null() raises:
    _check_mixed("pyarrow_nullable_codec_snappy.orc")


def test_zstd_file_reads_every_row_and_null() raises:
    _check_mixed("pyarrow_nullable_codec_zstd.orc")


def test_lz4_file_reads_every_row_and_null() raises:
    _check_mixed("pyarrow_nullable_codec_lz4.orc")


def test_a_file_of_three_stripes_reads_every_row() raises:
    var path = data_path("pyarrow_multistripe_nullable.orc")
    var b = _rows("SELECT * FROM read_orc(" + _q(path) + ") ORDER BY id")
    assert_equal(
        _columns(b.schema),
        "id:"
        + String(ArrowType.INT64)
        + ", label:"
        + String(ArrowType.STRING)
        + ", flag:"
        + String(ArrowType.BOOL),
    )
    assert_equal(b.num_rows(), _MULTI_ROWS)
    var flags = b.column_as_boolean(2)
    for r in range(_MULTI_ROWS):
        var at = "row " + String(r)
        _check_i64(b, 0, r, Optional(Int64(r)), at + " id")
        _check_str(b, 1, r, _label_multi(r), at + " label")
        var want = _flag(r)
        if want:
            assert_true(not flags.is_null(r), at + " flag: NULL")
            assert_equal(flags.get(r), want.value(), at + " flag")
        else:
            assert_true(flags.is_null(r), at + " flag: want NULL")


def _mixed() -> String:
    return _q(data_path("pyarrow_nullable_codec_zstd.orc"))


def test_a_projection_is_only_its_columns_in_query_order() raises:
    var b = _rows("SELECT nflt, label FROM read_orc(" + _mixed() + ") ORDER BY id")
    assert_equal(
        _columns(b.schema),
        "nflt:" + String(ArrowType.FLOAT64) + ", label:" + String(ArrowType.STRING),
    )
    assert_equal(b.num_rows(), _MIXED_ROWS)
    for r in range(_MIXED_ROWS):
        _check_f64(b, 0, r, _nflt(r), "row " + String(r) + " nflt")
        _check_str(b, 1, r, _label_mixed(r), "row " + String(r) + " label")


def test_a_filter_keeps_its_rows() raises:
    var b = _rows(
        "SELECT id, nint FROM read_orc(" + _mixed() + ") WHERE id > 3 ORDER BY id"
    )
    assert_equal(
        _columns(b.schema),
        "id:" + String(ArrowType.INT64) + ", nint:" + String(ArrowType.INT64),
    )
    assert_equal(b.num_rows(), _MIXED_ROWS - 4)
    for i in range(b.num_rows()):
        var r = i + 4
        _check_i64(b, 0, i, Optional(Int64(r)), "row " + String(r) + " id")
        _check_i64(b, 1, i, _nint(r), "row " + String(r) + " nint")


def test_a_filter_on_a_column_left_out_keeps_its_rows() raises:
    var b = _rows(
        "SELECT label FROM read_orc("
        + _mixed()
        + ") WHERE nint > 11000 ORDER BY id"
    )
    assert_equal(_columns(b.schema), "label:" + String(ArrowType.STRING))
    var kept = List[Int]()
    for r in range(_MIXED_ROWS):
        var n = _nint(r)
        if n and n.value() > 11000:
            kept.append(r)
    assert_equal(b.num_rows(), len(kept))
    for i in range(len(kept)):
        _check_str(b, 0, i, _label_mixed(kept[i]), "row " + String(kept[i]))


def test_count_star_and_count_of_a_column() raises:
    var b = _rows(
        "SELECT count(*) AS n, count(label) AS labelled FROM read_orc("
        + _mixed()
        + ")"
    )
    assert_equal(b.num_rows(), 1)
    assert_equal(b.column_as_primitive_int64(0).get(0), Int64(_MIXED_ROWS))
    var labelled = 0
    for r in range(_MIXED_ROWS):
        if _label_mixed(r):
            labelled += 1
    assert_equal(labelled, 800)
    assert_equal(b.column_as_primitive_int64(1).get(0), Int64(labelled))


def test_a_grouped_aggregate_has_a_null_group() raises:
    var b = _rows(
        "SELECT label, count(*) AS n, sum(nint) AS s FROM read_orc("
        + _mixed()
        + ") GROUP BY label ORDER BY label NULLS FIRST"
    )
    # The groups in order: NULL, then w, x, y, z.
    var keys: List[String] = ["", "w", "x", "y", "z"]
    assert_equal(b.num_rows(), len(keys))
    var labels = b.column_as_string(0)
    var counts = b.column_as_primitive_int64(1)
    var sums = b.column_as_primitive_int64(2)
    for g in range(len(keys)):
        var n = 0
        var s = Int64(0)
        for r in range(_MIXED_ROWS):
            var l = _label_mixed(r)
            var same = (not l and g == 0) or (l and l.value() == keys[g])
            if same:
                n += 1
                var v = _nint(r)
                if v:
                    s += v.value()
        if g == 0:
            assert_true(labels.is_null(0), "the first group is NULL")
        else:
            assert_equal(String(labels.get(g)), keys[g])
        assert_equal(counts.get(g), Int64(n), "count of group " + String(g))
        assert_equal(sums.get(g), s, "sum of group " + String(g))


# ---- files written here -----------------------------------------------------


def _scratch(name: String) raises -> String:
    return test_tmpdir() + "/" + name


def test_the_other_column_types_read_by_value() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.BOOL, True))
    sb.add_field(Field("i8", ArrowType.INT8, True))
    sb.add_field(Field("i16", ArrowType.INT16, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var bools: List[Bool] = [True, False, True]
    var i8s: List[Int8] = [-128, 0, 127]
    var i16s: List[Int16] = [-32768, 1, 32767]
    var i32s: List[Int32] = [-2147483648, 2, 2147483647]
    var f32s: List[Float32] = [-1.5, 0.25, 3.0]
    var days: List[Int32] = [-1, 0, 19000]
    var strs: List[String] = ["", "é", "zz"]
    var ab = BooleanArray.allocate(3)
    var a8 = PrimitiveArray[DType.int8].allocate(3)
    var a16 = PrimitiveArray[DType.int16].allocate(3)
    var a32 = PrimitiveArray[DType.int32].allocate(3)
    var af = PrimitiveArray[DType.float32].allocate(3)
    var ad = PrimitiveArray[DType.int32].allocate(3)
    for r in range(3):
        ab.set(r, bools[r])
        a8.set(r, i8s[r])
        a16.set(r, i16s[r])
        a32.set(r, i32s[r])
        af.set(r, f32s[r])
        ad.set(r, days[r])
    var bb = RecordBatchBuilder.with_capacity(7)
    bb.add_column(Column.from_boolean(ab^))
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int8](a8^, ArrowType.INT8)
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int16](a16^, ArrowType.INT16)
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](a32^, ArrowType.INT32)
    )
    bb.add_column(Column.from_primitive[DType.float32](af^))
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](ad^, ArrowType.DATE32)
    )
    bb.add_column(Column.from_string(StringArray.from_strings(strs)))
    var path = _scratch("types.orc")
    write_orc_file(
        bb.build(sb.build()),
        path,
        OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, "UTC"),
    )
    var b = _rows("SELECT * FROM read_orc(" + _q(path) + ") ORDER BY i8")
    assert_equal(
        _columns(b.schema),
        "b:" + String(ArrowType.BOOL)
        + ", i8:" + String(ArrowType.INT8)
        + ", i16:" + String(ArrowType.INT16)
        + ", i32:" + String(ArrowType.INT32)
        + ", f32:" + String(ArrowType.FLOAT32)
        + ", d:" + String(ArrowType.DATE32)
        + ", s:" + String(ArrowType.STRING),
    )
    assert_equal(b.num_rows(), 3)
    for r in range(3):
        var at = "row " + String(r)
        assert_equal(b.column_as_boolean(0).get(r), bools[r], at + " b")
        assert_equal(b.column_as_primitive[DType.int8](1).get(r), i8s[r], at)
        assert_equal(b.column_as_primitive[DType.int16](2).get(r), i16s[r], at)
        assert_equal(b.column_as_primitive[DType.int32](3).get(r), i32s[r], at)
        assert_true(b.column_as_primitive[DType.float32](4).get(r) == f32s[r], at)
        assert_equal(b.column_as_primitive[DType.int32](5).get(r), days[r], at)
        assert_equal(String(b.column_as_string(6).get(r)), strs[r], at + " s")


def _write(path: String, bytes: List[UInt8]) raises:
    var fs = LocalFs[NoopSink].new()
    var f = fs.open_write(path, WriteMode.create_truncate())
    _ = fs.write_at(f, Span(bytes))
    fs.close_write(f^)


def _no_names() -> List[String]:
    return List[String]()


def _no_stripe_file(name: String, var types: List[List[UInt8]]) raises -> String:
    """An uncompressed ORC file of no stripe whose Footer holds `types`,
    written to the scratch directory; its path."""
    var footer = encode_footer(
        3, 0, List[List[UInt8]](), types, 0, List[List[UInt8]](), 0
    )
    var ps = encode_post_script(
        len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORC"
    )
    var out: List[UInt8] = [UInt8(ord("O")), UInt8(ord("R")), UInt8(ord("C"))]
    var ps_len = len(ps)
    out.extend(footer^)
    out.extend(ps^)
    out.append(UInt8(ps_len))
    var path = _scratch(name)
    _write(path, out)
    return path^


def _leaf(kind: Int) -> List[UInt8]:
    return encode_type_node(kind, List[Int](), _no_names(), 0, 0, 0)


def _two_columns(name: String, second: Int, var tail: List[List[UInt8]]) raises -> String:
    """A file of columns `id` (BIGINT) and `c`, whose type node is `second`
    (its children, if any, are `tail`)."""
    var types = List[List[UInt8]]()
    var children: List[Int] = [1, 2]
    var names: List[String] = ["id", "c"]
    types.append(encode_type_node(ORC_KIND_STRUCT, children, names, 0, 0, 0))
    types.append(_leaf(ORC_KIND_LONG))
    if second == ORC_KIND_STRUCT:
        var inner: List[Int] = [3]
        var inner_names: List[String] = ["a"]
        types.append(encode_type_node(ORC_KIND_STRUCT, inner, inner_names, 0, 0, 0))
    elif second == ORC_KIND_LIST:
        var inner: List[Int] = [3]
        types.append(encode_type_node(ORC_KIND_LIST, inner, _no_names(), 0, 0, 0))
    else:
        types.append(_leaf(second))
    for i in range(len(tail)):
        types.append(tail[i].copy())
    return _no_stripe_file(name, types^)


def _refused_at_bind_naming(path: String, *words: String) raises:
    var reason = _refusal(
        "SELECT * FROM read_orc(" + _q(path) + ")", String(STEP_BIND)
    )
    assert_true(path in reason, reason)
    for w in words:
        assert_true(w in reason, reason)


def test_a_struct_column_is_refused() raises:
    var tail = List[List[UInt8]]()
    tail.append(_leaf(ORC_KIND_INT))
    var path = _two_columns("struct.orc", ORC_KIND_STRUCT, tail^)
    _refused_at_bind_naming(path, "'c'", String(ArrowType.STRUCT))


def test_a_list_column_is_refused() raises:
    var tail = List[List[UInt8]]()
    tail.append(_leaf(ORC_KIND_STRING))
    var path = _two_columns("list.orc", ORC_KIND_LIST, tail^)
    _refused_at_bind_naming(path, "'c'", String(ArrowType.LIST))


def test_a_timestamp_column_is_refused() raises:
    var path = _two_columns(
        "timestamp.orc", ORC_KIND_TIMESTAMP, List[List[UInt8]]()
    )
    _refused_at_bind_naming(path, "'c'", String(ArrowType.TIMESTAMP_NS))


def test_a_missing_file_is_refused_naming_it() raises:
    _refused_at_bind_naming(_scratch("no_such_file.orc"), "footer")


def test_a_file_that_is_not_orc_is_refused_by_name() raises:
    var path = _scratch("not_orc.orc")
    var text = String("id,label\n1,x\n")
    var bytes = List[UInt8]()
    for b in text.as_bytes():
        bytes.append(b)
    _write(path, bytes)
    _refused_at_bind_naming(path, "OrcSchemaError.MALFORMED_PROTOBUF")


def test_an_option_is_refused() raises:
    var reason = _refusal(
        "SELECT * FROM read_orc(" + _mixed() + ", compression = 'zstd')",
        String(STEP_PARSE),
    )
    assert_true("read_orc(" in reason and "NO options" in reason, reason)


def test_a_glob_is_refused() raises:
    var reason = _refusal(
        "SELECT * FROM read_orc(" + _q(_scratch("*.orc")) + ")",
        String(STEP_BIND),
    )
    assert_true("glob" in reason, reason)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
