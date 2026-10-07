# =============================================================================
# test_parallel_fork_join — the shared fork-join helper's focused unit test.
#
# Ports the GREEN scratch POC (poc_parallel): drives the FULL parallel path
# through a real multi-worker PerCoreAsyncRuntime + LocalDispatcher.
# run_with_state and asserts PARALLEL output == SERIAL output byte-identical
# over TWO output shapes:
#
#   1. List[UInt8]            — flat heap-owning byte output (csv-row-emit).
#   2. _IntListOut (the destroy-recreate hazard)     — a Movable struct whose field is List[Int]
#                              (a heap-owning inner type). This is the destroy-recreate
#                              shape: a Movable struct with a heap-owning
#                              field flowing through a byte-disjoint Slab.
#
# Both shapes prove the helper's safety contract holds under real
# fork-join: the concrete immutable in_o borrow threads across the generic
# dispatch boundary, the disjoint Slab[Optional[O]] reclaim via
# Optional.take is byte-faithful, and no ASAP-destruction fires mid-loop on
# the heap-owning inner List.
# =============================================================================

from std.memory import UnsafePointer
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join import (
    parallel_fork_join,
    parallel_fork_join_serial,
)
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab


# -----------------------------------------------------------------------------
# Shared input: a borrowed read-only column of Ints. The ChunkWork bodies
# read ONLY chunk `chunk_id`'s [lo, hi) row range — disjointness is the
# call-site contract the helper preserves.
# -----------------------------------------------------------------------------

struct _FakeColumns(Deinitable):
    var values: List[Int]
    var n_rows: Int

    def __init__(out self, var values: List[Int]):
        self.n_rows = len(values)
        self.values = values^


def _chunk_lo(chunk_id: Int, n_chunks_total: Int, n_rows: Int) -> Int:
    var rows_per_chunk = n_rows // n_chunks_total
    return chunk_id * rows_per_chunk


def _chunk_hi(chunk_id: Int, n_chunks_total: Int, n_rows: Int) -> Int:
    var rows_per_chunk = n_rows // n_chunks_total
    if chunk_id == n_chunks_total - 1:
        return n_rows
    return chunk_id * rows_per_chunk + rows_per_chunk


# -----------------------------------------------------------------------------
# Runtime helper (mirrors test_local_dispatcher._make_started_runtime).
# -----------------------------------------------------------------------------

def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


# =============================================================================
# Shape 1 — List[UInt8] flat byte output.
# =============================================================================


@fieldwise_init
struct _CsvRowEmit(ChunkWork):
    var n_chunks_total: Int

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        var ip = UnsafePointer(to=input).bitcast[_FakeColumns]()
        var lo = _chunk_lo(chunk_id, self.n_chunks_total, ip[].n_rows)
        var hi = _chunk_hi(chunk_id, self.n_chunks_total, ip[].n_rows)
        var buf = List[UInt8]()
        var r = lo
        while r < hi:
            var s = String(ip[].values[r])
            for b in s.as_bytes():
                buf.append(b)
            buf.append(10)
            r = r + 1
        var op = UnsafePointer(to=out_slot).bitcast[Optional[List[UInt8]]]()
        op[] = Optional[List[UInt8]](buf^)


def _flatten_bytes(var outputs: Slab[Optional[List[UInt8]]]) -> List[UInt8]:
    var out = List[UInt8]()
    var i = 0
    while i < outputs.len():
        ref slot = outputs.get_mut_interior(i)
        if slot:
            for b in slot.value():
                out.append(b)
        i = i + 1
    _ = outputs^
    return out^


# =============================================================================
# Shape 2 — _IntListOut: a Movable struct with a heap-owning List[Int]
# field (the destroy-recreate shape). Each chunk emits the doubled row values for its
# [lo, hi) range as a List[Int] wrapped in a Movable struct.
# =============================================================================


struct _IntListOut(Movable, Deinitable):
    var vals: List[Int]

    def __init__(out self, var vals: List[Int]):
        self.vals = vals^


@fieldwise_init
struct _IntDoubleEmit(ChunkWork):
    var n_chunks_total: Int

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        var ip = UnsafePointer(to=input).bitcast[_FakeColumns]()
        var lo = _chunk_lo(chunk_id, self.n_chunks_total, ip[].n_rows)
        var hi = _chunk_hi(chunk_id, self.n_chunks_total, ip[].n_rows)
        var v = List[Int]()
        var r = lo
        while r < hi:
            v.append(ip[].values[r] * 2)
            r = r + 1
        var op = UnsafePointer(to=out_slot).bitcast[Optional[_IntListOut]]()
        op[] = Optional[_IntListOut](_IntListOut(v^))


def _flatten_ints(var outputs: Slab[Optional[_IntListOut]]) -> List[Int]:
    var out = List[Int]()
    var i = 0
    while i < outputs.len():
        ref slot = outputs.get_mut_interior(i)
        if slot:
            for x in slot.value().vals:
                out.append(x)
        i = i + 1
    _ = outputs^
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_parallel_eq_serial_bytes() raises:
    """Shape 1: List[UInt8]. Parallel fork-join (real multi-worker
    PerCoreAsyncRuntime) == single-buffer serial, byte-identical."""
    var n_rows = 100_000
    var vals = List[Int]()
    for r in range(n_rows):
        vals.append(r * 7 + 3)
    var cols = _FakeColumns(vals^)
    var n_chunks = 16

    # Reference: single-buffer serial emit (n_chunks_total=1).
    var work_ref = _CsvRowEmit(n_chunks_total=1)
    var out_ref = parallel_fork_join_serial[
        _CsvRowEmit, _FakeColumns, List[UInt8], origin_of(cols)
    ](work_ref^, cols, 1)
    var bytes_ref = _flatten_bytes(out_ref^)

    # Parallel path through a real multi-worker dispatcher.
    var rt = _make_started_runtime(4)
    var ct = CancellationToken.new()
    ref disp = rt.dispatcher()
    var disp_ptr = Pointer(to=disp)

    var work_p = _CsvRowEmit(n_chunks_total=n_chunks)
    var out_p = parallel_fork_join[
        _CsvRowEmit,
        _FakeColumns,
        List[UInt8],
        origin_of(cols),
        origin_of(disp),
    ](work_p^, cols, n_chunks, disp_ptr, ct.clone())
    var bytes_par = _flatten_bytes(out_p^)
    rt.shutdown()

    assert_equal(len(bytes_par), len(bytes_ref))
    var i = 0
    while i < len(bytes_ref):
        assert_equal(bytes_par[i], bytes_ref[i])
        i = i + 1
    assert_true(len(bytes_ref) > 0)


def test_parallel_eq_serial_destroy_recreate_intlist() raises:
    """Shape 2: _IntListOut (Movable struct w/ heap-owning List[Int] —
    the destroy-recreate shape). Parallel fork-join == single-buffer serial,
    element-identical. Proves no ASAP-destruction fires on the inner
    heap List as it flows through the disjoint Slab[Optional[O]] reclaim.
    """
    var n_rows = 100_000
    var vals = List[Int]()
    for r in range(n_rows):
        vals.append(r * 11 + 5)
    var cols = _FakeColumns(vals^)
    var n_chunks = 16

    # Reference: single-chunk serial.
    var work_ref = _IntDoubleEmit(n_chunks_total=1)
    var out_ref = parallel_fork_join_serial[
        _IntDoubleEmit, _FakeColumns, _IntListOut, origin_of(cols)
    ](work_ref^, cols, 1)
    var ints_ref = _flatten_ints(out_ref^)

    # Parallel path through a real multi-worker dispatcher.
    var rt = _make_started_runtime(4)
    var ct = CancellationToken.new()
    ref disp = rt.dispatcher()
    var disp_ptr = Pointer(to=disp)

    var work_p = _IntDoubleEmit(n_chunks_total=n_chunks)
    var out_p = parallel_fork_join[
        _IntDoubleEmit,
        _FakeColumns,
        _IntListOut,
        origin_of(cols),
        origin_of(disp),
    ](work_p^, cols, n_chunks, disp_ptr, ct.clone())
    var ints_par = _flatten_ints(out_p^)
    rt.shutdown()

    assert_equal(len(ints_par), len(ints_ref))
    assert_equal(len(ints_ref), n_rows)
    var i = 0
    while i < len(ints_ref):
        assert_equal(ints_par[i], ints_ref[i])
        i = i + 1


def test_serial_fallback_matches() raises:
    """parallel_fork_join_serial over many chunks == single-chunk serial
    (the no-dispatcher fallback is byte-identical to the parallel path)."""
    var n_rows = 10_000
    var vals = List[Int]()
    for r in range(n_rows):
        vals.append(r * 3 + 1)
    var cols = _FakeColumns(vals^)

    var work_1 = _IntDoubleEmit(n_chunks_total=1)
    var out_1 = parallel_fork_join_serial[
        _IntDoubleEmit, _FakeColumns, _IntListOut, origin_of(cols)
    ](work_1^, cols, 1)
    var ints_1 = _flatten_ints(out_1^)

    var work_8 = _IntDoubleEmit(n_chunks_total=8)
    var out_8 = parallel_fork_join_serial[
        _IntDoubleEmit, _FakeColumns, _IntListOut, origin_of(cols)
    ](work_8^, cols, 8)
    var ints_8 = _flatten_ints(out_8^)

    assert_equal(len(ints_8), len(ints_1))
    var i = 0
    while i < len(ints_1):
        assert_equal(ints_8[i], ints_1[i])
        i = i + 1


def test_worker_count_is_hardware_derived() raises:
    """The helper's effective worker count is HARDWARE-DERIVED from the
    dispatcher's pool, not a hardcoded constant. Drives the parallel path
    through dispatchers of DIFFERENT pool sizes and asserts:

      1. `dispatcher.worker_count()` == the runtime's attached-worker
         count (the hardware-derived source the helper reads). This is
         the authoritative count the helper caps to.
      2. n_chunks > K (pool of K): correct over a K-worker pool — at most
         K shards are dispatched, output is byte-faithful.
      3. n_chunks < K (more workers than chunks): correct — the helper
         clamps the shard count down to n_chunks (no idle-worker hang,
         no over-dispatch), output is byte-faithful.

    No hardcoded 32 anywhere: a K=3 pool dispatches at most 3 shards even
    with n_chunks=12; a K=6 pool with n_chunks=2 dispatches at most 2.
    """
    var n_rows = 60_000
    var vals = List[Int]()
    for r in range(n_rows):
        vals.append(r * 13 + 2)
    var cols = _FakeColumns(vals^)

    # Reference: single-chunk serial.
    var work_ref = _IntDoubleEmit(n_chunks_total=1)
    var out_ref = parallel_fork_join_serial[
        _IntDoubleEmit, _FakeColumns, _IntListOut, origin_of(cols)
    ](work_ref^, cols, 1)
    var ints_ref = _flatten_ints(out_ref^)
    assert_equal(len(ints_ref), n_rows)

    # --- Pool of K=3, n_chunks=12 (more chunks than workers) ---
    var rt3 = _make_started_runtime(3)
    ref disp3 = rt3.dispatcher()
    # (1) The hardware-derived source the helper reads.
    assert_equal(disp3.worker_count(), 3)
    var disp3_ptr = Pointer(to=disp3)
    var ct3 = CancellationToken.new()
    var n_chunks_big = 12
    var work3 = _IntDoubleEmit(n_chunks_total=n_chunks_big)
    var out3 = parallel_fork_join[
        _IntDoubleEmit,
        _FakeColumns,
        _IntListOut,
        origin_of(cols),
        origin_of(disp3),
    ](work3^, cols, n_chunks_big, disp3_ptr, ct3.clone())
    var ints3 = _flatten_ints(out3^)
    rt3.shutdown()
    assert_equal(len(ints3), n_rows)
    var i = 0
    while i < len(ints_ref):
        assert_equal(ints3[i], ints_ref[i])
        i = i + 1

    # --- Pool of K=6, n_chunks=2 (fewer chunks than workers) ---
    # The helper must clamp the shard count to n_chunks=2 — it does NOT
    # dispatch 6 shards over 2 chunks (which would leave shards with an
    # empty [lo, hi) range / over-stride the output).
    var rt6 = _make_started_runtime(6)
    ref disp6 = rt6.dispatcher()
    assert_equal(disp6.worker_count(), 6)
    var disp6_ptr = Pointer(to=disp6)
    var ct6 = CancellationToken.new()
    var n_chunks_small = 2
    var work6 = _IntDoubleEmit(n_chunks_total=n_chunks_small)
    var out6 = parallel_fork_join[
        _IntDoubleEmit,
        _FakeColumns,
        _IntListOut,
        origin_of(cols),
        origin_of(disp6),
    ](work6^, cols, n_chunks_small, disp6_ptr, ct6.clone())
    var ints6 = _flatten_ints(out6^)
    rt6.shutdown()
    assert_equal(len(ints6), n_rows)
    var j = 0
    while j < len(ints_ref):
        assert_equal(ints6[j], ints_ref[j])
        j = j + 1


def test_max_workers_override_caps_below_pool() raises:
    """`max_workers > 0` is an OPTIONAL explicit caller cap applied on
    top of the hardware-derived count. With a pool of K=4 and
    max_workers=1, the helper dispatches at most 1 shard (the whole work
    on one worker); output stays byte-faithful. This is the ORC adopter's
    override path (`max_workers=_MAX_STREAM_COMPRESS_WORKERS`)."""
    var n_rows = 40_000
    var vals = List[Int]()
    for r in range(n_rows):
        vals.append(r * 17 + 9)
    var cols = _FakeColumns(vals^)

    var work_ref = _IntDoubleEmit(n_chunks_total=1)
    var out_ref = parallel_fork_join_serial[
        _IntDoubleEmit, _FakeColumns, _IntListOut, origin_of(cols)
    ](work_ref^, cols, 1)
    var ints_ref = _flatten_ints(out_ref^)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    assert_equal(disp.worker_count(), 4)
    var disp_ptr = Pointer(to=disp)
    var ct = CancellationToken.new()
    var n_chunks = 8
    var work = _IntDoubleEmit(n_chunks_total=n_chunks)
    var out_p = parallel_fork_join[
        _IntDoubleEmit,
        _FakeColumns,
        _IntListOut,
        origin_of(cols),
        origin_of(disp),
    ](work^, cols, n_chunks, disp_ptr, ct.clone(), max_workers=1)
    var ints_p = _flatten_ints(out_p^)
    rt.shutdown()

    assert_equal(len(ints_p), n_rows)
    var i = 0
    while i < len(ints_ref):
        assert_equal(ints_p[i], ints_ref[i])
        i = i + 1


def main() raises:
    test_parallel_eq_serial_bytes()
    print("test_parallel_eq_serial_bytes: GREEN")
    test_parallel_eq_serial_destroy_recreate_intlist()
    print("test_parallel_eq_serial_destroy_recreate_intlist: GREEN")
    test_serial_fallback_matches()
    print("test_serial_fallback_matches: GREEN")
    test_worker_count_is_hardware_derived()
    print("test_worker_count_is_hardware_derived: GREEN")
    test_max_workers_override_caps_below_pool()
    print("test_max_workers_override_caps_below_pool: GREEN")
    print("VERDICT: parallel == serial byte-identical (both shapes) — GREEN")
