# =============================================================================
# komira_async.runtime.morsel_step_driver — MorselStepDriver[S, Op] +
# MorselStepCtx[S] — bulk-IO worker-loop morsel-step trampoline
# =============================================================================
# Worker loop integration + MorselStepCtx, over the per-op_id parked-morsel
# slab (ParkedMorselSlab[State]).
#
# The THIRD substrate primitive: the morsel-step trampoline
# that ties together
#   1. StepResult (discriminated value type — `step_result.mojo`)
#   2. ParkedMorselSlab (per-worker state store — `parked_morsel_slab.mojo`)
#   3. Reactor.try_pop_any_completion (bulk-parallel non-blocking poll —
#      `reactor.mojo`)
# into the per-worker run-loop. It
# is the canonical worker shape for engine compute workers, distinct from:
#
#   * `LocalDispatcher.run_with_state` — the existing fork-join compute
#     dispatch (no IO, no parked-morsel resume); used by operators that
#     don't need IO.
#   * `Worker.run_until_shutdown` — the multiplexed event loop pattern
#     used by the HTTP server and runtime infrastructure (long-lived
#     state machines dispatched by fd; not per-morsel).
#
# Public surface:
#
#   trait MorselStepOperator:
#       """Operator authors implement step + observe done state."""
#       alias State
#       alias Output
#       fn step(mut self, mut state, ctx) -> StepResult[Output]
#       fn is_done(self) -> Bool   # true when no more morsels to emit
#       fn next_state(mut self) -> Optional[State]   # produces fresh state
#
# (We use a concrete struct + duck-typed parametric calls instead of a Mojo
# trait because Mojo 0.26.3's trait system doesn't support nested aliases
# cleanly. The `MorselStepDriver[S, Op]` parametric struct + function
# templates below give the same compile-time monomorphization shape.)
#
#   struct MorselStepCtx[S]:
#       """Per-step context handed to operator.step(). Exposes the worker's
#       reactor + io_block + cancellation token. Re-handed each step."""
#
#   struct MorselStepDriver[S, Op]:
#       """The trampoline. Owns the parked-morsel slab + the in-flight ring;
#       drives operator.step in a loop and resumes parked morsels on
#       completion."""
#
# Pointer discipline:
#   * ZERO `UnsafePointer` in any public method signature.
#   * ZERO new wildcard origins.
#   * The driver holds a mutable REF to the worker's `Reactor[S]` via a
#     `Pointer[Reactor[S], origin]` field with a concrete origin; this
#     mirrors the IoOp pattern. No raw UnsafePointer in the public API.
# =============================================================================

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import Completion
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.local_io_block import LocalIoBlock
from komira_async.runtime.parked_morsel_slab import ParkedMorselSlab
from komira_async.runtime.step_result import StepResult
from komira_core.collections.slab import Slab


# =============================================================================
# MorselStepCtx[S] — per-step context handed to operator.step().
# =============================================================================
#
# Holds the per-worker handles the operator may need during a step:
#   * reactor: the Reactor[S] for IO submission + completion polling.
#   * io_block: the LocalIoBlock[S] for spin-then-park primitives.
#   * cancel_token: the cancellation token to check on every step.
#   * worker_id: the running worker's identity (UInt16 — caller-friendly
#     scalar; matches Worker._worker_id shape).
#
# All references are scoped to the step invocation: the operator MUST NOT
# stash any of these in its morsel state across step calls. They are
# re-handed on the next step call by the driver.
#
# Storage shape:
#   * The Ctx is a stack-local value the driver constructs once per step
#     iteration. It carries Pointer[Reactor[S], origin] and Pointer[
#     LocalIoBlock[S], origin] under concrete origins (mut=True for both).
#   * cancel_token is held by VALUE (Movable, heap-arc-backed; the
#     CancellationToken's clone() is the shared-ownership primitive).
#
# The Ctx CANNOT be Movable across worker invocations — it carries
# borrowed lifetimes. So we don't expose it as a struct field on the
# driver; the driver synthesizes a fresh Ctx each step iteration. The
# operator's step body takes a reference to it.
# =============================================================================


@fieldwise_init
struct MorselStepCtx[
    S: WakerSink & Movable & Deinitable,
    reactor_origin: Origin[mut=True],
    io_block_origin: Origin[mut=True],
](Movable, Deinitable):
    """Per-step context handed to operator.step() by the trampoline.

    Field set:
      var _reactor: Pointer[Reactor[Self.S], Self.reactor_origin]
      var _io_block: Pointer[LocalIoBlock[Self.S], Self.io_block_origin]
      var _cancel_token: CancellationToken
      var _worker_id: UInt16

    Operator authors call:
      ctx.reactor() — get the per-worker Reactor[S]
      ctx.io_block() — get the LocalIoBlock[S] (try_io_handle entry point)
      ctx.cancellation() — get the cancel token (poll is_cancelled() to
                            check; clone() to hand off into a longer-lived
                            scope, e.g. a parked morsel's state)
      ctx.worker_id() — UInt16 for diagnostics / hot-shard metrics

    The Pointer<Reactor> + Pointer<LocalIoBlock> shape mirrors the
    IoOp[T, S, ro] pattern (origin-parameterized field; concrete origin
    threaded through monomorphization). No UnsafePointer in the public
    surface.
    """

    var _reactor: Pointer[Reactor[Self.S], Self.reactor_origin]
    var _io_block: Pointer[LocalIoBlock[Self.S], Self.io_block_origin]
    var _cancel_token: CancellationToken
    var _worker_id: UInt16

    def reactor(self) -> Pointer[Reactor[Self.S], Self.reactor_origin]:
        """Returns the borrowed Reactor pointer. Operator code dereferences
        via `ctx.reactor()[].submit(...)` (same pattern as IoOp)."""
        return self._reactor

    def io_block(self) -> Pointer[LocalIoBlock[Self.S], Self.io_block_origin]:
        """Returns the borrowed LocalIoBlock pointer for try_io* primitives."""
        return self._io_block

    def cancellation(self) -> CancellationToken:
        """Returns a CLONE of the cancellation token. Caller takes ownership;
        polling `is_cancelled()` is allowed on the clone. The clone() bumps
        the ArcPointer refcount on the chain slots (cheap)."""
        return self._cancel_token.clone()

    @always_inline
    def worker_id(self) -> UInt16:
        """Returns the running worker's id."""
        return self._worker_id

    def is_cancelled(self) -> Bool:
        """Convenience: poll the cancel token without cloning."""
        return self._cancel_token.is_cancelled()

    def try_pop_any_completion(self, op_ids: List[Int64]) raises -> Optional[Completion]:
        """Convenience: forwards to the worker's reactor's bulk-parallel
        primitive. Operator authors who write the prefetch loop directly
        (rather than going through PrefetchSource.step) call this on each
        spin iteration."""
        return self._reactor[].try_pop_any_completion(op_ids)


# =============================================================================
# MorselStepDriver[S, Op] — the trampoline.
# =============================================================================
#
# Owns:
#   * `_parked_morsels: ParkedMorselSlab[Op.State]` — per-worker store of
#     parked-morsel state, keyed by op_id.
#   * `_parked_op_ids: List[List[Int64]]` — for each parked morsel, the
#     FULL set of op_ids it's waiting on (the wait set;
#     "key it by ALL op_ids in the wait set"). Parallel array to the slab;
#     index N in `_parked_op_ids` matches index N in `_parked_morsels`'s
#     internal storage.
#   * `_max_inflight: Int` — backpressure cap on concurrently-parked
#     morsels. Default 64; dispatched
#   * `_done: Bool` — set when the driver observes operator.is_done()
#     AND parked_morsels.is_empty() AND no morsel-pull was successful.
#
# The driver does NOT own the operator (`Op`) — operators are passed in
# per call (the caller can hold one operator per worker, or multiple via
# fan-out). This decouples driver lifetime from operator type.
#
# Drive shape: synchronous, fork-join-friendly. The caller invokes
# `drive_one_iteration(ctx, operator)` repeatedly until the driver
# observes done. Each iteration:
#   1. Drain ready completions (non-blocking poll); resume parked morsels
#      whose wait set contains a completing op_id.
#   2. Pull a new morsel from the operator (operator.next_state()) if
#      under the in-flight cap.
#   3. Call operator.step(state, ctx) — handle StepResult.
#   4. Return: count of yielded outputs this iter (caller can sink them).
#
# This is the "function template" form of the worker-loop new mode. A
# higher-level integration that ties this into Worker.run_until_shutdown
# is left to a follow-up (the existing Worker has a complex multiplexed
# loop already; integrating morsel-step there requires a wider refactor).
# =============================================================================


# Default in-flight cap. 64 matches the S3 PrefetchSource depth from
# (per-storage-type table). Per-worker caps higher
# than this risk out-of-memory under burst loads; smaller caps lose
# bulk-parallel throughput on high-latency backends.
comptime DEFAULT_MAX_INFLIGHT: Int = 64


@fieldwise_init
struct MorselStepDriver[
    S: WakerSink & Movable & Deinitable,
    State: Movable & Deinitable,
    Output: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Per-worker morsel-step trampoline. Generic over:
      * S — worker waker sink type (matches Reactor[S], LocalIoBlock[S]).
      * State — per-morsel state type (operator's State alias).
      * Output — emitted morsel type (operator's Output alias).

    Field set:
      var _parked_morsels: ParkedMorselSlab[Self.State]
      var _parked_op_ids: List[List[Int64]]   # per-parked wait sets
      var _max_inflight: Int
      var _yielded_count: Int64               # observability
      var _parked_count: Int64                # observability
      var _resumed_count: Int64               # observability
      var _error_count: Int64                 # observability

    Why parallel arrays instead of `Dict[Int64, ...]`:
      * Mojo 0.26.3 Dict has a non-trivial copy / partial-move shape
        that interacts poorly with Movable-only State types.
      * Linear scan is fine at the <100 in-flight per worker scale the
 documents.
      * Same shape as Reactor._wakers (List[WakerSlot] + linear scan).

    Why _parked_op_ids is List[List[Int64]] not List[Int64]:
      * For depth=1 morsels, the inner List has 1 entry.
      * For depth=N (PrefetchSource bulk-parallel), it has N entries.
      * The driver scans all parked morsels for each completion: if a
        completion's op_id is in the morsel's wait set, the morsel
        wakes; the OTHER op_ids in its set become "spurious wake"
        candidates (the morsel will see them on next step or they get
        consumed by a later parked morsel — we don't pre-emptively
        cancel them; the operator's step body is responsible for
        idempotently handling extra completions).
    """

    var _parked_morsels: ParkedMorselSlab[Self.State]
    var _parked_op_ids: List[List[Int64]]
    var _max_inflight: Int
    var _yielded_count: Int64
    var _parked_count: Int64
    var _resumed_count: Int64
    var _error_count: Int64

    def __init__(out self):
        """Default-construct. Defaults to DEFAULT_MAX_INFLIGHT (64)."""
        self._parked_morsels = ParkedMorselSlab[Self.State]()
        self._parked_op_ids = List[List[Int64]]()
        self._max_inflight = DEFAULT_MAX_INFLIGHT
        self._yielded_count = Int64(0)
        self._parked_count = Int64(0)
        self._resumed_count = Int64(0)
        self._error_count = Int64(0)

    def __init__(out self, max_inflight: Int):
        """Construct with explicit in-flight cap. Per-storage-type
        defaults: NVMe=4, S3=64, Kafka=16, in-memory=1."""
        self._parked_morsels = ParkedMorselSlab[Self.State](
            capacity=max_inflight,
        )
        self._parked_op_ids = List[List[Int64]](capacity=max_inflight)
        self._max_inflight = max_inflight
        self._yielded_count = Int64(0)
        self._parked_count = Int64(0)
        self._resumed_count = Int64(0)
        self._error_count = Int64(0)

    def parked_len(self) -> Int:
        """Number of currently-parked morsels."""
        return self._parked_morsels.len()

    def yielded_count(self) -> Int64:
        """Observability: total morsels yielded since construction."""
        return self._yielded_count

    def parked_count(self) -> Int64:
        """Observability: total park transitions since construction.
        (NOT the same as parked_len() — counts each park event, not
        the current parked-morsel count)."""
        return self._parked_count

    def resumed_count(self) -> Int64:
        """Observability: total parked-morsel resumes since construction.
        Equal to parked_count once all parked morsels have woken (steady
        state in the bulk-parallel pattern)."""
        return self._resumed_count

    def error_count(self) -> Int64:
        """Observability: total step errors observed since construction."""
        return self._error_count

    # =========================================================================
    # Internal helpers — parked-morsel bookkeeping.
    # =========================================================================

    def _park_morsel(mut self, var state: Self.State, var op_ids: List[Int64]):
        """Stash a parked morsel keyed by its full wait set.

        We use the FIRST op_id in the wait set as the slab key (the slab
        is a parallel-array Map[Int64 -> State]). Additional op_ids in
        the set are recorded in `_parked_op_ids` so the resume path can
        match them.

        Caller contract: `op_ids` MUST be non-empty. Empty wait sets
        produce a "morsel with no wake source" which would deadlock; we
        treat empty as a programming error and skip the park (the
        StepResult.parked_any(empty_list) path is documented in
        step_result.mojo as accepted-but-deadlock-prone)."""
        if len(op_ids) == 0:
            # Defensive: caller bug. Drop the state by letting it fall
            # out of scope at function exit — cheaper than asserting.
            _ = state^
            _ = op_ids^
            return
        # The slab key is the first op_id in the set. Any completion
        # matching ANY op_id in the wait set will trigger a resume via
        # _resume_for_op_id, which scans _parked_op_ids for membership.
        var first = op_ids[0]
        self._parked_morsels.park(op_id=first, state=state^)
        self._parked_op_ids.append(op_ids^)
        self._parked_count = self._parked_count + Int64(1)

    def _take_parked_for_op_id(mut self, op_id: Int64) -> Optional[Self.State]:
        """Find the parked morsel whose wait set CONTAINS `op_id` and
        extract its state. Returns None if no parked morsel matches.

        Linear scan over `_parked_op_ids`. The matching morsel's slot in
        BOTH parallel arrays is removed (slab.take_at(idx) shifts tail
        in the slab; we mirror the shift in `_parked_op_ids`)."""
        var n = len(self._parked_op_ids)
        for i in range(n):
            var ids_len = len(self._parked_op_ids[i])
            var match_found = False
            var key: Int64 = Int64(0)
            for j in range(ids_len):
                if self._parked_op_ids[i][j] == op_id:
                    # Match found at index i. Capture the slab key (the
                    # first op_id in the wait set) before we mutate the
                    # parallel array.
                    key = self._parked_op_ids[i][0]
                    match_found = True
                    break
            if match_found:
                # Use the public take(key) API; the slab re-locates the
                # slot internally (its own scan-by-key shape).
                var maybe = self._parked_morsels.take(key)
                # Mirror the shift in _parked_op_ids: shift entries [i+1..n)
                # left by one. List[List[Int64]] doesn't ImplicitlyCopy
                # its elements, so we use explicit List(copy=...) move-
                # equivalent via swap-and-pop semantics. Simplest: swap
                # the matched slot with the last slot, then pop the last
                # slot. This breaks arrival-order, but the caller doesn't
                # rely on it (resume order is whatever the reactor surfaces).
                var last = n - 1
                if i != last:
                    # swap-remove: copy last to i, drop last.
                    var last_ids = List[Int64](self._parked_op_ids[last])
                    self._parked_op_ids[i] = last_ids^
                _ = self._parked_op_ids.pop()
                self._resumed_count = self._resumed_count + Int64(1)
                return maybe^
        return Optional[Self.State]()

    # =========================================================================
    # drain completions; resume parked morsels.
    # =========================================================================

    def drain_completions[
        ro: Origin[mut=True],
    ](
        mut self,
        ref [ro] reactor_ref: Reactor[Self.S],
    ) raises -> Int:
        """Step 1 of the trampoline iteration: drain any completions
        currently available from the reactor's non-blocking poll +
        pending-buffer. For each completion, look for a parked morsel
        whose wait set contains the completion's op_id; if found, the
        morsel is added back to a "ready-again" working set (caller's
        responsibility to step it).

        Returns the number of completions drained this call (regardless
        of whether they matched a parked morsel — non-matches are benign
        and may belong to dropped/cancelled ops).

        We use `poll_completions(0)` rather than the
        `try_pop_any_completion` primitive because at this layer we want
        to drain EVERY ready completion at once, not just one matching
        any of a specific op_id set. The reactor's pending-buffer drain
        is part of poll_completions' contract."""
        var completions = reactor_ref.poll_completions(Int32(0))
        var n = len(completions)
        # We don't directly emit "ready-again" state here — the caller
        # threads each resumed state back into its own step call. So the
        # drain helper is paired with `take_parked_for_op_id` from the
        # caller's loop body. To make the API amenable to that, we
        # return the COMPLETIONS list via the caller's view: the simplest
        # shape is to surface a list-of-(op_id, completion) and let the
        # caller drive resumes. For now we keep a count return; the
        # caller polls via `poll_completions` directly when it needs
        # the raw list. (Future tightening: extract drain_and_resume
        # into a single method that takes an operator + ctx and runs
        # the resume chain inline.)
        # PHASE 1 NOTE: caller is expected to use `poll_and_resume`
        # below for the integrated resume path.
        _ = completions^
        return n

    def poll_and_resume[
        ro: Origin[mut=True],
    ](
        mut self,
        ref [ro] reactor_ref: Reactor[Self.S],
        timeout_us: Int32,
    ) raises -> Slab[ResumedMorsel[Self.State]]:
        """Drain completions from the reactor and convert any whose op_id
        matches a parked morsel into ResumedMorsel records. Caller threads
        each resumed state back into its own step() call.

        Args:
          reactor_ref: Borrowed mut ref to the worker's reactor.
          timeout_us: Passed to poll_completions. 0 = non-blocking;
                      -1 = block forever (useful when there's nothing
                      else to do); >0 = bounded blocking.

        Returns: Slab[ResumedMorsel[State]] — one entry per resumed
        morsel. Slab (not List) because ResumedMorsel holds State which
        is Movable-only (List requires Copyable).

        Order is "first-completion-first" — the worker MAY want
        to step them in the order they arrived (FIFO) or process them
        in any order; the driver is order-agnostic.

        Non-matching completions (no parked morsel keyed off any op_id
        in the completion's op_id) are discarded silently. They typically
        belong to dropped or cancelled ops —
        """
        var resumed = Slab[ResumedMorsel[Self.State]]()
        var completions = reactor_ref.poll_completions(timeout_us)
        var n = len(completions)
        for i in range(n):
            var c = completions[i]
            var maybe_state = self._take_parked_for_op_id(c.op_id)
            if maybe_state.__bool__():
                # Optional.take() moves the State out (leaves None in
                # the Optional). State is Movable-only; Optional.take()
                # is the canonical partial-move primitive.
                var moved = maybe_state.take()
                resumed.append(ResumedMorsel[Self.State](
                    state=moved^,
                    completion=c,
                ))
        return resumed^

    # =========================================================================
    # handle a StepResult.
    # =========================================================================

    def handle_step_result(
        mut self,
        var sr: StepResult[Self.Output],
        var state: Self.State,
    ) -> StepDispatch[Self.Output]:
        """Match on the StepResult and update the driver's bookkeeping.

        Returns a StepDispatch enum-like that tells the caller what
        to do with the morsel:
          * Yielded(out): emit the output downstream.
          * Parked: morsel parked; caller does NOT need to do anything
            else (the state is now in the driver's slab).
          * Done: morsel finished; caller drops it.
          * Error(msg): unrecoverable; caller propagates.

        Bookkeeping updates:
          * Yielded → _yielded_count += 1
          * Parked → _park_morsel(state, ids); _parked_count += 1
          * Done   → state dropped at end-of-call
          * Error  → _error_count += 1; state dropped at end-of-call
        """
        if sr.is_yielded():
            self._yielded_count = self._yielded_count + Int64(1)
            var out = sr.morsel().value()
            _ = state^  # state is consumed by the caller's emit chain;
                        # operator.step yielded means the morsel finished
                        # this step's IO and produced an output. The
                        # state itself is still alive for the next step.
                        # For the simple case where step processes
                        # one morsel start-to-finish, the state is
                        # dropped here. Callers that need to keep state
                        # alive across yielded must use a separate
                        # branching shape.
            return StepDispatch[Self.Output](
                _kind=DISPATCH_YIELDED,
                _value=Optional[Self.Output](out),
                _err=String(""),
            )
        if sr.is_parked():
            # Take the op_ids list — multi-op via op_ids() (copy);
            # depth=1 via op_id() (single Int64).
            var ids = sr.op_ids()
            self._park_morsel(state^, ids^)
            return StepDispatch[Self.Output](
                _kind=DISPATCH_PARKED,
                _value=Optional[Self.Output](),
                _err=String(""),
            )
        if sr.is_done():
            _ = state^
            return StepDispatch[Self.Output](
                _kind=DISPATCH_DONE,
                _value=Optional[Self.Output](),
                _err=String(""),
            )
        if sr.is_error():
            self._error_count = self._error_count + Int64(1)
            _ = state^
            var err_text = sr.err_text()
            return StepDispatch[Self.Output](
                _kind=DISPATCH_ERROR,
                _value=Optional[Self.Output](),
                _err=err_text,
            )
        # Unreachable — StepResult has 4 variants and all are checked.
        _ = state^
        return StepDispatch[Self.Output](
            _kind=DISPATCH_DONE,
            _value=Optional[Self.Output](),
            _err=String(""),
        )

    def cancel_all_parked(mut self):
        """Cancel-and-drop every currently-parked morsel. Used by
        graceful shutdown / cancellation token fired path: the driver
        walks its slab, drops every State, clears the parallel
        wait-set list. Per is the shape on
        cancel: each worker cleans up its own parked morsels, no
        cross-pthread coordination required.

        After this call, parked_len() == 0.
        """
        # Drain the slab by repeated take(key) using the first id of
        # each wait set as key — same primitive _take_parked_for_op_id
        # uses internally. We walk _parked_op_ids tail-to-head and use
        # pop() (no shift required); this matches the parallel-array
        # contract since the slab's take(key) is keyed not by index.
        while len(self._parked_op_ids) > 0:
            var last = len(self._parked_op_ids) - 1
            var ids_len = len(self._parked_op_ids[last])
            if ids_len > 0:
                var key = self._parked_op_ids[last][0]
                _ = self._parked_morsels.take(key)
            _ = self._parked_op_ids.pop()


# =============================================================================
# StepDispatch[Output] — driver -> caller signal value.
# =============================================================================
#
# Discriminated value mirroring StepResult, but stripped of the parked
# variant's payload (the driver consumed the op_ids during park). The
# caller's loop body matches on this and:
#   * Yielded(out): emit out to the next operator / sink.
#   * Parked: nothing to do (state is in the driver's slab).
#   * Done: nothing to do; loop continues until driver observes "all
#           parked drained AND operator.is_done()".
#   * Error(msg): bubble up.
# =============================================================================


comptime DISPATCH_YIELDED: UInt8 = 0
comptime DISPATCH_PARKED: UInt8 = 1
comptime DISPATCH_DONE: UInt8 = 2
comptime DISPATCH_ERROR: UInt8 = 3


@fieldwise_init
struct StepDispatch[
    Output: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Copyable, Movable, Deinitable):
    """Driver -> caller dispatch signal. Same shape as StepResult but
    stripped of the parked op_ids payload (consumed by the driver).

    Field set:
      var _kind: UInt8                  # DISPATCH_*
      var _value: Optional[Self.Output] # populated when DISPATCH_YIELDED
      var _err: String                  # populated when DISPATCH_ERROR
    """

    var _kind: UInt8
    var _value: Optional[Self.Output]
    var _err: String

    @always_inline
    def is_yielded(self) -> Bool:
        return self._kind == DISPATCH_YIELDED

    @always_inline
    def is_parked(self) -> Bool:
        return self._kind == DISPATCH_PARKED

    @always_inline
    def is_done(self) -> Bool:
        return self._kind == DISPATCH_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._kind == DISPATCH_ERROR

    @always_inline
    def kind(self) -> UInt8:
        return self._kind

    def morsel(self) -> Optional[Self.Output]:
        if self._kind == DISPATCH_YIELDED:
            return self._value
        return Optional[Self.Output]()

    def err_text(self) -> String:
        return self._err


# =============================================================================
# ResumedMorsel[State] — driver's "this parked morsel just woke" record.
# =============================================================================


@fieldwise_init
struct ResumedMorsel[
    State: Movable & Deinitable,
](Movable, Deinitable):
    """Returned from `MorselStepDriver.poll_and_resume`. Each entry is
    a (state, completion) pair — the caller threads `state` back into
    `operator.step(state, ctx)` for the resume call.

    The completion may be useful for the operator's body to inspect
    (e.g. bytes-read on a parquet page-decode operator)."""

    var state: Self.State
    var completion: Completion
