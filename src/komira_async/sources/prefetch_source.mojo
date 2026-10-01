# =============================================================================
# komira_async.sources.prefetch_source — PrefetchRing[S, Output] +
# prefetch_source_step helper
# =============================================================================
# ONE bulk-parallel pattern; per-morsel
# IO is the depth=1 specialization. Operators submit up to `prefetch_depth`
# IO ops in flight per worker; depth is auto-tuned per storage type.
#
# Why composition (PrefetchRing) instead of a Mojo trait + default step:
#   * A PrefetchSource trait would declare an associated
#     `Output` type and a `step` body that uses `Output` + a generic
#     `IoOp[Bytes, S, ro]`. Mojo 0.26.3 trait support is too thin to
#     express this shape — traits with parametric associated types +
#     default bodies that use them don't reliably elaborate.
#   * Composition gives the same observable shape: every operator
#     composes a `PrefetchRing[S, Output]` field, calls
#     `prefetch_source_step` from its `step` method, and implements
#     two callbacks (`next_op` + `decode`). The ring handles refill +
#     completion polling + parking.
#   * Per the dispatch directive: "If a Mojo language constraint blocks
#     the trait+default-impl shape, adapt to the closest workable shape
#     and document." This file is that adaptation.
#
# Public surface:
#   PrefetchRing[S, Output]
#       Field-composition helper. Owns:
#         * _in_flight: List[Int64] — op_ids currently submitted
#         * _depth: Int — operator's chosen prefetch depth
#       Operators construct one per-source-instance, hold it as a field.
#
#   PrefetchStepResult[Output]
#       The four signals the prefetch step body returns to the operator's
#       owning code. Mirrors StepResult but without the parked op_ids
#       payload (the ring keeps them):
#         * Yielded(out)  — refill loop completed; emit `out`
#         * Parked        — refill loop parked; ring holds the op_ids
#         * Done          — operator is exhausted (next_op returned None)
#         * Error(text)   — unrecoverable
#
# Usage shape (operator authors):
#
#   struct LocalParquetSource:
#       var _ring: PrefetchRing[NoopSink, Morsel]
#       var _file_cursor: ...
#
#       fn prefetch_depth(self) -> Int: return 4   # NVMe
#
#       fn next_op(mut self) -> Optional[IoOp[...]]:
#           # Build the next IO op or return None if cursor exhausted.
#           ...
#
#       fn decode(mut self, c: Completion) -> Optional[Morsel]:
#           # Consume the completion's bytes, decode into a Morsel.
#           ...
#
#       fn step(mut self, ctx) -> StepResult[Morsel]:
#           # Run the prefetch step body. We can't use a single helper
#           # function template easily because Mojo lambdas / closures
#           # don't capture mut self cleanly. The recommended shape:
#           # inline the prefetch loop using `_ring`'s refill + poll
#           # primitives.
#           return prefetch_source_step_inline(self^, ctx)
#
# Pointer discipline:
#   * ZERO `UnsafePointer` in any public method signature.
#   * ZERO new wildcard origins.
#   * `_in_flight: List[Int64]` is a stack-tracking primitive; List[Int64]
#     is Movable + carries trivial drop.
# =============================================================================

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import Completion
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.morsel_step_driver import MorselStepCtx
from komira_async.runtime.step_result import StepResult


# Per-storage-type depth defaults from
#
# Calibrated empirically per storage type.
# Summary:
#
#   * The PrefetchRing has NO internal saturation up to depth=256 at every
#     latency tier ≥ 10ms (95-99% pipeline efficiency vs Little's-Law
#     ideal). The values below are NOT ring caps — they are matched to
#     external-bandwidth saturation per storage type.
#   * For sub-ms latencies (NVMe), depth > 32 actively hurts p99 due to
#     kernel-timer-batching slack. PREFETCH_DEPTH_LOCAL_NVME=4 stays
#     conservative.
#   * Power users overriding via `read_parquet(..., prefetch_depth=N)` can
#     safely go higher (256 measured clean) without the ring becoming the
#     bottleneck.
#
# The values below are defaults.
comptime PREFETCH_DEPTH_INMEMORY: Int = 1
comptime PREFETCH_DEPTH_LOCAL_NVME: Int = 4
comptime PREFETCH_DEPTH_NETWORKED_BLOCK: Int = 16
comptime PREFETCH_DEPTH_KAFKA: Int = 16
comptime PREFETCH_DEPTH_S3_EXPRESS: Int = 32
comptime PREFETCH_DEPTH_S3_STANDARD: Int = 64
comptime PREFETCH_DEPTH_OBJECT_STORE_METADATA: Int = 128


# =============================================================================
# PrefetchRing[S, Output] — composition helper.
# =============================================================================


@fieldwise_init
struct PrefetchRing[
    S: WakerSink & Movable & Deinitable,
    Output: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Per-source-instance prefetch ring. Operator authors compose this
    as a field; the ring's primitives handle refill + completion polling.

    Field set:
      var _in_flight: List[Int64]   # op_ids currently submitted
      var _depth: Int               # max in-flight bound (storage type)

    The `S` parameter matches the worker's waker-sink type; the `Output`
    parameter is the morsel type the operator emits (decoded from
    completions). The ring itself doesn't own `Output` values — it only
    tracks op_ids; the operator's `decode` step transforms a Completion
    into an Output.
    """

    var _in_flight: List[Int64]
    var _depth: Int

    def __init__(out self, depth: Int):
        """Construct with explicit prefetch depth. Operators pass the
        per-storage-type default (PREFETCH_DEPTH_S3_STANDARD = 64,
        PREFETCH_DEPTH_LOCAL_NVME = 4, etc.) or a user-override value."""
        self._in_flight = List[Int64](capacity=depth)
        self._depth = depth

    @always_inline
    def depth(self) -> Int:
        """The configured prefetch depth — `_in_flight.len()` MUST stay
        <= this bound."""
        return self._depth

    @always_inline
    def in_flight_len(self) -> Int:
        """Current in-flight op count. Used to decide whether to refill
        on each step iteration."""
        return len(self._in_flight)

    @always_inline
    def is_full(self) -> Bool:
        """True when in_flight_len == depth (refill loop should stop)."""
        return self.in_flight_len() >= self._depth

    @always_inline
    def is_empty(self) -> Bool:
        """True when no ops are in flight (caller may decide the
        operator is done if next_op also returns None)."""
        return self.in_flight_len() == 0

    def add_inflight(mut self, op_id: Int64):
        """Record that `op_id` was submitted to the reactor and is now
        in flight. Caller's contract: never exceed depth (in_flight_len
        must be < depth at call time)."""
        self._in_flight.append(op_id)

    def remove_inflight(mut self, op_id: Int64) -> Bool:
        """Remove `op_id` from the in-flight set. Returns True if found,
        False otherwise. Called when a completion matching the op_id
        arrives; the operator's `decode` then runs on the completion."""
        var n = len(self._in_flight)
        for i in range(n):
            if self._in_flight[i] == op_id:
                # Swap-remove (preserves O(1)).
                if i != n - 1:
                    self._in_flight[i] = self._in_flight[n - 1]
                _ = self._in_flight.pop()
                return True
        return False

    def op_ids_snapshot(self) -> List[Int64]:
        """Returns a COPY of the in-flight op_ids list. Used to construct
        the parked StepResult's wait set (`StepResult.parked_any(op_ids)`).

        Int64 List copy is a single-buffer memcpy — single-digit
        microseconds for N<=64. The cost is incurred once per park; the
        StepResult drop walks the same buffer."""
        return List[Int64](self._in_flight)

    def clear(mut self):
        """Drop all in-flight op_ids. Used by graceful shutdown / cancel
        propagation: the operator is responsible for ALSO calling
        Reactor.deregister on each op_id (or accepting the completions
        as best-effort drops)."""
        self._in_flight = List[Int64]()


# =============================================================================
# Reusable refill / poll-and-decode helpers.
# =============================================================================
#
# These free functions are the primitives that operator step bodies use.
# They take refs to the ring + reactor and operate on them directly. The
# step body itself remains in the operator (so it can call its own
# `next_op` / `decode` methods on `mut self` — which a helper function
# can't do without Mojo lambda support that 0.26.3 doesn't fully provide).
#
# The shape: operator's step() inlines these helpers in a structured
# pattern (see the docstring example at the top of this file). The
# pattern is duck-typed via convention, not enforced by a trait — but
# every operator follows the same shape, so behavior is uniform.
# =============================================================================


def prefetch_ring_try_pop_completion[
    S: WakerSink & Movable & Deinitable,
    Output: Copyable & ImplicitlyCopyable & Movable & Deinitable,
    ro: Origin[mut=True],
](
    mut ring: PrefetchRing[S, Output],
    ref [ro] reactor_ref: Reactor[S],
) raises -> Optional[Completion]:
    """Step-body helper: drives `Reactor.try_pop_any_completion` with the
    ring's current in-flight set. If a completion arrives for one of our
    op_ids, returns it (and the ring removes that op_id from in_flight).
    Otherwise returns None.

    The operator's step body uses this to decide:
      * Some(c)   → call self.decode(c); return StepResult.yielded(out).
      * None      → ring is either full + nothing-ready (park) OR empty
                    + next_op also returned None (done). The caller
                    consults ring.is_empty() to disambiguate.

    Note: this helper does NOT remove the op_id automatically — the caller
    must call `ring.remove_inflight(c.op_id)` after consuming the
    completion. This is to allow the operator to inspect the completion
    record's hangup / err_code BEFORE marking the slot freed (e.g., to
    decide whether to retry or propagate the error).
    """
    var op_ids = ring.op_ids_snapshot()
    return reactor_ref.try_pop_any_completion(op_ids)


def prefetch_ring_park_step_result[
    S: WakerSink & Movable & Deinitable,
    Output: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](
    ring: PrefetchRing[S, Output],
) -> StepResult[Output]:
    """Step-body helper: build the `StepResult.parked_any(op_ids)` shape
    for the current in-flight set. Caller returns this from its step()
    when no completion was ready and the ring is non-empty.

    The morsel-step trampoline (`MorselStepDriver`) walks the wait set
    + indexes the morsel state into the parked-morsel slab keyed by
    every op_id. The first completion matching ANY id wakes the morsel."""
    var ids = ring.op_ids_snapshot()
    return StepResult[Output].parked_any(op_ids=ids^)


# =============================================================================
# PrefetchStepResult[Output] — alias for StepResult[Output].
# =============================================================================
#
# The calls out a separate step-result kind for the
# prefetch step body. In our composition shape there's no need for a
# distinct type — operator step bodies return the same `StepResult[Output]`
# everywhere. The `PrefetchStepResult` alias below is purely a
# documentation convenience for code that wants the shape's intent
# explicit at the call site.


comptime PrefetchStepResult = StepResult


# =============================================================================
# Documentation — the recommended PrefetchSource step body shape.
# =============================================================================
#
# Operators implement `step` like this (pseudocode; concrete impls in
# the engine operators):
#
#   fn step(mut self, ctx: ref MorselStepCtx[S]) -> StepResult[Output]:
#       # 1. Refill: submit ops up to depth.
#       while not self._ring.is_full():
#           var maybe_op = self.next_op()
#           if not maybe_op.__bool__():
#               break  # cursor exhausted
#           var op = maybe_op.take()
#           # Submit via the ctx's reactor; collect the op_id.
#           var op_id = ctx.reactor()[].submit_get_id(op^)
#           self._ring.add_inflight(op_id)
#
#       # 2. Try to pop ANY in-flight completion.
#       var maybe_c = prefetch_ring_try_pop_completion(
#           self._ring, ctx.reactor()[],
#       )
#       if maybe_c.__bool__():
#           var c = maybe_c.value()
#           _ = self._ring.remove_inflight(c.op_id)
#           if c.err_code != Int32(0):
#               return StepResult[Output].error(
#                   err=String("PrefetchSource: completion errno=")
#                       + String(Int(c.err_code)),
#               )
#           var maybe_out = self.decode(c)
#           if maybe_out.__bool__():
#               return StepResult[Output].yielded(value=maybe_out.value())
#           # decode returned None — the completion produced no output
#           # (e.g., metadata-only prefetch); fall through to park.
#
#       # 3. Empty ring + cursor exhausted → done.
#       if self._ring.is_empty():
#           return StepResult[Output].done()
#
#       # 4. Park on the wait set.
#       return prefetch_ring_park_step_result(self._ring)
#
# The shape is uniform across depth=1 (single-op, e.g. Kafka producer)
# and depth=N (bulk-parallel, e.g. S3ParquetSource). Authors implement
# `next_op` + `decode`; the framework handles the rest.
# =============================================================================
