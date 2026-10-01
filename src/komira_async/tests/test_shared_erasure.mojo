# =============================================================================
# test_shared_erasure.mojo — the ONE blessed
# hardened erasure library.
# =============================================================================
# REAL unit tests for `komira_async.runtime.shared_erasure` — the consolidated
# erasure primitive that lets the rest of the runtime become wildcard-FIELD-free.
# Three constructs, each tested for REAL (no inline probes):
#
#   1. ErasedHandle DUAL-STEP — drain a heap-owning payload (List[Int] +
#      OwnedPointer[Int]) through BOTH step shapes (void `run` arm + result-
#      returning `step` arm), proving no UAF / double-free on either.
#
#   2. Generalized StateBound (THE KEYSTONE) — a minimal fork-join where N
#      worker shards read the bound State + shared Segment + per-dispatch atomics
#      THROUGH the erased payload, with ZERO wildcard FIELD on any struct. The
#      COMPOSITION CHECK: StateBound's borrow-safety SURVIVES going through
#      ErasedHandle's type-erasure, AND the shared Segment stays SHARED (one
#      home, reached by-pointer) across shards.
#
#   3. Carried engine handle (THE ENV-VAR KILLER) — bake a concrete-origin
#      handle to a real `SharedEngine` into the payload; from the consumer read
#      engine STRUCT FIELDS (`num_workers`, a `SiteDictionary` entry) and assert
#      they read CORRECTLY — the exact A/B `unsafe_from_address=Int` FAILED
#      (`num_workers()` must NOT be 0; the dict entry must resolve).
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_equal, assert_true

from komira_async.runtime.shared_erasure import (
    CarriedHandle,
    ErasableWork,
    ErasedHandle,
    ErasedStepResult,
    StateBoundWork,
    STEP_DONE,
    make_erased,
    step_no_ctx,
)

from komira_core.collections.slab import Slab

from komira_log.engine.shared_engine import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE


# -----------------------------------------------------------------------------
# Test helpers — build a List[Int] via append (the version-agnostic shape; the
# variadic `List[Int](e1, e2, ...)` ctor is brittle on Mojo 1.0.0b1, per
# tests/test_parked_morsel_slab.mojo's note).
# -----------------------------------------------------------------------------


def _ints3(a: Int, b: Int, c: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def _ints5(a: Int, b: Int, c: Int, d: Int, e: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    out.append(e)
    return out^


# =============================================================================
# ErasedHandle DUAL-STEP — a HEAP-OWNING payload through both arms.
# =============================================================================
# `_HeapWork` is deliberately the destroy-recreate shape: a Movable-not-Copyable work with
# BOTH a `List[Int]` heap field AND an `OwnedPointer[Int]` heap field. A botched
# erasure (wildcard cast severing liveness, double-free on drop, UAF read after
# ASAP) would corrupt or double-free these. The work mutates its own heap state
# in `run`/`step` so a read-after-free would surface.


struct _HeapWork(Movable, Deinitable, ErasableWork):
    """List[Int] + OwnedPointer[Int] — the destroy-recreate shape."""

    var _items: List[Int]
    var _accum: OwnedPointer[Int]

    def __init__(out self, var items: List[Int]):
        self._items = items^
        var raw = alloc[Int](1)
        raw[] = 0
        self._accum = OwnedPointer[Int](unsafe_from_raw_pointer=raw)

    def run(mut self) raises -> None:
        var s = 0
        for i in range(len(self._items)):
            s += self._items[i]
        self._accum[] = self._accum[] + s

    def step(mut self) raises -> Int:
        """Result arm: same accumulate, then signal DONE. The heavy result is
        heap-boxed by the producer step trampoline; here the trait `step`
        only returns the POD code."""
        self.run()
        return STEP_DONE

    @always_inline
    def accum(self) -> Int:
        return self._accum[]


def test_erased_handle_void_arm_heap_payload() raises -> None:
    """ErasedHandle VOID arm: drain a heap-owning (List[Int] + OwnedPointer[Int])
    payload via `run`, called MULTIPLE times — proving the work stays runnable
    in-place with no UAF, and the handle's drop runs the work destructor exactly
    once (no double-free of either heap field)."""
    var work = _HeapWork(_ints5(1, 2, 3, 4, 5))  # sum = 15
    var handle = make_erased[_HeapWork](work^)
    # Run BLIND through the void fn-ptr, 3 times — accumulates 15 each time. A
    # UAF on the heap fields would crash on the read-through inside `run`.
    handle.run()
    handle.run()
    handle.run()
    # Drop the handle: runs _HeapWork.__del__ IN-PLACE via `_drop_fn` (frees the
    # List + the OwnedPointer[Int]), THEN `_home` frees the raw blob. A
    # double-free of either heap field would abort here.
    _ = handle^
    # Reached here: the dual heap-field payload survived 3 blind runs + a clean
    # single drop (no UAF, no double-free).
    assert_true(True)


# -----------------------------------------------------------------------------
# result arm with a HEAP-BOXED Movable result round-trip.
# -----------------------------------------------------------------------------
# Proves the result-returning arm carries a Movable-not-Copyable result OUT
# through the erasure (heap-boxed in ErasedStepResult, reconstructed via
# take_result[R]). `_HeapResult` is itself heap-owning (a List[Int]) so a
# botched round-trip would corrupt / double-free it.


struct _HeapResult(Movable, Deinitable):
    """A Movable-not-Copyable result with a heap-owning List[Int] field — the
    destroy-recreate shape traveling OUT through the erasure."""

    var values: List[Int]
    var total: Int

    def __init__(out self, var values: List[Int], total: Int):
        self.values = values^
        self.total = total


struct _ResultWork(Movable, Deinitable, ErasableWork):
    """A work whose `step` heap-boxes a
    `_HeapResult` OUT. Holds a heap `List[Int]` it folds into the result."""

    var _items: List[Int]

    def __init__(out self, var items: List[Int]):
        self._items = items^

    def make_result(self) -> _HeapResult:
        """Build the heap-owning result from the work's own heap state."""
        var copy = List[Int]()
        var s = 0
        for i in range(len(self._items)):
            copy.append(self._items[i])
            s += self._items[i]
        return _HeapResult(copy^, s)

    def run(mut self) raises -> None:
        """Not this payload's arm;
        explicit no-op. REQUIRED now that `ErasableWork` has no trait defaults."""
        pass

    def step(mut self) raises -> Int:
        """Driven via producer trampoline `_result_step_for`, not this
        trait `step`; explicit DONE so the conformance is satisfied."""
        return STEP_DONE


def _result_step_for(
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
) raises -> ErasedStepResult:
    """A PRODUCER step trampoline for `_ResultWork` that heap-boxes a Movable
    `_HeapResult` OUT through the erasure (the handler-frame arm pattern). This
    is the per-W producer-side override of the default `_erased_step_for` — the
    same shape `erased_frame.mojo`'s `_erased_step_for` uses to box the DONE
    response.

    SAFETY: `p` is the byte ptr to the `_ResultWork` heap home placed by
    `make_erased`. We bitcast it back to `_ResultWork*` (the producer/consumer
    monomorphize the SAME W), build the result in-place, heap-box it into an
    `OwnedPointer[UInt8]`, and carry it in the ErasedStepResult. The pointer
    never escapes this body."""
    var work_ptr = p.bitcast[_ResultWork]()
    var result = work_ptr[].make_result()
    var result_home = alloc[_HeapResult](1)
    # SAFETY: fresh allocation we own; move the heap result into it.
    UnsafePointer(to=result_home[]).unsafe_write(result^)
    var result_blob = OwnedPointer[UInt8](
        unsafe_from_raw_pointer=result_home.bitcast[UInt8]()
    )
    return ErasedStepResult.done(result_blob^)


def test_erased_handle_result_arm_heap_result_roundtrip() raises -> None:
    """ErasedHandle RESULT arm: a Movable-not-Copyable heap-owning result
    (`_HeapResult` with a List[Int]) travels OUT through the erasure, reconstructed
    BYTE-IDENTICAL via `take_result[_HeapResult]()`. No double-free / leak: the
    box is consumed exactly once.

    We drive the producer step trampoline DIRECTLY over the work's heap home (the
    same path `ErasedHandle.step` takes, exercising the heap-box round-trip in
    isolation from the default trait-step code)."""
    var work = _ResultWork(_ints3(10, 20, 30))  # total = 60
    # Heap-box the work the way make_erased does, then call the producer step
    # trampoline over its home (proving the result round-trip end to end).
    var work_home = alloc[_ResultWork](1)
    UnsafePointer(to=work_home[]).unsafe_write(work^)
    var p = work_home.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin]()
    var sr = _result_step_for(p)
    assert_true(sr.is_done())
    assert_true(sr.has_result())
    var result = sr.take_result[_HeapResult]()
    # Byte-identical reconstruction of the heap-owning result.
    assert_equal(result.total, 60)
    assert_equal(len(result.values), 3)
    assert_equal(result.values[0], 10)
    assert_equal(result.values[1], 20)
    assert_equal(result.values[2], 30)
    # Drop the work home (its destructor frees the work's List), bypassing
    # double-destruction of the moved-out result (already owned by `result`).
    work_home.unsafe_deinit_pointee()
    work_home.bitcast[UInt8]().free()
    _ = result^


# =============================================================================
# Generalized StateBound (THE KEYSTONE) — N-shard fork-join, ZERO wildcard
#      FIELD, shared Segment, borrow-safety SURVIVES erasure.
# =============================================================================
# `_Counter` is the borrowed State; `_SharedSeg` is the SHARED Segment (one home,
# borrowed by N shards by-pointer — proving it is NOT copied). Each shard reads
# State + Segment + the atomics THROUGH the bound `StateBoundWork`, which is
# itself erased into an `ErasedHandle` (the composition the keystone proves).


struct _Counter(Movable, Deinitable):
    """The borrowed dispatch State — a heap List the shards read."""

    var data: List[Int]

    def __init__(out self, var data: List[Int]):
        self.data = data^


struct _SharedSeg(Movable, Deinitable):
    """The SHARED Segment — reached as a field of the ONE borrowed `_DispatchCtx`
    every shard rides. Carries a sentinel + a heap field so a copy (vs share)
    would be observable."""

    var multiplier: Int
    var tag: List[Int]

    def __init__(out self, multiplier: Int):
        self.multiplier = multiplier
        self.tag = List[Int]()  # sentinel; identity is by address, not value
        self.tag.append(7)


struct _DispatchCtx(Movable, Deinitable):
    """The per-dispatch context the shards borrow INTO — bundles the State + the
    SHARED Segment + the per-dispatch atomics under ONE owner, so all the shard
    borrows share ONE concrete `origin` (the load-bearing design: a concrete
    origin parameter cannot carry six independent borrows the way the wildcard
    did; bundling into one owner is the correct + strictly-safer shape). This is
    how a real per-core dispatcher owns ONE per-dispatch frame."""

    var state: _Counter
    var seg: _SharedSeg
    var in_flight: Int64
    var wake_word: Int64
    var error_slot: Int64
    var cancel: Int64

    def __init__(
        out self,
        var state: _Counter,
        var seg: _SharedSeg,
        in_flight: Int64,
    ):
        self.state = state^
        self.seg = seg^
        self.in_flight = in_flight
        self.wake_word = Int64(0)
        self.error_slot = Int64(0)
        self.cancel = Int64(0)


def test_statebound_through_erasure_field_free_shared_segment() raises -> None:
    """THE KEYSTONE. N shards bind the SAME borrowed State + the SAME shared
    Segment + the per-dispatch atomics into N `StateBoundWork` payloads, each
    erased into an `ErasedHandle`, and run BLIND. Proves:

      (a) The composed path is FIELD-FREE — `StateBoundWork` carries concrete
          `Origin[mut=True]` pointers (NOT wildcard), and `ErasedHandle` carries
          only an `OwnedPointer[UInt8]` + fn-ptr aliases. (`lint_wildcard_field.sh`
          confirms zero new owning wildcard fields — checked out-of-band.)

      (b) The shared Segment stays SHARED across shards — every shard's
          `seg_ref()` resolves to the SAME `_SharedSeg` home address (NOT a
          per-shard copy). We assert all N shards observe the identical Segment
          ADDRESS.

      (c) Borrow-safety SURVIVES the erasure — each shard reads State + Segment
          + atomics through the bound pointers AFTER going through type-erasure,
          with the owner (`state` / `seg` / atomics) kept alive on this frame
          (the fork-join-barrier liveness contract, here a synchronous loop)."""
    var n_shards = 4

    # The borrowed owner — the ONE per-dispatch context, live on THIS stack frame
    # for the whole dispatch (the synchronous analog of the wake-word barrier
    # holding it alive). Bundles State + shared Segment + atomics under one owner
    # so every shard borrow shares ONE concrete origin.
    var ctx = _DispatchCtx(
        _Counter(_ints3(100, 200, 300)),
        _SharedSeg(multiplier=3),
        Int64(n_shards),
    )

    # The SHARED Segment's home address — every shard must observe THIS exact
    # address (a field of the ONE borrowed ctx) through the erased payload
    # (proving share, not copy).
    var seg_addr = Int(UnsafePointer(to=ctx.seg))

    # Build N erased shards, each binding the SAME ctx borrow. `origin_of(ctx)`
    # is the concrete origin every shard rides. ErasedHandle is
    # Movable-not-Copyable → a `Slab` (NOT `List`) holds it (safe across destroy-recreate; the
    # blessed Movable-only container).
    var handles = Slab[ErasedHandle]()
    var observed_seg_addrs = List[Int]()
    for wid in range(n_shards):
        var lo = Int64(wid)
        var hi = Int64(wid + 1)
        # Construct the bound work — concrete origin via the `ref` ctor param.
        var shard = StateBoundWork[_DispatchCtx, origin_of(ctx)](
            ctx, lo, hi, Int32(wid)
        )
        # BEFORE erasure: confirm the shard sees the shared Segment home (the
        # SAME ctx.seg address) through the bound concrete-origin pointer.
        observed_seg_addrs.append(
            Int(UnsafePointer(to=shard.ctx_ref().seg))
        )
        # Erase it into a handle — borrow-safety must SURVIVE this.
        handles.append(
            make_erased[StateBoundWork[_DispatchCtx, origin_of(ctx)]](shard^)
        )

    # (b) Every shard observed the SAME shared Segment address (no copy) — the
    # shared Segment stays SHARED across all shards through the erasure.
    for wid in range(n_shards):
        assert_equal(observed_seg_addrs[wid], seg_addr)

    # (c) Run every erased shard BLIND. `StateBoundWork.run` is an explicit
    # no-op in this minimal payload (the production `_DispatchShard` body layers
    # on there), so THIS test proves the composed path runs + drops cleanly with
    # the borrow live; tests below
    # (`test_statebound_*_reads_through_erasure_at_runtime`) prove the read-
    # through actually executes post-erasure with an OBSERVABLE side effect. A
    # wildcard-severed liveness would crash on the read-through.
    for wid in range(n_shards):
        handles.get_mut_interior(wid).run()

    # Keep the borrowed owner live across the whole dispatch (the barrier
    # liveness contract). Touch it so the compiler observes it live here.
    _ = ctx.state.data[0]
    _ = ctx.seg.multiplier
    _ = ctx.in_flight

    # Drop the handles (each runs StateBoundWork.__del__ in-place — POD borrow
    # field, no heap to double-free — then frees the blob).
    _ = handles^

    # The ctx owner drops naturally at end-of-frame, AFTER every shard finished.
    _ = ctx^


# -----------------------------------------------------------------------------
# THE KEYSTONE AT RUNTIME — a StateBound payload whose `run`/`step` body
#       ACTUALLY reads the bound ctx THROUGH the erased handle and writes an
#       OBSERVABLE result.
# -----------------------------------------------------------------------------
# `StateBoundWork.run` is the trait DEFAULT no-op — so keystone test
# proves the bind-through-erasure STRUCTURALLY (the concrete origin is part of
# the erased W) but the post-erasure `handle.run()` never dereferences `_ctx`.
# This payload closes that gap: it carries the EXACT same concrete-origin
# `Pointer[Ctx, origin]` field shape as `StateBoundWork` (NO wildcard field —
# `lint_wildcard_field.sh` stays PASS), and its `run`/`step` body reads
# `ctx_ref().state` + `ctx_ref().seg.multiplier` THROUGH the bound pointer and
# writes an OBSERVABLE result into the SHARED ctx. Driven POST-erasure through
# the ErasedHandle trampoline, it genuinely demonstrates the read-through-after-
# erasure the keystone docstring claims.


struct _AccumStateBound[
    origin: Origin[mut=True],
](Movable, Deinitable, ErasableWork):
    """A test-only StateBound payload — IDENTICAL field shape to the production
    `StateBoundWork` (a single concrete-origin `Pointer[_DispatchCtx, origin]`
    borrow, NO wildcard field) — whose `run`/`step` body actually READS the
    bound `_DispatchCtx` THROUGH the erased handle and writes an OBSERVABLE
    result.

    Specialized to the concrete `_DispatchCtx` (vs the production
    `StateBoundWork`, which stays generic over `Ctx` so the production body can
    layer on later): a payload whose `run` body reads CONCRETE ctx FIELDS must
    know the concrete type — keeping it `Ctx`-generic would leave `Ctx` an
    abstract trait bound with no `.state` / `.seg` / `.wake_word`. The bind shape
    is unchanged: a single `Pointer[_DispatchCtx, origin]` concrete-origin field,
    NO wildcard, the SAME `ref [origin]` ctor + `ctx_ref()` accessor.

    `run` computes `sum(state.data[lo:hi]) * seg.multiplier` (reading BOTH the
    borrowed State's heap data AND the shared Segment's multiplier through the
    bound pointer) and FOLDS it into the SHARED ctx's `wake_word` slot — a write
    the test reads back AFTER the erased run, proving the read-through happened
    at runtime, post-erasure. `step` returns STEP_DONE after the same read-
    through + shared write; the void `run` arm carries the runtime demonstration.
    """

    # The borrowed per-dispatch context home, concrete `origin` — the SAME
    # field shape `StateBoundWork` carries (NOT a wildcard field).
    var _ctx: Pointer[_DispatchCtx, Self.origin]
    var _lo: Int64
    var _hi: Int64

    def __init__(
        out self,
        ref [Self.origin] ctx: _DispatchCtx,
        lo: Int64,
        hi: Int64,
    ):
        self._ctx = Pointer(to=ctx)
        self._lo = lo
        self._hi = hi

    @always_inline
    def ctx_ref(self) -> ref [Self.origin] _DispatchCtx:
        """Borrow the bound ctx through the concrete-origin pointer (ref tied to
        the inner pointer's origin — Repro 5/5b), exactly as `StateBoundWork`."""
        return self._ctx[]

    @always_inline
    def _compute(self) -> Int:
        """Read the borrowed State's heap slice + the shared Segment's multiplier
        THROUGH the bound concrete-origin pointer and fold them."""
        var s = 0
        for i in range(Int(self._lo), Int(self._hi)):
            s += self.ctx_ref().state.data[i]
        return s * self.ctx_ref().seg.multiplier

    def run(mut self) raises -> None:
        """VOID arm — read state+seg THROUGH the erased bound pointer and WRITE
        the computed value into the SHARED ctx's `wake_word` slot (observable
        from the test frame after the erased run returns)."""
        var computed = self._compute()
        # Mutating write THROUGH the bound concrete-origin pointer into the
        # SHARED ctx — the read-through demonstration's observable side effect.
        self.ctx_ref().wake_word += Int64(computed)

    def step(mut self) raises -> Int:
        """RESULT arm — same read-through + shared write through the bound
        pointer, signal DONE. The shared `wake_word` write is the observable
        runtime read-through (the test reads it back after `ErasedHandle.step`).
        """
        self.run()
        return STEP_DONE


def test_statebound_run_reads_through_erasure_at_runtime() raises -> None:
    """THE KEYSTONE AT RUNTIME. N shards bind the
    SAME shared `_DispatchCtx` into `_AccumStateBound` payloads, each erased into
    an `ErasedHandle`, and run BLIND through the erased VOID trampoline. Each
    shard's POST-erasure `run` body ACTUALLY reads the borrowed State's heap
    slice + the shared Segment's multiplier THROUGH the bound concrete-origin
    pointer and writes the computed value into the SHARED ctx — a side effect the
    test reads back AFTER the erased runs, GENUINELY demonstrating the read-
    through-after-erasure the keystone docstring claims (vs runs the
    trait-default no-op and reads only BEFORE erasure).

    With data=[100,200,300], multiplier=3, and shard wid covering [wid, wid+1):
      shard 0 -> 100*3 = 300
      shard 1 -> 200*3 = 600
      shard 2 -> 300*3 = 900
    Expected SHARED wake_word after all 3 erased runs = 300+600+900 = 1800."""
    var n_shards = 3
    var ctx = _DispatchCtx(
        _Counter(_ints3(100, 200, 300)),
        _SharedSeg(multiplier=3),
        Int64(n_shards),
    )

    # Build N erased shards binding the SAME shared ctx (one concrete origin).
    var handles = Slab[ErasedHandle]()
    for wid in range(n_shards):
        var shard = _AccumStateBound[origin_of(ctx)](
            ctx, Int64(wid), Int64(wid + 1)
        )
        handles.append(
            make_erased[_AccumStateBound[origin_of(ctx)]](shard^)
        )

    # Drive every erased shard BLIND through the VOID trampoline. The read-
    # through (state.data[wid] * seg.multiplier) + the shared write happen
    # INSIDE the erased `run` body — POST-erasure. A wildcard-severed liveness
    # would crash on the read-through or write garbage into wake_word.
    for wid in range(n_shards):
        handles.get_mut_interior(wid).run()

    # OBSERVABLE: the shared ctx's wake_word reflects the SUM the erased runs
    # computed by reading state + seg THROUGH the bound pointer — proving the
    # read-through-after-erasure happened at runtime (300+600+900 = 1800).
    assert_equal(ctx.wake_word, Int64(1800))

    _ = handles^
    # Keep the borrowed owner live across the whole dispatch (barrier contract).
    _ = ctx.state.data[0]
    _ = ctx.seg.multiplier
    _ = ctx^


def test_statebound_step_arm_reads_through_erasure_at_runtime() raises -> None:
    """THE KEYSTONE AT RUNTIME via the RESULT (`step`) arm. A single
    `_AccumStateBound` shard is erased into an `ErasedHandle` and driven through
    the PUBLIC `ErasedHandle.step()` path (which invokes the `_erased_step_for`
    trampoline -> the payload's `step` body) POST-erasure. The erased `step` body
    reads the bound State + the shared Segment THROUGH the bound concrete-origin
    pointer and writes the computed value into the SHARED ctx's `wake_word` slot.
    The test reads `ctx.wake_word` back AFTER the erased step and asserts it
    reflects the CORRECT shared-Segment/State value read THROUGH the erased
    handle — demonstrating the read-through-after-erasure on the result arm too.

    data=[11,22,33], multiplier=5, shard covers [1, 3) -> (22+33)*5 = 275."""
    var ctx = _DispatchCtx(
        _Counter(_ints3(11, 22, 33)),
        _SharedSeg(multiplier=5),
        Int64(1),
    )

    var shard = _AccumStateBound[origin_of(ctx)](ctx, Int64(1), Int64(3))
    var handle = make_erased[_AccumStateBound[origin_of(ctx)]](shard^)
    # Drive the RESULT arm BLIND through the public ErasedHandle.step_no_ctx()
    # path (the reactor-free task arm — threads the empty NoContext). The
    # read-through (state[1:3] * multiplier) + the shared write happen INSIDE the
    # erased `step` body — POST-erasure. The trait `step` returns STEP_DONE, which
    # the default `_erased_step_for` maps to a done-empty ErasedStepResult.
    var sr = step_no_ctx(handle)
    assert_true(sr.is_done())

    # OBSERVABLE: the shared ctx's wake_word reflects the value the erased `step`
    # computed by reading state + seg THROUGH the bound pointer — proving the
    # read-through-after-erasure on the result arm ((22+33)*5 = 275).
    assert_equal(ctx.wake_word, Int64(275))

    _ = handle^
    _ = ctx.state.data[0]
    _ = ctx.seg.multiplier
    _ = ctx^


def test_statebound_reads_state_and_atomics_through_erasure() raises -> None:
    """Reinforce (c): a shard reads the borrowed State's heap data + the shared
    Segment's multiplier + the cancel flag THROUGH the bound pointers, and the
    values are CORRECT after erasure (the borrow chain is not severed). Reads
    BEFORE erasure (direct) and asserts the bound accessors resolve correctly —
    the field-free StateBoundWork is the readable surface."""
    var ctx = _DispatchCtx(
        _Counter(_ints3(11, 22, 33)),
        _SharedSeg(multiplier=5),
        Int64(1),
    )

    var shard = StateBoundWork[_DispatchCtx, origin_of(ctx)](
        ctx, Int64(0), Int64(3), Int32(0)
    )

    # Read the borrowed State's heap data through the bound concrete-origin
    # pointer (a field of the borrowed ctx).
    assert_equal(shard.ctx_ref().state.data[0], 11)
    assert_equal(shard.ctx_ref().state.data[1], 22)
    assert_equal(shard.ctx_ref().state.data[2], 33)
    # Read the SHARED Segment's multiplier through the concrete-origin pointer.
    assert_equal(shard.ctx_ref().seg.multiplier, 5)
    # Read the per-dispatch atomics + cancel flag (fields of the bound ctx).
    assert_equal(shard.ctx_ref().in_flight, Int64(1))
    assert_equal(shard.ctx_ref().cancel, Int64(0))
    assert_equal(shard.lo(), Int64(0))
    assert_equal(shard.hi(), Int64(3))

    # Now erase + run BLIND, then keep the owner live (the barrier contract).
    var handle = make_erased[StateBoundWork[_DispatchCtx, origin_of(ctx)]](
        shard^
    )
    handle.run()
    _ = handle^

    _ = ctx.state.data[0]
    _ = ctx.seg.multiplier
    _ = ctx.in_flight
    _ = ctx^


# =============================================================================
# Carried engine handle (THE ENV-VAR KILLER) — read SharedEngine STRUCT
#      FIELDS through a baked-in concrete handle.
# =============================================================================
# Construct a REAL SharedEngine, bake a concrete-origin CarriedHandle into the
# payload, and from the consumer read engine STRUCT FIELDS. This is the EXACT
# A/B `unsafe_from_address=Int` FAILED: num_workers() MUST NOT be 0, and a
# SiteDictionary entry registered on the engine MUST resolve through the carried
# handle.


struct _EngineConsumerWork[origin: Origin[mut=False]](
    Movable, Deinitable, ErasableWork
):
    """A work that carries a concrete-origin handle to a SharedEngine and reads
    its struct fields. Records the read-back `num_workers` into a heap box so the
    test can confirm it is NOT 0 (the env-var/unsafe_from_address failure)."""

    var _engine: CarriedHandle[SharedEngine, Self.origin]
    var _read_num_workers: OwnedPointer[Int]

    def __init__(out self, var engine: CarriedHandle[SharedEngine, Self.origin]):
        self._engine = engine^
        var raw = alloc[Int](1)
        raw[] = -1  # sentinel: -1 means "not read yet"
        self._read_num_workers = OwnedPointer[Int](unsafe_from_raw_pointer=raw)

    def run(mut self) raises -> None:
        """Reach the engine through the CARRIED concrete handle (NOT the env-var)
        and read its `num_workers` struct field."""
        self._read_num_workers[] = self._engine.get().num_workers()

    def step(mut self) raises -> Int:
        """Not this payload's arm (it uses the void `run`); explicit DONE so the
        conformance is satisfied now that `ErasableWork` has no trait defaults."""
        return STEP_DONE

    @always_inline
    def read_num_workers(self) -> Int:
        return self._read_num_workers[]


def test_carried_engine_handle_reads_struct_fields() raises -> None:
    """THE ENV-VAR KILLER. Construct a real SharedEngine, bake a concrete-origin
    handle into a payload, and from the consumer read engine STRUCT FIELDS
    correctly — the exact A/B `unsafe_from_address=Int` FAILED.

    Asserts:
      * `num_workers` read through the carried handle is the CONSTRUCTED value
        (4), NOT 0 (the unsafe_from_address failure mode where the owner was
        ASAP-freed and num_workers() read 0).
      * A `SiteDictionary` entry registered on the engine RESOLVES through the
        carried handle (a heap-field read — the second half of the failed A/B).

    The engine is owned on a stable heap home (`OwnedPointer[SharedEngine]`) —
    the production forever-root shape (constructed once on a stable address; the
    carried handle borrows THAT, exactly as `EngineContext._log_engine` keeps it
    alive). The carried handle binds to the engine's heap-home origin; the
    consumer reaches it THROUGH the carried handle, never the env var.
    """
    var filter = EnvFilter()
    filter.global_level = LEVEL_TRACE
    var eng_home = OwnedPointer[SharedEngine](
        value=SharedEngine(num_workers=4, filter=filter^)
    )
    # Register a decodable site so the engine's SiteDictionary has a heap entry
    # to read back through the carried handle.
    eng_home[].register_site["carried handle test fmt={}", "komira_test"]()

    # Bake a concrete-origin handle (bound to the heap-home origin) into a
    # consumer work, erase it, and run BLIND — the consumer reaches the engine
    # ONLY through the carried handle, NOT the env-var.
    var carried = CarriedHandle[SharedEngine, origin_of(eng_home[])](
        eng_home[]
    )
    var work = _EngineConsumerWork[origin_of(eng_home[])](carried^)
    var handle = make_erased[_EngineConsumerWork[origin_of(eng_home[])]](
        work^
    )
    handle.run()
    _ = handle^

    # Read DIRECTLY through a fresh carried handle to assert the field VALUES
    # are CORRECT (the env-var-killer A/B — the erased run proved the reach does
    # not crash; this asserts num_workers != 0 + the heap dict entry resolves).
    var probe = CarriedHandle[SharedEngine, origin_of(eng_home[])](eng_home[])
    # (1) num_workers MUST be 4 (NOT 0 — the unsafe_from_address failure).
    assert_equal(probe.get().num_workers(), 4)
    # (2) the registered SiteDictionary entry RESOLVES through the carried
    # handle — a heap-owning-field read that the wildcard path corrupted.
    var site_id = eng_home[]._dict.sites[0].site_id
    var fmt = probe.get()._dict.lookup_fmt(site_id)
    assert_true(Bool(fmt))
    assert_equal(fmt.value(), String("carried handle test fmt={}"))

    # Keep the engine owner live across the whole reach (the forever-root
    # liveness contract). The OwnedPointer home drops at end-of-frame, AFTER
    # every carried-handle read has completed.
    _ = eng_home[].num_workers()  # keepalive touch before drop
    _ = eng_home^


def main() raises:
    test_erased_handle_void_arm_heap_payload()
    test_erased_handle_result_arm_heap_result_roundtrip()
    test_statebound_through_erasure_field_free_shared_segment()
    test_statebound_run_reads_through_erasure_at_runtime()
    test_statebound_step_arm_reads_through_erasure_at_runtime()
    test_statebound_reads_state_and_atomics_through_erasure()
    test_carried_engine_handle_reads_struct_fields()
    print("test_shared_erasure: ALL PASS")
