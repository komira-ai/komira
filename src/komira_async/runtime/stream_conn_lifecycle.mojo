# =============================================================================
# komira_async.runtime.stream_conn_lifecycle
# The connection-ownership lifecycle primitives for a long-lived / streaming
# suspendable frame on the per-core async runtime.
# =============================================================================
# The cheap connection-release primitive + the long-lived-frame lifecycle.
# This file touches NO live serve path. It is the SAFE-SHAPE foundation a
# streaming / notification handler builds on.
#
# ── THE PROBLEM ──────────────────────────────────────────────────────────────
# A streaming / long-lived suspendable frame parks for a multi-second lifetime
# across many idle wakes. If it PINS its leased PG connection across every idle
# wait, thousands of idle streams exhaust the bounded pool -> 503. The naive fix
# — store a borrowed `ref [pool] PgDatabase` lease across the park — is BANNED,
# because the frame is TYPE-ERASED: `ErasedFrame` bitcasts the handler SM into a
# `UInt8` blob, which ERASES the origin on any borrowed field, so the lifetime
# checker can no longer prove the borrow doesn't outlive the pool / can't enforce
# teardown order. That is the destroy-recreate trap: a field that holds a
# caller-stack pointer can outlive the caller via the pool's own teardown
# ordering, which invalidates the concept of lifetime.
#
# So the rule is OWNERSHIP, never a stored borrow. The connection-ownership
# lifecycle:
#   * ACTIVE READ BURST: the frame OWNS a moved-out connection (an
#     `Optional[Conn]` field) across its OWN read park. safe across destroy-recreate: an owned
#     value's lifetime IS the frame's; it moves WITH the SM through the
#     `ErasedFrame` bitcast (no origin to erase).
#   * IDLE WAIT (the timer / send-window / notification-ready park): the frame
#     GIVES the connection BACK to the pool (`pool.vacate(lease)`) and holds ONLY
#     a POD `StreamResumeToken` (last-seen id + cursor + the idle-wake op_id) —
#     no pointer, no origin, safe across destroy-recreate BY CONSTRUCTION (all scalar).
#   * ON WAKE: RE-ACQUIRE the connection through the pool handle reached via the
#     per-dispatch context (compiler-tracked), `pool.restore(lease, db^)` — never
#     a stored ref. The cheap-vacate pool primitive (`PgPool.vacate`/`restore`,
#     pg_pool.mojo) makes this re-acquire a pure ownership move — NO reconnect.
#
# ── WHY A MOCK IDLE-WAKE OP (decouple from the not-yet-built timer) ───────────
# The reactor has NO timer / non-I/O park primitive yet (the `TimerWheel` is
# not wired; `reactor.submit(OP_TIMER)` raises). A frame can only park on an in-flight I/O fd TODAY. So this
# POC proves the OWNERSHIP / destroy-recreate shape independently of the real timerfd, using
# `MockIdleWakeOp`: a fake reactor op that becomes ready after N polls, exactly
# like the fake-park ops in the handler tests. When a real timerfd lands,
# `MockIdleWakeOp.start`/`poll` are the seam to swap (the op_id it
# returns is already biased via `reactor.alloc_op_id`, so it parks/resumes
# through the EXISTING park/resume path with zero driver change).
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
# unsafe_from_address. The reactor is threaded per-call (never stored). Every
# field is POD or an owned value type. destroy-recreate: nothing is stored in a byte-slab;
# the resume token is all-scalar; the burst connection is an owned `Optional[T]`.
# Mojo 1.0.0b1.
# =============================================================================

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor


# =============================================================================
# deterministic timer-deadline JITTER.
# =============================================================================
# At thousands of idle streams, a timer-aligned wake SYNCHRONIZES the herd: if
# every parked stream re-parks on the SAME nominal deadline, they all fire on the
# same reactor cycle, then all re-acquire a connection from the BOUNDED pool in
# lockstep -> a thundering-herd `checkout` storm that swamps the pool (and the
# O(n) demux this batch is fixing). The mitigation is to spread each frame's
# deadline across a small JITTER BAND so the wakes — and therefore the re-acquire
# attempts — de-synchronize.
#
# The jitter is DETERMINISTIC (no runtime RNG — RNG would be non-reproducible and
# needs global/seed state we deliberately avoid): a hash of the frame's op_id
# folded into `[0, band_ns)` and ADDED to the nominal deadline. Two distinct
# op_ids land at (almost surely) distinct offsets; the same op_id always lands at
# the same offset (idempotent, testable). Because the reactor allocator hands out
# biased monotone op_ids (`OP_ID_ALLOC_BASE + k`), the raw low bits are adjacent
# across frames; we run them through the same splitmix finalizer the demux map
# uses so adjacent op_ids spread across the whole band rather than clumping.

comptime DEFAULT_JITTER_BAND_NS: Int64 = 250_000_000  # 250ms default spread band


@always_inline
def _mix_op_id_jitter(op_id: Int64) -> UInt64:
    """splitmix-style finalizer (same family as op_id_index_map._mix_op_id) so
    adjacent biased-monotone op_ids spread across the jitter band instead of
    landing in adjacent offsets."""
    var x = UInt64(op_id)
    x = (x ^ (x >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    x = (x ^ (x >> 27)) * UInt64(0x94D049BB133111EB)
    x = x ^ (x >> 31)
    return x


@always_inline
def op_id_jitter_ns(op_id: Int64, band_ns: Int64) -> Int64:
    """A DETERMINISTIC per-op_id jitter offset in `[0, band_ns)`. Same op_id +
    band always yields the same offset (idempotent); distinct op_ids spread
    across the band. `band_ns <= 0` yields 0 (jitter disabled)."""
    if band_ns <= 0:
        return Int64(0)
    return Int64(_mix_op_id_jitter(op_id) % UInt64(band_ns))


@always_inline
def jittered_deadline_ns(
    nominal_deadline_ns: Int64, op_id: Int64, band_ns: Int64
) -> Int64:
    """The nominal deadline PLUS this op_id's deterministic jitter offset. Used to
    de-synchronize a herd of timer-aligned idle re-parks so they do not all fire
    (and all re-acquire from the bounded pool) on the same reactor cycle. The
    offset is always >= 0 so jitter only ever PUSHES the deadline later, never
    earlier (a frame never wakes before its intended deadline)."""
    return nominal_deadline_ns + op_id_jitter_ns(op_id, band_ns)


# =============================================================================
# handled re-acquire-failure outcome.
# =============================================================================
# `Pool.checkout` / `PgPool.checkout` RAISES on exhaustion ("Pool exhausted: all
# N resources are in use"). On a timer-aligned herd, thousands of idle streams
# wake together and re-acquire a connection in lockstep; the pool is bounded, so
# the losers' `checkout` RAISES. If that raise propagated uncaught through the
# resume path it would convert an admission 503 into an UNCAUGHT mid-stream throw
# that tears down a live streaming frame. The graceful shape is to CATCH the
# exhaustion and RE-PARK-WITH-JITTER (backpressure): the frame goes back to sleep
# on a fresh jittered deadline and retries the re-acquire on the next wake,
# instead of dying. `try_reacquire_or_backpressure` (below) expresses that arm.

comptime REACQUIRE_OK: UInt8 = 0  # got a lease this attempt
comptime REACQUIRE_BACKPRESSURE: UInt8 = 1  # pool exhausted -> re-parked with jitter


@fieldwise_init
struct ReacquireOutcome(Copyable, Movable, Deinitable):
    """The result of a re-acquire attempt under pool pressure. ALL POD.

      * `status`        — REACQUIRE_OK (got `lease`) or REACQUIRE_BACKPRESSURE
                          (pool exhausted; the frame was re-parked on a fresh
                          jittered idle deadline carried in `retry_op_id`).
      * `lease`         — the acquired lease when status == REACQUIRE_OK; -1
                          otherwise.
      * `retry_op_id`   — the biased reactor op_id the frame is now re-parked on
                          when status == REACQUIRE_BACKPRESSURE; 0 otherwise.
    """

    var status: UInt8
    var lease: Int
    var retry_op_id: Int64

    @always_inline
    def is_ok(self) -> Bool:
        return self.status == REACQUIRE_OK

    @always_inline
    def is_backpressure(self) -> Bool:
        return self.status == REACQUIRE_BACKPRESSURE

    @staticmethod
    def ok(lease: Int) -> ReacquireOutcome:
        return ReacquireOutcome(
            status=REACQUIRE_OK, lease=lease, retry_op_id=Int64(0)
        )

    @staticmethod
    def backpressure(retry_op_id: Int64) -> ReacquireOutcome:
        return ReacquireOutcome(
            status=REACQUIRE_BACKPRESSURE, lease=-1, retry_op_id=retry_op_id
        )


def backpressure_repark[
    S: WakerSink & Movable & Deinitable,
](
    mut reactor: Reactor[S],
    nominal_deadline_ns: Int64,
    frame_salt: Int64,
    band_ns: Int64,
) raises -> ReacquireOutcome:
    """The HANDLED re-acquire-failure arm.

    Called when a streaming frame's re-acquire `checkout` RAISED on pool
    exhaustion. Instead of letting that raise tear down the live frame, the
    frame re-parks on a FRESH JITTERED idle deadline (graceful backpressure) and
    retries on the next wake. Registers a new jittered timer with the reactor and
    returns a BACKPRESSURE `ReacquireOutcome` carrying the new op_id to park on.

    The jitter (deterministic, per-`frame_salt`) is load-bearing here: a
    timer-aligned herd that all hit pool exhaustion together would otherwise all
    re-park on the SAME retry deadline and re-collide on the next cycle — a
    livelock. Spreading the retry deadlines de-synchronizes the herd so the pool
    drains in waves."""
    var jittered = jittered_deadline_ns(nominal_deadline_ns, frame_salt, band_ns)
    var retry_op_id = reactor.register_timer(jittered)
    return ReacquireOutcome.backpressure(retry_op_id)


# =============================================================================
# StreamResumeToken — the POD-across-the-idle-park resume state.
# =============================================================================
# The ONLY state a streaming frame carries across an IDLE park (when it does NOT
# own the connection). It is ALL SCALAR — no pointer, no origin, no heap-owning
# field — so it is safe across destroy-recreate BY CONSTRUCTION: even after the `ErasedFrame`
# bitcast erases origins, there is no origin here to lose, and no inner heap
# buffer whose liveness the compiler must track. A botched erasure cannot
# corrupt it (there is nothing to dangle). This is the structural contrast with
# the BANNED stored-borrow shape (a `ref [pool] PgDatabase` field), which the
# erasure WOULD turn into a dangling untracked pointer.
#
# Fields model the canonical streaming resume cursor (a polling notification /
# SSE stream): the highest id already delivered, an opaque page cursor, and the
# reactor op_id the frame is currently parked on for its idle wake.


@fieldwise_init
struct StreamResumeToken(Copyable, Movable, Deinitable):
    """The POD resume state a streaming frame holds across an IDLE park (the
    connection is BACK in the pool during the idle). All scalar — safe across destroy-recreate by
    construction; survives the `ErasedFrame` bitcast with no origin to erase and
    no heap field to dangle.

    Copyable (it is pure POD; copying it is a register/struct copy, no ownership
    transfer) so it can be read out + stashed freely.

      * `last_seen_id`  — the highest stream id already delivered to the client
                          (the watermark the next read filters above).
      * `cursor`        — an opaque page cursor (e.g. a created_at micros bound)
                          the next read resumes from. 0 if none.
      * `idle_wake_op_id` — the reactor op_id the frame is currently parked on
                          for its idle wake (a `MockIdleWakeOp` op_id today; a
                          timerfd op_id once 3 lands). 0 if not
                          currently idle-parked.
    """

    var last_seen_id: Int64
    var cursor: Int64
    var idle_wake_op_id: Int64

    @staticmethod
    def initial() -> StreamResumeToken:
        """A fresh token: nothing delivered yet, no cursor, not idle-parked."""
        return StreamResumeToken(
            last_seen_id=Int64(0),
            cursor=Int64(0),
            idle_wake_op_id=Int64(0),
        )

    def advance(mut self, new_last_seen_id: Int64, new_cursor: Int64):
        """Record progress after a burst delivered rows: bump the watermark +
        page cursor. Clears the idle-wake op_id (set again when the next idle
        park starts)."""
        if new_last_seen_id > self.last_seen_id:
            self.last_seen_id = new_last_seen_id
        self.cursor = new_cursor
        self.idle_wake_op_id = Int64(0)


# =============================================================================
# MockIdleWakeOp — the fake timer/idle park op (poll-counter readiness).
# =============================================================================
# Stands in for the not-yet-built reactor timer primitive.
# It models the IDLE wait the streaming frame parks on while its connection is
# back in the pool: `start` allocates a biased reactor op_id (no fd registration,
# exactly like the PARK handler in the handler tests) and returns it to park on;
# `poll` becomes READY after `polls_until_ready` calls. The point is to drive the
# vacate-before-idle-park + POD-across-park + restore-on-wake lifecycle to a
# proof WITHOUT a real timerfd — the ownership / destroy-recreate shape is independent of how
# the idle wake actually fires.
#
# This is a pure poll-counter: it does NOT register an fd, so the reactor needs
# no real readiness machinery (cross-platform, BACKEND_MOCK-friendly). The op_id
# is biased (>= OP_ID_ALLOC_BASE) so a driver/seam demux treats it as a
# dynamically-registered op, identical to a real timerfd op_id.

comptime IDLE_PENDING: UInt8 = 0
comptime IDLE_READY: UInt8 = 1


struct MockIdleWakeOp(Copyable, Movable, Deinitable):
    """A fake idle/timer park op that becomes ready after N polls. ALL POD —
    no fd, no heap, no pointer; safe across destroy-recreate and trivially erasure-safe. Replace
    `start`/`poll` with the real timerfd registration when 3
    lands; the op_id contract (biased, parked/resumed through the existing path)
    is unchanged."""

    var _op_id: Int64
    var _polls_remaining: Int
    var _state: UInt8

    def __init__(out self, polls_until_ready: Int):
        self._op_id = Int64(0)
        self._polls_remaining = polls_until_ready
        self._state = IDLE_PENDING

    @always_inline
    def op_id(self) -> Int64:
        return self._op_id

    @always_inline
    def is_pending(self) -> Bool:
        return self._state == IDLE_PENDING

    @always_inline
    def is_ready(self) -> Bool:
        return self._state == IDLE_READY

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) -> Int64:
        """Begin the idle wait: allocate a biased reactor op_id to park on. No fd
        registration (a real timerfd would register here). If
        `polls_until_ready == 0` the op is immediately ready (a zero-delay idle
        wake — the frame re-bursts at once). Returns the op_id to park on."""
        self._op_id = reactor.alloc_op_id()
        if self._polls_remaining <= 0:
            self._state = IDLE_READY
        return self._op_id

    def poll(mut self) -> UInt8:
        """The driver calls this on a wake. Decrement the poll counter; become
        READY once it reaches 0. Returns the new state. (A real timerfd's poll
        would re-read the timer fd and report READY iff it fired)."""
        if self._state == IDLE_READY:
            return self._state
        self._polls_remaining -= 1
        if self._polls_remaining <= 0:
            self._state = IDLE_READY
        return self._state


# =============================================================================
# RealTimerIdleWakeOp — the REAL reactor-timer-backed idle park op.
# =============================================================================
# 3. The production swap-in for
# MockIdleWakeOp: instead of a poll-counter, `start` registers a REAL deadline
# with the reactor (`reactor.register_timer(deadline_ns)`) and returns the
# biased op_id to PARK on. The deadline fires as an ordinary fd-readiness
# completion (Linux timerfd / macOS EVFILT_TIMER) routed through the SAME demux
# as a PG read — so the parked frame resumes via the existing driver path with
# ZERO driver change.
#
# THE FULL PROVABLE LOOP this enables (vs MockIdleWakeOp's cross-platform unit
# POC): own-during-burst -> release the conn to the pool -> register_timer +
# park (holding only the POD StreamResumeToken) -> deadline fires -> resume ->
# re-acquire -> re-burst. `MockIdleWakeOp` stays for the BACKEND_MOCK /
# cross-platform unit POC (no kernel fd); `RealTimerIdleWakeOp` is the
# BACKEND_EPOLL (Linux) / BACKEND_KQUEUE (macOS) production path.
#
# OWNERSHIP / destroy-recreate (identical contract to MockIdleWakeOp): ALL POD — the only
# state is the biased op_id (Int64) + a deadline (Int64) + a state byte. No fd
# is stored here (the reactor OWNS the timerfd, keyed on the op_id, and closes
# it on deregister); no heap, no pointer, no origin to erase. The streaming
# frame carries only `op_id()` (a scalar) in its POD StreamResumeToken across
# the park, so the ErasedFrame bitcast has nothing to corrupt.
#
# Encapsulation: `start` takes the reactor by `mut reactor` per-call (never
# stored); the reactor is reached through the per-dispatch context, exactly as
# the SuspendableHandler.step contract threads it. No UnsafePointer, no wildcard
# origin, no stored reactor reference.


struct RealTimerIdleWakeOp(Copyable, Movable, Deinitable):
    """A reactor-timer-backed idle/timer park op. Registers a real one-shot
    deadline with the reactor (timerfd on Linux / EVFILT_TIMER on macOS) and
    parks on the biased op_id it returns. ALL POD — the reactor owns the kernel
    fd (keyed on the op_id); this op holds only scalars, so it is safe across destroy-recreate and
    erasure-safe. The production swap-in for MockIdleWakeOp."""

    var _op_id: Int64
    var _deadline_ns: Int64
    var _state: UInt8

    def __init__(out self, deadline_ns: Int64):
        self._op_id = Int64(0)
        self._deadline_ns = deadline_ns
        self._state = IDLE_PENDING

    @always_inline
    def op_id(self) -> Int64:
        return self._op_id

    @always_inline
    def deadline_ns(self) -> Int64:
        return self._deadline_ns

    @always_inline
    def is_pending(self) -> Bool:
        return self._state == IDLE_PENDING

    @always_inline
    def is_ready(self) -> Bool:
        return self._state == IDLE_READY

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Begin the idle wait: register a REAL deadline timer with the reactor
        and return the biased op_id to park on. The reactor allocates +
        arms the timerfd / EVFILT_TIMER; when the deadline elapses the op_id
        fires as a normal completion. Returns the op_id to park on."""
        self._op_id = reactor.register_timer(self._deadline_ns)
        return self._op_id

    def start_jittered[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, mut reactor: Reactor[S], frame_salt: Int64, band_ns: Int64
    ) raises -> Int64:
        """Begin the idle wait on a JITTERED deadline. The
        nominal `_deadline_ns` is spread by a deterministic per-frame offset in
        `[0, band_ns)` so a herd of timer-aligned re-parks does not all fire (and
        re-acquire from the bounded pool) on the same reactor cycle.

        `frame_salt` is a CALLER-STABLE per-frame key (e.g. the frame's
        request_id, or the prior idle op_id) — the registration happens BEFORE the
        new op_id exists, so we cannot key the jitter on the op_id we are about to
        receive. Keying on a stable per-frame salt gives the same de-synchronizing
        spread (distinct frames -> distinct offsets) while staying single-
        registration and fully deterministic. The jittered deadline is recorded in
        `_deadline_ns` (so introspection reflects what was armed). The offset is
        always >= 0, so jitter only ever pushes the deadline LATER, never earlier."""
        var jittered = jittered_deadline_ns(
            self._deadline_ns, frame_salt, band_ns
        )
        self._deadline_ns = jittered
        self._op_id = reactor.register_timer(jittered)
        return self._op_id

    def mark_ready(mut self):
        """The driver calls this when the parked op_id's deadline completion
        has fired (reactor.is_ready(op_id) is True, or the completion routed to
        this frame). Transitions to READY so the frame re-bursts. (Unlike the
        MockIdleWakeOp poll-counter, readiness here is driven by the REAL kernel
        deadline via the reactor's completion demux — this method just records
        that the driver observed it)."""
        self._state = IDLE_READY

    def poll_reactor[
        S: WakerSink & Movable & Deinitable,
    ](mut self, reactor: Reactor[S]) -> UInt8:
        """Convenience for the single-frame test/driver loop: ask the reactor
        whether this op's deadline completion has fired (is_ready on the biased
        op_id) and transition to READY if so. Returns the new state. The
        production multiplexing driver routes the completion to the frame via
        the op_id demux instead of polling; this is the direct-poll shape for a
        single parked frame."""
        if self._state == IDLE_READY:
            return self._state
        if reactor.is_ready(self._op_id):
            self._state = IDLE_READY
        return self._state
