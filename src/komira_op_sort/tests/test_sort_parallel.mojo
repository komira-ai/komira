# =============================================================================
# sort_parallel: the parallel single-key sort gives the serial sort's rows
# =============================================================================
#
# Every case sorts the same batch twice, through `parallel_sort_single_key_serial`
# (cut into several slices by `num_workers`, so the per-slice sorts and the
# co-rank merge across runs both run) and through the serial
# `sort_topn_sink._sort_batch_single_key`, and requires equal columns. The
# payload column holds each row's input index, so a merge that broke a tie the
# wrong way (an unstable sort) fails on the payload even when the keys agree.
#
# Cases: INT64 ASC / DESC with ties, FLOAT64 ASC / DESC, INT32 with negatives,
# 4,096 rows with 64-way ties over 4 and 7 slices, the k-way merge of sorted
# partitions, the row floor of the gate, and FLOAT64 with NaNs of both signs
# and both zeros.
#
# The float case is a behaviour change. The flat key used to be IEEE
# `totalOrder`: a NaN with its sign bit set (what 0.0/0.0 gives on x86) sorted
# below -inf, and -0.0 sorted before +0.0. `sort_key_lt` (the serial kernels,
# DuckDB) puts every NaN above +inf and ties the zeros.
# `test_f64_nan_and_zeros_*` pins that order.
# =============================================================================

from std.memory import bitcast
from std.math import inf
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_collections.slab import Slab

from komira_op_sort.sort_parallel import (
    MIN_PARALLEL_SORT_ROWS,
    can_parallel_sort_single_key,
    merge_sorted_partitions_single_key_serial,
    parallel_sort_single_key_serial,
)
from komira_op_sort.sort_topn_sink import _sort_batch_single_key


def _batch[dt: DType](
    var keys: List[Scalar[dt]], n_payload: Int
) raises -> RecordBatch:
    """Key column `k` of `dt` and payload `orig` = 0..n-1."""
    var payload = List[Scalar[DType.int64]]()
    for i in range(n_payload):
        payload.append(Int64(i))
    var schema = Schema.from_fields_2(
        Field("k", dt, True), Field("orig", DType.int64, True)
    )
    var ck = Column.from_primitive[dt](PrimitiveArray[dt].from_list(keys^))
    var cp = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(payload^)
    )
    return RecordBatch.from_typed_columns_2(schema^, ck^, cp^)


def _payload(imm b: RecordBatch) raises -> List[Int]:
    var out = List[Int]()
    var p = b.column_at(1).as_primitive[DType.int64]()
    for i in range(p.length):
        out.append(Int(p.get_typed[Scalar[DType.int64]](i)))
    return out^


def _assert_same_rows[dt: DType](imm a: RecordBatch, imm b: RecordBatch) raises:
    """Equal key bits and equal payloads, row by row."""
    var ka = a.column_at(0).as_primitive[dt]()
    var kb = b.column_at(0).as_primitive[dt]()
    assert_equal(ka.length, kb.length)
    for i in range(ka.length):
        var x = ka.get_typed[Scalar[dt]](i)
        var y = kb.get_typed[Scalar[dt]](i)
        # A NaN equals only a NaN here (the payloads pin which row it is).
        assert_true(x == y or (x != x and y != y))
    var pa = _payload(a)
    var pb = _payload(b)
    for i in range(len(pa)):
        assert_equal(pa[i], pb[i])


def _both[dt: DType](
    keys: List[Scalar[dt]], desc: Bool, num_workers: Int
) raises -> Tuple[RecordBatch, RecordBatch]:
    var n = len(keys)
    var par = parallel_sort_single_key_serial(
        _batch[dt](keys.copy(), n), "k", desc, num_workers=num_workers
    )
    var ser = _sort_batch_single_key(_batch[dt](keys.copy(), n), "k", desc)
    return (par^, ser^)


def _check[dt: DType](
    keys: List[Scalar[dt]], desc: Bool, num_workers: Int
) raises:
    var r = _both[dt](keys, desc, num_workers)
    _assert_same_rows[dt](r[0], r[1])


def test_i64_asc_ties() raises:
    var keys: List[Int64] = [5, 3, 5, 1, 3, 1, 5, 3, 9, 1]
    _check[DType.int64](keys, False, 3)


def test_i64_desc_ties() raises:
    var keys: List[Int64] = [5, 3, 5, 1, 3, 1, 5, 3, 9, 1]
    _check[DType.int64](keys, True, 3)


def test_f64_asc_ties() raises:
    var keys: List[Float64] = [2.5, -1.0, 2.5, 0.0, -1.0, 3.14, 0.0, -9.0]
    _check[DType.float64](keys, False, 3)


def test_f64_desc() raises:
    var keys: List[Float64] = [2.5, -1.0, 2.5, 0.0, -1.0, 3.14, 0.0, -9.0]
    _check[DType.float64](keys, True, 3)


def test_i32_asc_negatives() raises:
    var keys: List[Int32] = [7, -3, 7, 0, -3, 12, 0, -100]
    _check[DType.int32](keys, False, 3)


def test_large_heavy_ties_many_runs() raises:
    """4,096 rows, keys in [0, 64) and not pre-sorted: every slice has many
    ties, and the co-rank has to split equal keys across run boundaries."""
    var keys = List[Int64]()
    for i in range(4096):
        keys.append(Int64((i * 2654435761) % 64))
    for nw in [4, 7]:
        _check[DType.int64](keys, False, nw)
        _check[DType.int64](keys, True, nw)


def test_one_slice_and_more_slices_than_rows() raises:
    """`num_workers` = 1 is the per-slice sort alone; more workers than rows
    is clamped to one row per slice."""
    var keys: List[Int64] = [4, 1, 4, 0, 1]
    _check[DType.int64](keys, False, 1)
    _check[DType.int64](keys, True, 64)


def _f64_bits(u: UInt64) -> Float64:
    return bitcast[DType.float64, 1](SIMD[DType.uint64, 1](u))[0]


def _nan_zero_keys() -> List[Float64]:
    """Rows 0..11: a positive NaN, a negative NaN (the bits 0.0/0.0 gives on
    x86), +inf, -inf, -0.0, +0.0 and numbers, with repeats."""
    var pos_nan = _f64_bits(0x7FF8000000000000)
    var neg_nan = _f64_bits(0xFFF8000000000000)
    var keys: List[Float64] = [
        1.5,                    # 0
        neg_nan,                # 1
        -0.0,                   # 2
        inf[DType.float64](),   # 3
        0.0,                    # 4
        pos_nan,                # 5
        -inf[DType.float64](),  # 6
        -0.0,                   # 7
        -2.0,                   # 8
        neg_nan,                # 9
        0.0,                    # 10
        1.5,                    # 11
    ]
    return keys^


def test_f64_nan_and_zeros_asc_duckdb_order() raises:
    """ASC: -inf, -2, the four zeros in input order (-0.0 ties +0.0), the two
    1.5s, +inf, then the three NaNs in input order, whatever their sign."""
    var r = _both[DType.float64](_nan_zero_keys(), False, 4)
    _assert_same_rows[DType.float64](r[0], r[1])
    var expect: List[Int] = [6, 8, 2, 4, 7, 10, 0, 11, 3, 1, 5, 9]
    var got = _payload(r[0])
    for i in range(len(expect)):
        assert_equal(got[i], expect[i])


def test_f64_nan_and_zeros_desc_duckdb_order() raises:
    """DESC: the three NaNs first (input order), +inf, 1.5s, the zeros in
    input order, -2, -inf."""
    var r = _both[DType.float64](_nan_zero_keys(), True, 4)
    _assert_same_rows[DType.float64](r[0], r[1])
    var expect: List[Int] = [1, 5, 9, 3, 0, 11, 2, 4, 7, 10, 8, 6]
    var got = _payload(r[0])
    for i in range(len(expect)):
        assert_equal(got[i], expect[i])


def test_merge_sorted_partitions_matches_one_sort() raises:
    """Three partitions, each sorted on its own (as `combine_partition`
    does), merged; the result is one stable sort of P0 ++ P1 ++ P2."""
    var per = 500
    var all_keys = List[Int64]()
    var parts = Slab[RecordBatch]()
    var orig = 0
    for p in range(3):
        var pk = List[Int64]()
        var pp = List[Int64]()
        for i in range(per):
            var k = Int64((p * 7 + i * 3) % 16)
            pk.append(k)
            pp.append(Int64(orig))
            all_keys.append(k)
            orig += 1
        var schema = Schema.from_fields_2(
            Field("k", DType.int64, True), Field("orig", DType.int64, True)
        )
        var b = RecordBatch.from_typed_columns_2(
            schema^,
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(pk^)
            ),
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(pp^)
            ),
        )
        parts.append(_sort_batch_single_key(b^, "k", True))
    var merged = merge_sorted_partitions_single_key_serial(parts^, "k", True)
    var n = len(all_keys)
    var ref_sorted = _sort_batch_single_key(
        _batch[DType.int64](all_keys^, n), "k", True
    )
    _assert_same_rows[DType.int64](merged, ref_sorted)


def test_gate_row_floor_and_key_types() raises:
    """The gate: one key of INT64 / INT32 / FLOAT64, at least
    `MIN_PARALLEL_SORT_ROWS` rows unless forced."""
    var small: List[Int64] = [3, 1, 2]
    var b = _batch[DType.int64](small^, 3)
    assert_false(can_parallel_sort_single_key(b, 1, "k"))
    assert_true(can_parallel_sort_single_key(b, 1, "k", force=True))
    assert_false(can_parallel_sort_single_key(b, 2, "k", force=True))
    assert_false(can_parallel_sort_single_key(b, 1, "missing", force=True))
    var big = List[Int64]()
    for i in range(MIN_PARALLEL_SORT_ROWS):
        big.append(Int64(i % 7))
    var bb = _batch[DType.int64](big^, MIN_PARALLEL_SORT_ROWS)
    assert_true(can_parallel_sort_single_key(bb, 1, "k"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
