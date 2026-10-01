# =============================================================================
# komira_async.cancellation.budget — ExecutionBudget
# =============================================================================
#
#
# Wall-clock + work-unit budget. Workers consult on morsel boundaries:
# if either dimension is exhausted, the budget cancels its bound token.
#
# Atomic[DType.int64] for morsels — uint8 lacks fetch_sub on Mojo 0.26.3
# (finding 4); int64 is canonical.
#
# 8 scope: morsels-only. Wall-clock deadline support is structurally
# present (deadline_ns field) but the time check requires clock_gettime FFI;
# the deadline_ns=0 (no deadline) path is the only one implemented in 1.8;
# / D adds the time-check pathway.
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64

from komira_async.cancellation.token import CancellationToken


struct ExecutionBudget(Movable, Deinitable):
    """Wall-clock + work-unit budget.

    8 morsels-only impl. Each call to check() decrements an atomic
    counter; on exhaustion the bound token is cancelled and CancelledError
    is raised. Wall-clock deadline support stubbed (deadline_ns=0 means no
    deadline; non-zero deferred).

    Pointer discipline:
      * morsels counter via OwnedPointer[Atomic[int64]] (Repro 7 pattern;
        Atomic non-Movable on 0.26.3, OwnedPointer indirection makes this
        Movable).
      * _bound_token by value — CancellationToken is Movable + Copyable.
    """

    var _deadline_ns: Int64
    var _morsels: OwnedPointer[AtomicI64]
    var _bound_token: CancellationToken

    def __init__(out self, deadline_ns: Int64, morsels: Int64, var bound_token: CancellationToken):
        # Bound token consumed by `var`; CancellationToken is Movable but
        # NOT Copyable. Callers `.clone()` if they need to retain a handle.
        self._deadline_ns = deadline_ns
        var raw = alloc[AtomicI64](1)
        # SAFETY: raw is a fresh allocation we own. Atomic ctor accepts a
        # Scalar value. Ownership transfers to OwnedPointer.
        raw[] = AtomicI64(Int64(morsels))
        self._morsels = OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)
        self._bound_token = bound_token^

    def check(mut self) raises:
        """Cancels _bound_token if budget
        exhausted. Decrements the morsels counter atomically; if the
        result is < 0 (i.e., we tried to consume past zero), cancels +
        raises.

        8 morsels-only. Wall-clock deadline check is gated on
        clock_gettime FFI plumbing.
        """
        # Atomic fetch_sub returns the value BEFORE the subtraction.
        # If pre-value <= 0, the budget was already at/past zero; cancel.
        # Instance method form (mut self via OwnedPointer[]=); avoids the
        # static-API + UnsafePointer-launder dance.
        var prev = self._morsels[].fetch_sub(Int64(1))
        if prev <= Int64(0):
            self._bound_token.cancel(String("ExecutionBudget exhausted"))
            # CancelledError is a struct; Mojo 0.26.3's `raise`
            # takes a builtin Error, so we raise an Error with the canonical
            # message. Callers test for cancellation via the bound token
            # (token.is_cancelled()) — the raised Error is the exit-fast
            # signal for the worker loop.
            raise Error("CancelledError: ExecutionBudget exhausted")

    def remaining(self) -> Int64:
        """Returns the current morsels count. Diagnostics-only."""
        return self._morsels[].load()
