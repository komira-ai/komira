# The chain-head FILL wave of the parallel composite build. Under FORCE with a
# 16-slot fill grain the table of a fixture-sized build is tiled into several
# fill chunks, so the wave really runs (below the production grain the driver
# would take its single memset): the table it leaves must be the serial build's
# at every pool width (an unfilled or mis-filled slot would hand out a chain
# head that points at row 0 or at garbage); the wave is dispatched exactly once
# on a pool of two or more and not at all on one worker; a token cancelled
# before the build stops it before the fill wave is dispatched; and the table's
# capacity follows the serial builder's at row counts where a different growth
# factor would pick a different power of two.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_async_api.token import CancellationToken

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_op_join_build.hash_chain_build_settings import (
    JOIN_PARALLEL_BUILD_FORCE,
    join_parallel_build_configure,
    join_ht_fill_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_probe.join_multi_key import MultiKeyColumns, _CHAIN_END
from komira_op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from komira_op_join_probe.join_multi_key_parallel_build import (
    mk_fill_chunk_bounds,
    multi_key_hash_join_build_parallel,
)

from komira_async.runtime.sched_trace import (
    SITE_JOIN_HT_FILL,
    sched_trace_configure,
    sched_trace_reset,
    sched_trace_site,
)

comptime I64 = DType.int64


def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return arr^


def _cols(imm cols: List[List[Int64]]) raises -> MultiKeyColumns:
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


def _fixture(n: Int) -> List[List[Int64]]:
    var a = List[Int64]()
    var b = List[Int64]()
    for i in range(n):
        a.append(Int64(i % 13))
        b.append(Int64((i * 5) % 7))
    return [a^, b^]


def _par(imm c: List[List[Int64]], workers: Int, chunk: Int, tok: CancellationToken) raises -> MultiKeyHashJoinBuilder:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_nf,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    comptime do = origin_of(disp)
    return multi_key_hash_join_build_parallel[True, LocalDispatcher[NoopSink], do](
        _cols(c),
        Optional[Pointer[LocalDispatcher[NoopSink], do]](Pointer(to=disp)),
        tok.clone(),
        False,
        chunk,
    )


def _nf() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _members(imm bld: MultiKeyHashJoinBuilder) raises -> List[Int]:
    """Every (slot, row) reachable from a chain head, sorted. The walk is
    bounded, so a cyclic chain fails here by name."""
    var out = List[Int]()
    for slot in range(bld._capacity):
        var cur = bld._hash_table[slot]
        var g = 0
        while cur != _CHAIN_END:
            out.append(slot * 1_000_000 + cur)
            cur = bld._next_chain[cur]
            g += 1
            if g > bld.num_rows():
                raise Error(
                    "_members: a chain cycles (more links than build rows) at"
                    " bucket " + String(slot)
                )
    return _sorted(out^)


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v^


def _begin() raises:
    reset_hash_chain_build_settings()
    sched_trace_configure(False)
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    join_ht_fill_configure(True, 16)


def _end() raises:
    sched_trace_configure(False)
    sched_trace_reset()
    reset_hash_chain_build_settings()


def _fill_waves() -> Int:
    return Int(sched_trace_site(SITE_JOIN_HT_FILL, Int32(2)))


def _assert_same_table(
    imm ser: MultiKeyHashJoinBuilder,
    imm par: MultiKeyHashJoinBuilder,
    msg: String,
) raises:
    assert_equal(par._capacity, ser._capacity, msg + " capacity")
    var sm = _members(ser)
    var pm = _members(par)
    assert_equal(len(pm), len(sm), msg + " chain members")
    for i in range(len(pm)):
        assert_equal(pm[i], sm[i], msg + " member " + String(i))
    # A slot is empty in one table exactly when it is empty in the other.
    for slot in range(ser._capacity):
        assert_equal(
            par._hash_table[slot] == _CHAIN_END,
            ser._hash_table[slot] == _CHAIN_END,
            msg + " empty slot " + String(slot),
        )
    assert_equal(par._num_inserted, ser._num_inserted, msg + " num_inserted")


def test_filled_table_equals_the_serial_build_at_every_pool_width() raises:
    _begin()
    sched_trace_configure(True)
    var c = _fixture(600)
    var ser = MultiKeyHashJoinBuilder.build(_cols(c))
    var ws: List[Int] = [1, 2, 3, 4, 8]
    var cs: List[Int] = [1, 5, 600, 5000]
    for w in range(len(ws)):
        for k in range(len(cs)):
            sched_trace_reset()
            var p = _par(c, ws[w], cs[k], CancellationToken.never())
            var tag = "workers=" + String(ws[w]) + " chunk=" + String(cs[k])
            _assert_same_table(ser, p, tag)
            assert_equal(
                _fill_waves(),
                1 if ws[w] >= 2 else 0,
                tag + ": fill waves dispatched",
            )
    _end()


def test_tiny_builds_leave_the_serial_table_with_the_fill_wave_live() raises:
    _begin()
    for n in [0, 1, 2]:
        var c = _fixture(n)
        var ser = MultiKeyHashJoinBuilder.build(_cols(c))
        var p = _par(c, 4, 0, CancellationToken.never())
        assert_equal(p.num_rows(), ser.num_rows(), "rows n=" + String(n))
        _assert_same_table(ser, p, "n=" + String(n))
    _end()


def test_a_cancelled_token_stops_the_build_before_the_fill_wave() raises:
    _begin()
    var c = _fixture(600)
    var tok = CancellationToken.new()
    tok.cancel(String("stop"))
    sched_trace_configure(True)
    sched_trace_reset()
    var raised = False
    try:
        var b = _par(c, 4, 7, tok)
        _ = b^
    except e:
        raised = True
    assert_true(raised, "a cancelled token must stop the build")
    assert_equal(
        _fill_waves(), 0, "the fill wave was dispatched under a cancelled token"
    )
    sched_trace_reset()
    var ok = _par(c, 4, 7, CancellationToken.never())
    assert_equal(_fill_waves(), 1, "a clean build dispatches the fill wave once")
    _ = ok^
    _end()


def test_capacity_follows_the_serial_builders_growth_factor() raises:
    """At these row counts 1.4 * n + 1 rounds up to 1,024 slots where a factor
    of 1.5 would take 2,048."""
    _begin()
    for n in [683, 700, 730]:
        var c = _fixture(n)
        var ser = MultiKeyHashJoinBuilder.build(_cols(c))
        var p = _par(c, 4, 0, CancellationToken.never())
        assert_equal(ser._capacity, 1024, "serial capacity n=" + String(n))
        assert_equal(p._capacity, ser._capacity, "parallel capacity n=" + String(n))
        _assert_same_table(ser, p, "n=" + String(n))
    _end()


def test_a_grain_that_does_not_divide_the_capacity_ends_at_the_capacity() raises:
    """With a grain of 100 over 1,024 slots the last chunk is short: the
    bounds are checked before any fill runs, then the table is compared with
    the serial build."""
    _begin()
    join_ht_fill_configure(True, 100)
    var bounds = mk_fill_chunk_bounds(1024)
    assert_equal(len(bounds), 12, "bounds for 1024 slots at grain 100")
    assert_equal(bounds[0], 0, "first bound")
    for i in range(1, len(bounds) - 1):
        assert_equal(bounds[i], i * 100, "bound " + String(i))
    assert_equal(
        bounds[len(bounds) - 1], 1024, "the last fill bound is the capacity"
    )
    var c = _fixture(700)
    var ser = MultiKeyHashJoinBuilder.build(_cols(c))
    assert_equal(ser._capacity, 1024, "serial capacity")
    sched_trace_configure(True)
    sched_trace_reset()
    var p = _par(c, 4, 0, CancellationToken.never())
    assert_equal(_fill_waves(), 1, "the fill wave ran once")
    _assert_same_table(ser, p, "grain 100")
    _end()


def main() raises:
    var suite = TestSuite()
    suite.test[test_filled_table_equals_the_serial_build_at_every_pool_width]()
    suite.test[test_tiny_builds_leave_the_serial_table_with_the_fill_wave_live]()
    suite.test[test_a_cancelled_token_stops_the_build_before_the_fill_wave]()
    suite.test[test_capacity_follows_the_serial_builders_growth_factor]()
    suite.test[test_a_grain_that_does_not_divide_the_capacity_ends_at_the_capacity]()
    suite^.run()
