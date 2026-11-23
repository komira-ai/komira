# Manifest files and manifest lists, decoded field by field.
#
# The test decodes the Avro records itself, in the order of the Java schema
# (it shares no code with the encoder), and compares each record as one line.
#
#   * test_a_manifest_holds_java_shaped_entries: an ADDED entry has null
#     sequence numbers, EXISTING and DELETED ones state them; a data file has
#     its counts, NaN counts (only for a double), bounds and split offsets, a
#     delete file none of the maps; an equality delete lists its ids, a
#     position delete the data file it names; partition values are nullable
#     unions (a null one is the null branch); the header names the codec
#     (deflate) and Iceberg's keys, and one block holds every entry.
#   * test_a_manifest_list_summarises_its_manifests: a record per manifest with
#     its path, length, content, sequence numbers, per-status file and row
#     counts, and a summary of each partition field (null flag, bounds); the
#     header carries snapshot-id, parent-snapshot-id (the text `null` for none)
#     and sequence-number.
#   * test_an_unpartitioned_table_has_empty_partitions: no partition field in
#     the entry, an empty summary in the list, `[]` as the partition spec.
#   * test_long_int_and_date_partitions: the schema types of the partition
#     fields and the values read back.
#   * test_a_partition_column_of_another_type_is_refused: by exact message.

from std.testing import TestSuite, assert_equal, assert_true

from avro.avro_codec import decompress_block
from avro.ocf_block_scan import scan_ocf_blocks
from avro.ocf_header import decode_ocf_header
from avro.varint_decode_scalar import AvroByteReader

from komira_iceberg_test_tables.avro_manifests import (
    manifest_entry_schema_json,
    manifest_file_bytes,
    manifest_list_bytes,
    manifest_list_schema_json,
)
from komira_iceberg_test_tables.metrics import file_metrics
from komira_iceberg_test_tables.table_model import (
    CONTENT_DATA,
    CONTENT_EQUALITY_DELETES,
    CONTENT_POSITION_DELETES,
    STATUS_ADDED,
    STATUS_DELETED,
    STATUS_EXISTING,
    TT_BOOLEAN,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    ColumnMetrics,
    ManifestEntryRecord,
    ManifestRecord,
    TableCell,
    TableColumn,
    TableFileRecord,
    TableRow,
    double_cell,
    int_cell,
    null_cell,
    string_cell,
)


def _columns() -> List[TableColumn]:
    var out = List[TableColumn]()
    out.append(TableColumn(1, "id", TT_LONG, True))
    out.append(TableColumn(2, "region", TT_STRING, True))
    out.append(TableColumn(3, "price", TT_DOUBLE, False))
    return out^


def _partition_columns() -> List[TableColumn]:
    var out = List[TableColumn]()
    out.append(TableColumn(2, "region", TT_STRING, True))
    return out^


def _row(id: Int, region: String, price: Float64) -> TableRow:
    var cells = List[TableCell]()
    cells.append(int_cell(id))
    cells.append(string_cell(region))
    cells.append(double_cell(price))
    return TableRow(cells^)


def _region(value: String) -> List[TableCell]:
    var cells = List[TableCell]()
    if value.byte_length() == 0:
        cells.append(null_cell())
    else:
        cells.append(string_cell(value))
    return cells^


def _file(
    name: String,
    content: Int,
    file_format: String,
    region: String,
    record_count: Int,
    size: Int,
    metrics: List[ColumnMetrics],
    equality_ids: List[Int],
    referenced: String,
) -> TableFileRecord:
    return TableFileRecord(
        name.copy(),
        "data/" + name,
        "file:///w/t/data/" + name,
        content,
        file_format.copy(),
        _region(region),
        Int64(record_count),
        Int64(size),
        metrics.copy(),
        equality_ids.copy(),
        referenced.copy(),
    )


def _hex(bytes: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var out = String()
    for i in range(len(bytes)):
        var v = Int(bytes[i])
        out += String(digits[byte = v // 16 : v // 16 + 1])
        out += String(digits[byte = v % 16 : v % 16 + 1])
    return out^


def _contains(bytes: List[UInt8], part: String) -> Bool:
    var needle = part.as_bytes()
    for start in range(len(bytes) - len(needle) + 1):
        var same = True
        for k in range(len(needle)):
            if bytes[start + k] != needle[k]:
                same = False
                break
        if same:
            return True
    return False


def _payload(bytes: List[UInt8], expected_records: Int) raises -> List[UInt8]:
    """The decompressed records of the file's one block."""
    var header = decode_ocf_header(Span(bytes))
    assert_equal(header.codec_name(), "deflate")
    var blocks = scan_ocf_blocks(Span(bytes))
    assert_equal(len(blocks), 1)
    assert_equal(Int(blocks[0].object_count), expected_records)
    return decompress_block(
        header.codec_tag,
        Span(bytes)[blocks[0].payload_offset : blocks[0].payload_offset + blocks[0].payload_len],
    )


def _optional_long[o: Origin[mut=False]](mut reader: AvroByteReader[o]) raises -> String:
    if reader.read_long() == 0:
        return String("null")
    return String(Int(reader.read_long()))


def _long_map[o: Origin[mut=False]](mut reader: AvroByteReader[o]) raises -> String:
    if reader.read_long() == 0:
        return String("null")
    var out = String()
    var count = Int(reader.read_long())
    while count != 0:
        for _ in range(count):
            if out.byte_length() > 0:
                out += ","
            out += String(Int(reader.read_int())) + ":" + String(Int(reader.read_long()))
        count = Int(reader.read_long())
    return out^


def _bytes_map[o: Origin[mut=False]](mut reader: AvroByteReader[o]) raises -> String:
    if reader.read_long() == 0:
        return String("null")
    var out = String()
    var count = Int(reader.read_long())
    while count != 0:
        for _ in range(count):
            if out.byte_length() > 0:
                out += ","
            out += String(Int(reader.read_int())) + ":" + _hex(reader.read_bytes())
        count = Int(reader.read_long())
    return out^


def _int_array[o: Origin[mut=False]](mut reader: AvroByteReader[o], longs: Bool) raises -> String:
    if reader.read_long() == 0:
        return String("null")
    var out = String()
    var count = Int(reader.read_long())
    while count != 0:
        for _ in range(count):
            if out.byte_length() > 0:
                out += ","
            if longs:
                out += String(Int(reader.read_long()))
            else:
                out += String(Int(reader.read_int()))
        count = Int(reader.read_long())
    return out^


def _partition[o: Origin[mut=False]](mut reader: AvroByteReader[o], columns: List[TableColumn]) raises -> String:
    var out = String()
    for c in range(len(columns)):
        if c > 0:
            out += ","
        if reader.read_long() == 0:
            out += "null"
        elif columns[c].type_tag == TT_STRING:
            out += reader.read_string()
        elif columns[c].type_tag == TT_LONG:
            out += String(Int(reader.read_long()))
        else:
            out += String(Int(reader.read_int()))
    return out^


def _entry[o: Origin[mut=False]](mut reader: AvroByteReader[o], partition_columns: List[TableColumn]) raises -> String:
    var out = String("status=") + String(Int(reader.read_int()))
    out += " snap=" + _optional_long(reader)
    out += " seq=" + _optional_long(reader)
    out += " fseq=" + _optional_long(reader)
    out += " content=" + String(Int(reader.read_int()))
    out += " path=" + reader.read_string()
    out += " format=" + reader.read_string()
    out += " part=" + _partition(reader, partition_columns)
    out += " rows=" + String(Int(reader.read_long()))
    out += " size=" + String(Int(reader.read_long()))
    out += " sizes=" + _long_map(reader)
    out += " vc=" + _long_map(reader)
    out += " nvc=" + _long_map(reader)
    out += " nanc=" + _long_map(reader)
    out += " lo=" + _bytes_map(reader)
    out += " up=" + _bytes_map(reader)
    if reader.read_long() == 0:
        out += " key=null"
    else:
        out += " key=bytes"
    out += " split=" + _int_array(reader, True)
    out += " eq=" + _int_array(reader, False)
    out += " sort=" + _optional_long(reader)
    if reader.read_long() == 0:
        out += " ref=null"
    else:
        out += " ref=" + reader.read_string()
    return out^


def _three_files() -> List[TableFileRecord]:
    var rows = List[TableRow]()
    rows.append(_row(1, "east", 2.5))
    rows.append(_row(3, "east", 0.5))
    rows.append(_row(2, "east", 1.0))
    var files = List[TableFileRecord]()
    files.append(
        _file("a.parquet", CONTENT_DATA, "PARQUET", "east", 3, 1234, file_metrics(_columns(), rows), List[Int](), "")
    )
    files.append(
        _file("pos.parquet", CONTENT_POSITION_DELETES, "PARQUET", "east", 2, 99, List[ColumnMetrics](), List[Int](), "file:///w/t/data/a.parquet")
    )
    var ids = List[Int]()
    ids.append(1)
    ids.append(5)
    files.append(
        _file("eq.avro", CONTENT_EQUALITY_DELETES, "AVRO", "", 1, 55, List[ColumnMetrics](), ids^, "")
    )
    return files^


def _manifest(
    content: Int, entries: List[ManifestEntryRecord], seq: Int, min_seq: Int, length: Int
) -> ManifestRecord:
    return ManifestRecord(
        "metadata/m.avro", "file:///w/t/metadata/m.avro", content, Int64(seq),
        Int64(min_seq), Int64(11), Int64(length), entries.copy(),
    )


def _manifests_of(manifest: ManifestRecord) -> List[ManifestRecord]:
    var out = List[ManifestRecord]()
    out.append(manifest.copy())
    return out^


def test_a_manifest_holds_java_shaped_entries() raises:
    var files = _three_files()
    var entries = List[ManifestEntryRecord]()
    entries.append(ManifestEntryRecord(STATUS_ADDED, 0, Int64(11), Int64(5)))
    entries.append(ManifestEntryRecord(STATUS_EXISTING, 1, Int64(7), Int64(3)))
    entries.append(ManifestEntryRecord(STATUS_DELETED, 2, Int64(11), Int64(2)))
    var manifest = _manifest(CONTENT_DATA, entries, 5, 2, 0)
    var bytes = manifest_file_bytes(manifest, files, _columns(), _partition_columns())
    var header = decode_ocf_header(Span(bytes))
    assert_equal(header.schema_json, manifest_entry_schema_json(_partition_columns()))
    assert_true(_contains(bytes, "partition-spec-id"))
    assert_true(_contains(bytes, "format-version"))
    assert_true(_contains(bytes, "schema-id"))
    assert_true(_contains(bytes, "data"))
    var raw = _payload(bytes, 3)
    var reader = AvroByteReader(Span(raw))
    assert_equal(
        _entry(reader, _partition_columns()),
        "status=1 snap=11 seq=null fseq=null content=0"
        " path=file:///w/t/data/a.parquet format=PARQUET part=east rows=3 size=1234"
        " sizes=null vc=1:3,2:3,3:3 nvc=1:0,2:0,3:0 nanc=3:0"
        " lo=1:0100000000000000,2:65617374,3:000000000000e03f"
        " up=1:0300000000000000,2:65617374,3:0000000000000440"
        " key=null split=4 eq=null sort=null ref=null",
    )
    assert_equal(
        _entry(reader, _partition_columns()),
        "status=0 snap=7 seq=3 fseq=3 content=1"
        " path=file:///w/t/data/pos.parquet format=PARQUET part=east rows=2 size=99"
        " sizes=null vc=null nvc=null nanc=null lo=null up=null"
        " key=null split=null eq=null sort=null ref=file:///w/t/data/a.parquet",
    )
    assert_equal(
        _entry(reader, _partition_columns()),
        "status=2 snap=11 seq=2 fseq=2 content=2"
        " path=file:///w/t/data/eq.avro format=AVRO part=null rows=1 size=55"
        " sizes=null vc=null nvc=null nanc=null lo=null up=null"
        " key=null split=null eq=1,5 sort=null ref=null",
    )
    assert_true(reader.at_end())
    var deletes = manifest_file_bytes(
        _manifest(1, entries, 5, 2, 0), files, _columns(), _partition_columns()
    )
    assert_true(_contains(deletes, "deletes"))


def test_a_manifest_list_summarises_its_manifests() raises:
    var files = _three_files()
    var rows = List[TableRow]()
    rows.append(_row(9, "west", 1.0))
    files.append(
        _file("w.parquet", CONTENT_DATA, "PARQUET", "west", 4, 10, file_metrics(_columns(), rows), List[Int](), "")
    )
    files.append(
        _file("s.parquet", CONTENT_DATA, "PARQUET", "south", 6, 10, List[ColumnMetrics](), List[Int](), "")
    )
    var first = List[ManifestEntryRecord]()
    first.append(ManifestEntryRecord(STATUS_ADDED, 0, Int64(11), Int64(5)))
    first.append(ManifestEntryRecord(STATUS_EXISTING, 3, Int64(7), Int64(3)))
    first.append(ManifestEntryRecord(STATUS_DELETED, 4, Int64(11), Int64(2)))
    var second = List[ManifestEntryRecord]()
    second.append(ManifestEntryRecord(STATUS_ADDED, 1, Int64(11), Int64(5)))
    second.append(ManifestEntryRecord(STATUS_ADDED, 2, Int64(11), Int64(5)))
    var third = List[ManifestEntryRecord]()
    third.append(ManifestEntryRecord(STATUS_ADDED, 2, Int64(11), Int64(5)))
    var manifests = List[ManifestRecord]()
    manifests.append(_manifest(CONTENT_DATA, first, 5, 2, 1000))
    manifests.append(_manifest(1, second, 5, 5, 2000))
    manifests.append(_manifest(1, third, 5, 5, 3000))
    var bytes = manifest_list_bytes(manifests, files, _partition_columns(), Int64(11), Int64(-1), Int64(5))
    assert_equal(decode_ocf_header(Span(bytes)).schema_json, manifest_list_schema_json())
    assert_true(_contains(bytes, "parent-snapshot-id"))
    assert_true(_contains(bytes, "null"))
    var raw = _payload(bytes, 3)
    var reader = AvroByteReader(Span(raw))
    for k in range(3):
        var line = String("path=") + reader.read_string()
        line += " len=" + String(Int(reader.read_long()))
        line += " spec=" + String(Int(reader.read_int()))
        line += " content=" + String(Int(reader.read_int()))
        line += " seq=" + String(Int(reader.read_long()))
        line += " min=" + String(Int(reader.read_long()))
        line += " snap=" + String(Int(reader.read_long()))
        line += " files=" + String(Int(reader.read_int())) + "/" + String(Int(reader.read_int())) + "/" + String(Int(reader.read_int()))
        line += " rows=" + String(Int(reader.read_long())) + "/" + String(Int(reader.read_long())) + "/" + String(Int(reader.read_long()))
        assert_equal(Int(reader.read_long()), 1)  # partitions present
        var count = Int(reader.read_long())
        line += " fields=" + String(count)
        for _ in range(count):
            line += " null=" + String(reader.read_boolean())
            assert_equal(Int(reader.read_long()), 0)  # contains_nan unknown
            if reader.read_long() == 0:
                line += " lo=null"
                assert_equal(Int(reader.read_long()), 0)
                line += " up=null"
            else:
                line += " lo=" + _hex(reader.read_bytes())
                assert_equal(Int(reader.read_long()), 1)
                line += " up=" + _hex(reader.read_bytes())
        assert_equal(Int(reader.read_long()), 0)  # end of the array
        assert_equal(Int(reader.read_long()), 0)  # key_metadata
        if k == 0:
            assert_equal(
                line,
                "path=file:///w/t/metadata/m.avro len=1000 spec=0 content=0 seq=5 min=2 snap=11"
                " files=1/1/1 rows=3/4/6 fields=1 null=False lo=65617374 up=77657374",
            )
        elif k == 2:
            # Only a null partition value: no bounds.
            assert_equal(
                line,
                "path=file:///w/t/metadata/m.avro len=3000 spec=0 content=1 seq=5 min=5 snap=11"
                " files=1/0/0 rows=1/0/0 fields=1 null=True lo=null up=null",
            )
        else:
            assert_equal(
                line,
                "path=file:///w/t/metadata/m.avro len=2000 spec=0 content=1 seq=5 min=5 snap=11"
                " files=2/0/0 rows=3/0/0 fields=1 null=True lo=65617374 up=65617374",
            )
    assert_true(reader.at_end())
    # A table with a parent writes its id.
    var with_parent = manifest_list_bytes(manifests, files, _partition_columns(), Int64(12), Int64(11), Int64(6))
    assert_true(_contains(with_parent, "11"))


def test_an_unpartitioned_table_has_empty_partitions() raises:
    # Unpartitioned: the files carry no partition tuple.
    var plain = List[TableFileRecord]()
    plain.append(
        TableFileRecord(
            "a", "data/a", "file:///w/t/data/a", CONTENT_DATA, "PARQUET",
            List[TableCell](), Int64(3), Int64(10), file_metrics(_columns(), List[TableRow]()),
            List[Int](), "",
        )
    )
    var entries = List[ManifestEntryRecord]()
    entries.append(ManifestEntryRecord(STATUS_ADDED, 0, Int64(11), Int64(5)))
    var manifest = _manifest(CONTENT_DATA, entries, 5, 5, 10)
    var bytes = manifest_file_bytes(manifest, plain, _columns(), List[TableColumn]())
    assert_true(_contains(bytes, "[]"))
    var raw = _payload(bytes, 1)
    var reader = AvroByteReader(Span(raw))
    assert_equal(
        _entry(reader, List[TableColumn]()),
        "status=1 snap=11 seq=null fseq=null content=0 path=file:///w/t/data/a"
        " format=PARQUET part= rows=3 size=10 sizes=null vc=1:0,2:0,3:0 nvc=1:0,2:0,3:0"
        " nanc=3:0 lo=null up=null key=null split=4 eq=null sort=null ref=null",
    )
    var list_bytes = manifest_list_bytes(
        _manifests_of(manifest), plain, List[TableColumn](), Int64(11), Int64(-1), Int64(5)
    )
    var list_raw = _payload(list_bytes, 1)
    var list_reader = AvroByteReader(Span(list_raw))
    _ = list_reader.read_string()
    _ = list_reader.read_long()
    _ = list_reader.read_int()
    _ = list_reader.read_int()
    for _ in range(3):
        _ = list_reader.read_long()
    for _ in range(3):
        _ = list_reader.read_int()
    for _ in range(3):
        _ = list_reader.read_long()
    assert_equal(Int(list_reader.read_long()), 1)
    assert_equal(Int(list_reader.read_long()), 0)
    assert_equal(Int(list_reader.read_long()), 0)
    assert_true(list_reader.at_end())


def test_long_int_and_date_partitions() raises:
    var partition = List[TableColumn]()
    partition.append(TableColumn(1, "a", TT_LONG, True))
    partition.append(TableColumn(2, "b", TT_INT, True))
    partition.append(TableColumn(3, "c", TT_DATE, True))
    var schema = manifest_entry_schema_json(partition)
    assert_true(schema.find('{"name":"a","type":["null","long"],"default":null,"field-id":1000}') >= 0, schema)
    assert_true(schema.find('{"name":"b","type":["null","int"],"default":null,"field-id":1001}') >= 0, schema)
    assert_true(
        schema.find('{"name":"c","type":["null",{"type":"int","logicalType":"date"}],"default":null,"field-id":1002}') >= 0,
        schema,
    )
    var cells = List[TableCell]()
    cells.append(int_cell(-5000000000))
    cells.append(int_cell(7))
    cells.append(int_cell(20819))
    var file = TableFileRecord(
        "a", "data/a", "file:///w/t/data/a", CONTENT_DATA, "PARQUET", cells^,
        Int64(1), Int64(1), List[ColumnMetrics](), List[Int](), "",
    )
    var files = List[TableFileRecord]()
    files.append(file^)
    var entries = List[ManifestEntryRecord]()
    entries.append(ManifestEntryRecord(STATUS_ADDED, 0, Int64(11), Int64(5)))
    var columns = List[TableColumn]()
    columns.append(TableColumn(1, "a", TT_LONG, True))
    columns.append(TableColumn(2, "b", TT_INT, True))
    columns.append(TableColumn(3, "c", TT_DATE, True))
    var bytes = manifest_file_bytes(_manifest(CONTENT_DATA, entries, 5, 5, 0), files, columns, partition)
    var raw = _payload(bytes, 1)
    var reader = AvroByteReader(Span(raw))
    var line = _entry(reader, partition)
    assert_true(line.find(" part=-5000000000,7,20819 ") >= 0, line)


def test_a_partition_column_of_another_type_is_refused() raises:
    var message = String()
    var partition = List[TableColumn]()
    partition.append(TableColumn(4, "flag", TT_BOOLEAN, True))
    try:
        _ = manifest_entry_schema_json(partition)
    except e:
        message = String(e)
    assert_equal(
        message,
        "komira_iceberg_test_tables: a partition column is a long, an int, a date or a string, not type 5",
    )
    partition = List[TableColumn]()
    partition.append(TableColumn(3, "price", TT_DOUBLE, True))
    message = String()
    try:
        _ = manifest_entry_schema_json(partition)
    except e:
        message = String(e)
    assert_equal(
        message,
        "komira_iceberg_test_tables: a partition column is a long, an int, a date or a string, not type 3",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
