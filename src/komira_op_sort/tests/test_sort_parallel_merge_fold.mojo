# =============================================================================
# The three merges of sorted partitions fold their partitions once, in slot
# order, keeping the key's NULLs
# =============================================================================
#
# `merge_sorted_partitions_single_key` (INT64 / INT32 / FLOAT64 key, serial heap
# merge), `merge_sorted_partitions_single_key_string` (serial comparator heap
# merge) and `merge_sorted_partitions_single_key_string_parallel` (pairwise-tree
# co-rank merge) each concatenate their partitions with
# `sink_batch_fold.fold_batches_into_one` before merging. Three properties, one
# guard each:
#
#   * COST. The fold copies each row once, so the same rows merged from 4 and
#     from 16 partitions copy the same bytes in the same number of allocations
#     (the fold census of `komira_operator_api.join_build_fold_census`).
#     Agreement across two shardings is the assertion, not a bound at one
#     partition count.
#   * ORDER. The merge reads [base[p], base[p+1]) as partition p's sorted run,
#     so the fold visits the slab in slot order. The fixture's partitions are
#     UNEVEN (100 / 300 / 200 / 400 rows): with equal sizes any permutation of
#     the slots maps each range onto another sorted run and the merge still
#     emits a sorted result, so only uneven sizes tie each range to its run.
#   * NULLS. The STRING merges read the key's validity bitmap to put NULLs
#     first, so the fold carries it. A NULL key's bytes are always "" (the
#     byte minimum), so the check is on validity: row 0 reads as NULL, not as
#     a valid ''. The INT merge reads values only and has no such check.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_operator_api.join_build_fold_census import (
    join_build_fold_allocs,
    join_build_fold_bytes,
    reset_join_build_fold_census,
)

from komira_op_sort.sort_parallel import merge_sorted_partitions_single_key_serial
from komira_op_sort.sort_parallel_string import (
    merge_sorted_partitions_single_key_string,
    merge_sorted_partitions_single_key_string_parallel_serial,
)


# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

comptime _NULL_PLACEHOLDER: String = "zzz_null_placeholder"
"""The value handed to `from_strings_with_validity` for a NULL row. It is not
stored (a NULL row is a length-0 slot); it would sort last if it were, so a
change there fails `test_string_*_keeps_null_keys_first` loudly."""


def _int_batch(var keys: List[Int64]) raises -> RecordBatch:
    """Two-column INT64 batch: "k" (the sort key) and "v" (== k, so a fold that
    misaligned the columns against each other is also caught)."""
    var n = len(keys)
    var k_arr = PrimitiveArray[DType.int64].allocate(n)
    var v_arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k_arr.set(i, keys[i])
        v_arr.set(i, keys[i])
    var schema = Schema.from_fields_2(
        Field("k", DType.int64, False),
        Field("v", DType.int64, False),
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](k_arr^),
        Column.from_primitive[DType.int64](v_arr^),
    )


def _str_batch(
    var keys: List[String], var valid: List[Bool], var payload: List[Int64]
) raises -> RecordBatch:
    """STRING key column "k" (nullable) + INT64 "orig" payload."""
    var sa = StringArray.from_strings_with_validity(keys, valid)
    var n = len(payload)
    var p_arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        p_arr.set(i, payload[i])
    var schema = Schema.from_fields_2(
        Field("k", ArrowType.STRING, True),
        Field("orig", DType.int64, True),
    )
    return RecordBatch.from_typed_columns_2(
        schema^, Column.from_string(sa^), Column.from_primitive[DType.int64](p_arr^)
    )


def _all_valid(n: Int) -> List[Bool]:
    var v = List[Bool](capacity=n)
    for _ in range(n):
        v.append(True)
    return v^


def _key_name(i: Int) -> String:
    """A fixed-width ascending key: `aaa_key_00000` .. — byte order == numeric
    order."""
    var s = String(i)
    while s.byte_length() < 5:
        s = String("0") + s
    return String("aaa_key_") + s


# -----------------------------------------------------------------------------
# Readers
# -----------------------------------------------------------------------------


def _read_int64_col(imm batch: RecordBatch, col: Int) raises -> List[Int64]:
    ref c = batch.column_at(col)
    var arr = c.as_primitive[DType.int64]()
    var out = List[Int64](capacity=batch.num_rows())
    for i in range(batch.num_rows()):
        out.append(arr.get(i))
    return out^


def _string_at(imm batch: RecordBatch, col: Int, row: Int) raises -> String:
    """Read the logical string at (col, row) straight off the column buffers —
    no StringArray construction, and it honours the column's `_offset`."""
    ref c = batch.column_at(col)
    var offs = c._offsets.value().view_ro()
    var data = c._data.view_ro()
    var o = c._offset + row
    var start = Int(offs.get_typed[Int32](o))
    var end = Int(offs.get_typed[Int32](o + 1))
    var out = String("")
    for i in range(start, end):
        out += chr(Int(data.get_typed[UInt8](i)))
    return out


def _valid_at(imm batch: RecordBatch, col: Int, row: Int) raises -> Bool:
    """The output column's VALIDITY at `row`. A column with no bitmap is
    all-valid, which is the state a dropped bitmap leaves it in."""
    ref c = batch.column_at(col)
    if not c._validity:
        return True
    ref bm = c._validity.value()
    return bm.test(c._offset + row)


# -----------------------------------------------------------------------------
# Shape builders — the SAME rows, sharded two ways
# -----------------------------------------------------------------------------


def _int_partitions(total: Int, nparts: Int) raises -> Slab[RecordBatch]:
    """`total` ascending keys [0, total) dealt ROUND-ROBIN over `nparts`
    partitions, so every partition is itself ascending (the merge's
    precondition) and no partition is a contiguous key block (so the merge does
    real work rather than degenerating into a concatenation)."""
    var parts = Slab[RecordBatch]()
    for p in range(nparts):
        var keys = List[Int64]()
        var i = p
        while i < total:
            keys.append(Int64(i))
            i += nparts
        parts.append(_int_batch(keys^))
    return parts^


def _str_partitions(total: Int, nparts: Int) raises -> Slab[RecordBatch]:
    """As `_int_partitions`, with STRING keys and no nulls."""
    var parts = Slab[RecordBatch]()
    for p in range(nparts):
        var keys = List[String]()
        var pay = List[Int64]()
        var i = p
        while i < total:
            keys.append(_key_name(i))
            pay.append(Int64(i))
            i += nparts
        var n = len(pay)
        parts.append(_str_batch(keys^, _all_valid(n), pay^))
    return parts^


struct _Census(Movable):
    var bytes: Int
    var allocs: Int

    def __init__(out self, bytes: Int, allocs: Int):
        self.bytes = bytes
        self.allocs = allocs


def _census_of_int_merge(total: Int, nparts: Int) raises -> _Census:
    var parts = _int_partitions(total, nparts)
    reset_join_build_fold_census()
    var merged = merge_sorted_partitions_single_key_serial(parts^, "k", False)
    var c = _Census(join_build_fold_bytes(), join_build_fold_allocs())
    # The merge must still be CORRECT in both shapes, or "the two shapes agree"
    # is agreement about a wrong answer.
    var got = _read_int64_col(merged, 0)
    assert_equal(len(got), total)
    for i in range(total):
        assert_equal(Int(got[i]), i)
    _ = merged^
    return c^


def _census_of_string_merge[
    parallel: Bool
](total: Int, nparts: Int) raises -> _Census:
    var parts = _str_partitions(total, nparts)
    reset_join_build_fold_census()

    comptime if parallel:
        var merged = merge_sorted_partitions_single_key_string_parallel_serial(
            parts^, "k", False
        )
        var c = _Census(join_build_fold_bytes(), join_build_fold_allocs())
        assert_equal(merged.num_rows(), total)
        for i in range(total):
            assert_equal(_string_at(merged, 0, i), _key_name(i))
        _ = merged^
        return c^
    else:
        var merged = merge_sorted_partitions_single_key_string(
            parts^, "k", False
        )
        var c = _Census(join_build_fold_bytes(), join_build_fold_allocs())
        assert_equal(merged.num_rows(), total)
        for i in range(total):
            assert_equal(_string_at(merged, 0, i), _key_name(i))
        _ = merged^
        return c^


def _assert_shape_independent(
    imm a: _Census, imm b: _Census, label: String
) raises:
    """THE load-bearing assertion. Same rows, different sharding => same copy.

    Deliberately NOT `<= some threshold`: a threshold at one partition count is
    satisfiable by a still-quadratic fold. Only AGREEMENT across two shardings
    distinguishes O(n) from O(n * np)."""
    # The census is printed before the assertions, so a red run shows the
    # numbers.
    print(
        "[fold-census] ", label,
        " 4parts=", a.allocs, "allocs/", a.bytes, "B",
        " 16parts=", b.allocs, "allocs/", b.bytes, "B",
        sep="",
    )
    var msg_bytes = (
        label
        + ": the fold copied a different number of BYTES for the SAME rows"
        + " sharded two ways (4 parts: "
        + String(a.bytes)
        + " B, 16 parts: "
        + String(b.bytes)
        + " B) — it is still quadratic in the PARTITION count"
    )
    assert_true(a.bytes == b.bytes, msg_bytes)
    var msg_allocs = (
        label
        + ": the fold made a different number of ALLOCATIONS for the SAME rows"
        + " sharded two ways (4 parts: "
        + String(a.allocs)
        + ", 16 parts: "
        + String(b.allocs)
        + ")"
    )
    assert_true(a.allocs == b.allocs, msg_allocs)


# -----------------------------------------------------------------------------
# COST: the INT merge
# -----------------------------------------------------------------------------


def test_int_merge_fold_is_shape_independent() raises:
    var a = _census_of_int_merge(4096, 4)
    var b = _census_of_int_merge(4096, 16)
    _assert_shape_independent(a, b, "merge_sorted_partitions_single_key")
    # The census must have seen the fold: two zeroes agree and prove nothing.
    assert_true(
        a.allocs > 0 and a.bytes > 0,
        "int merge emitted NO census — the guard would compare 0 == 0",
    )


# -----------------------------------------------------------------------------
# COST: the STRING serial merge
# -----------------------------------------------------------------------------


def test_string_serial_merge_fold_is_shape_independent() raises:
    var a = _census_of_string_merge[False](1024, 4)
    var b = _census_of_string_merge[False](1024, 16)
    _assert_shape_independent(
        a, b, "merge_sorted_partitions_single_key_string"
    )
    assert_true(
        a.allocs > 0 and a.bytes > 0,
        "string serial merge emitted NO census",
    )


# -----------------------------------------------------------------------------
# COST: the STRING parallel merge (the sort sink's STRING finalize)
# -----------------------------------------------------------------------------


def test_string_parallel_merge_fold_is_shape_independent() raises:
    var a = _census_of_string_merge[True](1024, 4)
    var b = _census_of_string_merge[True](1024, 16)
    _assert_shape_independent(
        a, b, "merge_sorted_partitions_single_key_string_parallel"
    )
    assert_true(
        a.allocs > 0 and a.bytes > 0,
        "string parallel merge emitted NO census",
    )


# -----------------------------------------------------------------------------
# ORDER: the fold's slot order is the merge's run boundaries
# -----------------------------------------------------------------------------

# Sizes 100/300/200/400, uneven on purpose (see ORDER in the header).
comptime _UNEVEN_TOTAL: Int = 1000


def _uneven_bucket(i: Int) -> Int:
    """Deal key `i` to one of four partitions of sizes 100/300/200/400, keeping
    every partition ASCENDING and interleaved with the others."""
    var m = i % 10
    if m == 0:
        return 0
    if m <= 3:
        return 1
    if m <= 5:
        return 2
    return 3


def _uneven_int_partitions() raises -> Slab[RecordBatch]:
    var parts = Slab[RecordBatch]()
    for p in range(4):
        var keys = List[Int64]()
        for i in range(_UNEVEN_TOTAL):
            if _uneven_bucket(i) == p:
                keys.append(Int64(i))
        parts.append(_int_batch(keys^))
    return parts^


def test_int_merge_is_sorted_under_uneven_partitions() raises:
    var parts = _uneven_int_partitions()
    # The fixture's premise: equal sizes would make the guard vacuous.
    assert_equal(parts[0].num_rows(), 100)
    assert_equal(parts[1].num_rows(), 300)
    assert_equal(parts[2].num_rows(), 200)
    assert_equal(parts[3].num_rows(), 400)

    var merged = merge_sorted_partitions_single_key_serial(parts^, "k", False)
    var k = _read_int64_col(merged, 0)
    var v = _read_int64_col(merged, 1)
    assert_equal(len(k), _UNEVEN_TOTAL)
    for i in range(_UNEVEN_TOTAL):
        assert_true(
            Int(k[i]) == i,
            "merge_sorted_partitions_single_key: output row "
            + String(i)
            + " should hold key "
            + String(i)
            + " but holds "
            + String(Int(k[i]))
            + ": the merge emitted an UNSORTED result (the fold no longer"
            + " visits the slab in slot order)",
        )
        # "v" travels with "k": the key column is sorted whatever the payload
        # does, so the payload is what shows the columns stayed in step.
        assert_true(
            Int(v[i]) == i,
            "merge_sorted_partitions_single_key: payload column drifted out of"
            " step with the key at output row " + String(i),
        )
    _ = merged^


def _uneven_str_partitions() raises -> Slab[RecordBatch]:
    var parts = Slab[RecordBatch]()
    for p in range(4):
        var keys = List[String]()
        var pay = List[Int64]()
        for i in range(_UNEVEN_TOTAL):
            if _uneven_bucket(i) == p:
                keys.append(_key_name(i))
                pay.append(Int64(i))
        var n = len(pay)
        parts.append(_str_batch(keys^, _all_valid(n), pay^))
    return parts^


def test_string_parallel_merge_is_sorted_under_uneven_partitions() raises:
    var parts = _uneven_str_partitions()
    assert_equal(parts[0].num_rows(), 100)
    assert_equal(parts[3].num_rows(), 400)

    var merged = merge_sorted_partitions_single_key_string_parallel_serial(
        parts^, "k", False
    )
    assert_equal(merged.num_rows(), _UNEVEN_TOTAL)
    var pay = _read_int64_col(merged, 1)
    for i in range(_UNEVEN_TOTAL):
        assert_true(
            _string_at(merged, 0, i) == _key_name(i),
            "merge_sorted_partitions_single_key_string_parallel: output row "
            + String(i)
            + " should hold key "
            + _key_name(i)
            + " but holds "
            + _string_at(merged, 0, i)
            + ": the merge emitted an UNSORTED result",
        )
        assert_true(
            Int(pay[i]) == i,
            "merge_sorted_partitions_single_key_string_parallel: payload"
            " column drifted out of step with the key at output row "
            + String(i),
        )
    _ = merged^


# -----------------------------------------------------------------------------
# NULLS: the STRING merges read the bitmap the fold carries
# -----------------------------------------------------------------------------

comptime _NULLS_PER_PART: Int = 3
comptime _VALID_PER_PART: Int = 40
comptime _NULL_PARTS: Int = 4


def _nulls_first_partitions() raises -> Slab[RecordBatch]:
    """Four partitions, each ALREADY sorted under the contract the merge
    assumes: NULLS FIRST, then valid keys ascending.

    Payload is -1 for a null row, the key index otherwise."""
    var parts = Slab[RecordBatch]()
    for p in range(_NULL_PARTS):
        var keys = List[String]()
        var valid = List[Bool]()
        var pay = List[Int64]()
        for _ in range(_NULLS_PER_PART):
            keys.append(_NULL_PLACEHOLDER)
            valid.append(False)
            pay.append(Int64(-1))
        var i = p
        while i < _VALID_PER_PART * _NULL_PARTS:
            keys.append(_key_name(i))
            valid.append(True)
            pay.append(Int64(i))
            i += _NULL_PARTS
        parts.append(_str_batch(keys^, valid^, pay^))

    # The input must carry a bitmap, or the guard has nothing to lose
    # (`from_strings_with_validity` returns no bitmap for an all-valid mask).
    for p in range(_NULL_PARTS):
        assert_true(
            parts[p].column_at(0)._validity.__bool__(),
            "vacuous fixture: partition "
            + String(p)
            + " has NO validity bitmap, so this guard could not detect one"
            + " being dropped",
        )
        assert_true(
            not _valid_at(parts[p], 0, 0),
            "vacuous fixture: partition "
            + String(p)
            + " row 0 should be the first of its NULL keys",
        )
    return parts^


def _assert_nulls_first(imm merged: RecordBatch, label: String) raises:
    var total_nulls = _NULLS_PER_PART * _NULL_PARTS
    var total = total_nulls + _VALID_PER_PART * _NULL_PARTS
    assert_equal(merged.num_rows(), total)

    # Validity is what discriminates (see NULLS in the header): with the
    # bitmap dropped the rows stay in place but read as valid ''.

    for r in range(total_nulls):
        assert_true(
            not _valid_at(merged, 0, r),
            String(label) + ": output row " + String(r)
            + " should be a NULL key (NULLS FIRST on ASC) but is valid,"
            + " holding '" + _string_at(merged, 0, r) + "': the fold dropped"
            + " the key column's validity bitmap",
        )
    for r in range(total_nulls, total):
        assert_true(
            _valid_at(merged, 0, r),
            String(label) + ": output row " + String(r)
            + " should be a VALID key but reads null",
        )
        assert_equal(_string_at(merged, 0, r), _key_name(r - total_nulls))


def test_string_serial_merge_keeps_null_keys_first() raises:
    var parts = _nulls_first_partitions()
    var merged = merge_sorted_partitions_single_key_string(parts^, "k", False)
    _assert_nulls_first(merged, "merge_sorted_partitions_single_key_string")
    _ = merged^


def test_string_parallel_merge_keeps_null_keys_first() raises:
    var parts = _nulls_first_partitions()
    var merged = merge_sorted_partitions_single_key_string_parallel_serial(
        parts^, "k", False
    )
    _assert_nulls_first(
        merged, "merge_sorted_partitions_single_key_string_parallel"
    )
    _ = merged^


def main() raises:
    test_int_merge_fold_is_shape_independent()
    test_string_serial_merge_fold_is_shape_independent()
    test_string_parallel_merge_fold_is_shape_independent()
    test_int_merge_is_sorted_under_uneven_partitions()
    test_string_parallel_merge_is_sorted_under_uneven_partitions()
    test_string_serial_merge_keeps_null_keys_first()
    test_string_parallel_merge_keeps_null_keys_first()
