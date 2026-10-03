# =============================================================================
# test_local_io_block.mojo
# =============================================================================
# Step 2 — LocalIoBlock[S] smoke tests.
#
#
# Coverage:
#   - Construct LocalIoBlock; submit a synthetic-ready IoOp; receive result.
#   - Synthetic-err IoOp surfaces the err string via raise.
#   - Pending IoOp without reactor wiring raises.
#   - Multiple concurrent (re-entrant on same worker thread) block_on calls.
#   - Façade is reachable via PerCoreAsyncRuntime.io_block() with stable
#     park-word load; round-trip use through the runtime accessor works.
#   - LocalIoBlock dropped without use — no leaks (smoke; ASAN not run, but
#     compiles + runs without crashing exercises the OwnedPointer drop path).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.io_op import IoOp, OP_PENDING
from komira_async.ops.waker_sink import NoopSink
from komira_async.primitives.never_origin import never_origin
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_io_block import LocalIoBlock
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)


def test_local_io_block_construct_standalone() raises:
    """LocalIoBlock constructs cleanly without a runtime."""
    var io = LocalIoBlock[NoopSink]()
    # Park-word starts at 0.
    assert_equal(Int(io.park_word_load()), 0)


def test_local_io_block_block_on_synthetic_ready_int() raises:
    """block_on a synthetic-ready IoOp[Int] returns the value by COPY."""
    var io = LocalIoBlock[NoopSink]()
    var op = IoOp[Int, NoopSink, never_origin].synthetic_ready(
        value=42, op_id=Int64(7),
    )
    var result = io.block_on(op^)
    assert_equal(result, 42)


def test_local_io_block_block_on_synthetic_ready_int64() raises:
    """T parameter elaborates for a different concrete type."""
    var io = LocalIoBlock[NoopSink]()
    var op = IoOp[Int64, NoopSink, never_origin].synthetic_ready(
        value=Int64(123_456_789), op_id=Int64(0),
    )
    var result = io.block_on(op^)
    assert_equal(result, Int64(123_456_789))


def test_local_io_block_block_on_synthetic_err_raises() raises:
    """OP_ERR ops surface the error via raise (delegates to IoOp.wait)."""
    var io = LocalIoBlock[NoopSink]()
    var op = IoOp[Int, NoopSink, never_origin].synthetic_err(
        err=String("synthetic-fail"), op_id=Int64(99),
    )
    var raised = False
    try:
        var _r = io.block_on(op^)
    except:
        raised = True
    assert_true(raised)


def test_local_io_block_block_on_pending_raises_stub_message() raises:
    """OP_PENDING with no reactor wiring raises the stub error.

    When a reactor-driven park
    loop lands, this test will be flipped to the new behavior."""
    var io = LocalIoBlock[NoopSink]()
    # Construct a Pending op directly (bypassing synthetic_ready).
    var op = IoOp[Int, NoopSink, never_origin](
        op_id=Int64(0), state=OP_PENDING,
    )
    var raised = False
    try:
        var _r = io.block_on(op^)
    except:
        raised = True
    assert_true(raised)


def test_local_io_block_multiple_block_on_calls() raises:
    """Re-entrance on the same worker thread: multiple sequential
    block_on calls return correct results.

    LocalIoBlock holds no per-call state on the path used by
    synthetic-ready ops; the park-word is a stable fixture that survives
    repeated calls. Tests for cross-thread re-entrance are out of scope
    (the worker thread is single-threaded by the
    per-core async model).
    """
    var io = LocalIoBlock[NoopSink]()
    var i = 0
    while i < 16:
        var op = IoOp[Int, NoopSink, never_origin].synthetic_ready(
            value=i * 3, op_id=Int64(i),
        )
        var r = io.block_on(op^)
        assert_equal(r, i * 3)
        i = i + 1
    # Park-word remains 0 (synthetic-ready path never touches it).
    assert_equal(Int(io.park_word_load()), 0)


def test_local_io_block_via_runtime_accessor() raises:
    """The façade is reachable via PerCoreAsyncRuntime.io_block(); the
    returned ref is bound to the runtime's `_io_block` field per the
    parametric-origin-return pattern."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    # Bind via `ref` — `var io = rt.io_block()` would attempt a copy and
    # fail (LocalIoBlock is Movable-only).
    ref io = rt.io_block()
    assert_equal(Int(io.park_word_load()), 0)
    var op = IoOp[Int, NoopSink, never_origin].synthetic_ready(
        value=99, op_id=Int64(1),
    )
    var r = io.block_on(op^)
    assert_equal(r, 99)


def test_local_io_block_chained_calls_via_runtime() raises:
    """Chained accessor invocation: `rt.io_block().block_on(...)` works
    in a single expression. This is the canonical caller pattern from
    the accessor pattern."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var op = IoOp[Int, NoopSink, never_origin].synthetic_ready(
        value=2026, op_id=Int64(0),
    )
    var r = rt.io_block().block_on(op^)
    assert_equal(r, 2026)


def test_local_io_block_drop_without_use() raises:
    """Construct then drop without calling block_on — exercises the
    OwnedPointer[Atomic[..]] drop path. Smoke; failure mode would be a
    crash / leak. We compile + run; reaching this assert is the test."""
    var i = 0
    while i < 4:
        var io = LocalIoBlock[NoopSink]()
        # Touch the park-word to defeat dead-store elision.
        _ = io.park_word_load()
        i = i + 1
    assert_true(True)


def main() raises:
    test_local_io_block_construct_standalone()
    test_local_io_block_block_on_synthetic_ready_int()
    test_local_io_block_block_on_synthetic_ready_int64()
    test_local_io_block_block_on_synthetic_err_raises()
    test_local_io_block_block_on_pending_raises_stub_message()
    test_local_io_block_multiple_block_on_calls()
    test_local_io_block_via_runtime_accessor()
    test_local_io_block_chained_calls_via_runtime()
    test_local_io_block_drop_without_use()
    print("PASS komira_async.runtime.local_io_block")
