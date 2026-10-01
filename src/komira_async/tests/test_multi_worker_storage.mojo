# =============================================================================
# test_multi_worker_storage.mojo
# =============================================================================
# Step 1 — multi-worker `PerCoreAsyncRuntime[S]` storage
# coverage.
#
# This file targets the Slab[OwnedPointer[Worker[S]]] migration:
#   * construct with N=1, N=2, N=4 via `attach_workers`
#   * `worker_at(i)` returns the right worker (worker_id == i)
#   * `signal_shutdown_all` reaches every worker (each worker's
#     `is_shutdown_signaled()` returns True after the broadcast)
#   * full `start()` + `shutdown()` cycle on N=4
#   * Drop without start does NOT panic (workers in slab dropped cleanly)
#   * Repeated attach_worker shim appends (multi-worker semantics)
#
# These tests use `BACKEND_MOCK` so no epoll fd is opened per worker.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PLACEMENT_MAX_SPREAD,
    PerCoreAsyncRuntime,
)


# Sink factory used by `attach_workers`. Uniform NoopSink across all
# workers — the test-only synthetic-IoOp shape.
def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_attach_workers_n1() raises:
    """N=1 via the multi-worker `attach_workers` entry.

    Functionally equivalent to the legacy `attach_worker` shim (the back-
    compat path). Slot 0 is populated with worker_id=0.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_workers(1, _noop_sink_factory, BACKEND_MOCK)
    assert_equal(rt.worker_count(), 1)
    assert_equal(Int(rt.worker_at(0).worker_id()), 0)


def test_attach_workers_n2() raises:
    """N=2. Slots 0/1 are populated; worker_ids are 0/1
    (monotonically-increasing across the slab).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_workers(2, _noop_sink_factory, BACKEND_MOCK)
    assert_equal(rt.worker_count(), 2)
    assert_equal(Int(rt.worker_at(0).worker_id()), 0)
    assert_equal(Int(rt.worker_at(1).worker_id()), 1)


def test_attach_workers_n4() raises:
    """N=4 (the bench gate target).

    Each slot holds a distinct Worker with worker_id = i. Slab capacity
    grew from 0 -> 4 via geometric resize (List[UInt8] backing buffer
    reallocates; OwnedPointer[Worker[S]] handles are POD-trivially-
    movable so the slab grow is safe across destroy-recreate per
    `lint_byteslab_heap_inner.sh`).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    assert_equal(rt.worker_count(), 4)
    var i = 0
    while i < 4:
        assert_equal(Int(rt.worker_at(i).worker_id()), i)
        i = i + 1


def test_signal_shutdown_all_reaches_every_worker_n4() raises:
    """signal_shutdown_all broadcasts to every worker.

    Each Worker's `is_shutdown_signaled()` returns False BEFORE the
    broadcast and True AFTER. This validates the slab iteration in
    `signal_shutdown_all` covers every slot.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    var i = 0
    while i < 4:
        assert_false(rt.worker_at(i).is_shutdown_signaled())
        i = i + 1
    rt.signal_shutdown_all()
    var j = 0
    while j < 4:
        assert_true(rt.worker_at(j).is_shutdown_signaled())
        j = j + 1


def test_start_shutdown_cycle_n4() raises:
    """full start + shutdown cycle with N=4 pthreads.

    Each pthread runs the worker's `run_until_shutdown` loop with
    BACKEND_MOCK (1ms poll interval; no epoll fd allocated). After
    shutdown, every pthread is joined. worker_count remains 4 (the
    workers are still attached, just not running).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    rt.shutdown()
    assert_equal(rt.worker_count(), 4)
    # Idempotent shutdown.
    rt.shutdown()
    assert_equal(rt.worker_count(), 4)


def _drop_without_start_helper() raises -> Int:
    """Helper for `test_drop_without_start_no_panic_n4`. The runtime
    is constructed inside this fn; on return, it goes out of scope
    and the Slab[OwnedPointer[Worker[S]]] drops every slot. Returns
    the worker_id of slot 0 so the caller can confirm the slab was
    populated before drop.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    assert_equal(rt.worker_count(), 4)
    return Int(rt.worker_at(0).worker_id())


def test_drop_without_start_no_panic_n4() raises:
    """dropping the runtime BEFORE `start()` is called
    must not panic. The slab's OwnedPointer slots drop cleanly (no
    pthreads to join because none were launched).

    Helper-fn scope governs the drop: when `_drop_without_start_helper`
    returns, `rt` goes out of scope and
    Slab[OwnedPointer[Worker[S]]]::__del__ destroys each slot in
    forward order; OwnedPointer's drop frees the backing Worker.
    """
    var probe = _drop_without_start_helper()
    # Reach this line == drop succeeded without panic.
    assert_equal(probe, 0)


def test_repeated_attach_worker_shim_appends() raises:
    """the back-compat `attach_worker(var sink, backend)`
    shim now APPENDS instead of raising on the second call.

    The single-worker constraint ("second attach raises")
    was a policy, not a structural invariant. With the multi-worker
    storage, repeated single-shot attaches build up a slab.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(rt.worker_count(), 3)
    var i = 0
    while i < 3:
        assert_equal(Int(rt.worker_at(i).worker_id()), i)
        i = i + 1


def test_attach_after_start_raises_n4() raises:
    """once `start()` has launched pthreads, growing the
    worker set would invalidate already-launched pthread Worker
    addresses. attach_workers / attach_worker after start MUST raise.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    var raised = False
    try:
        rt.attach_workers(1, _noop_sink_factory, BACKEND_MOCK)
    except:
        raised = True
    assert_true(raised)
    var raised2 = False
    try:
        rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    except:
        raised2 = True
    assert_true(raised2)
    rt.shutdown()


def test_start_with_zero_workers_raises() raises:
    """`start()` with no attached workers must raise."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    var raised = False
    try:
        rt.start()
    except:
        raised = True
    assert_true(raised)


def test_double_start_raises_n2() raises:
    """a second `start()` without an intervening
    `shutdown()` raises (matches contract).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    var raised = False
    try:
        rt.start()
    except:
        raised = True
    assert_true(raised)
    rt.shutdown()


def main() raises:
    test_attach_workers_n1()
    test_attach_workers_n2()
    test_attach_workers_n4()
    test_signal_shutdown_all_reaches_every_worker_n4()
    test_start_shutdown_cycle_n4()
    test_drop_without_start_no_panic_n4()
    test_repeated_attach_worker_shim_appends()
    test_attach_after_start_raises_n4()
    test_start_with_zero_workers_raises()
    test_double_start_raises_n2()
    print("PASS komira_async.runtime multi-worker storage")
