# =============================================================================
# read_manifest_list and read_manifest: the Avro files of a snapshot
# =============================================================================
#
# What each test proves:
#   * test_a_v2_manifest_list_reads_with_summaries: the fields of two manifests
#     (a data manifest with a partition summary and a delete manifest with a
#     bare one) read by name, in file order, under the null and the deflate
#     codec; a manifest with no summaries has none.
#   * test_a_v1_manifest_list_has_no_content_or_sequence_numbers: the v1
#     layout reads with content and sequence numbers 0 whatever the format
#     version the caller says only for v1; read as v2 it is refused for the
#     sequence number it lacks.
#   * test_manifest_entries_read_by_name: status, the sequence number (an
#     entry's own, else the manifest's), the content, the path, the upper-cased
#     format, the record count, every partition value of the seven Avro types
#     re-serialized to single-value bytes (null as None), the three count maps,
#     the bounds, the equality ids and the referenced data file; a DELETED entry
#     is returned for the planner to drop.
#   * test_metric_maps_written_as_avro_maps_read_the_same: the six maps as Avro
#     maps with string keys read as the array form does, and a v1 manifest
#     without content or equality ids reads as data files that inherit sequence
#     number 0.
#   * test_a_manifest_under_deflate_reads: the codec of the header is honoured.
#   * test_map_keys_that_are_no_field_id_and_a_missing_partition_are_ignored: an
#     Avro map keyed "abc", "7" and "" keeps only field 7, and an entry whose
#     schema has no partition record has a null for every spec field.
#   * test_malformed_manifests_are_refused_by_message: an entry with no
#     data_file, no file_path, or a status outside 0..2, and a list entry with
#     no manifest_path, are ICEBERG_MANIFEST_INVALID with the reason.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from avro.ocf_block_emit import emit_ocf_block, emit_ocf_header_kv
from avro.ocf_header import AVRO_CODEC_DEFLATE, AVRO_CODEC_NULL, OCF_SYNC_LEN
from avro.varint_encode import encode_int, encode_long, encode_string
from iceberg_scan.manifests import (
    ENTRY_ADDED,
    ENTRY_DELETED,
    ENTRY_EXISTING,
    IcebergFileEntry,
    IcebergManifestFile,
    read_manifest,
    read_manifest_list,
)
from iceberg_scan.table_fixture import (
    FixtureEntry,
    FixtureManifest,
    FixtureSummary,
    FixtureValue,
    fixture_double_bytes,
    fixture_float_bytes,
    fixture_int_bytes,
    fixture_long_bytes,
    fixture_manifest,
    fixture_manifest_list,
    fixture_text_bytes,
)
from iceberg_scan.table_metadata import (
    IcebergField,
    IcebergPartitionField,
    IcebergPartitionSpecDef,
    IcebergSchemaDef,
)


def _spec(names: List[String]) -> IcebergPartitionSpecDef:
    var fields = List[IcebergPartitionField]()
    for k in range(len(names)):
        fields.append(IcebergPartitionField(k + 1, 1000 + k, names[k], "identity"))
    return IcebergPartitionSpecDef(0, fields^)


def _schema() -> IcebergSchemaDef:
    return IcebergSchemaDef(0, List[IcebergField]())


def _manifest_file(path: String, sequence_number: Int64) -> IcebergManifestFile:
    var m = IcebergManifestFile()
    m.path = path
    m.sequence_number = sequence_number
    return m^


def _list_of_two() -> List[FixtureManifest]:
    var ms = List[FixtureManifest]()
    var data = FixtureManifest("/w/t/metadata/m0.avro")
    data.sequence_number = 3
    data.min_sequence_number = 2
    data.added_snapshot_id = 77
    var summary = FixtureSummary()
    summary.contains_null = True
    summary.contains_nan = Optional[Bool](False)
    summary.lower = Optional[List[UInt8]](fixture_int_bytes(10))
    summary.upper = Optional[List[UInt8]](fixture_int_bytes(20))
    data.summaries.append(summary^)
    ms.append(data^)
    var deletes = FixtureManifest("/w/t/metadata/m1.avro")
    deletes.content = 1
    deletes.spec_id = 4
    deletes.sequence_number = 4
    deletes.min_sequence_number = 4
    var bare = FixtureSummary()
    deletes.summaries.append(bare^)
    ms.append(deletes^)
    var none = FixtureManifest("/w/t/metadata/m2.avro")
    ms.append(none^)
    return ms^


def _check_list(read: List[IcebergManifestFile]) raises:
    assert_equal(len(read), 3)
    assert_equal(read[0].path, "/w/t/metadata/m0.avro")
    assert_equal(read[0].spec_id, 0)
    assert_equal(read[0].content, 0)
    assert_equal(read[0].sequence_number, 3)
    assert_equal(read[0].min_sequence_number, 2)
    assert_equal(read[0].added_snapshot_id, 77)
    assert_equal(len(read[0].partitions), 1)
    assert_true(read[0].partitions[0].contains_null)
    assert_false(read[0].partitions[0].contains_nan.value())
    assert_true(read[0].partitions[0].lower.value() == fixture_int_bytes(10))
    assert_true(read[0].partitions[0].upper.value() == fixture_int_bytes(20))
    assert_equal(read[1].content, 1)
    assert_equal(read[1].spec_id, 4)
    assert_equal(read[1].sequence_number, 4)
    assert_equal(len(read[1].partitions), 1)
    assert_false(read[1].partitions[0].contains_null)
    assert_false(Bool(read[1].partitions[0].contains_nan))
    assert_false(Bool(read[1].partitions[0].lower))
    assert_false(Bool(read[1].partitions[0].upper))
    assert_equal(len(read[2].partitions), 0)


def test_a_v2_manifest_list_reads_with_summaries() raises:
    var plain = fixture_manifest_list(_list_of_two(), AVRO_CODEC_NULL)
    _check_list(read_manifest_list(Span(plain), 2))
    var packed = fixture_manifest_list(_list_of_two(), AVRO_CODEC_DEFLATE)
    _check_list(read_manifest_list(Span(packed), 2))
    var empty = fixture_manifest_list(List[FixtureManifest](), AVRO_CODEC_NULL)
    assert_equal(len(read_manifest_list(Span(empty), 2)), 0)


def test_a_v1_manifest_list_has_no_content_or_sequence_numbers() raises:
    var bytes = fixture_manifest_list(_list_of_two(), AVRO_CODEC_NULL, True)
    var read = read_manifest_list(Span(bytes), 1)
    assert_equal(len(read), 3)
    assert_equal(read[1].content, 0)
    assert_equal(read[1].sequence_number, 0)
    assert_equal(read[1].min_sequence_number, 0)
    assert_equal(read[0].added_snapshot_id, 77)
    assert_equal(len(read[0].partitions), 1)
    try:
        _ = read_manifest_list(Span(bytes), 2)
        assert_true(False, "a v1 list was read as v2")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_MANIFEST_INVALID: the manifest /w/t/metadata/m0.avro has no sequence_number",
        )


def _names() -> List[String]:
    var names = List[String]()
    names.append("p_int")
    names.append("p_long")
    names.append("p_text")
    names.append("p_bool")
    names.append("p_double")
    names.append("p_float")
    names.append("p_null")
    return names^


def _types() -> List[String]:
    var types = List[String]()
    types.append("int")
    types.append("long")
    types.append("string")
    types.append("boolean")
    types.append("double")
    types.append("float")
    types.append("int")
    return types^


def _entries() -> List[FixtureEntry]:
    var out = List[FixtureEntry]()
    var a = FixtureEntry("file:///w/t/data/a.parquet")
    a.status = 1
    a.record_count = 5
    a.partition.append(FixtureValue.of_int(7))
    a.partition.append(FixtureValue.of_long(Int64(1099511627779)))
    a.partition.append(FixtureValue.of_text("eu"))
    a.partition.append(FixtureValue.of_bool(True))
    a.partition.append(FixtureValue.of_double(1.5))
    a.partition.append(FixtureValue.of_float(2.5))
    a.partition.append(FixtureValue.null_value())
    a.value_counts.add(1, 5)
    a.value_counts.add(2, 5)
    a.null_counts.add(1, 0)
    a.nan_counts.add(3, 1)
    a.lower.add(1, fixture_long_bytes(10))
    a.upper.add(1, fixture_long_bytes(99))
    a.lower.add(2, fixture_text_bytes("abc"))
    out.append(a^)
    var b = FixtureEntry("/w/t/data/b.parquet")
    b.status = 0
    b.sequence_number = Optional[Int64](3)
    b.format = "parquet"
    for _k in range(7):
        b.partition.append(FixtureValue.null_value())
    out.append(b^)
    var c = FixtureEntry("/w/t/data/del.parquet")
    c.status = 2
    c.content = 2
    c.format = "AVRO"
    c.equality_ids.append(3)
    c.equality_ids.append(4)
    c.referenced_data_file = Optional[String]("/w/t/data/a.parquet")
    for _k in range(7):
        c.partition.append(FixtureValue.null_value())
    out.append(c^)
    return out^


def _check_entries(
    read: List[IcebergFileEntry], spec_id: Int
) raises:
    assert_equal(len(read), 3)
    ref a = read[0]
    assert_equal(a.status, ENTRY_ADDED)
    assert_equal(a.data_sequence_number, 5)  # inherited from the manifest
    assert_equal(a.content, 0)
    assert_equal(a.file_path, "file:///w/t/data/a.parquet")
    assert_equal(a.file_format, "PARQUET")
    assert_equal(a.spec_id, spec_id)
    assert_equal(a.record_count, 5)
    assert_equal(len(a.partition), 7)
    assert_true(a.partition[0].value() == fixture_int_bytes(7))
    assert_true(a.partition[1].value() == fixture_long_bytes(Int64(1099511627779)))
    assert_true(a.partition[2].value() == fixture_text_bytes("eu"))
    var one = List[UInt8]()
    one.append(1)
    assert_true(a.partition[3].value() == one)
    assert_true(a.partition[4].value() == fixture_double_bytes(1.5))
    assert_true(a.partition[5].value() == fixture_float_bytes(2.5))
    assert_false(Bool(a.partition[6]))
    assert_equal(a.value_counts.get(1).value(), 5)
    assert_equal(a.value_counts.get(2).value(), 5)
    assert_false(Bool(a.value_counts.get(3)))
    assert_equal(a.null_value_counts.get(1).value(), 0)
    assert_equal(a.nan_value_counts.get(3).value(), 1)
    assert_true(a.lower_bounds.get(1).value() == fixture_long_bytes(10))
    assert_true(a.upper_bounds.get(1).value() == fixture_long_bytes(99))
    assert_true(a.lower_bounds.get(2).value() == fixture_text_bytes("abc"))
    assert_false(Bool(a.upper_bounds.get(2)))
    assert_equal(len(a.equality_ids), 0)
    assert_false(Bool(a.referenced_data_file))
    ref b = read[1]
    assert_equal(b.status, ENTRY_EXISTING)
    assert_equal(b.data_sequence_number, 3)  # its own
    assert_equal(b.file_format, "PARQUET")
    assert_false(Bool(b.partition[0]))
    assert_equal(len(b.value_counts.ids), 0)
    ref c = read[2]
    assert_equal(c.status, ENTRY_DELETED)
    assert_equal(c.content, 2)
    assert_equal(c.file_format, "AVRO")
    assert_equal(len(c.equality_ids), 2)
    assert_equal(c.equality_ids[0], 3)
    assert_equal(c.equality_ids[1], 4)
    assert_equal(c.referenced_data_file.value(), "/w/t/data/a.parquet")


def test_manifest_entries_read_by_name() raises:
    var bytes = fixture_manifest(_entries(), _names(), _types(), AVRO_CODEC_NULL)
    var m = _manifest_file("/w/t/metadata/m0.avro", 5)
    m.spec_id = 2
    _check_entries(read_manifest(Span(bytes), m, _spec(_names()), _schema()), 2)


def test_metric_maps_written_as_avro_maps_read_the_same() raises:
    var bytes = fixture_manifest(
        _entries(), _names(), _types(), AVRO_CODEC_NULL, as_map=True
    )
    var m = _manifest_file("/w/t/metadata/m0.avro", 5)
    m.spec_id = 1
    _check_entries(read_manifest(Span(bytes), m, _spec(_names()), _schema()), 1)

    # A v1 manifest has no content, equality ids or referenced file.
    var v1 = fixture_manifest(
        _entries(), _names(), _types(), AVRO_CODEC_NULL, v1=True
    )
    var read = read_manifest(
        Span(v1), _manifest_file("/w/t/metadata/v1.avro", 0), _spec(_names()), _schema()
    )
    assert_equal(len(read), 3)
    assert_equal(read[0].data_sequence_number, 0)
    assert_equal(read[1].data_sequence_number, 0)
    assert_equal(read[2].content, 0)
    assert_equal(len(read[2].equality_ids), 0)
    assert_false(Bool(read[2].referenced_data_file))
    assert_equal(read[0].value_counts.get(1).value(), 5)


def test_a_manifest_under_deflate_reads() raises:
    var bytes = fixture_manifest(_entries(), _names(), _types(), AVRO_CODEC_DEFLATE)
    var m = _manifest_file("/w/t/metadata/m0.avro", 5)
    m.spec_id = 6
    _check_entries(read_manifest(Span(bytes), m, _spec(_names()), _schema()), 6)
    var none = List[FixtureEntry]()
    var empty = fixture_manifest(none, _names(), _types(), AVRO_CODEC_NULL)
    assert_equal(
        len(read_manifest(Span(empty), m, _spec(_names()), _schema())), 0
    )


def _sync() -> Array[UInt8, OCF_SYNC_LEN]:
    return Array[UInt8, OCF_SYNC_LEN](fill=5)


def _ocf(schema: String, payload: List[UInt8]) raises -> List[UInt8]:
    var keys = List[String]()
    var values = List[String]()
    var out = List[UInt8]()
    emit_ocf_header_kv(schema, AVRO_CODEC_NULL, _sync(), keys, values, out)
    emit_ocf_block(Span(payload), 1, AVRO_CODEC_NULL, _sync(), out)
    return out^


def test_map_keys_that_are_no_field_id_and_a_missing_partition_are_ignored() raises:
    var payload = List[UInt8]()
    encode_int(1, payload)
    encode_string("/w/t/data/a.parquet", payload)
    encode_long(3, payload)
    encode_string("abc", payload)
    encode_long(5, payload)
    encode_string("7", payload)
    encode_long(9, payload)
    encode_string("", payload)
    encode_long(1, payload)
    encode_long(0, payload)
    var bytes = _ocf(
        '{"type":"record","name":"e","fields":[{"name":"status","type":"int"},'
        '{"name":"data_file","type":{"type":"record","name":"d","fields":['
        '{"name":"file_path","type":"string"},'
        '{"name":"value_counts","type":{"type":"map","values":"long"}}]}}]}',
        payload,
    )
    var read = read_manifest(
        Span(bytes), _manifest_file("/w/t/metadata/m.avro", 2), _spec(_names()), _schema()
    )
    assert_equal(len(read), 1)
    assert_equal(len(read[0].value_counts.ids), 1)
    assert_equal(read[0].value_counts.get(7).value(), 9)
    # The writer wrote no partition record: every field of the spec is null.
    assert_equal(len(read[0].partition), 7)
    assert_false(Bool(read[0].partition[3]))
    assert_equal(read[0].data_sequence_number, 2)


def test_malformed_manifests_are_refused_by_message() raises:
    var m = _manifest_file("/w/t/metadata/bad.avro", 1)
    var spec = _spec(List[String]())
    var no_data_file = List[UInt8]()
    encode_int(1, no_data_file)
    var bytes = _ocf(
        '{"type":"record","name":"e","fields":[{"name":"status","type":"int"}]}',
        no_data_file,
    )
    try:
        _ = read_manifest(Span(bytes), m, spec, _schema())
        assert_true(False, "an entry with no data_file was read")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_MANIFEST_INVALID: an entry of /w/t/metadata/bad.avro has no data_file",
        )

    var no_path = List[UInt8]()
    encode_int(1, no_path)
    encode_int(5, no_path)
    var nameless = _ocf(
        '{"type":"record","name":"e","fields":[{"name":"status","type":"int"},'
        '{"name":"data_file","type":{"type":"record","name":"d","fields":'
        '[{"name":"record_count","type":"int"}]}}]}',
        no_path,
    )
    try:
        _ = read_manifest(Span(nameless), m, spec, _schema())
        assert_true(False, "an entry with no file_path was read")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_MANIFEST_INVALID: an entry of /w/t/metadata/bad.avro has no file_path",
        )

    var odd = List[FixtureEntry]()
    var entry = FixtureEntry("/w/t/data/a.parquet")
    entry.status = 7
    odd.append(entry^)
    var bad_status = fixture_manifest(odd, List[String](), List[String](), AVRO_CODEC_NULL)
    try:
        _ = read_manifest(Span(bad_status), m, spec, _schema())
        assert_true(False, "an entry of status 7 was read")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_MANIFEST_INVALID: an entry of /w/t/metadata/bad.avro has no valid status",
        )

    var no_manifest_path = List[UInt8]()
    encode_int(0, no_manifest_path)
    var list_bytes = _ocf(
        '{"type":"record","name":"m","fields":[{"name":"partition_spec_id","type":"int"}]}',
        no_manifest_path,
    )
    try:
        _ = read_manifest_list(Span(list_bytes), 2)
        assert_true(False, "a list entry with no manifest_path was read")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_MANIFEST_INVALID: a manifest list entry has no manifest_path",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_v2_manifest_list_reads_with_summaries]()
    suite.test[test_a_v1_manifest_list_has_no_content_or_sequence_numbers]()
    suite.test[test_manifest_entries_read_by_name]()
    suite.test[test_metric_maps_written_as_avro_maps_read_the_same]()
    suite.test[test_a_manifest_under_deflate_reads]()
    suite.test[test_map_keys_that_are_no_field_id_and_a_missing_partition_are_ignored]()
    suite.test[test_malformed_manifests_are_refused_by_message]()
    suite^.run()
