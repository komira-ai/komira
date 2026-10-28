# =============================================================================
# Nested sort keys: BOOL and float leaves order like the flat kernels
# =============================================================================
#
# `sort_indices_nested` compares a struct field (or list element) through a
# per-type leaf comparator. Two leaves had their own rules and disagreed with
# the flat kernels:
#
#   * BOOL. Arrow packs BOOL one BIT per row. The leaf read row `r` as BYTE
#     `r`, so row 3 of a struct<b: bool> was compared by the byte holding rows
#     24..31 (past the end of a short column). The order then had nothing to
#     do with the values. Expected: false < true, ties in input order.
#   * FLOAT. The leaf compared with the IEEE `<`, so a NaN field was "equal"
#     to everything and the insertion sort stopped wherever it met one.
#     Expected: DuckDB's order, NaN above +inf (`sort.sort_key_lt`).
#
# Planted mutants: the byte read restored turns the BOOL tests red; the bare
# `<` restored turns the float tests red.
# =============================================================================

from std.math import inf
from std.testing import TestSuite, assert_equal

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.struct_array import StructArray
from komira_buffer.heap_region import HeapRegion
from komira_op_sort.sort_nested import sort_indices_nested


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _struct_of(var child: Column[HeapRegion]) raises -> Column[HeapRegion]:
    var names: List[String] = ["v"]
    return Column.from_struct(StructArray.from_columns_1(names, child^))


def _bool_col(values: List[Bool]) -> Column[HeapRegion]:
    var arr = BooleanArray.allocate(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    return Column.from_boolean(arr)


def _f64_col(values: List[Float64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(values)
    )


def _assert_order(
    idx: PrimitiveArray[DType.int32], expected: List[Int], label: String
) raises:
    assert_equal(idx.length, len(expected), label + ": length")
    for i in range(len(expected)):
        assert_equal(
            Int(idx.get(i)), expected[i], label + ": position " + String(i)
        )


def test_struct_bool_field_ascending() raises:
    var vals: List[Bool] = [
        True, False, True, False, False, True, False, True, True, False,
        True, False,
    ]
    var col = _struct_of(_bool_col(vals))
    _assert_order(
        sort_indices_nested(col, False),
        [1, 3, 4, 6, 9, 11, 0, 2, 5, 7, 8, 10],
        "struct<bool> ASC",
    )


def test_struct_bool_field_descending() raises:
    var vals: List[Bool] = [
        False, True, False, False, True, True, False, False, True,
    ]
    var col = _struct_of(_bool_col(vals))
    _assert_order(
        sort_indices_nested(col, True),
        [1, 4, 5, 8, 0, 2, 3, 6, 7],
        "struct<bool> DESC",
    )


def test_struct_float_field_nan_above_inf() raises:
    var vals: List[Float64] = [
        _nan(), 1.0, inf[DType.float64](), -1.0, _nan(), 0.5,
    ]
    var col = _struct_of(_f64_col(vals))
    _assert_order(
        sort_indices_nested(col, False), [3, 5, 1, 2, 0, 4], "struct<f64> ASC"
    )
    _assert_order(
        sort_indices_nested(col, True), [0, 4, 2, 1, 5, 3], "struct<f64> DESC"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
