# The seeded h2o-style group-by generator and the number source under it.
#
#   * test_mix64_matches_the_published_splitmix64_outputs: the first two
#     outputs of SplitMix64 from state 0, so the constants and shifts are the
#     published ones.
#   * test_draws_depend_on_seed_stream_and_row_and_stay_in_range.
#   * test_draw_values_are_pinned: literal draws, ranges and scores for seed
#     123, so a change to the mixer, the stream multiplier or a range modulus
#     shows even when the expected rows are computed from the same functions.
#   * test_a_bijection_visits_every_key_once: for sizes with many and few
#     coprime multipliers and for several seeds, rows 0..n-1 map onto 1..n.
#   * test_the_same_seed_and_size_write_the_same_bytes: two runs give equal
#     bytes; another seed, another row count, another group count and another
#     codec give different bytes; the file is a Parquet file.
#   * test_a_file_holds_exactly_the_rows_the_seed_defines: the file decoded by
#     komira_parquet has the nine columns with their types, 1000 rows, and every
#     cell is the value the stream defines, whether the table was built in one
#     batch or in many.
#   * test_values_stay_in_their_ranges_and_cover_the_groups: id1..id6 within
#     their ranges, all k groups of id1 appear, v1 and v2 in 1..5, v3 in
#     0..100, no nulls.
#   * test_a_row_is_the_same_in_every_batch: rows 500..509 built alone equal
#     rows 500..509 of the whole table.
#   * test_one_group_and_id3_range_edges: k equal to rows leaves one id3 value.
#   * test_refusals: group count outside 1..rows, rows below 1, a row range
#     outside the table, a batch size below 1.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_parquet.bytes_decode import decode_row_group_from_bytes, row_group_byte_range
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import CompressionCodec

from komira_bench_data import (
    Bijection,
    H2O_DEFAULT_SEED,
    draw,
    draw_range,
    draw_score,
    h2o_groupby_batch,
    h2o_groupby_parquet,
    mix64,
)
from komira_bench_data.draw import padded_id

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


def _expected_row(seed: UInt64, rows: Int, k: Int, r: Int) -> String:
    var n3 = rows // k if rows // k > 1 else 1
    return (
        padded_id(draw_range(seed, 1, r, k), 3)
        + "|"
        + padded_id(draw_range(seed, 2, r, k), 3)
        + "|"
        + padded_id(draw_range(seed, 3, r, n3), 10)
        + "|"
        + String(Int32(draw_range(seed, 4, r, k)))
        + "|"
        + String(Int32(draw_range(seed, 5, r, k)))
        + "|"
        + String(Int32(draw_range(seed, 6, r, n3)))
        + "|"
        + String(Int32(draw_range(seed, 7, r, 5)))
        + "|"
        + String(Int32(draw_range(seed, 8, r, 5)))
        + "|"
        + String(draw_score(seed, 9, r))
    )


def test_mix64_matches_the_published_splitmix64_outputs() raises:
    assert_equal(mix64(0), UInt64(0xE220A8397B1DCDAF))
    assert_equal(mix64(0x9E3779B97F4A7C15), UInt64(0x6E789E6AA1B965F4))


def test_draws_depend_on_seed_stream_and_row_and_stay_in_range() raises:
    var base = draw(1, 2, 3)
    assert_true(draw(2, 2, 3) != base)
    assert_true(draw(1, 3, 3) != base)
    assert_true(draw(1, 2, 4) != base)
    assert_equal(draw(1, 2, 3), base)
    for r in range(2000):
        var v = draw_range(_SEED, 1, r, 7)
        assert_true(v >= 1 and v <= 7)
        var s = draw_score(_SEED, 2, r)
        assert_true(s >= 0.0 and s <= 100.0)
        assert_equal(draw_range(_SEED, 3, r, 1), 1)


def test_draw_values_are_pinned() raises:
    assert_equal(draw(123, 1, 0), UInt64(0x6D6463CBFA18074B))
    assert_equal(draw(123, 1, 1), UInt64(0xA4E9525FE38FD21C))
    assert_equal(draw(123, 2, 7), UInt64(0x99DEF1055E43D463))
    assert_equal(draw(123, 3, 999), UInt64(0xECAC5149E3A63784))
    assert_equal(draw_range(123, 1, 0, 1000), 268)
    assert_equal(draw_range(123, 1, 1, 1000), 573)
    assert_equal(draw_range(123, 2, 7, 1000), 924)
    assert_equal(draw_range(123, 3, 999, 1000), 413)
    assert_equal(draw_score(123, 1, 0), 5.2513)
    assert_equal(draw_score(123, 1, 1), 55.793125)
    assert_equal(draw_score(123, 2, 7), 15.731652)
    assert_equal(draw_score(123, 3, 999), 98.058451)


def test_a_bijection_visits_every_key_once() raises:
    var sizes: List[Int] = [1, 2, 3, 4, 6, 7, 10, 12, 30, 97, 100, 1000, 1024, 4096]
    var seeds: List[UInt64] = [0, 1, _SEED, 0xFFFFFFFFFFFFFFFF]
    for si in range(len(sizes)):
        for sd in range(len(seeds)):
            var n = sizes[si]
            var bj = Bijection(seeds[sd], 30, n)
            var seen = List[Bool]()
            for _ in range(n + 1):
                seen.append(False)
            for row in range(n):
                var key = bj.key(row)
                assert_true(key >= 1 and key <= n, "n=" + String(n) + " key " + String(key))
                assert_false(seen[key], "n=" + String(n) + " repeats key " + String(key))
                seen[key] = True


def test_the_same_seed_and_size_write_the_same_bytes() raises:
    var a = h2o_groupby_parquet(1000, 10, _SEED)
    var b = h2o_groupby_parquet(1000, 10, _SEED)
    assert_true(len(a) > 8)
    assert_equal(len(a), len(b))
    assert_true(_same(a, b), "two runs wrote different bytes")
    assert_equal(a[0], UInt8(ord("P")))
    assert_equal(a[3], UInt8(ord("1")))
    assert_equal(a[len(a) - 1], UInt8(ord("1")))
    assert_false(_same(a, h2o_groupby_parquet(1000, 10, _SEED + 1)))
    assert_false(_same(a, h2o_groupby_parquet(999, 10, _SEED)))
    assert_false(_same(a, h2o_groupby_parquet(1000, 11, _SEED)))
    assert_false(_same(a, h2o_groupby_parquet(1000, 10, _SEED, CompressionCodec.UNCOMPRESSED)))
    # One batch of 1000 and a batch size of 1000 are the same table, bytes included.
    assert_true(_same(a, h2o_groupby_parquet(1000, 10, _SEED, batch_rows=1000)))


def test_a_file_holds_exactly_the_rows_the_seed_defines() raises:
    var file = h2o_groupby_parquet(1000, 10, _SEED)
    var md = _footer(file)
    assert_equal(len(md.schema), 10)
    var names: List[String] = ["id1", "id2", "id3", "id4", "id5", "id6", "v1", "v2", "v3"]
    for c in range(9):
        assert_equal(md.schema[c + 1].name, names[c])
    var first = _read_rg(file, md, 0)
    assert_true(first.column_at(0).arrow_type == ArrowType.STRING)
    assert_true(first.column_at(3).arrow_type == ArrowType.INT32)
    assert_true(first.column_at(8).arrow_type == ArrowType.FLOAT64)
    var one_batch = _file_rows(file)
    var many_batches = _file_rows(h2o_groupby_parquet(1000, 10, _SEED, batch_rows=128))
    assert_equal(len(one_batch), 1000)
    assert_equal(len(many_batches), 1000)
    for r in range(1000):
        var want = _expected_row(_SEED, 1000, 10, r)
        assert_equal(one_batch[r], want, "row " + String(r))
        assert_equal(many_batches[r], want, "row " + String(r) + " (128-row batches)")


def test_values_stay_in_their_ranges_and_cover_the_groups() raises:
    var rows = 5000
    var k = 10
    var n3 = rows // k
    var b = h2o_groupby_batch(rows, k, _SEED, 0, rows)
    assert_equal(b.num_rows(), rows)
    var seen = List[Bool]()
    for _ in range(k + 1):
        seen.append(False)
    for i in range(rows):
        for c in range(9):
            assert_false(b.column_at(c).is_null_at(i))
        var id1 = b.column_at(0).as_string().get(i)
        assert_equal(id1.byte_length(), 5)
        assert_true(id1.startswith("id"))
        var g = atol(String(id1[byte=2:]))
        assert_true(g >= 1 and g <= k)
        seen[g] = True
        var id3 = atol(String(b.column_at(2).as_string().get(i)[byte=2:]))
        assert_true(id3 >= 1 and id3 <= n3)
        var id4 = Int(b.column_at(3).as_primitive[DType.int32]().get(i))
        var id5 = Int(b.column_at(4).as_primitive[DType.int32]().get(i))
        var id6 = Int(b.column_at(5).as_primitive[DType.int32]().get(i))
        assert_true(id4 >= 1 and id4 <= k and id5 >= 1 and id5 <= k)
        assert_true(id6 >= 1 and id6 <= n3)
        var v1 = Int(b.column_at(6).as_primitive[DType.int32]().get(i))
        var v2 = Int(b.column_at(7).as_primitive[DType.int32]().get(i))
        assert_true(v1 >= 1 and v1 <= 5 and v2 >= 1 and v2 <= 5)
        var v3 = b.column_at(8).as_primitive[DType.float64]().get(i)
        assert_true(v3 >= 0.0 and v3 <= 100.0)
    for g in range(1, k + 1):
        assert_true(seen[g], "group " + String(g) + " never appears")


def test_a_row_is_the_same_in_every_batch() raises:
    var whole = _batch_rows(h2o_groupby_batch(1000, 10, _SEED, 0, 1000))
    var part = _batch_rows(h2o_groupby_batch(1000, 10, _SEED, 500, 10))
    assert_equal(len(part), 10)
    for i in range(10):
        assert_equal(part[i], whole[500 + i])


def test_one_group_and_id3_range_edges() raises:
    var rows = _batch_rows(h2o_groupby_batch(5, 5, _SEED, 0, 5))
    for i in range(5):
        assert_true(rows[i].find("|id0000000001|") >= 0, rows[i])
    var single = _batch_rows(h2o_groupby_batch(20, 1, _SEED, 0, 20))
    for i in range(20):
        assert_true(single[i].startswith("id001|id001|"), single[i])


def test_refusals() raises:
    with assert_raises(contains="groups must be in"):
        _ = h2o_groupby_batch(10, 0, _SEED, 0, 10)
    with assert_raises(contains="groups must be in"):
        _ = h2o_groupby_batch(10, 11, _SEED, 0, 10)
    with assert_raises(contains="outside 0..10"):
        _ = h2o_groupby_batch(10, 2, _SEED, 5, 6)
    with assert_raises(contains="outside 0..10"):
        _ = h2o_groupby_batch(10, 2, _SEED, -1, 2)
    with assert_raises(contains="rows must be in"):
        _ = h2o_groupby_parquet(0, 1, _SEED)
    with assert_raises(contains="groups must be in"):
        _ = h2o_groupby_parquet(10, 11, _SEED)
    with assert_raises(contains="batch_rows must be at least 1"):
        _ = h2o_groupby_parquet(10, 2, _SEED, batch_rows=0)


def main() raises:
    test_mix64_matches_the_published_splitmix64_outputs()
    test_draws_depend_on_seed_stream_and_row_and_stay_in_range()
    test_draw_values_are_pinned()
    test_a_bijection_visits_every_key_once()
    test_the_same_seed_and_size_write_the_same_bytes()
    test_a_file_holds_exactly_the_rows_the_seed_defines()
    test_values_stay_in_their_ranges_and_cover_the_groups()
    test_a_row_is_the_same_in_every_batch()
    test_one_group_and_id3_range_edges()
    test_refusals()
    print("OK")
