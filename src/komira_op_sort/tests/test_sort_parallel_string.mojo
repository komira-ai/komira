# =============================================================================
# sort_parallel_string: the parallel STRING sort and merges give the serial
# sort's rows
# =============================================================================
#
# Each case sorts one batch through a parallel entry, cut into several slices
# by `num_workers`, and through the serial `_sort_batch_single_key`
# (`sort_indices_string`), and requires the same strings and the same payload
# (the input row index) in every row. The payload catches an unstable merge.
#
#   * ties ASC / DESC, and 4,096 rows of 16 keys over 4 and 7 slices;
#   * `test_cross_slice_prefix_collision`: 64 keys with one 16-byte prefix,
#     differing only after it. The 8-byte prefix keys all collide, so only the
#     full comparator orders them;
#   * a string that is a prefix of another ("ab" before "abc") across slices;
#   * NULLs across slices: NULLS FIRST ascending, NULLS LAST descending;
#   * the serial heap merge and the parallel pairwise-tree merge of sorted
#     partitions, each against one sort of the concatenation;
#   * BINARY keys (embedded zero bytes, one shared prefix, a key that is a
#     prefix of another), sorted in parallel and merged from sorted partitions.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab

from komira_op_sort.sort_parallel_string import (
    can_parallel_sort_single_key_string,
    merge_sorted_partitions_single_key_string,
    merge_sorted_partitions_single_key_string_parallel_serial,
    parallel_sort_single_key_string_serial,
)
from komira_op_sort.sort_topn_sink import _sort_batch_single_key


def _batch(
    keys: List[String], valid: List[Bool], first_orig: Int = 0
) raises -> RecordBatch:
    """Key `k` (STRING; NULL where `valid` is False, when it is not empty)
    and payload `orig` = first_orig.."""
    var payload = List[Int64]()
    for i in range(len(keys)):
        payload.append(Int64(first_orig + i))
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
    """The string at `row` of column 0, read from the buffers (honours the
    column's offset)."""
    ref c = batch.column_at(0)
    var offs = c._offsets.value().view_ro()
    var data = c._data.view_ro()
    var o = c._offset + row
    var start = Int(offs.get_typed[Int32](o))
    var end = Int(offs.get_typed[Int32](o + 1))
    var out = String("")
    for i in range(start, end):
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


def _check(
    keys: List[String], valid: List[Bool], desc: Bool, num_workers: Int
) raises:
    var par = parallel_sort_single_key_string_serial(
        _batch(keys, valid), "k", desc, num_workers=num_workers
    )
    var ser = _sort_batch_single_key(_batch(keys, valid), "k", desc)
    _assert_same_rows(par, ser)


def _ties() -> List[String]:
    var keys: List[String] = [
        "delta", "alpha", "delta", "beta", "alpha",
        "charlie", "beta", "alpha", "epsilon", "beta",
    ]
    return keys^


def test_ties_asc() raises:
    _check(_ties(), List[Bool](), False, 3)


def test_ties_desc() raises:
    _check(_ties(), List[Bool](), True, 3)


def test_cross_slice_prefix_collision() raises:
    var keys = List[String]()
    for i in range(64):
        var t = (i * 37 + 11) % 64
        keys.append(String("shared_prefix_xx") + String(1000 + t))
    _check(keys, List[Bool](), False, 4)
    _check(keys, List[Bool](), True, 4)


def test_prefix_of_another_across_slices() raises:
    var base: List[String] = ["ab", "abc", "a", "abcd", "abc", "", "ab", "b"]
    var keys = List[String]()
    for _ in range(8):
        for j in range(len(base)):
            keys.append(base[j])
    _check(keys, List[Bool](), False, 5)
    _check(keys, List[Bool](), True, 5)


def test_nulls_across_slices() raises:
    var words: List[String] = ["mango", "apple", "pear", "apple"]
    var keys = List[String]()
    var valid = List[Bool]()
    for i in range(48):
        keys.append(String("") if i % 5 == 0 else words[i % 4])
        valid.append(i % 5 != 0)
    _check(keys, valid, False, 4)
    _check(keys, valid, True, 4)


def test_nulls_first_ascending_last_descending() raises:
    """The placement itself, not only agreement with the serial sort."""
    var keys: List[String] = ["b", "", "a", ""]
    var valid: List[Bool] = [True, False, True, False]
    var asc = parallel_sort_single_key_string_serial(
        _batch(keys, valid), "k", False, num_workers=2
    )
    var pa = asc.column_at(1).as_primitive[DType.int64]()
    var expect_asc: List[Int] = [1, 3, 2, 0]
    for i in range(4):
        assert_equal(Int(pa.get_typed[Scalar[DType.int64]](i)), expect_asc[i])
    var desc = parallel_sort_single_key_string_serial(
        _batch(keys, valid), "k", True, num_workers=2
    )
    var pd = desc.column_at(1).as_primitive[DType.int64]()
    var expect_desc: List[Int] = [0, 2, 1, 3]
    for i in range(4):
        assert_equal(Int(pd.get_typed[Scalar[DType.int64]](i)), expect_desc[i])


def test_large_heavy_ties() raises:
    var keys = List[String]()
    for i in range(4096):
        keys.append(String("key_") + String((i * 2654435761) % 16))
    for nw in [4, 7]:
        _check(keys, List[Bool](), False, nw)
        _check(keys, List[Bool](), True, nw)


def _partitions(
    desc: Bool, mut parts: Slab[RecordBatch]
) raises -> List[String]:
    """Append three partitions of 300 rows over 8 keys to `parts`, each
    sorted on its own; return all the keys in partition order."""
    var all_keys = List[String]()
    var orig = 0
    for p in range(3):
        var pk = List[String]()
        for i in range(300):
            var w = String("v") + String((p * 7 + i * 3) % 8) + String("_tag")
            pk.append(w)
            all_keys.append(w)
        parts.append(
            _sort_batch_single_key(_batch(pk, List[Bool](), orig), "k", desc)
        )
        orig += 300
    return all_keys^


def test_serial_partition_merge_matches_one_sort() raises:
    for desc in [False, True]:
        var parts = Slab[RecordBatch]()
        var keys = _partitions(desc, parts)
        var merged = merge_sorted_partitions_single_key_string(
            parts^, "k", desc
        )
        var ref_sorted = _sort_batch_single_key(
            _batch(keys, List[Bool]()), "k", desc
        )
        _assert_same_rows(merged, ref_sorted)


def test_parallel_partition_merge_matches_one_sort() raises:
    for desc in [False, True]:
        for nw in [1, 3, 8]:
            var parts = Slab[RecordBatch]()
            var keys = _partitions(desc, parts)
            var merged = merge_sorted_partitions_single_key_string_parallel_serial(
                parts^, "k", desc, num_workers=nw
            )
            var ref_sorted = _sort_batch_single_key(
                _batch(keys, List[Bool]()), "k", desc
            )
            _assert_same_rows(merged, ref_sorted)


def test_gate() raises:
    var keys: List[String] = ["b", "a"]
    var b = _batch(keys, List[Bool]())
    assert_false(can_parallel_sort_single_key_string(b, 1, "k"))
    assert_true(can_parallel_sort_single_key_string(b, 1, "k", force=True))
    assert_false(can_parallel_sort_single_key_string(b, 1, "orig", force=True))
    assert_false(can_parallel_sort_single_key_string(b, 2, "k", force=True))


# -----------------------------------------------------------------------------
# BINARY keys
# -----------------------------------------------------------------------------


def _binary_rows(n: Int, seed: UInt64) -> List[List[UInt8]]:
    """`n` byte strings: most share the prefix "ab" then a zero byte
    and differ in a trailing byte or two, a few are shorter prefixes of those."""
    var rows = List[List[UInt8]]()
    var state = seed
    for _ in range(n):
        state = state * 6364136223846793005 + 1442695040888963407
        var tail = UInt8(Int((state >> 24) % 5))
        var shape = Int((state >> 40) % 6)
        var row: List[UInt8] = [UInt8(0x61), UInt8(0x62), UInt8(0x00)]
        if shape == 0:
            row = [UInt8(0x61), UInt8(0x62)]
        elif shape == 1:
            row = [UInt8(0x61), UInt8(0x62), UInt8(0x00)]
        elif shape == 2:
            row.append(tail)
            row.append(UInt8(0x00))
        else:
            row.append(tail)
        rows.append(row^)
    return rows^


def _binary_batch(
    rows: List[List[UInt8]], first_orig: Int = 0
) raises -> RecordBatch:
    """Key `k` (BINARY) and payload `orig` = first_orig.."""
    var payload = List[Int64]()
    for i in range(len(rows)):
        payload.append(Int64(first_orig + i))
    var schema = Schema.from_fields_2(
        Field("k", ArrowType.BINARY, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_binary(BinaryArray.from_bytes_list(rows)),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(payload^)
        ),
    )


def _assert_same_binary_rows(imm a: RecordBatch, imm b: RecordBatch) raises:
    """Equal key bytes and equal payloads, row by row."""
    assert_equal(a.num_rows(), b.num_rows())
    var pa = a.column_at(1).as_primitive[DType.int64]()
    var pb = b.column_at(1).as_primitive[DType.int64]()
    ref ca = a.column_at(0)
    ref cb = b.column_at(0)
    var oa = ca._offsets.value().view_ro()
    var ob = cb._offsets.value().view_ro()
    var da = ca._data.view_ro()
    var db = cb._data.view_ro()
    for r in range(a.num_rows()):
        var sa = Int(oa.get_typed[Int32](ca._offset + r))
        var ea = Int(oa.get_typed[Int32](ca._offset + r + 1))
        var sb = Int(ob.get_typed[Int32](cb._offset + r))
        var eb = Int(ob.get_typed[Int32](cb._offset + r + 1))
        assert_equal(ea - sa, eb - sb)
        for i in range(ea - sa):
            assert_equal(
                Int(da.get_typed[UInt8](sa + i)),
                Int(db.get_typed[UInt8](sb + i)),
            )
        assert_equal(
            Int(pa.get_typed[Scalar[DType.int64]](r)),
            Int(pb.get_typed[Scalar[DType.int64]](r)),
        )


def test_binary_sort_matches_serial() raises:
    var rows = _binary_rows(600, 17)
    for desc in [False, True]:
        for nw in [1, 3, 7]:
            var par = parallel_sort_single_key_string_serial(
                _binary_batch(rows), "k", desc, num_workers=nw
            )
            var ser = _sort_batch_single_key(_binary_batch(rows), "k", desc)
            _assert_same_binary_rows(par, ser)


def test_binary_partition_merge_matches_one_sort() raises:
    for desc in [False, True]:
        for nw in [1, 3, 8]:
            var parts = Slab[RecordBatch]()
            var all_rows = List[List[UInt8]]()
            var orig = 0
            for p in range(3):
                var rows = _binary_rows(250, UInt64(5 + p))
                for i in range(len(rows)):
                    all_rows.append(rows[i].copy())
                parts.append(
                    _sort_batch_single_key(
                        _binary_batch(rows, orig), "k", desc
                    )
                )
                orig += 250
            var merged = merge_sorted_partitions_single_key_string_parallel_serial(
                parts^, "k", desc, num_workers=nw
            )
            var ref_sorted = _sort_batch_single_key(
                _binary_batch(all_rows), "k", desc
            )
            _assert_same_binary_rows(merged, ref_sorted)


def test_binary_key_passes_the_gate() raises:
    var rows = _binary_rows(4, 1)
    var b = _binary_batch(rows)
    assert_true(can_parallel_sort_single_key_string(b, 1, "k", force=True))
    assert_false(can_parallel_sort_single_key_string(b, 1, "k"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
