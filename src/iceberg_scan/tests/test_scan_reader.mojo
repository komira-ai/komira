# =============================================================================
# read_iceberg_scan: the rows of a planned scan
# =============================================================================
#
# Data files are written to the scratch directory with parquet_writer; a test
# builds the IcebergScanSpec the planner would (test_scan_reader_deletes holds
# the delete files). What each test proves:
#   * test_rows_of_several_files_concatenate_in_order: two files (the first in
#     two row groups) read as one batch in file order, every field nullable.
#   * test_every_bound_type_reads_and_widens: int widens to long, float to
#     double, date and boolean and string and decimal(9, 2) read as they are
#     (the decimal's precision and scale reach the schema), an int64 column is a
#     timestamp, nulls stay null.
#   * test_missing_columns_read_as_nulls_of_the_bound_type: a column the file
#     lacks is null, whatever its type; a decimal no file holds is (38, 0).
#   * test_the_table_types_set_decimal_precision_and_the_timestamptz_zone: with
#     the type names a spec carries, a timestamptz read from plain int64 is in
#     UTC, a decimal no file holds has the table's precision and scale, a naive
#     timestamp stays naive, and a file decimal of another scale is refused
#     naming the table's type.
#   * test_columns_bind_by_field_id_when_the_file_has_ids_else_by_name: a file
#     with ids binds a renamed and reordered column by id and reads a column
#     whose id it lacks as null even when a column of that name exists; a file
#     with no ids binds by name.
#   * test_a_column_that_cannot_be_read_at_its_bound_type_is_refused_by_message:
#     an int64 file column bound as string, a decimal of another scale, a
#     file that is not Parquet, too short, or has a footer length that does not
#     fit, a file whose footer says a column is nested, and a file that is not
#     there.
#   * test_empty_scans_keep_their_schema: no data file, a zero-row file, delete
#     files of no rows, and a file whose every row is deleted give no rows of
#     the spec's schema.
#   * test_a_planned_table_reads_end_to_end: a table written as manifests and
#     files, planned with a filter that skips a file and read, has the live rows.

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from avro.ocf_header import AVRO_CODEC_NULL
from byte_buffer.byte_view import ByteView
from parquet.metadata_parser import parse_full_metadata
from parquet_api.types import CompressionCodec
from parquet_writer import (
    serialize_file_metadata,
    write_record_batch_to_parquet_bytes,
)
from physical_plan.iceberg_scan_spec import (
    IcebergDataFileSpec,
    IcebergDeleteSpec,
    IcebergScanSpec,
)
from plan_expr.expr import BIN_GT, Expr
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir
from iceberg_scan.scan_planner import plan_iceberg_scan
from iceberg_scan.scan_reader import read_iceberg_scan
from iceberg_scan.table_fixture import (
    FixtureEntry,
    FixtureManifest,
    fixture_bool_column,
    fixture_date_column,
    fixture_decimal_column,
    fixture_f32_column,
    fixture_f64_column,
    fixture_i32_column,
    fixture_i64_column,
    fixture_long_bytes,
    fixture_manifest,
    fixture_manifest_list,
    fixture_metadata_json,
    fixture_micros_column,
    fixture_snapshot_json,
    fixture_string_column,
    fixture_text_bytes,
)
from iceberg_scan.table_ref import iceberg_scan_binding, resolve_iceberg_table


# ---- files ----------------------------------------------------------------


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/reader_" + name
    makedirs(d, exist_ok=True)
    return d^


def _put(path: String, data: List[UInt8]) raises:
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`; the list
    # it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _with_field_ids(file: List[UInt8], ids: List[Int]) raises -> List[UInt8]:
    """`file` with `ids` stamped on its leaf columns, in order: the data region
    as it was, followed by the footer re-serialized with the ids."""
    return _restamped(file, ids, -1)


def _with_nested_column(file: List[UInt8], column: Int) raises -> List[UInt8]:
    """`file` whose footer says the leaf column `column` (0-based) has a child,
    that is, a nested column."""
    return _restamped(file, List[Int](), column)


def _restamped(
    file: List[UInt8], ids: List[Int], nested: Int
) raises -> List[UInt8]:
    """`file` with its footer re-serialized: `ids` stamped on its leaf columns
    in order, and the leaf column `nested` (when not negative) given a child."""
    var n = len(file)
    var old = 0
    for k in range(4):
        old |= Int(file[n - 8 + k]) << (8 * k)
    var md = parse_full_metadata(_view(Span(file)[n - 8 - old : n - 8]))
    for i in range(len(ids)):
        md.schema[i + 1].field_id = Optional[Int](ids[i])
    if nested >= 0:
        md.schema[nested + 1].num_children = 1
    var out = List[UInt8]()
    for i in range(n - 8 - old):
        out.append(file[i])
    var footer = serialize_file_metadata(md)
    var flen = len(footer)
    for i in range(flen):
        out.append(footer[i])
    for k in range(4):
        out.append(UInt8((flen >> (8 * k)) & 0xFF))
    for c in [0x50, 0x41, 0x52, 0x31]:
        out.append(UInt8(c))
    return out^


def _write_parquet(
    path: String,
    var sb: SchemaBuilder,
    var b: RecordBatchBuilder,
    rows_per_group: Int = 1000,
    ids: List[Int] = List[Int](),
) raises:
    var batch = b.build(sb.build())
    var bytes = write_record_batch_to_parquet_bytes(
        batch, CompressionCodec.UNCOMPRESSED, rows_per_group
    )
    if len(ids) > 0:
        bytes = _with_field_ids(bytes, ids)
    _put(path, bytes)


def _write_basic(
    path: String,
    ids: List[Int],
    names: List[String],
    name_nulls: List[Int],
    xs: List[Float64],
    x_nulls: List[Int],
    rows_per_group: Int = 1000,
) raises:
    """A file of id INT64, name STRING and x FLOAT64."""
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    b.add_column(fixture_i64_column(ids, List[Int]()))
    sb.add_field(Field("name", ArrowType.STRING, True))
    b.add_column(fixture_string_column(names, name_nulls))
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    b.add_column(fixture_f64_column(xs, x_nulls))
    _write_parquet(path, sb^, b^, rows_per_group)


# ---- specs ------------------------------------------------------------------


def _add_column(mut spec: IcebergScanSpec, name: String, t: ArrowType, id: Int):
    spec.column_names.append(name)
    spec.column_types.append(t)
    spec.column_field_ids.append(id)


def _basic_spec() -> IcebergScanSpec:
    var spec = IcebergScanSpec()
    _add_column(spec, "id", ArrowType.INT64, 1)
    _add_column(spec, "name", ArrowType.STRING, 2)
    _add_column(spec, "x", ArrowType.FLOAT64, 3)
    return spec^


def _add_data(
    mut spec: IcebergScanSpec,
    path: String,
    stored: String = "",
    position_deletes: List[Int] = List[Int](),
    equality_deletes: List[Int] = List[Int](),
):
    var recorded = path
    if stored.byte_length() > 0:
        recorded = stored
    spec.data_files.append(
        IcebergDataFileSpec(path, recorded, position_deletes.copy(), equality_deletes.copy())
    )


def _add_delete(
    mut spec: IcebergScanSpec,
    path: String,
    content: Int,
    file_format: String,
    columns: List[String] = List[String](),
):
    spec.deletes.append(IcebergDeleteSpec(path, content, file_format, columns.copy()))


def _ids_of(b: RecordBatch) raises -> List[Int]:
    var out = List[Int]()
    var col = b.column_at(0).as_primitive[DType.int64]()
    for r in range(b.num_rows()):
        out.append(Int(col.get(r)))
    return out^


def _error_of(spec: IcebergScanSpec) -> String:
    try:
        _ = read_iceberg_scan(spec)
    except e:
        return String(e)
    return String("(read)")


# ---- tests ------------------------------------------------------------------


def test_rows_of_several_files_concatenate_in_order() raises:
    var d = _dir("order")
    _write_basic(d + "/f1.parquet", [1, 2, 3], ["a", "b", "c"], [2], [0.5, 1.0, 1.5], [1], 2)
    _write_basic(d + "/f2.parquet", [4, 5], ["d", "e"], List[Int](), [2.5, 3.5], List[Int]())
    var spec = _basic_spec()
    _add_data(spec, d + "/f1.parquet")
    _add_data(spec, d + "/f2.parquet")
    var out = read_iceberg_scan(spec)
    assert_equal(out.num_rows(), 5)
    assert_equal(out.num_columns(), 3)
    assert_equal(out.schema.field_name(0), "id")
    assert_equal(out.schema.field_name(1), "name")
    assert_equal(out.schema.field_name(2), "x")
    assert_true(out.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(out.schema.field_arrow_type(1) == ArrowType.STRING)
    assert_true(out.schema.field_arrow_type(2) == ArrowType.FLOAT64)
    for c in range(3):
        assert_true(out.schema.field_nullable(c))
    var ids = _ids_of(out)
    for r in range(5):
        assert_equal(ids[r], r + 1)
    var names = out.column_at(1).as_string()
    assert_equal(names.get(0), "a")
    assert_true(out.column_at(1).is_null_at(2))
    assert_equal(names.get(3), "d")
    assert_equal(names.get(4), "e")
    var xs = out.column_at(2).as_primitive[DType.float64]()
    assert_equal(xs.get(0), 0.5)
    assert_true(out.column_at(2).is_null_at(1))
    assert_equal(xs.get(2), 1.5)
    assert_equal(xs.get(4), 3.5)


def test_every_bound_type_reads_and_widens() raises:
    var d = _dir("types")
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("i", ArrowType.INT32, True))
    b.add_column(fixture_i32_column([7, 0, -3], [1]))
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    b.add_column(fixture_f32_column([0.5, 1.25, 0.0], [2]))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    b.add_column(fixture_date_column([20700, 20700, 20701], [1]))
    sb.add_field(Field("t", ArrowType.TIMESTAMP_US, True))
    b.add_column(fixture_micros_column([1788300000000000, 1788300000000001, 1788300000000002], [2]))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    b.add_column(fixture_bool_column([True, False, True], [2]))
    sb.add_field(Field("s", ArrowType.STRING, True))
    b.add_column(fixture_string_column(["x", "y", "z"], [0]))
    sb.add_field(Field.decimal128("p", 9, 2, True))
    b.add_column(fixture_decimal_column([12345, 0, -5], [1], 9, 2))
    _write_parquet(d + "/t.parquet", sb^, b^)
    var spec = IcebergScanSpec()
    _add_column(spec, "i", ArrowType.INT64, 1)
    _add_column(spec, "f", ArrowType.FLOAT64, 2)
    _add_column(spec, "d", ArrowType.DATE32, 3)
    _add_column(spec, "t", ArrowType.TIMESTAMP_US, 4)
    _add_column(spec, "b", ArrowType.BOOL, 5)
    _add_column(spec, "s", ArrowType.STRING, 6)
    _add_column(spec, "p", ArrowType.DECIMAL128, 7)
    _add_data(spec, d + "/t.parquet")
    var out = read_iceberg_scan(spec)
    assert_equal(out.num_rows(), 3)
    assert_true(out.column_at(0).arrow_type == ArrowType.INT64)
    var ints = out.column_at(0).as_primitive[DType.int64]()
    assert_equal(ints.get(0), 7)
    assert_true(out.column_at(0).is_null_at(1))
    assert_equal(ints.get(2), -3)
    assert_true(out.column_at(1).arrow_type == ArrowType.FLOAT64)
    var floats = out.column_at(1).as_primitive[DType.float64]()
    assert_equal(floats.get(0), 0.5)
    assert_equal(floats.get(1), 1.25)
    assert_true(out.column_at(1).is_null_at(2))
    assert_true(out.column_at(2).arrow_type == ArrowType.DATE32)
    var dates = out.column_at(2).as_primitive[DType.int32]()
    assert_equal(dates.get(0), 20700)
    assert_true(out.column_at(2).is_null_at(1))
    assert_true(out.schema.field_arrow_type(3) == ArrowType.TIMESTAMP_US)
    assert_equal(out.schema.field_tz(3), "")
    var micros = out.column_at(3).as_primitive[DType.int64]()
    assert_equal(micros.get(1), 1788300000000001)
    assert_true(out.column_at(3).is_null_at(2))
    var flags = out.column_at(4).as_boolean()
    assert_true(flags.get(0))
    assert_false(flags.get(1))
    assert_true(out.column_at(4).is_null_at(2))
    assert_true(out.column_at(5).is_null_at(0))
    assert_equal(out.column_at(5).as_string().get(2), "z")
    assert_true(out.schema.field_arrow_type(6) == ArrowType.DECIMAL128)
    assert_equal(out.schema.field_decimal_precision(6), 9)
    assert_equal(out.schema.field_decimal_scale(6), 2)
    var price = out.column_at(6).as_decimal128()
    assert_equal(price.get_low(0), 12345)
    assert_true(out.column_at(6).is_null_at(1))
    assert_equal(price.get_low(2), -5)


def test_missing_columns_read_as_nulls_of_the_bound_type() raises:
    var d = _dir("missing")
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    b.add_column(fixture_i64_column([1, 2], List[Int]()))
    _write_parquet(d + "/only_id.parquet", sb^, b^)
    var spec = IcebergScanSpec()
    _add_column(spec, "id", ArrowType.INT64, 1)
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    types.append(ArrowType.BOOL)
    types.append(ArrowType.FLOAT64)
    types.append(ArrowType.FLOAT32)
    types.append(ArrowType.INT32)
    types.append(ArrowType.DATE32)
    types.append(ArrowType.TIMESTAMP_US)
    types.append(ArrowType.DECIMAL128)
    for k in range(len(types)):
        _add_column(spec, "added_" + String(k), types[k], 10 + k)
    _add_data(spec, d + "/only_id.parquet")
    var out = read_iceberg_scan(spec)
    assert_equal(out.num_rows(), 2)
    assert_equal(out.num_columns(), 10)
    assert_equal(_ids_of(out)[1], 2)
    for k in range(len(types)):
        ref col = out.column_at(k + 1)
        assert_true(col.arrow_type == types[k])
        assert_equal(col.length(), 2)
        assert_equal(col.null_count(), 2)
        assert_true(col.is_null_at(0))
        assert_true(col.is_null_at(1))
    assert_equal(out.schema.field_decimal_precision(9), 38)
    assert_equal(out.schema.field_decimal_scale(9), 0)
    assert_equal(out.schema.field_tz(8), "")


def test_columns_bind_by_field_id_when_the_file_has_ids_else_by_name() raises:
    var d = _dir("binding")
    # The file's columns are x (id 2) and y (id 1): renamed and reordered since.
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    b.add_column(fixture_i64_column([10, 20], List[Int]()))
    sb.add_field(Field("y", ArrowType.STRING, True))
    b.add_column(fixture_string_column(["p", "q"], List[Int]()))
    var ids = List[Int]()
    ids.append(2)
    ids.append(1)
    _write_parquet(d + "/with_ids.parquet", sb^, b^, 1000, ids)

    var spec = IcebergScanSpec()
    _add_column(spec, "first", ArrowType.STRING, 1)
    _add_column(spec, "second", ArrowType.INT64, 2)
    _add_column(spec, "x", ArrowType.INT64, 9)  # a name the file has, an id it lacks
    _add_data(spec, d + "/with_ids.parquet")
    var out = read_iceberg_scan(spec)
    assert_equal(out.num_rows(), 2)
    assert_equal(out.column_at(0).as_string().get(1), "q")
    assert_equal(out.column_at(1).as_primitive[DType.int64]().get(0), 10)
    assert_true(out.column_at(2).is_null_at(0))
    assert_true(out.column_at(2).is_null_at(1))

    # A file with no ids binds by name, whatever the ids say.
    var sb2 = SchemaBuilder()
    var b2 = RecordBatchBuilder()
    sb2.add_field(Field("x", ArrowType.INT64, True))
    b2.add_column(fixture_i64_column([1], List[Int]()))
    sb2.add_field(Field("y", ArrowType.STRING, True))
    b2.add_column(fixture_string_column(["z"], List[Int]()))
    _write_parquet(d + "/without_ids.parquet", sb2^, b2^)
    var by_name = IcebergScanSpec()
    _add_column(by_name, "y", ArrowType.STRING, 77)
    _add_column(by_name, "other", ArrowType.INT64, 1)
    _add_data(by_name, d + "/without_ids.parquet")
    var named = read_iceberg_scan(by_name)
    assert_equal(named.column_at(0).as_string().get(0), "z")
    assert_true(named.column_at(1).is_null_at(0))


def test_a_column_that_cannot_be_read_at_its_bound_type_is_refused_by_message() raises:
    var d = _dir("mismatch")
    _write_basic(d + "/f.parquet", [1], ["a"], List[Int](), [1.0], List[Int]())
    var wrong = IcebergScanSpec()
    _add_column(wrong, "name", ArrowType.INT64, 2)
    _add_data(wrong, d + "/f.parquet")
    assert_equal(
        _error_of(wrong),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/f.parquet: the column 'name' is string in the file but is bound as int64",
    )

    # A decimal must keep the scale (and precision) of the first file.
    var first = SchemaBuilder()
    var fb = RecordBatchBuilder()
    first.add_field(Field.decimal128("p", 9, 2, True))
    fb.add_column(fixture_decimal_column([1], List[Int](), 9, 2))
    _write_parquet(d + "/p92.parquet", first^, fb^)
    var second = SchemaBuilder()
    var sb2 = RecordBatchBuilder()
    second.add_field(Field.decimal128("p", 9, 3, True))
    sb2.add_column(fixture_decimal_column([1], List[Int](), 9, 3))
    _write_parquet(d + "/p93.parquet", second^, sb2^)
    var decimals = IcebergScanSpec()
    _add_column(decimals, "p", ArrowType.DECIMAL128, 1)
    _add_data(decimals, d + "/p92.parquet")
    _add_data(decimals, d + "/p93.parquet")
    assert_equal(
        _error_of(decimals),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/p93.parquet: the column 'p' is decimal(9,3) in the file but"
        " decimal(9,2) in the first file that holds it",
    )

    # Files that are not Parquet.
    var junk = List[UInt8]()
    for k in range(20):
        junk.append(UInt8(65 + k))
    _put(d + "/junk.parquet", junk)
    var short = List[UInt8]()
    for k in range(6):
        short.append(UInt8(65 + k))
    _put(d + "/short.parquet", short)
    var cut = List[UInt8]()
    for c in [0x50, 0x41, 0x52, 0x31, 0, 0, 0, 0, 0xE8, 0x03, 0, 0, 0x50, 0x41, 0x52, 0x31]:
        cut.append(UInt8(c))
    _put(d + "/cut.parquet", cut)
    var unreadable = IcebergScanSpec()
    _add_column(unreadable, "id", ArrowType.INT64, 1)
    _add_data(unreadable, d + "/junk.parquet")
    assert_equal(
        _error_of(unreadable),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/junk.parquet: cannot read the file: the file has no PAR1 magic",
    )
    var tiny = IcebergScanSpec()
    _add_column(tiny, "id", ArrowType.INT64, 1)
    _add_data(tiny, d + "/short.parquet")
    assert_equal(
        _error_of(tiny),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/short.parquet: cannot read the file: the file is too short to be a Parquet file",
    )
    var truncated = IcebergScanSpec()
    _add_column(truncated, "id", ArrowType.INT64, 1)
    _add_data(truncated, d + "/cut.parquet")
    assert_equal(
        _error_of(truncated),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/cut.parquet: cannot read the file: the footer length does not fit the file",
    )
    # A file whose footer says a column is nested.
    var nsb = SchemaBuilder()
    var nb = RecordBatchBuilder()
    nsb.add_field(Field("id", ArrowType.INT64, True))
    nb.add_column(fixture_i64_column([1], List[Int]()))
    var flat = write_record_batch_to_parquet_bytes(
        nb.build(nsb.build()), CompressionCodec.UNCOMPRESSED, 1000
    )
    _put(d + "/nested.parquet", _with_nested_column(flat, 0))
    var nested = IcebergScanSpec()
    _add_column(nested, "id", ArrowType.INT64, 1)
    _add_data(nested, d + "/nested.parquet")
    assert_equal(
        _error_of(nested),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/nested.parquet: cannot read the file: the column 'id' is nested;"
        " only flat files are read",
    )
    var absent = IcebergScanSpec()
    _add_column(absent, "id", ArrowType.INT64, 1)
    _add_data(absent, d + "/not_there.parquet")
    assert_true(
        _error_of(absent).startswith(
            "ICEBERG_DATA_FILE_MISMATCH: " + d + "/not_there.parquet: cannot read the file: "
        )
    )


def _write_position_deletes(
    path: String,
    stored: String,
    positions: List[Int],
    other_rows: Bool,
    ids: List[Int] = List[Int](),
    path_name: String = "file_path",
    pos_name: String = "pos",
) raises:
    var paths = List[String]()
    var pos = List[Int]()
    for i in range(len(positions)):
        paths.append(stored)
        pos.append(positions[i])
    if other_rows:
        paths.append("file:///elsewhere/other.parquet")
        pos.append(0)
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field(path_name, ArrowType.STRING, True))
    b.add_column(fixture_string_column(paths, List[Int]()))
    sb.add_field(Field(pos_name, ArrowType.INT64, True))
    b.add_column(fixture_i64_column(pos, List[Int]()))
    _write_parquet(path, sb^, b^, 1000, ids)


def test_empty_scans_keep_their_schema() raises:
    var d = _dir("empty")
    var none = read_iceberg_scan(_basic_spec())
    assert_equal(none.num_rows(), 0)
    assert_equal(none.num_columns(), 3)
    assert_equal(none.schema.field_name(2), "x")
    assert_true(none.schema.field_arrow_type(1) == ArrowType.STRING)

    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    b.add_column(fixture_i64_column(List[Int](), List[Int]()))
    sb.add_field(Field("name", ArrowType.STRING, True))
    b.add_column(fixture_string_column(List[String](), List[Int]()))
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    b.add_column(fixture_f64_column(List[Float64](), List[Int]()))
    _write_parquet(d + "/zero.parquet", sb^, b^)
    _write_basic(d + "/two.parquet", [1, 2], ["a", "b"], List[Int](), [1.0, 2.0], List[Int]())
    var spec = _basic_spec()
    _add_data(spec, d + "/zero.parquet")
    _add_data(spec, d + "/two.parquet")
    var zero_and_two = read_iceberg_scan(spec)
    assert_equal(zero_and_two.num_rows(), 2)
    var only_zero = _basic_spec()
    _add_data(only_zero, d + "/zero.parquet")
    assert_equal(read_iceberg_scan(only_zero).num_rows(), 0)

    # Delete files of no rows delete nothing.
    var no_rows = SchemaBuilder()
    var no_rows_b = RecordBatchBuilder()
    no_rows.add_field(Field("file_path", ArrowType.STRING, True))
    no_rows_b.add_column(fixture_string_column(List[String](), List[Int]()))
    no_rows.add_field(Field("pos", ArrowType.INT64, True))
    no_rows_b.add_column(fixture_i64_column(List[Int](), List[Int]()))
    _write_parquet(d + "/pd_empty.parquet", no_rows^, no_rows_b^)
    var no_keys = SchemaBuilder()
    var no_keys_b = RecordBatchBuilder()
    no_keys.add_field(Field("id", ArrowType.INT64, True))
    no_keys_b.add_column(fixture_i64_column(List[Int](), List[Int]()))
    _write_parquet(d + "/eq_empty.parquet", no_keys^, no_keys_b^)
    var inert = _basic_spec()
    var id_only = List[String]()
    id_only.append("id")
    _add_delete(inert, d + "/pd_empty.parquet", 1, "PARQUET")
    _add_delete(inert, d + "/eq_empty.parquet", 2, "PARQUET", id_only)
    var first_two = List[Int]()
    first_two.append(0)
    var eq_one = List[Int]()
    eq_one.append(1)
    _add_data(inert, d + "/two.parquet", "", first_two, eq_one)
    assert_equal(read_iceberg_scan(inert).num_rows(), 2)

    # Every row of the only file deleted.
    var all_rows = List[Int]()
    all_rows.append(0)
    all_rows.append(1)
    _write_position_deletes(d + "/pd.parquet", d + "/two.parquet", all_rows, False)
    var gone = _basic_spec()
    _add_delete(gone, d + "/pd.parquet", 1, "PARQUET")
    var one = List[Int]()
    one.append(0)
    _add_data(gone, d + "/two.parquet", "", one)
    var nothing = read_iceberg_scan(gone)
    assert_equal(nothing.num_rows(), 0)
    assert_equal(nothing.num_columns(), 3)
    # ... and beside a file that keeps its rows.
    var mixed = _basic_spec()
    _add_delete(mixed, d + "/pd.parquet", 1, "PARQUET")
    _add_data(mixed, d + "/two.parquet", "", one)
    _add_data(mixed, d + "/two.parquet")
    assert_equal(read_iceberg_scan(mixed).num_rows(), 2)


def test_a_planned_table_reads_end_to_end() raises:
    var root = _dir("end_to_end")
    makedirs(root + "/metadata", exist_ok=True)
    makedirs(root + "/data", exist_ok=True)
    _write_basic(root + "/data/f1.parquet", [1, 2, 3], ["a", "b", "c"], List[Int](), [1.0, 2.0, 3.0], List[Int]())
    _write_basic(root + "/data/f2.parquet", [8, 9, 10], ["h", "i", "j"], List[Int](), [8.0, 9.0, 10.0], List[Int]())
    var uri = "file://" + root
    var f1 = FixtureEntry(uri + "/data/f1.parquet")
    f1.sequence_number = Optional[Int64](1)
    f1.lower.add(1, fixture_long_bytes(1))
    f1.upper.add(1, fixture_long_bytes(3))
    var f2 = FixtureEntry(uri + "/data/f2.parquet")
    f2.sequence_number = Optional[Int64](1)
    f2.lower.add(1, fixture_long_bytes(8))
    f2.upper.add(1, fixture_long_bytes(10))
    var data = List[FixtureEntry]()
    data.append(f1^)
    data.append(f2^)
    var no_names = List[String]()
    var no_types = List[String]()
    _put(
        root + "/metadata/data.avro",
        fixture_manifest(data, no_names, no_types, AVRO_CODEC_NULL),
    )
    _write_position_deletes(root + "/data/pd.parquet", uri + "/data/f2.parquet", [0], False)
    var pd = FixtureEntry(uri + "/data/pd.parquet")
    pd.content = 1
    var deletes = List[FixtureEntry]()
    deletes.append(pd^)
    _put(
        root + "/metadata/deletes.avro",
        fixture_manifest(deletes, no_names, no_types, AVRO_CODEC_NULL),
    )
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(uri + "/metadata/data.avro"))
    var delete_manifest = FixtureManifest(uri + "/metadata/deletes.avro")
    delete_manifest.content = 1
    delete_manifest.sequence_number = 2
    manifests.append(delete_manifest^)
    _put(root + "/metadata/snap-1.avro", fixture_manifest_list(manifests, AVRO_CODEC_NULL))
    var snaps = List[String]()
    snaps.append(fixture_snapshot_json(1, 2, uri + "/metadata/snap-1.avro", 0))
    var fields = String(
        '{"id": 1, "name": "id", "required": true, "type": "long"}, '
        '{"id": 2, "name": "name", "required": false, "type": "string"}, '
        '{"id": 3, "name": "x", "required": false, "type": "double"}'
    )
    var text = fixture_metadata_json(uri, fields, "", snaps, 1)
    _put(root + "/metadata/v1.metadata.json", fixture_text_bytes(text))
    _put(root + "/metadata/version-hint.text", fixture_text_bytes("1"))

    var binding = iceberg_scan_binding(resolve_iceberg_table(root, False, None))
    var all_files = plan_iceberg_scan(binding, None)
    var every = read_iceberg_scan(all_files.spec)
    # f1 whole, f2 without its position 0.
    var ids = _ids_of(every)
    assert_equal(len(ids), 5)
    assert_equal(ids[0], 1)
    assert_equal(ids[3], 9)
    assert_equal(ids[4], 10)
    var filter = Optional[Expr](
        Expr.binary(BIN_GT, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int64(5)))
    )
    var pruned = plan_iceberg_scan(binding, filter)
    assert_equal(pruned.counts.data_files_skipped, 1)
    var late = _ids_of(read_iceberg_scan(pruned.spec))
    assert_equal(len(late), 2)
    assert_equal(late[0], 9)


def test_the_table_types_set_decimal_precision_and_the_timestamptz_zone() raises:
    var d = _dir("typed")
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("at", ArrowType.INT64, True))
    b.add_column(fixture_i64_column([1, 2], List[Int]()))
    b.add_column(fixture_i64_column([1800000000000000, 1800000000000001], List[Int]()))
    _write_parquet(d + "/plain.parquet", sb^, b^)

    # The file stores `at` as plain int64 and holds no `amount`: the table's
    # types still give `at` its UTC zone and `amount` its (12, 3).
    var spec = IcebergScanSpec()
    _add_column(spec, "id", ArrowType.INT64, 1)
    _add_column(spec, "at", ArrowType.TIMESTAMP_US, 2)
    _add_column(spec, "amount", ArrowType.DECIMAL128, 3)
    spec.column_type_names.append("long")
    spec.column_type_names.append("timestamptz")
    spec.column_type_names.append("decimal(12,3)")
    _add_data(spec, d + "/plain.parquet")
    var out = read_iceberg_scan(spec)
    assert_equal(out.num_rows(), 2)
    assert_equal(out.schema.field_tz(1), "UTC")
    assert_equal(out.schema.field_decimal_precision(2), 12)
    assert_equal(out.schema.field_decimal_scale(2), 3)
    assert_equal(out.column_at(2).null_count(), 2)

    # A naive timestamp stays naive.
    var naive = IcebergScanSpec()
    _add_column(naive, "at", ArrowType.TIMESTAMP_US, 2)
    naive.column_type_names.append("timestamp")
    _add_data(naive, d + "/plain.parquet")
    assert_equal(read_iceberg_scan(naive).schema.field_tz(0), "")

    # A file decimal whose scale is not the table's is refused, naming the
    # table's type.
    var dsb = SchemaBuilder()
    var db = RecordBatchBuilder()
    dsb.add_field(Field.decimal128("p", 9, 2, True))
    db.add_column(fixture_decimal_column([1], List[Int](), 9, 2))
    _write_parquet(d + "/p92.parquet", dsb^, db^)
    var wrong = IcebergScanSpec()
    _add_column(wrong, "p", ArrowType.DECIMAL128, 1)
    wrong.column_type_names.append("decimal(9,3)")
    _add_data(wrong, d + "/p92.parquet")
    assert_equal(
        _error_of(wrong),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/p92.parquet: the column 'p' is decimal(9,2) in the file but"
        " decimal(9,3) in the table",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_rows_of_several_files_concatenate_in_order]()
    suite.test[test_every_bound_type_reads_and_widens]()
    suite.test[test_missing_columns_read_as_nulls_of_the_bound_type]()
    suite.test[test_columns_bind_by_field_id_when_the_file_has_ids_else_by_name]()
    suite.test[test_a_column_that_cannot_be_read_at_its_bound_type_is_refused_by_message]()
    suite.test[test_empty_scans_keep_their_schema]()
    suite.test[test_a_planned_table_reads_end_to_end]()
    suite.test[test_the_table_types_set_decimal_precision_and_the_timestamptz_zone]()
    suite^.run()
