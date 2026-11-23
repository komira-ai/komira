# =============================================================================
# read_iceberg_scan: position and equality deletes
# =============================================================================
#
# Data and delete files are written to the scratch directory with parquet_writer
# (and avro for Avro delete files); a test builds the IcebergScanSpec the
# planner would. What each test proves:
#   * test_position_deletes_remove_rows_by_stored_path_and_position: Parquet and
#     Avro position deletes, rows of other files and positions past the end
#     ignored, columns found by name or by the reserved field ids; each malformed
#     position delete file is refused by message.
#   * test_equality_deletes_match_null_to_null_and_nan_to_nan: Parquet equality
#     deletes on a nullable string and a float with NaN and -0.0, an Avro one
#     over int, nullable string and double, two delete files at once, and one
#     key over every supported type; refusals of an Avro delete over a decimal,
#     an unscanned column, a missing column and an Avro bytes value.

from std.math import nan
from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from avro.ocf_block_emit import emit_ocf_block, emit_ocf_header_kv
from avro.ocf_header import AVRO_CODEC_NULL, OCF_SYNC_LEN
from avro.varint_encode import (
    encode_bytes,
    encode_double,
    encode_int,
    encode_long,
    encode_string,
)
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
from runtime_paths import test_tmpdir
from iceberg_scan.scan_reader import read_iceberg_scan
from iceberg_scan.table_fixture import (
    fixture_bool_column,
    fixture_date_column,
    fixture_decimal_column,
    fixture_f32_column,
    fixture_f64_column,
    fixture_i32_column,
    fixture_i64_column,
    fixture_micros_column,
    fixture_string_column,
)


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
    var n = len(file)
    var old = 0
    for k in range(4):
        old |= Int(file[n - 8 + k]) << (8 * k)
    var md = parse_full_metadata(_view(Span(file)[n - 8 - old : n - 8]))
    for i in range(len(ids)):
        md.schema[i + 1].field_id = Optional[Int](ids[i])
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


def _avro_file(path: String, schema: String, payload: List[UInt8], count: Int) raises:
    var keys = List[String]()
    var values = List[String]()
    var out = List[UInt8]()
    var sync = Array[UInt8, OCF_SYNC_LEN](fill=9)
    emit_ocf_header_kv(schema, AVRO_CODEC_NULL, sync, keys, values, out)
    emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)
    _put(path, out)


comptime _POSITION_SCHEMA = String(
    '{"type":"record","name":"d","fields":['
    '{"name":"file_path","type":"string"},{"name":"pos","type":"long"}]}'
)


def test_position_deletes_remove_rows_by_stored_path_and_position() raises:
    var d = _dir("position")
    var stored = String("file:///warehouse/orders/data/pos_data.parquet")
    _write_basic(
        d + "/pos_data.parquet", [1, 2, 3, 4, 5], ["a", "b", "c", "d", "e"], List[Int](),
        [1.0, 2.0, 3.0, 4.0, 5.0], List[Int](),
    )
    # Parquet: positions 1 and 3 of this file; 99 and -5 are not rows; one
    # row names another file.
    var positions = List[Int]()
    positions.append(1)
    positions.append(3)
    positions.append(99)
    positions.append(-5)
    _write_position_deletes(d + "/pd1.parquet", stored, positions, True)
    # Avro: position 0.
    var payload = List[UInt8]()
    encode_string(stored, payload)
    encode_long(0, payload)
    _avro_file(d + "/pd2.avro", _POSITION_SCHEMA, payload, 1)
    var spec = _basic_spec()
    _add_delete(spec, d + "/pd1.parquet", 1, "PARQUET")
    _add_delete(spec, d + "/pd2.avro", 1, "AVRO")
    var both = List[Int]()
    both.append(0)
    both.append(1)
    _add_data(spec, d + "/pos_data.parquet", stored, both)
    var out = read_iceberg_scan(spec)
    assert_equal(out.num_rows(), 2)
    var ids = _ids_of(out)
    assert_equal(ids[0], 3)
    assert_equal(ids[1], 5)
    assert_equal(out.column_at(1).as_string().get(0), "c")

    # Columns found by the reserved field ids, not by name.
    var reserved = List[Int]()
    reserved.append(2147483546)
    reserved.append(2147483545)
    var last = List[Int]()
    last.append(4)
    _write_position_deletes(d + "/pd3.parquet", stored, last, False, reserved, "fp", "ps")
    var by_ids = _basic_spec()
    _add_delete(by_ids, d + "/pd3.parquet", 1, "PARQUET")
    var one = List[Int]()
    one.append(0)
    _add_data(by_ids, d + "/pos_data.parquet", stored, one)
    var kept = _ids_of(read_iceberg_scan(by_ids))
    assert_equal(len(kept), 4)
    assert_equal(kept[3], 4)

    # A delete named by a data file that has its own path as stored path.
    var by_path = _basic_spec()
    _write_position_deletes(d + "/pd4.parquet", d + "/pos_data.parquet", last, False)
    _add_delete(by_path, d + "/pd4.parquet", 1, "PARQUET")
    _add_data(by_path, d + "/pos_data.parquet", "", one)
    assert_equal(len(_ids_of(read_iceberg_scan(by_path))), 4)

    # Malformed position delete files.
    var no_columns = _basic_spec()
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.STRING, True))
    b.add_column(fixture_string_column(["x"], List[Int]()))
    sb.add_field(Field("b", ArrowType.INT64, True))
    b.add_column(fixture_i64_column([1], List[Int]()))
    _write_parquet(d + "/pd_no_columns.parquet", sb^, b^)
    _add_delete(no_columns, d + "/pd_no_columns.parquet", 1, "PARQUET")
    _add_data(no_columns, d + "/pos_data.parquet", stored, one)
    assert_equal(
        _error_of(no_columns),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/pd_no_columns.parquet: the position delete file has no file_path or pos column",
    )
    var wrong_types = _basic_spec()
    var sb2 = SchemaBuilder()
    var b2 = RecordBatchBuilder()
    sb2.add_field(Field("file_path", ArrowType.INT64, True))
    b2.add_column(fixture_i64_column([1], List[Int]()))
    sb2.add_field(Field("pos", ArrowType.INT64, True))
    b2.add_column(fixture_i64_column([1], List[Int]()))
    _write_parquet(d + "/pd_wrong_types.parquet", sb2^, b2^)
    _add_delete(wrong_types, d + "/pd_wrong_types.parquet", 1, "PARQUET")
    _add_data(wrong_types, d + "/pos_data.parquet", stored, one)
    assert_equal(
        _error_of(wrong_types),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/pd_wrong_types.parquet: file_path is not a string column or pos is not a long column",
    )
    var null_pos = _basic_spec()
    var sb3 = SchemaBuilder()
    var b3 = RecordBatchBuilder()
    sb3.add_field(Field("file_path", ArrowType.STRING, True))
    b3.add_column(fixture_string_column([stored], List[Int]()))
    sb3.add_field(Field("pos", ArrowType.INT64, True))
    b3.add_column(fixture_i64_column([1], [0]))
    _write_parquet(d + "/pd_null_pos.parquet", sb3^, b3^)
    _add_delete(null_pos, d + "/pd_null_pos.parquet", 1, "PARQUET")
    _add_data(null_pos, d + "/pos_data.parquet", stored, one)
    assert_equal(
        _error_of(null_pos),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/pd_null_pos.parquet: a position delete row has a null file_path or pos",
    )
    var short_avro = _basic_spec()
    var only_path = List[UInt8]()
    encode_string(stored, only_path)
    _avro_file(
        d + "/pd_lacks_pos.avro",
        '{"type":"record","name":"d","fields":[{"name":"file_path","type":"string"}]}',
        only_path,
        1,
    )
    _add_delete(short_avro, d + "/pd_lacks_pos.avro", 1, "AVRO")
    _add_data(short_avro, d + "/pos_data.parquet", stored, one)
    assert_equal(
        _error_of(short_avro),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/pd_lacks_pos.avro: a position delete row lacks file_path or pos",
    )


def _write_name_deletes(path: String, names: List[String], nulls: List[Int]) raises:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("name", ArrowType.STRING, True))
    b.add_column(fixture_string_column(names, nulls))
    _write_parquet(path, sb^, b^)


def test_equality_deletes_match_null_to_null_and_nan_to_nan() raises:
    var d = _dir("equality")
    var xs: List[Float64] = [nan[DType.float64](), 0.0, 1.5, 2.5, 3.5]
    _write_basic(
        d + "/eq_data.parquet", [1, 2, 3, 4, 5], ["a", "", "c", "", "e"], [1, 3], xs, List[Int](),
    )
    var one = List[Int]()
    one.append(0)
    var cols = List[String]()
    cols.append("name")

    # name IN (NULL, 'c'): rows 2, 3 and 4 go.
    var nulls: List[String] = ["", "c"]
    _write_name_deletes(d + "/eq_name.parquet", nulls, [0])
    var by_name = _basic_spec()
    _add_delete(by_name, d + "/eq_name.parquet", 2, "PARQUET", cols)
    _add_data(by_name, d + "/eq_data.parquet", "", List[Int](), one)
    var after_name = _ids_of(read_iceberg_scan(by_name))
    assert_equal(len(after_name), 2)
    assert_equal(after_name[0], 1)
    assert_equal(after_name[1], 5)

    # The same, with an Avro delete of id 5 as well.
    var avro_payload = List[UInt8]()
    encode_int(5, avro_payload)
    _avro_file(
        d + "/eq_id.avro",
        '{"type":"record","name":"d","fields":[{"name":"id","type":"int"}]}',
        avro_payload,
        1,
    )
    var id_cols = List[String]()
    id_cols.append("id")
    var both = _basic_spec()
    _add_delete(both, d + "/eq_name.parquet", 2, "PARQUET", cols)
    _add_delete(both, d + "/eq_id.avro", 2, "AVRO", id_cols)
    var two = List[Int]()
    two.append(0)
    two.append(1)
    _add_data(both, d + "/eq_data.parquet", "", List[Int](), two)
    var after_both = _ids_of(read_iceberg_scan(both))
    assert_equal(len(after_both), 1)
    assert_equal(after_both[0], 1)

    # x IN (NaN, -0.0): the NaN row and the 0.0 row go.
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    var dead: List[Float64] = [nan[DType.float64](), -0.0]
    b.add_column(fixture_f64_column(dead, List[Int]()))
    _write_parquet(d + "/eq_x.parquet", sb^, b^)
    var x_cols = List[String]()
    x_cols.append("x")
    var by_x = _basic_spec()
    _add_delete(by_x, d + "/eq_x.parquet", 2, "PARQUET", x_cols)
    _add_data(by_x, d + "/eq_data.parquet", "", List[Int](), one)
    var after_x = _ids_of(read_iceberg_scan(by_x))
    assert_equal(len(after_x), 3)
    assert_equal(after_x[0], 3)

    # Avro: (id, name, x) tuples with an int, a nullable string and a double.
    var tuples = List[UInt8]()
    encode_int(2, tuples)
    encode_long(0, tuples)  # name: null
    encode_double(-0.0, tuples)
    encode_int(3, tuples)
    encode_long(1, tuples)
    encode_string("c", tuples)
    encode_double(1.5, tuples)
    encode_int(4, tuples)
    encode_long(1, tuples)
    encode_string("zzz", tuples)
    encode_double(2.5, tuples)
    _avro_file(
        d + "/eq_tuple.avro",
        '{"type":"record","name":"d","fields":[{"name":"id","type":"int"},'
        '{"name":"name","type":["null","string"]},{"name":"x","type":"double"}]}',
        tuples,
        3,
    )
    var tuple_cols = List[String]()
    tuple_cols.append("id")
    tuple_cols.append("name")
    tuple_cols.append("x")
    var by_tuple = _basic_spec()
    _add_delete(by_tuple, d + "/eq_tuple.avro", 2, "AVRO", tuple_cols)
    _add_data(by_tuple, d + "/eq_data.parquet", "", List[Int](), one)
    var after_tuple = _ids_of(read_iceberg_scan(by_tuple))
    assert_equal(len(after_tuple), 3)
    assert_equal(after_tuple[0], 1)
    assert_equal(after_tuple[1], 4)
    assert_equal(after_tuple[2], 5)

    # One key over every supported type, in the file's own types.
    var tsb = SchemaBuilder()
    var tb = RecordBatchBuilder()
    tsb.add_field(Field("i", ArrowType.INT32, True))
    tb.add_column(fixture_i32_column([1, 2, 3], List[Int]()))
    tsb.add_field(Field("f", ArrowType.FLOAT32, True))
    tb.add_column(fixture_f32_column([0.5, 1.5, 2.5], List[Int]()))
    tsb.add_field(Field("d", ArrowType.DATE32, True))
    tb.add_column(fixture_date_column([20700, 20701, 20702], List[Int]()))
    tsb.add_field(Field("flag", ArrowType.BOOL, True))
    tb.add_column(fixture_bool_column([True, False, True], List[Int]()))
    tsb.add_field(Field("s", ArrowType.STRING, True))
    tb.add_column(fixture_string_column(["x", "y", "z"], List[Int]()))
    tsb.add_field(Field.decimal128("p", 9, 2, True))
    tb.add_column(fixture_decimal_column([100, 200, 300], List[Int](), 9, 2))
    tsb.add_field(Field("t", ArrowType.TIMESTAMP_US, True))
    tb.add_column(fixture_micros_column([1788300000000000, 1788300000000001, 1788300000000002], List[Int]()))
    tsb.add_field(Field("g", ArrowType.FLOAT32, True))
    tb.add_column(fixture_f32_column([0.25, 0.5, 0.75], List[Int]()))
    _write_parquet(d + "/types.parquet", tsb^, tb^)
    var dsb = SchemaBuilder()
    var db = RecordBatchBuilder()
    dsb.add_field(Field("i", ArrowType.INT32, True))
    db.add_column(fixture_i32_column([2, 9], List[Int]()))
    dsb.add_field(Field("f", ArrowType.FLOAT32, True))
    db.add_column(fixture_f32_column([1.5, 9.0], List[Int]()))
    dsb.add_field(Field("d", ArrowType.DATE32, True))
    db.add_column(fixture_date_column([20701, 20710], List[Int]()))
    dsb.add_field(Field("flag", ArrowType.BOOL, True))
    db.add_column(fixture_bool_column([False, True], List[Int]()))
    dsb.add_field(Field("s", ArrowType.STRING, True))
    db.add_column(fixture_string_column(["y", "q"], List[Int]()))
    dsb.add_field(Field.decimal128("p", 9, 2, True))
    db.add_column(fixture_decimal_column([200, 5], List[Int](), 9, 2))
    dsb.add_field(Field("t", ArrowType.TIMESTAMP_US, True))
    db.add_column(fixture_micros_column([1788300000000001, 1788300000000009], List[Int]()))
    dsb.add_field(Field("g", ArrowType.FLOAT32, True))
    db.add_column(fixture_f32_column([0.5, 0.0], List[Int]()))
    _write_parquet(d + "/types_delete.parquet", dsb^, db^)
    var typed = IcebergScanSpec()
    _add_column(typed, "i", ArrowType.INT64, 1)
    _add_column(typed, "f", ArrowType.FLOAT64, 2)
    _add_column(typed, "d", ArrowType.DATE32, 3)
    _add_column(typed, "flag", ArrowType.BOOL, 4)
    _add_column(typed, "s", ArrowType.STRING, 5)
    _add_column(typed, "p", ArrowType.DECIMAL128, 6)
    _add_column(typed, "t", ArrowType.TIMESTAMP_US, 7)
    _add_column(typed, "g", ArrowType.FLOAT32, 8)
    var typed_cols = List[String]()
    for k in range(len(typed.column_names)):
        typed_cols.append(typed.column_names[k])
    _add_delete(typed, d + "/types_delete.parquet", 2, "PARQUET", typed_cols)
    _add_data(typed, d + "/types.parquet", "", List[Int](), one)
    var after_typed = read_iceberg_scan(typed)
    assert_equal(after_typed.num_rows(), 2)
    assert_equal(after_typed.column_at(0).as_primitive[DType.int64]().get(0), 1)
    assert_equal(after_typed.column_at(0).as_primitive[DType.int64]().get(1), 3)

    # Refusals.
    var decimal_avro = IcebergScanSpec()
    _add_column(decimal_avro, "p", ArrowType.DECIMAL128, 6)
    var p_cols = List[String]()
    p_cols.append("p")
    var raw = List[UInt8]()
    var bytes_value = List[UInt8]()
    bytes_value.append(1)
    encode_bytes(Span(bytes_value), raw)
    _avro_file(
        d + "/eq_p.avro",
        '{"type":"record","name":"d","fields":[{"name":"p","type":"bytes"}]}',
        raw,
        1,
    )
    _add_delete(decimal_avro, d + "/eq_p.avro", 2, "AVRO", p_cols)
    _add_data(decimal_avro, d + "/types.parquet", "", List[Int](), one)
    assert_equal(
        _error_of(decimal_avro),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: the Avro equality delete file "
        + d
        + "/eq_p.avro is over the decimal column 'p'",
    )
    var unscanned = _basic_spec()
    var z_cols = List[String]()
    z_cols.append("zzz")
    _add_delete(unscanned, d + "/eq_name.parquet", 2, "PARQUET", z_cols)
    _add_data(unscanned, d + "/eq_data.parquet", "", List[Int](), one)
    assert_equal(
        _error_of(unscanned),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/eq_name.parquet: the equality column 'zzz' is not a scanned column",
    )
    var lacking = _basic_spec()
    _add_delete(lacking, d + "/eq_x.parquet", 2, "PARQUET", cols)
    _add_data(lacking, d + "/eq_data.parquet", "", List[Int](), one)
    assert_equal(
        _error_of(lacking),
        "ICEBERG_DATA_FILE_MISMATCH: " + d + "/eq_x.parquet: the file has no column 'name'",
    )
    var bytes_name = _basic_spec()
    _avro_file(
        d + "/eq_bytes.avro",
        '{"type":"record","name":"d","fields":[{"name":"name","type":"bytes"}]}',
        raw,
        1,
    )
    _add_delete(bytes_name, d + "/eq_bytes.avro", 2, "AVRO", cols)
    _add_data(bytes_name, d + "/eq_data.parquet", "", List[Int](), one)
    assert_equal(
        _error_of(bytes_name),
        "ICEBERG_DATA_FILE_MISMATCH: "
        + d
        + "/eq_bytes.avro: the column 'name' holds a value of an unsupported Avro type",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_position_deletes_remove_rows_by_stored_path_and_position]()
    suite.test[test_equality_deletes_match_null_to_null_and_nan_to_nan]()
    suite^.run()
