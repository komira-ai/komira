# =============================================================================
# orders_fixture.mojo -- the table `orders` of the Iceberg scan conformance.
# =============================================================================
#
# Seven columns (order_id long, qty int, region string, price double with a
# NaN, ship_date date in 2027, paid boolean, note string with nulls),
# partitioned by the identity of region, written in six commits:
#
#   1  append    a1 (east, 4 rows), b1 (west, 3), n1 (north, 3)
#   2  append    a2 (east, 3)
#   3  position deletes (east): a1 position 1 (order 2), a2 position 2 (order 7)
#   4  equality deletes (east) on order_id: 3 and 6; they apply to a1 and a2
#                (older), not to a file added after them
#   5  append    a3 (east, 2): order 3 again, which the equality delete (older)
#                leaves alone, and order 8
#   6  overwrite removes b1 (its manifest is rewritten, the file DELETED) and
#                adds b2 (west, 2)
#
# The live rows are orders 1 and 4 (a1), 5 (a2), 3 and 8 (a3), 11 and 14 (b2),
# 21 to 23 (n1): ten. The table as of commit 2 has thirteen. The files are
# recorded under `ORDERS_LOCATION`, which is not where they are written.
# =============================================================================

from std.math import nan

from .table_model import (
    TableCell,
    TableColumn,
    TableRow,
    TT_BOOLEAN,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    bool_cell,
    double_cell,
    int_cell,
    null_cell,
    string_cell,
)
from .test_table import PositionDelete, TestDataFile, TestTable

comptime ORDERS_LOCATION: String = "file:///warehouse/db/orders"

# 2027-01-01 as days since the Unix epoch.
comptime ORDERS_FIRST_DAY: Int = 20819


def orders_columns() -> List[TableColumn]:
    """The seven columns of `orders`; every one but `note` is required."""
    var out = List[TableColumn]()
    out.append(TableColumn(1, "order_id", TT_LONG, True))
    out.append(TableColumn(2, "qty", TT_INT, True))
    out.append(TableColumn(3, "region", TT_STRING, True))
    out.append(TableColumn(4, "price", TT_DOUBLE, True))
    out.append(TableColumn(5, "ship_date", TT_DATE, True))
    out.append(TableColumn(6, "paid", TT_BOOLEAN, True))
    out.append(TableColumn(7, "note", TT_STRING, False))
    return out^


def _order(
    order_id: Int,
    qty: Int,
    region: String,
    price: Float64,
    day: Int,
    paid: Bool,
    note: String,
) -> TableRow:
    """A row; `day` counts from 2027-01-01 and an empty `note` is a null."""
    var cells = List[TableCell]()
    cells.append(int_cell(order_id))
    cells.append(int_cell(qty))
    cells.append(string_cell(region))
    cells.append(double_cell(price))
    cells.append(int_cell(ORDERS_FIRST_DAY + day))
    cells.append(bool_cell(paid))
    if note.byte_length() == 0:
        cells.append(null_cell())
    else:
        cells.append(string_cell(note))
    return TableRow(cells^)


def _partition(region: String) -> List[TableCell]:
    var cells = List[TableCell]()
    cells.append(string_cell(region))
    return cells^


def _file(name: String, region: String, var rows: List[TableRow]) -> TestDataFile:
    return TestDataFile(name.copy(), _partition(region), rows^)


def write_orders_fixture(root: String) raises -> TestTable:
    """Writes `orders` under `root` and returns the table (its snapshot ids
    are `snapshot_id(1)` to `snapshot_id(6)`)."""
    var partition_by = List[String]()
    partition_by.append("region")
    var table = TestTable(
        root.copy(), String(ORDERS_LOCATION), orders_columns(), partition_by
    )

    var a1 = List[TableRow]()
    a1.append(_order(1, 10, "east", 9.5, 4, True, "first"))
    a1.append(_order(2, 20, "east", 19.25, 5, False, ""))
    a1.append(_order(3, 30, "east", 3.0, 40, True, "third"))
    a1.append(_order(4, 40, "east", nan[DType.float64](), 41, True, ""))
    var b1 = List[TableRow]()
    b1.append(_order(11, 5, "west", 1.5, 59, False, "w-one"))
    b1.append(_order(12, 15, "west", 2.5, 60, True, ""))
    b1.append(_order(13, 25, "west", 3.5, 61, False, "w-three"))
    var n1 = List[TableRow]()
    n1.append(_order(21, 110, "north", 21.5, 181, True, "n-one"))
    n1.append(_order(22, 120, "north", 22.5, 182, False, ""))
    n1.append(_order(23, 130, "north", 23.5, 183, True, "n-three"))
    var first = List[TestDataFile]()
    first.append(_file("a1", "east", a1^))
    first.append(_file("b1", "west", b1^))
    first.append(_file("n1", "north", n1^))
    _ = table.append(first)

    var a2 = List[TableRow]()
    a2.append(_order(5, 50, "east", 50.0, 90, True, "fifth"))
    a2.append(_order(6, 60, "east", 6.5, 91, False, "sixth"))
    a2.append(_order(7, 70, "east", 7.75, 92, True, ""))
    var second = List[TestDataFile]()
    second.append(_file("a2", "east", a2^))
    _ = table.append(second)

    var positions = List[PositionDelete]()
    positions.append(PositionDelete("a1", 1))
    positions.append(PositionDelete("a2", 2))
    _ = table.add_position_deletes("pos_del_1", _partition("east"), positions)

    var keys = List[TableRow]()
    var key3 = List[TableCell]()
    key3.append(int_cell(3))
    keys.append(TableRow(key3^))
    var key6 = List[TableCell]()
    key6.append(int_cell(6))
    keys.append(TableRow(key6^))
    var key_columns = List[String]()
    key_columns.append("order_id")
    _ = table.add_equality_deletes("eq_del_1", _partition("east"), key_columns, keys)

    var a3 = List[TableRow]()
    a3.append(_order(3, 33, "east", 33.0, 120, False, "third again"))
    a3.append(_order(8, 80, "east", 8.0, 121, True, "eighth"))
    var third = List[TestDataFile]()
    third.append(_file("a3", "east", a3^))
    _ = table.append(third)

    var b2 = List[TableRow]()
    b2.append(_order(11, 6, "west", 1.5, 59, True, "w-one-v2"))
    b2.append(_order(14, 35, "west", 5.5, 151, False, ""))
    var replaced = List[String]()
    replaced.append("b1")
    var added = List[TestDataFile]()
    added.append(_file("b2", "west", b2^))
    _ = table.overwrite(replaced, added)
    return table^


def orders_files() -> List[String]:
    """The files `write_orders_fixture` writes, as paths under its root, in
    the order the table version, manifest lists and manifests are written."""
    var out = List[String]()
    for v in range(1, 7):
        out.append("metadata/v" + String(v) + ".metadata.json")
    out.append("metadata/version-hint.text")
    var lists = List[String]()
    lists.append("metadata/snap-6000000001-1-a1b2c3d4-0000-4000-8000-000000000101.avro")
    lists.append("metadata/snap-6000000002-1-a1b2c3d4-0000-4000-8000-000000000102.avro")
    lists.append("metadata/snap-6000000003-1-a1b2c3d4-0000-4000-8000-000000000103.avro")
    lists.append("metadata/snap-6000000004-1-a1b2c3d4-0000-4000-8000-000000000104.avro")
    lists.append("metadata/snap-6000000005-1-a1b2c3d4-0000-4000-8000-000000000105.avro")
    lists.append("metadata/snap-6000000006-1-a1b2c3d4-0000-4000-8000-000000000106.avro")
    for i in range(len(lists)):
        out.append(lists[i].copy())
    for m in range(1, 8):
        out.append("metadata/a1b2c3d4-0000-4000-8000-00000000000" + String(m) + "-m0.avro")
    out.append("data/region=east/a1.parquet")
    out.append("data/region=west/b1.parquet")
    out.append("data/region=north/n1.parquet")
    out.append("data/region=east/a2.parquet")
    out.append("data/region=east/pos_del_1.parquet")
    out.append("data/region=east/eq_del_1.parquet")
    out.append("data/region=east/a3.parquet")
    out.append("data/region=west/b2.parquet")
    return out^
