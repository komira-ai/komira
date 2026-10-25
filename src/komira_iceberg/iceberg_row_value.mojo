# =============================================================================
# iceberg_row_value.mojo — Avro row encode/decode over the shared `RowCell`.
# =============================================================================
#
# The delete-file writer, the Avro data-file writer and the merge-on-read reader
# all need ONE shared, typed representation of a table cell that:
#   (a) round-trips through Avro binary (the delete files are Avro OCF), and
#   (b) supports VALUE EQUALITY (equality-delete matching is "does this data
#       row's equality columns EQUAL a delete row's equality columns?").
#
# (b) — the CELL MODEL ITSELF — lives in `komira_rowcell` (`RowCell`, its
# `CELL_T_*` tags, the `make_*_cell` constructors, `rows_equal`): it is not
# Iceberg's, and a consumer of the cell alone should not carry the Avro and
# Parquet closure of this package. This file keeps (a), the ICEBERG-SPECIFIC
# half: the Avro wire form, the schema-driven data-file build/read, and the
# encode-boundary type reconciliation. The cell symbols are RE-EXPORTED below.
#
# WHY a typed-cell Avro row form for the data file (not Parquet): it proves
# insert -> update -> delete -> read-back CORRECTNESS over the in-memory /
# local store. Merge-on-read correctness (sequence ordering + equality-key
# matching + position masking) lives at the ROW level; serializing data and
# delete rows in ONE decode-symmetric Avro form lets the reader decode and
# compare rows WITHOUT the Parquet decode stack. The real-Parquet append path
# (iceberg_writer.commit_append) is separate.
#
# The Avro row form is REQUIRED-only (no null union): a null cell encodes as
# its type's zero value. Callers that need NULL keep to the Parquet path.
#
# Encapsulation: every function takes owned/borrowed typed values and returns
# owned List[UInt8] / typed values. ZERO UnsafePointer in any signature; ZERO
# wildcard origins.
# =============================================================================

from komira_avro.ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header_kv,
    emit_ocf_block,
)
from komira_avro.ocf_header import AVRO_CODEC_NULL
from komira_avro.ocf_block_scan import scan_ocf_blocks
from komira_avro.varint_encode import (
    encode_long,
    encode_int,
    encode_boolean,
    encode_float,
    encode_double,
    encode_string,
)
from komira_avro.varint_decode_scalar import AvroByteReader

# The shared cell model — the zero-dep leaf. RE-EXPORTED from this module (and
# hence from the package `__init__`) so every historical import path still
# resolves. Do NOT move any of these back into this file: this file depends on
# komira_avro, and pulling the cell back here would put the Avro closure into
# every consumer of the cell.
from komira_rowcell.row_cell import (
    RowCell,
    make_boolean_cell,
    make_int_cell,
    make_long_cell,
    make_float_cell,
    make_double_cell,
    make_string_cell,
    make_null_cell,
    rows_equal,
)

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
    iceberg_type_name,
    json_escape_string,
)


# =============================================================================
# Type reconciliation at the encode boundary (fail loud, no silent coerce).
# =============================================================================
#
# A cell whose `type_tag` does NOT match the declared column type would be
# SILENTLY coerced to a wrong value at the encode boundary: `as_long()` on a
# STRING cell returns 0 (the unused integral arm), so a >Int64 integer KEY
# promoted to a canonical-decimal STRING cell (value-preserving at the RowCell
# level) would encode as LONG 0. Two distinct large keys both
# collapse to 0 => a cross-key equality-delete collision (one key's delete masks
# the other key's row). The absent-column `make_null_cell` + wrong-tag shape is
# the same class.
#
# The rule: a value that is UNREPRESENTABLE in the declared column type is a
# REAL ingest error (the honest precedent is `_parse_int64` RAISING on overflow
# rather than wrapping), NOT something to coerce to 0. So the encode boundary
# reconciles each cell's `type_tag` against the schema field's declared type and
# RAISES (naming the column + why) on a mismatch.
#
# A GENUINE NULL cell (`make_null_cell(tag)`) carries the DECLARED `type_tag`
# (its null flag is orthogonal to its tag), so it MATCHES its column and does
# NOT raise (the Avro row form then writes the type's zero value; see the file
# header) and never wrongly raises. Only a TYPE-MISMATCH (a cell whose active tag differs from the
# column's declared tag — e.g. a STRING cell for a LONG column) raises.
#
# This check lives HERE, not with the cell model, because it is an ICEBERG
# ENCODE-boundary rule: it is phrased against a declared Iceberg column type and
# its errors are Iceberg-encode errors.


@always_inline
def reconcile_cell_type(
    cell: RowCell, declared_tag: Int, col_name: String
) raises:
    """RAISE if `cell` cannot be represented in a column of declared type
    `declared_tag`; return silently if it can.

    Representable iff `cell.type_tag == declared_tag`. A null cell carries its
    declared tag, so a genuine null of the RIGHT type is representable (the Avro row form writes
    the zero value). A cell of a DIFFERENT tag (the over-Int64 STRING-for-LONG case, or any
    tag/column mismatch that would silently coerce to a wrong value via the
    unused value arm) is NOT representable — this is a real ingest error, so we
    fail loud rather than silently encode 0 / the wrong wire form.

    `col_name` names the offending column in the error (the caller passes the
    schema field name / a field-id label)."""
    if cell.type_tag == declared_tag:
        return
    # The dominant, security-relevant case: a value promoted to a STRING cell
    # (the over-Int64 canonical-decimal promotion) landing in a numeric
    # column. `as_long()` / `as_double()` would silently return 0 here.
    if cell.type_tag == ICE_T_STRING and (
        declared_tag == ICE_T_LONG
        or declared_tag == ICE_T_INT
        or declared_tag == ICE_T_BOOLEAN
    ):
        raise Error(
            "iceberg encode: value not representable in "
            + iceberg_type_name(declared_tag)
            + " column '"
            + col_name
            + "': a STRING-typed cell (e.g. an over-Int64 integer promoted to a"
            + " canonical-decimal string) cannot be encoded as "
            + iceberg_type_name(declared_tag)
            + " without silently coercing to 0 — reject rather than corrupt"
        )
    raise Error(
        "iceberg encode: cell type "
        + iceberg_type_name(cell.type_tag)
        + " does not match declared "
        + iceberg_type_name(declared_tag)
        + " column '"
        + col_name
        + "' (would silently coerce to a wrong value) — reject rather than"
        + " corrupt"
    )


# =============================================================================
# Per-cell Avro encode / decode (positional, by declared type).
# =============================================================================
#
# A row is encoded as its cells in column order, each cell in its Avro primitive
# form — REQUIRED (no null union). The writer and reader agree on the column
# TYPES out-of-band (the schema / equality_ids), so the wire form is a bare
# positional record, exactly like an Iceberg data-file row for required columns.


def encode_cell(cell: RowCell, mut out: List[UInt8]):
    """Encode one cell into `out` in its declared Avro primitive form."""
    var t = cell.type_tag
    if t == ICE_T_BOOLEAN:
        encode_boolean(cell.i != Int64(0), out)
    elif t == ICE_T_INT:
        encode_int(Int32(cell.i), out)
    elif t == ICE_T_LONG:
        encode_long(cell.i, out)
    elif t == ICE_T_FLOAT:
        encode_float(Float32(cell.f), out)
    elif t == ICE_T_DOUBLE:
        encode_double(cell.f, out)
    else:  # ICE_T_STRING
        encode_string(cell.s, out)


def read_checked_string[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o]) raises -> String:
    """The next Avro string, as a `String` only if its bytes are valid UTF-8.

    The reader's own `read_string` builds the `String` from a NUL-terminated
    copy without validating it: invalid UTF-8 becomes an invalid `String`, and
    an embedded NUL ends the text early while the cursor advances past it. These
    bytes come from an object store, so they are checked here and kept whole."""
    var raw = reader.read_bytes()
    try:
        return String(from_utf8=Span(raw))
    except e:
        raise Error("iceberg avro: string is not valid UTF-8")


def decode_cell[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o], type_tag: Int) raises -> RowCell:
    """Decode one cell of declared `type_tag` from `reader`."""
    if type_tag == ICE_T_BOOLEAN:
        return make_boolean_cell(reader.read_boolean())
    elif type_tag == ICE_T_INT:
        return make_int_cell(reader.read_int())
    elif type_tag == ICE_T_LONG:
        return make_long_cell(reader.read_long())
    elif type_tag == ICE_T_FLOAT:
        return make_float_cell(reader.read_float())
    elif type_tag == ICE_T_DOUBLE:
        return make_double_cell(reader.read_double())
    elif type_tag == ICE_T_STRING:
        return make_string_cell(read_checked_string(reader))
    raise Error("decode_cell: unknown type tag " + String(type_tag))


def encode_row(row: List[RowCell], mut out: List[UInt8]):
    """Encode a full row (cells in column order) into `out`."""
    for i in range(len(row)):
        encode_cell(row[i], out)


def decode_row[
    o: Origin[mut=False]
](mut reader: AvroByteReader[o], col_types: List[Int]) raises -> List[RowCell]:
    """Decode a full row of `col_types` (in column order) from `reader`."""
    var out = List[RowCell]()
    for i in range(len(col_types)):
        out.append(decode_cell(reader, col_types[i]))
    return out^


def decode_partition_cell(blob: List[UInt8], type_tag: Int) raises -> RowCell:
    """Decode a single partition value from its raw Avro byte blob (the form
    `encode_cell` produced + `ManifestEntry.partition_avro` carries) back into a
    typed `RowCell`.

    Wraps the blob in an `AvroByteReader` and reads exactly one cell of the
    declared `type_tag`. The decode inverse of `encode_partition_values` /
    `encode_cell` for one partition field's value."""
    var reader = AvroByteReader(Span(blob))
    return decode_cell(reader, type_tag)


# =============================================================================
# DATA file (Avro OCF of typed rows).
# =============================================================================
#
# A data file here is an Avro OCF of full typed rows (all schema columns, in
# order, required). Symmetric with the delete files, so ONE decoder shape drives
# both sides of the merge. The real-Parquet append path
# (iceberg_writer.commit_append over Parquet files the caller stages) is
# separate; this Avro form is the test-substrate data file.


def _data_file_schema_json(schema: IcebergSchema) raises -> String:
    """The Avro record schema for a data file: one required field per
    schema column, in order, stamped with the field-id + primitive type name."""
    var out = String('{"type":"record","name":"data","fields":[')
    for i in range(len(schema.fields)):
        if i > 0:
            out += ","
        ref f = schema.fields[i]
        var tn = iceberg_type_name(f.type_tag)
        out += '{"name":' + json_escape_string(f.name) + ',"type":"' + tn + '"'
        out += ',"field-id":' + String(f.field_id) + "}"
    out += "]}"
    return out^


def col_types_of(schema: IcebergSchema) -> List[Int]:
    """The schema's column type tags in column order (the row decoder needs
    them to decode each cell)."""
    var out = List[Int]()
    for i in range(len(schema.fields)):
        out.append(schema.fields[i].type_tag)
    return out^


def build_data_file(
    schema: IcebergSchema, rows: List[List[RowCell]]
) raises -> List[UInt8]:
    """Serialize a DATA file (Avro OCF) of full typed `rows` (each a
    tuple of cells matching `schema` in column order)."""
    var sync = generate_sync_marker()
    var out = List[UInt8]()

    var kv_keys = List[String]()
    var kv_vals = List[String]()
    kv_keys.append(String("format-version"))
    kv_vals.append(String("2"))
    kv_keys.append(String("content"))
    kv_vals.append(String("data"))

    var sj = _data_file_schema_json(schema)
    emit_ocf_header_kv(sj, AVRO_CODEC_NULL, sync, kv_keys, kv_vals, out)

    var payload = List[UInt8]()
    var count = 0
    var ncols = len(schema.fields)
    for i in range(len(rows)):
        if len(rows[i]) != ncols:
            raise Error("build_data_file: row arity != schema column count")
        encode_row(rows[i], payload)
        count += 1
    if count > 0:
        emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)
    return out^


def read_data_file(
    bytes: List[UInt8], col_types: List[Int]
) raises -> List[List[RowCell]]:
    """Decode a data file (Avro OCF) into its typed rows.

    `col_types` is the schema's column types in order (from `col_types_of`)."""
    if len(col_types) == 0:
        raise Error("read_data_file: no columns")
    var out = List[List[RowCell]]()
    var blocks = scan_ocf_blocks(Span(bytes))
    for bi in range(len(blocks)):
        ref blk = blocks[bi]
        var start = blk.payload_offset
        var end = start + blk.payload_len
        var reader = AvroByteReader(Span(bytes)[start:end])
        var nrec = Int(blk.object_count)
        # Every record takes at least one byte per column, so a count above
        # the payload length is a lie: refuse it before looping on it.
        if nrec > blk.payload_len:
            raise Error(
                "read_data_file: block claims "
                + String(nrec)
                + " records in "
                + String(blk.payload_len)
                + " payload bytes"
            )
        for _r in range(nrec):
            out.append(decode_row(reader, col_types))
        if not reader.at_end():
            raise Error("read_data_file: trailing bytes after the last record")
    return out^
