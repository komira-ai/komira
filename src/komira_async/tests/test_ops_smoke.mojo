# =============================================================================
# test_ops_smoke.mojo
# =============================================================================
# IoOp[T, S, ro] value-type smoke + functional tests.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.io_op import (
    IoOp,
    OP_ERR,
    OP_PENDING,
    OP_READY,
    ioop_ready,
)
from komira_async.ops.waker_sink import (
    FdWaker,
    NoopSink,
    ThreadWaker,
    WakerSink,
)
from komira_async.cancellation.token import CancellationToken
from komira_async.primitives.never_origin import never_origin


def test_thread_waker_imports() raises:
    """ThreadWaker imports + can be value-constructed."""
    var w = ThreadWaker(_placeholder=UInt8(0))
    var raised = False
    try:
        w.wake(Int64(1))
    except:
        raised = True
    assert_true(raised)


def test_fd_waker_imports() raises:
    """FdWaker imports."""
    var w = FdWaker(_placeholder=UInt8(0))
    var raised = False
    try:
        w.wake(Int64(2))
    except:
        raised = True
    assert_true(raised)


def test_noop_sink_imports() raises:
    """NoopSink imports (used by synthetic IoOps)."""
    var s = NoopSink(_placeholder=UInt8(0))
    # NoopSink.wake should never be called per its doc-comment;
    # raises explicitly to surface mistakes.
    var raised = False
    try:
        s.wake(Int64(0))
    except:
        raised = True
    assert_true(raised)


def test_ioop_synthetic_ready_returns_value_via_wait() raises:
    """synthetic Ready IoOp delivers the value via wait()
    without driving any reactor. This validates the value-type plumbing
    (state machine + Optional[T] + return-by-COPY).

    T = Int (Copyable, ImplicitlyCopyable, Movable, Deinitable).
    S = NoopSink (sentinel; not used by synthetic ops).
    ro = never_origin (immutable static origin; synthetic op has no
         caller-borrow so this is the correct annotation).
    """
    var op = IoOp[Int, NoopSink, never_origin].synthetic_ready(
        value=42, op_id=Int64(7)
    )
    assert_equal(op.op_id(), Int64(7))
    assert_true(op.is_ready())
    assert_false(op.is_pending())
    assert_false(op.has_err())
    var v = op^.wait()
    assert_equal(v, 42)


def test_ioop_synthetic_err_raises_via_wait() raises:
    """synthetic Err IoOp surfaces the error string via wait()."""
    var op = IoOp[Int, NoopSink, never_origin].synthetic_err(
        err=String("boom"), op_id=Int64(11)
    )
    assert_true(op.has_err())
    assert_false(op.is_ready())
    var raised = False
    try:
        var _v = op^.wait()
    except:
        raised = True
    assert_true(raised)


def test_ioop_pending_without_reactor_raises_in_phase12() raises:
    """a Pending op without a reactor wiring cannot make
    progress; wait() raises an explicit "needs Reactor wiring" error. This
    test guards the staging boundary — once IoOp gets a
    reactor pointer, this test should be replaced with a real
    reactor-driven wait-loop test.
    """
    var op = IoOp[Int, NoopSink, never_origin](op_id=Int64(0), state=OP_PENDING)
    assert_true(op.is_pending())
    var raised = False
    try:
        var _v = op^.wait()
    except:
        raised = True
    assert_true(raised)


def test_ioop_for_read_phase13_stub() raises:
    """Stub: for_read raises until 1.3 wires the Reactor."""
    var raised = False
    try:
        var _op = IoOp[Int, NoopSink, never_origin].for_read()
    except:
        raised = True
    assert_true(raised)


def test_ioop_wait_with_token_class_b_stub() raises:
    """wait_with_token now takes a CancellationToken
    and short-circuits on Ready / Err / pre-cancel. The earlier
    behavior was `raise Error("stub")`; updated to
    verify the new contract: synthetic Ready returns the value.
    """
    var op = IoOp[Int, NoopSink, never_origin].synthetic_ready(
        value=99, op_id=Int64(1)
    )
    var token = CancellationToken.new()
    var v = op^.wait_with_token(token)
    assert_equal(v, 99)


def test_ioop_ready_helper() raises:
    """free fn `ioop_ready[T, S, ro](value)` is the
    canonical synthetic-Ready constructor used by channel.recv /
    MorselPool.try_claim / Stream.next / Timer.sleep when the
    operation can be answered immediately.
    """
    var op = ioop_ready[Int, NoopSink, never_origin](value=1234)
    assert_true(op.is_ready())
    var v = op^.wait()
    assert_equal(v, 1234)


def main() raises:
    test_thread_waker_imports()
    test_fd_waker_imports()
    test_noop_sink_imports()
    test_ioop_synthetic_ready_returns_value_via_wait()
    test_ioop_synthetic_err_raises_via_wait()
    test_ioop_pending_without_reactor_raises_in_phase12()
    test_ioop_for_read_phase13_stub()
    test_ioop_wait_with_token_class_b_stub()
    test_ioop_ready_helper()
    print("PASS komira_async.ops smoke")
