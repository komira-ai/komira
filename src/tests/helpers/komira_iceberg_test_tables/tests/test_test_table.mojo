# TestTable: the layout of a table on disk, what each commit lists, and its
# refusals.
#
#   * test_an_unpartitioned_table_is_laid_out_as_java_lays_it_out: two appends
#     write the data files, one manifest and one manifest list per commit, a
#     metadata.json per commit and version-hint.text holding the version (no
#     newline); a manifest records `<location>/<path>` though the files are
#     elsewhere; the second snapshot lists its new manifest first, then the
#     first snapshot's; sequence numbers, snapshot ids and the summary.
#   * test_partition_directories_follow_the_partition_values: string, long,
#     int and date values and a null each name a `col=value` directory.
#   * test_position_deletes_are_sorted_by_path_then_position: the rows of the
#     delete file, read back, in the spec's order; `referenced` records the
#     one data file named, and is refused for two.
#   * test_a_position_delete_file_can_be_avro and
#     test_equality_deletes_name_table_columns: formats and field ids.
#   * test_overwrite_rewrites_the_manifest_that_holds_a_removed_file: the
#     rewritten manifest has the removed file DELETED and the others EXISTING
#     with their own sequence numbers, the manifests that hold none are listed
#     as they were, the added files have a manifest first, and a manifest
#     whose files are all removed has min sequence number of the commit.
#   * test_create_writes_a_table_with_no_snapshot.
#   * test_refusals: every refusal by exact message.

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.record_batch import RecordBatch
from avro.avro_ocf_reader import read_avro_bytes
from byte_buffer.byte_view import ByteView
from parquet.bytes_decode import decode_row_group_from_bytes, row_group_byte_range
from parquet.metadata_parser import parse_full_metadata
from parquet.morsel_reader import ColumnProjection
from parquet_api.metadata import FileMetaData
from runtime_paths import test_tmpdir

from komira_iceberg_test_tables.table_model import (
    CONTENT_DATA,
    CONTENT_EQUALITY_DELETES,
    CONTENT_POSITION_DELETES,
    STATUS_ADDED,
    STATUS_DELETED,
    STATUS_EXISTING,
    TT_DATE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    TableCell,
    TableColumn,
    TableRow,
    int_cell,
    null_cell,
    string_cell,
)
from komira_iceberg_test_tables.test_table import (
    PositionDelete,
    TestDataFile,
    TestTable,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _read_parquet(path: String) raises -> RecordBatch:
    var file = Path(path).read_bytes()
    var md = _footer(file)
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


def _columns() -> List[TableColumn]:
    var out = List[TableColumn]()
    out.append(TableColumn(1, "id", TT_LONG, True))
    out.append(TableColumn(2, "name", TT_STRING, False))
    return out^


def _data_file(name: String, first_id: Int, count: Int) -> TestDataFile:
    """Rows first_id .. first_id + count - 1, named `n<id>`; no partition."""
    var rows = List[TableRow]()
    for i in range(count):
        var cells = List[TableCell]()
        cells.append(int_cell(first_id + i))
        cells.append(string_cell("n" + String(first_id + i)))
        rows.append(TableRow(cells^))
    return TestDataFile(name.copy(), List[TableCell](), rows^)


def _new_table(name: String) raises -> TestTable:
    return TestTable(
        test_tmpdir() + "/table_" + name,
        "file:///warehouse/db/" + name,
        _columns(),
    )


def _exists(table: TestTable, rel: String) -> Bool:
    return Path(table.root + "/" + rel).exists()


def _text(table: TestTable, rel: String) raises -> String:
    return Path(table.root + "/" + rel).read_text()


def _has(text: String, part: String) -> Bool:
    return text.find(part) >= 0


def _overwrite_error(mut table: TestTable, removed: List[String]) raises -> String:
    try:
        _ = table.overwrite(removed, List[TestDataFile]())
    except e:
        return String(e)
    return String("")


def _append_error(mut table: TestTable, files: List[TestDataFile]) raises -> String:
    try:
        _ = table.append(files)
    except e:
        return String(e)
    return String("")


def test_an_unpartitioned_table_is_laid_out_as_java_lays_it_out() raises:
    var table = _new_table("layout")
    var first = List[TestDataFile]()
    first.append(_data_file("f1", 1, 2))
    first.append(_data_file("f2", 3, 1))
    var snap1 = table.append(first)
    assert_equal(Int(snap1), 6000000001)
    assert_equal(Int(table.snapshot_id(1)), 6000000001)
    assert_true(_exists(table, "data/f1.parquet"))
    assert_true(_exists(table, "data/f2.parquet"))
    assert_true(_exists(table, "metadata/v1.metadata.json"))
    assert_equal(_text(table, "metadata/version-hint.text"), "1")
    assert_true(_exists(table, "metadata/a1b2c3d4-0000-4000-8000-000000000001-m0.avro"))
    assert_true(
        _exists(table, "metadata/snap-6000000001-1-a1b2c3d4-0000-4000-8000-000000000101.avro")
    )
    assert_equal(
        table.files[0].uri, "file:///warehouse/db/layout/data/f1.parquet"
    )
    assert_equal(table.files[0].rel_path, "data/f1.parquet")
    assert_equal(Int(table.files[0].record_count), 2)
    assert_equal(
        Int(table.files[0].size_bytes),
        len(Path(table.root + "/data/f1.parquet").read_bytes()),
    )
    assert_equal(len(table.files[0].metrics), 2)
    assert_equal(len(table.files[0].partition), 0)
    assert_equal(len(table.manifests), 1)
    assert_equal(len(table.manifests[0].entries), 2)
    assert_equal(table.manifests[0].entries[0].status, STATUS_ADDED)
    assert_equal(Int(table.manifests[0].entries[0].data_seq), 1)
    assert_equal(Int(table.manifests[0].sequence_number), 1)
    assert_equal(
        Int(table.manifests[0].length),
        len(Path(table.root + "/" + table.manifests[0].rel_path).read_bytes()),
    )
    assert_equal(table.snapshots[0].operation, "append")
    assert_equal(table.snapshots[0].added_data_files, 2)
    assert_equal(Int(table.snapshots[0].added_records), 3)

    var second = List[TestDataFile]()
    second.append(_data_file("f3", 4, 1))
    var snap2 = table.append(second)
    assert_equal(Int(snap2), 6000000002)
    assert_equal(_text(table, "metadata/version-hint.text"), "2")
    assert_true(_exists(table, "metadata/v2.metadata.json"))
    assert_equal(len(table.manifests), 2)
    assert_equal(
        table.manifests[0].uri,
        "file:///warehouse/db/layout/metadata/a1b2c3d4-0000-4000-8000-000000000002-m0.avro",
    )
    assert_equal(Int(table.manifests[0].sequence_number), 2)
    assert_equal(Int(table.manifests[1].sequence_number), 1)
    assert_equal(Int(table.snapshots[1].parent_snapshot_id), 6000000001)
    var json = _text(table, "metadata/v2.metadata.json")
    assert_true(_has(json, '"location" : "file:///warehouse/db/layout",'), json)
    assert_true(_has(json, '"current-snapshot-id" : 6000000002,'), json)
    assert_true(_has(json, '"last-sequence-number" : 2,'), json)
    assert_true(_has(json, '"parent-snapshot-id" : 6000000001,'), json)
    assert_true(
        _has(json, '"manifest-list" : "file:///warehouse/db/layout/metadata/snap-6000000002-1-a1b2c3d4-0000-4000-8000-000000000102.avro",'),
        json,
    )
    assert_false(_has(_text(table, "metadata/v1.metadata.json"), "6000000002"))


def test_partition_directories_follow_the_partition_values() raises:
    var columns = List[TableColumn]()
    columns.append(TableColumn(1, "id", TT_LONG, True))
    columns.append(TableColumn(2, "region", TT_STRING, False))
    columns.append(TableColumn(3, "bucket", TT_LONG, False))
    columns.append(TableColumn(4, "n", TT_INT, False))
    columns.append(TableColumn(5, "d", TT_DATE, False))
    var by = List[String]()
    by.append("region")
    by.append("bucket")
    by.append("n")
    by.append("d")
    var table = TestTable(
        test_tmpdir() + "/table_partitions", "file:///w/p", columns^, by
    )
    var files = List[TestDataFile]()
    for k in range(2):
        var partition = List[TableCell]()
        var cells = List[TableCell]()
        cells.append(int_cell(1))
        if k == 0:
            partition.append(string_cell("east"))
            partition.append(int_cell(5))
            partition.append(int_cell(7))
            partition.append(int_cell(20819))
        else:
            partition.append(null_cell())
            partition.append(int_cell(-1))
            partition.append(int_cell(0))
            partition.append(int_cell(1))
        cells.append(partition[0].copy())
        cells.append(partition[1].copy())
        cells.append(partition[2].copy())
        cells.append(partition[3].copy())
        var rows = List[TableRow]()
        rows.append(TableRow(cells^))
        files.append(TestDataFile("f" + String(k), partition^, rows^))
    _ = table.append(files)
    assert_equal(table.files[0].rel_path, "data/region=east/bucket=5/n=7/d=20819/f0.parquet")
    assert_equal(table.files[1].rel_path, "data/region=null/bucket=-1/n=0/d=1/f1.parquet")
    assert_true(_exists(table, "data/region=east/bucket=5/n=7/d=20819/f0.parquet"))
    assert_true(_exists(table, "data/region=null/bucket=-1/n=0/d=1/f1.parquet"))
    var json = _text(table, "metadata/v1.metadata.json")
    assert_true(_has(json, '"last-partition-id" : 1003,'), json)
    assert_true(_has(json, '{"name":"d","transform":"identity","source-id":5,"field-id":1003}'), json)


def test_position_deletes_are_sorted_by_path_then_position() raises:
    var table = _new_table("pos_sorted")
    var files = List[TestDataFile]()
    files.append(_data_file("f1", 1, 3))
    files.append(_data_file("f2", 4, 3))
    _ = table.append(files)
    var deletes = List[PositionDelete]()
    deletes.append(PositionDelete("f2", 1))
    deletes.append(PositionDelete("f1", 2))
    deletes.append(PositionDelete("f1", 0))
    var snap = table.add_position_deletes("pd", List[TableCell](), deletes)
    assert_equal(Int(snap), 6000000002)
    var batch = _read_parquet(table.root + "/data/pd.parquet")
    assert_equal(batch.num_rows(), 3)
    assert_equal(batch.schema.field_name(0), "file_path")
    assert_equal(batch.schema.field_name(1), "pos")
    var f1 = String("file:///warehouse/db/pos_sorted/data/f1.parquet")
    var f2 = String("file:///warehouse/db/pos_sorted/data/f2.parquet")
    assert_equal(batch.column_at(0).as_string().get(0), f1)
    assert_equal(Int(batch.column_at(1).as_primitive[DType.int64]().get(0)), 0)
    assert_equal(batch.column_at(0).as_string().get(1), f1)
    assert_equal(Int(batch.column_at(1).as_primitive[DType.int64]().get(1)), 2)
    assert_equal(batch.column_at(0).as_string().get(2), f2)
    assert_equal(Int(batch.column_at(1).as_primitive[DType.int64]().get(2)), 1)
    assert_equal(len(table.manifests), 2)
    assert_equal(table.manifests[0].content, 1)
    assert_equal(table.manifests[1].content, 0)
    assert_equal(table.files[2].content, CONTENT_POSITION_DELETES)
    assert_equal(table.files[2].file_format, "PARQUET")
    assert_equal(len(table.files[2].metrics), 0)
    assert_equal(table.files[2].referenced_data_file, "")
    assert_equal(table.snapshots[1].added_delete_files, 1)
    # With `referenced`, the entry names the one data file.
    var one = List[PositionDelete]()
    one.append(PositionDelete("f1", 1))
    _ = table.add_position_deletes("pd2", List[TableCell](), one, "PARQUET", True)
    assert_equal(table.files[3].referenced_data_file, f1)


def test_a_position_delete_file_can_be_avro() raises:
    var table = _new_table("pos_avro")
    var files = List[TestDataFile]()
    files.append(_data_file("f1", 1, 3))
    _ = table.append(files)
    var deletes = List[PositionDelete]()
    deletes.append(PositionDelete("f1", 2))
    _ = table.add_position_deletes("pd", List[TableCell](), deletes, "AVRO")
    assert_true(_exists(table, "data/pd.avro"))
    assert_false(_exists(table, "data/pd.parquet"))
    assert_equal(table.files[1].file_format, "AVRO")
    var avro_bytes = Path(table.root + "/data/pd.avro").read_bytes()
    var batch = read_avro_bytes(Span(avro_bytes))
    assert_equal(batch.num_rows(), 1)
    assert_equal(
        batch.column_at(0).as_string().get(0),
        "file:///warehouse/db/pos_avro/data/f1.parquet",
    )
    assert_equal(Int(batch.column_at(1).as_primitive[DType.int64]().get(0)), 2)


def test_equality_deletes_name_table_columns() raises:
    var table = _new_table("equality")
    var files = List[TestDataFile]()
    files.append(_data_file("f1", 1, 3))
    _ = table.append(files)
    var rows = List[TableRow]()
    var key = List[TableCell]()
    key.append(int_cell(2))
    rows.append(TableRow(key^))
    var columns = List[String]()
    columns.append("id")
    var snap = table.add_equality_deletes("eq", List[TableCell](), columns, rows)
    assert_equal(Int(snap), 6000000002)
    assert_equal(table.files[1].content, CONTENT_EQUALITY_DELETES)
    assert_equal(len(table.files[1].equality_ids), 1)
    assert_equal(table.files[1].equality_ids[0], 1)
    var batch = _read_parquet(table.root + "/data/eq.parquet")
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.schema.field_name(0), "id")
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(0)), 2)
    var in_avro = table.add_equality_deletes("eq2", List[TableCell](), columns, rows, "AVRO")
    assert_equal(Int(in_avro), 6000000003)
    assert_true(_exists(table, "data/eq2.avro"))


def test_overwrite_rewrites_the_manifest_that_holds_a_removed_file() raises:
    var table = _new_table("overwrite")
    var first = List[TestDataFile]()
    first.append(_data_file("a", 1, 2))
    first.append(_data_file("b", 3, 1))
    _ = table.append(first)
    var second = List[TestDataFile]()
    second.append(_data_file("c", 4, 1))
    _ = table.append(second)
    var deletes = List[PositionDelete]()
    deletes.append(PositionDelete("c", 0))
    _ = table.add_position_deletes("pd", List[TableCell](), deletes)

    var removed = List[String]()
    removed.append("a")
    var added = List[TestDataFile]()
    added.append(_data_file("d", 5, 1))
    var snap = table.overwrite(removed, added)
    assert_equal(Int(snap), 6000000004)
    assert_equal(table.snapshots[3].operation, "overwrite")
    assert_equal(table.snapshots[3].added_data_files, 1)
    assert_equal(len(table.manifests), 4)
    # The added files first, then the delete manifest and the untouched data
    # manifest as they were, then the rewritten one.
    assert_equal(table.files[table.manifests[0].entries[0].file_index].name, "d")
    assert_equal(table.manifests[0].entries[0].status, STATUS_ADDED)
    assert_equal(table.manifests[1].content, 1)
    assert_equal(table.manifests[2].content, CONTENT_DATA)
    assert_equal(table.manifests[2].entries[0].status, STATUS_ADDED)
    var rewritten = table.manifests[3].copy()
    assert_equal(len(rewritten.entries), 2)
    assert_equal(rewritten.entries[0].status, STATUS_DELETED)
    assert_equal(Int(rewritten.entries[0].data_seq), 1)
    assert_equal(Int(rewritten.entries[0].snapshot_id), 6000000004)
    assert_equal(rewritten.entries[1].status, STATUS_EXISTING)
    assert_equal(Int(rewritten.entries[1].data_seq), 1)
    assert_equal(Int(rewritten.entries[1].snapshot_id), 6000000001)
    assert_equal(Int(rewritten.sequence_number), 4)
    assert_equal(Int(rewritten.min_sequence_number), 1)
    assert_equal(
        rewritten.uri,
        "file:///warehouse/db/overwrite/metadata/a1b2c3d4-0000-4000-8000-000000000004-m0.avro",
    )

    # A removed file, and a delete file, are not live data files.
    var again = List[String]()
    again.append("a")
    assert_equal(_overwrite_error(table, again), "TestTable.overwrite: a is not a live data file of the table")
    var delete_name = List[String]()
    delete_name.append("pd")
    assert_equal(_overwrite_error(table, delete_name), "TestTable.overwrite: pd is not a live data file of the table")

    # Removing the last live file of a manifest, adding none: its entries are
    # DELETED, the dropped one is gone, the minimum is the commit's.
    var last = List[String]()
    last.append("b")
    _ = table.overwrite(last, List[TestDataFile]())
    assert_equal(len(table.manifests), 4)
    assert_equal(len(table.manifests[3].entries), 1)
    assert_equal(table.manifests[3].entries[0].status, STATUS_DELETED)
    assert_equal(Int(table.manifests[3].min_sequence_number), 5)
    assert_equal(table.snapshots[4].added_data_files, 0)


def test_create_writes_a_table_with_no_snapshot() raises:
    var table = _new_table("empty")
    table.create()
    assert_true(_exists(table, "metadata/v1.metadata.json"))
    assert_equal(_text(table, "metadata/version-hint.text"), "1")
    var json = _text(table, "metadata/v1.metadata.json")
    assert_true(_has(json, '"current-snapshot-id" : -1,'), json)
    assert_true(_has(json, '"refs" : { },'), json)
    assert_equal(len(table.snapshots), 0)
    var files = List[TestDataFile]()
    files.append(_data_file("f1", 1, 1))
    _ = table.append(files)
    assert_true(_exists(table, "metadata/v2.metadata.json"))
    assert_equal(_text(table, "metadata/version-hint.text"), "2")


def test_refusals() raises:
    var by = List[String]()
    by.append("nope")
    var message = String()
    try:
        _ = TestTable(test_tmpdir() + "/table_refusals", "file:///w/r", _columns(), by)
    except e:
        message = String(e)
    assert_equal(message, "TestTable: the partition column nope is not a column of the table")

    var table = _new_table("refusals")
    assert_equal(_append_error(table, List[TestDataFile]()), "TestTable.append: no data file")
    var with_partition = List[TestDataFile]()
    var partition = List[TableCell]()
    partition.append(string_cell("x"))
    var base = _data_file("f0", 1, 1)
    with_partition.append(TestDataFile("f0", partition^, base.rows.copy()))
    assert_equal(
        _append_error(table, with_partition),
        "TestTable: a partition tuple of 1 cells for 0 partition columns",
    )
    var twice = List[TestDataFile]()
    twice.append(_data_file("f1", 1, 1))
    twice.append(_data_file("f1", 2, 1))
    assert_equal(_append_error(table, twice), "TestTable: the file name f1 is used twice")

    var one = List[TestDataFile]()
    one.append(_data_file("g1", 1, 1))
    one.append(_data_file("g2", 2, 1))
    _ = table.append(one)
    var no_deletes = List[PositionDelete]()
    var no_delete_error = String()
    try:
        _ = table.add_position_deletes("pd", List[TableCell](), no_deletes)
    except e:
        no_delete_error = String(e)
    assert_equal(no_delete_error, "TestTable.add_position_deletes: no delete")
    var unknown = List[PositionDelete]()
    unknown.append(PositionDelete("nope", 0))
    var unknown_error = String()
    try:
        _ = table.add_position_deletes("pd", List[TableCell](), unknown)
    except e:
        unknown_error = String(e)
    assert_equal(unknown_error, "TestTable: no data file called nope")
    var two_files = List[PositionDelete]()
    two_files.append(PositionDelete("g1", 0))
    two_files.append(PositionDelete("g2", 0))
    var referenced_error = String()
    try:
        _ = table.add_position_deletes("pd", List[TableCell](), two_files, "PARQUET", True)
    except e:
        referenced_error = String(e)
    assert_equal(
        referenced_error,
        "TestTable.add_position_deletes: referenced needs deletes of one data file",
    )

    var empty_rows = List[TableRow]()
    var no_columns = List[String]()
    var eq_error = String()
    try:
        _ = table.add_equality_deletes("eq", List[TableCell](), no_columns, empty_rows)
    except e:
        eq_error = String(e)
    assert_equal(eq_error, "TestTable.add_equality_deletes: no column or no row")
    var bad_columns = List[String]()
    bad_columns.append("nope")
    var rows = List[TableRow]()
    var key = List[TableCell]()
    key.append(int_cell(1))
    rows.append(TableRow(key^))
    var bad_error = String()
    try:
        _ = table.add_equality_deletes("eq", List[TableCell](), bad_columns, rows)
    except e:
        bad_error = String(e)
    assert_equal(bad_error, "TestTable.add_equality_deletes: nope is not a column of the table")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
