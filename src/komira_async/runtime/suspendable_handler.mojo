# =============================================================================
# komira_async.runtime.suspendable_handler —
# Hand-rolled suspendable-handler ABI (one path) + poll-shaped PG read.
# =============================================================================
# The "enum-state-machine handler ABI" for a per-core async server. It does
# NOT change the synchronous `RequestDispatcher.dispatch` contract for any
# existing handler. A handler written as a hand-rolled state machine SUSPENDS
# on its database read and is resumed by a multiplexing driver, so one worker
# can hold >1 request in flight.
#
# ── WHY A HAND-ROLLED STATE MACHINE ──────────────────────────────────────────
# Mojo 1.0.0b1 has NO compiler async/await. A handler that wants to park its
# Postgres round-trip on the per-worker reactor and let the worker serve another
# request meanwhile cannot be expressed as a coroutine. It must be an explicit
# enum of steps + a struct that OWNS the live working set across the suspension
# + a `step(mut self, mut reactor) -> HandlerStepResult` method that resumes at
# the saved step. The primitives this builds on already exist
# (`StepResult` shape, `Reactor.submit` / `poll_completions`); this file adds
# the handler-specific ABI shape on top.
#
# ── THE ABI ──────────────────────────────────────────────────────────────────
#   1. HANDLER_STEP_* — the per-handler step enum (UInt8 sentinels; Mojo has no
#      payloaded enum). Each handler defines its own ordered set of steps.
#   2. HandlerStepResult — the discriminated park/done value the step() method
#      returns. Modeled on `komira_async.runtime.step_result.StepResult` but
#      carrying an `HttpResponse` output (Movable, NOT Copyable) on Ready, so it
#      cannot reuse StepResult[T] (which requires T: ImplicitlyCopyable).
#   3. SuspendableHandler (duck-typed parametric, NOT a trait) — any handler
#      state-machine struct that exposes `step(mut self, mut reactor) ->
#      HandlerStepResult`. We use a concrete-struct + parametric-driver shape
#      (same reason morsel_step_driver does: Mojo 1.0.0b1 traits can't carry the
#      nested-alias + Movable-output cleanly).
#   4. SuspendedFrame[H] — refinement (A): the MIGRATION-READY owned frame. A
#      single heap allocation that OWNS the handler state machine + its result
#      channel, with NO borrowed/wildcard refs into the originating worker's
#      stack or reactor. Generalizes LocalSpawner's `_SpawnedTaskHeader` owned-
#      move shape to a SUSPENDED (not run-to-completion) frame. The frame stays
#      PINNED to its worker (no migration, so the destroy-recreate hazard
#      never enters), but the OWNERSHIP shape is migration-ready so a future
#      cross-core step needs no rewrite.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# ZERO UnsafePointer in any public signature. ZERO wildcard origin. ZERO
# unsafe_from_address. The reactor is threaded per-call as `mut reactor:
# Reactor[S]` (never stored as a field — no borrow held across the worker loop).
# The handler state machine owns only POD + heap-owning value types (Strings,
# the PollPgRead op which holds only an op_id + a result buffer). destroy-recreate: nothing
# is stored in a byte-slab.
#
# ── PACKAGE LAYERING (avoid the komira_http ↔ komira_async cycle) ──────────
# `komira_http` ALREADY depends on `komira_async` (the transport drives the
# reactor). So this ABI — which lives in `komira_async` — MUST NOT import
# `komira_http` (that would be a dependency cycle). The fix: `HandlerStepResult`
# is PARAMETRIC over the response output type `Resp: Movable` rather than baking
# in `HttpResponse`. The concrete handler state machine that produces an
# `HttpResponse` lives in a package that depends on BOTH `komira_http` and
# `komira_async`. So the reusable contract stays in the substrate; only the
# HTTP-specific instantiation lives upstack.
# =============================================================================

from std.memory import OwnedPointer

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import Completion
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.parked_morsel_slab import ParkedMorselSlab

from komira_collections.slab import Slab


# =============================================================================
# HandlerStepResult[Resp] — the discriminated park/done/error value.
# =============================================================================
# Mirrors `step_result.StepResult` (STEP_YIELDED/PARKED/DONE/ERR) but:
#   * carries the response `Resp` (Movable, possibly NOT Copyable, e.g.
#     HttpResponse) on the DONE variant, so it cannot reuse StepResult[T]
#     (StepResult requires the output to be ImplicitlyCopyable). The DONE value
#     is moved OUT via `take_response()`.
#   * a handler step never "yields" a stream of values — it produces exactly one
#     terminal response — so there is no YIELDED variant; the variants are
#     PARKED / DONE / ERR.
#   * `Resp` is a type PARAMETER (not `HttpResponse` directly) so this lives in
#     `komira_async` without a `komira_http` dependency (see PACKAGE LAYERING
#     above). The handler SM instantiates `HandlerStepResult[HttpResponse]`.
#
# The PARKED variant carries the op_id the handler is awaiting (the reactor
# op_id its poll-shaped op registered). The driver keys the parked frame off
# this op_id and resumes the frame when a Completion with that op_id arrives.

comptime HANDLER_PARKED: UInt8 = 0  # awaiting a reactor op_id; carries op_id
comptime HANDLER_DONE: UInt8 = 1  # terminal; carries the response
comptime HANDLER_ERR: UInt8 = 2  # unrecoverable; carries an error String
# RESERVED (streaming-readiness — lock the shape now, implement later):
# the handler produced ONE chunk of a streaming response AND stayed resumable.
# It carries BOTH a chunk (a SECOND payload, parallel to the DONE response —
# moved out via `take_chunk()`) AND a resume op_id (the GENERIC biased op_id the
# frame re-parks on until the next stream event — a PG-read completion, a timer
# tick, or a socket-writable readiness for backpressure; the one arm serves all
# three). The EMIT machinery (the chunk write-back + the re-park-and-resume loop)
# is NOT implemented yet — this sentinel + the ctor + `take_chunk` RESERVE the
# 4th discriminant so a future EMIT slots into the driver's exhaustive switch as
# a 4th arm, never falling through an `else: deliver` that would silently
# retire-and-drop a streaming frame on its first chunk.
comptime HANDLER_EMIT: UInt8 = 3  # RESERVED: one stream chunk + stay resumable


@fieldwise_init
struct HandlerStepResult[
    Resp: Movable & Deinitable,
](Movable, Deinitable):
    """The value a suspendable handler's `step()` returns. Discriminated:
      * PARKED(op_id): the handler kicked off a non-blocking I/O op and is
        suspended awaiting the reactor op_id. The driver parks the frame and
        resumes it when `op_id` completes.
      * DONE(Resp): the handler finished; the response is moved out via
        `take_response()`.
      * ERR(String): unrecoverable error; the driver maps it to a 500.
      * EMIT(chunk, op_id) — RESERVED (streaming-readiness): the handler
        produced ONE chunk of a streaming response AND stayed resumable. Carries
        BOTH a `Resp`-shaped chunk (a stream chunk is a partial response — moved
        out via `take_chunk()`, a SECOND payload parallel to the DONE response)
        AND a GENERIC biased resume op_id (the frame re-parks on it until the
        next stream event — PG-read / timer tick / socket-writable for
        backpressure; the one arm serves all three). The EMIT machinery is NOT
        implemented yet; this variant RESERVES the 4th discriminant so a future
        EMIT slots into the driver's exhaustive switch (never silently
        retire-and-dropped). See HANDLER_EMIT above.

    Movable, NOT necessarily Copyable: the DONE/EMIT variant owns a `Resp` (e.g.
    HttpResponse, itself Movable-not-Copyable). Single-ownership; the driver
    moves it. `Resp` is a parameter so the substrate carries no HTTP dependency.
    """

    var _kind: UInt8
    var _op_id: Int64
    var _response: Optional[Self.Resp]
    var _err: String
    # RESERVED: the EMIT chunk — a SECOND payload parallel to `_response`. A
    # stream chunk is a `Resp`-shaped partial response, moved out via
    # `take_chunk()`. None for PARKED / DONE / ERR.
    var _chunk: Optional[Self.Resp]

    @staticmethod
    def parked(op_id: Int64) -> HandlerStepResult[Self.Resp]:
        """The handler suspended awaiting reactor `op_id`."""
        return HandlerStepResult[Self.Resp](
            _kind=HANDLER_PARKED,
            _op_id=op_id,
            _response=Optional[Self.Resp](),
            _err=String(""),
            _chunk=Optional[Self.Resp](),
        )

    @staticmethod
    def done(var response: Self.Resp) -> HandlerStepResult[Self.Resp]:
        """The handler produced its terminal response."""
        return HandlerStepResult[Self.Resp](
            _kind=HANDLER_DONE,
            _op_id=Int64(0),
            _response=Optional[Self.Resp](response^),
            _err=String(""),
            _chunk=Optional[Self.Resp](),
        )

    @staticmethod
    def error(err: String) -> HandlerStepResult[Self.Resp]:
        """The handler hit an unrecoverable error. Carries no response (the
        driver maps ERR to a 500 in the response domain it owns)."""
        return HandlerStepResult[Self.Resp](
            _kind=HANDLER_ERR,
            _op_id=Int64(0),
            _response=Optional[Self.Resp](),
            _err=err,
            _chunk=Optional[Self.Resp](),
        )

    @staticmethod
    def emit(var chunk: Self.Resp, op_id: Int64) -> HandlerStepResult[Self.Resp]:
        """RESERVED (streaming-readiness — NOT yet driven by any live handler):
        the handler produced one stream chunk and stayed resumable, re-parking
        on `op_id`. The chunk is moved out via `take_chunk()`; the frame resumes
        when `op_id` completes. The EMIT write-back + re-park machinery is
        deferred — this ctor exists so the discriminant is constructible the
        moment EMIT is implemented, and so the driver's exhaustive switch has a
        4th arm to test against today."""
        return HandlerStepResult[Self.Resp](
            _kind=HANDLER_EMIT,
            _op_id=op_id,
            _response=Optional[Self.Resp](),
            _err=String(""),
            _chunk=Optional[Self.Resp](chunk^),
        )

    @always_inline
    def is_parked(self) -> Bool:
        return self._kind == HANDLER_PARKED

    @always_inline
    def is_done(self) -> Bool:
        return self._kind == HANDLER_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._kind == HANDLER_ERR

    @always_inline
    def is_emit(self) -> Bool:
        """RESERVED: True iff this is the EMIT (one chunk + stay resumable)
        variant. No live handler returns EMIT yet; the predicate exists so the
        driver's exhaustive switch can route it (today: to the safe ERR arm)."""
        return self._kind == HANDLER_EMIT

    @always_inline
    def op_id(self) -> Int64:
        """The awaited reactor op_id when PARKED (or the resume op_id when
        EMIT); 0 otherwise."""
        return self._op_id

    def take_response(mut self) -> Self.Resp:
        """Move the terminal response out of a DONE result. Caller MUST check
        `is_done()` first (an ERR/PARKED/EMIT result has no response; calling
        this on one is a programming error — the Optional.take() will abort).
        The driver always checks is_done() before calling this."""
        return self._response.take()

    def take_chunk(mut self) -> Self.Resp:
        """RESERVED (streaming-readiness): move the EMIT stream chunk out — the
        SECOND payload, parallel to `take_response`. Caller MUST check
        `is_emit()` first (a non-EMIT result has no chunk; the Optional.take()
        aborts otherwise). Unused until the EMIT machinery lands."""
        return self._chunk.take()

    def err_text(self) -> String:
        return self._err


# =============================================================================
# PollPgRead — the poll-shaped PG read op (one read path).
# =============================================================================
# The minimal poll-shaped op: it models ONE PG read round-trip
# as a non-blocking op over a real reactor fd, exposing the
# start → poll → take_result lifecycle instead of a blocking `wait()`.
#
# WHY THIS SHAPE (and the honest scope limit):
# The production PG read (`PgDatabase.query` → `PgConnection.query_prepared`)
# is a MULTI-MESSAGE blocking loop: it sends Bind/Execute, then loops
# `_read_one_message` → `_recv_some_into_rbuf` → `PgReactorStream.recv_some`,
# and recv_some PARKS THE WORKER THREAD via `reactor.poll_completions(-1)`
# (in the PG TLS transport). That deep blocking park is the exact
# serialization point.
# Turning the FULL pgwire loop into a frame-resumable state machine (one that
# survives across every recv park, carrying the partial read buffer + wire
# parse cursor in the frame) is a much larger step, not this module's scope.
#
# PollPgRead models the I/O at the granularity the ABI needs to
# prove: a request submits a non-blocking read on its connection fd
# (`start(reactor)`), the driver polls (`poll(reactor, completion)`), and when
# the fd is readable the op drains the bytes (`take_result`). This is the
# poll-shaped CONTRACT the production op must expose; the production op's body
# is "drive the pgwire message loop one non-blocking step at a time and return
# PENDING when recv would block" instead of "read one byte". The contract — and
# the multiplexing it enables — is identical.

comptime PG_READ_PENDING: UInt8 = 0
comptime PG_READ_READY: UInt8 = 1
comptime PG_READ_ERR: UInt8 = 2


struct PollPgRead(Movable, Deinitable):
    """A poll-shaped single PG read over a reactor-registered fd. Owns:
      * `_fd`: the connection fd (read end of the PG socket; here a socketpair
        fd in the tests). Owned by the caller's connection, not by this op
        — this op never closes it. Held by value (Int32) — no pointer.
      * `_op_id`: the reactor op_id this read is registered under (0 until
        `start`).
      * `_state`: PG_READ_PENDING / PG_READ_READY / PG_READ_ERR.
      * `_result`: the bytes drained once ready (the "row data").

    Lifecycle:
      start(reactor)        — submit a non-blocking read; on EWOULDBLOCK,
                              register the fd + return the op_id to park on.
                              On an immediate-ready fast path, drain + mark
                              READY (no park).
      poll(reactor)         — non-blocking: re-attempt the read; on success
                              drain + mark READY + deregister; on EWOULDBLOCK
                              stay PENDING.
      take_result()         — move the drained bytes out (caller checks
                              is_ready()).

    ENCAPSULATION: no UnsafePointer in any signature; the fd is a plain Int32;
    the reactor is threaded per-call. destroy-recreate: `_result` is a plain List[UInt8]
    field on a stack/heap value, never in a byte-slab.
    """

    var _fd: Int32
    var _op_id: Int64
    var _state: UInt8
    var _result: List[UInt8]
    # The number of bytes this read wants before it is "complete" (models a
    # full row-set: a test primes exactly this many bytes on the fd in
    # one or more chunks, so a read that gets a partial chunk stays PENDING).
    var _want_bytes: Int

    def __init__(out self, fd: Int32, want_bytes: Int):
        self._fd = fd
        self._op_id = Int64(0)
        self._state = PG_READ_PENDING
        self._result = List[UInt8]()
        self._want_bytes = want_bytes

    @always_inline
    def is_pending(self) -> Bool:
        return self._state == PG_READ_PENDING

    @always_inline
    def is_ready(self) -> Bool:
        return self._state == PG_READ_READY

    @always_inline
    def is_error(self) -> Bool:
        return self._state == PG_READ_ERR

    @always_inline
    def op_id(self) -> Int64:
        return self._op_id

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Kick off the read. Allocates a reactor op_id, registers the fd for
        read-readiness, and attempts one non-blocking drain. Returns the op_id
        to park on (the driver keys the frame off it). If enough bytes were
        already buffered (immediate-ready fast path), `_state` is READY and the
        registration is removed before returning."""
        self._op_id = reactor.alloc_op_id()
        reactor.register_read(self._fd, self._op_id, UInt16(0))
        # Attempt an immediate non-blocking drain (the fast path — bytes may
        # already be on the socket).
        self._drain_nonblocking()
        if self._state == PG_READ_READY:
            reactor.deregister(self._op_id)
        return self._op_id

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> UInt8:
        """The driver calls this when a Completion for `_op_id` arrives. Re-
        attempt the non-blocking drain; if the full row-set is in, mark READY +
        deregister. Otherwise stay PENDING (the read was a partial chunk; the
        driver re-parks on the SAME op_id — the fd registration is still live).
        Returns the new state."""
        if self._state != PG_READ_PENDING:
            return self._state
        self._drain_nonblocking()
        if self._state == PG_READ_READY:
            reactor.deregister(self._op_id)
        return self._state

    def _drain_nonblocking(mut self):
        """Non-blocking recv loop on `_fd`: append whatever bytes are available
        (MSG_DONTWAIT), stop on EWOULDBLOCK. Marks READY once `_want_bytes` have
        accumulated; PENDING otherwise; ERR on a hard recv error / peer close
        before the full row-set.

        SAFETY: the scratch buffer is a stack-local InlineArray owned by this
        frame; the recv FFI writes into it via its `.unsafe_ptr()` and does not
        retain the pointer. No pointer crosses any module boundary."""
        from std.ffi import external_call

        # MSG_DONTWAIT = 0x40 on Linux: a non-blocking recv regardless of the
        # socket's blocking mode (a socketpair is blocking by default).
        var msg_dontwait: Int32 = Int32(0x40)
        var guard = 0
        while len(self._result) < self._want_bytes and guard < 1_000_000:
            var scratch = Array[UInt8, 4096](fill=UInt8(0))
            var want = self._want_bytes - len(self._result)
            if want > 4096:
                want = 4096
            var got = external_call["recv", Int](
                self._fd, scratch.unsafe_ptr(), UInt(want), msg_dontwait,
            )
            if got > 0:
                for i in range(Int(got)):
                    self._result.append(scratch[i])
            elif got == 0:
                # Peer closed before the full row-set arrived.
                self._state = PG_READ_ERR
                return
            else:
                # got < 0: EWOULDBLOCK (no more bytes right now) — stay PENDING
                # and return so the driver can run another frame. We do NOT
                # distinguish EAGAIN from a hard error here; the
                # belt-and-suspenders guard + the test's clean primes keep this
                # path EWOULDBLOCK-only.
                self._state = PG_READ_PENDING
                return
            guard += 1
        if len(self._result) >= self._want_bytes:
            self._state = PG_READ_READY

    def take_result(mut self) -> List[UInt8]:
        """Move the drained row-set bytes out. Caller checks is_ready()."""
        var out = self._result^
        self._result = List[UInt8]()
        return out^


# =============================================================================
# SuspendableHandler[Resp] — the trait handlers conform to.
# =============================================================================
# Cloning a concrete frame + driver pair per handler is the
# arity-sibling-clone smell. The frame + driver are PARAMETRIC over a handler
# that conforms to this trait, so each handler is JUST a state-machine struct
# + an `impl SuspendableHandler` — no frame/driver clone.
#
# The trait is parametric over the response type `Resp` (the substrate carries
# no `komira_http` dependency — see PACKAGE LAYERING in the header). A handler
# that produces an `HttpResponse` conforms to `SuspendableHandler[HttpResponse]`.
#
# Mojo 1.0.0b1 trait shape (mirrors RequestDispatcher / Runtime): the single
# method `step` is PARAMETRIC over the reactor sink `S` (the per-call reactor
# borrow), and the associated `Resp` is a trait type PARAMETER (not an
# associated alias — Mojo 1.0.0b1 can't carry a Movable-output associated alias
# cleanly across the parametric driver). A conformer implements:
#
#   struct MyHandlerSM(Movable, Deinitable,
#                      SuspendableHandler[HttpResponse]):
#       fn step[S: WakerSink & Movable & Deinitable](
#           mut self, mut reactor: Reactor[S],
#       ) raises -> HandlerStepResult[HttpResponse]: ...


trait SuspendableHandler(Movable, Deinitable):
    """The contract a suspendable handler state machine conforms to. `step`
    resumes the handler at its saved step and runs until it must park (returns
    PARKED(op_id)) or finishes (returns DONE(response) / ERR(msg)). The reactor
    is threaded per-call (never stored) so the handler holds no borrow across
    the worker loop and stays migration-ready (the cross-core property).

    The output type is an ASSOCIATED alias `Resp` (NOT a trait parameter — Mojo
    1.0.0b1 rejects parameterized trait declarations; same associated-type shape
    as `Runtime.Sink`) so the substrate carries no HTTP dependency: the HTTP
    handlers declare `comptime Resp = HttpResponse`. Downstream generic code
    reaches it as `H.Resp` / `Self.H.Resp`."""

    comptime Resp: Movable & Deinitable

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Self.Resp]:
        ...


# =============================================================================
# HANDLER_OP_ID_BIAS — the demux-disjointness threshold (load-bearing).
# =============================================================================
# THE OP_ID DEMUX correctness hazard (the genuinely new Stage-3 piece): on the
# HttpServer, `Completion.op_id` is a SHARED Int64 namespace that mixes
#   * fd-cookies — the listener fd + each long-lived conn registration use
#     `UInt64(fd)` as the kernel cookie (reactor.register_long_lived), so the
#     completion's op_id IS the fd (small int, >=3, grows with conn count).
#   * dynamically-allocated op_ids — a handler's awaited PG read registers its
#     fd under `reactor.alloc_op_id()`.
# Without intervention these two sub-spaces OVERLAP: after a handful of
# `register_read`s the monotone counter passes through live conn fd values, so
# handler op_id 5 would be indistinguishable from conn fd 5 at the demux, and
# the reactor would alias two distinct fds under the same kernel cookie — a
# mis-route sends a conn-read completion into a parked handler frame's step()
# (corrupting the state machine) or a handler-resume completion into the conn
# read path (reading PG bytes as an HTTP request).
#
# FIX (at the SOURCE — `Reactor.alloc_op_id`): every dynamically-allocated
# op_id is BIASED by `OP_ID_ALLOC_BASE` (== this constant, 2^40) so it is
# structurally ABOVE any possible fd (RLIMIT_NOFILE is hard-capped far under
# 2^40). A completion op_id `>= HANDLER_OP_ID_BIAS` is therefore UNAMBIGUOUSLY a
# dynamically-registered op (here: a parked handler frame's awaited read); one
# BELOW it is UNAMBIGUOUSLY a listener/conn fd-cookie. Because the bias is
# applied at allocation, the handler's PgQueryOp/PollPgRead is UNCHANGED (it
# still calls `alloc_op_id()`; the returned value is already biased), and the
# driver keys + matches parked frames on the raw (already-biased) op_id — no
# translation arithmetic. This constant is the DEMUX PREDICATE threshold; it
# MUST equal `reactor.OP_ID_ALLOC_BASE`.
comptime HANDLER_OP_ID_BIAS: Int64 = Int64(1) << 40


# =============================================================================
# DeliveredResponse[Resp] — a finished request's tagged response.
# =============================================================================


struct DeliveredResponse[Resp: Movable & Deinitable](
    Movable, Deinitable
):
    """A finished request's response, tagged with its request id (its conn fd
    in the server seam) so the caller can route the response back to the RIGHT
    connection. `Resp` is parametric so the substrate carries no HTTP
    dependency."""

    # `response` is a public field: tests read `dr.response.status` directly,
    # and the server seam moves the whole `DeliveredResponse` out of the
    # delivered Slab via `Slab.take_at` into a fully-owned local, then moves
    # `local.response^` out of THAT dead local (a whole-value destructure, not a
    # partial-move out of a borrowed `self` — pointer-rule-safe). So no move-out
    # method is needed on the borrowed struct.
    var request_id: Int64
    var response: Self.Resp

    def __init__(out self, request_id: Int64, var response: Self.Resp):
        self.request_id = request_id
        self.response = response^


# =============================================================================
# SuspendedFrame[Resp, H] — the migration-ready owned suspended frame.
# =============================================================================
# PARAMETRIC over the
# handler `H: SuspendableHandler[Resp]`. A single heap allocation that OWNS the
# handler state machine via OwnedPointer (heap-stable address), the reactor
# op_id it is currently parked on, and a request id (the conn fd in the server
# seam — so the resumed handler writes back to the right connection).
#
# Migration-ready: the SM is fully OWNED by the frame (moved in,
# no borrowed ref into the originating worker's stack); NO field holds a
# wildcard origin or a reactor pointer (the reactor is threaded into `step()`
# per-call); the frame is heap-stable so the op_id -> frame mapping stays valid
# as the owning container grows. A future cross-core migration moves the
# OwnedPointer between worker queues with no SM rewrite. destroy-recreate: the frame is a
# single heap value reached via OwnedPointer, NOT a Movable struct stored in a
# byte-slab.


struct SuspendedFrame[H: SuspendableHandler](Movable, Deinitable):
    """A migration-ready owned suspended-handler frame, parametric over the
    handler `H: SuspendableHandler` (single parameter — the response type is
    `H.Resp`, the handler's associated alias). Owns the SM via OwnedPointer
    (heap-stable address) + the reactor op_id it is parked on + a request id
    (the conn fd) for routing the response back to the right connection."""

    var _sm: OwnedPointer[Self.H]
    var _parked_op_id: Int64
    var _request_id: Int64

    def __init__(out self, var sm: Self.H, request_id: Int64):
        self._sm = OwnedPointer[Self.H](value=sm^)
        self._parked_op_id = Int64(0)
        self._request_id = request_id

    @always_inline
    def parked_op_id(self) -> Int64:
        return self._parked_op_id

    @always_inline
    def request_id(self) -> Int64:
        return self._request_id

    def set_parked_op_id(mut self, op_id: Int64):
        self._parked_op_id = op_id

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Self.H.Resp]:
        """Drive the owned SM one step (resumes at its saved step). The SM is
        reached through the OwnedPointer's stable heap address."""
        return self._sm[].step[S](reactor)


# =============================================================================
# SuspendableHandlerDriver[S, Resp, H] — the per-worker multiplexing driver.
# =============================================================================
# The trampoline that makes one worker serve >1 request concurrently, now
# PARAMETRIC over the handler type so every handler reuses it with
# no clone (pointer-rule). Owns the in-flight frames keyed by their parked
# op_id (a ParkedMorselSlab — the engine's canonical op_id-keyed Movable-only
# store; a frame owning an OwnedPointer is NOT Copyable, so List is out) + the
# delivered responses (a Slab, same reason).
#
# Drive shape (synchronous, runs on the worker's own thread — no migration,
# safe across destroy-recreate):
#   admit(frame, biased_op_id_hint) — step a fresh frame once; if it parks,
#                        stash it keyed by the BIASED op_id; if it finishes in
#                        one step (401 / fast path / a SyncToSuspendable handler
#                        that never parks), deliver the response immediately.
#   resume(op_id)      — resume the frame parked on `op_id`; on DONE/ERR deliver,
#                        on re-PARK re-key on the new biased op_id.
#
# The driver is SERVE-SEAM-AGNOSTIC: it does NOT poll the reactor itself (the
# HttpServer owns the single poll loop and routes completions to `resume`). The
# `run_until_idle` / `drive_one_ready_batch` (which DO poll) are kept
# as test conveniences below but the server seam uses `admit` + `resume`.


struct SuspendableHandlerDriver[
    S: WakerSink & Movable & Deinitable,
    H: SuspendableHandler,
](Movable, Deinitable):
    """Per-worker multiplexing driver for suspendable handler frames,
    parametric over the reactor sink `S` + the handler `H: SuspendableHandler`
    (the response type is `H.Resp`). Holds the in-flight parked frames (keyed by
    their already-biased op_id, in a ParkedMorselSlab) + the delivered responses
    (in a Slab). The HttpServer demux routes a reactor completion to `resume`
    only when the completion's op_id is in the biased space (>=
    HANDLER_OP_ID_BIAS), so a conn-read completion can NEVER reach a parked
    frame and vice versa."""

    var _parked: ParkedMorselSlab[SuspendedFrame[Self.H]]
    var _delivered: Slab[DeliveredResponse[Self.H.Resp]]
    # Observability — concurrency-evidence counters.
    var _admit_count: Int64
    var _park_count: Int64
    var _resume_count: Int64
    var _peak_inflight: Int64

    def __init__(out self):
        self._parked = ParkedMorselSlab[SuspendedFrame[Self.H]]()
        self._delivered = Slab[DeliveredResponse[Self.H.Resp]]()
        self._admit_count = Int64(0)
        self._park_count = Int64(0)
        self._resume_count = Int64(0)
        self._peak_inflight = Int64(0)

    @always_inline
    def inflight_count(self) -> Int:
        return self._parked.len()

    @always_inline
    def peak_inflight(self) -> Int64:
        return self._peak_inflight

    @always_inline
    def resume_count(self) -> Int64:
        return self._resume_count

    @always_inline
    def park_count(self) -> Int64:
        return self._park_count

    @always_inline
    def admit_count(self) -> Int64:
        return self._admit_count

    @always_inline
    def delivered_count(self) -> Int:
        return len(self._delivered)

    @always_inline
    def is_parked_op_id(self, op_id: Int64) -> Bool:
        """THE DEMUX PREDICATE (used by the HttpServer seam): is this completion
        op_id one this driver is currently parked on? True iff the op_id is in
        the dynamically-allocated (biased) space AND a frame is keyed on it. The
        server checks this BEFORE the conn-fd lookup; the allocation-time bias
        guarantees no false positive against a conn fd-cookie."""
        if op_id < HANDLER_OP_ID_BIAS:
            return False
        return self._parked.contains(op_id)

    def peak_parked_op_id_for_test(self) raises -> Int64:
        """TEST-ONLY: the (biased) op_id the FIRST parked frame is keyed on, or 0
        if none. Lets the op_id-demux isolation test read which biased op_id a
        frame parked on without depending on the reactor's internal counter
        value. Not used by the serve seam."""
        if self._parked.len() == 0:
            return Int64(0)
        return self._parked.op_id_at(0)

    def _update_peak(mut self):
        var n = Int64(self._parked.len())
        if n > self._peak_inflight:
            self._peak_inflight = n

    def _deliver(
        mut self,
        var frame: SuspendedFrame[Self.H],
        var sr: HandlerStepResult[Self.H.Resp],
    ):
        """The DONE arm of the exhaustive switch: land the terminal response
        into the delivered slab keyed by the frame's request_id (the conn fd),
        then drop the frame. Caller has already discriminated `is_done()` in
        `_dispatch_step_result` — this method does NOT re-check the kind.
        `take_response` moves the Resp out of the OWNED `sr`
        (a whole-value destructure of a local, not a partial-move out of a
        borrowed self)."""
        var rid = frame.request_id()
        self._delivered.append(
            DeliveredResponse[Self.H.Resp](rid, sr.take_response())
        )
        _ = frame^

    def _deliver_err(
        mut self,
        var frame: SuspendedFrame[Self.H],
        var sr: HandlerStepResult[Self.H.Resp],
    ):
        """The ERR arm of the exhaustive switch (and the DEFAULT arm — an
        unknown/reserved kind is routed here, NOT silently delivered). An ERR
        result carries NO response: the substrate has no error-response type, so
        the SyncToSuspendable adapter + every concrete handler turn a DOMAIN
        error into a DONE(error-response) BEFORE returning — ERR is reserved for
        unrecoverable handler bugs (and for a not-yet-implemented kind reaching
        the driver). The driver does NOT fabricate a response; the seam observes
        no delivery for this rid and drops the conn (defensive). The frame drops
        here (its SM destructor runs), so a handler bug can't strand the frame
        parked. `sr` is consumed for symmetry with the other arms."""
        _ = sr^
        _ = frame^

    def _park(
        mut self,
        var frame: SuspendedFrame[Self.H],
        op_id: Int64,
    ):
        """Stash a frame keyed by the op_id it just parked on (already in the
        biased space — `alloc_op_id` biases at the source)."""
        frame.set_parked_op_id(op_id)
        self._parked.park(op_id, frame^)
        self._park_count = self._park_count + Int64(1)
        self._update_peak()

    def _dispatch_step_result(
        mut self,
        var frame: SuspendedFrame[Self.H],
        var sr: HandlerStepResult[Self.H.Resp],
    ) raises -> Bool:
        """THE EXHAUSTIVE SWITCH on the step-result kind. Both `admit` and
        `resume` funnel through here so the terminal-vs-park decision lives in
        ONE place and is exhaustive by construction. Returns True iff the frame
        PARKED (and therefore stays in `_parked`); False iff the frame was
        retired (delivered or dropped) and no longer exists.

        The arms (one per discriminant — NO `else: deliver` fall-through, which
        is the bug to avoid: a naive 2-state `if is_parked(): park else:
        deliver` would silently RETIRE-and-DROP a streaming EMIT frame on its
        first chunk):
          * PARKED → `_park`        (frame retained, keyed by the biased op_id)
          * DONE   → `_deliver`     (response landed; frame dropped)
          * ERR    → `_deliver_err` (no response; frame dropped, conn dropped)
          * EMIT   → RESERVED streaming arm. No live handler returns EMIT yet,
                     so this is UNREACHABLE-by-current-handlers. When the EMIT
                     machinery lands (the chunk write-back + the re-park-and-stay
                     -resumable loop) it goes HERE — additive, not a driver-ABI
                     redesign. TODAY it routes to the SAFE ERR arm (`_deliver_err`)
                     so an accidentally-emitting frame is retired defensively, not
                     silently delivered. The 4th arm is PRESENT so the switch is
                     exhaustive the moment EMIT is implemented.
          * DEFAULT → an unknown/reserved kind is routed to the SAFE ERR arm,
                     never silently delivered. A future kind that reaches the
                     driver before the driver knows about it cannot be mistaken
                     for a DONE response."""
        if sr.is_parked():
            self._park(frame^, sr.op_id())
            return True
        elif sr.is_done():
            self._deliver(frame^, sr^)
            return False
        elif sr.is_error():
            self._deliver_err(frame^, sr^)
            return False
        elif sr.is_emit():
            # RESERVED streaming arm (see docstring). Safe-ERR retire today; the
            # EMIT chunk-write-back + re-park machinery slots in here later.
            self._deliver_err(frame^, sr^)
            return False
        else:
            # DEFAULT: unknown/reserved kind — route to the SAFE ERR arm, NOT a
            # silent deliver.
            self._deliver_err(frame^, sr^)
            return False

    def admit(
        mut self,
        var frame: SuspendedFrame[Self.H],
        mut reactor: Reactor[Self.S],
    ) raises -> Bool:
        """Step a freshly-admitted frame once, then route the result through the
        exhaustive switch (`_dispatch_step_result`). If it parks (on an
        already-biased reactor op_id from `alloc_op_id`), it is stashed keyed by
        that op_id and the worker is free to admit/serve another request. If it
        finishes in one step (401 / fast path / a SyncToSuspendable handler that
        never parks), the response is delivered immediately — no park. Returns
        True iff the frame PARKED."""
        self._admit_count = self._admit_count + Int64(1)
        var sr = frame.step[Self.S](reactor)
        return self._dispatch_step_result(frame^, sr^)

    def resume(
        mut self, op_id: Int64, mut reactor: Reactor[Self.S]
    ) raises:
        """Resume the frame parked on `op_id` (if any), then route the result
        through the exhaustive switch (`_dispatch_step_result`): on re-PARK the
        frame is re-keyed on the new (biased) op_id; on DONE/ERR/unknown it is
        delivered or retired. Non-matching op_ids are benign (a completion for a
        since-finished / unknown op — e.g. a stale conn event that already failed
        the demux predicate)."""
        var maybe = self._parked.take(op_id)
        if maybe:
            self._resume_count = self._resume_count + Int64(1)
            var frame = maybe.take()
            var sr = frame.step[Self.S](reactor)
            _ = self._dispatch_step_result(frame^, sr^)

    def take_delivered(mut self) -> Slab[DeliveredResponse[Self.H.Resp]]:
        """Move the delivered responses out (the seam writes each back to its
        conn fd; a test asserts on them)."""
        var out = self._delivered^
        self._delivered = Slab[DeliveredResponse[Self.H.Resp]]()
        return out^

    # -------------------------------------------------------------------------
    # Test conveniences — reactor-polling drive methods. The SERVER
    # seam does NOT use these (the HttpServer owns the poll loop); they exist so
    # the demux + multiplex can be exercised in isolation without a server.
    # -------------------------------------------------------------------------
    def drive_one_ready_batch(mut self, mut reactor: Reactor[Self.S]) raises:
        """Drive EXACTLY ONE poll cycle: block until at least one parked frame's
        fd is ready, drain that completion batch, and resume the matching
        frame(s). Frames whose fds are NOT ready stay parked. No-op when nothing
        is parked. The reactor completion op_id arrives BIASED (the test/seam
        registered the fd under the biased op_id), so it matches the parked key
        directly."""
        if self._parked.len() == 0:
            return
        var completions = reactor.poll_completions(Int32(-1))
        for ci in range(len(completions)):
            self.resume(completions[ci].op_id, reactor)

    def run_until_idle(mut self, mut reactor: Reactor[Self.S]) raises:
        """Drive parked frames to completion: until no frame is parked, poll the
        reactor for any completion, resume the matching frame. Uses a blocking
        poll (timeout_us=-1): there IS at least one parked frame so a completion
        WILL arrive."""
        var guard = 0
        while self._parked.len() > 0 and guard < 1_000_000:
            var completions = reactor.poll_completions(Int32(-1))
            for ci in range(len(completions)):
                self.resume(completions[ci].op_id, reactor)
            guard += 1
