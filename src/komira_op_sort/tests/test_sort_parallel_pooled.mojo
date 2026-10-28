# =============================================================================
# sort_parallel: the pooled entries give the serial sort's rows
# =============================================================================
#
# Every other sort_parallel test runs the `*_serial` entries, which execute the
# chunks inline. These tests run the pooled entries on a started runtime with
# four workers, so the slices are sorted and merged on different threads (the
# disjoint-slice writes and the ping-pong buffers of the merge rounds), and the
# gather runs on the pool too. Each case sorts the same batch through
# `sort_topn_sink._sort_batch_single_key` and requires equal key bytes and an
# equal payload column (each row's input index, so ties are checked to keep
# input order).
#
#   * INT64 (ascending, descending, both extremes), INT32, FLOAT64 (NaN and
#     both zeros);
#   * a 70,000-row INT64 sort, above the row floor of the parallel gather;
#   * STRING and BINARY sorts;
#   * the numeric merge and the STRING merge of sorted partitions.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab

from komira_op_sort.sort_parallel import (
    merge_sorted_partitions_single_key,
    parallel_sort_single_key,
)
from komira_op_sort.sort_parallel_string import (
    merge_sorted_partitions_single_key_string_parallel,
    parallel_sort_single_key_string,
)
from komira_op_sort.sort_topn_sink import _sort_batch_single_key


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime(n_workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


struct _Lcg(Copyable, Movable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return self.state >> 11


# -----------------------------------------------------------------------------
# Fixtures and comparison
# -----------------------------------------------------------------------------


def _num_batch[dt: DType](
    keys: List[Scalar[dt]], first: Int = 0
) raises -> RecordBatch:
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


def _text_batch(
    keys: List[String], first: Int = 0
) raises -> RecordBatch:
    var payload = List[Int64]()
    for i in range(len(keys)):
        payload.append(Int64(first + i))
    var schema = Schema.from_fields_2(
        Field("k", ArrowType.STRING, True), Field("orig", DType.int64, True)
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_string(StringArray.from_strings(keys)),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(payload^)
        ),
    )


def _binary_batch(
    rows: List[List[UInt8]], first: Int = 0
) raises -> RecordBatch:
    var payload = List[Int64]()
    for i in range(len(rows)):
        payload.append(Int64(first + i))
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


def _assert_same_payload(imm a: RecordBatch, imm b: RecordBatch) raises:
    assert_equal(a.num_rows(), b.num_rows())
    var pa = a.column_at(1).as_primitive[DType.int64]()
    var pb = b.column_at(1).as_primitive[DType.int64]()
    for r in range(a.num_rows()):
        assert_equal(
            Int(pa.get_typed[Scalar[DType.int64]](r)),
            Int(pb.get_typed[Scalar[DType.int64]](r)),
        )


def _assert_same_num[dt: DType](imm a: RecordBatch, imm b: RecordBatch) raises:
    var ka = a.column_at(0).as_primitive[dt]()
    var kb = b.column_at(0).as_primitive[dt]()
    assert_equal(ka.length, kb.length)
    for i in range(ka.length):
        var x = ka.get_typed[Scalar[dt]](i)
        var y = kb.get_typed[Scalar[dt]](i)
        assert_true(x == y or (x != x and y != y))
    _assert_same_payload(a, b)


def _assert_same_bytes(imm a: RecordBatch, imm b: RecordBatch) raises:
    """Equal key bytes (STRING or BINARY) and an equal payload, row by row."""
    assert_equal(a.num_rows(), b.num_rows())
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
    _assert_same_payload(a, b)


def _i64_keys(n: Int, seed: UInt64, modulus: Int) -> List[Int64]:
    var r = _Lcg(seed)
    var keys = List[Int64]()
    for _ in range(n):
        var v = Int(r.next() % UInt64(modulus))
        keys.append(Int64(v - modulus // 2))
    return keys^


def _words(n: Int, seed: UInt64) -> List[String]:
    var r = _Lcg(seed)
    var alpha: List[String] = [
        "", "a", "ab", "abcdefghijklmnop", "abcdefghijklmnopq",
        "abcdefghijklmnopr", "b", "zz", "tag_1", "tag_10", "tag_2",
    ]
    var out = List[String]()
    for _ in range(n):
        out.append(alpha[Int(r.next() % UInt64(len(alpha)))])
    return out^


# -----------------------------------------------------------------------------
# Numeric sorts
# -----------------------------------------------------------------------------


def test_pooled_int64_sort_matches_serial() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    assert_true(
        disp.worker_count() >= 2, "a 1-worker pool would run the chunks inline"
    )
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    var keys = _i64_keys(6000, 3, 40)
    for desc in [False, True]:
        for nw in [1, 2, 4, 7]:
            var par = parallel_sort_single_key[True, origin_of(disp)](
                _num_batch[DType.int64](keys), "k", desc, h, nw
            )
            var ser = _sort_batch_single_key(
                _num_batch[DType.int64](keys), "k", desc
            )
            _assert_same_num[DType.int64](par, ser)
    rt.shutdown()


def test_pooled_int64_sort_with_both_extremes() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    var keys = List[Int64]()
    for i in range(3000):
        var c = (i * 2654435761) % 5
        if c == 0:
            keys.append(Int64.MIN)
        elif c == 1:
            keys.append(Int64.MAX)
        else:
            keys.append(Int64(i % 7) - 3)
    for desc in [False, True]:
        for nw in [2, 4]:
            var par = parallel_sort_single_key[True, origin_of(disp)](
                _num_batch[DType.int64](keys), "k", desc, h, nw
            )
            var ser = _sort_batch_single_key(
                _num_batch[DType.int64](keys), "k", desc
            )
            _assert_same_num[DType.int64](par, ser)
    rt.shutdown()


def test_pooled_int64_sort_above_the_parallel_gather_floor() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    var keys = _i64_keys(70000, 11, 1000)
    for desc in [False, True]:
        var par = parallel_sort_single_key[True, origin_of(disp)](
            _num_batch[DType.int64](keys), "k", desc, h, 4
        )
        var ser = _sort_batch_single_key(
            _num_batch[DType.int64](keys), "k", desc
        )
        _assert_same_num[DType.int64](par, ser)
    rt.shutdown()


def test_pooled_int32_and_float64_sorts_match_serial() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    var r = _Lcg(21)
    var k32 = List[Int32]()
    var kf = List[Float64]()
    var nan_pos = bitcast[DType.float64, 1](
        SIMD[DType.uint64, 1](0x7FF8000000000000)
    )[0]
    var nan_neg = bitcast[DType.float64, 1](
        SIMD[DType.uint64, 1](0xFFF8000000000001)
    )[0]
    var specials: List[Float64] = [0.0, -0.0, 1.5, -1.5, nan_pos, nan_neg, 7.25]
    for _ in range(4000):
        k32.append(Int32(Int(r.next() % 50)) - 25)
        kf.append(specials[Int(r.next() % UInt64(len(specials)))])
    for desc in [False, True]:
        for nw in [2, 5]:
            _assert_same_num[DType.int32](
                parallel_sort_single_key[True, origin_of(disp)](
                    _num_batch[DType.int32](k32), "k", desc, h, nw
                ),
                _sort_batch_single_key(_num_batch[DType.int32](k32), "k", desc),
            )
            _assert_same_num[DType.float64](
                parallel_sort_single_key[True, origin_of(disp)](
                    _num_batch[DType.float64](kf), "k", desc, h, nw
                ),
                _sort_batch_single_key(
                    _num_batch[DType.float64](kf), "k", desc
                ),
            )
    rt.shutdown()


def test_pooled_numeric_partition_merge_matches_one_sort() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    for desc in [False, True]:
        var parts = Slab[RecordBatch]()
        var all_keys = List[Int64]()
        var orig = 0
        for p in range(4):
            var pk = _i64_keys(700, UInt64(31 + p), 20)
            for i in range(len(pk)):
                all_keys.append(pk[i])
            parts.append(
                _sort_batch_single_key(
                    _num_batch[DType.int64](pk, orig), "k", desc
                )
            )
            orig += 700
        var merged = merge_sorted_partitions_single_key[True, origin_of(disp)](
            parts^, "k", desc, h
        )
        _assert_same_num[DType.int64](
            merged,
            _sort_batch_single_key(
                _num_batch[DType.int64](all_keys), "k", desc
            ),
        )
    rt.shutdown()


# -----------------------------------------------------------------------------
# STRING and BINARY
# -----------------------------------------------------------------------------


def test_pooled_string_sort_matches_serial() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    var keys = _words(5000, 41)
    for desc in [False, True]:
        for nw in [1, 2, 4, 7]:
            var par = parallel_sort_single_key_string[True, origin_of(disp)](
                _text_batch(keys), "k", desc, h, nw
            )
            var ser = _sort_batch_single_key(_text_batch(keys), "k", desc)
            _assert_same_bytes(par, ser)
    rt.shutdown()


def test_pooled_binary_sort_matches_serial() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    var r = _Lcg(51)
    var rows = List[List[UInt8]]()
    for _ in range(3000):
        var v = r.next()
        var row: List[UInt8] = [UInt8(0x61), UInt8(0x62), UInt8(0x00)]
        if v % 4 == 0:
            row = [UInt8(0x61), UInt8(0x62)]
        else:
            row.append(UInt8(Int((v >> 8) % 5)))
        rows.append(row^)
    for desc in [False, True]:
        for nw in [2, 4]:
            var par = parallel_sort_single_key_string[True, origin_of(disp)](
                _binary_batch(rows), "k", desc, h, nw
            )
            var ser = _sort_batch_single_key(_binary_batch(rows), "k", desc)
            _assert_same_bytes(par, ser)
    rt.shutdown()


def test_pooled_string_partition_merge_matches_one_sort() raises:
    var rt = _started_runtime(4)
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        )
    )
    for desc in [False, True]:
        for nw in [2, 4]:
            var parts = Slab[RecordBatch]()
            var all_keys = List[String]()
            var orig = 0
            for p in range(5):
                var pk = _words(500, UInt64(61 + p))
                for i in range(len(pk)):
                    all_keys.append(pk[i])
                parts.append(
                    _sort_batch_single_key(_text_batch(pk, orig), "k", desc)
                )
                orig += 500
            var merged = merge_sorted_partitions_single_key_string_parallel[
                True, origin_of(disp)
            ](parts^, "k", desc, h, nw)
            _assert_same_bytes(
                merged,
                _sort_batch_single_key(_text_batch(all_keys), "k", desc),
            )
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
