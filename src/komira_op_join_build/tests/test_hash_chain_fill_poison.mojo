# =============================================================================
# test_hash_chain_fill_poison -- poison-and-read-back of the fanned chain-head
# fill of the parallel hash-join build
# =============================================================================
#
# A gap in the fill's tiling leaves a chain head holding whatever the
# allocator handed back. A probe walks such a head without necessarily
# answering wrong (and can loop forever on a cycle), so the TABLE is checked:
# every bucket is `_CHAIN_END` or the head of a row that hashes to it, and
# exactly the buckets some key hashes to are non-empty. The allocator is
# dirtied first so a fresh zero page cannot pass for a filled one, and the
# 16-slot grain tiles the 8,192-slot table into 512 morsels.
#
# Mutant run: the fill writing `M - 1` slots per morsel instead of `M` turns
# this file red (and hangs the probe-driven suites on the cycles it creates,
# which is why this check has a file of its own).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken

from komira_op_join_build.hash_chain_build_settings import (
    JOIN_PARALLEL_BUILD_FORCE,
    join_ht_fill_configure,
    join_parallel_build_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_build.hash_chain_parallel_build import chain_build_parallel
from komira_op_join_build.join import _hash_join_key


comptime _POOL_WORKERS = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _keys(n: Int, stride: Int) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(i * stride)))
    return arr^


def _dirty_the_allocator(slots: Int):
    """Allocate a table-sized list, fill it with a pattern that is a valid
    in-range row index, and drop it, so the next same-size allocation is
    likely to come back dirty."""
    var dirt = List[Int]()
    dirt.resize(slots, 5)
    _ = dirt^


def test_fanned_fill_leaves_no_garbage_head() raises:
    reset_hash_chain_build_settings()
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    join_ht_fill_configure(True, 16)
    var n = 3000
    var cap = 8192
    _dirty_the_allocator(cap)
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var bufs = chain_build_parallel(
        disp, ct^, _keys(n, 3), elide_bi=True, fused=True
    )
    assert_equal(bufs.capacity, cap)
    var ht = bufs.take_hash_table()
    var kn = bufs.take_key_next()
    var mask = UInt64(cap - 1)
    var occupied = List[Bool]()
    occupied.resize(cap, False)
    for i in range(n):
        occupied[Int(_hash_join_key(Int64(i * 3)) & mask)] = True
    var expect_heads = 0
    var heads = 0
    for s in range(cap):
        if occupied[s]:
            expect_heads += 1
        var h = ht[s]
        if h == -1:
            assert_false(occupied[s], "an occupied bucket lost its head")
            continue
        heads += 1
        assert_true(h >= 0 and h < n, "head " + String(h) + " out of range")
        var key = kn[2 * h]
        assert_equal(
            Int(_hash_join_key(key) & mask), s, "head of the wrong bucket"
        )
    assert_equal(heads, expect_heads, "exactly the hashed buckets are heads")
    reset_hash_chain_build_settings()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
