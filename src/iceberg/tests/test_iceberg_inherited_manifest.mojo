# =============================================================================
# test_iceberg_inherited_manifest.mojo — a manifest written once, and the check
# that a manifest list is this package's own.
# =============================================================================
#
# What each test proves:
#   1. An entry whose sequence number is ICE_SEQ_INHERIT (the commit's and the
#      file's own) writes null `sequence_number` and `file_sequence_number`,
#      byte for byte; a commit sequence number or a file's own is still
#      written as before.
#   2. `build_data_manifest` writes a v2 data manifest from the table's schema
#      text and id: the header keys, the entry schema, one ADDED entry per file
#      with the snapshot id and no sequence number, and a valid empty manifest
#      for no files.
#   3. `is_komira_manifest_list` is true for a list this package writes (with
#      entries and empty) and false for a manifest file, for bytes that are not
#      an OCF, for a truncated header, for a list whose header schema differs
#      by one character, and for a list under another codec.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from avro.ocf_block_emit import generate_sync_marker, emit_ocf_header_kv
from avro.ocf_header import decode_ocf_header, AVRO_CODEC_DEFLATE
from avro.varint_encode import encode_string

from iceberg import (
    ICE_DATA_CONTENT_DATA,
    ICE_SEQ_INHERIT,
    ICE_STATUS_ADDED,
    ColumnBound,
    DataFileInfo,
    IcebergSchema,
    ManifestFileEntry,
    ICE_T_LONG,
    build_data_manifest,
    build_manifest_file,
    build_manifest_list,
    encode_manifest_entry,
    is_komira_manifest_list,
    manifest_entry_schema_json,
    manifest_file_schema_json,
    read_manifest_entries,
    schema_json,
)


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


def _file(path: String, rows: Int, size: Int) -> DataFileInfo:
    var bounds = List[ColumnBound]()
    bounds.append(ColumnBound(1, None, None, 0, rows))
    return DataFileInfo(path, size, rows, bounds^)


def _prefix_is(bytes: List[UInt8], expected: List[Int]) -> Bool:
    if len(bytes) < len(expected):
        return False
    for i in range(len(expected)):
        if Int(bytes[i]) != expected[i]:
            return False
    return True


def test_an_inherited_sequence_number_is_written_null() raises:
    # status ADDED (2), snapshot_id present (2) = 7 (14), then both sequence
    # numbers null (0, 0), then the data_file's content 0.
    var inherited = List[UInt8]()
    encode_manifest_entry(
        Int64(7), ICE_SEQ_INHERIT, _file(String("d/a.parquet"), 3, 10), inherited
    )
    assert_true(_prefix_is(inherited, [2, 2, 14, 0, 0, 0]))

    # A commit sequence number 3 (6) is written twice, as before.
    var commit = List[UInt8]()
    encode_manifest_entry(
        Int64(7), Int64(3), _file(String("d/a.parquet"), 3, 10), commit
    )
    assert_true(_prefix_is(commit, [2, 2, 14, 2, 6, 2, 6, 0]))

    # A file's own sequence number 9 (18) wins even when the commit inherits.
    var own = List[UInt8]()
    encode_manifest_entry(
        Int64(7),
        ICE_SEQ_INHERIT,
        DataFileInfo(
            String("d/a.parquet"),
            10,
            3,
            List[ColumnBound](),
            ICE_DATA_CONTENT_DATA,
            List[Int](),
            Int64(9),
        ),
        own,
    )
    assert_true(_prefix_is(own, [2, 2, 14, 2, 18, 2, 18, 0]))


def test_a_manifest_file_built_with_an_inherited_commit_has_null_sequences() raises:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    var files = List[DataFileInfo]()
    files.append(_file(String("d/a.parquet"), 3, 10))
    var bytes = build_manifest_file(
        schema, schema_json(schema), Int64(7), ICE_SEQ_INHERIT, files
    )
    var entries = read_manifest_entries(bytes)
    assert_equal(len(entries), 1)
    assert_equal(entries[0].file_path, "d/a.parquet")
    assert_equal(entries[0].record_count, 3)


def test_build_data_manifest_writes_the_header_and_added_entries() raises:
    var schema_text = String(
        '{"type":"struct","schema-id":4,"fields":[{"id":1,"name":"id",'
        '"required":true,"type":"long"}]}'
    )
    var files = List[DataFileInfo]()
    files.append(_file(String("s3://w/db/t/data/u-0.parquet"), 3, 111))
    files.append(_file(String("s3://w/db/t/data/u-1.parquet"), 5, 222))
    var bytes = build_data_manifest(schema_text, 4, Int64(77), files)

    var hdr = decode_ocf_header(Span(bytes))
    assert_equal(hdr.schema_json, manifest_entry_schema_json())
    assert_true(_contains(bytes, _kv(String("schema"), schema_text)))
    assert_true(_contains(bytes, _kv(String("schema-id"), String("4"))))
    assert_true(_contains(bytes, _kv(String("partition-spec"), String("[]"))))
    assert_true(_contains(bytes, _kv(String("partition-spec-id"), String("0"))))
    assert_true(_contains(bytes, _kv(String("format-version"), String("2"))))
    assert_true(_contains(bytes, _kv(String("content"), String("data"))))

    var got = read_manifest_entries(bytes)
    assert_equal(len(got), 2)
    assert_equal(got[0].file_path, "s3://w/db/t/data/u-0.parquet")
    assert_equal(got[0].record_count, 3)
    assert_equal(got[0].file_size_in_bytes, 111)
    assert_equal(got[0].status, ICE_STATUS_ADDED)
    assert_equal(got[0].content, ICE_DATA_CONTENT_DATA)
    assert_equal(got[1].file_path, "s3://w/db/t/data/u-1.parquet")
    assert_equal(got[1].record_count, 5)

    # The entries name the snapshot (77 is the two bytes 154, 1 as an Avro
    # long) and no sequence number: status, snapshot present, snapshot id,
    # null, null.
    var entry = List[UInt8]()
    encode_manifest_entry(
        Int64(77), ICE_SEQ_INHERIT, files[0], entry
    )
    assert_true(_prefix_is(entry, [2, 2, 154, 1, 0, 0]))
    assert_true(_contains(bytes, entry))


def test_build_data_manifest_with_no_files_is_a_valid_empty_manifest() raises:
    var bytes = build_data_manifest(
        String('{"type":"struct","fields":[]}'),
        0,
        Int64(1),
        List[DataFileInfo](),
    )
    assert_equal(len(read_manifest_entries(bytes)), 0)
    assert_equal(
        decode_ocf_header(Span(bytes)).schema_json, manifest_entry_schema_json()
    )


def test_a_list_written_by_this_package_is_recognised() raises:
    var entries = List[ManifestFileEntry]()
    entries.append(ManifestFileEntry(String("m/a-m0.avro"), 100, 1, Int64(5)))
    assert_true(
        is_komira_manifest_list(build_manifest_list(Int64(9), Int64(2), entries))
    )
    assert_true(
        is_komira_manifest_list(
            build_manifest_list(Int64(9), Int64(2), List[ManifestFileEntry]())
        )
    )


def test_anything_else_is_not_a_komira_manifest_list() raises:
    # A manifest FILE is an OCF with a different record schema.
    var empty = build_data_manifest(
        String('{"type":"struct","fields":[]}'),
        0,
        Int64(1),
        List[DataFileInfo](),
    )
    assert_false(is_komira_manifest_list(empty))

    # Not an OCF at all, and an OCF cut inside its header.
    var junk = List[UInt8]()
    for i in range(40):
        junk.append(UInt8(i))
    assert_false(is_komira_manifest_list(junk))
    assert_false(is_komira_manifest_list(List[UInt8]()))
    var list_bytes = build_manifest_list(
        Int64(9), Int64(2), List[ManifestFileEntry]()
    )
    var cut = List[UInt8]()
    for i in range(10):
        cut.append(list_bytes[i])
    assert_false(is_komira_manifest_list(cut))

    # The list's own bytes with one character of the header schema changed.
    var altered = list_bytes.copy()
    var needle_text = String("manifest_path")
    var needle = needle_text.as_bytes()
    var at = -1
    for i in range(len(altered) - len(needle)):
        var same = True
        for j in range(len(needle)):
            if altered[i + j] != needle[j]:
                same = False
                break
        if same:
            at = i
            break
    assert_true(at >= 0)
    altered[at] = UInt8(ord("M"))
    assert_false(is_komira_manifest_list(altered))

    # The same schema text under another codec.
    var other_codec = List[UInt8]()
    emit_ocf_header_kv(
        manifest_file_schema_json(),
        AVRO_CODEC_DEFLATE,
        generate_sync_marker(),
        List[String](),
        List[String](),
        other_codec,
    )
    assert_false(is_komira_manifest_list(other_codec))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
