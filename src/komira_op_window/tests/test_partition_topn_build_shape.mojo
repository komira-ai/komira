# =============================================================================
# test_partition_topn_build_shape -- the compact path's heap build
# =============================================================================
#
# `partition_topn_compact`: the probe table is sized from the partitions it
# sees (it grows on load, it does not start at the row count), the chunked
# build plus merge equals the single-pass build, and a partition key equal to
# the table's empty marker (`Int64.MIN`) is still one partition.
#
# 60,000 rows over 900 partitions (67 rows each); the order key is a mixer of
# the row index with no tie inside a partition, so the kept rows are
# determined and the two builds must agree on them.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_window.partition_topn_compact import (
    CompactRow,
    _ChunkHeaps,
    _PTOPN_ADAPT_START,
    _PTOPN_EST_PARTITION_CAP,
    _build_heaps_range,
    _merge_chunk_heaps,
)


comptime _ROWS: Int = 60_000
comptime _PARTS: Int = 900
comptime _K: Int = 4


def _part_keys() -> List[Int64]:
    var pk = List[Int64](capacity=_ROWS)
    for i in range(_ROWS):
        pk.append(Int64(i % _PARTS))
    return pk^


def _order_keys() -> List[UInt64]:
    var ok = List[UInt64](capacity=_ROWS)
    for i in range(_ROWS):
        ok.append(UInt64((i * 2_654_435_761) % 1_000_003))
    return ok^


def _census(heaps: List[List[CompactRow]], pk: List[Int64]) raises -> List[String]:
    """One `"<pk>:<sorted order_bits>"` per partition, sorted: comparable
    across builds that see partitions in different orders."""
    var rows = List[String]()
    for p in range(len(heaps)):
        if len(heaps[p]) == 0:
            continue
        var key = Int(pk[Int(heaps[p][0].row_idx)])
        var obs = List[Int]()
        for i in range(len(heaps[p])):
            assert_equal(Int(pk[Int(heaps[p][i].row_idx)]), key, "a heap holds two partitions")
            obs.append(Int(heaps[p][i].order_bits))
        sort(obs)
        var s = String(key) + ":"
        for i in range(len(obs)):
            s += String(obs[i]) + ","
        rows.append(s)
    sort(rows)
    return rows^


def test_probe_table_is_sized_from_the_partitions() raises:
    var pk = _part_keys()
    var ok = _order_keys()
    var out = _ChunkHeaps()
    _build_heaps_range(pk, ok, 0, _ROWS, _K, out)
    assert_equal(len(out.heaps), _PARTS)
    assert_true(out.tab_grows > 0, "the table grows on load")
    assert_true(out.tab_final > _PTOPN_ADAPT_START)
    assert_true(out.tab_final >= 2 * _PARTS, "at most half full")
    assert_true(out.tab_final * 4 < 2 * min(_ROWS, _PTOPN_EST_PARTITION_CAP), "not sized from the rows")


def test_chunked_build_plus_merge_equals_single_pass() raises:
    var pk = _part_keys()
    var ok = _order_keys()
    var single = _ChunkHeaps()
    _build_heaps_range(pk, ok, 0, _ROWS, _K, single)
    var want = _census(single.heaps, pk)
    var chunks = List[_ChunkHeaps]()
    for c in range(4):
        var part = _ChunkHeaps()
        _build_heaps_range(pk, ok, (c * _ROWS) // 4, ((c + 1) * _ROWS) // 4, _K, part)
        chunks.append(part^)
    var got = _census(_merge_chunk_heaps(chunks, _K), pk)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def test_empty_marker_key_is_one_partition() raises:
    # Int64.MIN is the table's empty marker: five rows with that key, three
    # with key 0, must build two heaps (and a merge of two chunks too).
    var pk: List[Int64] = [Int64.MIN, 0, Int64.MIN, Int64.MIN, 0, Int64.MIN, 0, Int64.MIN]
    var ok: List[UInt64] = [5, 4, 3, 2, 1, 6, 7, 8]
    var out = _ChunkHeaps()
    _build_heaps_range(pk, ok, 0, 8, 2, out)
    assert_equal(len(out.heaps), 2)
    var a = _ChunkHeaps()
    var b = _ChunkHeaps()
    _build_heaps_range(pk, ok, 0, 4, 2, a)
    _build_heaps_range(pk, ok, 4, 8, 2, b)
    var chunks = List[_ChunkHeaps]()
    chunks.append(a^)
    chunks.append(b^)
    var merged = _merge_chunk_heaps(chunks, 2)
    assert_equal(len(merged), 2)
    for p in range(2):
        assert_equal(len(merged[p]), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
