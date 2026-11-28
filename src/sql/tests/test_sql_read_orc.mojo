# =============================================================================
# test_sql_read_orc: the `read_orc('path')` table function, parser to scan leaf.
# =============================================================================
#
# Every ORC file is written by the test under test_tmpdir(): by the ORC writer,
# or, for column types the writer cannot produce, as a footer-only file (the
# magic, a Footer of the given type tree, the PostScript; no stripe, no row).
#
#   1. The parser maps `read_orc('p')` to TVF_ORC with its path; unaliased it
#      answers to "read_orc", and an explicit alias (with or without AS) wins.
#   2. `read_orc('p', x = 1)` is refused with the whole no-options sentence.
#   3. Binding a file written with the ORC writer, under each codec, gives the
#      file's column names in file order at their types, nullable; the scan leaf
#      is the ORC source (SOURCE_VARIANT_ORC) of that path and schema.
#   4. The scan leaf's identity folds the path and the file's mtime: a source
#      built with mtime 0, or over another path, is a different source.
#   5. The nine accepted column types (BOOL, INT8, INT16, INT32, INT64, FLOAT32,
#      FLOAT64, STRING, DATE32) all bind, in file order.
#   6. A struct column and a list column are refused naming the path, the column
#      and the type; so are timestamp, decimal and binary columns.
#   7. A glob path is refused by name, before any file is read.
#   7a. A Hive ACID file (whose `row.*` columns are primitive, so every type
#      check would pass), a file of no column, and a file naming two columns
#      alike up to case are each refused naming the path (and the column).
#   8. A missing file, a zero-byte file and a file that is not ORC are refused
#      with the footer message naming the path.
#   9. `plan_from_sql` of a SELECT with a WHERE over `read_orc` builds a plan
#      whose scan is the ORC source and whose output is the selected columns,
#      without reading any row (the file holds a footer only).

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from arrow_ipc.chunked_read import read_chunked
from byte_buffer.file_identity import FileIdentity
from orc import (
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_ZSTD,
    ORC_KIND_BINARY,
    ORC_KIND_DECIMAL,
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
    read_orc_bytes_schema,
    write_orc_file,
)
from runtime_paths import test_tmpdir
from scan_source.orc_source import OrcSource
from scan_source.source_variant import SOURCE_VARIANT_ORC, SourceVariant
from sql.sql_ast import FromRelation, SqlStatement, TvfOptions, TVF_ORC
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_catalog import SqlCatalog
from sql.sql_frontend import plan_from_sql
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize
from sql.sql_tvf_bind import (
    orc_tvf_schema,
    tvf_relation_scan,
    tvf_relation_schema,
)


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _message(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    return String("")


def _path(name: String) raises -> String:
    return test_tmpdir() + String("/") + name


def _no_names() -> List[String]:
    return List[String]()


def _write_bytes(path: String, bytes: List[UInt8]) raises:
    var handle = open(path, "w")
    handle.write_bytes(Span(bytes))
    handle.close()


def _footer_only_file(
    path: String, var types: List[List[UInt8]]
) raises -> String:
    """An uncompressed ORC file of no stripe and no row, whose Footer holds
    `types`."""
    var footer = encode_footer(
        3, 0, List[List[UInt8]](), types, 0, List[List[UInt8]](), 0
    )
    var ps = encode_post_script(
        len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORC"
    )
    var out: List[UInt8] = [UInt8(ord("O")), UInt8(ord("R")), UInt8(ord("C"))]
    out.extend(footer^)
    out.extend(ps.copy())
    out.append(UInt8(len(ps)))
    _write_bytes(path, out)
    return path


def _file_with_one_column(path: String, kind: Int) raises -> String:
    """A footer-only file of `struct<c: kind>` for a childless `kind`."""
    var types = List[List[UInt8]]()
    var children: List[Int] = [1]
    var names: List[String] = ["c"]
    types.append(encode_type_node(ORC_KIND_STRUCT, children, names, 0, 0, 0))
    types.append(encode_type_node(kind, List[Int](), _no_names(), 0, 10, 2))
    return _footer_only_file(path, types^)


def _three_column_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("zeta", ArrowType.INT64, True))
    sb.add_field(Field("alpha", ArrowType.STRING, True))
    sb.add_field(Field("mid", ArrowType.FLOAT64, True))
    var ids: List[Int64] = [4, 5, 6, 7]
    var names: List[String] = ["a", "bb", "ccc", "dddd"]
    var xs: List[Float64] = [0.5, 1.5, 2.5, 3.5]
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids)
        )
    )
    b.add_column(Column.from_string(StringArray.from_strings(names)))
    b.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(xs)
        )
    )
    return b.build(sb.build())


def _nine_type_batch() raises -> RecordBatch:
    var n = 3
    var sb = SchemaBuilder()
    sb.add_field(Field("bl", ArrowType.BOOL, True))
    sb.add_field(Field("t8", ArrowType.INT8, True))
    sb.add_field(Field("s16", ArrowType.INT16, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("l64", ArrowType.INT64, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field("st", ArrowType.STRING, True))
    sb.add_field(Field("dt", ArrowType.DATE32, True))
    var bl = BooleanArray.allocate(n)
    bl.set(0, True)
    bl.set(1, False)
    bl.set(2, True)
    var a8 = PrimitiveArray[DType.int8].allocate(n)
    var a16 = PrimitiveArray[DType.int16].allocate(n)
    var a32 = PrimitiveArray[DType.int32].allocate(n)
    var a64 = PrimitiveArray[DType.int64].allocate(n)
    var af32 = PrimitiveArray[DType.float32].allocate(n)
    var af64 = PrimitiveArray[DType.float64].allocate(n)
    var adt = PrimitiveArray[DType.int32].allocate(n)
    var ss = List[String]()
    for i in range(n):
        a8.set(i, Int8(i + 1))
        a16.set(i, Int16(i + 10))
        a32.set(i, Int32(i + 100))
        a64.set(i, Int64(i + 1000))
        af32.set(i, Float32(i) + 0.5)
        af64.set(i, Float64(i) + 0.25)
        adt.set(i, Int32(i))
        ss.append(String("v") + String(i))
    var b = RecordBatchBuilder.with_capacity(9)
    b.add_column(Column.from_boolean(bl^))
    b.add_column(Column.from_primitive_with_arrow_type[DType.int8](a8^, ArrowType.INT8))
    b.add_column(Column.from_primitive_with_arrow_type[DType.int16](a16^, ArrowType.INT16))
    b.add_column(Column.from_primitive_with_arrow_type[DType.int32](a32^, ArrowType.INT32))
    b.add_column(Column.from_primitive_with_arrow_type[DType.int64](a64^, ArrowType.INT64))
    b.add_column(Column.from_primitive[DType.float32](af32^))
    b.add_column(Column.from_primitive[DType.float64](af64^))
    b.add_column(Column.from_string(StringArray.from_strings(ss)))
    b.add_column(Column.from_primitive_with_arrow_type[DType.int32](adt^, ArrowType.DATE32))
    return b.build(sb.build())


def _assert_columns(
    schema: Schema, names: List[String], types: List[ArrowType], what: String
) raises:
    assert_equal(schema.num_columns(), len(names), what + ": column count")
    for i in range(len(names)):
        assert_equal(schema.field_name(i), names[i], what + ": name " + String(i))
        assert_true(
            schema.field_arrow_type(i) == types[i],
            what + ": type of " + names[i],
        )
        assert_true(schema.field_nullable(i), what + ": nullable " + names[i])


def _refusal_of_bind(path: String) raises -> String:
    try:
        _ = orc_tvf_schema(path)
    except e:
        return String(e)
    return String("")


def test_the_parser_maps_read_orc_to_its_kind_path_and_alias() raises:
    var bare = _parse("SELECT * FROM read_orc('dir/f.orc')")
    ref rel = bare.query.from_tables[0]
    assert_equal(Int(rel.tvf_kind), Int(TVF_ORC))
    assert_equal(rel.tvf_path.value(), "dir/f.orc")
    assert_equal(rel.rel_alias, "read_orc")
    assert_equal(rel.name, "")
    var with_as = _parse("SELECT * FROM read_orc('dir/f.orc') AS o")
    assert_equal(Int(with_as.query.from_tables[0].tvf_kind), Int(TVF_ORC))
    assert_equal(with_as.query.from_tables[0].rel_alias, "o")
    var without_as = _parse("SELECT o.a FROM read_orc('dir/f.orc') o")
    assert_equal(without_as.query.from_tables[0].rel_alias, "o")


def test_read_orc_with_an_option_is_refused_by_name() raises:
    assert_equal(
        _message("SELECT * FROM read_orc('f.orc', x = 1)"),
        "SQL not supported: read_orc('f.orc', ...) takes NO options — an ORC"
        " file carries its schema and its codec in its footer, so there is no"
        " dialect to steer and nothing an option could mean. It is REJECTED"
        " rather than ignored — an ignored option can change the result"
        " silently.",
    )
    assert_equal(
        _message("SELECT * FROM read_avro('f.avro', x = 1)"),
        "SQL not supported: read_avro('f.avro', ...) takes NO options — an"
        " Avro OCF carries its writer schema and its codec in the container"
        " header, so there is no dialect to steer and nothing an option could"
        " mean. It is REJECTED rather than ignored — an ignored option can"
        " change the result silently.",
    )


def test_a_written_file_binds_to_its_columns_under_every_codec() raises:
    var codecs: List[Int] = [
        ORC_COMPRESSION_NONE,
        ORC_COMPRESSION_ZLIB,
        ORC_COMPRESSION_SNAPPY,
        ORC_COMPRESSION_LZ4,
        ORC_COMPRESSION_ZSTD,
    ]
    var names: List[String] = ["zeta", "alpha", "mid"]
    var types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.STRING, ArrowType.FLOAT64
    ]
    for c in range(len(codecs)):
        var path = _path("three_" + String(c) + ".orc")
        write_orc_file(
            _three_column_batch(), path, OrcWriterOptions(codecs[c], 2, "UTC")
        )
        var label = String("codec ") + String(codecs[c])
        _assert_columns(orc_tvf_schema(path), names, types, label)
        var rel = FromRelation.tvf_of(path, TVF_ORC, TvfOptions())
        _assert_columns(tvf_relation_schema(rel), names, types, label + " rel")
        var plan = tvf_relation_scan(rel)
        assert_true(plan.is_scan(), label + ": a scan leaf")
        _assert_columns(plan.output_schema, names, types, label + " leaf")
        ref source = plan.scan_data_ref().source
        assert_equal(Int(source.tag), Int(SOURCE_VARIANT_ORC), label)
        assert_equal(source.schema().num_columns(), 3, label + " source")


def test_the_scan_leaf_carries_the_path_and_the_file_mtime() raises:
    var path = _path("leaf.orc")
    write_orc_file(
        _three_column_batch(),
        path,
        OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, "UTC"),
    )
    var schema = orc_tvf_schema(path)
    var plan = tvf_relation_scan(
        FromRelation.tvf_of(path, TVF_ORC, TvfOptions())
    )
    ref source = plan.scan_data_ref().source
    var mtime = UInt64(FileIdentity.stat_path(path).mtime_ns)
    var want = SourceVariant(
        OrcSource(String(path), schema.copy(), List[Int](), mtime_ns=mtime)
    )
    assert_equal(source.fingerprint(), want.fingerprint(), "path and mtime")
    var unpinned = SourceVariant(
        OrcSource(String(path), schema.copy(), List[Int]())
    )
    assert_true(
        source.fingerprint() != unpinned.fingerprint(),
        "a leaf with mtime 0 is a different source",
    )
    var other = SourceVariant(
        OrcSource(String(path) + "x", schema.copy(), List[Int](), mtime_ns=mtime)
    )
    assert_true(
        source.fingerprint() != other.fingerprint(),
        "another path is a different source",
    )


def test_the_nine_accepted_column_types_bind_in_file_order() raises:
    var path = _path("nine.orc")
    write_orc_file(
        _nine_type_batch(),
        path,
        OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, "UTC"),
    )
    var names: List[String] = [
        "bl", "t8", "s16", "i32", "l64", "f32", "f64", "st", "dt"
    ]
    var types: List[ArrowType] = [
        ArrowType.BOOL,
        ArrowType.INT8,
        ArrowType.INT16,
        ArrowType.INT32,
        ArrowType.INT64,
        ArrowType.FLOAT32,
        ArrowType.FLOAT64,
        ArrowType.STRING,
        ArrowType.DATE32,
    ]
    _assert_columns(orc_tvf_schema(path), names, types, "nine types")


def test_struct_and_list_columns_are_refused_naming_column_and_type() raises:
    # struct<id: bigint, info: struct<a: int>, tags: array<string>>
    var types = List[List[UInt8]]()
    var root_children: List[Int] = [1, 2, 4]
    var root_names: List[String] = ["id", "info", "tags"]
    types.append(encode_type_node(ORC_KIND_STRUCT, root_children, root_names, 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_LONG, List[Int](), _no_names(), 0, 0, 0))
    var info_children: List[Int] = [3]
    var info_names: List[String] = ["a"]
    types.append(encode_type_node(ORC_KIND_STRUCT, info_children, info_names, 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_INT, List[Int](), _no_names(), 0, 0, 0))
    var tags_children: List[Int] = [5]
    types.append(encode_type_node(ORC_KIND_LIST, tags_children, _no_names(), 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_STRING, List[Int](), _no_names(), 0, 0, 0))
    var nested = _footer_only_file(_path("nested.orc"), types^)
    assert_equal(
        _refusal_of_bind(nested),
        "SQL not supported: read_orc('" + nested + "'): column 'info' is struct;"
        " read_orc reads BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT, FLOAT,"
        " DOUBLE, VARCHAR and DATE columns",
    )
    # struct<id: bigint, tags: array<string>>: the list is the first refusal.
    var only_list = List[List[UInt8]]()
    var l_children: List[Int] = [1, 2]
    var l_names: List[String] = ["id", "tags"]
    only_list.append(encode_type_node(ORC_KIND_STRUCT, l_children, l_names, 0, 0, 0))
    only_list.append(encode_type_node(ORC_KIND_LONG, List[Int](), _no_names(), 0, 0, 0))
    var t2: List[Int] = [3]
    only_list.append(encode_type_node(ORC_KIND_LIST, t2, _no_names(), 0, 0, 0))
    only_list.append(encode_type_node(ORC_KIND_STRING, List[Int](), _no_names(), 0, 0, 0))
    var listed = _footer_only_file(_path("listed.orc"), only_list^)
    assert_equal(
        _refusal_of_bind(listed),
        "SQL not supported: read_orc('" + listed + "'): column 'tags' is list;"
        " read_orc reads BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT, FLOAT,"
        " DOUBLE, VARCHAR and DATE columns",
    )



def _leaf(kind: Int) -> List[UInt8]:
    return encode_type_node(kind, List[Int](), _no_names(), 0, 0, 0)


def test_acid_empty_and_duplicate_name_files_are_refused() raises:
    # A Hive ACID file: the five metadata columns, then row: struct<a: bigint>.
    var acid = List[List[UInt8]]()
    var acid_children: List[Int] = [1, 2, 3, 4, 5, 6]
    var acid_names: List[String] = [
        "operation",
        "originalTransaction",
        "bucket",
        "rowId",
        "currentTransaction",
        "row",
    ]
    acid.append(encode_type_node(ORC_KIND_STRUCT, acid_children, acid_names, 0, 0, 0))
    acid.append(_leaf(ORC_KIND_INT))
    acid.append(_leaf(ORC_KIND_LONG))
    acid.append(_leaf(ORC_KIND_INT))
    acid.append(_leaf(ORC_KIND_LONG))
    acid.append(_leaf(ORC_KIND_LONG))
    var row_children: List[Int] = [7]
    var row_names: List[String] = ["a"]
    acid.append(encode_type_node(ORC_KIND_STRUCT, row_children, row_names, 0, 0, 0))
    acid.append(_leaf(ORC_KIND_LONG))
    var acid_path = _footer_only_file(_path("acid.orc"), acid^)
    assert_equal(
        _refusal_of_bind(acid_path),
        "SQL not supported: read_orc('" + acid_path + "') is a Hive ACID file;"
        " read_orc reads plain ORC files",
    )
    # A root struct of no field.
    var empty = List[List[UInt8]]()
    empty.append(encode_type_node(ORC_KIND_STRUCT, List[Int](), _no_names(), 0, 0, 0))
    var empty_path = _footer_only_file(_path("no_column.orc"), empty^)
    assert_equal(
        _refusal_of_bind(empty_path),
        "SQL not supported: read_orc('" + empty_path + "') holds no column",
    )
    # struct<x: bigint, X: bigint>: SQL names both `x`.
    var twice = List[List[UInt8]]()
    var twice_children: List[Int] = [1, 2]
    var twice_names: List[String] = ["x", "X"]
    twice.append(encode_type_node(ORC_KIND_STRUCT, twice_children, twice_names, 0, 0, 0))
    twice.append(_leaf(ORC_KIND_LONG))
    twice.append(_leaf(ORC_KIND_LONG))
    var twice_path = _footer_only_file(_path("twice.orc"), twice^)
    assert_equal(
        _refusal_of_bind(twice_path),
        "SQL not supported: read_orc('" + twice_path + "'): column 'X' appears"
        " twice",
    )

def test_timestamp_decimal_and_binary_columns_are_refused() raises:
    var kinds: List[Int] = [ORC_KIND_TIMESTAMP, ORC_KIND_DECIMAL, ORC_KIND_BINARY]
    for i in range(len(kinds)):
        var path = _file_with_one_column(
            _path("unsupported_" + String(i) + ".orc"), kinds[i]
        )
        var got = _one_column_type(path)
        assert_equal(
            _refusal_of_bind(path),
            "SQL not supported: read_orc('" + path + "'): column 'c' is "
            + String(got) + "; read_orc reads BOOLEAN, TINYINT, SMALLINT,"
            " INTEGER, BIGINT, FLOAT, DOUBLE, VARCHAR and DATE columns",
        )


def _one_column_type(path: String) raises -> ArrowType:
    """The Arrow type of the one column of a `_file_with_one_column` file, as
    the ORC reader's own schema reads it."""
    var buf = read_chunked(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    var t = read_orc_bytes_schema(span).field_arrow_type(0)
    _ = buf^
    return t


def test_a_glob_path_is_refused_by_name() raises:
    var got = _refusal_of_bind("data/*.orc")
    assert_equal(
        got,
        "SQL not supported: read_orc('data/*.orc') names a glob; read_orc"
        " reads one file. Name the file.",
    )
    assert_true("glob" in _refusal_of_bind("data/f?.orc"), "question mark")
    assert_true("glob" in _refusal_of_bind("data/f[12].orc"), "bracket")


def test_unreadable_files_are_refused_with_the_footer_message() raises:
    var missing = _path("no_such_file.orc")
    var m = _refusal_of_bind(missing)
    assert_true(
        m.startswith(
            "SQL bind error: read_orc('" + missing
            + "') cannot read the file's footer: "
        ),
        m,
    )
    var empty = _path("empty.orc")
    _write_bytes(empty, List[UInt8]())
    var e = _refusal_of_bind(empty)
    assert_true(
        e.startswith(
            "SQL bind error: read_orc('" + empty
            + "') cannot read the file's footer: "
        ),
        e,
    )
    var text = _path("not_orc.orc")
    var junk = List[UInt8]()
    for i in range(64):
        junk.append(UInt8(65 + i % 26))
    _write_bytes(text, junk)
    var t = _refusal_of_bind(text)
    assert_true(
        t.startswith(
            "SQL bind error: read_orc('" + text
            + "') cannot read the file's footer: "
        ),
        t,
    )
    assert_true("MALFORMED_PROTOBUF" in t, t)


def test_plan_from_sql_over_read_orc_reads_no_row() raises:
    # A footer-only file holds no stripe: planning can only have read the footer.
    var types = List[List[UInt8]]()
    var children: List[Int] = [1, 2]
    var names: List[String] = ["a", "b"]
    types.append(encode_type_node(ORC_KIND_STRUCT, children, names, 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_LONG, List[Int](), _no_names(), 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_STRING, List[Int](), _no_names(), 0, 0, 0))
    var path = _footer_only_file(_path("planned.orc"), types^)
    var cat = SqlCatalog()
    var plan = plan_from_sql(
        "SELECT a, b FROM read_orc('" + path + "') WHERE a > 3",
        cat,
        NoParquetFooters(),
    )
    var out: List[String] = ["a", "b"]
    var out_types: List[ArrowType] = [ArrowType.INT64, ArrowType.STRING]
    assert_equal(plan.output_schema.num_columns(), 2)
    for i in range(2):
        assert_equal(plan.output_schema.field_name(i), out[i])
        assert_true(plan.output_schema.field_arrow_type(i) == out_types[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
