# =============================================================================
# sort_parallel: INT64 keys that span the whole Int64 range
# =============================================================================
#
# The co-rank search narrows a threshold key in [min key, max key] by halving.
# For an INT64 column that holds both `Int64.MIN` and `Int64.MAX` the distance
# between the bounds is 2^64 - 1, which does not fit a signed Int64 and whose
# increment does not fit a UInt64. The midpoints must stay inside [lo, hi] and
# the descending midpoint must round up so the search always makes progress.
#
# The midpoints themselves are pinned in test_sort_parallel_midpoint.mojo.
#
#   * `test_extremes_*` sort and merge columns holding both extremes, ascending
#     and descending, over 2 and 4 slices, and require the serial sort's rows
#     (the payload column holds each row's input index, so it shows that ties
#     keep input order).
# =============================================================================

from std.math import inf
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_collections.slab import Slab

from komira_op_sort.sort_parallel import (
    merge_sorted_partitions_single_key_serial,
    parallel_sort_single_key_serial,
)
from komira_op_sort.sort_topn_sink import _sort_batch_single_key


def _batch[dt: DType](
    keys: List[Scalar[dt]], first: Int = 0
) raises -> RecordBatch:
    """Key column `k` of `dt` and payload `orig` = first.. (input index)."""
    var payload = List[Scalar[DType.int64]]()
    for i in range(len(keys)):
        payload.append(Int64(first + i))
    var schema = Schema.from_fields_2(
        Field("k", dt, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[dt](PrimitiveArray[dt].from_list(keys.copy())),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(payload^)
        ),
    )


def _assert_same_rows[dt: DType](imm a: RecordBatch, imm b: RecordBatch) raises:
    assert_equal(a.num_rows(), b.num_rows())
    var ka = a.column_at(0).as_primitive[dt]()
    var kb = b.column_at(0).as_primitive[dt]()
    var pa = a.column_at(1).as_primitive[DType.int64]()
    var pb = b.column_at(1).as_primitive[DType.int64]()
    for i in range(a.num_rows()):
        var x = ka.get_typed[Scalar[dt]](i)
        var y = kb.get_typed[Scalar[dt]](i)
        assert_true(x == y or (x != x and y != y))
        assert_equal(
            Int(pa.get_typed[Scalar[DType.int64]](i)),
            Int(pb.get_typed[Scalar[DType.int64]](i)),
        )


def _check[dt: DType](
    keys: List[Scalar[dt]], desc: Bool, num_workers: Int
) raises:
    var par = parallel_sort_single_key_serial(
        _batch[dt](keys), "k", desc, num_workers=num_workers
    )
    var ser = _sort_batch_single_key(_batch[dt](keys), "k", desc)
    _assert_same_rows[dt](par, ser)


def test_extremes_ascending() raises:
    var keys: List[Int64] = [
        Int64.MIN, Int64.MAX, 0, Int64.MAX, Int64.MIN, 5, -5, 0
    ]
    _check[DType.int64](keys, False, 2)
    _check[DType.int64](keys, False, 4)


def test_extremes_descending() raises:
    var keys: List[Int64] = [
        Int64.MIN, Int64.MAX, 0, Int64.MAX, Int64.MIN, 5, -5, 0
    ]
    _check[DType.int64](keys, True, 2)
    _check[DType.int64](keys, True, 4)


def test_extremes_only_the_two_bounds_with_ties() raises:
    """Only MIN and MAX, many of each: every co-rank search runs over the
    widest possible range and splits equal keys across runs."""
    var keys = List[Int64]()
    for i in range(257):
        keys.append(Int64.MAX if (i * 7) % 3 == 0 else Int64.MIN)
    for nw in [2, 3, 5]:
        _check[DType.int64](keys, False, nw)
        _check[DType.int64](keys, True, nw)


def test_extremes_mixed_with_near_bounds_over_many_slices() raises:
    var keys = List[Int64]()
    for i in range(1024):
        var c = (i * 2654435761) % 6
        if c == 0:
            keys.append(Int64.MIN)
        elif c == 1:
            keys.append(Int64.MAX)
        elif c == 2:
            keys.append(Int64.MIN + 1)
        elif c == 3:
            keys.append(Int64.MAX - 1)
        else:
            keys.append(Int64(i % 5) - 2)
    for nw in [2, 4, 7]:
        _check[DType.int64](keys, False, nw)
        _check[DType.int64](keys, True, nw)


def test_float_extremes_descending_and_ascending() raises:
    var keys: List[Float64] = [
        inf[DType.float64](), -inf[DType.float64](), Float64.MAX,
        -Float64.MAX, 0.0, inf[DType.float64](), -inf[DType.float64](), 1.5,
    ]
    for nw in [2, 4]:
        _check[DType.float64](keys, False, nw)
        _check[DType.float64](keys, True, nw)


def test_merge_of_sorted_partitions_holding_both_extremes() raises:
    for desc in [False, True]:
        var parts = Slab[RecordBatch]()
        var all_keys = List[Int64]()
        var orig = 0
        for p in range(3):
            var pk = List[Int64]()
            for i in range(40):
                var c = (p + i * 3) % 4
                if c == 0:
                    pk.append(Int64.MIN)
                elif c == 1:
                    pk.append(Int64.MAX)
                else:
                    pk.append(Int64(i % 3))
                all_keys.append(pk[len(pk) - 1])
            parts.append(
                _sort_batch_single_key(_batch[DType.int64](pk, orig), "k", desc)
            )
            orig += 40
        var merged = merge_sorted_partitions_single_key_serial(
            parts^, "k", desc
        )
        _assert_same_rows[DType.int64](
            merged,
            _sort_batch_single_key(_batch[DType.int64](all_keys), "k", desc),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
