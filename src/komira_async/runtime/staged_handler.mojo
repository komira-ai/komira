# =============================================================================
# komira_async/runtime/staged_handler.mojo — the variadic StagedHandler
# combinator.
# =============================================================================
# The productionized form of the proven variadic combinator
# (the POC lives in
# test_staged_handler_variadic.mojo). This module
# is a BYTE-FAITHFUL relocation of that POC's framework surface into a public
# primitive — the cursor ladder, the heap-erased active op, the per-seam carry
# reinterpret, the framework-owned terminal render. The toy carry/op/renderer
# types stay in the test; the FRAMEWORK (Stage / Renderer / AsyncOp traits +
# StagedHandler + the _box/_unbox/_move_reinterpret helpers + StagedHandlerNoop)
# moves here so route factories import it.
#
# ── THE EXACT UNKNOWN RESOLVED (and how — proven in the POC) ──────────────────
# The variadic CURSOR (walk the *Stages pack with a runtime _step over a comptime
# pack) and the per-seam carry-reinterpret were each verified SEPARATELY but
# fused into one generic-N body that ALSO conforms to SuspendableHandler. The
# fusion this module owns:
#
#   1. STORAGE: `Tuple[*Self.Stages]` (the user's stage structs). Indexable
#      inside `@parameter for` with per-element `make_op` calls.
#   2. THE ACTIVE OP across a park: each stage's `Op` type differs, so a single
#      typed op field can't span all stages. The op is stored HEAP-ERASED in
#      `_op_box: Optional[OwnedPointer[UInt8]]` (the `make_erased` blob shape),
#      recovered via `_unbox[Self.Stages[i].Op]` in the resume branch matching the
#      cursor. ONE op live at a time (the stage the cursor is on).
#   3. THE CURSOR: `_step: UInt8` (stage index 0..N-1, or `_STAGED_DONE`). `step`
#      is `@parameter for i in range(N): if Int(self._step)==i: return
#      self._drive_stage[i]()` — the runtime cursor selects the unrolled branch.
#   4. THE PER-SEAM CARRY (the wall): inside the `@parameter for`,
#      `Stages[i].Op.Out` and `Stages[i+1].In` are OPAQUE-DISTINCT even with a
#      `_type_is_eq` proof. `_move_reinterpret[Src,Dst]` (heap-box + steal +
#      bitcast + reconstruct + take, `_type_is_eq`-gated) bridges it. Carry lives
#      transiently within one step(); never held across a park.
#   5. CONFORMANCE: the combinator conforms to SuspendableHandler (`Resp` is the
#      RENDERER's associated `Resp` — `HttpResponse` in production, a toy resp in
#      the POC) and `make_erased[StagedHandlerNoop[...], NoopSink]` boxes it into
#      ONE ErasedFrame[NoopSink] — stepped BLIND through the Stage-0 driver.
#
# ── PRODUCTIONIZATION DELTA from the POC ──────────────────────────────────────
# The ONLY change from the proven POC body is that the response type is now the
# renderer's associated `Resp` (`R.Resp`) instead of a hardcoded `ToyResp`. The
# POC pinned `comptime Resp = ToyResp` everywhere; production needs the same
# combinator to emit `HttpResponse`. So the `Renderer` trait gains a
# `comptime Resp` associated type and `guard_response` / `error_response` /
# `render` return `Self.Resp`; `StagedHandler` declares `comptime Resp = R.Resp`.
# Everything else (the field set, cursor, heap-box helpers, the @parameter-for,
# the framework-owned terminal render) is byte-faithful to the POC.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────
# The user surface is value-typed: a route factory passes `Tuple[*Stages]` + a
# Renderer + a seed input, and gets a SuspendableHandler back. ZERO UnsafePointer
# crosses any public boundary; the only UnsafePointer is the `init_pointee_move`
# inside `_box` (the blessed pointer-rule heap-box, never escaping the body) +
# the OwnedPointer reconstruct in `_unbox`. No wildcard origin in any field; no
# `unsafe_from_address`. destroy-recreate: the active op + the carry live HEAP-ERASED in
# OwnedPointer[UInt8] (concrete origin, ASAP-tracked) — never a byte-slab.
# Mojo 1.0.0b1.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
)


# =============================================================================
# framework heap-box primitives: _box / _unbox / _move_reinterpret.
# =============================================================================
# `_box`/`_unbox` heap-erase a Movable value into / out of an OwnedPointer[UInt8]
# (the `make_erased`/`take_response` blob shape). `_move_reinterpret[Src,Dst]`
# (gated `(Src == Dst)`) is the per-seam carry bridge: in the generic
# StagedHandler body `Stages[i].Op.Out` and `Stages[i+1].In` are opaque-distinct
# even though proven equal, so a direct move / `rebind` will not type — the
# heap-box round-trip is the only thing that compiles. All three live ENTIRELY in
# framework code; the user never sees them. They use the blessed pointer-rule
# OwnedPointer.into_inner() partial-move primitive (NO raw take_pointee).


def _box[T: Movable & Deinitable](var v: T) -> OwnedPointer[UInt8]:
    """Heap-box a Movable `T` into a type-erased `OwnedPointer[UInt8]`.

    SAFETY: `alloc[T](1)` is a fresh concrete-origin allocation we own;
    `init_pointee_move` move-constructs `v` into it; the bytes are bitcast to a
    `UInt8` home wrapped in an OwnedPointer (single owner). Recovered ONLY by
    `_unbox[T]` for the SAME `T`. The pointer never escapes this body."""
    var home = alloc[T](1)
    UnsafePointer(to=home[]).unsafe_write(v^)
    return OwnedPointer[UInt8](unsafe_from_raw_pointer=home.bitcast[UInt8]())


def _unbox[T: Movable & Deinitable](var box: OwnedPointer[UInt8]) -> T:
    """Recover a `T` heap-boxed by `_box[T]` and move it out (consuming the box).

    SAFETY: the box's bytes ARE a valid `T` (produced by `_box[T]` for the SAME
    `T` the caller names — a `make_erased`/`take_response`-shaped reinterpret).
    `unsafe_leak()` relinquishes the UInt8 box's free, the bytes are retyped to
    `T*`, an `OwnedPointer[T]` is reconstructed over the SAME allocation, and
    `OwnedPointer.into_inner()` moves the `T` out + frees in one shot — no double-free.
    The pointer never escapes this body; no module boundary is crossed."""
    var raw = box^.unsafe_take_allocation().unsafe_leak()
    var owned = OwnedPointer[T](unsafe_from_raw_pointer=raw.bitcast[T]())
    return owned^.into_inner()


def _move_reinterpret[
    Src: Movable & Deinitable,
    Dst: Movable & Deinitable,
](var src: Src) -> Dst:
    """Move a `Src` value out as a `Dst`, PROVEN equal by the caller's
    `constrained[(Src == Dst)]` but opaque-distinct in the generic body.
    The carry-seam bridge: `Stages[i].Op.Out` -> `Stages[i+1].In`. A box+unbox
    round-trip — the only thing that compiles across the opaque-alias wall."""
    comptime assert (Src == Dst), "_move_reinterpret requires Src == Dst (a proven no-op reinterpret)"
    return _unbox[Dst](_box[Src](src^))


# =============================================================================
# the poll-shaped op states + the AsyncOp trait (the framework DRAINS it).
# =============================================================================

comptime OP_PENDING: UInt8 = 0
comptime OP_READY: UInt8 = 1
comptime OP_ERR: UInt8 = 2


trait AsyncOp(Movable, Deinitable):
    """A poll-shaped async op the framework drains to completion. The stage's
    `make_op` returns one; the framework calls start() once (register + get the
    op_id to park on), then poll() each readiness, until READY, then
    take_result() to move the `Out` carry out. An op may mark itself READY in
    start() (the OP_READY born-ready fast path — the cache-hit case).

    The real PG ops (`PgQueryOp`, `PollPgRead`, `AuthSessionPgHandlerSM`) do not
    natively expose this exact shape; thin adapters wrap them
    so a stage's `Op` IS an AsyncOp. The adapters do NOT rewrite the ops — they
    re-expose start/poll/op_state/take_result over the op's own lifecycle."""

    comptime Out: Movable & Deinitable

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        ...

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> UInt8:
        ...

    def op_state(self) -> UInt8:
        ...

    def op_id(self) -> Int64:
        ...

    def take_result(mut self) -> Self.Out:
        ...

    def err_text(self) -> String:
        ...


# =============================================================================
# the Stage trait (the user surface — one tiny Stage struct per segment).
# =============================================================================
# Each await-segment is an OPERATOR STRUCT passed as a TYPE param. The user
# writes ONLY `make_op` — no _step, no cursor, no poll.


trait Stage(Movable, Deinitable):
    """One await-segment. `In` is the carry IN; `Op` is the poll-shaped op this
    stage parks on; `Op.Out` is the carry OUT. The user implements ONLY
    `make_op` — the framework owns start/poll/take/cursor/park."""

    comptime In: Movable & Deinitable
    comptime Op: AsyncOp

    def make_op(self, var input: Self.In) raises -> Self.Op:
        ...


# =============================================================================
# the Renderer trait — the framework-owned TERMINAL adapter.
# =============================================================================
# The renderer turns the FINAL carry (the last stage's Op.Out) into the response,
# applied in StagedHandler._complete_stage (framework-owned terminal step), NOT
# the blind driver. It owns the GUARD (a domain-401 on a bad first carry,
# strict-401 pinned to stage 0) + the ERROR map (a mid-chain op ERR -> a domain
# response, e.g. 403/500). `Guard0` = the FIRST stage's carry type; `Final` =
# the LAST stage's carry type (the render input); `Resp` = the response type the
# combinator produces (`HttpResponse` in production via a JSON responder).


trait Renderer(Movable, Deinitable):
    """The terminal render + the post-stage0 guard + the mid-chain error map.
    A TYPE param (the working shape), not a fn-value param.

    `Resp` is the response type (the `StagedHandler`'s `comptime Resp`). In
    production a renderer wraps a `JsonResponder` over a `ResponseBody` carry
    and returns `HttpResponse`; the POC returns a toy response. The production
    JSON path is `JsonRenderer[Stage0Carry, Body]`."""

    comptime Guard0: Movable & Deinitable
    comptime Final: Movable & Deinitable
    comptime Resp: Movable & Deinitable

    def guard_ok(self, carry0: Self.Guard0) -> Bool:
        """True if stage0's carry is OK to proceed; False short-circuits to
        `guard_response` (the strict-401)."""
        ...

    def guard_response(self) raises -> Self.Resp:
        ...

    def error_response(self, stage_index: Int, msg: String) raises -> Self.Resp:
        """Map a mid-chain op ERR (an Outcome.err at any stage) to a domain
        response. The framework calls this when a stage's op resolves OP_ERR —
        generically over the pack, so a deny at ANY stage short-circuits here
        instead of falling through to render."""
        ...

    def render(self, var final_carry: Self.Final) raises -> Self.Resp:
        """The terminal response from the final stage's carry."""
        ...


# =============================================================================
# THE COMBINATOR: StagedHandler[RS, R, *Stages] — variadic, generic-N.
# =============================================================================
# The cursor ladder lives HERE, written ONCE in framework code. Conforms to
# SuspendableHandler (Resp = R.Resp) so make_erased boxes it into ONE
# ErasedFrame[S]. RS (the sink) is FIRST on the bare struct only to dodge the
# `step[S]` shadow ("invalid redefinition of 'S'"); the USER alias
# `StagedHandlerNoop[R, *Stages]` pins RS = NoopSink and presents the
# Renderer FIRST, *Stages LAST surface.
#
# Storage:
#   * `_step: UInt8`                              — cursor (0..N-1; N == DONE).
#   * `_stages: Tuple[*Self.Stages]`             — the user's stage structs.
#   * `_input: Optional[Stages.0.In]`            — the seed (stage 0's carry-in).
#   * `_carry_box: Optional[OwnedPointer[UInt8]]`— carry between stages
#       (transient within one step; never across a park).
#   * `_op_box: Optional[OwnedPointer[UInt8]]`   — the active op, heap-erased
#       (different type per stage), recovered via `_unbox[Stages[i].Op]`.
#   * `_has_op: Bool`                            — whether `_op_box` holds the op
#       for the current `_step` (distinguishes first-entry build from resume).
#   * `_r: R`                                    — the renderer (terminal adapter).

comptime _STAGED_DONE: UInt8 = 255


struct StagedHandler[
    RS: WakerSink & Movable & Deinitable,
    R: Renderer,
    *Stages: Stage,
](Movable, Deinitable, SuspendableHandler):
    """A variadic N-stage suspendable handler. Drives stage0 -> carry -> stage1
    -> ... -> stage[N-1] -> render, parking on each op, the type-erased carry
    threaded across every seam. The user writes ONLY the Stage structs' make_op
    + the Renderer; the cursor lives here, ONCE.

    Conforms to SuspendableHandler (Resp = R.Resp). The seed is the first
    stage's carry-in (`Optional[Stages.0.In]`, NOT `In: Defaultable` — a move-
    only/leased input may not satisfy Defaultable). Carry contract
    (op[i].Out == Stages[i+1].In; op[N-1].Out == R.Final; op[0].Out == R.Guard0)
    enforced per-seam at the reinterpret site via `_move_reinterpret`'s
    `constrained[_type_is_eq]`."""

    comptime Resp = Self.R.Resp

    var _step: UInt8
    var _input: Optional[Self.Stages[0].In]
    var _stages: Tuple[*Self.Stages]
    var _carry_box: Optional[OwnedPointer[UInt8]]
    var _op_box: Optional[OwnedPointer[UInt8]]
    var _has_op: Bool
    var _r: Self.R

    def __init__(
        out self,
        var input: Self.Stages[0].In,
        var stages: Tuple[*Self.Stages],
        var r: Self.R,
    ):
        self._step = 0
        self._input = Optional[Self.Stages[0].In](input^)
        self._stages = stages^
        self._carry_box = Optional[OwnedPointer[UInt8]]()
        self._op_box = Optional[OwnedPointer[UInt8]]()
        self._has_op = False
        self._r = r^

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[
        Self.R.Resp
    ]:
        comptime assert (S == Self.RS), "StagedHandler.step sink must match RS (the server pins one sink)"
        # The @parameter for unrolls; the branch with i == _step is the live one.
        comptime for i in range(Self.Stages.__len__()):
            if Int(self._step) == i:
                return self._drive_stage[i, S](reactor)
        # Cursor at DONE (or out of range) — should never be re-stepped.
        return HandlerStepResult[Self.R.Resp].error(
            String("StagedHandler.step at terminal/unknown cursor")
        )

    def _drive_stage[
        i: Int, S: WakerSink & Movable & Deinitable
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[
        Self.R.Resp
    ]:
        if not self._has_op:
            # First entry to stage i: take the carry-in (the seed for i==0, the
            # threaded carry box otherwise), build the op via the user's make_op.
            var carry_in = self._take_carry_in[i]()
            var op = self._stages[i].make_op(carry_in^)
            var oid = op.start[S](reactor)
            if op.op_state() == OP_ERR:
                var msg = op.err_text()
                self._step = _STAGED_DONE
                return HandlerStepResult[Self.R.Resp].done(
                    self._r.error_response(i, msg)
                )
            self._op_box = Optional[OwnedPointer[UInt8]](
                _box[Self.Stages[i].Op](op^)
            )
            self._has_op = True
            if self._peek_op_state[i]() == OP_READY:
                return self._complete_stage[i, S](reactor)
            return HandlerStepResult[Self.R.Resp].parked(oid)
        # Resume: recover op[i] from the box, poll it, re-box if still pending.
        var op = _unbox[Self.Stages[i].Op](self._op_box.take())
        var st = op.poll[S](reactor)
        if st == OP_ERR:
            var msg = op.err_text()
            self._has_op = False
            self._step = _STAGED_DONE
            return HandlerStepResult[Self.R.Resp].done(
                self._r.error_response(i, msg)
            )
        if st == OP_READY:
            self._op_box = Optional[OwnedPointer[UInt8]](
                _box[Self.Stages[i].Op](op^)
            )
            return self._complete_stage[i, S](reactor)
        var oid = op.op_id()
        self._op_box = Optional[OwnedPointer[UInt8]](
            _box[Self.Stages[i].Op](op^)
        )
        return HandlerStepResult[Self.R.Resp].parked(oid)

    def _take_carry_in[i: Int](mut self) -> Self.Stages[i].In:
        """Take the carry-in for stage i: the seed input for i==0, else the
        threaded carry box (reinterpreted to Stages[i].In)."""
        comptime if i == 0:
            # The seed is stored as `Optional[Stages.0.In]` (field-position
            # dotted-pack spelling); reinterpret its stored type to the loop's
            # pack-element form `Self.Stages[0].In` (proven equal — i == 0).
            return _move_reinterpret[Self.Stages[0].In, Self.Stages[i].In](
                self._input.take()
            )
        else:
            return _unbox[Self.Stages[i].In](self._carry_box.take())

    def _peek_op_state[i: Int](mut self) -> UInt8:
        """Read the just-stored op's state without consuming it (unbox, read,
        re-box). Used right after start() to detect a born-READY op."""
        var op = _unbox[Self.Stages[i].Op](self._op_box.take())
        var st = op.op_state()
        self._op_box = Optional[OwnedPointer[UInt8]](
            _box[Self.Stages[i].Op](op^)
        )
        return st

    def _complete_stage[
        i: Int, S: WakerSink & Movable & Deinitable
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[
        Self.R.Resp
    ]:
        # op[i] is READY in the box. Take its Out as the carry. For stage 0 also
        # run the strict-401 guard on the carry. If this was the last stage,
        # render (the framework-owned TERMINAL step); else advance + drive i+1 in
        # the SAME step (so a born-READY next stage chains forward).
        var op = _unbox[Self.Stages[i].Op](self._op_box.take())
        self._has_op = False
        var out = op.take_result()
        # Stage 0 strict-401 guard: pin the guard to the FIRST carry. Reinterpret
        # op[0].Out -> R.Guard0 (proven equal) and run the guard before anything.
        comptime if i == 0:
            var guard_carry = _move_reinterpret[
                Self.Stages[i].Op.Out, Self.R.Guard0
            ](out^)
            if not self._r.guard_ok(guard_carry):
                self._step = _STAGED_DONE
                return HandlerStepResult[Self.R.Resp].done(
                    self._r.guard_response()
                )
            return self._advance_after[i, S](
                reactor,
                _move_reinterpret[Self.R.Guard0, Self.Stages[i].Op.Out](
                    guard_carry^
                ),
            )
        else:
            return self._advance_after[i, S](reactor, out^)

    def _advance_after[
        i: Int, S: WakerSink & Movable & Deinitable
    ](
        mut self,
        mut reactor: Reactor[S],
        var carry_out: Self.Stages[i].Op.Out,
    ) raises -> HandlerStepResult[Self.R.Resp]:
        """Common tail of _complete_stage: either render (last stage) or thread
        the carry into stage i+1 and drive it in the SAME step."""
        comptime if i + 1 >= Self.Stages.__len__():
            # TERMINAL: render the final carry (op[N-1].Out -> R.Final). The
            # responder is applied HERE, in framework-owned terminal code,
            # monomorphized per handler — NOT in the blind driver.
            self._step = _STAGED_DONE
            return HandlerStepResult[Self.R.Resp].done(
                self._r.render(
                    _move_reinterpret[Self.Stages[i].Op.Out, Self.R.Final](
                        carry_out^
                    )
                )
            )
        else:
            # Thread the carry into stage i+1's carry-in slot (Stages[i].Op.Out ==
            # Stages[i+1].In, proven), advance the cursor, drive i+1 NOW.
            self._step = UInt8(i + 1)
            self._carry_box = Optional[OwnedPointer[UInt8]](
                _box[Self.Stages[i + 1].In](
                    _move_reinterpret[
                        Self.Stages[i].Op.Out, Self.Stages[i + 1].In
                    ](carry_out^)
                )
            )
            return self._drive_stage[i + 1, S](reactor)


# =============================================================================
# the user-facing alias (Renderer FIRST, *Stages LAST; sink pinned).
# =============================================================================
# The user-facing surface: `StagedHandlerNoop[R, *Stages]`. The bare struct's
# RS sink param is pinned to NoopSink (the server pins one sink everywhere); the
# user never spells it. This is what a route factory instantiates.

comptime StagedHandlerNoop[R: Renderer, *Stages: Stage] = StagedHandler[
    NoopSink, R, *Stages
]
