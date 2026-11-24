# The `orders` fixture of the Iceberg scan conformance.
#
#   * test_orders_writes_exactly_the_files_it_lists: the files under the root
#     are, as a set, `orders_files()`: the list a build rule names as the
#     outputs of the program that writes the table.
#   * test_orders_has_six_snapshots_in_the_order_the_cases_expect: ids
#     6000000001 to 6000000006, the operations, the version hint, the current
#     snapshot and the location the manifests record.
#   * test_orders_data_files_hold_the_rows_the_cases_expect: the east file a1
#     (a NaN price, a null note) and the west file b2 read back, and the
#     bounds and counts of a1 in its manifest entry.
#   * test_orders_files_are_the_ones_a_delete_applies_to: the position delete
#     names a1 and a2, the equality delete is of order_id with ids [1], the
#     delete manifests come before the data manifests of older commits.

from std.os import listdir
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.record_batch import RecordBatch
from byte_buffer.byte_view import ByteView
from parquet.bytes_decode import decode_row_group_from_bytes, row_group_byte_range
from parquet.metadata_parser import parse_full_metadata
from parquet.morsel_reader import ColumnProjection
from parquet_api.metadata import FileMetaData
from runtime_paths import test_tmpdir

from komira_iceberg_test_tables.orders_fixture import (
    ORDERS_LOCATION,
    orders_columns,
    orders_files,
    write_orders_fixture,
)
from komira_iceberg_test_tables.table_model import (
    CONTENT_EQUALITY_DELETES,
    CONTENT_POSITION_DELETES,
    STATUS_ADDED,
    STATUS_DELETED,
    STATUS_EXISTING,
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


def _walk(root: String, rel: String, mut out: List[String]) raises:
    """Every file under `root/rel`, as a path under `root`."""
    var dir = root.copy()
    if rel.byte_length() > 0:
        dir = root + "/" + rel
    var names = listdir(dir)
    for i in range(len(names)):
        var child = String(names[i])
        if rel.byte_length() > 0:
            child = rel + "/" + String(names[i])
        if Path(root + "/" + child).is_dir():
            _walk(root, child, out)
        else:
            out.append(child)


def _contains(list: List[String], item: String) -> Bool:
    for i in range(len(list)):
        if list[i] == item:
            return True
    return False


def test_orders_writes_exactly_the_files_it_lists() raises:
    var root = test_tmpdir() + "/orders_files"
    _ = write_orders_fixture(root)
    var found = List[String]()
    _walk(root, "", found)
    var listed = orders_files()
    assert_equal(len(listed), 28)
    assert_equal(len(found), len(listed))
    for i in range(len(listed)):
        assert_true(_contains(found, listed[i]), listed[i] + " was not written")
    for i in range(len(found)):
        assert_true(_contains(listed, found[i]), found[i] + " is not listed")


def test_orders_has_six_snapshots_in_the_order_the_cases_expect() raises:
    var root = test_tmpdir() + "/orders_snapshots"
    var table = write_orders_fixture(root)
    assert_equal(len(table.snapshots), 6)
    for i in range(6):
        assert_equal(Int(table.snapshots[i].snapshot_id), 6000000001 + i)
        assert_equal(Int(table.snapshots[i].sequence_number), i + 1)
    assert_equal(table.snapshots[0].operation, "append")
    assert_equal(table.snapshots[2].operation, "overwrite")
    assert_equal(table.snapshots[5].operation, "overwrite")
    assert_equal(Path(root + "/metadata/version-hint.text").read_text(), "6")
    assert_equal(len(orders_columns()), 7)
    var json = Path(root + "/metadata/v6.metadata.json").read_text()
    assert_true(json.find('"location" : "' + String(ORDERS_LOCATION) + '",') >= 0, json)
    assert_true(json.find('"current-snapshot-id" : 6000000006,') >= 0, json)
    assert_true(json.find('"last-sequence-number" : 6,') >= 0, json)


def test_orders_data_files_hold_the_rows_the_cases_expect() raises:
    var root = test_tmpdir() + "/orders_rows"
    var table = write_orders_fixture(root)
    var a1 = _read_parquet(root + "/data/region=east/a1.parquet")
    assert_equal(a1.num_rows(), 4)
    assert_equal(a1.schema.field_name(6), "note")
    assert_equal(Int(a1.column_at(0).as_primitive[DType.int64]().get(3)), 4)
    var price = a1.column_at(3).as_primitive[DType.float64]().get(3)
    assert_true(price != price)
    assert_true(a1.column_at(6).is_null_at(1))
    assert_equal(Int(a1.column_at(4).as_primitive[DType.int32]().get(0)), 20823)
    var b2 = _read_parquet(root + "/data/region=west/b2.parquet")
    assert_equal(b2.num_rows(), 2)
    assert_equal(b2.column_at(2).as_string().get(1), "west")
    # a1's metrics: order_id 1..4, one NaN price, two null notes.
    ref entry_file = table.files[0]
    assert_equal(entry_file.name, "a1")
    assert_equal(Int(entry_file.metrics[0].value_count), 4)
    assert_equal(Int(entry_file.metrics[3].nan_count), 1)
    assert_equal(Int(entry_file.metrics[6].null_count), 2)
    assert_equal(Int(entry_file.metrics[0].lower[0]), 1)
    assert_equal(Int(entry_file.metrics[0].upper[0]), 4)
    assert_equal(Int(entry_file.metrics[1].upper[0]), 40)


def test_orders_files_are_the_ones_a_delete_applies_to() raises:
    var root = test_tmpdir() + "/orders_deletes"
    var table = write_orders_fixture(root)
    # Files in commit order: a1, b1, n1, a2, pos_del_1, eq_del_1, a3, b2.
    assert_equal(table.files[4].name, "pos_del_1")
    assert_equal(table.files[4].content, CONTENT_POSITION_DELETES)
    assert_equal(table.files[5].name, "eq_del_1")
    assert_equal(table.files[5].content, CONTENT_EQUALITY_DELETES)
    assert_equal(table.files[5].equality_ids[0], 1)
    var pos = _read_parquet(root + "/data/region=east/pos_del_1.parquet")
    assert_equal(pos.num_rows(), 2)
    assert_equal(
        pos.column_at(0).as_string().get(0),
        "file:///warehouse/db/orders/data/region=east/a1.parquet",
    )
    assert_equal(Int(pos.column_at(1).as_primitive[DType.int64]().get(0)), 1)
    assert_equal(
        pos.column_at(0).as_string().get(1),
        "file:///warehouse/db/orders/data/region=east/a2.parquet",
    )
    assert_equal(Int(pos.column_at(1).as_primitive[DType.int64]().get(1)), 2)
    var eq = _read_parquet(root + "/data/region=east/eq_del_1.parquet")
    assert_equal(eq.num_rows(), 2)
    assert_equal(Int(eq.column_at(0).as_primitive[DType.int64]().get(0)), 3)
    assert_equal(Int(eq.column_at(0).as_primitive[DType.int64]().get(1)), 6)
    # The last snapshot lists: b2's manifest, a3's, the equality-delete and the
    # position-delete manifests, a2's, then the rewritten first one.
    assert_equal(len(table.manifests), 6)
    assert_equal(table.files[table.manifests[0].entries[0].file_index].name, "b2")
    assert_equal(table.manifests[1].content, 0)
    assert_equal(table.manifests[2].content, 1)
    assert_equal(table.manifests[3].content, 1)
    var rewritten = table.manifests[5].copy()
    assert_equal(len(rewritten.entries), 3)
    assert_equal(table.files[rewritten.entries[0].file_index].name, "a1")
    assert_equal(rewritten.entries[0].status, STATUS_EXISTING)
    assert_equal(table.files[rewritten.entries[1].file_index].name, "b1")
    assert_equal(rewritten.entries[1].status, STATUS_DELETED)
    assert_equal(rewritten.entries[2].status, STATUS_EXISTING)
    assert_equal(table.manifests[0].entries[0].status, STATUS_ADDED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
