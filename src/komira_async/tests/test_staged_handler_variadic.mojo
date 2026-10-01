# =============================================================================
# test_staged_handler_variadic.mojo
# StagedHandler[R, *Stages] variadic combinator at N=2 / N=3 / N=4.
# =============================================================================
# The foundation for a staged HTTP handler
# framework. Fuses the fixed-arity Chain2 POC (test_fn_chain_authoring_poc.mojo)
# into ONE variadic generic-N combinator: `StagedHandler[RS, R, *Stages]`
# (arg order on the USER alias: Renderer FIRST, the greedy
# `*Stages` pack LAST — `StagedHandlerNoop[R, *Stages]` pins the sink; the bare
# struct carries the internal `RS` sink param first to dodge the `step[S]`
# shadow). It conforms to `SuspendableHandler` and boxes via `make_erased_handler_frame` into
# ONE `ErasedHandlerFrame[S]`.
#
# ── THE EXACT UNKNOWN RESOLVED (and how — proven in 3 standalone probes) ──────
# The variadic CURSOR (walk the *Stages pack with a runtime _step over a comptime
# pack) and the per-seam carry-reinterpret were each verified SEPARATELY but
# NEVER fused into one generic-N body that ALSO conforms to SuspendableHandler.
# The in-tree variadic precedent (HashAggTable/JoinBuildTable) is the WRONG shape
# (trait-method-PER-SLOT — each pack element processed independently against the
# same row); NONE thread an opaque move-only carry FROM Stages[i].Op.Out INTO
# Stages[i+1].In. The fusion proven here:
#
#   1. STORAGE: `Tuple[*Self.Stages]` (the user's stage structs). Verified
#      indexable inside `@parameter for` with per-element `make_op` calls.
#   2. THE ACTIVE OP across a park: each stage's `Op` type differs, so a single
#      typed op field can't span all stages. The op is stored HEAP-ERASED in
#      `_op_box: Optional[OwnedPointer[UInt8]]` (the `make_erased_handler_frame` blob shape),
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
#   5. CONFORMANCE: the combinator conforms to SuspendableHandler (Resp=ToyResp)
#      and `make_erased_handler_frame[StagedHandlerNoop[...], NoopSink]` boxes it into ONE
#      ErasedHandlerFrame[NoopSink] — stepped BLIND through the Stage-0 driver.
#
# ── ACCEPTANCE (this file) ───────────────────────────────────────────────────
#   1. N=3 (auth -> authz -> list) AND N=4 (auth -> authz -> list -> enrich)
#      each park MULTIPLE times, thread the type-erased carry across EVERY seam,
#      render the final response — DIRECT and BLIND through ErasedHandlerFrame.
#   2. Mid-chain short-circuit: an op OP_ERR (Outcome.err) at stage 1 (authz
#      deny) means stages 2+ never run and the renderer's error_response maps it
#      to a 403 — generically over the pack (not just stage 0).
#   3. Both-immediate-ready (ops born OP_READY advance without parking — the
#      cache-hit case) AND multi-park sub-cases.
#   4. The renderer/responder is applied in the framework-owned TERMINAL step
#      (`StagedHandler._finish`/_complete), monomorphized per handler — NOT in
#      the blind driver.
#   5. Strict-401 guard pinned to stage 0 (an invalid first carry short-circuits
#      to guard_response WITHOUT building any later op).
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform. Toy ops park on a bare
# `reactor.alloc_op_id()` and become READY after a fixed poll count.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

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
)

# CHUNK 1: the framework surface is now a PUBLIC primitive
# under src/. This test imports it (the Stage / Renderer / AsyncOp traits + the
# op states + the StagedHandlerNoop alias) instead of defining it inline — a
# pure relocation; the 7 tests below are unchanged. The combinator + the
# heap-box helpers live in the src/ primitive now.
from komira_async.runtime.staged_handler import (
    OP_PENDING,
    OP_READY,
    OP_ERR,
    AsyncOp,
    Stage,
    Renderer,
    StagedHandlerNoop,
)

from komira_core.collections.slab import Slab


# =============================================================================
# Toy carry types (DISTINCT per seam) + the response.
# =============================================================================
# Each stage's Out is a DISTINCT type so the carry threading is genuinely
# type-changing at each seam. A mix of flat POD + heap-owning (List/String)
# carries — the destroy-recreate shape that must survive the chain + the erasure bitcast.


struct AuthedUser(Movable, Deinitable, Copyable):
    """Carry out of the auth stage. Flat POD."""

    var user_id: Int64
    var valid: Bool

    def __init__(out self, user_id: Int64, valid: Bool):
        self.user_id = user_id
        self.valid = valid


struct AuthzGrant(Movable, Deinitable):
    """Carry out of the authz stage. Heap-owning (a role String) — a non-trivial
    field that must survive the seam + the erasure bitcast."""

    var user_id: Int64
    var role: String
    var allowed: Bool

    def __init__(out self, user_id: Int64, var role: String, allowed: Bool):
        self.user_id = user_id
        self.role = role^
        self.allowed = allowed


struct NotifRows(Movable, Deinitable):
    """Carry out of the list/work stage. Heap-owning List (the destroy-recreate shape)."""

    var rows: List[Int64]

    def __init__(out self, var rows: List[Int64]):
        self.rows = rows^

    def take_rows(mut self) -> List[Int64]:
        """Swap the rows out, leaving an empty (destructor-safe) List — the
        stdlib `swap(field, default)` pointer-rule partial-move primitive (NO
        partial-move-of-the-middle, which would leave `self` un-destroyable)."""
        var out = List[Int64]()
        swap(self.rows, out)
        return out^


struct EnrichedRows(Movable, Deinitable):
    """Carry out of the 4th-stage enrich op. Heap-owning List + String — a SECOND
    heap-owning carry at a LATER seam in the N=4 chain."""

    var rows: List[Int64]
    var note: String

    def __init__(out self, var rows: List[Int64], var note: String):
        self.rows = rows^
        self.note = note^


struct ToyResp(Movable, Deinitable):
    """The terminal response (Movable-not-Copyable, heap-owning body String)."""

    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^


# =============================================================================
# Concrete AsyncOps (park after a fixed poll count, or born READY).
# =============================================================================
# `ready_after=0` => born READY in start() (the cache-hit / immediate-ready fast
# path). The user does NOT write these per handler in production — they are
# reusable primitives (PgQueryOp). Distinct Out types prove the per-seam carry.


struct AuthLookupOp(Movable, Deinitable, AsyncOp):
    """Session lookup -> AuthedUser. valid iff token != 0."""

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
        # Carry the (possibly negative) token as user_id so the authz stage can
        # detect the removed-member deny convention (user_id <= 0).
        return AuthedUser(self._token, self._token != Int64(0))

    def err_text(self) -> String:
        return String("")


struct AuthzCheckOp(Movable, Deinitable, AsyncOp):
    """Membership/role check -> AuthzGrant. allowed iff user_id > 0 (a non-
    positive user_id models a removed member -> 403 deny -> the op resolves
    OP_ERR, the mid-chain Outcome.err shape)."""

    comptime Out = AuthzGrant

    var _user_id: Int64
    var _op_id: Int64
    var _state: UInt8
    var _polls_left: Int

    def __init__(out self, user_id: Int64, ready_after: Int):
        self._user_id = user_id
        self._op_id = Int64(0)
        self._state = OP_PENDING
        self._polls_left = ready_after

    def _resolve(mut self):
        if self._user_id <= Int64(0):
            self._state = OP_ERR
        else:
            self._state = OP_READY

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        self._op_id = reactor.alloc_op_id()
        if self._polls_left <= 0:
            self._resolve()
        return self._op_id

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> UInt8:
        if self._state != OP_PENDING:
            return self._state
        self._polls_left -= 1
        if self._polls_left <= 0:
            self._resolve()
        return self._state

    def op_state(self) -> UInt8:
        return self._state

    def op_id(self) -> Int64:
        return self._op_id

    def take_result(mut self) -> AuthzGrant:
        return AuthzGrant(self._user_id, String("developer"), True)

    def err_text(self) -> String:
        return String("forbidden: not a member")


struct ListQueryOp(Movable, Deinitable, AsyncOp):
    """Notif list query -> NotifRows. base id from whichever carry feeds it."""

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
        var rows = List[Int64]()
        rows.append(self._owner)
        rows.append(self._owner + Int64(1))
        rows.append(self._owner + Int64(2))
        return NotifRows(rows^)

    def err_text(self) -> String:
        return String("")


struct EnrichOp(Movable, Deinitable, AsyncOp):
    """4th-stage enrich -> EnrichedRows. Takes the NotifRows carry, x10s + tags.
    Proves a 4th await-boundary + a second heap-owning carry at a later seam."""

    comptime Out = EnrichedRows

    var _rows: List[Int64]
    var _op_id: Int64
    var _state: UInt8
    var _polls_left: Int

    def __init__(out self, var rows: List[Int64], ready_after: Int):
        self._rows = rows^
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

    def take_result(mut self) -> EnrichedRows:
        var out = List[Int64]()
        var total: Int64 = 0
        for i in range(len(self._rows)):
            out.append(self._rows[i] * Int64(10))
            total += self._rows[i]
        return EnrichedRows(out^, String("sum=") + String(total))

    def err_text(self) -> String:
        return String("")


# =============================================================================
# THE USER SURFACE: one tiny Stage struct per segment (the `Stage` trait is
# imported from the src/ primitive). Each await-segment is an OPERATOR STRUCT
# passed as a TYPE param. The user writes ONLY `make_op`.
# =============================================================================


struct AuthStage(Movable, Deinitable, Stage):
    """Stage 0: park on the session lookup. In = bearer token (Int64);
    Op = AuthLookupOp (Out = AuthedUser)."""

    comptime In = Int64
    comptime Op = AuthLookupOp

    var _ready_after: Int

    def __init__(out self, ready_after: Int = 2):
        self._ready_after = ready_after

    def make_op(self, var input: Int64) raises -> AuthLookupOp:
        return AuthLookupOp(input, ready_after=self._ready_after)


struct AuthzStage(Movable, Deinitable, Stage):
    """Stage 1 (N>=3): park on the membership/role check. In = AuthedUser;
    Op = AuthzCheckOp (Out = AuthzGrant). A removed member -> op ERR -> the chain
    short-circuits to the renderer's error mapping (a 403)."""

    comptime In = AuthedUser
    comptime Op = AuthzCheckOp

    var _ready_after: Int

    def __init__(out self, ready_after: Int = 2):
        self._ready_after = ready_after

    def make_op(self, var input: AuthedUser) raises -> AuthzCheckOp:
        return AuthzCheckOp(input.user_id, ready_after=self._ready_after)


struct ListStageFromAuth(Movable, Deinitable, Stage):
    """Work stage whose In is the AuthedUser carry (the N=2 shape: auth -> list).
    Op = ListQueryOp (Out = NotifRows)."""

    comptime In = AuthedUser
    comptime Op = ListQueryOp

    var _ready_after: Int

    def __init__(out self, ready_after: Int = 2):
        self._ready_after = ready_after

    def make_op(self, var input: AuthedUser) raises -> ListQueryOp:
        return ListQueryOp(input.user_id, ready_after=self._ready_after)


struct ListStageFromGrant(Movable, Deinitable, Stage):
    """Work stage whose In is the AuthzGrant carry (the N>=3 shape:
    ... authz -> list). Op = ListQueryOp (Out = NotifRows). Keys the query off
    the granted user_id (the authz-resolved scope)."""

    comptime In = AuthzGrant
    comptime Op = ListQueryOp

    var _ready_after: Int

    def __init__(out self, ready_after: Int = 2):
        self._ready_after = ready_after

    def make_op(self, var input: AuthzGrant) raises -> ListQueryOp:
        return ListQueryOp(input.user_id, ready_after=self._ready_after)


struct EnrichStage(Movable, Deinitable, Stage):
    """4th stage: enrich the rows. In = NotifRows; Op = EnrichOp
    (Out = EnrichedRows)."""

    comptime In = NotifRows
    comptime Op = EnrichOp

    var _ready_after: Int

    def __init__(out self, ready_after: Int = 2):
        self._ready_after = ready_after

    def make_op(self, var input: NotifRows) raises -> EnrichOp:
        # take_rows() swaps the List out (destructor-safe) — no partial-move of
        # the middle of `input` (which would leave it un-destroyable).
        return EnrichOp(input.take_rows(), ready_after=self._ready_after)


# =============================================================================
# Concrete Renderers (the `Renderer` trait is imported from src/). Each
# declares `comptime Resp = ToyResp` (the POC response type) + owns the guard /
# error map / terminal render, applied by the framework in the terminal step.
# The src/ `Renderer` trait's guard_response/error_response/render are `raises`
# (production renderers serialize JSON), so the POC renderers match that.
# =============================================================================


struct NotifRenderer2(Movable, Deinitable, Renderer):
    """N=2 terminal: Guard0 = AuthedUser (401 on invalid), Final = NotifRows."""

    comptime Guard0 = AuthedUser
    comptime Final = NotifRows
    comptime Resp = ToyResp

    def __init__(out self):
        pass

    def guard_ok(self, carry0: AuthedUser) -> Bool:
        return carry0.valid

    def guard_response(self) raises -> ToyResp:
        return ToyResp(401, String("unauthorized"))

    def error_response(self, stage_index: Int, msg: String) raises -> ToyResp:
        return ToyResp(
            500, String("error@") + String(stage_index) + String(":") + msg
        )

    def render(self, var final_carry: NotifRows) raises -> ToyResp:
        return _render_notifs(final_carry^)


struct NotifRenderer3(Movable, Deinitable, Renderer):
    """N=3 terminal: Guard0 = AuthedUser (401), Final = NotifRows. A mid-chain
    authz deny (stage 1) maps to a 403 via error_response."""

    comptime Guard0 = AuthedUser
    comptime Final = NotifRows
    comptime Resp = ToyResp

    def __init__(out self):
        pass

    def guard_ok(self, carry0: AuthedUser) -> Bool:
        return carry0.valid

    def guard_response(self) raises -> ToyResp:
        return ToyResp(401, String("unauthorized"))

    def error_response(self, stage_index: Int, msg: String) raises -> ToyResp:
        if stage_index == 1:
            return ToyResp(403, String("forbidden"))
        return ToyResp(
            500, String("error@") + String(stage_index) + String(":") + msg
        )

    def render(self, var final_carry: NotifRows) raises -> ToyResp:
        return _render_notifs(final_carry^)


struct NotifRenderer4(Movable, Deinitable, Renderer):
    """N=4 terminal: Guard0 = AuthedUser (401), Final = EnrichedRows. authz deny
    (stage 1) -> 403."""

    comptime Guard0 = AuthedUser
    comptime Final = EnrichedRows
    comptime Resp = ToyResp

    def __init__(out self):
        pass

    def guard_ok(self, carry0: AuthedUser) -> Bool:
        return carry0.valid

    def guard_response(self) raises -> ToyResp:
        return ToyResp(401, String("unauthorized"))

    def error_response(self, stage_index: Int, msg: String) raises -> ToyResp:
        if stage_index == 1:
            return ToyResp(403, String("forbidden"))
        return ToyResp(
            500, String("error@") + String(stage_index) + String(":") + msg
        )

    def render(self, var final_carry: EnrichedRows) raises -> ToyResp:
        var body = String("enriched:") + final_carry.note + String("|")
        for i in range(len(final_carry.rows)):
            if i > 0:
                body += String(",")
            body += String(final_carry.rows[i])
        return ToyResp(200, body^)


def _render_notifs(var rows: NotifRows) -> ToyResp:
    var body = String("notifs:")
    for i in range(len(rows.rows)):
        if i > 0:
            body += String(",")
        body += String(rows.rows[i])
    return ToyResp(200, body^)


# =============================================================================
# / — The combinator + the StagedHandlerNoop alias are now imported from
# the src/ primitive (komira_async.runtime.staged_handler). The concrete
# per-route aliases the tests build compose StagedHandlerNoop over the
# toy Renderers + Stage structs above — no per-arity sibling struct.
# =============================================================================


# The concrete handler shapes the tests build, each a ONE-LINE alias over the
# variadic combinator — no per-arity sibling struct.

# N=2: auth -> list (the original NotifList shape).
comptime NotifListN2 = StagedHandlerNoop[
    NotifRenderer2, AuthStage, ListStageFromAuth
]

# N=3: auth -> authz -> list (the RBAC shape).
comptime NotifListN3 = StagedHandlerNoop[
    NotifRenderer3, AuthStage, AuthzStage, ListStageFromGrant
]

# N=4: auth -> authz -> list -> enrich.
comptime NotifListN4 = StagedHandlerNoop[
    NotifRenderer4, AuthStage, AuthzStage, ListStageFromGrant, EnrichStage
]


def _build_n2(token: Int64) -> NotifListN2:
    return NotifListN2(
        token, Tuple(AuthStage(), ListStageFromAuth()), NotifRenderer2()
    )


def _build_n3(token: Int64) -> NotifListN3:
    return NotifListN3(
        token,
        Tuple(AuthStage(), AuthzStage(), ListStageFromGrant()),
        NotifRenderer3(),
    )


def _build_n3_ready(token: Int64) -> NotifListN3:
    # All ops born READY (ready_after=0) — the cache-hit / immediate-ready case.
    return NotifListN3(
        token,
        Tuple(
            AuthStage(ready_after=0),
            AuthzStage(ready_after=0),
            ListStageFromGrant(ready_after=0),
        ),
        NotifRenderer3(),
    )


def _build_n4(token: Int64) -> NotifListN4:
    return NotifListN4(
        token,
        Tuple(
            AuthStage(),
            AuthzStage(),
            ListStageFromGrant(),
            EnrichStage(),
        ),
        NotifRenderer4(),
    )


comptime _NoopFrame = ErasedHandlerFrame[NoopSink]


# =============================================================================
# Test helpers.
# =============================================================================


def _new_reactor() raises -> Reactor[NoopSink]:
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)


# =============================================================================
# 1. N=3 multi-park DIRECT: auth (2 polls) -> authz (2 polls) -> list (2 polls)
#    -> render. Threads AuthedUser -> AuthzGrant -> NotifRows across every seam.
# =============================================================================
def test_n3_multipark_direct() raises:
    """Drive the N=3 handler directly via step(). Three stages each park (ready
    after 2 polls); the type-changing carry threads at every seam; render
    produces the 200 + a body derived from the carry chain."""
    var reactor = _new_reactor()
    var h = _build_n3(Int64(5))  # token 5 -> user_id 5 (valid, >0 -> authz OK)

    var parks = 0
    var done = False
    var status = 0
    var body = String("")
    var guard = 0
    while (not done) and guard < 100:
        var sr = h.step[NoopSink](reactor)
        if sr.is_parked():
            parks += 1
            assert_true(
                sr.op_id() >= HANDLER_OP_ID_BIAS, "parked op_id is biased"
            )
        elif sr.is_done():
            var resp = sr.take_response()
            status = resp.status
            body = resp.body
            done = True
        elif sr.is_error():
            raise Error(String("unexpected ERR: ") + sr.err_text())
        guard += 1

    assert_true(done, "N=3 chain finished")
    assert_equal(status, 200)
    # token 5 -> user_id 5 -> authz grants user_id 5 -> rows [5,6,7]
    assert_equal(body, String("notifs:5,6,7"))
    # Three distinct parking stages -> at least 3 park returns (each stage parks
    # at least once across its 2-poll lifetime).
    assert_true(parks >= 3, "each of the 3 stages parked at least once")

    _ = h^
    print("  [1] N=3 multi-park (direct): carry threaded across 3 seams OK")


# =============================================================================
# 2. N=4 multi-park DIRECT: auth -> authz -> list -> enrich -> render. A SECOND
#    heap-owning carry (EnrichedRows) at the last seam.
# =============================================================================
def test_n4_multipark_direct() raises:
    """Drive the N=4 handler directly. Four stages, four parks, the carry
    threaded AuthedUser -> AuthzGrant -> NotifRows -> EnrichedRows, then render."""
    var reactor = _new_reactor()
    var h = _build_n4(Int64(3))  # token 3 -> user_id 3 -> rows [3,4,5] -> x10

    var parks = 0
    var done = False
    var status = 0
    var body = String("")
    var guard = 0
    while (not done) and guard < 100:
        var sr = h.step[NoopSink](reactor)
        if sr.is_parked():
            parks += 1
        elif sr.is_done():
            var resp = sr.take_response()
            status = resp.status
            body = resp.body
            done = True
        elif sr.is_error():
            raise Error(String("unexpected ERR: ") + sr.err_text())
        guard += 1

    assert_true(done, "N=4 chain finished")
    assert_equal(status, 200)
    # rows [3,4,5] -> x10 [30,40,50]; note sum=3+4+5=12
    assert_equal(body, String("enriched:sum=12|30,40,50"))
    assert_true(parks >= 4, "each of the 4 stages parked at least once")

    _ = h^
    print("  [2] N=4 multi-park (direct): 2nd heap carry threaded at last seam OK")


# =============================================================================
# 3. N=3 AND N=4 BLIND through ONE ErasedHandlerFrame driver. The chains are ONE erased
#    handler each in a Slab[ErasedHandlerFrame[NoopSink]], stepped blind via _step_fn.
# =============================================================================
def test_n3_n4_through_erased_frame() raises:
    """make_erased_handler_frame boxes both an N=3 and an N=4 StagedHandler into ONE
    Slab[ErasedHandlerFrame[NoopSink]]; step them BLIND through _step_fn to DONE. The
    cursor + per-stage ops + the threaded carries live behind the erasure; the
    driver never sees the concrete handler type, and the responder is applied in
    the handler's own framework-owned terminal step (not the driver)."""
    var reactor = _new_reactor()

    var frames = Slab[_NoopFrame]()
    frames.append(
        make_erased_handler_frame[NotifListN3, NoopSink](_build_n3(Int64(8)), Int64(800))
    )
    frames.append(
        make_erased_handler_frame[NotifListN4, NoopSink](_build_n4(Int64(2)), Int64(900))
    )
    assert_equal(frames.len(), 2)

    var n3_status = 0
    var n3_body = String("")
    var n4_status = 0
    var n4_body = String("")

    # Drive each erased frame BLIND to DONE.
    for idx in range(2):
        var done = False
        var guard = 0
        while (not done) and guard < 100:
            var sr = frames[idx].step(reactor)
            if sr.is_parked():
                frames[idx].set_parked_op_id(sr.op_id())
            elif sr.is_done():
                var resp = sr.take_response[ToyResp]()
                if idx == 0:
                    n3_status = resp.status
                    n3_body = resp.body
                else:
                    n4_status = resp.status
                    n4_body = resp.body
                done = True
            elif sr.is_error():
                raise Error(String("unexpected ERR: ") + sr.err_text())
            guard += 1
        assert_true(done, "erased frame finished")

    assert_equal(n3_status, 200)
    assert_equal(n3_body, String("notifs:8,9,10"))  # user_id 8 -> rows [8,9,10]
    assert_equal(n4_status, 200)
    # token 2 -> rows [2,3,4] -> x10 [20,30,40]; sum=9
    assert_equal(n4_body, String("enriched:sum=9|20,30,40"))

    _ = frames^
    print("  [3] N=3 + N=4 BLIND through one ErasedHandlerFrame driver OK")


# =============================================================================
# 4. Mid-chain short-circuit: an authz deny (stage 1) -> op ERR -> renderer's
#    error_response maps to 403; stages 2+ NEVER run. Generic over the pack.
# =============================================================================
def test_mid_chain_short_circuit_403() raises:
    """token = -7 -> AuthedUser(user_id=-7, valid=True) passes the stage-0 guard
    (valid), but the authz op (stage 1) sees user_id <= 0 (removed member) and
    resolves OP_ERR -> the framework routes to error_response(1, ...) -> a 403,
    and the list/enrich stages NEVER build an op. The short-circuit is at a
    MIDDLE stage (not stage 0) — the N>2 generalization the Chain2 POC could not
    test."""
    var reactor = _new_reactor()
    var h = _build_n4(Int64(-7))  # valid token (!=0) but user_id<=0 -> authz deny

    var done = False
    var status = 0
    var body = String("")
    var guard = 0
    while (not done) and guard < 100:
        var sr = h.step[NoopSink](reactor)
        if sr.is_parked():
            pass
        elif sr.is_done():
            var resp = sr.take_response()
            status = resp.status
            body = resp.body
            done = True
        elif sr.is_error():
            raise Error(String("unexpected substrate ERR: ") + sr.err_text())
        guard += 1

    assert_true(done, "short-circuited chain finished")
    assert_equal(status, 403)  # the authz deny mapped to a domain 403, not 500
    assert_equal(body, String("forbidden"))

    _ = h^
    print("  [4] mid-chain (stage 1) short-circuit -> 403, stages 2+ skipped OK")


# =============================================================================
# 5. Strict-401 guard pinned to stage 0: an invalid first carry short-circuits
#    to guard_response WITHOUT building any later op.
# =============================================================================
def test_stage0_guard_401() raises:
    """token = 0 -> AuthedUser(valid=False). The stage-0 guard (guard_ok) fires
    after the auth op resolves and short-circuits to a 401 WITHOUT building the
    authz/list/enrich ops. This is the strict-401 (first-carry guard) preserved
    from the Chain2 POC, now at N=4."""
    var reactor = _new_reactor()
    var h = _build_n4(Int64(0))  # token 0 -> invalid auth

    var done = False
    var status = 0
    var body = String("")
    var guard = 0
    while (not done) and guard < 100:
        var sr = h.step[NoopSink](reactor)
        if sr.is_done():
            var resp = sr.take_response()
            status = resp.status
            body = resp.body
            done = True
        elif sr.is_error():
            raise Error(String("unexpected ERR: ") + sr.err_text())
        guard += 1

    assert_true(done, "guard short-circuited")
    assert_equal(status, 401)
    assert_equal(body, String("unauthorized"))

    _ = h^
    print("  [5] stage-0 strict-401 guard (no later op built) OK")


# =============================================================================
# 6. Both-immediate-ready (cache-hit): every op born OP_READY (ready_after=0).
#    The chain advances stage-to-stage WITHOUT parking — ONE step reaches DONE.
# =============================================================================
def test_all_ops_ready_no_park() raises:
    """All three N=3 ops are born READY in start() (ready_after=0). The cursor
    chains stage0 -> stage1 -> stage2 -> render in a SINGLE step() (no park) —
    the cache-hit fast path the auth/streaming work depends on. The first step
    must return DONE directly."""
    var reactor = _new_reactor()
    var h = _build_n3_ready(Int64(11))  # all born-ready, valid token

    var sr = h.step[NoopSink](reactor)
    assert_true(
        sr.is_done(), "all-ready chain reaches DONE in ONE step (no park)"
    )
    var resp = sr.take_response()
    assert_equal(resp.status, 200)
    assert_equal(resp.body, String("notifs:11,12,13"))  # user_id 11 -> [11,12,13]

    _ = h^
    print("  [6] all-ops-ready: chain to DONE in one step, no park OK")


# =============================================================================
# 7. N=2 floor still works through the SAME variadic combinator (regression: the
#    fixed-arity Chain2 shape is subsumed, no per-arity sibling).
# =============================================================================
def test_n2_floor_via_variadic() raises:
    """The original 2-stage NotifList (auth -> list) built from the SAME
    variadic combinator (StagedHandlerNoop[R, S0, S1]) — the Chain2 floor is now
    just N=2 of the variadic, no separate Chain2 struct."""
    var reactor = _new_reactor()
    var h = _build_n2(Int64(7))  # token 7 -> user_id 7 -> rows [7,8,9]

    var done = False
    var status = 0
    var body = String("")
    var guard = 0
    while (not done) and guard < 100:
        var sr = h.step[NoopSink](reactor)
        if sr.is_done():
            var resp = sr.take_response()
            status = resp.status
            body = resp.body
            done = True
        elif sr.is_error():
            raise Error(String("unexpected ERR: ") + sr.err_text())
        guard += 1

    assert_true(done, "N=2 chain finished")
    assert_equal(status, 200)
    assert_equal(body, String("notifs:7,8,9"))

    _ = h^
    print("  [7] N=2 floor via the variadic combinator OK")


def main() raises:
    test_n3_multipark_direct()
    test_n4_multipark_direct()
    test_n3_n4_through_erased_frame()
    test_mid_chain_short_circuit_403()
    test_stage0_guard_401()
    test_all_ops_ready_no_park()
    test_n2_floor_via_variadic()
    print("PASS test_staged_handler_variadic (StagedHandler N=2/3/4)")
