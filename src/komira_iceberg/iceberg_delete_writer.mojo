# =============================================================================
# iceberg_delete_writer.mojo — Iceberg v2 delete-file writer (equality + pos).
# =============================================================================
#
# Iceberg v2 merge-on-read masks rows with two delete-file kinds. This module
# serializes BOTH as Avro Object Container Files (OCF), REUSING the same
# komira_avro OCF framing (emit_ocf_header_kv + emit_ocf_block) the manifest
# layer uses — so the delete files are spec-shaped Avro like everything else the
# writer emits.
#
#   1. EQUALITY DELETES (content=2) — delete-by-key. The file's rows carry the
#      values of the EQUALITY COLUMNS (a subset of the table schema identified
#      by `equality_ids`). A reader masks any DATA row whose equality columns
#      EQUAL a delete row's — for data files with a STRICTLY LOWER sequence
#      number than the delete (the ordering rule that keeps a later re-insert of
#      the same key alive). Natural for a change stream: a delete or update
#      carries the primary key, not a file offset.
#
#   2. POSITION DELETES (content=1) — masks rows by (data-file-path, row
#      position). Each row is {file_path: string, pos: long}. Cheaper for the
#      reader but needs the row's file and offset, which a stream does not
#      carry, so it is the secondary path (engine-side DELETE/MERGE).
#
# The Avro schema for each delete file is FIXED (equality: the equality columns'
# types in order; position: {file_path, pos}) and stamped with the Iceberg
# spec field-ids so an external reader binds it (equality columns carry the
# table field-ids; position carries 2147483546 file_path / 2147483545 pos).
#
# The delete files are Avro, which the spec permits next to Parquet data files;
# an engine that reads only Parquet delete files will not apply them.
#
# Encapsulation: public functions take owned/borrowed typed values and return
# owned List[UInt8]. ZERO UnsafePointer in any signature; ZERO wildcard origins.
# =============================================================================

from komira_avro.ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header_kv,
    emit_ocf_block,
)
from komira_avro.ocf_header import AVRO_CODEC_NULL
from komira_avro.ocf_block_scan import scan_ocf_blocks
from komira_avro.varint_decode_scalar import AvroByteReader
from komira_avro.varint_encode import encode_long, encode_string

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    iceberg_type_name,
)
from .iceberg_row_value import (
    read_checked_string,
    RowCell,
    encode_row,
    decode_row,
    reconcile_cell_type,
)


# Iceberg spec field-ids reserved for the position-delete columns.
comptime ICE_POS_DELETE_FILE_PATH_ID: Int = 2147483546
comptime ICE_POS_DELETE_POS_ID: Int = 2147483545


# =============================================================================
# EQUALITY-delete file (Avro OCF).
# =============================================================================


def _equality_delete_schema_json(
    equality_ids: List[Int], col_types: List[Int]
) raises -> String:
    """The Avro record schema for an equality-delete file: one field per
    equality column, in order, named by field-id, stamped with the spec
    field-id + the Iceberg primitive type name. All required (no null union)."""
    var out = String('{"type":"record","name":"equality_deletes","fields":[')
    for i in range(len(equality_ids)):
        if i > 0:
            out += ","
        var fid = equality_ids[i]
        var tn = iceberg_type_name(col_types[i])
        out += '{"name":"f' + String(fid) + '","type":"' + tn + '"'
        out += ',"field-id":' + String(fid) + "}"
    out += "]}"
    return out^


def build_equality_delete_file(
    equality_ids: List[Int],
    col_types: List[Int],
    rows: List[List[RowCell]],
) raises -> List[UInt8]:
    """Serialize an EQUALITY-delete file (Avro OCF) over `rows`.

    Each row is a tuple of cells matching `equality_ids` / `col_types` in order
    (one delete-by-key per row). The OCF carries the Iceberg-required
    key-value metadata (format-version, content=equality-deletes) so an external
    reader binds it; the record schema stamps the equality field-ids."""
    if len(equality_ids) != len(col_types):
        raise Error(
            "build_equality_delete_file: equality_ids / col_types length"
            " mismatch"
        )
    var sync = generate_sync_marker()
    var out = List[UInt8]()

    var kv_keys = List[String]()
    var kv_vals = List[String]()
    kv_keys.append(String("format-version"))
    kv_vals.append(String("2"))
    kv_keys.append(String("content"))
    kv_vals.append(String("equality-deletes"))

    var schema = _equality_delete_schema_json(equality_ids, col_types)
    emit_ocf_header_kv(schema, AVRO_CODEC_NULL, sync, kv_keys, kv_vals, out)

    var payload = List[UInt8]()
    var count = 0
    for i in range(len(rows)):
        if len(rows[i]) != len(col_types):
            raise Error(
                "build_equality_delete_file: row arity != equality key arity"
            )
        # Fail loud, no silent coerce: reconcile every delete-key cell's tag
        # against the declared equality-column type BEFORE encoding. Without
        # this, a STRING cell (an over-Int64 canonical-decimal promotion) for a
        # LONG key column would either encode as the WRONG Avro wire form
        # (`encode_cell` routes on the CELL's tag) or — matched with the reader's
        # LONG decode — silently mismatch, and two distinct large keys would
        # collide, so one key's equality-delete MASKS the other key's row. A
        # value unrepresentable in the declared key type is a real ingest error.
        for j in range(len(col_types)):
            reconcile_cell_type(
                rows[i][j],
                col_types[j],
                String("equality-key[") + String(equality_ids[j]) + "]",
            )
        encode_row(rows[i], payload)
        count += 1
    if count > 0:
        emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)
    return out^


def read_equality_delete_file(
    bytes: List[UInt8], col_types: List[Int]
) raises -> List[List[RowCell]]:
    """Decode an equality-delete file (Avro OCF) into its delete-key rows.

    `col_types` is the equality columns' types in order (the reader knows them
    from the manifest entry's `equality_ids` + the table schema). Returns one
    `List[RowCell]` per delete row."""
    if len(col_types) == 0:
        raise Error(
            "read_equality_delete_file: no equality columns (a delete row with"
            " no key would match every row)"
        )
    var out = List[List[RowCell]]()
    var blocks = scan_ocf_blocks(Span(bytes))
    for bi in range(len(blocks)):
        ref blk = blocks[bi]
        var start = blk.payload_offset
        var end = start + blk.payload_len
        var reader = AvroByteReader(Span(bytes)[start:end])
        var nrec = Int(blk.object_count)
        # Every row takes at least one byte per column: a larger count is a lie.
        if nrec > blk.payload_len:
            raise Error(
                "read_equality_delete_file: block claims "
                + String(nrec)
                + " rows in "
                + String(blk.payload_len)
                + " payload bytes"
            )
        for _r in range(nrec):
            out.append(decode_row(reader, col_types))
        if not reader.at_end():
            raise Error("read_equality_delete_file: trailing bytes")
    return out^


# =============================================================================
# POSITION-delete file (Avro OCF).
# =============================================================================


@fieldwise_init
struct PositionDeleteEntry(Copyable, Movable, Deinitable):
    """One position-delete row: mask (file_path, pos) in a data file.

    Fields:
      var file_path: String — the DATA file's object key the position refers to.
      var pos: Int64        — the 0-based row position within that data file.
    """

    var file_path: String
    var pos: Int64

    def copy(self) -> Self:
        return Self(String(self.file_path), self.pos)


def _position_delete_schema_json() -> String:
    """The fixed Avro record schema for a position-delete file:
    {file_path: string (2147483546), pos: long (2147483545)}."""
    var out = String('{"type":"record","name":"position_deletes","fields":[')
    out += (
        '{"name":"file_path","type":"string","field-id":'
        + String(ICE_POS_DELETE_FILE_PATH_ID)
        + "},"
        '{"name":"pos","type":"long","field-id":'
        + String(ICE_POS_DELETE_POS_ID)
        + "}"
    )
    out += "]}"
    return out^


def _entry_lt(a: PositionDeleteEntry, b: PositionDeleteEntry) -> Bool:
    """`a` sorts before `b`: file_path by unsigned bytes, then pos."""
    var ab = a.file_path.as_bytes()
    var bb = b.file_path.as_bytes()
    var m = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(m):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    if len(ab) != len(bb):
        return len(ab) < len(bb)
    return a.pos < b.pos


def _sorted_order(entries: List[PositionDeleteEntry]) -> List[Int]:
    """The indices of `entries` in (file_path, pos) order: a stable bottom-up
    merge sort (n log n; the entries are not copied)."""
    var n = len(entries)
    var cur = List[Int](capacity=n)
    for i in range(n):
        cur.append(i)
    var width = 1
    while width < n:
        var nxt = List[Int](capacity=n)
        var lo = 0
        while lo < n:
            var mid = lo + width if lo + width < n else n
            var hi = lo + 2 * width if lo + 2 * width < n else n
            var i = lo
            var j = mid
            while i < mid and j < hi:
                # Take from the right only when strictly smaller: stable.
                if _entry_lt(entries[cur[j]], entries[cur[i]]):
                    nxt.append(cur[j])
                    j += 1
                else:
                    nxt.append(cur[i])
                    i += 1
            while i < mid:
                nxt.append(cur[i])
                i += 1
            while j < hi:
                nxt.append(cur[j])
                j += 1
            lo += 2 * width
        cur = nxt^
        width *= 2
    return cur^


def build_position_delete_file(
    entries: List[PositionDeleteEntry],
) raises -> List[UInt8]:
    """Serialize a POSITION-delete file (Avro OCF) over `entries`.

    Each row is {file_path: string, pos: long}. The spec requires the rows
    sorted by file_path (unsigned bytes), then pos, so they are written in that
    order whatever order the caller supplies. A negative position is refused."""
    var sync = generate_sync_marker()
    var out = List[UInt8]()

    var kv_keys = List[String]()
    var kv_vals = List[String]()
    kv_keys.append(String("format-version"))
    kv_vals.append(String("2"))
    kv_keys.append(String("content"))
    kv_vals.append(String("position-deletes"))

    var schema = _position_delete_schema_json()
    emit_ocf_header_kv(schema, AVRO_CODEC_NULL, sync, kv_keys, kv_vals, out)

    for i in range(len(entries)):
        if entries[i].pos < Int64(0):
            raise Error(
                "build_position_delete_file: negative position "
                + String(entries[i].pos)
            )
    var order = _sorted_order(entries)
    var payload = List[UInt8]()
    var count = 0
    for k in range(len(order)):
        ref e = entries[order[k]]
        encode_string(e.file_path, payload)
        encode_long(e.pos, payload)
        count += 1
    if count > 0:
        emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)
    return out^


def read_position_delete_file(
    bytes: List[UInt8],
) raises -> List[PositionDeleteEntry]:
    """Decode a position-delete file (Avro OCF) into its (file_path, pos)
    entries."""
    var out = List[PositionDeleteEntry]()
    var blocks = scan_ocf_blocks(Span(bytes))
    for bi in range(len(blocks)):
        ref blk = blocks[bi]
        var start = blk.payload_offset
        var end = start + blk.payload_len
        var reader = AvroByteReader(Span(bytes)[start:end])
        var nrec = Int(blk.object_count)
        # A row is a string (at least its length byte) and a long: two bytes.
        if nrec > blk.payload_len // 2:
            raise Error(
                "read_position_delete_file: block claims "
                + String(nrec)
                + " rows in "
                + String(blk.payload_len)
                + " payload bytes"
            )
        for _r in range(nrec):
            var fp = read_checked_string(reader)
            var pos = reader.read_long()
            out.append(PositionDeleteEntry(fp^, pos))
        if not reader.at_end():
            raise Error("read_position_delete_file: trailing bytes")
    return out^
