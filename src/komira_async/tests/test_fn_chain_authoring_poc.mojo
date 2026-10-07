# =============================================================================
# test_fn_chain_authoring_poc.mojo
# POC: LIGHTEST stackless authoring (fn-chain vs struct).
# =============================================================================
# The goal: Tokio-ease for writing async HTTP
# handlers on OUR per-core runtime. Stackless (no Mojo async, no fibers), so the
# await-boundary decomposition is irreducible — the goal is to make each segment
# as cheap to write as possible and let the FRAMEWORK own poll/drain/cursor/
# take/carry/erasure.
#
# THE QUESTION (GO / NO-GO on the fn-chain form): can the user write a top-level
# free `fn` per await-segment + a render, and a comptime combinator chain them,
# so the user NEVER writes a `_step` cursor / poll loop / per-phase struct?
#
#   fn auth_step(token) -> AuthOp ;  fn list_step(user) -> ListOp ;  fn render(...)
#   comptime NotifHandler = chain(auth_step, list_step, render)
#
# VERDICT: NO-GO on the free-fn-chain form. Mojo 1.0.0b1 hard-walls a comptime
# fn-VALUE struct param THREE independent ways (all reproduced minimally in a
# 30-line standalone):
#   (1) a top-level named `fn auth_step(...) -> Op` does NOT coerce to a
#       `fn(...) -> Op` comptime param ("cannot implicitly convert ... value");
#   (2) CALLING a comptime fn-value param in a method body errors
#       "missing 1 required keyword-only argument: 'take'";
#   (3) a method referencing a comptime fn-value param becomes `capturing`,
#       which does NOT conform to a non-`capturing` trait method.
#
# SO THIS POC SHIPS THE FORM THAT COMPILES + RUNS (the AsyncStage-struct form,
# the in-tree combinator idiom — cf. MorselStepDriver[S,Op], JoinBuildTable[KB,
# *Payload]): each await-segment is a tiny OPERATOR STRUCT passed as a TYPE param,
# implementing ONE method (`make_op`). The combinator `Chain2[RS,S0,S1,R]` owns
# the cursor / drain / take / carry / park. The user writes ~6 lines per stage +
# a renderer struct — NEVER a step/cursor/poll. That is still a large ergonomic
# win over a hand-rolled `_step` ladder, and it is the recommended
# shape.
#
# WHAT THIS POC PROVES (compiles + runs on Mojo 1.0.0b1, BACKEND_MOCK):
#   (1) The `AsyncOp` poll-shaped trait (start/poll/take_result + assoc `Out`) —
#       the op the framework DRAINS to completion. Modeled on PgQueryOp/PollPgRead.
#   (2) A 2-stage combinator `Chain2[RS, S0, S1, R]` that conforms to
#       SuspendableHandler (boxes into ONE ErasedHandlerFrame[S]) and owns the CURSOR +
#       the active op + the threaded carry; the USER writes only the Stage/Render
#       structs' make_op/render bodies, NEVER step/poll/cursor/take.
#   (3) MULTI-PARK end-to-end: stage0 parks (ready after N polls) -> framework
#       drains -> carry threaded into stage1 -> stage1 parks -> drains -> render.
#   (4) It routes through the SAME ErasedHandlerFrame driver as test_erased_frame_spike: the
#       chain is ONE erased handler in a Slab[ErasedHandlerFrame[S]].
#
# CARRY THREADING — the seam carry (S0.Op.Out -> S1.In, S1.Op.Out -> R.Carry1) is
# OPAQUE-DISTINCT in the generic Chain2 body EVEN with a `constrained[_type_is_eq]`
# proof (the variadic-stage-pipeline wall — operator-
# struct type params do NOT escape it). `rebind` does NOT bridge it (copy-based;
# the carry is move-only at the generic level). The ONLY thing that compiles is
# the framework's `_move_reinterpret[Src,Dst]` heap-box reinterpret — the
# `ErasedStepResult.take_response[Resp]` shape. It lives ENTIRELY in framework
# code, written once; the user never sees it. It is the residual BOILERPLATE the
# honest verdict flags.
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform. The toy ops park on a
# bare `reactor.alloc_op_id()` and become READY after a fixed poll count (no real
# I/O readiness), exactly like the prior spikes.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_MOCK,
    OP_ID_ALLOC_BASE,
    Reactor,
)
from komira_async.runtime.shared_erasure import (
    ErasedHandlerFrame,
    make_erased_handler_frame,
)
from komira_async.runtime.suspendable_handler import (
    HANDLER_OP_ID_BIAS,
    HandlerStepResult,
    SuspendableHandler,
)

from komira_collections.slab import Slab


# =============================================================================
# _move_reinterpret[Src, Dst] — the framework's carry-seam reinterpret.
# =============================================================================
# THE WALL (reproduced — see the report): in the generic Chain2 body the
# compiler treats stage0's carry-out `S0.Op.Out` and stage1's carry-in `S1.In`
# as OPAQUE DISTINCT types EVEN THOUGH a `constrained[_type_is_eq[...]]` proves
# them equal. `rebind[Dst](x)` does NOT bridge them: rebind is COPY-based and
# the generic carry types are NOT ImplicitlyCopyable (a move-only NotifRows /
# AuthedUser at the generic level) — "value of type 'S1.In' cannot be implicitly
# copied". Exactly the variadic-stage-pipeline finding:
# operator-struct type params do NOT escape the opaque-alias wall.
#
# The ONLY thing that compiles is the substrate's own move-reinterpret (the
# `ErasedStepResult.take_response[Resp]` shape): heap-box the Src, steal the raw
# bytes, bitcast to Dst, reconstruct an OwnedPointer[Dst], take. Gated by
# `constrained[(Src == Dst)]` so it is a no-op reinterpret, never a real
# type pun. This lives ENTIRELY in framework code (written once); the user never
# sees it. It is the residual BOILERPLATE the honest verdict flags.


def _move_reinterpret[
    Src: Movable & Deinitable,
    Dst: Movable & Deinitable,
](var src: Src) -> Dst:
    """Move a `Src` value out as a `Dst`, where `Src` and `Dst` are PROVEN equal
    by the caller's `constrained[(Src == Dst)]` but the compiler treats
    them as opaque-distinct in the generic body. Heap-box + steal + bitcast +
    reconstruct + take — the blessed pointer-rule partial-move primitive, no raw
    take_pointee, no double-free (the box is unsafe_leak()'d so it relinquishes its
    free). Same shape as `ErasedStepResult.take_response[Resp]`."""
    comptime assert (Src == Dst), "_move_reinterpret requires Src == Dst (a proven no-op reinterpret)"
    var home = alloc[Src](1)
    # SAFETY: fresh allocation we own; in-place move-construct src into it.
    UnsafePointer(to=home[]).unsafe_write(src^)
    var box = OwnedPointer[UInt8](unsafe_from_raw_pointer=home.bitcast[UInt8]())
    var raw = box^.unsafe_take_allocation().unsafe_leak()
    var dst_owned = OwnedPointer[Dst](unsafe_from_raw_pointer=raw.bitcast[Dst]())
    return dst_owned^.into_inner()


# =============================================================================
# The poll-shaped op states + the AsyncOp trait (the framework DRAINS it).
# =============================================================================
# Mirrors PollPgRead / PgQueryOp: PENDING / READY / ERR. The framework polls the
# op to completion; on READY it moves the Out value out via take_result().

comptime OP_PENDING: UInt8 = 0
comptime OP_READY: UInt8 = 1
comptime OP_ERR: UInt8 = 2


trait AsyncOp(Movable, Deinitable):
    """A poll-shaped async op the framework drains to completion. The user's
    stage-fn returns one of these; the framework calls start() once (to register
    + get the op_id to park on), then poll() each time the op's fd is readable,
    until READY, then take_result() to move the Out value out.

    `Out` is an associated alias (the carry type into the next stage). The op
    OWNS its in-flight working set across the park (its fd + partial buffer);
    that is why it must be a struct, not a closure — a free fn cannot hold state
    across a suspension. But the user writes only the stage-fn that BUILDS the
    op; the op types are reusable primitives (PgQueryOp, an auth lookup op, ...).
    """

    comptime Out: Movable & Deinitable

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Register the op, return the op_id to park on. (On an immediate-ready
        fast path the op may mark itself READY here and the framework skips the
        park — same as PollPgRead.start.)"""
        ...

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> UInt8:
        """Re-attempt the op; return the new state (PENDING/READY/ERR)."""
        ...

    def op_state(self) -> UInt8:
        ...

    def op_id(self) -> Int64:
        ...

    def take_result(mut self) -> Self.Out:
        """Move the Out carry out (caller checks op_state() == OP_READY)."""
        ...

    def err_text(self) -> String:
        ...


# =============================================================================
# Toy domain types (the carry + the response).
# =============================================================================
# Flat PODs / simple heap containers — the carry between stages. Stand in for
# AuthedUser / List[Notification] / HttpResponse.


struct AuthedUser(Movable, Deinitable, Copyable):
    """The carry out of the auth stage into the list stage. Flat POD."""

    var user_id: Int64
    var valid: Bool

    def __init__(out self, user_id: Int64, valid: Bool):
        self.user_id = user_id
        self.valid = valid


struct NotifRows(Movable, Deinitable):
    """The carry out of the list stage into render. A heap-owning List (the
    destroy-recreate shape — a non-trivial heap field that must survive the chain)."""

    var rows: List[Int64]

    def __init__(out self, var rows: List[Int64]):
        self.rows = rows^


struct ToyResp(Movable, Deinitable):
    """The terminal response (Movable-not-Copyable, heap-owning body String)."""

    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^


# =============================================================================
# Two concrete AsyncOps (parks after a fixed poll count, then READY).
# =============================================================================
# These model the two PG round-trips. Each parks on a bare alloc_op_id() and
# becomes READY after `_ready_after` polls (no real fd readiness — BACKEND_MOCK).
# The user does NOT write these per-handler in production: they are reusable
# primitives (PgQueryOp). Here two toy ops with different Out types prove the
# carry threading.


struct AuthLookupOp(Movable, Deinitable, AsyncOp):
    """Parks on a session lookup; produces an AuthedUser. Out = AuthedUser."""

    comptime Out = AuthedUser

    var _token: Int64
    var _op_id: Int64
    var _state: UInt8
    var _polls_left: Int

    def __init__(out self, token: Int64, ready_after: Int):
        self._token = token
        self._op_id = Int64(0)
        self._state = OP_PENDING
        self._polls_left = ready_after

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        self._op_id = reactor.alloc_op_id()
        if self._polls_left <= 0:
            self._state = OP_READY
        return self._op_id

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> UInt8:
        if self._state != OP_PENDING:
            return self._state
        self._polls_left -= 1
        if self._polls_left <= 0:
            self._state = OP_READY
        return self._state

    def op_state(self) -> UInt8:
        return self._state

    def op_id(self) -> Int64:
        return self._op_id

    def take_result(mut self) -> AuthedUser:
        # Resolve the token to a user (valid iff token != 0).
        return AuthedUser(self._token + Int64(1000), self._token != Int64(0))

    def err_text(self) -> String:
        return String("")


struct ListQueryOp(Movable, Deinitable, AsyncOp):
    """Parks on the notif list query; produces NotifRows. Out = NotifRows."""

    comptime Out = NotifRows

    var _owner: Int64
    var _op_id: Int64
    var _state: UInt8
    var _polls_left: Int

    def __init__(out self, owner: Int64, ready_after: Int):
        self._owner = owner
        self._op_id = Int64(0)
        self._state = OP_PENDING
        self._polls_left = ready_after

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        self._op_id = reactor.alloc_op_id()
        if self._polls_left <= 0:
            self._state = OP_READY
        return self._op_id

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> UInt8:
        if self._state != OP_PENDING:
            return self._state
        self._polls_left -= 1
        if self._polls_left <= 0:
            self._state = OP_READY
        return self._state

    def op_state(self) -> UInt8:
        return self._state

    def op_id(self) -> Int64:
        return self._op_id

    def take_result(mut self) -> NotifRows:
        # Model 3 rows derived from the owner id.
        var rows = List[Int64]()
        rows.append(self._owner)
        rows.append(self._owner + Int64(1))
        rows.append(self._owner + Int64(2))
        return NotifRows(rows^)

    def err_text(self) -> String:
        return String("")


# =============================================================================
# THE USER SURFACE: a Stage trait + one tiny Stage struct per await-segment.
# =============================================================================
# WHY NOT A FREE-FN CHAIN (the NO-GO finding — see the design doc + the report):
# Mojo 1.0.0b1 hard-walls a comptime fn-VALUE struct param three independent
# ways (all reproduced minimally):
#   (1) a top-level named `fn auth_step(token: Int64) -> Op` does NOT coerce to a
#       `fn(Int64) -> Op` comptime param ("cannot implicitly convert ... value");
#   (2) CALLING a comptime fn-value param inside a method body errors with
#       "missing 1 required keyword-only argument: 'take'";
#   (3) a method that references a comptime fn-value param becomes `capturing`,
#       which does NOT conform to a non-`capturing` trait method requirement.
# So the chain cannot be expressed as free fns + comptime fn-ptr params. The
# shape that COMPILES is the in-tree combinator idiom (cf. MorselStepDriver[S,Op],
# JoinBuildTable[KB,*Payload]): each stage is an OPERATOR STRUCT passed as a TYPE
# param. The user writes a tiny struct per await-segment with ONE method
# (`make_op`) — no `_step`, no cursor, no poll. The combinator owns everything.
#
# The Stage trait: each stage knows its input carry `In`, its op `Op` (whose
# `Op.Out` is the carry into the next stage), and a `make_op(In) -> Op` builder.


trait Stage(Movable, Deinitable):
    """One await-segment. `In` is the carry IN (from the prior stage / the
    request); `Op` is the poll-shaped op this stage parks on; `Op.Out` is the
    carry OUT (into the next stage). The user implements ONLY `make_op` — the
    framework owns start/poll/take/cursor/park."""

    comptime In: Movable & Deinitable
    comptime Op: AsyncOp

    def make_op(self, var input: Self.In) raises -> Self.Op:
        """Build the op from the input carry. No reactor, no park, no cursor —
        the framework drives the returned op to completion."""
        ...


# The two stages of the NotifList handler. Each is a ~6-line struct. The user
# writes NO step/cursor/poll — just make_op. (Stages can hold config; here they
# are empty.)


struct AuthStage(Movable, Deinitable, Stage):
    """Stage 0: park on the session lookup. In = the bearer token (Int64);
    Op = AuthLookupOp (Op.Out = AuthedUser)."""

    comptime In = Int64
    comptime Op = AuthLookupOp

    def __init__(out self):
        pass

    def make_op(self, var input: Int64) raises -> AuthLookupOp:
        return AuthLookupOp(input, ready_after=2)


struct ListStage(Movable, Deinitable, Stage):
    """Stage 1: park on the list query. In = AuthedUser (the carry from
    AuthStage); Op = ListQueryOp (Op.Out = NotifRows)."""

    comptime In = AuthedUser
    comptime Op = ListQueryOp

    def __init__(out self):
        pass

    def make_op(self, var input: AuthedUser) raises -> ListQueryOp:
        return ListQueryOp(input.user_id, ready_after=2)


def render(var rows: NotifRows) -> ToyResp:
    """Pure terminal render — no park. Produces the response from the final
    carry. A plain free fn here works because render is invoked as a comptime
    TYPE-param method below (Renderer.render), NOT a fn-value param —"""
    var body = String("notifs:")
    for i in range(len(rows.rows)):
        if i > 0:
            body += String(",")
        body += String(rows.rows[i])
    return ToyResp(200, body^)


trait Renderer(Movable, Deinitable):
    """The terminal render + the post-stage0 guard (e.g. strict-401 on invalid
    auth). Implemented as ONE small struct so it is a TYPE param (the working
    shape), not a fn-value param (the NO-GO shape)."""

    comptime Carry0: Movable & Deinitable
    comptime Carry1: Movable & Deinitable

    def guard_ok(self, carry0: Self.Carry0) -> Bool:
        """True if stage0's carry is OK to proceed; False short-circuits."""
        ...

    def guard_response(self) -> ToyResp:
        """The short-circuit response (e.g. a 401) when guard_ok is False."""
        ...

    def render(self, var carry1: Self.Carry1) -> ToyResp:
        """The terminal response from the final carry."""
        ...


struct NotifRenderer(Movable, Deinitable, Renderer):
    """The NotifList terminal: 401 on invalid auth, else render the rows."""

    comptime Carry0 = AuthedUser
    comptime Carry1 = NotifRows

    def __init__(out self):
        pass

    def guard_ok(self, carry0: AuthedUser) -> Bool:
        return carry0.valid

    def guard_response(self) -> ToyResp:
        return ToyResp(401, String("unauthorized"))

    def render(self, var carry1: NotifRows) -> ToyResp:
        return render(carry1^)


# =============================================================================
# THE COMBINATOR: Chain2 — owns the cursor + carry + active op, conforms
#      to SuspendableHandler. The user NEVER writes any of this.
# =============================================================================
# Parametric over the SINK + the two Stage operator structs + the Renderer (all
# TYPE params — the working idiom). Because the stages are concrete types, the
# carry types (S0.Op.Out == AuthedUser == S1.In, S1.Op.Out == NotifRows) are NOT
# opaque — the compiler sees them concretely, so NO heap-box reinterpret is
# needed at the seams (the win over the generic `Pipeline[*Stages]` body where
# Stage[i].Out was opaque).
#
# The cursor ladder lives HERE, written ONCE in framework code. The user's
# Stage structs are pure transforms.

comptime _CHAIN_STAGE0: UInt8 = 0  # building/parking on op0 (auth)
comptime _CHAIN_STAGE1: UInt8 = 1  # building/parking on op1 (list)
comptime _CHAIN_DONE: UInt8 = 2


struct Chain2[
    RS: WakerSink & Movable & Deinitable,
    S0: Stage,
    S1: Stage,
    R: Renderer,
](Movable, Deinitable, SuspendableHandler):
    """A 2-stage handler. Owns the cursor (_step), the request input, the two
    Stage structs, the Renderer, and the currently-active op (Optional[S0.Op] /
    Optional[S1.Op]). Drives S0 -> carry -> S1 -> render, parking on each op.

    The carry contract is enforced by the framework, not the user:
      S0.Op.Out == S1.In   (auth carry feeds the list stage)
      S1.Op.Out == R.Carry1 (list rows feed the render)
      S0.Op.Out == R.Carry0 (auth carry feeds the guard)
    checked once here via `constrained[_type_is_eq...]`.

    Conforms to SuspendableHandler with Resp = ToyResp, so make_erased_handler_frame[Chain2,
    S] boxes it into ONE ErasedHandlerFrame[S] — the chain is one erased handler."""

    comptime Resp = ToyResp

    var _step: UInt8
    var _input: Optional[Self.S0.In]
    var _s0: Self.S0
    var _s1: Self.S1
    var _r: Self.R
    var _op0: Optional[Self.S0.Op]
    var _op1: Optional[Self.S1.Op]

    def __init__(out self, var input: Self.S0.In, var s0: Self.S0, var s1: Self.S1, var r: Self.R):
        comptime assert (Self.S0.Op.Out == Self.S1.In), "stage0's carry-out type must equal stage1's carry-in type"
        comptime assert (Self.S1.Op.Out == Self.R.Carry1), "stage1's carry-out type must equal the renderer's Carry1"
        comptime assert (Self.S0.Op.Out == Self.R.Carry0), "stage0's carry-out type must equal the renderer's Carry0 (guard)"
        self._step = _CHAIN_STAGE0
        self._input = Optional[Self.S0.In](input^)
        self._s0 = s0^
        self._s1 = s1^
        self._r = r^
        self._op0 = Optional[Self.S0.Op]()
        self._op1 = Optional[Self.S1.Op]()

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[ToyResp]:
        comptime assert (S == Self.RS), "Chain2.step sink must match the chain's RS parameter (the server" " pins one sink everywhere — same as the production NoopSink pin)"
        if self._step == _CHAIN_STAGE0:
            return self._drive_stage0[S](reactor)
        elif self._step == _CHAIN_STAGE1:
            return self._drive_stage1[S](reactor)
        else:
            return HandlerStepResult[ToyResp].error(
                String("chain: step() at unexpected step")
            )

    def _drive_stage0[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[ToyResp]:
        if not self._op0:
            # First entry: build the op via the user's stage0 make_op, start it.
            var op = self._s0.make_op(self._input.take())
            var oid = op.start[S](reactor)
            if op.op_state() == OP_ERR:
                return HandlerStepResult[ToyResp].error(op.err_text())
            self._op0 = Optional[Self.S0.Op](op^)
            if self._op0.value().op_state() == OP_READY:
                return self._advance_to_stage1[S](reactor)
            return HandlerStepResult[ToyResp].parked(oid)
        # Resumed: poll the op.
        var st = self._op0.value().poll[S](reactor)
        if st == OP_ERR:
            return HandlerStepResult[ToyResp].error(self._op0.value().err_text())
        if st == OP_READY:
            return self._advance_to_stage1[S](reactor)
        return HandlerStepResult[ToyResp].parked(self._op0.value().op_id())

    def _advance_to_stage1[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[ToyResp]:
        # Take the carry out of op0 (op0 consumed here), run the guard, then
        # build + start op1 with the carry threaded in. The carry types match
        # concretely (the ctor's `constrained` proved S0.Op.Out == S1.In), so
        # NO heap-box reinterpret is needed — the win over the opaque-alias
        # generic Pipeline body.
        var carry0 = self._op0.value().take_result()
        _ = self._op0.take()  # op0 consumed
        # Reinterpret the (opaque) S0.Op.Out carry to the renderer's Carry0 (the
        # ctor proved S0.Op.Out == R.Carry0). Run the guard on a borrow.
        var guard_carry = _move_reinterpret[Self.S0.Op.Out, Self.R.Carry0](carry0^)
        if not self._r.guard_ok(guard_carry):
            self._step = _CHAIN_DONE
            return HandlerStepResult[ToyResp].done(self._r.guard_response())
        # Reinterpret again (R.Carry0 == S1.In proven, transitively) and thread
        # the carry into stage1's make_op.
        var op1 = self._s1.make_op(
            _move_reinterpret[Self.R.Carry0, Self.S1.In](guard_carry^)
        )
        var oid = op1.start[S](reactor)
        if op1.op_state() == OP_ERR:
            self._step = _CHAIN_DONE
            return HandlerStepResult[ToyResp].error(op1.err_text())
        self._op1 = Optional[Self.S1.Op](op1^)
        self._step = _CHAIN_STAGE1
        if self._op1.value().op_state() == OP_READY:
            return self._finish[S](reactor)
        return HandlerStepResult[ToyResp].parked(oid)

    def _drive_stage1[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[ToyResp]:
        var st = self._op1.value().poll[S](reactor)
        if st == OP_ERR:
            self._step = _CHAIN_DONE
            return HandlerStepResult[ToyResp].error(self._op1.value().err_text())
        if st == OP_READY:
            return self._finish[S](reactor)
        return HandlerStepResult[ToyResp].parked(self._op1.value().op_id())

    def _finish[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[ToyResp]:
        self._step = _CHAIN_DONE
        var carry1 = self._op1.value().take_result()
        _ = self._op1.take()
        # Reinterpret the (opaque) S1.Op.Out carry to the renderer's Carry1 (the
        # ctor proved S1.Op.Out == R.Carry1) and render.
        return HandlerStepResult[ToyResp].done(
            self._r.render(
                _move_reinterpret[Self.S1.Op.Out, Self.R.Carry1](carry1^)
            )
        )


# =============================================================================
# The user's whole handler: ONE comptime alias over the stage structs.
# =============================================================================
comptime NotifListHandler = Chain2[NoopSink, AuthStage, ListStage, NotifRenderer]


def _build_notif_handler(input: Int64) -> NotifListHandler:
    """The route factory: build the chain handler from the request input. (The
    Router would call this at dispatch time.)"""
    return NotifListHandler(input, AuthStage(), ListStage(), NotifRenderer())


comptime _ChainFrame = ErasedHandlerFrame[NoopSink]


# =============================================================================
# 1. The fn-chain handler drives stage0 -> carry -> stage1 -> render through the
#    SuspendableHandler.step ladder DIRECTLY (no erasure yet). Multi-park.
# =============================================================================
def test_fn_chain_two_stage_multipark_direct() raises:
    """Drive the Chain2 handler directly via step(): stage0 parks (op0 ready
    after 2 polls), carry threaded, stage1 parks (op1 ready after 2 polls),
    render produces the response. Asserts the final 200 + body derived from the
    carry chain (token -> user_id -> rows)."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    # token=5 -> user_id=1005 (valid) -> rows=[1005,1006,1007]
    var h = _build_notif_handler(Int64(5))

    # step 1: stage0 START -> PARKED.
    var sr = h.step[NoopSink](reactor)
    assert_true(sr.is_parked(), "stage0 parks on the auth lookup")
    var op0_id = sr.op_id()
    assert_true(op0_id >= HANDLER_OP_ID_BIAS, "op0 op_id is biased")

    # step 2: stage0 RESUME poll (polls_left 2 -> 1) -> still PENDING -> re-park.
    sr = h.step[NoopSink](reactor)
    assert_true(sr.is_parked(), "stage0 still pending after 1 poll")

    # step 3: stage0 RESUME poll (1 -> 0) -> READY -> advance to stage1 -> stage1
    #          START -> PARKED on op1.
    sr = h.step[NoopSink](reactor)
    assert_true(sr.is_parked(), "stage1 parks on the list query (carry threaded)")
    var op1_id = sr.op_id()
    assert_true(op1_id >= HANDLER_OP_ID_BIAS, "op1 op_id is biased")
    assert_true(op1_id != op0_id, "op1 has a distinct op_id from op0")

    # step 4: stage1 RESUME poll (2 -> 1) -> PENDING -> re-park.
    sr = h.step[NoopSink](reactor)
    assert_true(sr.is_parked(), "stage1 still pending after 1 poll")

    # step 5: stage1 RESUME poll (1 -> 0) -> READY -> render -> DONE.
    sr = h.step[NoopSink](reactor)
    assert_true(sr.is_done(), "render produces the terminal response")
    var resp = sr.take_response()
    assert_equal(resp.status, 200)
    # token 5 -> user_id 1005 -> rows [1005, 1006, 1007]
    assert_equal(resp.body, String("notifs:1005,1006,1007"))

    _ = h^
    print("  [1] fn-chain 2-stage multi-park (direct step): carry threaded OK")


# =============================================================================
# 2. SAME fn-chain handler, boxed into ONE ErasedHandlerFrame[S] and stepped BLIND.
#    Proves the chain is ONE erased handler routed through the Stage-0 driver.
# =============================================================================
def test_fn_chain_through_erased_frame() raises:
    """make_erased_handler_frame[NotifListHandler, NoopSink] boxes the chain into ONE
    ErasedHandlerFrame[NoopSink] in a Slab; step it BLIND through _step_fn across all
    parks. The chain (cursor + carry + 2 ops) lives behind the erasure; the
    driver never sees the concrete Chain2 type. Final response round-trips
    byte-identical through the heap-box."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    var frames = Slab[_ChainFrame]()
    # token=7 -> user_id=1007 -> rows=[1007,1008,1009]
    frames.append(make_erased_handler_frame[NotifListHandler, NoopSink](
        _build_notif_handler(Int64(7)), Int64(700)
    ))
    assert_equal(frames.len(), 1)

    # Drive the erased frame BLIND through every park to DONE. 5 steps mirror the
    # direct test (stage0 start+park, stage0 poll, stage0->stage1 advance+park,
    # stage1 poll, stage1 ready+render).
    var done = False
    var guard = 0
    var final_status = 0
    var final_body = String("")
    while (not done) and guard < 100:
        var sr = frames[0].step(reactor)
        if sr.is_parked():
            frames[0].set_parked_op_id(sr.op_id())
        elif sr.is_done():
            var resp = sr.take_response[ToyResp]()
            final_status = resp.status
            final_body = resp.body
            done = True
        elif sr.is_error():
            raise Error(String("unexpected ERR: ") + sr.err_text())
        guard += 1

    assert_true(done, "the erased chain finished")
    assert_equal(final_status, 200)
    assert_equal(final_body, String("notifs:1007,1008,1009"))

    _ = frames^
    print("  [2] fn-chain through ErasedHandlerFrame: one erased handler, blind step OK")


# =============================================================================
# 3. The 401 short-circuit: an invalid auth carry (token=0) short-circuits to a
#    one-step 401 DONE without ever building/parking stage1. Strict-401 shape.
# =============================================================================
def test_fn_chain_unauthorized_short_circuit() raises:
    """token=0 resolves to an INVALID AuthedUser; the guard fires and the chain
    DONEs a 401 WITHOUT building or parking the list op. This is the strict-401
    composition (auth as the first stage, deny short-circuits)."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    var h = _build_notif_handler(Int64(0))  # token 0 -> invalid

    # stage0 START -> PARKED, then 2 polls to READY, then the guard fires.
    var sr = h.step[NoopSink](reactor)
    assert_true(sr.is_parked())
    sr = h.step[NoopSink](reactor)  # poll 2->1
    assert_true(sr.is_parked())
    sr = h.step[NoopSink](reactor)  # poll 1->0 -> READY -> guard -> 401 DONE
    assert_true(sr.is_done(), "invalid auth short-circuits to a one-step DONE")
    var resp = sr.take_response()
    assert_equal(resp.status, 401)
    assert_equal(resp.body, String("unauthorized"))

    _ = h^
    print("  [3] fn-chain 401 short-circuit (no stage1 park) OK")


def main() raises:
    test_fn_chain_two_stage_multipark_direct()
    test_fn_chain_through_erased_frame()
    test_fn_chain_unauthorized_short_circuit()
    print("PASS test_fn_chain_authoring_poc")
