# =============================================================================
# test_iceberg_manifest_spec.mojo — manifests against the Iceberg v2 spec.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. The manifest-entry and manifest-list Avro schemas carry every field with
#      the spec's name AND field id (readers bind by id), and are valid Avro
#      that komira_avro's parser accepts.
#   2. A manifest file's header holds the keys the spec requires, with
#      `partition-spec` as the bare FIELDS array (Iceberg's own readers parse it
#      as an array, not as the metadata.json object) and `content` data/deletes.
#   3. Manifest entries round-trip: content, sequence number (own or inherited),
#      counts, equality ids and the partition tuple, for an unpartitioned and
#      a bucket+identity partitioned table.
#   4. A manifest list round-trips, and a manifest carried forward from an
#      earlier snapshot keeps the snapshot id and spec id it was written with
#      (a rewritten added_snapshot_id mis-attributes files to the new commit).
#   5. Truncated or mistyped input is refused, not misread.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_avro.avro_schema import AvroSchema
from komira_avro.ocf_header import decode_ocf_header
from komira_avro.varint_encode import encode_string

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_T_INT,
    ICE_DATA_CONTENT_DATA,
    ICE_DATA_CONTENT_POSITION_DELETES,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    ICE_SEQ_INHERIT,
    ICE_STATUS_ADDED,
    ICE_MANIFEST_CONTENT_DATA,
    ICE_MANIFEST_CONTENT_DELETES,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    PartitionSpec,
    ManifestFileEntry,
    RowCell,
    make_long_cell,
    make_string_cell,
    schema_json,
    partition_spec_fields_json,
    partition_value_of,
    partition_value_type_tags,
    encode_partition_values,
    decode_partition_cell,
    manifest_entry_schema_json,
    manifest_file_schema_json,
    build_manifest_file,
    avro_field_name,
    build_manifest_list,
    read_manifest_list,
    read_manifest_entries,
)


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    var n = len(needle)
    if n == 0:
        return True
    for i in range(len(hay) - n + 1):
        var ok = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _kv(key: String, value: String) -> List[UInt8]:
    """The Avro-binary encoding of one header metadata pair."""
    var out = List[UInt8]()
    encode_string(key, out)
    encode_string(value, out)
    return out^



def test_manifest_entry_schema_has_spec_names_and_ids() raises:
    var js = manifest_entry_schema_json()
    # (name, field-id) from the v2 spec: manifest_entry, then data_file (r2).
    var _pair_list: List[String] = [
        '{"name":"status","type":"int","field-id":0}',
        '"name":"snapshot_id","type":["null","long"],"default":null,"field-id":1}',
        '"name":"sequence_number","type":["null","long"],"default":null,"field-id":3}',
        '"name":"file_sequence_number","type":["null","long"],"default":null,"field-id":4}',
        '"name":"data_file","type":{"type":"record","name":"r2"',
        '"name":"content","type":"int","field-id":134}',
        '"name":"file_path","type":"string","field-id":100}',
        '"name":"file_format","type":"string","field-id":101}',
        '"name":"partition","type":{"type":"record","name":"r102","fields":[]},"field-id":102}',
        '"name":"record_count","type":"long","field-id":103}',
        '"name":"file_size_in_bytes","type":"long","field-id":104}',
        '"name":"column_sizes","type":["null",{"type":"array","logicalType":"map","items":{"type":"record","name":"k117_v118"',
        '"name":"value_counts","type":["null",{"type":"array","logicalType":"map","items":{"type":"record","name":"k119_v120"',
        '"name":"null_value_counts","type":["null",{"type":"array","logicalType":"map","items":{"type":"record","name":"k121_v122"',
        '"name":"nan_value_counts","type":["null",{"type":"array","logicalType":"map","items":{"type":"record","name":"k138_v139"',
        '"name":"lower_bounds","type":["null",{"type":"array","logicalType":"map","items":{"type":"record","name":"k126_v127"',
        '"name":"upper_bounds","type":["null",{"type":"array","logicalType":"map","items":{"type":"record","name":"k129_v130"',
        '"name":"key_metadata","type":["null","bytes"],"default":null,"field-id":131}',
        '"name":"split_offsets","type":["null",{"type":"array","items":"long","element-id":133}],"default":null,"field-id":132}',
        '"name":"equality_ids","type":["null",{"type":"array","items":"int","element-id":136}],"default":null,"field-id":135}',
        '"name":"sort_order_id","type":["null","int"],"default":null,"field-id":140}',    ]
    for pair in _pair_list:
        assert_true(_has(js, pair), "manifest_entry schema lacks " + pair)
    var _id_list: List[String] = [
        '"field-id":108', '"field-id":109', '"field-id":110', '"field-id":137',
        '"field-id":125', '"field-id":128',    ]
    for id in _id_list:
        assert_true(_has(js, id), "map field id missing: " + id)
    _ = AvroSchema.parse(js)


def test_manifest_list_schema_has_spec_names_and_ids() raises:
    var js = manifest_file_schema_json()
    var _pair_list: List[String] = [
        '"name":"manifest_path","type":"string","field-id":500}',
        '"name":"manifest_length","type":"long","field-id":501}',
        '"name":"partition_spec_id","type":"int","field-id":502}',
        '"name":"content","type":"int","field-id":517}',
        '"name":"sequence_number","type":"long","field-id":515}',
        '"name":"min_sequence_number","type":"long","field-id":516}',
        '"name":"added_snapshot_id","type":"long","field-id":503}',
        '"name":"added_files_count","type":"int","field-id":504}',
        '"name":"existing_files_count","type":"int","field-id":505}',
        '"name":"deleted_files_count","type":"int","field-id":506}',
        '"name":"added_rows_count","type":"long","field-id":512}',
        '"name":"existing_rows_count","type":"long","field-id":513}',
        '"name":"deleted_rows_count","type":"long","field-id":514}',
        '"field-id":507}',
        '"name":"contains_null","type":"boolean","field-id":509}',
        '"name":"contains_nan","type":["null","boolean"],"default":null,"field-id":518}',
        '"name":"lower_bound","type":["null","bytes"],"default":null,"field-id":510}',
        '"name":"upper_bound","type":["null","bytes"],"default":null,"field-id":511}',
        '"element-id":508',    ]
    for pair in _pair_list:
        assert_true(_has(js, pair), "manifest_file schema lacks " + pair)
    _ = AvroSchema.parse(js)


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("region"), ICE_T_STRING, required=True)
    return s^


def _data_file(path: String, rows: Int, size: Int) -> DataFileInfo:
    var bounds = List[ColumnBound]()
    var lo = List[UInt8]()
    lo.append(1)
    var hi = List[UInt8]()
    hi.append(9)
    bounds.append(
        ColumnBound(
            1, Optional[List[UInt8]](lo^), Optional[List[UInt8]](hi^), 0, rows
        )
    )
    bounds.append(ColumnBound(2, None, None, 3, rows))
    return DataFileInfo(path, size, rows, bounds^)


def test_manifest_header_keys_and_content_kind() raises:
    var schema = _schema()
    var files = List[DataFileInfo]()
    files.append(_data_file(String("d/a.parquet"), 10, 111))
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
    )
    var hdr = decode_ocf_header(Span(bytes))
    assert_equal(hdr.schema_json, manifest_entry_schema_json())
    assert_true(_contains(bytes, _kv(String("schema"), schema_json(schema))))
    assert_true(_contains(bytes, _kv(String("schema-id"), String("0"))))
    assert_true(_contains(bytes, _kv(String("partition-spec"), String("[]"))))
    assert_true(_contains(bytes, _kv(String("partition-spec-id"), String("0"))))
    assert_true(_contains(bytes, _kv(String("format-version"), String("2"))))
    assert_true(_contains(bytes, _kv(String("content"), String("data"))))

    var dbytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
        ICE_MANIFEST_CONTENT_DELETES,
    )
    assert_true(_contains(dbytes, _kv(String("content"), String("deletes"))))


def test_manifest_partition_spec_header_is_the_fields_array() raises:
    var schema = _schema()
    var spec = PartitionSpec(2)
    spec.add_bucket(1, 4, String("id_bucket"))
    spec.add_identity(2, String("region"))
    var files = List[DataFileInfo]()
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
        ICE_MANIFEST_CONTENT_DATA, spec,
    )
    var fields = partition_spec_fields_json(spec)
    assert_true(_has(fields, '"transform":"bucket[4]"'))
    assert_true(_contains(bytes, _kv(String("partition-spec"), fields)))
    assert_true(_contains(bytes, _kv(String("partition-spec-id"), String("2"))))
    # An empty manifest (no entries) is a valid header-only OCF.
    assert_equal(len(read_manifest_entries(bytes, partition_value_type_tags(spec, schema))), 0)
    # The embedded record schema types the partition struct.
    var hdr = decode_ocf_header(Span(bytes))
    assert_true(
        _has(
            hdr.schema_json,
            '"name":"r102","fields":[{"name":"id_bucket","type":"int","field-id":1000},'
            '{"name":"region","type":"string","field-id":1001}]',
        )
    )
    _ = AvroSchema.parse(hdr.schema_json)


def test_entries_round_trip_unpartitioned() raises:
    var schema = _schema()
    var files = List[DataFileInfo]()
    files.append(_data_file(String("d/a.parquet"), 10, 111))
    var eq_ids = List[Int]()
    eq_ids.append(1)
    eq_ids.append(2)
    files.append(
        DataFileInfo(
            String("d/del.avro"), 55, 2, List[ColumnBound](),
            ICE_DATA_CONTENT_EQUALITY_DELETES, eq_ids^, Int64(9),
        )
    )
    files.append(
        DataFileInfo(
            String("d/pos.avro"), 66, 4, List[ColumnBound](),
            ICE_DATA_CONTENT_POSITION_DELETES, List[Int](),
        )
    )
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
    )
    var got = read_manifest_entries(bytes)
    assert_equal(len(got), 3)
    assert_equal(got[0].file_path, String("d/a.parquet"))
    # Every entry is ADDED (1): a reader counts only ADDED and EXISTING entries
    # as live, so any other status would hide the file from every engine.
    for i in range(3):
        assert_equal(got[i].status, ICE_STATUS_ADDED)
        assert_equal(got[i].status, 1)
    assert_equal(got[0].content, ICE_DATA_CONTENT_DATA)
    assert_equal(got[0].sequence_number, Int64(3))  # inherited from the commit
    assert_equal(got[0].record_count, 10)
    assert_equal(got[0].file_size_in_bytes, 111)
    assert_equal(len(got[0].equality_ids), 0)
    assert_equal(got[1].file_path, String("d/del.avro"))
    assert_equal(got[1].content, ICE_DATA_CONTENT_EQUALITY_DELETES)
    assert_equal(got[1].sequence_number, Int64(9))  # its own
    assert_equal(len(got[1].equality_ids), 2)
    assert_equal(got[1].equality_ids[0], 1)
    assert_equal(got[1].equality_ids[1], 2)
    assert_equal(got[2].content, ICE_DATA_CONTENT_POSITION_DELETES)
    assert_equal(got[2].sequence_number, Int64(3))
    assert_equal(len(got[2].partition_avro), 0)
    var copy = got[1].copy()
    assert_equal(copy.file_path, String("d/del.avro"))
    assert_equal(len(copy.equality_ids), 2)


def test_entries_round_trip_partitioned() raises:
    var schema = _schema()
    var spec = PartitionSpec(0)
    spec.add_bucket(1, 4, String("id_bucket"))
    spec.add_identity(2, String("region"))
    var types = partition_value_type_tags(spec, schema)
    var row = List[RowCell]()
    row.append(make_long_cell(Int64(42)))
    row.append(make_string_cell(String("us-east")))
    var pv = partition_value_of(spec, schema, row)
    var files = List[DataFileInfo]()
    files.append(
        _data_file(String("d/p.parquet"), 3, 77).with_partition(
            encode_partition_values(pv), types.copy()
        )
    )
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
        ICE_MANIFEST_CONTENT_DATA, spec,
    )
    var got = read_manifest_entries(bytes, types)
    assert_equal(len(got), 1)
    assert_equal(len(got[0].partition_avro), 2)
    var bucket = decode_partition_cell(got[0].partition_avro[0], ICE_T_INT)
    var region = decode_partition_cell(got[0].partition_avro[1], ICE_T_STRING)
    assert_equal(Int(bucket.as_long()), Int(pv[0].as_long()))
    assert_equal(region.as_string(), String("us-east"))
    # Read with the wrong types: refused, never silently misread.
    var bad = List[Int]()
    bad.append(99)
    with assert_raises():
        _ = read_manifest_entries(bytes, bad)


def test_colliding_avro_field_names_are_refused() raises:
    # `a-b` sanitises to `a_x2Db`, which is also a legal literal name.
    assert_equal(avro_field_name(String("a-b")), String("a_x2Db"))
    assert_equal(avro_field_name(String("a_x2Db")), String("a_x2Db"))
    var spec = PartitionSpec(0)
    spec.add_identity(1, String("a-b"))
    spec.add_identity(2, String("a_x2Db"))
    var types = List[Int]()
    types.append(ICE_T_INT)
    types.append(ICE_T_INT)
    with assert_raises(contains="collide"):
        _ = manifest_entry_schema_json(spec, types)
    # Distinct sanitised names are accepted.
    var ok = PartitionSpec(0)
    ok.add_identity(1, String("a-b"))
    ok.add_identity(2, String("a_b"))
    _ = manifest_entry_schema_json(ok, types)


def test_manifest_list_round_trip_and_carry_forward() raises:
    var entries = List[ManifestFileEntry]()
    # Carried forward from snapshot 10, written under spec 3, delete manifest.
    entries.append(
        ManifestFileEntry(
            String("m/old-m0.avro"), 100, 2, Int64(8),
            ICE_MANIFEST_CONTENT_DELETES, Int64(4), Int64(10), 3,
        )
    )
    # Added by the snapshot being committed (20): inherits id and sequence.
    entries.append(ManifestFileEntry(String("m/new-m0.avro"), 200, 1, Int64(5)))
    var bytes = build_manifest_list(Int64(20), Int64(6), entries)
    assert_equal(decode_ocf_header(Span(bytes)).schema_json, manifest_file_schema_json())
    var got = read_manifest_list(bytes)
    assert_equal(len(got), 2)
    assert_equal(got[0].manifest_path, String("m/old-m0.avro"))
    assert_equal(got[0].manifest_length, 100)
    assert_equal(got[0].content, ICE_MANIFEST_CONTENT_DELETES)
    assert_equal(got[0].sequence_number, Int64(4))
    assert_equal(got[0].added_snapshot_id, Int64(10))  # kept, not rewritten to 20
    assert_equal(got[0].partition_spec_id, 3)
    assert_equal(got[0].added_files_count, 2)
    assert_equal(got[0].added_rows_count, Int64(8))
    assert_equal(got[1].manifest_path, String("m/new-m0.avro"))
    assert_equal(got[1].content, ICE_MANIFEST_CONTENT_DATA)
    assert_equal(got[1].sequence_number, Int64(6))  # inherited from the commit
    assert_equal(got[1].added_snapshot_id, Int64(20))  # this snapshot
    assert_equal(got[1].partition_spec_id, 0)
    # A second round trip is stable: the carried values survive re-emission.
    var again = read_manifest_list(build_manifest_list(Int64(30), Int64(7), got))
    assert_equal(again[0].added_snapshot_id, Int64(10))
    assert_equal(again[1].added_snapshot_id, Int64(20))
    assert_equal(again[1].sequence_number, Int64(6))
    var c = got[0].copy()
    assert_equal(c.added_snapshot_id, Int64(10))
    assert_equal(c.partition_spec_id, 3)


def test_empty_manifest_list_and_garbage() raises:
    var bytes = build_manifest_list(Int64(1), Int64(1), List[ManifestFileEntry]())
    assert_equal(len(read_manifest_list(bytes)), 0)
    var junk = List[UInt8]()
    for i in range(40):
        junk.append(UInt8(i))
    with assert_raises():
        _ = read_manifest_list(junk)
    with assert_raises():
        _ = read_manifest_entries(junk)
    assert_equal(ICE_SEQ_INHERIT, Int64(-1))


def _legal_avro_name(name: String) -> Bool:
    var bs = name.as_bytes()
    if len(bs) == 0:
        return False
    for i in range(len(bs)):
        var c = Int(bs[i])
        var letter = (c >= ord("a") and c <= ord("z")) or (c >= ord("A") and c <= ord("Z")) or c == ord("_")
        var digit = c >= ord("0") and c <= ord("9")
        if not (letter or (digit and i > 0)):
            return False
    return True


def _every_name_is_legal(js: String) raises -> Int:
    """Check every `"name":"..."` of an Avro schema; returns how many."""
    var n = 0
    var at = js.find('"name":"')
    while at >= 0:
        var start = at + 8
        var end = js.find('"', start)
        assert_true(_legal_avro_name(String(js[byte=start:end])), "illegal Avro name in " + js)
        n += 1
        at = js.find('"name":"', end)
    return n


def test_avro_field_names_follow_the_iceberg_rule() raises:
    assert_equal(avro_field_name(String("region")), String("region"))
    assert_equal(avro_field_name(String("_a1")), String("_a1"))
    assert_equal(avro_field_name(String("my-region")), String("my_x2Dregion"))
    assert_equal(avro_field_name(String("a.b")), String("a_x2Eb"))
    assert_equal(avro_field_name(String("1st")), String("_1st"))
    assert_equal(avro_field_name(String("地域")), String("_x5730_x57DF"))
    assert_equal(avro_field_name(String("é")), String("_xE9"))
    assert_equal(avro_field_name(String("😀")), String("_x1F600"))
    assert_equal(avro_field_name(String("")), String("_"))
    assert_equal(avro_field_name(String("a b")), String("a_x20b"))


def test_a_manifest_with_free_text_partition_names_is_valid_avro() raises:
    var schema = _schema()
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("地域"))
    spec.add_identity(2, String("my-region"))
    spec.add_identity(2, String("1st"))
    spec.add_identity(2, String("region"))
    var files = List[DataFileInfo]()
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
        ICE_MANIFEST_CONTENT_DATA, spec,
    )
    var js = decode_ocf_header(Span(bytes)).schema_json
    assert_true(_every_name_is_legal(js) > 20)
    _ = AvroSchema.parse(js)
    # The legal names are in the schema; the originals ride along where they
    # changed, and the partition-spec header keeps the real names.
    assert_true(_has(js, '"name":"_x5730_x57DF","type":"string","field-id":1000,"iceberg-field-name":"地域"'))
    assert_true(_has(js, '"name":"my_x2Dregion"'))
    assert_true(_has(js, '"name":"_1st"'))
    assert_true(_has(js, '"name":"region","type":"string","field-id":1003}'))
    assert_true(_contains(bytes, _kv(String("partition-spec"), partition_spec_fields_json(spec))))
    assert_true(_has(partition_spec_fields_json(spec), '"name":"地域"'))


def test_non_ascii_partition_values_and_paths_round_trip() raises:
    var schema = _schema()
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("地域"))
    var types = partition_value_type_tags(spec, schema)
    var row = List[RowCell]()
    row.append(make_long_cell(Int64(1)))
    row.append(make_string_cell(String("日本 😀")))
    var pv = partition_value_of(spec, schema, row)
    var files = List[DataFileInfo]()
    files.append(
        _data_file(String("data/é/日本.parquet"), 2, 9).with_partition(
            encode_partition_values(pv), types.copy()
        )
    )
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), Int64(3), files,
        ICE_MANIFEST_CONTENT_DATA, spec,
    )
    var got = read_manifest_entries(bytes, types)
    assert_equal(len(got), 1)
    assert_equal(got[0].file_path, String("data/é/日本.parquet"))
    assert_equal(
        decode_partition_cell(got[0].partition_avro[0], ICE_T_STRING).as_string(),
        String("日本 😀"),
    )
    var entries = List[ManifestFileEntry]()
    entries.append(ManifestFileEntry(String("m/é-m0.avro"), 10, 1, Int64(2)))
    var back = read_manifest_list(build_manifest_list(Int64(1), Int64(1), entries))
    assert_equal(back[0].manifest_path, String("m/é-m0.avro"))


def test_a_path_that_is_not_utf8_is_refused() raises:
    var entries = List[ManifestFileEntry]()
    entries.append(ManifestFileEntry(String("m/é-m0.avro"), 10, 1, Int64(2)))
    var bytes = build_manifest_list(Int64(1), Int64(1), entries)
    # é is C3 A9: make the continuation byte 0x28, which is not one.
    var at = -1
    for i in range(len(bytes)):
        if bytes[i] == UInt8(0xC3):
            at = i
            break
    assert_true(at >= 0)
    bytes[at + 1] = UInt8(0x28)
    with assert_raises():
        _ = read_manifest_list(bytes)
    var schema = _schema()
    var files = List[DataFileInfo]()
    files.append(_data_file(String("d/é.parquet"), 1, 5))
    var mbytes = build_manifest_file(schema, schema_json(schema), Int64(7), Int64(3), files)
    var m = -1
    for i in range(len(mbytes)):
        if mbytes[i] == UInt8(0xC3):
            m = i
            break
    assert_true(m >= 0)
    mbytes[m + 1] = UInt8(0x28)
    with assert_raises():
        _ = read_manifest_entries(mbytes)


def main() raises:
    test_manifest_entry_schema_has_spec_names_and_ids()
    test_manifest_list_schema_has_spec_names_and_ids()
    test_manifest_header_keys_and_content_kind()
    test_manifest_partition_spec_header_is_the_fields_array()
    test_entries_round_trip_unpartitioned()
    test_entries_round_trip_partitioned()
    test_manifest_list_round_trip_and_carry_forward()
    test_empty_manifest_list_and_garbage()
    test_avro_field_names_follow_the_iceberg_rule()
    test_colliding_avro_field_names_are_refused()
    test_a_manifest_with_free_text_partition_names_is_valid_avro()
    test_non_ascii_partition_values_and_paths_round_trip()
    test_a_path_that_is_not_utf8_is_refused()
    print("test_iceberg_manifest_spec: all passed")
