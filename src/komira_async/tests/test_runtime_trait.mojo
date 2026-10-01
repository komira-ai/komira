# =============================================================================
# test_runtime_trait.mojo
# =============================================================================
# sub-phase 4 — Runtime trait acceptance tests.
#
# Verifies the four acceptance gates from the slot brief:
#   (a) `Runtime` trait compiles on Mojo 1.0.0b1.
#   (b) `PerCoreAsyncRuntime[S]` conforms with no fn-ptr indirection.
#   (c) `komira_async` builds + tests standalone (this test file imports
#       only komira_async — no engine / parquet / sdk symbols).
#   (d) A downstream struct generic over `[RT: Runtime]` monomorphizes
#       against `PerCoreAsync`.
#
# The "no fn-ptr table" property is verified by a separate AOT objdump
# tripwire. This test verifies the SEMANTIC end of the seam (the trait
# surface works correctly when called); the objdump verifies the
# PERFORMANCE end (the dispatch is fully monomorphized at compile time).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.runtime_trait import (
    MODEL_SHARE_NOTHING_PER_CORE,
    MODEL_WORK_STEALING,
    Runtime,
)


# =============================================================================
# Sink factory for PerCoreAsyncRuntime[NoopSink] construction.
# =============================================================================
def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Downstream-generic struct — the HttpClient[RT: Runtime] shape.
# =============================================================================
# Acceptance: "a downstream struct generic over [RT: Runtime]
# monomorphizes against PerCoreAsync". This struct stays minimal — it
# exercises the trait surface end-to-end (comptime member access, method
# dispatch, comptime-if branching over RUNTIME_MODEL) without depending on
# any HTTP-specific scaffolding.

@fieldwise_init
struct DownstreamGeneric[RT: Runtime](Movable, Deinitable):
    """Mirrors HttpClient[RT: Runtime]. The body uses Self.RT.<Member>
    spellings."""
    var _placeholder: UInt8

    @staticmethod
    def query_model() -> UInt8:
        return Self.RT.RUNTIME_MODEL

    @staticmethod
    def is_thread_pinned() -> Bool:
        return Self.RT.TASKS_ARE_THREAD_PINNED

    def query_workers(self, ref rt: Self.RT) -> Int:
        return rt.worker_count()

    def use_comptime_branch(self) -> UInt8:
        comptime if Self.RT.RUNTIME_MODEL == MODEL_SHARE_NOTHING_PER_CORE:
            return UInt8(11)
        else:
            return UInt8(22)


# =============================================================================
# Tests
# =============================================================================


def test_runtime_model_constants() raises:
    """Acceptance (a): the trait + comptime value namespace compiles."""
    assert_equal(Int(MODEL_SHARE_NOTHING_PER_CORE), 0)
    assert_equal(Int(MODEL_WORK_STEALING), 1)


def test_per_core_async_conforms_runtime() raises:
    """Acceptance (b): PerCoreAsyncRuntime[NoopSink] conforms to Runtime.

    Construction with `placement=PLACEMENT_FIXED` (deferred-start mode) +
    attach_workers(0, ...) gives us an empty-but-valid runtime to query.
    We don't start any pthreads (no need for the trait-surface test).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    # Empty runtime: worker_count == 0.
    assert_equal(rt.worker_count(), 0)


def test_runtime_comptime_members() raises:
    """Acceptance (b) cont: read the comptime members through the
    conformer type. Validates that the comptime alias declarations
    resolve correctly without any runtime indirection.
    """
    # Read directly off the conformer (the typical caller pattern: comptime
    # access through the runtime type parameter).
    assert_equal(
        Int(PerCoreAsyncRuntime[NoopSink].RUNTIME_MODEL),
        Int(MODEL_SHARE_NOTHING_PER_CORE),
    )
    assert_true(PerCoreAsyncRuntime[NoopSink].TASKS_ARE_THREAD_PINNED)


def test_downstream_generic_query_model() raises:
    """Acceptance (d): DownstreamGeneric[PerCoreAsyncRuntime[NoopSink]]
    accesses Self.RT.RUNTIME_MODEL — proves the parametric path through
    a trait-bound type parameter elaborates correctly.
    """
    var model = DownstreamGeneric[
        PerCoreAsyncRuntime[NoopSink]
    ].query_model()
    assert_equal(Int(model), Int(MODEL_SHARE_NOTHING_PER_CORE))


def test_downstream_generic_thread_pinned() raises:
    """Acceptance (d) cont: TASKS_ARE_THREAD_PINNED reads True for
    PerCoreAsync."""
    var pinned = DownstreamGeneric[
        PerCoreAsyncRuntime[NoopSink]
    ].is_thread_pinned()
    assert_true(pinned)


def test_downstream_generic_worker_count_dispatch() raises:
    """Acceptance (d) cont: DownstreamGeneric calls rt.worker_count()
    through the Runtime trait method. This is the per-instance method
    dispatch path (vs. the comptime-static-method paths above).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    var dg = DownstreamGeneric[PerCoreAsyncRuntime[NoopSink]](
        _placeholder=UInt8(0),
    )
    var n = dg.query_workers(rt)
    assert_equal(n, 0)


def test_downstream_generic_comptime_branch() raises:
    """Acceptance (d) cont: `comptime if Self.RT.RUNTIME_MODEL == ...`
    branches at COMPILE TIME. The dead branch should be eliminated; the
    poc_runtime_trait_seam probe verifies the objdump-level
    disappearance of the alternate path.
    """
    var dg = DownstreamGeneric[PerCoreAsyncRuntime[NoopSink]](
        _placeholder=UInt8(0),
    )
    var branched = dg.use_comptime_branch()
    # PerCoreAsync is MODEL_SHARE_NOTHING_PER_CORE → branch returns 11.
    assert_equal(Int(branched), 11)


def test_attach_worker_then_count() raises:
    """Integration: attach one mock-backend worker; worker_count() returns
    1; this exercises the trait method on a non-empty conformer.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(_noop_sink_factory(), BACKEND_MOCK)
    assert_equal(rt.worker_count(), 1)

    # DownstreamGeneric sees the same count through the trait dispatch.
    var dg = DownstreamGeneric[PerCoreAsyncRuntime[NoopSink]](
        _placeholder=UInt8(0),
    )
    assert_equal(dg.query_workers(rt), 1)


def test_timer_now_ns_stub_zero() raises:
    """v0.4 stub semantic: `timer_now_ns` returns 0 until Worker.TimerWheel
    is wired. This test guards the stub semantics so
    consumers that fall back to a wall-clock read are not surprised."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(_noop_sink_factory(), BACKEND_MOCK)
    # In-bounds: stub returns 0.
    assert_equal(Int(rt.timer_now_ns(0)), 0)
    # Out-of-bounds: stub returns 0 (no raise — diff from poll_completions).
    assert_equal(Int(rt.timer_now_ns(99)), 0)


def test_poll_completions_oob_raises() raises:
    """poll_completions raises on an out-of-range worker_idx — exercises
    the trait method's error path."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(_noop_sink_factory(), BACKEND_MOCK)
    var raised = False
    try:
        var _n = rt.poll_completions(99, Int32(0))
    except:
        raised = True
    assert_true(raised)


def main() raises:
    test_runtime_model_constants()
    test_per_core_async_conforms_runtime()
    test_runtime_comptime_members()
    test_downstream_generic_query_model()
    test_downstream_generic_thread_pinned()
    test_downstream_generic_worker_count_dispatch()
    test_downstream_generic_comptime_branch()
    test_attach_worker_then_count()
    test_timer_now_ns_stub_zero()
    test_poll_completions_oob_raises()
