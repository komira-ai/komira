# =============================================================================
# iceberg_parquet_data.mojo — Parquet DATA-file encode/decode leg.
# =============================================================================
#
# The data-file body of a table. The merge-on-read LOGIC (manifest layer, commit
# orchestration, `_apply_merge` / `_is_equality_deleted` /
# `_is_position_deleted`) is format-AGNOSTIC: it only ever consumes
# `List[List[RowCell]]` per data file. This module is the seam to Parquet:
#
#   * WRITE: `build_parquet_data_file(schema, rows)` — serialize the typed rows
#     to a Parquet file (in-memory bytes via `ParquetFileWriter.close_to_bytes`),
#     one column per schema field in field order. No file is opened and no
#     temporary path is used: the writer returns the bytes.
#
#   * READ: `read_parquet_data_file(bytes, col_types)` — decode a Parquet data
#     file into the row form the merge algebra consumes: parse the footer,
#     `decode_row_group_from_bytes` per row group, lift each row's cells by
#     column ordinal against `col_types`.
#
# The DELETE files stay Avro (equality-delete + position-delete). That is
# spec-legal — Iceberg v2 permits Avro delete files alongside Parquet data files
# — and the delete decode round-trips the SAME `RowCell` model, so the merge
# predicate is untouched.
#
# DECODE INVARIANT (load-bearing for merge-on-read):
#   * The row-major decode here yields rows in FILE-ABSOLUTE ROW ORDER, with NO
#     pushdown / projection / reordering: `ColumnProjection.all()`, row groups
#     visited in footer order, rows within a row group in decode order. The
#     position-delete predicate (`_is_position_deleted`) masks by the
#     file-absolute row ordinal `ri`, so this decoder MUST NOT reorder or drop
#     rows — every row is emitted, in written order. (A future pushdown /
#     row-selection optimization on the DATA read path would have to preserve
#     the absolute ordinal, or route position deletes differently.)
#
# The Parquet files carry no `PARQUET:field_id` column metadata: a reader binds
# the columns to the table's field ids through the `schema.name-mapping.default`
# table property that metadata.json carries.
#
# Encapsulation: every public function takes owned/borrowed typed values and
# returns owned List[UInt8] / owned List[List[RowCell]]. ZERO UnsafePointer in
# any signature; ZERO wildcard origins; no address rebuilt from an integer and
# no partial move through a pointer.
# The bytes-view construction is confined to a `SharedAlignedBuffer` (which owns
# the bytes and yields origin-tied views via its own methods) — the raw pointer
# never crosses this module's boundary.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_parquet_api.types import ParquetType
from komira_parquet_writer.writer import ParquetFileWriter
from komira_parquet_writer.writer_helpers import (
    make_schema_elements,
    make_schema_elements_nullable,
)
from komira_parquet.bytes_decode import (
    ByteRange,
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
)
from .iceberg_row_value import (
    RowCell,
    make_boolean_cell,
    make_int_cell,
    make_long_cell,
    make_float_cell,
    make_double_cell,
    make_string_cell,
    make_null_cell,
    reconcile_cell_type,
)


# Parquet trailing PAR1 magic bytes (P=80, A=65, R=82, 1=49).
comptime _PAR1_0: UInt8 = 80
comptime _PAR1_1: UInt8 = 65
comptime _PAR1_2: UInt8 = 82
comptime _PAR1_3: UInt8 = 49


# =============================================================================
# Iceberg-type -> Parquet-physical-type mapping.
# =============================================================================


def _parquet_type_of(iceberg_tag: Int) raises -> ParquetType:
    """Map an Iceberg primitive type tag to its Parquet physical type.

    Mirrors the mapping documented on the ICE_T_* constants in iceberg_types:
      BOOLEAN -> BOOLEAN, INT -> INT32, LONG -> INT64, FLOAT -> FLOAT,
      DOUBLE -> DOUBLE, STRING -> BYTE_ARRAY (UTF-8)."""
    if iceberg_tag == ICE_T_BOOLEAN:
        return ParquetType.BOOLEAN
    elif iceberg_tag == ICE_T_INT:
        return ParquetType.INT32
    elif iceberg_tag == ICE_T_LONG:
        return ParquetType.INT64
    elif iceberg_tag == ICE_T_FLOAT:
        return ParquetType.FLOAT
    elif iceberg_tag == ICE_T_DOUBLE:
        return ParquetType.DOUBLE
    elif iceberg_tag == ICE_T_STRING:
        return ParquetType.BYTE_ARRAY
    raise Error(
        "iceberg_parquet_data: unmapped iceberg type tag "
        + String(iceberg_tag)
    )


# =============================================================================
# WRITE — serialize typed rows to a REAL Parquet data file (in-memory bytes).
# =============================================================================


def build_parquet_data_file(
    schema: IcebergSchema, rows: List[List[RowCell]]
) raises -> List[UInt8]:
    """Serialize a DATA file as Parquet over full typed `rows` (each a tuple of
    cells matching `schema` in column order).

    One Parquet column per schema field, in field order; the physical type is
    the Iceberg-tag -> Parquet-type mapping (`_parquet_type_of`). The bytes are
    assembled in memory (`ParquetFileWriter.close_to_bytes`) — no disk I/O and no
    temporary file.

    Column-major write: each field's cells are gathered across all rows into a
    typed Arrow array, then written as one PLAIN column page. This is the write
    inverse of `read_parquet_data_file`.

    Fail loud, no silent coerce: before a cell is encoded into its column, its
    `type_tag` is reconciled against the schema field's DECLARED type
    (`reconcile_cell_type`). A cell that CANNOT be represented in the declared
    column type — e.g. a STRING cell (an over-Int64 canonical-decimal
    promotion) for a LONG column, which `as_long()` would silently coerce to 0
    — RAISES rather than corrupting. A genuine NULL cell (matching tag) does NOT
    raise: a NULLABLE column writes it as NULL (validity bit cleared), while a
    NULL for a REQUIRED (NOT NULL) column raises (a null in a required column is
    a real ingest error)."""
    var ncols = len(schema.fields)

    # Build the Parquet schema elements (name + physical type + nullability per
    # field). Nullable (Iceberg `required=False`) columns are OPTIONAL so genuine
    # null cells write real NULL (def-levels), not a coerced 0.
    var col_names = List[String]()
    var types = List[ParquetType]()
    var col_nullable = List[Bool]()
    for c in range(ncols):
        col_names.append(String(schema.fields[c].name))
        types.append(_parquet_type_of(schema.fields[c].type_tag))
        col_nullable.append(not schema.fields[c].required)
    var schema_elements = make_schema_elements_nullable(
        col_names^, types, col_nullable
    )

    var writer = ParquetFileWriter.create(schema_elements^)

    # Validate row arity up-front (matches build_data_file's contract).
    for r in range(len(rows)):
        if len(rows[r]) != ncols:
            raise Error(
                "build_parquet_data_file: row arity != schema column count"
            )

    var nrows = len(rows)

    # Column-major: gather each field's values across all rows, write one page.
    for c in range(ncols):
        var t = schema.fields[c].type_tag
        var col_name = String(schema.fields[c].name)
        var nullable = not schema.fields[c].required

        # Reconcile every cell's tag against the DECLARED column type BEFORE
        # touching a value arm. A mismatch (STRING-for-LONG etc.) raises loud
        # here rather than silently coercing to 0 downstream. A null cell of the
        # right declared type passes this check (its tag matches).
        for r in range(nrows):
            reconcile_cell_type(rows[r][c], t, col_name)
            # A NULL cell in a REQUIRED (NOT NULL) column is a real error.
            if rows[r][c].is_null() and not nullable:
                raise Error(
                    "build_parquet_data_file: NULL value in required column '"
                    + col_name
                    + "' (Iceberg required columns are NOT NULL)"
                )

        if t == ICE_T_BOOLEAN:
            if nullable:
                var arr = BooleanArray.allocate_nullable(nrows)
                for r in range(nrows):
                    if rows[r][c].is_null():
                        arr._set_null(r)
                    else:
                        arr.set(r, rows[r][c].as_long() != Int64(0))
                writer.write_boolean_batch(c, arr)
            else:
                var arr = BooleanArray.allocate(nrows)
                for r in range(nrows):
                    arr.set(r, rows[r][c].as_long() != Int64(0))
                writer.write_boolean_batch(c, arr)
        elif t == ICE_T_INT:
            _write_primitive_col[DType.int32](writer, c, rows, nrows, nullable)
        elif t == ICE_T_LONG:
            _write_primitive_col[DType.int64](writer, c, rows, nrows, nullable)
        elif t == ICE_T_FLOAT:
            _write_primitive_col[DType.float32](
                writer, c, rows, nrows, nullable
            )
        elif t == ICE_T_DOUBLE:
            _write_primitive_col[DType.float64](
                writer, c, rows, nrows, nullable
            )
        elif t == ICE_T_STRING:
            if nullable:
                var vals = List[String]()
                var valid = List[Bool]()
                for r in range(nrows):
                    if rows[r][c].is_null():
                        vals.append(String(""))
                        valid.append(False)
                    else:
                        vals.append(rows[r][c].as_string())
                        valid.append(True)
                var arr = StringArray[HeapRegion].from_strings_with_validity(
                    vals, valid
                )
                writer.write_string_batch(c, arr)
            else:
                var vals = List[String]()
                for r in range(nrows):
                    vals.append(rows[r][c].as_string())
                var arr = StringArray[HeapRegion].from_strings(vals)
                writer.write_string_batch(c, arr)
        else:
            raise Error(
                "build_parquet_data_file: unmapped iceberg type tag "
                + String(t)
            )

    return writer.close_to_bytes()


@always_inline
def _cell_primitive_value[
    dtype: DType
](cell: RowCell) -> Scalar[dtype]:
    """The `dtype`-typed value of a numeric cell (already reconciled to a
    matching column type by the caller). Integral dtypes read the integral arm;
    floating dtypes read the floating arm."""
    comptime if dtype == DType.float32 or dtype == DType.float64:
        return cell.as_double().cast[dtype]()
    else:
        return cell.as_long().cast[dtype]()


def _write_primitive_col[
    dtype: DType
](
    mut writer: ParquetFileWriter,
    c: Int,
    rows: List[List[RowCell]],
    nrows: Int,
    nullable: Bool,
) raises:
    """Write column `c` as a `dtype` PrimitiveArray page. Nullable columns write
    genuine NULL for null cells (validity bit cleared via `_set_null`), not a
    coerced 0; required columns take the all-valid fast path."""
    if nullable:
        var arr = PrimitiveArray[dtype].allocate_nullable(nrows)
        for r in range(nrows):
            if rows[r][c].is_null():
                arr._set_null(r)
            else:
                arr.set(r, _cell_primitive_value[dtype](rows[r][c]))
        writer.write_batch[dtype](c, arr)
    else:
        var vals = List[Scalar[dtype]]()
        for r in range(nrows):
            vals.append(_cell_primitive_value[dtype](rows[r][c]))
        var arr = PrimitiveArray[dtype].from_list(vals)
        writer.write_batch[dtype](c, arr)


# =============================================================================
# READ — decode a REAL Parquet data file into typed rows.
# =============================================================================


def check_row_group_range(start: Int, end: Int, limit: Int) raises:
    """Refuse a row-group byte range `[start, end)` that is negative, inverted
    (an overflowed sum ends below its start) or reaches past `limit`, the end of
    the file's data region. `SharedAlignedBuffer.view_range_ro` checks its
    bounds only in debug builds, and the range comes from the footer."""
    if start < 0 or end < start or end > limit:
        raise Error(
            "read_parquet_data_file: a row group claims bytes ["
            + String(start)
            + ", "
            + String(end)
            + ") outside the file's data region [0, "
            + String(limit)
            + ")"
        )


def read_parquet_data_file(
    bytes: List[UInt8], col_types: List[Int]
) raises -> List[List[RowCell]]:
    """Decode a Parquet data file (whole object, in memory) into its typed rows
    — the row form the merge algebra consumes.

    `col_types` is the schema's column type tags in column order (from
    `col_types_of`); we address the decoded columns by ordinal and lift each
    cell to its declared Iceberg type, exactly as the Avro decoder did.

    Loads the bytes into a `SharedAlignedBuffer` (so view offsets == file
    absolute offsets), parses the footer, and decodes each row group via the
    IO-free `decode_row_group_from_bytes`. Rows are emitted in FILE-ABSOLUTE
    ROW ORDER (no pushdown / projection / reorder) — see the module header's
    DECODE INVARIANT (the position-delete predicate depends on it)."""
    var n = len(bytes)
    if n < 12:
        raise Error(
            "read_parquet_data_file: data object too small ("
            + String(n)
            + " bytes) to be a Parquet file"
        )
    # Trailing 8 bytes = footer_len (4 LE) + PAR1 magic (4).
    if (
        bytes[n - 4] != _PAR1_0
        or bytes[n - 3] != _PAR1_1
        or bytes[n - 2] != _PAR1_2
        or bytes[n - 1] != _PAR1_3
    ):
        raise Error(
            "read_parquet_data_file: missing trailing PAR1 magic (the data"
            " object is not a Parquet file)"
        )
    var footer_len = (
        Int(bytes[n - 8])
        | (Int(bytes[n - 7]) << 8)
        | (Int(bytes[n - 6]) << 16)
        | (Int(bytes[n - 5]) << 24)
    )
    if footer_len <= 0 or footer_len + 8 > n:
        raise Error(
            "read_parquet_data_file: invalid footer length "
            + String(footer_len)
        )
    var metadata_offset = n - 8 - footer_len

    # Load the whole object into an aligned buffer (view offsets == file
    # absolute offsets, so each row group's byte range slices directly in).
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    buf.copy_from_bytes_list(bytes.copy())
    buf.set_length(n)

    var meta = parse_full_metadata(
        buf.view_range_ro(metadata_offset, footer_len)
    )
    var out = List[List[RowCell]]()
    var ncols = len(col_types)
    var num_rgs = len(meta.row_groups)
    for rg_idx in range(num_rgs):
        var rg = meta.row_groups[rg_idx].copy()
        var rg_br = row_group_byte_range(rg)
        # The range comes from the footer, which is untrusted, and the view
        # below is bounds-checked only in debug builds.
        check_row_group_range(rg_br.start, rg_br.end, metadata_offset)
        var rg_view = buf.view_range_ro(rg_br.start, rg_br.length())
        var batch = decode_row_group_from_bytes(
            rg_view,
            rg_br,
            rg,
            meta.schema.copy(),
            ColumnProjection.all(),
        )
        # Schema evolution (add-column) tolerance: an OLD data file (written under
        # a prior, NARROWER schema) has FEWER columns than the current schema.
        # We read the file's own columns by ordinal and NULL-FILL the trailing
        # schema columns (the added columns absent from this file). A file WIDER
        # than the schema is an error (drop-column is not supported).
        var file_cols = batch.num_columns()
        if file_cols > ncols:
            raise Error(
                "read_parquet_data_file: row group has "
                + String(file_cols)
                + " columns, MORE than the schema's "
                + String(ncols)
                + " (drop-column / schema narrowing is not supported)"
            )
        _append_batch_rows(batch, col_types, file_cols, out)
        _ = batch

    # KEEPALIVE: hold `buf` alive past the column lifts. ASAP destruction can
    # drop `buf` immediately after the last `view_range_ro`, but a
    # freshly-decoded column's first data page can still be in flight against
    # the source view. A REAL read on `buf` after the rows are built anchors the
    # buffer's liveness through the decode (an empty `_ = buf` is NOT reliable;
    # a real read is).
    var _anchor = buf.read_u8_at(n - 1)
    _ = _anchor
    _ = buf^
    return out^


def _append_batch_rows(
    batch: RecordBatch,
    col_types: List[Int],
    file_cols: Int,
    mut out: List[List[RowCell]],
) raises:
    """Lift every row of `batch` (in decode order) into `out` as typed cells,
    addressing columns by ordinal against `col_types`.

    `file_cols` is the number of columns the DATA FILE actually has (its Parquet
    arity). It may be FEWER than `len(col_types)` (the current schema's arity)
    when the file was written under a prior, NARROWER schema — the trailing
    schema columns (added AFTER this file was written) are NULL-FILLED
    (`make_null_cell`) rather than read from the (absent) file column. This is
    the schema-evolution add-column tolerance.

    Split out of `read_parquet_data_file` so the per-column typed extraction is
    done ONCE per row group (each `as_primitive` / `as_string` / `as_boolean`
    copies the column into a typed array; doing it per-row would be O(rows*cols)
    copies). The two loops are: (1) extract each PRESENT column into its typed
    array; (2) walk rows, reading cell (r, c) from the pre-extracted array (or
    null-filling for c >= file_cols)."""
    var ncols = len(col_types)
    var nrows = batch.num_rows()

    # Pre-extract each PRESENT column into a typed array (once per row group).
    # We hold them in parallel Optionals keyed by the column's declared type so
    # the per-row read is a direct `.get(r)` with no re-extraction. Columns at
    # ordinal >= file_cols are absent from the file (null-filled below), so we
    # only extract the file's own [0, file_cols) columns.
    var int32_cols = List[Optional[PrimitiveArray[DType.int32]]]()
    var int64_cols = List[Optional[PrimitiveArray[DType.int64]]]()
    var f32_cols = List[Optional[PrimitiveArray[DType.float32]]]()
    var f64_cols = List[Optional[PrimitiveArray[DType.float64]]]()
    var bool_cols = List[Optional[BooleanArray]]()
    var str_cols = List[Optional[StringArray[HeapRegion]]]()

    for c in range(ncols):
        var t = col_types[c]
        int32_cols.append(None)
        int64_cols.append(None)
        f32_cols.append(None)
        f64_cols.append(None)
        bool_cols.append(None)
        str_cols.append(None)
        if c >= file_cols:
            continue  # absent from the file -> null-filled, no extraction.
        if t == ICE_T_BOOLEAN:
            bool_cols[c] = batch.column_at(c).as_boolean()
        elif t == ICE_T_INT:
            int32_cols[c] = batch.column_at(c).as_primitive[DType.int32]()
        elif t == ICE_T_LONG:
            int64_cols[c] = batch.column_at(c).as_primitive[DType.int64]()
        elif t == ICE_T_FLOAT:
            f32_cols[c] = batch.column_at(c).as_primitive[DType.float32]()
        elif t == ICE_T_DOUBLE:
            f64_cols[c] = batch.column_at(c).as_primitive[DType.float64]()
        elif t == ICE_T_STRING:
            str_cols[c] = batch.column_at(c).as_string()
        else:
            raise Error(
                "read_parquet_data_file: unmapped iceberg type tag "
                + String(t)
            )

    for r in range(nrows):
        var row = List[RowCell]()
        for c in range(ncols):
            var t = col_types[c]
            if c >= file_cols:
                # column added AFTER this file was written -> NULL.
                row.append(make_null_cell(t))
            elif t == ICE_T_BOOLEAN:
                if bool_cols[c].value().is_null(r):
                    row.append(make_null_cell(t))
                else:
                    row.append(make_boolean_cell(bool_cols[c].value().get(r)))
            elif t == ICE_T_INT:
                if int32_cols[c].value().is_null(r):
                    row.append(make_null_cell(t))
                else:
                    row.append(make_int_cell(int32_cols[c].value().get(r)))
            elif t == ICE_T_LONG:
                if int64_cols[c].value().is_null(r):
                    row.append(make_null_cell(t))
                else:
                    row.append(make_long_cell(int64_cols[c].value().get(r)))
            elif t == ICE_T_FLOAT:
                if f32_cols[c].value().is_null(r):
                    row.append(make_null_cell(t))
                else:
                    row.append(make_float_cell(f32_cols[c].value().get(r)))
            elif t == ICE_T_DOUBLE:
                if f64_cols[c].value().is_null(r):
                    row.append(make_null_cell(t))
                else:
                    row.append(make_double_cell(f64_cols[c].value().get(r)))
            else:  # ICE_T_STRING
                if str_cols[c].value().is_null(r):
                    row.append(make_null_cell(t))
                else:
                    row.append(make_string_cell(str_cols[c].value().get(r)))
        out.append(row^)
