# =============================================================================
# komira_async.runtime.local_io_block — LocalIoBlock[S]
# =============================================================================
# `io_block()` accessor on PerCoreAsyncRuntime.
#
# `LocalIoBlock[S]` is the lowest-risk of the three trait-surface
# façades. It exists to let a task body block on an `IoOp[T, S, ro]` from
# inside a worker-context call site:
#
#     ref io = rt.io_block()
#     var result = io.block_on(my_op^)
#
# The façade is a STORED FIELD on `PerCoreAsyncRuntime` (settled by the
# parametric-origin-return pattern); the accessor returns
# `ref [self._io_block] LocalIoBlock[Self.S]`. Storing the façade lets the
# wake-word live at a stable heap address for the runtime's lifetime — it's
# the canonical shape we want once the worker integration lands.
#
# Step 2 scope (this file):
#   - Accepts a moved-in IoOp[T, S, ro], returns its result by COPY (or
#     raises on err).
#   - Drives the op state machine (OP_READY / OP_ERR / OP_PENDING) using
#     the same logic IoOp.wait() does today.
#   - Holds a stable park-word (`_park_word: OwnedPointer[Atomic[int32]]`)
#     reserved for the reactor-driven park/unpark cycle. Today the
#     park-word is held but unused — its presence guarantees a stable
#     heap-stable wake-target address that the IoSubsystem can signal once
#     the cross-worker SPSC wiring lands. This costs ~16 bytes; the
#     bench-gate is unaffected (block_on on a synthetic-ready op never
#     touches the syscall path).
#
# Future:
#   - On OP_PENDING, drive a park-loop:
#       1. snapshot wake_word.load(Acquire)
#       2. recheck op state (drained by reactor sink writing into the slot
#          OR by direct trampoline write)
#       3. if still pending: wait_on_address(wake_word, snapshot) to park
#       4. on wake / EAGAIN: re-check
#   - The wake-word is signaled by the worker's IoSubsystem when its
#     reactor.run_once observes the op_id ready (the existing waker_sink
#     pattern; the sink hands op_id off to the LocalIoBlock's wake_word
#     via a per-op_id side-table).
#
# Pointer discipline:
#   - ZERO `UnsafePointer` in any public method signature.
#   - ZERO new `unsafe_from_address=Int(...)` sites.
#   - ZERO new wildcard origins.
#   - The single internal heap-stable atomic uses the same `OwnedPointer[
#     Atomic[..]] + unsafe_from_raw_pointer` shape used elsewhere in the
#     package (Repro 7 / the canonical shape). No new patterns introduced.
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI32
from std.time import perf_counter_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.io_op import IoOp, OP_PENDING, OP_READY, OP_ERR
from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import (
    Completion,
    OpHandle,
    OP_PENDING as OPH_PENDING,
    OP_READY as OPH_READY,
    OP_ERR as OPH_ERR,
)
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.step_result import StepResult
from komira_async.runtime.wake_primitives import pause_intrinsic


struct LocalIoBlock[
    S: WakerSink & Movable & Deinitable,
](Movable, Deinitable):
    """trait-surface façade for
    blocking on an IoOp from inside a worker call site.

    Stored as a field on PerCoreAsyncRuntime[S]; reached via
    `rt.io_block()` which returns `ref [self._io_block] LocalIoBlock[S]`.

    Field set:
      var _park_word: OwnedPointer[Atomic[DType.int32]]   # stable wake-target

    The park-word is reserved for the reactor-driven park/unpark
    cycle. It MUST live at a stable heap address (futex / __ulock_wait
    rely on the address staying valid for the syscall's duration), which
    the OwnedPointer + heap-Atomic shape provides. Same pattern used by
    Worker._shutdown_flag and Reactor._next_op_id.
    """

    var _park_word: OwnedPointer[AtomicI32]

    def __init__(out self):
        """Construct a LocalIoBlock with a fresh park-word at 0.

        Atomic[DType.int32] is non-Movable on Mojo 0.26.3, so we
        heap-allocate via alloc + the OwnedPointer.unsafe_from_raw_pointer
        ctor (Repro 7 / the canonical shape). Same shape as Worker._shutdown_flag.
        """
        var raw = alloc[AtomicI32](1)
        # SAFETY: raw is a fresh allocation we own; we initialize it via
        # direct field-style assignment (the Atomic ctor accepts a Scalar
        # value), then transfer ownership to OwnedPointer. __del__ frees
        # via OwnedPointer's drop.
        raw[] = AtomicI32(Int32(0))
        self._park_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw,
        )

    def block_on[
        T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
        ro: Origin[mut=False],
    ](mut self, var op: IoOp[T, Self.S, ro]) raises -> T:
        """Block on the supplied IoOp until
        it transitions out of OP_PENDING; return the result by COPY.

        Step 2 body — synthetic-ready / synthetic-err only:
          - OP_READY  → return op._result.value() by copy.
          - OP_ERR    → raise Error(op._err).
          - OP_PENDING → raise Error(...). There is no real reactor wiring
            yet; a later step replaces this
            branch with wait_on_address(self._park_word, ...) + a worker
            run_once drive loop.

        T is returned by COPY (per the IoOp.wait() contract — the
        `T: ImplicitlyCopyable` bound is load-bearing). No partial-move
        via take_pointee.

        The op is moved in (`var op`) and consumed by this call. Drop runs
        at end-of-call.
        """
        var status = op.poll()
        if status == OP_READY:
            # Return by copy — IoOp.wait() does the same. The Optional
            # holds the value at OP_READY construction (synthetic_ready
            # factory + reactor-completion path both populate _result).
            # `wait()` takes `var self` (consumes the op), so we transfer
            # ownership via `^`. The function-result is T returned by COPY
            # via Optional.value() (T: ImplicitlyCopyable per IoOp's
            # bound).
            return op^.wait()
        if status == OP_ERR:
            # Re-raise the captured error string. IoOp.wait() also handles
            # this branch; we delegate to keep the invariant in one place.
            return op^.wait()
        # OP_PENDING with no reactor backing: same behavior as the
        # current IoOp.wait() — raise unconditionally.
        # This ships the trait-surface API; a later step wires the real
        # reactor-park loop. Tests that exercise this branch verify the
        # error-shape, not the eventual park behavior.
        raise Error(
            "LocalIoBlock.block_on: IoOp pending with no reactor wiring"
            " (synthetic ops only)"
        )

    def park_word_load(self) -> Int32:
        """Diagnostic accessor: returns the current value of the park-word.
        Useful for tests to verify the wake-word starts at 0 and to
        synchronize with future wake-from-reactor wiring. Returns a typed
        scalar — public surface stays UnsafePointer-free.
        """
        return self._park_word[].load()

    # ==================================================================