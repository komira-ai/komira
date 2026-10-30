# The seeded h2o-style join generator: the four tables x, small, medium and big.
#
#   * test_every_table_writes_the_same_bytes_for_the_same_seed: two runs give
#     equal bytes for each table; another seed gives different bytes.
#   * test_a_file_holds_exactly_the_rows_the_batch_builder_defines: each
#     table's file decoded by komira_parquet has the table's row count and the
#     cells of the table built directly, in one batch and in many.
#   * test_table_sizes_follow_the_x_size: x and big have N rows, small N // 1e6
#     and medium N // 1e3, each at least 1.
#   * test_every_x_key_has_a_partner: with N = 3,000,000, small holds each of
#     the keys 1..3 once and medium each of 1..3000 once, and x and big keys
#     stay inside those ranges, with the string columns spelling the integers.
#   * test_big_holds_distinct_keys_in_its_unique_column: id3 of any rows of big
#     are pairwise different and inside 1..N.
#   * test_a_row_is_the_same_in_every_batch: rows built alone equal the same
#     rows of the whole table, for all four tables.
#   * test_refusals: an unknown table, rows below 1, a row range outside the
#     table, a batch size below 1.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_parquet.bytes_decode import decode_row_group_from_bytes, row_group_byte_range
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.metadata import FileMetaData

from komira_bench_data import (
    H2O_DEFAULT_SEED,
    h2o_join_batch,
    h2o_join_parquet,
    h2o_join_table_names,
    h2o_join_table_rows,
)

comptime _SEED: UInt64 = H2O_DEFAULT_SEED


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


def _read_rg(file: List[UInt8], md: FileMetaData, g: Int) raises -> RecordBatch:
    ref rg = md.row_groups[g]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _row_text(b: RecordBatch, i: Int) raises -> String:
    """Every cell of row `i`, joined with '|' (nulls shown as NULL)."""
    var out = String()
    for c in range(b.num_columns()):
        if c > 0:
            out += "|"
        if b.column_at(c).is_null_at(i):
            out += "NULL"
        elif b.column_at(c).arrow_type == ArrowType.STRING:
            out += b.column_at(c).as_string().get(i)
        elif b.column_at(c).arrow_type == ArrowType.INT32:
            out += String(b.column_at(c).as_primitive[DType.int32]().get(i))
        else:
            out += String(b.column_at(c).as_primitive[DType.float64]().get(i))
    return out^


def _file_rows(file: List[UInt8]) raises -> List[String]:
    var md = _footer(file)
    var rows = List[String]()
    for g in range(len(md.row_groups)):
        var b = _read_rg(file, md, g)
        for i in range(b.num_rows()):
            rows.append(_row_text(b, i))
    return rows^


def _batch_rows(b: RecordBatch) raises -> List[String]:
    var rows = List[String]()
    for i in range(b.num_rows()):
        rows.append(_row_text(b, i))
    return rows^


def _int(b: RecordBatch, c: Int, i: Int) raises -> Int:
    return Int(b.column_at(c).as_primitive[DType.int32]().get(i))


def test_every_table_writes_the_same_bytes_for_the_same_seed() raises:
    var tables = h2o_join_table_names()
    assert_equal(len(tables), 4)
    for t in range(len(tables)):
        var a = h2o_join_parquet(tables[t], 2000, _SEED)
        var b = h2o_join_parquet(tables[t], 2000, _SEED)
        assert_true(len(a) > 8)
        assert_true(_same(a, b), tables[t] + ": two runs wrote different bytes")
        assert_false(_same(a, h2o_join_parquet(tables[t], 2000, _SEED + 1)), tables[t])


def test_a_file_holds_exactly_the_rows_the_batch_builder_defines() raises:
    var tables = h2o_join_table_names()
    for t in range(len(tables)):
        var name = tables[t]
        var want = _batch_rows(h2o_join_batch(name, 2000, _SEED, 0, h2o_join_table_rows(name, 2000)))
        var one = _file_rows(h2o_join_parquet(name, 2000, _SEED))
        var many = _file_rows(h2o_join_parquet(name, 2000, _SEED, batch_rows=300))
        assert_equal(len(one), len(want), name)
        assert_equal(len(many), len(want), name)
        for r in range(len(want)):
            assert_equal(one[r], want[r], name + " row " + String(r))
            assert_equal(many[r], want[r], name + " row " + String(r) + " (300-row batches)")


def test_table_sizes_follow_the_x_size() raises:
    assert_equal(h2o_join_table_rows("x", 10_000_000), 10_000_000)
    assert_equal(h2o_join_table_rows("big", 10_000_000), 10_000_000)
    assert_equal(h2o_join_table_rows("small", 10_000_000), 10)
    assert_equal(h2o_join_table_rows("medium", 10_000_000), 10_000)
    assert_equal(h2o_join_table_rows("small", 5), 1)
    assert_equal(h2o_join_table_rows("medium", 5), 1)
    assert_equal(h2o_join_batch("small", 5, _SEED, 0, 1).num_rows(), 1)
    var files = _file_rows(h2o_join_parquet("medium", 5000, _SEED))
    assert_equal(len(files), 5)


def _check_wide(b: RecordBatch, n: Int) raises:
    for i in range(b.num_rows()):
        var k1 = _int(b, 0, i)
        var k2 = _int(b, 1, i)
        var k3 = _int(b, 2, i)
        assert_true(k1 >= 1 and k1 <= 3)
        assert_true(k2 >= 1 and k2 <= 3000)
        assert_true(k3 >= 1 and k3 <= n)
        assert_equal(b.column_at(3).as_string().get(i), "id" + String(k1))
        assert_equal(b.column_at(4).as_string().get(i), "id" + String(k2))
        assert_equal(b.column_at(5).as_string().get(i), "id" + String(k3))
        var v = b.column_at(6).as_primitive[DType.float64]().get(i)
        assert_true(v >= 0.0 and v <= 100.0)


def test_every_x_key_has_a_partner() raises:
    var n = 3_000_000
    var small = h2o_join_batch("small", n, _SEED, 0, 3)
    var seen_small = List[Bool]()
    for _ in range(4):
        seen_small.append(False)
    for i in range(3):
        var key = _int(small, 0, i)
        assert_true(key >= 1 and key <= 3)
        assert_false(seen_small[key])
        seen_small[key] = True
        assert_equal(small.column_at(1).as_string().get(i), "id" + String(key))

    var medium = h2o_join_batch("medium", n, _SEED, 0, 3000)
    var seen_medium = List[Bool]()
    for _ in range(3001):
        seen_medium.append(False)
    for i in range(3000):
        var key = _int(medium, 1, i)
        assert_true(key >= 1 and key <= 3000)
        assert_false(seen_medium[key])
        seen_medium[key] = True
        var k1 = _int(medium, 0, i)
        assert_true(k1 >= 1 and k1 <= 3)
        assert_equal(medium.column_at(2).as_string().get(i), "id" + String(k1))
        assert_equal(medium.column_at(3).as_string().get(i), "id" + String(key))

    var x = h2o_join_batch("x", n, _SEED, 0, 2000)
    var big = h2o_join_batch("big", n, _SEED, 0, 2000)
    _check_wide(x, n)
    _check_wide(big, n)


def test_big_holds_distinct_keys_in_its_unique_column() raises:
    var n = 3_000_000
    var rows = 4000
    var big = h2o_join_batch("big", n, _SEED, 1_000_000, rows)
    var keys = List[Int]()
    for i in range(rows):
        keys.append(_int(big, 2, i))
    # Sort-free distinctness: a table of the keys seen, by key.
    var seen = List[Bool]()
    for _ in range(n + 1):
        seen.append(False)
    for i in range(rows):
        assert_true(keys[i] >= 1 and keys[i] <= n)
        assert_false(seen[keys[i]], "key " + String(keys[i]) + " repeats")
        seen[keys[i]] = True


def test_a_row_is_the_same_in_every_batch() raises:
    var tables = h2o_join_table_names()
    for t in range(len(tables)):
        var name = tables[t]
        var total = h2o_join_table_rows(name, 2000)
        var whole = _batch_rows(h2o_join_batch(name, 2000, _SEED, 0, total))
        var from_row = total // 2
        var part = _batch_rows(h2o_join_batch(name, 2000, _SEED, from_row, total - from_row))
        for i in range(len(part)):
            assert_equal(part[i], whole[from_row + i], name)


def test_refusals() raises:
    with assert_raises(contains="no table 'huge'"):
        _ = h2o_join_table_rows("huge", 10)
    with assert_raises(contains="no table 'huge'"):
        _ = h2o_join_batch("huge", 10, _SEED, 0, 1)
    with assert_raises(contains="rows must be at least 1"):
        _ = h2o_join_batch("x", 0, _SEED, 0, 0)
    with assert_raises(contains="outside the 10 rows of x"):
        _ = h2o_join_batch("x", 10, _SEED, 5, 6)
    with assert_raises(contains="outside the 1 rows of small"):
        _ = h2o_join_batch("small", 10, _SEED, 0, 2)
    with assert_raises(contains="rows must be in"):
        _ = h2o_join_parquet("x", 0, _SEED)
    with assert_raises(contains="batch_rows must be at least 1"):
        _ = h2o_join_parquet("x", 10, _SEED, batch_rows=0)


def main() raises:
    test_every_table_writes_the_same_bytes_for_the_same_seed()
    test_a_file_holds_exactly_the_rows_the_batch_builder_defines()
    test_table_sizes_follow_the_x_size()
    test_every_x_key_has_a_partner()
    test_big_holds_distinct_keys_in_its_unique_column()
    test_a_row_is_the_same_in_every_batch()
    test_refusals()
    print("OK")
