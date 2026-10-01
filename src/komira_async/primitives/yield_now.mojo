# =============================================================================
# komira_async.primitives.yield_now — cooperative-scheduling yield
# =============================================================================
#
#
# Minimum-viable form: yield_now() returns a synthetic-ready
# IoOp[(), NoopSink, never_origin]. The IoOp is Ready from construction, so
# `yield_now().wait()` returns immediately. The actual cooperative-yield
# semantics (re-enqueue current task to local FIFO; let other tasks run;
# then resume) requires the worker-local task queue + scheduler step,
# which this does not yet use.
#
# This shape ships the public signature so dependent code
# compiles + the IoOp-uniformity property holds (callers can compose
# `yield_now()` with other IoOps in select/gather). The yield is a no-op
# at runtime.
# =============================================================================

from komira_async.ops.io_op import IoOp, ioop_ready
from komira_async.ops.waker_sink import NoopSink
from komira_async.primitives.never_origin import never_origin


def yield_now() -> IoOp[Int, NoopSink, never_origin]:
    """Yield the current task back to the
    local FIFO so other ready tasks can run before this one resumes.

    Minimum-viable: returns a synthetic-ready IoOp. The actual
    cooperative-yield semantics need the worker-local
    task queue + scheduler step. Until then, `yield_now().wait()` is a
    no-op (returns immediately).

    Type parameter `T = Int`: ideally `IoOp[(), ...]`, but Mojo 0.26.3
    doesn't have a unit type aside from `NoneType` (which is awkward to
    bind through generics with the ImplicitlyCopyable bound).
    uses `Int` as the placeholder payload (returns 0); may
    reshape to a true unit-typed yield_now.
    """
    return ioop_ready[Int, NoopSink, never_origin](0)
