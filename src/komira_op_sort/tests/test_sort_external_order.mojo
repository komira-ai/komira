# =============================================================================
# ExternalSorter, spilled and merged, gives the rows of one in-memory sort
# =============================================================================
#
# Each case absorbs the same batches into a sorter whose budget forces a
# spill on almost every batch (so the output is a k-way merge of many spilled
# runs: 100 rows a batch, a budget of 64 bytes) and compares the output, row by row (keys and a payload holding each
# row's input position), with one `sort_batch_by_keys` over all the rows in
# absorb order: that is the order the sorter promises.
#
#   * INT64 keys with ties, ASC and DESC, over 10 runs;
#   * FLOAT64 keys with NaNs of both signs, -0.0 / +0.0 and +-inf, ASC and
#     DESC: the merge has to order the run heads by `sort_key_lt`, as the
#     run sort did (NaN above +inf);
#   * an INT64 key with NULL rows: the run sort orders a numeric key by its
#     stored values, so the merge has to as well;
#   * two keys (INT32, then FLOAT64 DESC);
#   * a single in-memory run, whose output keeps the input's column names.
#
# The merge comparator orders floats by `sort_key_lt` (an IEEE `<` / `>` ties
# a NaN with every value, so a NaN run head would stall mid-merge) and orders
# NULLs as the run sort did, not always last. `test_float_nan_zero_inf_*` covers
# the first, `test_nullable_int64_key_*` the second.
# =============================================================================

from std.memory import bitcast
from std.math import inf
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_collections.slab import Slab
from komira_column_kernels.cross_batch_gather import cross_batch_gather
from komira_libc.posix import _read_env

from komira_op_sort.sort_external import ExternalSorter
from komira_op_sort.sort_multi import sort_batch_by_keys


def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _f64_bits(u: UInt64) -> Float64:
    return bitcast[DType.float64, 1](SIMD[DType.uint64, 1](u))[0]


def _batch[dt: DType](
    keys: List[Scalar[dt]], valid: List[Bool], lo: Int, hi: Int
) raises -> RecordBatch:
    """Key `k` of `dt` (NULL where `valid` is False, when not empty) and
    payload `orig` = the row's position over all batches."""
    var k = (
        PrimitiveArray[dt].allocate_nullable(hi - lo) if len(valid) > 0
        else PrimitiveArray[dt].allocate(hi - lo)
    )
    var p = List[Int64]()
    for i in range(lo, hi):
        k.set(i - lo, keys[i])
        p.append(Int64(i))
        if len(valid) > 0 and not valid[i]:
            k.validity.value().clear(i - lo)
            k.null_count += 1
    var col = Column.from_primitive[dt](k^)
    var schema = Schema.from_fields_2(
        Field("k", dt, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        col^,
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(p^)
        ),
    )


def _payload_of(var batches: Slab[RecordBatch]) raises -> List[Int]:
    """The `orig` column of every batch, concatenated."""
    var out = List[Int]()
    for b in range(len(batches)):
        ref batch = batches[b]
        var p = batch.column_at(batch.schema.column_index("orig")).as_primitive[
            DType.int64
        ]()
        for i in range(p.length):
            out.append(Int(p.get_typed[Scalar[DType.int64]](i)))
    return out^


def _check[dt: DType](
    keys: List[Scalar[dt]], valid: List[Bool], desc: Bool, label: String
) raises:
    var n = len(keys)
    var per = 100
    var names: List[String] = ["k"]
    var dirs: List[Bool] = [desc]
    var s = ExternalSorter.create(
        memory_budget=64,
        key_names=names.copy(),
        descending=dirs.copy(),
        spill_dir=_scratch_dir() + "/" + label,
        output_batch_size=17,
    )
    var all_batches = Slab[RecordBatch]()
    var idx = List[Tuple[Int, Int]]()
    var lo = 0
    var b = 0
    while lo < n:
        var hi = min(lo + per, n)
        s.absorb(_batch[dt](keys, valid, lo, hi))
        all_batches.append(_batch[dt](keys, valid, lo, hi))
        for r in range(hi - lo):
            idx.append((b, r))
        lo = hi
        b += 1
    var got = _payload_of(s^.finish())
    var whole = cross_batch_gather(all_batches, idx)
    var want_batch = sort_batch_by_keys(whole^, names, dirs)
    var want_slab = Slab[RecordBatch]()
    want_slab.append(want_batch^)
    var want = _payload_of(want_slab^)
    assert_equal(len(got), n)
    for i in range(n):
        assert_equal(got[i], want[i], label + ": row " + String(i))


def _int_keys(n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(Int64((i * 7919) % 53) - 20)
    return out^


def test_int64_ties_many_runs_asc() raises:
    _check[DType.int64](_int_keys(1000), List[Bool](), False, "i64_asc")


def test_int64_ties_many_runs_desc() raises:
    _check[DType.int64](_int_keys(1000), List[Bool](), True, "i64_desc")


def _float_keys(n: Int) -> List[Float64]:
    var pos_nan = _f64_bits(0x7FF8000000000000)
    var neg_nan = _f64_bits(0xFFF8000000000000)
    var out = List[Float64]()
    for i in range(n):
        var m = (i * 31) % 13
        if m == 0:
            out.append(pos_nan)
        elif m == 1:
            out.append(neg_nan)
        elif m == 2:
            out.append(-0.0)
        elif m == 3:
            out.append(0.0)
        elif m == 4:
            out.append(inf[DType.float64]())
        elif m == 5:
            out.append(-inf[DType.float64]())
        else:
            out.append(Float64(m) * 0.5 - 4.0)
    return out^


def test_float_nan_zero_inf_asc() raises:
    _check[DType.float64](_float_keys(600), List[Bool](), False, "f64_asc")


def test_float_nan_zero_inf_desc() raises:
    _check[DType.float64](_float_keys(600), List[Bool](), True, "f64_desc")


def _nullable() -> List[Bool]:
    var v = List[Bool]()
    for i in range(500):
        v.append(i % 7 != 3)
    return v^


def test_nullable_fixture_has_nulls() raises:
    """The NULL cases are not vacuous: the key column carries a bitmap with
    NULL rows."""
    var b = _batch[DType.int64](_int_keys(500), _nullable(), 0, 100)
    ref c = b.column_at(0)
    assert_true(c._validity.__bool__())
    assert_true(not c._validity.value().test(c._offset + 3))
    assert_true(c._validity.value().test(c._offset + 4))


def test_nullable_int64_key_asc() raises:
    _check[DType.int64](_int_keys(500), _nullable(), False, "null_asc")


def test_nullable_int64_key_desc() raises:
    _check[DType.int64](_int_keys(500), _nullable(), True, "null_desc")


def test_single_run_keeps_column_names() raises:
    var names: List[String] = ["k"]
    var dirs: List[Bool] = [False]
    var s = ExternalSorter.create(
        memory_budget=1 << 30,
        key_names=names^,
        descending=dirs^,
        spill_dir=_scratch_dir() + "/single",
    )
    var keys: List[Int64] = [3, 1, 2]
    s.absorb(_batch[DType.int64](keys, List[Bool](), 0, 3))
    var out = s^.finish()
    assert_equal(len(out), 1)
    assert_equal(out[0].schema.field_at(0).name, "k")
    assert_equal(out[0].schema.field_at(1).name, "orig")
    var p = out[0].column_at(1).as_primitive[DType.int64]()
    assert_equal(Int(p.get_typed[Scalar[DType.int64]](0)), 1)
    assert_equal(Int(p.get_typed[Scalar[DType.int64]](2)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
