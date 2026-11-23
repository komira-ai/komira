# =============================================================================
# avro_manifests.mojo -- manifest files and manifest lists, as Iceberg Java
# writes them for a version-2 table.
# =============================================================================
#
# Both are Avro object container files, deflate-compressed, whose record
# schemas are Java's: field ids as `field-id` attributes, every optional field
# a `["null", T]` union, a field-id-keyed map an array of `{key, value}`
# records, and the header carrying the Iceberg keys (`schema`,
# `partition-spec`, `format-version`, `content`; `snapshot-id`, ...).
#
# A manifest entry records what Java records. An ADDED entry leaves its
# sequence numbers null (they are inherited from the manifest list's entry for
# the manifest); an EXISTING or DELETED entry states them. Every partition
# field is a nullable union. A manifest list entry summarises each partition
# field of its manifest (null flag, bounds).
# =============================================================================

from avro.ocf_block_emit import emit_ocf_block, emit_ocf_header_kv
from avro.ocf_header import AVRO_CODEC_DEFLATE, OCF_SYNC_LEN
from avro.varint_encode import (
    encode_boolean,
    encode_bytes,
    encode_int,
    encode_long,
    encode_string,
    encode_union_tag,
)

from .metrics import column_metrics
from .table_metadata import compact_schema_json, partition_fields_json
from .table_model import (
    CONTENT_DATA,
    PARTITION_FIELD_ID_START,
    STATUS_ADDED,
    STATUS_DELETED,
    STATUS_EXISTING,
    TT_DATE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    ManifestEntryRecord,
    ManifestRecord,
    TableCell,
    TableColumn,
    TableFileRecord,
    TableRow,
)


def _write_avro_type(mut out: String, type_tag: Int) raises:
    # Appends; see _write_type_name in table_model.mojo.
    if type_tag == TT_LONG:
        out += '"long"'
    elif type_tag == TT_INT:
        out += '"int"'
    elif type_tag == TT_STRING:
        out += '"string"'
    elif type_tag == TT_DATE:
        out += '{"type":"int","logicalType":"date"}'
    else:
        raise Error(
            "komira_iceberg_test_tables: a partition column is a long, an int, "
            "a date or a string, not type " + String(type_tag)
        )


def _map_type(record_name: String, value_type: String, key_id: Int, value_id: Int) -> String:
    """An int-keyed map: an array of `{key, value}` records (Java's form)."""
    var out = String('{"type":"array","items":{"type":"record","name":"')
    out += record_name + '","fields":['
    out += '{"name":"key","type":"int","field-id":' + String(key_id) + "},"
    out += '{"name":"value","type":"' + value_type + '","field-id":' + String(value_id) + "}"
    out += ']},"logicalType":"map"}'
    return out^


def manifest_entry_schema_json(partition_columns: List[TableColumn]) raises -> String:
    """The `manifest_entry` record schema of a version-2 manifest whose
    partition spec is the identity of `partition_columns`."""
    var partition = String('{"type":"record","name":"r102","fields":[')
    for i in range(len(partition_columns)):
        ref col = partition_columns[i]
        if i > 0:
            partition += ","
        partition += '{"name":"' + col.name + '","type":["null",'
        _write_avro_type(partition, col.type_tag)
        partition += '],"default":null,"field-id":' + String(PARTITION_FIELD_ID_START + i) + "}"
    partition += "]}"
    var out = String('{"type":"record","name":"manifest_entry","fields":[')
    out += '{"name":"status","type":"int","field-id":0},'
    out += '{"name":"snapshot_id","type":["null","long"],"default":null,"field-id":1},'
    out += '{"name":"sequence_number","type":["null","long"],"default":null,"field-id":3},'
    out += '{"name":"file_sequence_number","type":["null","long"],"default":null,"field-id":4},'
    out += '{"name":"data_file","type":{"type":"record","name":"r2","fields":['
    out += '{"name":"content","type":"int","field-id":134},'
    out += '{"name":"file_path","type":"string","field-id":100},'
    out += '{"name":"file_format","type":"string","field-id":101},'
    out += '{"name":"partition","type":' + partition + ',"field-id":102},'
    out += '{"name":"record_count","type":"long","field-id":103},'
    out += '{"name":"file_size_in_bytes","type":"long","field-id":104},'
    out += '{"name":"column_sizes","type":["null",' + _map_type("k117_v118", "long", 117, 118) + '],"default":null,"field-id":108},'
    out += '{"name":"value_counts","type":["null",' + _map_type("k119_v120", "long", 119, 120) + '],"default":null,"field-id":109},'
    out += '{"name":"null_value_counts","type":["null",' + _map_type("k121_v122", "long", 121, 122) + '],"default":null,"field-id":110},'
    out += '{"name":"nan_value_counts","type":["null",' + _map_type("k138_v139", "long", 138, 139) + '],"default":null,"field-id":137},'
    out += '{"name":"lower_bounds","type":["null",' + _map_type("k126_v127", "bytes", 126, 127) + '],"default":null,"field-id":125},'
    out += '{"name":"upper_bounds","type":["null",' + _map_type("k129_v130", "bytes", 129, 130) + '],"default":null,"field-id":128},'
    out += '{"name":"key_metadata","type":["null","bytes"],"default":null,"field-id":131},'
    out += '{"name":"split_offsets","type":["null",{"type":"array","items":"long","element-id":133}],"default":null,"field-id":132},'
    out += '{"name":"equality_ids","type":["null",{"type":"array","items":"int","element-id":136}],"default":null,"field-id":135},'
    out += '{"name":"sort_order_id","type":["null","int"],"default":null,"field-id":140},'
    out += '{"name":"referenced_data_file","type":["null","string"],"default":null,"field-id":143}'
    out += ']},"field-id":2}'
    out += "]}"
    return out^


def manifest_list_schema_json() -> String:
    """The `manifest_file` record schema of a version-2 manifest list."""
    var out = String('{"type":"record","name":"manifest_file","fields":[')
    out += '{"name":"manifest_path","type":"string","field-id":500},'
    out += '{"name":"manifest_length","type":"long","field-id":501},'
    out += '{"name":"partition_spec_id","type":"int","field-id":502},'
    out += '{"name":"content","type":"int","field-id":517},'
    out += '{"name":"sequence_number","type":"long","field-id":515},'
    out += '{"name":"min_sequence_number","type":"long","field-id":516},'
    out += '{"name":"added_snapshot_id","type":"long","field-id":503},'
    out += '{"name":"added_files_count","type":"int","field-id":504},'
    out += '{"name":"existing_files_count","type":"int","field-id":505},'
    out += '{"name":"deleted_files_count","type":"int","field-id":506},'
    out += '{"name":"added_rows_count","type":"long","field-id":512},'
    out += '{"name":"existing_rows_count","type":"long","field-id":513},'
    out += '{"name":"deleted_rows_count","type":"long","field-id":514},'
    out += '{"name":"partitions","type":["null",{"type":"array","items":{"type":"record","name":"r508","fields":['
    out += '{"name":"contains_null","type":"boolean","field-id":509},'
    out += '{"name":"contains_nan","type":["null","boolean"],"default":null,"field-id":518},'
    out += '{"name":"lower_bound","type":["null","bytes"],"default":null,"field-id":510},'
    out += '{"name":"upper_bound","type":["null","bytes"],"default":null,"field-id":511}'
    out += ']},"element-id":508}],"default":null,"field-id":507},'
    out += '{"name":"key_metadata","type":["null","bytes"],"default":null,"field-id":519}'
    out += "]}"
    return out^


# ---- records ---------------------------------------------------------------


def _encode_long_map(keys: List[Int], values: List[Int64], mut out: List[UInt8]):
    """An optional field-id -> long map: null when empty."""
    if len(keys) == 0:
        encode_union_tag(0, out)
        return
    encode_union_tag(1, out)
    encode_long(Int64(len(keys)), out)
    for i in range(len(keys)):
        encode_int(Int32(keys[i]), out)
        encode_long(values[i], out)
    encode_long(Int64(0), out)


def _encode_bytes_map(keys: List[Int], values: List[List[UInt8]], mut out: List[UInt8]):
    """An optional field-id -> bytes map: null when empty."""
    if len(keys) == 0:
        encode_union_tag(0, out)
        return
    encode_union_tag(1, out)
    encode_long(Int64(len(keys)), out)
    for i in range(len(keys)):
        encode_int(Int32(keys[i]), out)
        encode_bytes(Span(values[i]), out)
    encode_long(Int64(0), out)


def _encode_partition_value(column: TableColumn, cell: TableCell, mut out: List[UInt8]):
    """One partition field: a nullable union of the column's value."""
    if cell.is_null:
        encode_union_tag(0, out)
        return
    encode_union_tag(1, out)
    if column.type_tag == TT_STRING:
        encode_string(cell.s, out)
    elif column.type_tag == TT_LONG:
        encode_long(cell.i, out)
    else:
        encode_int(Int32(cell.i), out)


def _encode_entry(
    entry: ManifestEntryRecord,
    file: TableFileRecord,
    partition_columns: List[TableColumn],
    mut out: List[UInt8],
):
    encode_int(Int32(entry.status), out)
    encode_union_tag(1, out)
    encode_long(entry.snapshot_id, out)
    if entry.status == STATUS_ADDED:
        # Inherited from the manifest list.
        encode_union_tag(0, out)
        encode_union_tag(0, out)
    else:
        encode_union_tag(1, out)
        encode_long(entry.data_seq, out)
        encode_union_tag(1, out)
        encode_long(entry.data_seq, out)
    # data_file
    encode_int(Int32(file.content), out)
    encode_string(file.uri, out)
    encode_string(file.file_format, out)
    for i in range(len(partition_columns)):
        _encode_partition_value(partition_columns[i], file.partition[i], out)
    encode_long(file.record_count, out)
    encode_long(file.size_bytes, out)
    encode_union_tag(0, out)  # column_sizes
    var ids = List[Int]()
    var counts = List[Int64]()
    var nulls = List[Int64]()
    var nan_ids = List[Int]()
    var nans = List[Int64]()
    var lower_ids = List[Int]()
    var lowers = List[List[UInt8]]()
    var uppers = List[List[UInt8]]()
    for m in range(len(file.metrics)):
        ref cm = file.metrics[m]
        ids.append(cm.field_id)
        counts.append(cm.value_count)
        nulls.append(cm.null_count)
        if cm.nan_count >= 0:
            nan_ids.append(cm.field_id)
            nans.append(cm.nan_count)
        if cm.has_bounds:
            lower_ids.append(cm.field_id)
            lowers.append(cm.lower.copy())
            uppers.append(cm.upper.copy())
    _encode_long_map(ids, counts, out)
    _encode_long_map(ids, nulls, out)
    _encode_long_map(nan_ids, nans, out)
    _encode_bytes_map(lower_ids, lowers, out)
    _encode_bytes_map(lower_ids, uppers, out)
    encode_union_tag(0, out)  # key_metadata
    if file.content == CONTENT_DATA:
        encode_union_tag(1, out)  # split_offsets: [4]
        encode_long(Int64(1), out)
        encode_long(Int64(4), out)
        encode_long(Int64(0), out)
    else:
        encode_union_tag(0, out)
    if len(file.equality_ids) > 0:
        encode_union_tag(1, out)
        encode_long(Int64(len(file.equality_ids)), out)
        for i in range(len(file.equality_ids)):
            encode_int(Int32(file.equality_ids[i]), out)
        encode_long(Int64(0), out)
    else:
        encode_union_tag(0, out)
    encode_union_tag(0, out)  # sort_order_id
    if len(file.referenced_data_file) > 0:
        encode_union_tag(1, out)
        encode_string(file.referenced_data_file, out)
    else:
        encode_union_tag(0, out)


def _sync_marker() -> Array[UInt8, OCF_SYNC_LEN]:
    return Array[UInt8, OCF_SYNC_LEN](fill=UInt8(0x5A))


def manifest_file_bytes(
    manifest: ManifestRecord,
    files: List[TableFileRecord],
    columns: List[TableColumn],
    partition_columns: List[TableColumn],
) raises -> List[UInt8]:
    """The bytes of `manifest`: its entries, one block, under the header
    Iceberg Java writes."""
    var keys = List[String]()
    var values = List[String]()
    keys.append("schema")
    values.append(compact_schema_json(columns, 0))
    keys.append("schema-id")
    values.append("0")
    keys.append("partition-spec")
    values.append(partition_fields_json(partition_columns))
    keys.append("partition-spec-id")
    values.append("0")
    keys.append("format-version")
    values.append("2")
    keys.append("content")
    if manifest.content == CONTENT_DATA:
        values.append("data")
    else:
        values.append("deletes")
    var sync = _sync_marker()
    var out = List[UInt8]()
    emit_ocf_header_kv(
        manifest_entry_schema_json(partition_columns),
        AVRO_CODEC_DEFLATE,
        sync,
        keys,
        values,
        out,
    )
    var payload = List[UInt8]()
    for e in range(len(manifest.entries)):
        ref entry = manifest.entries[e]
        _encode_entry(entry, files[entry.file_index], partition_columns, payload)
    emit_ocf_block(Span(payload), len(manifest.entries), AVRO_CODEC_DEFLATE, sync, out)
    return out^


def _count_of(manifest: ManifestRecord, status: Int) -> Int:
    var n = 0
    for e in range(len(manifest.entries)):
        if manifest.entries[e].status == status:
            n += 1
    return n


def _rows_of(manifest: ManifestRecord, files: List[TableFileRecord], status: Int) -> Int64:
    var n = Int64(0)
    for e in range(len(manifest.entries)):
        if manifest.entries[e].status == status:
            n += files[manifest.entries[e].file_index].record_count
    return n


def _encode_manifest_entry_summary(
    manifest: ManifestRecord,
    files: List[TableFileRecord],
    partition_columns: List[TableColumn],
    mut out: List[UInt8],
):
    """The `partitions` field: one summary per partition field."""
    encode_union_tag(1, out)
    if len(partition_columns) > 0:
        encode_long(Int64(len(partition_columns)), out)
    for p in range(len(partition_columns)):
        var tuples = List[TableRow]()
        for e in range(len(manifest.entries)):
            var cells = List[TableCell]()
            cells.append(files[manifest.entries[e].file_index].partition[p].copy())
            tuples.append(TableRow(cells^))
        var summary = column_metrics(partition_columns[p], tuples, 0)
        encode_boolean(summary.null_count > 0, out)
        encode_union_tag(0, out)  # contains_nan: unknown
        if summary.has_bounds:
            encode_union_tag(1, out)
            encode_bytes(Span(summary.lower), out)
            encode_union_tag(1, out)
            encode_bytes(Span(summary.upper), out)
        else:
            encode_union_tag(0, out)
            encode_union_tag(0, out)
    encode_long(Int64(0), out)


def manifest_list_bytes(
    manifests: List[ManifestRecord],
    files: List[TableFileRecord],
    partition_columns: List[TableColumn],
    snapshot_id: Int64,
    parent_snapshot_id: Int64,
    sequence_number: Int64,
) raises -> List[UInt8]:
    """The bytes of a snapshot's manifest list: one record per manifest, in
    the order given. `parent_snapshot_id` is -1 for none (Java writes the
    text `null` then)."""
    var keys = List[String]()
    var values = List[String]()
    keys.append("snapshot-id")
    values.append(String(snapshot_id))
    keys.append("parent-snapshot-id")
    if parent_snapshot_id >= 0:
        values.append(String(parent_snapshot_id))
    else:
        values.append("null")
    keys.append("sequence-number")
    values.append(String(sequence_number))
    keys.append("format-version")
    values.append("2")
    var sync = _sync_marker()
    var out = List[UInt8]()
    emit_ocf_header_kv(
        manifest_list_schema_json(), AVRO_CODEC_DEFLATE, sync, keys, values, out
    )
    var payload = List[UInt8]()
    for k in range(len(manifests)):
        ref m = manifests[k]
        encode_string(m.uri, payload)
        encode_long(m.length, payload)
        encode_int(Int32(0), payload)  # partition_spec_id
        encode_int(Int32(m.content), payload)
        encode_long(m.sequence_number, payload)
        encode_long(m.min_sequence_number, payload)
        encode_long(m.added_snapshot_id, payload)
        encode_int(Int32(_count_of(m, STATUS_ADDED)), payload)
        encode_int(Int32(_count_of(m, STATUS_EXISTING)), payload)
        encode_int(Int32(_count_of(m, STATUS_DELETED)), payload)
        encode_long(_rows_of(m, files, STATUS_ADDED), payload)
        encode_long(_rows_of(m, files, STATUS_EXISTING), payload)
        encode_long(_rows_of(m, files, STATUS_DELETED), payload)
        _encode_manifest_entry_summary(m, files, partition_columns, payload)
        encode_union_tag(0, payload)  # key_metadata
    emit_ocf_block(Span(payload), len(manifests), AVRO_CODEC_DEFLATE, sync, out)
    return out^
