# The parallel composite build against the serial `MultiKeyHashJoinBuilder.build`
# under every probe kind (INNER, LEFT, SEMI, ANTI, RIGHT, FULL): for 1, 2 and 4
# pool workers and chunk sizes from one row to larger than the build, on INT64
# keys with NULL-keyed rows and duplicates, and on FLOAT64 (NaN, -0.0, NULL),
# STRING (empty, duplicates, NULL) and DICTIONARY (NULL) keys extracted from
# record batches. Also: a build whose rows all share one bucket keeps every
# row on its chain exactly once at every chunk size, and a cancelled token
# makes a pooled build raise and leave a usable pool behind.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken

from komira_op_join_build.hash_chain_build_settings import (
    JOIN_PARALLEL_BUILD_FORCE,
    join_parallel_build_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key import MultiKeyColumns, _CHAIN_END
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_anti,
    multi_key_probe_semi,
)
from komira_op_join_probe.join_multi_key_outer import (
    multi_key_probe_full_into,
    multi_key_probe_right_into,
)
from komira_op_join_probe.join_multi_key_parallel_build import (
    multi_key_hash_join_build_parallel,
)


comptime I64 = DType.int64
comptime _ENC: Int = 1_000_000


def _begin() raises:
    """FORCE (so the small builds here take the parallel wave) from the default
    settings, whatever an earlier test configured."""
    reset_hash_chain_build_settings()
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def _encode(imm bm: List[Int], imm pm: List[Int]) -> List[Int]:
    var enc = List[Int]()
    for i in range(len(bm)):
        enc.append((bm[i] + 1) * _ENC + (pm[i] + 1))
    return _sorted(enc^)


def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var arr = PrimitiveArray[I64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return arr^


def _int_columns(imm cols: List[List[Int64]]) raises -> MultiKeyColumns:
    var n_keys = len(cols)
    var ik = Slab[PrimitiveArray[I64]].create(n_keys)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(n_keys)
    var dk = Slab[Optional[StringDictionaryArray]].create(n_keys)
    var fps = List[UInt64]()
    for k in range(n_keys):
        ik.append(_i64_arr(cols[k]))
        sk.append(Optional[StringArray[HeapRegion]](None))
        dk.append(Optional[StringDictionaryArray](None))
        fps.append(UInt64(0))
    return MultiKeyColumns(ik^, sk^, dk^, fps^, n_keys)


struct _Results(Movable):
    """Every probe kind's sorted encoded answer over one builder."""

    var inner: List[Int]
    var left: List[Int]
    var semi: List[Int]
    var anti: List[Int]
    var right: List[Int]
    var full: List[Int]

    def __init__(
        out self,
        var inner: List[Int],
        var left: List[Int],
        var semi: List[Int],
        var anti: List[Int],
        var right: List[Int],
        var full: List[Int],
    ):
        self.inner = inner^
        self.left = left^
        self.semi = semi^
        self.anti = anti^
        self.right = right^
        self.full = full^


def _probe_cols(which: Int) raises -> MultiKeyColumns:
    """The probe side's key columns: 0..3 the typed key sets, 9 the INT64 one.
    Built afresh per call because every probe consumes its columns."""
    if which == 9:
        return _int_columns(_int_probe_cols())
    return extract_join_key_columns_serial(
        _typed_probe_batch(), _typed_keys(which)
    )


def _probe_all(
    imm builder: MultiKeyHashJoinBuilder, which: Int
) raises -> _Results:
    var ibm = List[Int]()
    var ipm = List[Int]()
    builder.probe_inner_into(_probe_cols(which), ibm, ipm)
    var lbm = List[Int]()
    var lpm = List[Int]()
    builder.probe_left_into(_probe_cols(which), lbm, lpm)
    var semi = multi_key_probe_semi(builder, _probe_cols(which))
    var anti = multi_key_probe_anti(builder, _probe_cols(which))
    var rbm = List[Int]()
    var rpm = List[Int]()
    multi_key_probe_right_into(builder, _probe_cols(which), rbm, rpm)
    var fbm = List[Int]()
    var fpm = List[Int]()
    multi_key_probe_full_into(builder, _probe_cols(which), fbm, fpm)
    return _Results(
        _encode(ibm, ipm),
        _encode(lbm, lpm),
        _sorted(semi^),
        _sorted(anti^),
        _encode(rbm, rpm),
        _encode(fbm, fpm),
    )


def _assert_same(imm a: List[Int], imm b: List[Int], msg: String) raises:
    assert_equal(len(a), len(b), msg + ": result size")
    for i in range(len(a)):
        assert_equal(a[i], b[i], msg + ": element " + String(i))


def _assert_results_same(
    imm ser: _Results, imm par: _Results, msg: String
) raises:
    _assert_same(ser.inner, par.inner, msg + " INNER")
    _assert_same(ser.left, par.left, msg + " LEFT")
    _assert_same(ser.semi, par.semi, msg + " SEMI")
    _assert_same(ser.anti, par.anti, msg + " ANTI")
    _assert_same(ser.right, par.right, msg + " RIGHT")
    _assert_same(ser.full, par.full, msg + " FULL")


def _chain_rows(imm builder: MultiKeyHashJoinBuilder) raises -> List[Int]:
    """Every row reachable from a chain head, sorted. The walk is bounded by
    the build's row count, so a cyclic chain raises by name instead of hanging.
    """
    var out = List[Int]()
    for slot in range(builder._capacity):
        var cur = builder._hash_table[slot]
        var steps = 0
        while cur != _CHAIN_END:
            out.append(cur)
            cur = builder._next_chain[cur]
            steps += 1
            if steps > builder.num_rows():
                raise Error(
                    "_chain_rows: a chain cycles (more links than build rows)"
                    " at bucket " + String(slot)
                )
    return _sorted(out^)


def _parallel_int_build(
    imm cols: List[List[Int64]], workers: Int, chunk_rows: Int
) raises -> MultiKeyHashJoinBuilder:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    comptime do = origin_of(disp)
    return multi_key_hash_join_build_parallel[
        True, LocalDispatcher[NoopSink], do
    ](
        _int_columns(cols),
        Optional[Pointer[LocalDispatcher[NoopSink], do]](Pointer(to=disp)),
        CancellationToken.never(),
        False,
        chunk_rows,
    )


def _parallel_typed_build(
    imm batch: RecordBatch,
    imm keys: List[String],
    workers: Int,
    chunk_rows: Int,
) raises -> MultiKeyHashJoinBuilder:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    comptime do = origin_of(disp)
    return multi_key_hash_join_build_parallel[
        True, LocalDispatcher[NoopSink], do
    ](
        extract_join_key_columns_serial(batch, keys),
        Optional[Pointer[LocalDispatcher[NoopSink], do]](Pointer(to=disp)),
        CancellationToken.never(),
        False,
        chunk_rows,
    )


# ---- INT64 fixture ----------------------------------------------------------

def _int_build_cols() -> List[List[Int64]]:
    """300 rows over (a, b): a small domain, so chains hold duplicates and rows
    that share `a` and differ in `b`; some probe keys never occur on the build
    side."""
    var a = List[Int64]()
    var b = List[Int64]()
    for i in range(300):
        a.append(Int64(i % 13))
        b.append(Int64((i * 5) % 7))
    return [a^, b^]


def _int_probe_cols() -> List[List[Int64]]:
    var a = List[Int64]()
    var b = List[Int64]()
    for i in range(150):
        a.append(Int64(i % 17))
        b.append(Int64((i * 3) % 8))
    return [a^, b^]


def test_every_probe_kind_agrees_across_workers_and_chunk_sizes() raises:
    """INNER, LEFT, SEMI, ANTI, RIGHT and FULL over the parallel table answer
    exactly what they answer over the serial table, for every pool width and
    chunk size, so no row is lost, duplicated or mis-bucketed whatever the
    split."""
    _begin()
    var cols = _int_build_cols()
    var ser = MultiKeyHashJoinBuilder.build(_int_columns(cols))
    var expect = _probe_all(ser, 9)
    assert_true(len(expect.inner) > 0, "the fixture has matches")
    assert_true(len(expect.anti) > 0, "the fixture has unmatched probe rows")
    var serial_rows = _chain_rows(ser)
    assert_equal(len(serial_rows), 300, "serial chains hold every row")

    var workers: List[Int] = [1, 2, 4]
    var chunks: List[Int] = [1, 2, 7, 64, 299, 300, 1000]
    for w in range(len(workers)):
        for c in range(len(chunks)):
            var par = _parallel_int_build(cols, workers[w], chunks[c])
            var tag = (
                "workers=" + String(workers[w]) + " chunk=" + String(chunks[c])
            )
            _assert_same(serial_rows, _chain_rows(par), tag + " chain rows")
            assert_equal(par._num_inserted, ser._num_inserted, tag)
            _assert_results_same(expect, _probe_all(par, 9), tag)
            _ = par^
    _ = ser^
    reset_hash_chain_build_settings()


def test_every_row_of_one_bucket_is_chained_once_at_every_chunk_size() raises:
    """Every build row has the same composite key, so every push contends for
    one chain head: each chunk size and pool width must leave each row on the
    chain exactly once."""
    _begin()
    var a = List[Int64]()
    var b = List[Int64]()
    for _ in range(1500):
        a.append(Int64(7))
        b.append(Int64(-3))
    var cols: List[List[Int64]] = [a^, b^]
    var workers: List[Int] = [2, 4]
    var chunks: List[Int] = [1, 3, 10, 250]
    for w in range(len(workers)):
        for c in range(len(chunks)):
            var par = _parallel_int_build(cols, workers[w], chunks[c])
            var rows = _chain_rows(par)
            var tag = (
                "workers=" + String(workers[w]) + " chunk=" + String(chunks[c])
            )
            assert_equal(len(rows), 1500, tag + ": rows on the chain")
            for r in range(1500):
                assert_equal(rows[r], r, tag + ": row missing or duplicated")
            assert_equal(par._num_inserted, 1500, tag + ": num_inserted")
            _ = par^
    reset_hash_chain_build_settings()


def test_repeated_pool_create_and_build_cycles() raises:
    """Twenty pools created, used for a contended build and destroyed in a row:
    a build that outlived its wave or left shared state behind shows up as a
    wrong chain here."""
    _begin()
    var a = List[Int64]()
    var b = List[Int64]()
    for i in range(400):
        a.append(Int64(i % 3))
        b.append(Int64(i % 2))
    var cols: List[List[Int64]] = [a^, b^]
    for round in range(20):
        var par = _parallel_int_build(cols, 4, 1 + (round % 5))
        var rows = _chain_rows(par)
        assert_equal(len(rows), 400, "round " + String(round))
        for r in range(400):
            assert_equal(rows[r], r, "round " + String(round) + " row")
        _ = par^
    reset_hash_chain_build_settings()


# ---- typed fixture: FLOAT64, STRING, DICTIONARY -----------------------------


def _f64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _string_array(
    imm values: List[String], imm nulls: List[Bool]
) raises -> StringArray[HeapRegion]:
    from std.sys import size_of

    comptime int32_size = size_of[Int32]()
    var n = len(values)
    var total = 0
    for i in range(n):
        if not nulls[i]:
            total += values[i].byte_length()
    var offsets = OwnedAlignedBuffer((n + 1) * int32_size)
    offsets.set_typed[Int32](0, Int32(0))
    var data = OwnedAlignedBuffer(max(total, 1))
    var off = 0
    var null_count = 0
    var bm = Bitmap.create(n)
    for i in range(n):
        if nulls[i]:
            bm.clear(i)
            null_count += 1
        else:
            bm.set(i)
            var len_i = values[i].byte_length()
            if len_i > 0:
                var src = ByteView(values[i].unsafe_ptr().bitcast[UInt8](), len_i)
                data.view_range_mut(off, len_i).copy_from_view_at(0, src)
            off += len_i
        offsets.set_typed[Int32](i + 1, Int32(off))
    offsets.set_length(Int64((n + 1) * int32_size))
    data.set_length(Int64(off))
    return StringArray[HeapRegion](
        offsets=offsets^,
        data=data^,
        validity=bm^,
        length=n,
        data_length=total,
        null_count=null_count,
    )


def _dict_column(
    imm indices: List[Int], imm nulls: List[Bool], imm dictionary: List[String]
) raises -> Column[HeapRegion]:
    var n = len(indices)
    var idx = PrimitiveArray[DType.int32].allocate_nullable(n)
    var p = idx._typed_ptr_mut()
    var null_count = 0
    for i in range(n):
        if nulls[i]:
            null_count += 1
            idx.validity.value().clear(i)
            p.store[width=1](i, Scalar[DType.int32](0))
        else:
            idx.validity.value().set(i)
            p.store[width=1](i, Scalar[DType.int32](indices[i]))
    idx.null_count = null_count
    var dict_arr = StringDictionaryArray.from_parts(
        idx^, StringArray.from_strings(dictionary)
    )
    return Column.from_dictionary(dict_arr)


def _typed_batch(n: Int, stride: Int) raises -> RecordBatch:
    """(f FLOAT64, s STRING, d DICTIONARY, i INT64): `f` cycles through NaN of
    several bit patterns, 0.0, -0.0 and ordinary values, with NULLs; `s` has
    duplicates, the empty string and NULLs; `d` has NULLs; `i` is small."""
    var f = PrimitiveArray[DType.float64].allocate_nullable(n)
    var iv = PrimitiveArray[DType.int64].allocate(n)
    var svals = List[String]()
    var snull = List[Bool]()
    var didx = List[Int]()
    var dnull = List[Bool]()
    var names: List[String] = ["", "a", "bb", "a", "long-key-with-bytes-\xc3\xa9", "bb"]
    for r in range(n):
        var i = r * stride
        var m = i % 8
        if m == 0:
            f.set(r, _f64(UInt64(0x7FF8000000000000)))
        elif m == 1:
            f.set(r, _f64(UInt64(0xFFF8000000000001)))
        elif m == 2:
            f.set(r, Float64(0.0))
        elif m == 3:
            f.set(r, _f64(UInt64(0x8000000000000000)))
        else:
            f.set(r, Float64(i % 5))
        if i % 13 == 5:
            f._set_null(r)
        svals.append(String(names[i % 6]))
        snull.append(i % 11 == 4)
        didx.append(i % 4)
        dnull.append(i % 9 == 2)
        iv.set(r, Int64(i % 3))
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("d", ArrowType.DICTIONARY, True))
    sb.add_field(Field("i", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.float64](f^))
    bb.add_column(Column.from_string(_string_array(svals, snull)))
    var dictionary: List[String] = ["red", "green", "blue", "red"]
    bb.add_column(_dict_column(didx, dnull, dictionary))
    bb.add_column(Column.from_primitive[DType.int64](iv^))
    return bb.build(sb.build())


def _typed_build_batch() raises -> RecordBatch:
    return _typed_batch(240, 1)


def _typed_probe_batch() raises -> RecordBatch:
    return _typed_batch(130, 3)


def _typed_keys(set_id: Int) -> List[String]:
    if set_id == 0:
        return ["f", "i"]
    if set_id == 1:
        return ["s", "i"]
    if set_id == 2:
        return ["d", "i"]
    return ["f", "s", "d"]


def test_float_string_and_dictionary_keys_agree_for_every_probe_kind() raises:
    """FLOAT64 keys (NaN of any bits, 0.0 and -0.0, NULL), STRING keys (empty,
    duplicate, NULL), DICTIONARY keys (NULL) and a three-type key: the parallel
    table answers every probe kind as the serial table does, so the key
    canonicalisation and the NULL rule hold under the wave."""
    _begin()
    var build = _typed_build_batch()
    for set_id in range(4):
        var keys = _typed_keys(set_id)
        var ser = MultiKeyHashJoinBuilder.build(
            extract_join_key_columns_serial(build, keys)
        )
        var expect = _probe_all(ser, set_id)
        assert_true(len(expect.inner) > 0, "key set " + String(set_id) + " joins")
        var serial_rows = _chain_rows(ser)

        var workers: List[Int] = [1, 3]
        var chunks: List[Int] = [1, 17, 1000]
        for w in range(len(workers)):
            for c in range(len(chunks)):
                var par = _parallel_typed_build(
                    build, keys, workers[w], chunks[c]
                )
                var tag = (
                    "keys=" + String(set_id) + " workers=" + String(workers[w])
                    + " chunk=" + String(chunks[c])
                )
                _assert_same(serial_rows, _chain_rows(par), tag + " chain rows")
                _assert_results_same(expect, _probe_all(par, set_id), tag)
                _ = par^
        _ = ser^
    reset_hash_chain_build_settings()


# ---- cancellation -----------------------------------------------------------


def test_a_cancelled_token_raises_and_leaves_a_usable_pool() raises:
    """A token cancelled before the pooled wave makes the build raise (naming
    the cancellation) and return no table; the same pool then builds normally."""
    _begin()
    var cols = _int_build_cols()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    comptime do = origin_of(disp)

    var token = CancellationToken.new()
    token.cancel(String("stop the build"))
    var raised = False
    try:
        var built = multi_key_hash_join_build_parallel[
            True, LocalDispatcher[NoopSink], do
        ](
            _int_columns(cols),
            Optional[Pointer[LocalDispatcher[NoopSink], do]](Pointer(to=disp)),
            token^,
            False,
            1,
        )
        _ = built^
    except e:
        raised = True
        assert_true(
            String(e).find("ancel") >= 0,
            "the error does not name the cancellation: " + String(e),
        )
    assert_true(raised, "a cancelled build returned a table")

    var ser = MultiKeyHashJoinBuilder.build(_int_columns(cols))
    var ok = multi_key_hash_join_build_parallel[
        True, LocalDispatcher[NoopSink], do
    ](
        _int_columns(cols),
        Optional[Pointer[LocalDispatcher[NoopSink], do]](Pointer(to=disp)),
        CancellationToken.never(),
        False,
        1,
    )
    _assert_same(_chain_rows(ser), _chain_rows(ok), "after the cancel")
    _ = ser^
    _ = ok^
    reset_hash_chain_build_settings()


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_probe_kind_agrees_across_workers_and_chunk_sizes]()
    suite.test[test_every_row_of_one_bucket_is_chained_once_at_every_chunk_size]()
    suite.test[test_repeated_pool_create_and_build_cycles]()
    suite.test[test_float_string_and_dictionary_keys_agree_for_every_probe_kind]()
    suite.test[test_a_cancelled_token_raises_and_leaves_a_usable_pool]()
    suite^.run()
