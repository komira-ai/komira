# =============================================================================
# sort_dictrank: the dense-rank counting sort gives the serial sort's rows,
# and its gate reads the whole column
# =============================================================================
#
#   * Equivalence: low-cardinality STRING keys, with and without NULLs, ASC and
#     DESC, over 1, 3 and 8 slices, against `_sort_batch_single_key`
#     (`sort_indices_string`): same strings, same payload (input row) in every
#     row. NULLs land first for ASC and last for DESC, as in the serial sort.
#   * The fallback: a ceiling below the exact distinct count sends the batch
#     to the comparison sort, with the same rows.
#   * The gate: a key with one value in its first quarter and a distinct value
#     in every later row is declined. A sample of only the first rows
#     would see most of its sample as one value and admit it; the strided
#     sample reads the whole column and declines.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray

from komira_op_sort.sort_dictrank import (
    can_dictrank_sort_single_key_string,
    parallel_dictrank_sort_string_serial,
)
from komira_op_sort.sort_dictrank_build import DICTRANK_MIN_ROWS
from komira_op_sort.sort_topn_sink import _sort_batch_single_key


def _batch(keys: List[String], valid: List[Bool]) raises -> RecordBatch:
    var payload = List[Int64]()
    for i in range(len(keys)):
        payload.append(Int64(i))
    var sa = (
        StringArray.from_strings(keys) if len(valid) == 0
        else StringArray.from_strings_with_validity(keys, valid)
    )
    var schema = Schema.from_fields_2(
        Field("k", ArrowType.STRING, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_string(sa^),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(payload^)
        ),
    )


def _string_at(imm batch: RecordBatch, row: Int) raises -> String:
    ref c = batch.column_at(0)
    var offs = c._offsets.value().view_ro()
    var data = c._data.view_ro()
    var o = c._offset + row
    var out = String("")
    for i in range(Int(offs.get_typed[Int32](o)), Int(offs.get_typed[Int32](o + 1))):
        out += chr(Int(data.get_typed[UInt8](i)))
    return out


def _assert_same_rows(imm a: RecordBatch, imm b: RecordBatch) raises:
    assert_equal(a.num_rows(), b.num_rows())
    var pa = a.column_at(1).as_primitive[DType.int64]()
    var pb = b.column_at(1).as_primitive[DType.int64]()
    for r in range(a.num_rows()):
        assert_equal(_string_at(a, r), _string_at(b, r))
        assert_equal(
            Int(pa.get_typed[Scalar[DType.int64]](r)),
            Int(pb.get_typed[Scalar[DType.int64]](r)),
        )


def _low_card(n: Int, with_nulls: Bool) -> Tuple[List[String], List[Bool]]:
    """`n` rows over 7 values (one a prefix of another, one empty), every
    9th row NULL when `with_nulls`."""
    var words: List[String] = ["pear", "apple", "", "pea", "zebra", "apple2", "b"]
    var keys = List[String]()
    var valid = List[Bool]()
    for i in range(n):
        keys.append(words[(i * 5 + 3) % 7])
        valid.append(not (with_nulls and i % 9 == 4))
    if not with_nulls:
        valid = List[Bool]()
    return (keys^, valid^)


def _check(
    keys: List[String], valid: List[Bool], desc: Bool, nw: Int,
    max_distinct: Int = 1 << 17,
) raises:
    var got = parallel_dictrank_sort_string_serial(
        _batch(keys, valid), "k", desc, num_workers=nw,
        max_distinct=max_distinct,
    )
    var want = _sort_batch_single_key(_batch(keys, valid), "k", desc)
    _assert_same_rows(got, want)


def test_no_nulls_matches_serial() raises:
    var t = _low_card(500, False)
    for nw in [1, 3, 8]:
        _check(t[0], t[1], False, nw)
        _check(t[0], t[1], True, nw)


def test_nulls_match_serial() raises:
    var t = _low_card(500, True)
    for nw in [1, 3, 8]:
        _check(t[0], t[1], False, nw)
        _check(t[0], t[1], True, nw)


def test_nulls_first_ascending_last_descending() raises:
    var keys: List[String] = ["b", "", "a", "", "b"]
    var valid: List[Bool] = [True, False, True, False, True]
    var asc = parallel_dictrank_sort_string_serial(
        _batch(keys, valid), "k", False, num_workers=2
    )
    var pa = asc.column_at(1).as_primitive[DType.int64]()
    var expect_asc: List[Int] = [1, 3, 2, 0, 4]
    for i in range(5):
        assert_equal(Int(pa.get_typed[Scalar[DType.int64]](i)), expect_asc[i])
    var desc = parallel_dictrank_sort_string_serial(
        _batch(keys, valid), "k", True, num_workers=2
    )
    var pd = desc.column_at(1).as_primitive[DType.int64]()
    var expect_desc: List[Int] = [0, 4, 2, 1, 3]
    for i in range(5):
        assert_equal(Int(pd.get_typed[Scalar[DType.int64]](i)), expect_desc[i])


def test_ceiling_below_exact_count_falls_back_with_same_rows() raises:
    """Seven distinct values against a ceiling of 3."""
    var t = _low_card(300, True)
    _check(t[0], t[1], False, 4, max_distinct=3)
    _check(t[0], t[1], True, 4, max_distinct=3)


def test_gate_admits_low_cardinality_and_declines_high() raises:
    var t = _low_card(1000, False)
    var low = _batch(t[0], t[1])
    assert_true(can_dictrank_sort_single_key_string(low, "k", force=True))
    # Unforced, 1000 rows is under the row floor.
    assert_true(1000 < DICTRANK_MIN_ROWS)
    assert_false(can_dictrank_sort_single_key_string(low, "k"))
    # Seven distinct values against a ceiling of 5.
    assert_false(
        can_dictrank_sort_single_key_string(low, "k", True, max_distinct=5)
    )
    var high = List[String]()
    for i in range(1000):
        high.append(String("v") + String(i))
    var hb = _batch(high, List[Bool]())
    assert_false(can_dictrank_sort_single_key_string(hb, "k", force=True))
    # Not a STRING key.
    assert_false(can_dictrank_sort_single_key_string(low, "orig", force=True))


def test_gate_declines_a_key_distinct_in_its_tail() raises:
    """200,000 rows: the first 50,000 one value, every later row distinct.
    The strided sample (stride 3 over 65,536 probes) sees about 75% distinct
    and declines; the first 65,536 rows alone are about 24% distinct."""
    var keys = List[String]()
    for i in range(200_000):
        keys.append(String("same") if i < 50_000 else String("t") + String(i))
    var b = _batch(keys, List[Bool]())
    assert_false(can_dictrank_sort_single_key_string(b, "k"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
