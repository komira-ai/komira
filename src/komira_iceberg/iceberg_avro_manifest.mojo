# =============================================================================
# iceberg_avro_manifest.mojo — Iceberg v2 manifest file + manifest list (Avro).
# =============================================================================
#
# Iceberg's manifests are Avro Object Container Files (OCF). This module emits
# the two manifest layers a v2 table needs, BY HAND against the EXACT
# spec-defined Avro record schemas + field-ids — reusing the komira_avro
# binary primitives (varint_encode / ocf_block_emit) verbatim:
#
#   1. MANIFEST FILE (`<uuid>-m0.avro`): one record per DATA FILE. The record
#      is `manifest_entry` { status(0), snapshot_id(1), sequence_number(3),
#      file_sequence_number(4), data_file(2) }, where `data_file` is the
#      `r2` struct { content(134), file_path(100), file_format(101),
#      partition(102), record_count(103), file_size_in_bytes(104),
#      column_sizes(108), value_counts(109), null_value_counts(110),
#      nan_value_counts(137), lower_bounds(125), upper_bounds(128),
#      key_metadata(131), split_offsets(132), equality_ids(135),
#      sort_order_id(140) }.
#
#   2. MANIFEST LIST (`snap-<id>-…-<uuid>.avro`): one record per MANIFEST file.
#      The record is `manifest_file` { manifest_path(500), manifest_length(501),
#      partition_spec_id(502), content(517), sequence_number(515),
#      min_sequence_number(516), added_snapshot_id(503),
#      added_files_count(504), existing_files_count(505),
#      deleted_files_count(506), added_rows_count(512), existing_rows_count(513),
#      deleted_rows_count(514), partitions(507) }.
#
# WHY HAND-WRITE THE AVRO (not the komira_avro RecordBatch writer): the OCF
# RecordBatch writer derives its Avro schema from an Arrow schema and cannot
# (a) stamp the per-field `field-id` attributes Iceberg readers MATCH ON, nor
# (b) express the map<int,bytes> bound columns, nor (c) write the OCF
# key-value file metadata (schema / partition-spec / format-version / content)
# Iceberg requires in the manifest header. So we build the schema-JSON string +
# the record bytes directly, and frame them with `emit_ocf_header_kv` +
# `emit_ocf_block` (the SAME OCF framing the komira_avro writer uses, so the
# files are spec-correct OCF).
#
# v2 SCOPE: every data file is status=1 (ADDED); the manifest list's
# `partitions` summary is the null branch; one partition spec (id 0). The
# decoders read the manifests this module writes (positional, by the declared
# field order); they do not resolve an arbitrary writer's schema.
#
# Encapsulation: public functions take owned/borrowed typed values and return
# owned `List[UInt8]`. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; the OCF entropy FFI is confined inside komira_avro.
# =============================================================================

from komira_avro.ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header_kv,
    emit_ocf_block,
    AVRO_DEFAULT_BLOCK_SIZE_BYTES,
)
from komira_avro.ocf_header import OCF_SYNC_LEN, AVRO_CODEC_NULL
from komira_avro.ocf_block_scan import scan_ocf_blocks, OcfBlock
from komira_avro.varint_decode_scalar import AvroByteReader
from komira_avro.varint_encode import (
    encode_long,
    encode_int,
    encode_boolean,
    encode_float,
    encode_double,
    encode_string,
    encode_bytes,
    encode_union_tag,
)

from .iceberg_types import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
    DataFileInfo,
    json_escape_string,
    ColumnBound,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_POSITION_DELETES,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_SEQ_INHERIT,
)
from .iceberg_partition import PartitionSpec, partition_value_type_tags
from .iceberg_metadata_json import partition_spec_fields_json


# =============================================================================
# Manifest content / status / file-format constants (spec enums).
# =============================================================================
#
# data_file.content (field-id 134) / manifest_file.content (field-id 517):
#   0 == DATA, 1 == POSITION_DELETES, 2 == EQUALITY_DELETES.
# The three ICE_CONTENT_* names below are the public spelling re-exported by the
# package facade; they alias the single-source-of-truth enum in iceberg_types.
comptime ICE_CONTENT_DATA: Int = ICE_DATA_CONTENT_DATA
comptime ICE_CONTENT_POSITION_DELETES: Int = ICE_DATA_CONTENT_POSITION_DELETES
comptime ICE_CONTENT_EQUALITY_DELETES: Int = ICE_DATA_CONTENT_EQUALITY_DELETES

# manifest_file.content (the manifest-LIST level): 0 = a manifest of DATA files,
# 1 = a manifest of DELETE files. A v2 reader routes an entry by this value.
comptime ICE_MANIFEST_CONTENT_DATA: Int = 0
comptime ICE_MANIFEST_CONTENT_DELETES: Int = 1

comptime ICE_STATUS_EXISTING: Int = 0
comptime ICE_STATUS_ADDED: Int = 1
comptime ICE_STATUS_DELETED: Int = 2

comptime ICE_FILE_FORMAT_PARQUET: String = "PARQUET"
comptime ICE_FILE_FORMAT_AVRO: String = "AVRO"


# =============================================================================
# Manifest FILE Avro schema JSON (the manifest_entry record).
# =============================================================================
#
# The `data_file` struct is `r2`; its `partition` field (102) is an empty
# struct `r102` (unpartitioned). Optional Avro fields are `["null", T]`
# unions (NULL_FIRST: branch 0 == null, branch 1 == value). The bound columns
# (108/109/110/137/125/128) are `array of key_value` (Avro's map-as-array
# logical form Iceberg uses) — but we emit them as the spec's
# `["null", {type:"map", ...}]` Avro maps. We keep the schema MINIMAL but
# spec-faithful: required fields + the 5 stat maps + the optional scalars a
# reader expects. Field-ids are stamped via the Avro `field-id` attribute.


def _ice_map_type(
    record_name: String, value_type: String, key_id: Int, value_id: Int
) -> String:
    """An Iceberg int-keyed "map" Avro fragment: an ARRAY of {key:int, value:T}
    records annotated `"logicalType":"map"` (Avro maps are string-keyed, so
    Iceberg uses this array-of-key_value form for int field-id keys).

    `value_type` is the Avro value type name ("long" / "bytes"). `key_id` /
    `value_id` are the spec-assigned field-ids for the key + value fields."""
    var out = String('{"type":"array","logicalType":"map","items":')
    out += '{"type":"record","name":"' + record_name + '","fields":['
    out += '{"name":"key","type":"int","field-id":' + String(key_id) + "},"
    out += (
        '{"name":"value","type":"'
        + value_type
        + '","field-id":'
        + String(value_id)
        + "}"
    )
    out += "]}}"
    return out^


def _write_avro_type_name[W: Writer](mut writer: W, type_tag: Int) raises:
    """WRITE what `_avro_type_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    a shared-library link binds INDEPENDENTLY, and a pair bound CROSSED
    returns the wrong string."""
    if type_tag == ICE_T_BOOLEAN:
        writer.write(String("boolean"))
        return
    elif type_tag == ICE_T_INT:
        writer.write(String("int"))
        return
    elif type_tag == ICE_T_LONG:
        writer.write(String("long"))
        return
    elif type_tag == ICE_T_FLOAT:
        writer.write(String("float"))
        return
    elif type_tag == ICE_T_DOUBLE:
        writer.write(String("double"))
        return
    elif type_tag == ICE_T_STRING:
        writer.write(String("string"))
        return
    raise Error("_avro_type_name: unknown type tag " + String(type_tag))


def _avro_type_name(type_tag: Int) raises -> String:
    """The Avro primitive type name for an Iceberg partition-value type tag."""
    var out = String()
    _write_avro_type_name(out, type_tag)
    return out^


def _hex_upper(v: Int) -> String:
    var digits = String("0123456789ABCDEF")
    if v == 0:
        return String("0")
    var out = String("")
    var started = False
    var shift = 28
    while shift >= 0:
        var nib = (v >> shift) & 0xF
        if nib != 0 or started:
            started = True
            out += String(digits[byte=nib : nib + 1])
        shift -= 4
    return out^


def avro_field_name(name: String) -> String:
    """`name` as an Avro field name (`[A-Za-z_][A-Za-z0-9_]*`), by the rule
    Iceberg's own writers use: a character outside the grammar becomes `_x` and
    its code point in upper-case hex, and a leading digit gets a `_` in front.
    A legal name is returned unchanged. Partition field names are free text
    (`my-region`, a name in any script) and become Avro record field names in
    the manifest schema; an illegal one would make the manifest invalid Avro."""
    var bs = name.as_bytes()
    var n = len(bs)
    var out = String("")
    var i = 0
    while i < n:
        var b = Int(bs[i])
        var cp = b
        var width = 1
        if b >= 0xF0 and i + 3 < n:
            cp = ((b & 0x07) << 18) | ((Int(bs[i + 1]) & 0x3F) << 12) | ((Int(bs[i + 2]) & 0x3F) << 6) | (Int(bs[i + 3]) & 0x3F)
            width = 4
        elif b >= 0xE0 and i + 2 < n:
            cp = ((b & 0x0F) << 12) | ((Int(bs[i + 1]) & 0x3F) << 6) | (Int(bs[i + 2]) & 0x3F)
            width = 3
        elif b >= 0xC0 and i + 1 < n:
            cp = ((b & 0x1F) << 6) | (Int(bs[i + 1]) & 0x3F)
            width = 2
        var letter = (
            (cp >= ord("a") and cp <= ord("z"))
            or (cp >= ord("A") and cp <= ord("Z"))
            or cp == ord("_")
        )
        var digit = cp >= ord("0") and cp <= ord("9")
        if letter or (digit and i > 0):
            out += chr(cp)
        elif digit:
            out += "_" + chr(cp)
        else:
            out += "_x" + _hex_upper(cp)
        i += width
    if out.byte_length() == 0:
        return String("_")
    return out^


def manifest_entry_schema_json(
    spec: PartitionSpec = PartitionSpec(0),
    partition_value_types: List[Int] = List[Int](),
) raises -> String:
    """The Avro schema JSON for a v2 manifest file's `manifest_entry` record.

    Field-ids are the spec-assigned ids (load-bearing for cross-engine reads).
    `data_file.partition` is the `r102` struct: EMPTY for an unpartitioned spec
    (the unpartitioned form), else one field per partition field typed to its VALUE's
    Avro type (`partition_value_types`, from `partition_value_type_tags`)."""
    # data_file (r2) field list. The bound/count "maps" are NOT native Avro
    # maps (Avro maps are string-keyed; Iceberg's map keys are int field-ids).
    # Iceberg encodes them as an ARRAY of {key:int, value:T} records annotated
    # `"logicalType":"map"` (the array-of-key_value form). `_ice_map_type`
    # builds that schema fragment with the spec's key-id / value-id pairs.
    var partition_schema = String('{"type":"record","name":"r102","fields":[')
    for i in range(len(spec.fields)):
        ref pf = spec.fields[i]
        if i > 0:
            partition_schema += ","
        var vtag = (
            partition_value_types[i] if i < len(partition_value_types)
            else ICE_T_INT
        )
        var safe = avro_field_name(pf.name)
        partition_schema += '{"name":' + json_escape_string(safe)
        partition_schema += ',"type":"' + _avro_type_name(vtag)
        partition_schema += '","field-id":' + String(pf.field_id)
        if safe != pf.name:
            # Iceberg's own writers keep the original name beside the legal one.
            partition_schema += ',"iceberg-field-name":' + json_escape_string(pf.name)
        partition_schema += "}"
    partition_schema += "]}"

    var df = String('{"type":"record","name":"r2","fields":[')
    df += (
        '{"name":"content","type":"int","field-id":134},'
        '{"name":"file_path","type":"string","field-id":100},'
        '{"name":"file_format","type":"string","field-id":101},'
        '{"name":"partition","type":'
        + partition_schema
        + ',"field-id":102},'
        '{"name":"record_count","type":"long","field-id":103},'
        '{"name":"file_size_in_bytes","type":"long","field-id":104},'
        '{"name":"column_sizes","type":["null",'
        + _ice_map_type("k117_v118", "long", 117, 118)
        + '],"default":null,"field-id":108},'
        '{"name":"value_counts","type":["null",'
        + _ice_map_type("k119_v120", "long", 119, 120)
        + '],"default":null,"field-id":109},'
        '{"name":"null_value_counts","type":["null",'
        + _ice_map_type("k121_v122", "long", 121, 122)
        + '],"default":null,"field-id":110},'
        '{"name":"nan_value_counts","type":["null",'
        + _ice_map_type("k138_v139", "long", 138, 139)
        + '],"default":null,"field-id":137},'
        '{"name":"lower_bounds","type":["null",'
        + _ice_map_type("k126_v127", "bytes", 126, 127)
        + '],"default":null,"field-id":125},'
        '{"name":"upper_bounds","type":["null",'
        + _ice_map_type("k129_v130", "bytes", 129, 130)
        + '],"default":null,"field-id":128},'
        '{"name":"key_metadata","type":["null","bytes"],"default":null,'
        '"field-id":131},'
        '{"name":"split_offsets","type":["null",{"type":"array",'
        '"items":"long","element-id":133}],"default":null,"field-id":132},'
        '{"name":"equality_ids","type":["null",{"type":"array",'
        '"items":"int","element-id":136}],"default":null,"field-id":135},'
        '{"name":"sort_order_id","type":["null","int"],"default":null,'
        '"field-id":140}'
    )
    df += "]}"

    var entry = String('{"type":"record","name":"manifest_entry","fields":[')
    entry += (
        '{"name":"status","type":"int","field-id":0},'
        '{"name":"snapshot_id","type":["null","long"],"default":null,'
        '"field-id":1},'
        '{"name":"sequence_number","type":["null","long"],"default":null,'
        '"field-id":3},'
        '{"name":"file_sequence_number","type":["null","long"],"default":null,'
        '"field-id":4},'
    )
    entry += '{"name":"data_file","type":' + df + ',"field-id":2}'
    entry += "]}"
    return entry^


# =============================================================================
# Manifest LIST Avro schema JSON (the manifest_file record).
# =============================================================================


def manifest_file_schema_json() -> String:
    """The Avro schema JSON for a v2 manifest list's `manifest_file` record.

    All v2 row-count + file-count fields are required. `partitions` (507) is
    an optional array of `field_summary`; for an unpartitioned table we write
    the null branch (no partition summaries)."""
    var s = String('{"type":"record","name":"manifest_file","fields":[')
    s += (
        '{"name":"manifest_path","type":"string","field-id":500},'
        '{"name":"manifest_length","type":"long","field-id":501},'
        '{"name":"partition_spec_id","type":"int","field-id":502},'
        '{"name":"content","type":"int","field-id":517},'
        '{"name":"sequence_number","type":"long","field-id":515},'
        '{"name":"min_sequence_number","type":"long","field-id":516},'
        '{"name":"added_snapshot_id","type":"long","field-id":503},'
        '{"name":"added_files_count","type":"int","field-id":504},'
        '{"name":"existing_files_count","type":"int","field-id":505},'
        '{"name":"deleted_files_count","type":"int","field-id":506},'
        '{"name":"added_rows_count","type":"long","field-id":512},'
        '{"name":"existing_rows_count","type":"long","field-id":513},'
        '{"name":"deleted_rows_count","type":"long","field-id":514},'
        '{"name":"partitions","type":["null",{"type":"array","items":'
        '{"type":"record","name":"r508","fields":['
        '{"name":"contains_null","type":"boolean","field-id":509},'
        '{"name":"contains_nan","type":["null","boolean"],"default":null,'
        '"field-id":518},'
        '{"name":"lower_bound","type":["null","bytes"],"default":null,'
        '"field-id":510},'
        '{"name":"upper_bound","type":["null","bytes"],"default":null,'
        '"field-id":511}]},"element-id":508}],"default":null,"field-id":507}'
    )
    s += "]}"
    return s^


# =============================================================================
# data_file record body encode (one manifest_entry).
# =============================================================================
#
# Encodes one manifest_entry into the block payload, in DECLARED FIELD ORDER
# (Avro is positional — order MUST match the schema above exactly).


def _encode_bound_map(
    bounds: List[ColumnBound],
    want_lower: Bool,
    mut out: List[UInt8],
):
    """Encode lower_bounds / upper_bounds as an Avro `["null", array<record>]`
    (Iceberg's int-keyed map = array of {key:int, value:bytes} records).

    Only columns that HAVE a bound (Optional populated) contribute an entry; a
    column with no bound is omitted. The present branch writes the ARRAY wire
    form: a `long` block-count of items, then each item (an INT key field-id +
    a `bytes` value), then a terminating `0` block-count. An empty map writes
    the present branch with a single 0 block-count (a valid empty array)."""
    var keys = List[Int]()
    var vals = List[List[UInt8]]()
    for i in range(len(bounds)):
        ref b = bounds[i]
        if want_lower:
            if b.lower:
                keys.append(b.field_id)
                vals.append(b.lower.value().copy())
        else:
            if b.upper:
                keys.append(b.field_id)
                vals.append(b.upper.value().copy())
    if len(keys) == 0:
        # null branch (no bounds for this file).
        encode_union_tag(0, out)
        return
    # present branch (index 1 in ["null", array]).
    encode_union_tag(1, out)
    # Avro array: one block of `count` items, then a 0-count terminator. Each
    # item is the record {key:int, value:bytes} (positional, no length prefix
    # on the record itself).
    encode_long(Int64(len(keys)), out)
    for i in range(len(keys)):
        encode_int(Int32(keys[i]), out)  # key (int field-id)
        encode_bytes(Span(vals[i]), out)  # value (bytes)
    encode_long(Int64(0), out)


def _encode_count_map(
    bounds: List[ColumnBound],
    want_null_counts: Bool,
    mut out: List[UInt8],
):
    """Encode value_counts / null_value_counts as `["null", array<record>]`
    (Iceberg int-keyed map = array of {key:int, value:long} records).

    `want_null_counts=True` emits null_value_counts (per-column null cell
    count); False emits value_counts (per-column total cell count). A column
    whose count is unknown (<0) is omitted."""
    var keys = List[Int]()
    var vals = List[Int64]()
    for i in range(len(bounds)):
        ref b = bounds[i]
        var c = b.null_count if want_null_counts else b.value_count
        if c < 0:
            continue
        keys.append(b.field_id)
        vals.append(Int64(c))
    if len(keys) == 0:
        encode_union_tag(0, out)
        return
    encode_union_tag(1, out)
    encode_long(Int64(len(keys)), out)
    for i in range(len(keys)):
        encode_int(Int32(keys[i]), out)  # key (int field-id)
        encode_long(vals[i], out)  # value (long)
    encode_long(Int64(0), out)


def encode_manifest_entry(
    snapshot_id: Int64,
    sequence_number: Int64,
    data_file: DataFileInfo,
    mut out: List[UInt8],
):
    """Encode one `manifest_entry` record (status=ADDED) into `out`.

    Field order MUST match `manifest_entry_schema_json` exactly (Avro is
    positional).

    The entry's sequence number is the data_file's OWN `sequence_number` when it
    supplies one (any value != ICE_SEQ_INHERIT — delete files do); otherwise the
    commit-wide `sequence_number` argument (the append path). This is what lets
    the reader order deletes vs data-file generations from the manifest alone.

    The `content` + `equality_ids` come from `data_file` (0=data, no
    equality-ids for the append path; 1/2 + the equality field-ids for a delete
    file)."""
    var entry_seq = (
        data_file.sequence_number if data_file.sequence_number
        != ICE_SEQ_INHERIT else sequence_number
    )
    # file_format: data + position-delete files are PARQUET/AVRO; an
    # equality-delete file (this writer emits it as Avro) is AVRO. We tag data
    # (content 0) as PARQUET and BOTH delete kinds as AVRO (the delete writer's
    # serialization). A reader keys behavior on `content`, not `file_format`.
    var file_format = (
        String(ICE_FILE_FORMAT_PARQUET) if data_file.content
        == ICE_CONTENT_DATA else String(ICE_FILE_FORMAT_AVRO)
    )

    # status (required int): ADDED.
    encode_int(Int32(ICE_STATUS_ADDED), out)
    # snapshot_id (["null","long"]): present.
    encode_union_tag(1, out)
    encode_long(snapshot_id, out)
    # sequence_number (["null","long"]): present (the data sequence number).
    encode_union_tag(1, out)
    encode_long(entry_seq, out)
    # file_sequence_number (["null","long"]): present.
    encode_union_tag(1, out)
    encode_long(entry_seq, out)

    # ---- data_file (r2) ----
    # content (required int): 0 data / 1 position-delete / 2 equality-delete.
    encode_int(Int32(data_file.content), out)
    # file_path (required string).
    encode_string(data_file.file_path, out)
    # file_format (required string).
    encode_string(file_format, out)
    # partition (required r102 struct): the partition tuple's pre-encoded Avro
    # bytes concatenated positionally (one blob per partition field, in
    # partition-field order). Empty for an unpartitioned table -> zero bytes
    # (the empty `r102` form).
    for pv in range(len(data_file.partition_avro)):
        for bi in range(len(data_file.partition_avro[pv])):
            out.append(data_file.partition_avro[pv][bi])
    # record_count (required long).
    encode_long(Int64(data_file.record_count), out)
    # file_size_in_bytes (required long).
    encode_long(Int64(data_file.file_size_in_bytes), out)
    # column_sizes (["null", map<int,long>]): null (we don't track per-col
    # on-disk sizes here).
    encode_union_tag(0, out)
    # value_counts (["null", map<int,long>]).
    _encode_count_map(data_file.bounds, False, out)
    # null_value_counts (["null", map<int,long>]).
    _encode_count_map(data_file.bounds, True, out)
    # nan_value_counts (["null", map<int,long>]): null.
    encode_union_tag(0, out)
    # lower_bounds (["null", map<int,bytes>]).
    _encode_bound_map(data_file.bounds, True, out)
    # upper_bounds (["null", map<int,bytes>]).
    _encode_bound_map(data_file.bounds, False, out)
    # key_metadata (["null","bytes"]): null.
    encode_union_tag(0, out)
    # split_offsets (["null", array<long>]): null.
    encode_union_tag(0, out)
    # equality_ids (["null", array<int>]): present ONLY for equality-delete
    # files that carry match field-ids; null otherwise.
    if len(data_file.equality_ids) > 0:
        encode_union_tag(1, out)  # present branch
        encode_long(Int64(len(data_file.equality_ids)), out)  # array block count
        for i in range(len(data_file.equality_ids)):
            encode_int(Int32(data_file.equality_ids[i]), out)
        encode_long(Int64(0), out)  # array terminator block
    else:
        encode_union_tag(0, out)  # null
    # sort_order_id (["null","int"]): null.
    encode_union_tag(0, out)


# =============================================================================
# Build a manifest file (one OCF) listing the given data files.
# =============================================================================


def build_manifest_file(
    schema: IcebergSchema,
    schema_json: String,
    snapshot_id: Int64,
    sequence_number: Int64,
    data_files: List[DataFileInfo],
    manifest_content: Int = ICE_MANIFEST_CONTENT_DATA,
    spec: PartitionSpec = PartitionSpec(0),
) raises -> List[UInt8]:
    """Build a complete v2 manifest FILE (Avro OCF) listing `data_files`.

    The OCF carries the Iceberg-required key-value file metadata: `schema`,
    `schema-id`, `partition-spec` (the spec's FIELDS array, the form the table
    spec and Iceberg's own readers expect in a manifest header, not the
    `{spec-id, fields}` object of metadata.json), `partition-spec-id`,
    `format-version`, `content`. All files are status=ADDED. `manifest_content` is DATA (0) for
    a data manifest (the OCF `content` KV = "data") or DELETES (1) for a delete
    manifest (`content` KV = "deletes"); it defaults to DATA so the append path
    + the REST adapter call it unchanged. Each entry's own content (0/1/2) is
    carried on its `DataFileInfo`.

    `spec` (default unpartitioned) drives the `manifest_entry` schema's `r102`
    partition record + the `partition-spec-id` KV. Each data file's own
    `partition_avro` bytes are written into its entry — a partitioned data file
    records its partition tuple, an unpartitioned one records zero bytes (the
    unpartitioned form)."""
    var sync = generate_sync_marker()
    var out = List[UInt8]()

    # partition VALUE types (for the r102 schema): bucket -> int, identity ->
    # source type. Derived from spec + schema (empty for unpartitioned).
    var pv_types = partition_value_type_tags(spec, schema)

    # Iceberg-required manifest OCF key-value metadata (beyond avro.schema +
    # avro.codec). These are read by the Iceberg reader to bind the manifest.
    var kv_keys = List[String]()
    var kv_vals = List[String]()
    kv_keys.append(String("schema"))
    kv_vals.append(schema_json)
    kv_keys.append(String("schema-id"))
    kv_vals.append(String(schema.schema_id))
    kv_keys.append(String("partition-spec"))
    kv_vals.append(partition_spec_fields_json(spec))
    kv_keys.append(String("partition-spec-id"))
    kv_vals.append(String(spec.spec_id))
    kv_keys.append(String("format-version"))
    kv_vals.append(String("2"))
    kv_keys.append(String("content"))
    kv_vals.append(
        String("deletes") if manifest_content
        == ICE_MANIFEST_CONTENT_DELETES else String("data")
    )

    var entry_schema = manifest_entry_schema_json(spec, pv_types)
    emit_ocf_header_kv(entry_schema, AVRO_CODEC_NULL, sync, kv_keys, kv_vals, out)

    # Encode all manifest_entry records into one block payload.
    var payload = List[UInt8]()
    var count = 0
    for i in range(len(data_files)):
        encode_manifest_entry(
            snapshot_id, sequence_number, data_files[i], payload
        )
        count += 1
    if count > 0:
        emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)

    return out^


# =============================================================================
# Build the manifest LIST (one OCF) referencing the manifest file(s).
# =============================================================================


struct ManifestFileEntry(Copyable, Movable, Deinitable):
    """One entry in the manifest list — describes a manifest FILE.

    Fields:
      var manifest_path: String     — object key of the manifest file.
      var manifest_length: Int      — byte size of the manifest file.
      var added_files_count: Int    — # files added by this manifest.
      var added_rows_count: Int64   — # rows across those files.
      var content: Int              — ICE_MANIFEST_CONTENT_DATA (0) or
                                      ICE_MANIFEST_CONTENT_DELETES (1). Defaults
                                      to DATA so the append path + the REST
                                      adapter keep constructing with 4 args.
      var sequence_number: Int64    — the manifest's own sequence number, or
                                      ICE_SEQ_INHERIT (-1) to inherit the
                                      commit's. A DELETE manifest carries its
                                      own so the manifest-list `sequence_number`
                                      + `min_sequence_number` reflect the delete
                                      generation (merge-on-read ordering).
      var added_snapshot_id: Int64  — the snapshot that ADDED this manifest, or
                                      ICE_SEQ_INHERIT (-1) for the snapshot being
                                      committed. A manifest carried forward from
                                      a parent snapshot keeps the id it was added
                                      under.
      var partition_spec_id: Int    — the id of the spec the manifest was
                                      written with (0 by default).
    """

    var manifest_path: String
    var manifest_length: Int
    var added_files_count: Int
    var added_rows_count: Int64
    var content: Int
    var sequence_number: Int64
    var added_snapshot_id: Int64
    var partition_spec_id: Int

    def __init__(
        out self,
        var manifest_path: String,
        manifest_length: Int,
        added_files_count: Int,
        added_rows_count: Int64,
    ):
        """Legacy 4-arg (DATA-manifest) ctor — content defaults to data,
        sequence inherits the commit. Append path + REST adapter."""
        self.manifest_path = manifest_path^
        self.manifest_length = manifest_length
        self.added_files_count = added_files_count
        self.added_rows_count = added_rows_count
        self.content = ICE_MANIFEST_CONTENT_DATA
        self.sequence_number = ICE_SEQ_INHERIT
        self.added_snapshot_id = ICE_SEQ_INHERIT
        self.partition_spec_id = 0

    def __init__(
        out self,
        var manifest_path: String,
        manifest_length: Int,
        added_files_count: Int,
        added_rows_count: Int64,
        content: Int,
        sequence_number: Int64 = ICE_SEQ_INHERIT,
        added_snapshot_id: Int64 = ICE_SEQ_INHERIT,
        partition_spec_id: Int = 0,
    ):
        """Full ctor — carries the manifest `content` (data / deletes), an
        explicit per-manifest `sequence_number`, the snapshot that added the
        manifest and the partition spec id."""
        self.manifest_path = manifest_path^
        self.manifest_length = manifest_length
        self.added_files_count = added_files_count
        self.added_rows_count = added_rows_count
        self.content = content
        self.sequence_number = sequence_number
        self.added_snapshot_id = added_snapshot_id
        self.partition_spec_id = partition_spec_id

    def copy(self) -> Self:
        return Self(
            String(self.manifest_path),
            self.manifest_length,
            self.added_files_count,
            self.added_rows_count,
            self.content,
            self.sequence_number,
            self.added_snapshot_id,
            self.partition_spec_id,
        )


def encode_manifest_file_record(
    entry: ManifestFileEntry,
    snapshot_id: Int64,
    sequence_number: Int64,
    mut out: List[UInt8],
):
    """Encode one `manifest_file` record into `out` (field order = schema).

    The entry's own `sequence_number` (when set, != ICE_SEQ_INHERIT — delete
    manifests set it) overrides the commit-wide `sequence_number`; the entry's
    `content` (data / deletes) is written at the manifest-list level so a reader
    routes the manifest correctly."""
    var entry_seq = (
        entry.sequence_number if entry.sequence_number
        != ICE_SEQ_INHERIT else sequence_number
    )
    # manifest_path (required string).
    encode_string(entry.manifest_path, out)
    # manifest_length (required long).
    encode_long(Int64(entry.manifest_length), out)
    # partition_spec_id (required int).
    encode_int(Int32(entry.partition_spec_id), out)
    # content (required int): 0 == data manifest, 1 == delete manifest.
    encode_int(Int32(entry.content), out)
    # sequence_number (required long).
    encode_long(entry_seq, out)
    # min_sequence_number (required long).
    encode_long(entry_seq, out)
    # added_snapshot_id (required long): the snapshot that added the manifest
    # (a carried-forward manifest keeps its original).
    encode_long(
        entry.added_snapshot_id if entry.added_snapshot_id
        != ICE_SEQ_INHERIT else snapshot_id,
        out,
    )
    # added_files_count (required int).
    encode_int(Int32(entry.added_files_count), out)
    # existing_files_count (required int): 0.
    encode_int(Int32(0), out)
    # deleted_files_count (required int): 0.
    encode_int(Int32(0), out)
    # added_rows_count (required long).
    encode_long(entry.added_rows_count, out)
    # existing_rows_count (required long): 0.
    encode_long(Int64(0), out)
    # deleted_rows_count (required long): 0.
    encode_long(Int64(0), out)
    # partitions (["null", array<field_summary>]): null (unpartitioned).
    encode_union_tag(0, out)


def build_manifest_list(
    snapshot_id: Int64,
    sequence_number: Int64,
    manifests: List[ManifestFileEntry],
) raises -> List[UInt8]:
    """Build a complete v2 manifest LIST (Avro OCF) referencing `manifests`.

    `manifests` must enumerate ALL live manifests for this snapshot (the new
    commit's manifest PLUS every manifest carried forward from the parent
    snapshot) — an Iceberg snapshot's manifest list is the COMPLETE set of
    manifests visible at that snapshot, not just the delta. Each entry records
    its own `added_snapshot_id` so a reader attributes files correctly: an entry
    that sets none (ICE_SEQ_INHERIT) was added by THIS snapshot, a carried-forward
    one keeps the snapshot that added it."""
    var sync = generate_sync_marker()
    var out = List[UInt8]()

    var list_schema = manifest_file_schema_json()
    # The manifest list OCF carries only the standard avro.schema + avro.codec
    # metadata (no Iceberg-specific KV is required on the list itself).
    var kv_keys = List[String]()
    var kv_vals = List[String]()
    emit_ocf_header_kv(list_schema, AVRO_CODEC_NULL, sync, kv_keys, kv_vals, out)

    var payload = List[UInt8]()
    var count = 0
    for i in range(len(manifests)):
        encode_manifest_file_record(
            manifests[i], snapshot_id, sequence_number, payload
        )
        count += 1
    if count > 0:
        emit_ocf_block(Span(payload), count, AVRO_CODEC_NULL, sync, out)

    return out^
