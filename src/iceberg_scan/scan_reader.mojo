# =============================================================================
# iceberg_scan/scan_reader.mojo -- the rows of a planned Iceberg scan
# =============================================================================
#
# WHAT THIS IS. `read_iceberg_scan` is what the pipeline's SOURCE_ICEBERG arm
# calls: it reads every data file of an `IcebergScanSpec` in order, applies the
# delete files the planner matched to it, and returns the surviving rows of all
# files as one batch whose schema is the spec's columns, every field nullable.
# A spec of no data file is a batch of no rows of that schema.
#
# BINDING A SPEC COLUMN TO A FILE COLUMN.
#   * A Parquet file that carries field ids (`SchemaElement.field_id`) binds by
#     id: a column renamed or reordered since the file was written still reads,
#     and a column the file has no id for reads as nulls even when a column of
#     that name exists (its id was dropped and the name reused).
#   * A file with no field ids binds by name.
#   * A column the file lacks is all null.
#   * A file column of the bound type is read as it is; int widens to long and
#     float to double; an int64 column (or one of the legacy microsecond
#     timestamp type) is a timestamp, which Iceberg stores as INT64 microseconds;
#     a decimal must have the scale and precision its column is typed at. Any
#     other difference is `ICEBERG_DATA_FILE_MISMATCH` naming the file and the
#     column.
#   * A decimal column's precision and scale, and a timestamp column's zone,
#     are the table's when the spec carries the Iceberg type names (the planner
#     always sets them: `timestamptz` reads in UTC). A spec without them takes
#     both from the first data file that holds the column; a column no file
#     holds is then decimal(38, 0) or naive.
#
# DELETES.
#   * Position deletes (Parquet or Avro: `file_path`, `pos`) remove the rows
#     of a data file whose file-absolute position is named under its stored
#     path.
#   * Equality deletes (Parquet or Avro) remove the rows whose values of the
#     delete's columns equal a row of the delete file. Null equals null, as the
#     table spec says. Floats compare by value (NaN equals NaN, -0.0 equals
#     0.0). An Avro equality delete over a decimal column is refused.
#   * Each delete file is read once per scan, however many data files use it.
#
# ERRORS. `ICEBERG_DATA_FILE_MISMATCH: <file>: <what>` for a file that cannot be
# read or whose column cannot be read at the bound type;
# `ICEBERG_MANIFEST_INVALID` for an Avro delete file that does not decode.
# =============================================================================

from std.collections import Dict
from std.memory import bitcast

from arrow.arrow_types import ArrowType
from arrow.bitmap import Bitmap
from arrow.column import Column
from arrow.concat import concat_record_batches_nway
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from async_rt.ops.waker_sink import NoopSink
from byte_buffer.byte_view import ByteView
from byte_buffer.heap_region import HeapRegion
from byte_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from column_kernels.compiler_helpers import gather_batch
from containers.slab import Slab
from fs.local_fs import LocalFs
from parquet.file_decode import decode_parquet_file_from_bytes
from parquet.metadata_parser import parse_full_metadata
from physical_plan.iceberg_scan_spec import IcebergScanSpec

from .avro_datum import (
    AVRO_DATUM_BOOL,
    AVRO_DATUM_DOUBLE,
    AVRO_DATUM_FLOAT,
    AVRO_DATUM_INT,
    AVRO_DATUM_LONG,
    AVRO_DATUM_STRING,
    read_avro_datums,
)
from .local_file import read_local_file
from .table_ref import iceberg_arrow_field
from .table_metadata import IcebergField, OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED


comptime ICEBERG_DATA_FILE_MISMATCH: String = "ICEBERG_DATA_FILE_MISMATCH"

comptime _Fs = LocalFs[NoopSink]

# The reserved field ids of a position delete file's columns.
comptime _POS_DELETE_PATH_ID: Int = 2147483546
comptime _POS_DELETE_POS_ID: Int = 2147483545

comptime _DEFAULT_DECIMAL_PRECISION: Int = 38
comptime _DEFAULT_DECIMAL_SCALE: Int = 0

# What binding a file column to a bound type takes.
comptime _AS_IS: Int = 0
comptime _WIDEN_INT: Int = 1
comptime _WIDEN_FLOAT: Int = 2
comptime _AS_TIMESTAMP: Int = 3
comptime _NO_BINDING: Int = -1


def _mismatch(path: String, what: String) -> Error:
    return Error(
        ICEBERG_DATA_FILE_MISMATCH + String(": ") + path + String(": ") + what
    )


# =============================================================================
# One Parquet file.
# =============================================================================


struct _ParquetFile(Movable):
    var path: String
    var batch: RecordBatch
    var rows: Int
    var names: List[String]
    var ids: List[Int]
    """The leaf's field id, or -1 when it has none."""
    var has_ids: Bool

    def __init__(
        out self,
        var path: String,
        var batch: RecordBatch,
        rows: Int,
        var names: List[String],
        var ids: List[Int],
        has_ids: Bool,
    ):
        self.path = path^
        self.batch = batch^
        self.rows = rows
        self.names = names^
        self.ids = ids^
        self.has_ids = has_ids

    def leaf(self, name: String, field_id: Int) -> Int:
        """The leaf a column binds to (module header), or -1."""
        for i in range(len(self.names)):
            if self.has_ids:
                if self.ids[i] == field_id:
                    return i
            elif self.names[i] == name:
                return i
        return -1


def _magic_at(file: ByteView[_], offset: Int) -> Bool:
    return (
        file.read_u8_at(offset) == 0x50
        and file.read_u8_at(offset + 1) == 0x41
        and file.read_u8_at(offset + 2) == 0x52
        and file.read_u8_at(offset + 3) == 0x31
    )


def _open_parquet_inner(path: String) raises -> _ParquetFile:
    var fs = _Fs.new()
    var buf = fs.read_whole(path)
    # `view_range_ro` over the length: a mapped file has no capacity to view.
    var view = buf.view_range_ro(0, buf.len())
    var n = view.len()
    if n < 12:
        raise Error("the file is too short to be a Parquet file")
    if not _magic_at(view, 0) or not _magic_at(view, n - 4):
        raise Error("the file has no PAR1 magic")
    var footer_len = Int(view.read_u32_le_at(n - 8))
    var footer_start = n - 8 - footer_len
    if footer_len == 0 or footer_start < 4:
        raise Error("the footer length does not fit the file")
    var md = parse_full_metadata(view.sub(footer_start, footer_len))
    var names = List[String]()
    var ids = List[Int]()
    var has_ids = False
    for i in range(1, len(md.schema)):
        ref el = md.schema[i]
        if el.num_children > 0:
            raise Error(
                String("the column '") + el.name + String("' is nested; only flat files are read")
            )
        names.append(el.name)
        if el.field_id:
            ids.append(el.field_id.value())
            has_ids = True
        else:
            ids.append(-1)
    if len(md.row_groups) == 0:
        return _ParquetFile(path, RecordBatch(), 0, names^, ids^, has_ids)
    var batch = decode_parquet_file_from_bytes(view)
    var rows = batch.num_rows()
    return _ParquetFile(path, batch^, rows, names^, ids^, has_ids)


def _open_parquet(path: String) raises -> _ParquetFile:
    try:
        return _open_parquet_inner(path)
    except e:
        raise _mismatch(path, String("cannot read the file: ") + String(e))


# =============================================================================
# Columns.
# =============================================================================


def _binding_of(file_type: ArrowType, want: ArrowType) -> Int:
    if file_type == want:
        return _AS_IS
    if want == ArrowType.INT64 and file_type == ArrowType.INT32:
        return _WIDEN_INT
    if want == ArrowType.FLOAT64 and file_type == ArrowType.FLOAT32:
        return _WIDEN_FLOAT
    if want == ArrowType.TIMESTAMP_US and (
        file_type == ArrowType.INT64 or file_type == ArrowType.TIMESTAMP
    ):
        return _AS_TIMESTAMP
    return _NO_BINDING


def _null_column(t: ArrowType, rows: Int, precision: Int, scale: Int) raises -> Column[HeapRegion]:
    """`rows` nulls of type `t`."""
    if t == ArrowType.DECIMAL128:
        var arr = Decimal128Array.allocate_nullable(rows, precision, scale)
        for i in range(rows):
            arr.set_null(i)
        return Column.from_decimal128(arr)
    if t == ArrowType.INT32 or t == ArrowType.DATE32:
        return _null_fixed(t, rows, 4)
    elif t == ArrowType.INT64 or t == ArrowType.TIMESTAMP_US or t == ArrowType.FLOAT64:
        return _null_fixed(t, rows, 8)
    elif t == ArrowType.FLOAT32:
        return _null_fixed(t, rows, 4)
    elif t == ArrowType.BOOL:
        var bytes = (rows + 7) // 8
        var data = OwnedAlignedBuffer(max(bytes, 1))
        data.zero()
        data.set_length(Int64(bytes))
        return Column[HeapRegion](
            arrow_type=t,
            data=data^,
            offsets=None,
            validity=Bitmap.create(rows),
            length=rows,
            null_count=rows,
            offset=0,
        )
    # STRING
    var offsets = OwnedAlignedBuffer((rows + 1) * 4)
    offsets.zero()
    offsets.set_length(Int64((rows + 1) * 4))
    var data = OwnedAlignedBuffer(1)
    data.set_length(0)
    return Column[HeapRegion](
        arrow_type=t,
        data=data^,
        offsets=offsets^,
        validity=Bitmap.create(rows),
        length=rows,
        null_count=rows,
        offset=0,
    )


def _null_fixed(t: ArrowType, rows: Int, width: Int) raises -> Column[HeapRegion]:
    var data = OwnedAlignedBuffer(max(rows * width, 1))
    data.zero()
    data.set_length(Int64(rows * width))
    return Column[HeapRegion](
        arrow_type=t,
        data=data^,
        offsets=None,
        validity=Bitmap.create(rows),
        length=rows,
        null_count=rows,
        offset=0,
    )


def _widen_int(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    var src = col.as_primitive[DType.int32]()
    var n = col.length()
    var out = PrimitiveArray[DType.int64].allocate_nullable(n)
    for r in range(n):
        if col.is_null_at(r):
            out.validity.value().clear(r)
            out.null_count += 1
        else:
            out.set(r, Int64(src.get(r)))
    return Column.from_primitive[DType.int64](out)


def _widen_float(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    var src = col.as_primitive[DType.float32]()
    var n = col.length()
    var out = PrimitiveArray[DType.float64].allocate_nullable(n)
    for r in range(n):
        if col.is_null_at(r):
            out.validity.value().clear(r)
            out.null_count += 1
        else:
            out.set(r, Float64(src.get(r)))
    return Column.from_primitive[DType.float64](out)


struct _Want(Copyable, Movable):
    """A column a file is read at: its name, id, type and, for a decimal, its
    precision and scale."""

    var name: String
    var field_id: Int
    var type: ArrowType
    var precision: Int
    var scale: Int
    var typed_by_table: Bool
    """Whether the precision and scale are the table's (the spec carries the
    type names) rather than the first file's."""

    def __init__(
        out self,
        var name: String,
        field_id: Int,
        type: ArrowType,
        precision: Int,
        scale: Int,
        typed_by_table: Bool = False,
    ):
        self.name = name^
        self.field_id = field_id
        self.type = type
        self.precision = precision
        self.scale = scale
        self.typed_by_table = typed_by_table


def _bound_column(
    file: _ParquetFile, want: _Want, allow_missing: Bool
) raises -> Column[HeapRegion]:
    """The column `want` of `file`, at its bound type (module header)."""
    var leaf = file.leaf(want.name, want.field_id)
    if leaf < 0:
        if not allow_missing:
            raise _mismatch(
                file.path, String("the file has no column '") + want.name + String("'")
            )
        return _null_column(want.type, file.rows, want.precision, want.scale)
    ref src = file.batch.column_at(leaf)
    var how = _binding_of(src.arrow_type, want.type)
    if how == _NO_BINDING:
        raise _mismatch(
            file.path,
            String("the column '")
            + want.name
            + String("' is ")
            + String(src.arrow_type)
            + String(" in the file but is bound as ")
            + String(want.type),
        )
    if how == _WIDEN_INT:
        return _widen_int(src)
    elif how == _WIDEN_FLOAT:
        return _widen_float(src)
    var col = src.deep_copy()
    if how == _AS_TIMESTAMP:
        col.arrow_type = ArrowType.TIMESTAMP_US
    elif want.type == ArrowType.DECIMAL128:
        if (
            file.batch.schema.field_decimal_precision(leaf) != want.precision
            or file.batch.schema.field_decimal_scale(leaf) != want.scale
        ):
            raise _mismatch(
                file.path,
                String("the column '")
                + want.name
                + String("' is decimal(")
                + String(file.batch.schema.field_decimal_precision(leaf))
                + String(",")
                + String(file.batch.schema.field_decimal_scale(leaf))
                + String(") in the file but decimal(")
                + String(want.precision)
                + String(",")
                + String(want.scale)
                + (
                    String(") in the table") if want.typed_by_table else String(
                        ") in the first file that holds it"
                    )
                ),
            )
    return col^


def _table_typed(spec: IcebergScanSpec, c: Int) raises -> Optional[Schema]:
    """The one-column schema of column `c` at the Iceberg type the table gives
    it, when the spec carries the type names (else None)."""
    if len(spec.column_type_names) != len(spec.column_names):
        return None
    var sb = SchemaBuilder()
    sb.add_field(
        iceberg_arrow_field(
            IcebergField(
                spec.column_field_ids[c],
                spec.column_names[c],
                False,
                spec.column_type_names[c],
            )
        )
    )
    return sb.build()


def _wants_of(
    spec: IcebergScanSpec, files: List[_ParquetFile]
) raises -> List[_Want]:
    """The columns of the spec with their decimal precision and scale: the
    table's when the spec carries the type names, else the first file's that
    holds the column (module header)."""
    var out = List[_Want]()
    for c in range(len(spec.column_names)):
        var p = _DEFAULT_DECIMAL_PRECISION
        var s = _DEFAULT_DECIMAL_SCALE
        var typed = False
        if spec.column_types[c] == ArrowType.DECIMAL128:
            var table = _table_typed(spec, c)
            if table:
                p = table.value().field_decimal_precision(0)
                s = table.value().field_decimal_scale(0)
                typed = True
            for i in range(len(files)):
                if typed:
                    break
                var leaf = files[i].leaf(spec.column_names[c], spec.column_field_ids[c])
                if leaf >= 0 and files[i].rows > 0:
                    p = files[i].batch.schema.field_decimal_precision(leaf)
                    s = files[i].batch.schema.field_decimal_scale(leaf)
                    break
        out.append(
            _Want(
                spec.column_names[c],
                spec.column_field_ids[c],
                spec.column_types[c],
                p,
                s,
                typed,
            )
        )
    return out^


def _output_schema(
    spec: IcebergScanSpec, wants: List[_Want], files: List[_ParquetFile]
) raises -> Schema:
    var sb = SchemaBuilder()
    for c in range(len(wants)):
        ref w = wants[c]
        if w.type == ArrowType.DECIMAL128:
            sb.add_field(Field.decimal128(w.name, w.precision, w.scale, True))
        elif w.type == ArrowType.TIMESTAMP_US:
            var tz = String("")
            var table = _table_typed(spec, c)
            if table:
                tz = table.value().field_tz(0)
            for i in range(len(files)):
                if table:
                    break
                var leaf = files[i].leaf(w.name, w.field_id)
                if leaf >= 0 and files[i].rows > 0:
                    tz = files[i].batch.schema.field_tz(leaf)
                    break
            sb.add_field(Field.timestamp(w.name, ArrowType.TIMESTAMP_US, tz, True))
        else:
            sb.add_field(Field(w.name, w.type, True))
    return sb.build()


# =============================================================================
# Keys of rows, for equality deletes.
# =============================================================================


def _int_piece(v: Int64) -> String:
    return String("I") + String(v)


def _float_piece(f: Float64) -> String:
    if f != f:
        return String("FNaN")
    var canonical = f
    if f == 0.0:
        canonical = 0.0
    return String("F") + String(bitcast[DType.int64, 1](canonical))


def _string_piece(s: String) -> String:
    return String("S") + String(s.byte_length()) + String(":") + s


def _pieces(col: Column[HeapRegion]) raises -> List[String]:
    """One key piece per row of a bound column; null is its own piece."""
    var t = col.arrow_type
    var n = col.length()
    var out = List[String](capacity=n)
    if t == ArrowType.INT32 or t == ArrowType.DATE32:
        var a = col.as_primitive[DType.int32]()
        for r in range(n):
            out.append(String("N") if col.is_null_at(r) else _int_piece(Int64(a.get(r))))
    elif t == ArrowType.INT64 or t == ArrowType.TIMESTAMP_US:
        var a = col.as_primitive[DType.int64]()
        for r in range(n):
            out.append(String("N") if col.is_null_at(r) else _int_piece(a.get(r)))
    elif t == ArrowType.FLOAT32:
        var a = col.as_primitive[DType.float32]()
        for r in range(n):
            out.append(String("N") if col.is_null_at(r) else _float_piece(Float64(a.get(r))))
    elif t == ArrowType.FLOAT64:
        var a = col.as_primitive[DType.float64]()
        for r in range(n):
            out.append(String("N") if col.is_null_at(r) else _float_piece(a.get(r)))
    elif t == ArrowType.BOOL:
        var a = col.as_boolean()
        for r in range(n):
            if col.is_null_at(r):
                out.append(String("N"))
            else:
                out.append(_int_piece(Int64(1) if a.get(r) else Int64(0)))
    elif t == ArrowType.STRING:
        var a = col.as_string()
        for r in range(n):
            out.append(String("N") if col.is_null_at(r) else _string_piece(a.get(r)))
    else:
        # DECIMAL128: the 128-bit unscaled value.
        var a = col.as_decimal128()
        for r in range(n):
            if col.is_null_at(r):
                out.append(String("N"))
            else:
                out.append(
                    String("D") + String(a.get_high(r)) + String(":") + String(a.get_low(r))
                )
    return out^


def _keys_of(columns: List[List[String]], rows: Int) -> List[String]:
    """The key of each row: its columns' pieces, in order."""
    var out = List[String](capacity=rows)
    for r in range(rows):
        var key = String("")
        for c in range(len(columns)):
            key += columns[c][r]
            key += String("|")
        out.append(key^)
    return out^


# =============================================================================
# Delete files.
# =============================================================================


struct _PositionDeletes(Movable):
    var paths: List[String]
    var positions: List[Int64]

    def __init__(out self):
        self.paths = List[String]()
        self.positions = List[Int64]()


struct _EqualityDeletes(Movable):
    var keys: Dict[String, Bool]

    def __init__(out self):
        self.keys = Dict[String, Bool]()


def _position_deletes_of(path: String, file_format: String) raises -> _PositionDeletes:
    var out = _PositionDeletes()
    if file_format == "AVRO":
        var raw = read_local_file(path)
        var d = read_avro_datums(Span(raw))
        for r in range(len(d.records)):
            var p = d.get_string(d.records[r], String("file_path"))
            var pos = d.get_long(d.records[r], String("pos"))
            if not p or not pos:
                raise _mismatch(path, String("a position delete row lacks file_path or pos"))
            out.paths.append(p.value())
            out.positions.append(pos.value())
        return out^
    var file = _open_parquet(path)
    if file.rows == 0:
        return out^
    var pi = file.leaf(String("file_path"), _POS_DELETE_PATH_ID)
    var qi = file.leaf(String("pos"), _POS_DELETE_POS_ID)
    if pi < 0 or qi < 0:
        raise _mismatch(path, String("the position delete file has no file_path or pos column"))
    ref pc = file.batch.column_at(pi)
    ref qc = file.batch.column_at(qi)
    if pc.arrow_type != ArrowType.STRING or qc.arrow_type != ArrowType.INT64:
        raise _mismatch(path, String("file_path is not a string column or pos is not a long column"))
    var paths = pc.as_string()
    var positions = qc.as_primitive[DType.int64]()
    for r in range(file.rows):
        if pc.is_null_at(r) or qc.is_null_at(r):
            raise _mismatch(path, String("a position delete row has a null file_path or pos"))
        out.paths.append(paths.get(r))
        out.positions.append(positions.get(r))
    return out^


def _avro_piece(d_kind: Int, i: Int64, f: Float64, text: String) -> String:
    if d_kind == AVRO_DATUM_STRING:
        return _string_piece(text)
    elif d_kind == AVRO_DATUM_FLOAT or d_kind == AVRO_DATUM_DOUBLE:
        return _float_piece(f)
    return _int_piece(i)


def _equality_deletes_of(
    path: String,
    file_format: String,
    columns: List[String],
    wants: List[_Want],
) raises -> _EqualityDeletes:
    var out = _EqualityDeletes()
    var picked = List[Int]()
    for k in range(len(columns)):
        var found = -1
        for c in range(len(wants)):
            if wants[c].name == columns[k]:
                found = c
                break
        if found < 0:
            raise _mismatch(path, String("the equality column '") + columns[k] + String("' is not a scanned column"))
        picked.append(found)
    if file_format == "AVRO":
        var raw = read_local_file(path)
        var d = read_avro_datums(Span(raw))
        for r in range(len(d.records)):
            var key = String("")
            for k in range(len(picked)):
                if wants[picked[k]].type == ArrowType.DECIMAL128:
                    raise Error(
                        OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED
                        + String(": the Avro equality delete file ")
                        + path
                        + String(" is over the decimal column '")
                        + wants[picked[k]].name
                        + String("'")
                    )
                var node = d.field(d.records[r], wants[picked[k]].name)
                if node < 0:
                    key += String("N")
                else:
                    ref n = d.nodes[node]
                    var kind = n.kind
                    if kind == AVRO_DATUM_BOOL or kind == AVRO_DATUM_INT or kind == AVRO_DATUM_LONG or kind == AVRO_DATUM_FLOAT or kind == AVRO_DATUM_DOUBLE or kind == AVRO_DATUM_STRING:
                        key += _avro_piece(kind, n.i, n.f, String(unsafe_from_utf8=Span(n.bytes)))
                    else:
                        raise _mismatch(path, String("the column '") + wants[picked[k]].name + String("' holds a value of an unsupported Avro type"))
                key += String("|")
            out.keys[key] = True
        return out^
    var file = _open_parquet(path)
    if file.rows == 0:
        return out^
    var pieces = List[List[String]]()
    for k in range(len(picked)):
        var col = _bound_column(file, wants[picked[k]], False)
        pieces.append(_pieces(col))
    var keys = _keys_of(pieces, file.rows)
    for r in range(len(keys)):
        out.keys[keys[r]] = True
    return out^


# =============================================================================
# The scan.
# =============================================================================


def _surviving_rows(
    batch: RecordBatch,
    stored_path: String,
    position_deletes: List[Int],
    equality_deletes: List[Int],
    spec: IcebergScanSpec,
    positions: List[_PositionDeletes],
    equalities: List[_EqualityDeletes],
) raises -> List[Int]:
    """The rows of `batch` no delete removes, in order."""
    var rows = batch.num_rows()
    var gone = List[Bool](length=rows, fill=False)
    for k in range(len(position_deletes)):
        ref pd = positions[position_deletes[k]]
        for j in range(len(pd.paths)):
            if pd.paths[j] == stored_path and pd.positions[j] >= 0 and Int(pd.positions[j]) < rows:
                gone[Int(pd.positions[j])] = True
    for k in range(len(equality_deletes)):
        ref spec_delete = spec.deletes[equality_deletes[k]]
        var pieces = List[List[String]]()
        for e in range(len(spec_delete.equality_columns)):
            var idx = batch.schema.column_index(spec_delete.equality_columns[e])
            pieces.append(_pieces(batch.column_at(idx)))
        var keys = _keys_of(pieces, rows)
        ref eq = equalities[equality_deletes[k]]
        for r in range(rows):
            if keys[r] in eq.keys:
                gone[r] = True
    var kept = List[Int]()
    for r in range(rows):
        if not gone[r]:
            kept.append(r)
    return kept^


def read_iceberg_scan(spec: IcebergScanSpec) raises -> RecordBatch:
    """The surviving rows of every data file of `spec`, as one batch of the
    spec's columns (module header)."""
    var files = List[_ParquetFile]()
    for i in range(len(spec.data_files)):
        files.append(_open_parquet(spec.data_files[i].path))
    var wants = _wants_of(spec, files)
    var schema = _output_schema(spec, wants, files)

    # Every delete file once.
    var positions = List[_PositionDeletes]()
    var equalities = List[_EqualityDeletes]()
    for j in range(len(spec.deletes)):
        ref d = spec.deletes[j]
        if d.content == 1:
            positions.append(_position_deletes_of(d.path, d.file_format))
            equalities.append(_EqualityDeletes())
        else:
            positions.append(_PositionDeletes())
            equalities.append(
                _equality_deletes_of(d.path, d.file_format, d.equality_columns, wants)
            )

    var parts = Slab[RecordBatch]()
    for i in range(len(files)):
        ref f = files[i]
        if f.rows == 0:
            continue
        var builder = RecordBatchBuilder()
        for c in range(len(wants)):
            builder.add_column(_bound_column(f, wants[c], True))
        var batch = builder.build(schema.copy())
        ref df = spec.data_files[i]
        if len(df.position_deletes) > 0 or len(df.equality_deletes) > 0:
            var kept = _surviving_rows(
                batch,
                df.stored_path,
                df.position_deletes,
                df.equality_deletes,
                spec,
                positions,
                equalities,
            )
            if len(kept) < f.rows:
                batch = gather_batch(batch, kept)
        parts.append(batch^)
    if len(parts) == 0:
        return RecordBatch.empty_from_schema(schema^)
    if len(parts) == 1:
        var only = parts.pop()
        return only.take()
    return concat_record_batches_nway(parts^)
