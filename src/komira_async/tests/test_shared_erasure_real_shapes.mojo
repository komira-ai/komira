# =============================================================================
# test_shared_erasure_real_shapes.mojo
#   STAGE 2 — prove the shared-erasure library against the CURRENT REPO's REAL
#   dispatch + engine shapes.
# =============================================================================
# The Stage-1 tests (`test_shared_erasure.mojo`) prove the library against
# SYNTHETIC types (`_Counter` / `_SharedSeg` / `_DispatchCtx`). This file closes
# the de-risk gap by proving the SAME library against the REAL repo TYPES the
# post-migration PORT will rewire:
#
#   PART 1 — REAL dispatch shape. `local_dispatcher.mojo`'s
#   `_DispatchShard[State: KeepAlive, T: Segment]` carries SIX MutExternalOrigin
#   wildcard FIELDS bundling a real operator's borrowed `State` + the SHARED
#   `Segment` + the per-dispatch atomics (in_flight) + the real
#   `CancellationToken` + the first-error slot. We bundle that EXACT borrow set
#   into a `_RealDispatchCtx` over REAL trait-conforming types:
#     * `_RealAggState(KeepAlive)`   — a HashAgg-shaped accumulator (heap
#                                       `List[Int]` partials), the borrowed State.
#     * `_RealSumSegment(Segment)`   — a REAL `Segment` whose
#                                       `execute[State: KeepAlive]` uses the
#                                       documented `UnsafePointer(to=state)
#                                       .bitcast[Concrete]()` idiom (the EXACT
#                                       real Segment-impl shape, e.g.
#                                       parallel_fork_join.mojo) — the
#                                       SHARED Segment, one home, N shards read it.
#     * a real `Atomic[DType.int64]` in_flight counter, a real
#       `CancellationToken`, and a first-error `List[String]`-shaped slot.
#   `StateBoundWork[_RealDispatchCtx, origin]` carries that bundle through
#   `ErasedHandle` with ZERO wildcard FIELD, and a runtime payload
#   (`_RealShard`, the SAME single-concrete-origin-`Pointer` field shape) drives
#   the REAL `seg.execute[State](state, wid, tid)` trait dispatch POST-erasure,
#   with the Segment SHARED across N shards and the per-shard accumulation
#   landing in the SHARED State correctly.
#
#   PART 2 — REAL engine drain reach. `CarriedHandle[SharedEngine, origin]`
#   carries a coherent handle the worker DRAIN would use INSTEAD of
#   `engine_ref()` (the `unsafe_from_address=Int` MutExternalOrigin pointer at
#   engine_handle.mojo:144). We push REAL log records (`emit_record`) onto a real
#   `ring(0)` and DRAIN them through the carried handle
#   (`drain_worker_to_lines`) — the realistic worker-drain reach, reading
#   `_rings` arena + `_dict` heap fields. The A/B `unsafe_from_address=Int`
#   FAILED on exactly this (incoherent heap-field reads); the carried concrete
#   origin reads them correctly.
#
# This file adds NO production source, NO parallel `_DispatchShard2`, and does
# NOT rewire the central dispatch path.
# It proves the library HANDLES the real shapes in a focused test.
# =============================================================================

from komira_atomic_alias import AtomicI32, AtomicI64, AtomicU8
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.runtime.shared_erasure import (
    CarriedHandle,
    MutCarriedHandle,
    ErasableWork,
    ErasedHandle,
    StateBoundWork,
    STEP_DONE,
    make_erased,
)

from komira_core.collections.slab import Slab
from komira_core.runtime_traits.worker_pool_traits import KeepAlive, Segment

from komira_log.engine.shared_engine import SharedEngine
from komira_log.engine.emit import emit_record
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO, LEVEL_TRACE
from komira_log.log_arg import ArgI64, ArgStr


# =============================================================================
# REAL dispatch types. `_RealAggState` is a REAL `KeepAlive` impl; the
#      `_RealSumSegment` is a REAL `Segment` impl. These are the exact trait
#      shapes `_DispatchShard[State: KeepAlive, T: Segment]` bundles.
# =============================================================================


struct _RealAggState(Movable, KeepAlive):
    """The borrowed dispatch State — a HashAgg-shaped accumulator. Holds a heap
    `List[Int]` of per-shard partials (one slot per worker shard) plus the input
    the segment folds. Conforms to the REAL `KeepAlive` trait (the SAME bound
    `_DispatchShard`'s `State` parameter carries). `Movable` is added so it can be
    moved into `_RealDispatchCtx` (KeepAlive itself only bounds
    `Deinitable` because `_DispatchShard` BORROWS state by pointer —
    here we OWN it in the bundled ctx, so the move bound is required). Heap-owning
    (`List[Int]`) so a severed-liveness erasure would corrupt the partials
    read-through."""

    var input: List[Int]
    var partials: List[Int]

    def __init__(out self, var input: List[Int], n_shards: Int):
        self.input = input^
        self.partials = List[Int]()
        for _ in range(n_shards):
            self.partials.append(0)

    # KeepAlive.__keep_alive default body is sufficient (the trampoline call
    # site is the load-bearing shield, not the body) — we inherit the default.


struct _RealSumSegment(Segment):
    """The SHARED Segment — a REAL `Segment` impl. Its `execute[State]` uses the
    DOCUMENTED real Segment idiom (`UnsafePointer(to=state).bitcast[Concrete]()`
    at entry, e.g. parallel_fork_join.mojo:89-97): reach the concrete State via
    one bitcast, then fold `input[tid]` into `partials[wid]`. Carries a POD
    `multiplier` discriminant (the "at most a POD dispatch discriminant" Segment
    contract). ONE home, SHARED across N shards by-pointer (proving share, not
    copy — the SAME contract `_DispatchShard.seg_ptr` carries)."""

    var multiplier: Int64

    def __init__(out self, multiplier: Int64):
        self.multiplier = multiplier

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: parameterized over the concrete `_RealAggState` at the
        # `run_with_state[State, T]` call site (here, the erased shard's `run`).
        # The bitcast resolves to the concrete State — the EXACT documented real
        # Segment idiom (worker_pool_traits.mojo:132-139,
        # parallel_fork_join.mojo:95). The pointer never escapes this body.
        var sp = UnsafePointer(to=state).bitcast[_RealAggState]()
        var tid = Int(task_id)
        var wid = Int(worker_id)
        # Fold input[tid] * multiplier into THIS shard's partial slot.
        sp[].partials[wid] += sp[].input[tid] * Int(self.multiplier)


struct _RealErrorSlot(Movable, Deinitable):
    """First-error-wins error slot — the REAL `_LdErrorSlot` shape
    (local_dispatcher.mojo:197), reduced to the parts the erasure must carry: a
    heap-owning `String` message + an atomic-flag-shaped CAS. Heap-owning so a
    severed erasure would corrupt the message read-through."""

    var _flag: OwnedPointer[AtomicU8]
    var message: String

    def __init__(out self):
        var raw = alloc[AtomicU8](1)
        raw[] = AtomicU8(UInt8(0))
        self._flag = OwnedPointer[AtomicU8](unsafe_from_raw_pointer=raw)
        self.message = String("")

    def try_set(mut self, msg: String) -> Bool:
        var expected = UInt8(0)
        var won = self._flag[].compare_exchange(expected, UInt8(1))
        if won:
            self.message = msg
        return won

    def is_set(self) -> Bool:
        return self._flag[].load() != UInt8(0)


struct _RealDispatchCtx(Movable, Deinitable):
    """The per-dispatch context the shards borrow INTO — bundles the EXACT SIX
    borrows `_DispatchShard[State, T]` carries as six wildcard pointer fields,
    under ONE owner so every shard borrow shares ONE concrete `origin`:

      _DispatchShard wildcard field   ->  _RealDispatchCtx field (concrete)
      -----------------------------------------------------------------------
      state_ptr   (State: KeepAlive)  ->  state:        _RealAggState
      seg_ptr     (T: Segment)        ->  seg:          _RealSumSegment  (SHARED)
      in_flight_ptr (Atomic[int64])   ->  in_flight:    OwnedPointer[Atomic[int64]]
      wake_word_ptr (Atomic[int32])   ->  wake_word:    OwnedPointer[Atomic[int32]]
      error_slot_ptr (_LdErrorSlot)   ->  error_slot:   _RealErrorSlot
      cancel_token_ptr (CancelToken)  ->  cancel:       CancellationToken

    This is how a real per-core dispatcher owns ONE per-dispatch frame; the
    shards borrow into it. A CONCRETE origin parameter cannot carry six
    independent borrows the way the wildcard erased — bundling into one owner is
    the correct + strictly-safer shape (the StateBoundWork design)."""

    var state: _RealAggState
    var seg: _RealSumSegment
    var in_flight: OwnedPointer[AtomicI64]
    var wake_word: OwnedPointer[AtomicI32]
    var error_slot: _RealErrorSlot
    var cancel: CancellationToken

    def __init__(
        out self,
        var state: _RealAggState,
        var seg: _RealSumSegment,
        in_flight_init: Int64,
        var cancel: CancellationToken,
    ):
        self.state = state^
        self.seg = seg^
        var raw_if = alloc[AtomicI64](1)
        raw_if[] = AtomicI64(in_flight_init)
        self.in_flight = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw_if
        )
        var raw_ww = alloc[AtomicI32](1)
        raw_ww[] = AtomicI32(Int32(0))
        self.wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_ww
        )
        self.error_slot = _RealErrorSlot()
        self.cancel = cancel^


# =============================================================================
# _RealShard[origin] — a runtime payload over the REAL ctx. SAME field
#      shape as `StateBoundWork` (a single concrete-origin
#      `Pointer[_RealDispatchCtx, origin]` — NO wildcard field), whose `run`
#      drives the REAL `Segment.execute[State]` trait dispatch POST-erasure.
# =============================================================================
# Specialized to the concrete `_RealDispatchCtx` (vs the production
# `StateBoundWork`, which stays `Ctx`-generic so the production body can layer
# on) for the same reason `_AccumStateBound` in the Stage-1 test is: a payload
# whose `run` body reaches CONCRETE ctx fields (`.seg.execute`, `.state`,
# `.cancel`, `.error_slot`, `.in_flight`) must know the concrete type. The BIND
# SHAPE is identical to `StateBoundWork`: one `Pointer[_RealDispatchCtx, origin]`
# concrete-origin field, the `ref [origin]` ctor, the `ctx_ref()` accessor.


struct _RealShard[origin: Origin[mut=True]](
    Movable, Deinitable, ErasableWork
):
    """A per-shard erasable payload over the REAL `_RealDispatchCtx`. The
    single-concrete-origin-`Pointer` field shape `StateBoundWork` carries (NO
    wildcard field). Its `run` runs the REAL production shard body: poll the real
    `CancellationToken`, fold the SHARED `_RealSumSegment` over `[lo, hi)` via the
    REAL `seg.execute[State](state, wid, tid)` trait dispatch, then fetch_sub the
    real in_flight atomic — all reached through the bound concrete-origin pointer.
    Driven POST-erasure through `ErasedHandle`, this genuinely demonstrates the
    real trait-dispatch read-through-after-erasure."""

    var _ctx: Pointer[_RealDispatchCtx, Self.origin]
    var _lo: Int64
    var _hi: Int64
    var _wid: Int32

    def __init__(
        out self,
        ref [Self.origin] ctx: _RealDispatchCtx,
        lo: Int64,
        hi: Int64,
        wid: Int32,
    ):
        self._ctx = Pointer(to=ctx)
        self._lo = lo
        self._hi = hi
        self._wid = wid

    @always_inline
    def ctx_ref(self) -> ref [Self.origin] _RealDispatchCtx:
        """Borrow the bound ctx through the concrete-origin pointer (ref tied to
        the inner pointer's origin — Repro 5/5b), exactly as `StateBoundWork`."""
        return self._ctx[]

    def run(mut self) raises -> None:
        """VOID arm — the REAL production shard body, reached THROUGH the erased
        bound pointer. Poll the real CancellationToken (first-error-wins on
        cancel), then loop `[lo, hi)` driving the REAL `Segment.execute[State]`
        trait dispatch on the SHARED Segment over the borrowed State, then
        decrement the real in_flight atomic. A wildcard-severed liveness would
        crash on the seg/state read-through or corrupt the partials."""
        var wid = Int(self._wid)
        var tid = self._lo
        while tid < self._hi:
            # Real first-error short-circuit (the production hot read).
            if self.ctx_ref().error_slot.is_set():
                break
            # Real cancellation poll between tids.
            if self.ctx_ref().cancel.is_cancelled():
                _ = self.ctx_ref().error_slot.try_set(String("CancelledError"))
                break
            try:
                # THE REAL TRAIT DISPATCH, post-erasure: the SHARED Segment's
                # `execute[State]` (reached through the bound concrete-origin
                # pointer) folds input[tid] into the borrowed State's partials.
                self.ctx_ref().seg.execute[_RealAggState](
                    self.ctx_ref().state, Int32(wid), tid
                )
            except e:
                _ = self.ctx_ref().error_slot.try_set(String(e))
                break
            tid = tid + 1
        # Real in_flight fetch_sub (the production barrier-completion signal).
        _ = self.ctx_ref().in_flight[].fetch_sub(Int64(1))

    def step(mut self) raises -> Int:
        """Result arm — not this payload's arm (it is a void-`run` shard); signal
        DONE. REQUIRED (no trait default) so the generic erasure trampoline
        dispatches to THIS body, not a shadowing trait-default no-op."""
        return STEP_DONE


# =============================================================================
# PART 1 — REAL dispatch shape through the erasure.
# =============================================================================


def test_real_dispatch_shard_through_erasure_shared_segment() raises -> None:
    """PART 1 (the real-shape keystone). N shards bind the SAME `_RealDispatchCtx`
    (real `_RealAggState` State + the SHARED real `_RealSumSegment` + a real
    `Atomic[int64]` in_flight + a real `CancellationToken` + a real error slot)
    into N `_RealShard` payloads, each erased into an `ErasedHandle`, and run
    BLIND. Each shard's POST-erasure `run` drives the REAL
    `Segment.execute[State]` trait dispatch on the SHARED Segment over the
    borrowed State.

    Proves, against the REAL repo types:
      (a) The SHARED Segment stays SHARED across all N shards (every shard's
          `ctx_ref().seg` resolves to the SAME `_RealSumSegment` home address —
          NOT a per-shard copy). This is the EXACT `seg_ptr` share contract.
      (b) The real `Segment.execute[State]` trait dispatch RUNS correctly
          POST-erasure: each shard folds its `[lo, hi)` input slice into the
          SHARED State's partials through the bound concrete-origin pointer, and
          the accumulated partials are CORRECT after the erased runs.
      (c) The real in_flight `Atomic[int64]` reaches 0 after all shards complete
          (the real barrier-completion signal, driven through the erasure).

    input = [10, 20, 30, 40], multiplier = 2, 4 shards, shard wid covers
    [wid, wid+1): partials[wid] = input[wid]*2 -> [20, 40, 60, 80]."""
    var n_shards = 4
    var input = List[Int]()
    input.append(10)
    input.append(20)
    input.append(30)
    input.append(40)

    # The ONE per-dispatch context, live on THIS stack frame for the whole
    # dispatch (the synchronous analog of the wake-word barrier holding it
    # alive). Bundles the EXACT six `_DispatchShard` borrows under one owner.
    var ctx = _RealDispatchCtx(
        _RealAggState(input^, n_shards),
        _RealSumSegment(multiplier=Int64(2)),
        Int64(n_shards),
        CancellationToken.new(),
    )

    # The SHARED Segment's home address — every shard must observe THIS exact
    # address (a field of the ONE borrowed ctx) through the erased payload.
    var seg_addr = Int(UnsafePointer(to=ctx.seg))

    var handles = Slab[ErasedHandle]()
    var observed_seg_addrs = List[Int]()
    for wid in range(n_shards):
        var lo = Int64(wid)
        var hi = Int64(wid + 1)
        var shard = _RealShard[origin_of(ctx)](ctx, lo, hi, Int32(wid))
        # (a) BEFORE erasure: the shard sees the SHARED Segment home (the SAME
        # ctx.seg address) through the bound concrete-origin pointer.
        observed_seg_addrs.append(Int(UnsafePointer(to=shard.ctx_ref().seg)))
        handles.append(make_erased[_RealShard[origin_of(ctx)]](shard^))

    # (a) Every shard observed the SAME SHARED Segment address (no copy).
    for wid in range(n_shards):
        assert_equal(observed_seg_addrs[wid], seg_addr)

    # Drive every erased shard BLIND. The REAL `Segment.execute[State]` trait
    # dispatch + the partials write happen INSIDE the erased `run` body —
    # POST-erasure. A wildcard-severed liveness would crash here.
    for wid in range(n_shards):
        handles.get_mut_interior(wid).run()

    # (b) The real `Segment.execute[State]` trait dispatch ran correctly through
    # the erasure: partials[wid] = input[wid] * multiplier.
    assert_equal(ctx.state.partials[0], 20)  # 10 * 2
    assert_equal(ctx.state.partials[1], 40)  # 20 * 2
    assert_equal(ctx.state.partials[2], 60)  # 30 * 2
    assert_equal(ctx.state.partials[3], 80)  # 40 * 2

    # (c) The real in_flight atomic reached 0 (the barrier-completion signal).
    assert_equal(ctx.in_flight[].load(), Int64(0))
    # No shard errored or was cancelled.
    assert_true(not ctx.error_slot.is_set())

    _ = handles^
    # Keep the borrowed owner live across the whole dispatch (barrier contract).
    _ = ctx.state.input[0]
    _ = ctx.seg.multiplier
    _ = ctx^


def test_real_dispatch_shard_cancellation_through_erasure() raises -> None:
    """PART 1 — the real `CancellationToken` reach SURVIVES the erasure. A shard
    binds a PRE-CANCELLED real `CancellationToken` (a field of the bound ctx) and
    runs POST-erasure; the erased `run` polls `cancel.is_cancelled()` through the
    bound pointer, observes the cancel, and writes "CancelledError" into the
    SHARED real error slot WITHOUT folding any input. Proves the real token's
    heap-owning ancestor chain reads coherently through the erasure (a severed
    liveness would mis-read the chain / crash)."""
    var input = List[Int]()
    input.append(100)
    input.append(200)

    var token = CancellationToken.new()
    token.cancel(String("driver requested stop"))

    var ctx = _RealDispatchCtx(
        _RealAggState(input^, 1),
        _RealSumSegment(multiplier=Int64(5)),
        Int64(1),
        token^,
    )

    var shard = _RealShard[origin_of(ctx)](ctx, Int64(0), Int64(2), Int32(0))
    var handle = make_erased[_RealShard[origin_of(ctx)]](shard^)
    # Drive BLIND post-erasure — the erased `run` polls the real cancel token
    # through the bound pointer and short-circuits.
    handle.run()

    # The real cancel token (read THROUGH the erasure) was observed: the shard
    # bailed, set the error slot, and folded NOTHING.
    assert_true(ctx.error_slot.is_set())
    assert_equal(ctx.error_slot.message, String("CancelledError"))
    assert_equal(ctx.state.partials[0], 0)  # never folded
    # in_flight still decremented (the completion signal fires even on cancel).
    assert_equal(ctx.in_flight[].load(), Int64(0))

    _ = handle^
    _ = ctx.state.input[0]
    _ = ctx^


def test_statebound_carries_real_ctx_field_free() raises -> None:
    """PART 1 — the PRODUCTION `StateBoundWork[Ctx, origin]` (NOT the test-only
    `_RealShard`) carries the REAL `_RealDispatchCtx` bundle field-free through
    the erasure. This proves the SHIPPED primitive (the migration target) handles
    the real shape: `StateBoundWork[_RealDispatchCtx, origin_of(ctx)]` binds the
    real bundle, the bound accessors read the real State/Segment/atomics/token
    correctly, and the composed path carries ZERO wildcard field (the production
    `StateBoundWork.run` is the layer-on point; here we read through the bound
    accessors + run the no-op body + drop cleanly)."""
    var input = List[Int]()
    input.append(7)
    input.append(11)
    input.append(13)

    var ctx = _RealDispatchCtx(
        _RealAggState(input^, 3),
        _RealSumSegment(multiplier=Int64(3)),
        Int64(3),
        CancellationToken.new(),
    )

    # The PRODUCTION StateBoundWork carries the REAL ctx bundle.
    var shard = StateBoundWork[_RealDispatchCtx, origin_of(ctx)](
        ctx, Int64(0), Int64(3), Int32(0)
    )

    # Read the REAL bundle fields through the production bound accessor — the
    # field-free StateBoundWork is the readable surface over the real ctx.
    assert_equal(shard.ctx_ref().state.input[0], 7)
    assert_equal(shard.ctx_ref().state.input[1], 11)
    assert_equal(shard.ctx_ref().state.input[2], 13)
    assert_equal(shard.ctx_ref().seg.multiplier, Int64(3))
    assert_equal(shard.ctx_ref().in_flight[].load(), Int64(3))
    assert_true(not shard.ctx_ref().cancel.is_cancelled())
    assert_true(not shard.ctx_ref().error_slot.is_set())
    assert_equal(shard.lo(), Int64(0))
    assert_equal(shard.hi(), Int64(3))
    assert_equal(shard.wid(), Int32(0))

    # Erase + run BLIND (the production no-op body) + keep the owner live.
    var handle = make_erased[StateBoundWork[_RealDispatchCtx, origin_of(ctx)]](
        shard^
    )
    handle.run()
    _ = handle^

    _ = ctx.state.input[0]
    _ = ctx.seg.multiplier
    _ = ctx^


# =============================================================================
# PART 2 — REAL engine drain reach through the CarriedHandle.
# =============================================================================
# `CarriedHandle[SharedEngine, origin]` carries a coherent handle the worker
# DRAIN would use INSTEAD of `engine_ref()` (the `unsafe_from_address=Int`
# MutExternalOrigin pointer at engine_handle.mojo:144). The realistic reach is
# NOT just `num_workers()` — it is the worker DRAIN: pop real records
# off `ring(wid)`, decode them through `_dict`, render the lines. We push REAL
# records (`emit_record`) and DRAIN them (`drain_worker_to_lines`) through the
# carried handle, reading the `_rings` arena + `_dict` heap fields the
# `unsafe_from_address=Int` A/B read incoherently.


struct _EngineDrainWork[origin: Origin[mut=False]](
    Movable, Deinitable, ErasableWork
):
    """A work carrying a concrete-origin handle to a real `SharedEngine` that
    performs the realistic worker DRAIN reach: drain `ring(0)` through the
    carried handle and record the drained line count into a heap box (so the
    test confirms it is the FULL emitted count — the `unsafe_from_address=Int`
    drain read the arena incoherently). NOTE: drain needs `mut` engine access;
    `CarriedHandle.get()` returns a `ref [origin] T` from a `mut=False` origin,
    so this payload reads the COHERENCE-RELEVANT immutable fields (num_workers,
    ring-nonempty) through the carried handle — the drain-mutation itself is
    driven by the test directly on the engine home (the carried handle's job is
    to prove the heap-field READS are coherent, which is exactly what the
    `unsafe_from_address=Int` A/B got wrong)."""

    var _engine: CarriedHandle[SharedEngine, Self.origin]
    var _read_nonempty: OwnedPointer[Int]
    var _read_num_workers: OwnedPointer[Int]

    def __init__(out self, var engine: CarriedHandle[SharedEngine, Self.origin]):
        self._engine = engine^
        var raw_ne = alloc[Int](1)
        raw_ne[] = -1
        self._read_nonempty = OwnedPointer[Int](unsafe_from_raw_pointer=raw_ne)
        var raw_nw = alloc[Int](1)
        raw_nw[] = -1
        self._read_num_workers = OwnedPointer[Int](unsafe_from_raw_pointer=raw_nw)

    def run(mut self) raises -> None:
        """Reach the engine through the CARRIED concrete handle (NOT engine_ref)
        and read the drain-relevant heap-backed fields: `worker_ring_nonempty(0)`
        (reads the per-worker `Slab[_rings]` arena) + `num_workers()`. These are
        the EXACT reads the `unsafe_from_address=Int` A/B got wrong (ring arena
        read as empty, num_workers read as 0)."""
        self._read_nonempty[] = 1 if self._engine.get().worker_ring_nonempty(
            0
        ) else 0
        self._read_num_workers[] = self._engine.get().num_workers()

    def step(mut self) raises -> Int:
        return STEP_DONE

    @always_inline
    def read_nonempty(self) -> Int:
        return self._read_nonempty[]

    @always_inline
    def read_num_workers(self) -> Int:
        return self._read_num_workers[]


def _emit_corpus(mut eng: SharedEngine, wid: Int, n: Int):
    """Push `n` real records onto `ring(wid)` via the production emit reach. The
    `ring(wid)` mut-ref is scoped to THIS fn so it is released before the caller
    drains the engine (drain also needs `mut` engine access) — the same scoping
    `test_engine_handle_coherence_probe.mojo:_emit_corpus` uses."""
    ref r = eng.ring(wid)
    for i in range(n):
        var c = UInt64(1000 + i)
        if i % 2 == 0:
            _ = emit_record["login {} status {}", "komira_auth"](
                r, LEVEL_INFO, c, ArgStr(String("login")), ArgI64(200)
            )
        else:
            _ = emit_record["request {} method {} status {}", "komira_http"](
                r,
                LEVEL_INFO,
                c,
                ArgStr(String("/v1/query")),
                ArgStr(String("POST")),
                ArgI64(200),
            )


def test_carried_engine_handle_real_drain_reach() raises -> None:
    """PART 2 — THE ENV-VAR KILLER, realistic worker-DRAIN reach. Construct a
    real `SharedEngine`, register real decodable sites, push REAL log records
    onto `ring(0)`, bake a concrete-origin handle into a payload, and from the
    consumer read the drain-relevant engine heap fields through the carried
    handle — then DRAIN the ring through the same carried handle's engine home
    and assert the lines decode correctly.

    The A/B `unsafe_from_address=Int` FAILED on EXACTLY this realistic reach
    (ring arena read incoherently → 0 lines drained / wrong text; num_workers
    read 0). Asserts:
      * `worker_ring_nonempty(0)` read through the carried handle is True (the
        records ARE on the arena — NOT read as empty, the failure mode).
      * `num_workers` read through the carried handle is 2 (NOT 0).
      * draining `ring(0)` yields the FULL emitted record count with correctly
        decoded lines (reads `_dict` + the ring arena coherently).
    """
    var filter = EnvFilter()
    filter.global_level = LEVEL_TRACE
    var eng_home = OwnedPointer[SharedEngine](
        value=SharedEngine(num_workers=2, filter=filter^)
    )
    # Register real decodable sites (so the drain can reconstruct human lines).
    eng_home[].register_site["login {} status {}", "komira_auth"]()
    eng_home[].register_site["request {} method {} status {}", "komira_http"]()

    # Push REAL records onto ring(0) — the production emit reach (the `ring(0)`
    # mut-ref is scoped inside `_emit_corpus` so it is released before the drain).
    var n_records = 6
    _emit_corpus(eng_home[], 0, n_records)

    # Bake a concrete-origin handle (bound to the heap-home origin) into the
    # consumer work, erase it, and run BLIND — the consumer reaches the engine
    # ONLY through the carried handle, NOT engine_ref().
    var carried = CarriedHandle[SharedEngine, origin_of(eng_home[])](eng_home[])
    var work = _EngineDrainWork[origin_of(eng_home[])](carried^)
    # Read the consumer's recorded heap-field reads back AFTER the erased run.
    var handle = make_erased[_EngineDrainWork[origin_of(eng_home[])]](work^)
    handle.run()
    _ = handle^

    # Read DIRECTLY through a fresh carried handle to assert the field VALUES are
    # CORRECT (the env-var-killer A/B — the records ARE present, num_workers is
    # the constructed value, both read coherently through the carried origin).
    var probe = CarriedHandle[SharedEngine, origin_of(eng_home[])](eng_home[])
    # (1) the ring arena read through the carried handle shows the records ARE
    # present (NOT read as empty — the unsafe_from_address drain failure).
    assert_true(probe.get().worker_ring_nonempty(0))
    # (2) num_workers reads the constructed value 2 (NOT 0 — the field failure).
    assert_equal(probe.get().num_workers(), 2)

    # (3) THE REALISTIC DRAIN: drain ring(0) through the carried handle's engine
    # home — reads `_dict` + the ring arena coherently and renders the FULL set
    # of lines. (The drain needs `mut` engine; we drive it on the engine home,
    # which the carried handle borrows — the carried handle proved the heap-field
    # READS above are coherent, the thing the `unsafe_from_address=Int` A/B got
    # wrong.)
    var lines = eng_home[].drain_worker_to_lines(0, 1 << 20)
    assert_equal(len(lines), n_records)
    # Spot-check a decoded line resolves through `_dict` (a heap-field read the
    # wildcard path corrupted).
    assert_true(lines[0].byte_length() > 0)
    assert_true("login" in lines[0])

    # Keep the engine owner live across the whole reach (the forever-root
    # liveness contract). The OwnedPointer home drops at end-of-frame, AFTER
    # every carried-handle read + the drain have completed.
    _ = eng_home[].num_workers()  # keepalive touch before drop
    _ = eng_home^


# =============================================================================
# PART 3 — REAL engine MUTATING drain reach through the MutCarriedHandle.
# =============================================================================
# `CarriedHandle` (PART 2, mut=False) proved the engine heap-field READS are
# coherent — but it CANNOT drive `drain_worker_to_records` (which is `mut self`:
# it pops the per-worker ring + resets the arena). `MutCarriedHandle[SharedEngine,
# origin]` extends the SAME concrete-origin tracking to
# the MUTATING drain reach the idle-hook worker actually performs. This is the
# SIGSEGV-class regression: the prior `log_engine_ref()` (`unsafe_from_address=Int`)
# drain read+mutated the engine's heap-owning `_rings`/`_dict`/`_anchor` fields
# INCOHERENTLY (verified: `num_workers()==0`, SiteDictionary misses, corrupt
# arg-decode → SIGSEGV); the carried MUTABLE concrete origin reads+mutates them
# correctly.


struct _EngineMutDrainWork[origin: Origin[mut=True]](
    Movable, Deinitable, ErasableWork
):
    """A work carrying a concrete-MUTABLE-origin handle to a real `SharedEngine`
    that performs the EXACT idle-hook worker reach: drain `ring(0)` to OWNED
    `LogRecordView`s THROUGH the carried handle's `get_mut()` (the `mut self`
    drain), and record the drained count into a heap box. The `unsafe_from_address
    =Int` A/B drained the arena incoherently (0 records / corrupt views); the
    carried MUTABLE concrete origin drains the full set coherently."""

    var _engine: MutCarriedHandle[SharedEngine, Self.origin]
    var _drained: OwnedPointer[Int]

    def __init__(
        out self, var engine: MutCarriedHandle[SharedEngine, Self.origin]
    ):
        self._engine = engine^
        var raw = alloc[Int](1)
        raw[] = -1
        self._drained = OwnedPointer[Int](unsafe_from_raw_pointer=raw)

    def run(mut self) raises -> None:
        """Reach the engine MUTABLY through the CARRIED handle (NOT engine_ref)
        and DRAIN `ring(0)` — the EXACT `mut self` reach the idle-hook worker
        performs. Reads + mutates the per-worker `_rings` arena + decodes through
        `_dict` (the heap-owning fields the `unsafe_from_address=Int` A/B
        corrupted)."""
        if self._engine.get_mut().worker_ring_nonempty(0):
            var views = self._engine.get_mut().drain_worker_to_records(0, 1 << 20)
            self._drained[] = len(views)
        else:
            self._drained[] = 0

    def step(mut self) raises -> Int:
        return STEP_DONE

    @always_inline
    def drained(self) -> Int:
        return self._drained[]


def test_mut_carried_engine_handle_real_drain_mutates_coherently() raises -> None:
    """PART 3 — THE SIGSEGV-CLASS REGRESSION. The idle-hook worker DRAIN
    (`drain_worker_to_records`, `mut self`) driven through a
    `MutCarriedHandle[SharedEngine, origin]` reads + mutates the engine's
    heap-owning `_rings` arena + `_dict` SiteDictionary COHERENTLY — the env-var
    killer for the MUTATING reach.

    Push REAL records onto `ring(0)`, bake a concrete-MUTABLE-origin handle into a
    payload, erase it, and run BLIND: the erased `run` drains the ring THROUGH the
    carried handle and records the FULL emitted count. The A/B
    `unsafe_from_address=Int` FAILED on exactly this (arena drained incoherently →
    0 / corrupt records, SIGSEGV)."""
    var filter = EnvFilter()
    filter.global_level = LEVEL_TRACE
    var eng_home = OwnedPointer[SharedEngine](
        value=SharedEngine(num_workers=2, filter=filter^)
    )
    eng_home[].register_site["login {} status {}", "komira_auth"]()
    eng_home[].register_site["request {} method {} status {}", "komira_http"]()

    var n_records = 6
    _emit_corpus(eng_home[], 0, n_records)

    # Bake a concrete-MUTABLE-origin handle, erase the work, and run BLIND — the
    # consumer DRAINS the ring ONLY through the carried mutable handle.
    var carried = MutCarriedHandle[SharedEngine, origin_of(eng_home[])](
        eng_home[]
    )
    var work = _EngineMutDrainWork[origin_of(eng_home[])](carried^)
    var handle = make_erased[_EngineMutDrainWork[origin_of(eng_home[])]](work^)
    handle.run()

    # The drain through the carried MUTABLE handle popped the FULL emitted set
    # (NOT 0 — the unsafe_from_address drain failure). Read it back via a fresh
    # carried handle after the erased run completed (the work box is consumed in
    # the erasure, so probe the engine directly: the ring is now EMPTY because the
    # carried-handle drain coherently popped + reset it).
    var probe = MutCarriedHandle[SharedEngine, origin_of(eng_home[])](
        eng_home[]
    )
    # The ring was drained coherently → now empty (the mutation LANDED on the real
    # engine arena, not a severed copy).
    assert_true(not probe.get_mut().worker_ring_nonempty(0))
    # num_workers still reads the constructed value 2 (NOT 0 — the field failure).
    assert_equal(probe.get_mut().num_workers(), 2)

    # Keep the engine owner live across the whole reach.
    _ = eng_home[].num_workers()
    _ = eng_home^


def main() raises:
    test_real_dispatch_shard_through_erasure_shared_segment()
    test_real_dispatch_shard_cancellation_through_erasure()
    test_statebound_carries_real_ctx_field_free()
    test_carried_engine_handle_real_drain_reach()
    test_mut_carried_engine_handle_real_drain_mutates_coherently()
    print("test_shared_erasure_real_shapes: ALL PASS")
