# =============================================================================
# komira_async.runtime.shared_erasure — the ONE blessed hardened erasure library
# =============================================================================
# The SOLE blessed wildcard SITE in the runtime: this module
# consolidates the THREE type-erasure / state-binding shapes that the runtime +
# dispatch consumers had scattered (each carrying its own wildcard field) into
# one hardened primitive, so the REST of the runtime can become wildcard-FIELD-
# free. The migration target: `_TaskEntry` (task/queue arm), `ErasedFrame`
# (handler-frame arm), and `_DispatchShard` (the StateBound arm) all collapse
# onto `ErasedHandle` + `StateBoundWork` here.
#
# It consolidates THREE things:
#
#   1. ErasedHandle — a DUAL-STEP type-erasure handle. Fields are
#      `_home: OwnedPointer[UInt8]` (CONCRETE origin, ASAP-tracked) + FFI-POD
#      run/drop/step code-ptrs. ZERO wildcard FIELDS — the `MutExternalOrigin`
#      is confined to the fn-ptr comptime ALIASES + the ONE step/drop cast-site
#      body. Supports BOTH a void-returning `run` (task/queue arm) AND a
#      result-returning `step` (handler-frame arm, heap-boxed result per the
#      `erased_frame.mojo` `_ErasedStepResult` pattern). Safe ctor
#      `make_erased[W: ErasableWork](var work)` via alloc + init_pointee_move;
#      top-level parametric trampolines (NOT nested closures); pointer-free
#      PUBLIC API.
#
#   2. StateBoundWork[Ctx, origin] — the generalized StateBound. Binds a
#      caller's BORROWED per-dispatch context `Ctx` (which bundles the State +
#      shared Segment + per-dispatch atomics in_flight / wake_word / error_slot +
#      cancel) into a payload that goes through ErasedHandle's erasure — WITHOUT
#      a wildcard FIELD on any struct. The generalization of `_DispatchShard`
#      (which carries SIX wildcard fields): the borrow rides as ONE
#      `Pointer[Ctx, origin]` with a CONCRETE origin parameter on the struct
#      (the `memory_region.mojo` precedent), NOT `UnsafePointer[_,
#      MutExternalOrigin]`. (Bundling the six borrows into ONE owner is
#      load-bearing: a concrete origin parameter ENFORCES that every borrow
#      bound to it shares that exact origin — which the wildcard erased — so the
#      six independent borrows must be reached through one tracked owner. This is
#      strictly safer.) The CRITICAL COMPOSITION CHECK: the borrow-safety
#      SURVIVES the type-erasure — the shared Segment stays SHARED (a field of
#      the one borrowed Ctx, reached by-pointer), and the composed path is
#      field-free (`lint_wildcard_field.sh` adds zero owning wildcard fields).
#
#   3. CarriedHandle[T, origin] — a producer bakes a CONCRETE-origin handle to a
#      shared resource (e.g. `SharedEngine`) into the payload; the consumer
#      reaches the resource via the carried handle, NOT an env-var /
#      `unsafe_from_address=Int` reconstruction (the exact mechanism the
#      idle-hook HALT pinned as `compiler_miscompile_wildcard`). This proves a
#      task / dispatch / hook / drain reach can DROP the env-var: the consumer
#      reads engine STRUCT FIELDS (`num_workers`, a `SiteDictionary` entry)
#      correctly — the A/B `unsafe_from_address=Int` FAILED (`num_workers()==0`,
#      missed dict, SIGSEGV).
#
# ── ENCAPSULATION (+ pointer-rule FFI-POD fn-ptr carve-out) ──────────
# `ErasedHandle`'s fields are an `OwnedPointer[UInt8]` (concrete origin) + three
# alias-typed fn-ptr fields. The wildcard origin (`MutExternalOrigin`) lives
# ONLY inside the `_RunFn` / `_StepFn` / `_DropFn` comptime ALIASES and inside
# the trampoline / cast-site bodies — NEVER on a 4-space FIELD line (the shape
# `lint_wildcard_field.sh` gates on). `make_erased` takes `var work: W` (no
# pointer) and returns `ErasedHandle` (no pointer in the signature). The
# consumer API is step/run-via-fn-ptr. ZERO `UnsafePointer` in any PUBLIC
# signature. This file is the ONE allowlisted wildcard SITE: the three fn-ptr
# alias fields are the FFI-POD carve-out (code pointers, no heap).
#
# ── DESTROY-RECREATE SAFETY + the DUAL-STEP DROP FINDING ──────────────────────────
# Identical ownership shape to `ErasedFrame[S]` (which already owns its SM via
# `OwnedPointer[UInt8]`). The handle is consumed EXACTLY ONCE: `run`/`step` use
# the work IN-PLACE (no consume); `__del__` destroys the work + frees the home
# in ONE tracked consume (see below). The blob is a single heap allocation
# reached via an OwnedPointer with a CONCRETE origin; nothing is stored in a
# byte-slab with a wildcard cast (the destroy-recreate trap). `ErasedHandle` is per-dispatch
# / per-task, NOT a destroy-recreate pool field — so NOT the destroy-recreate shape.
#
# DUAL-STEP DROP FINDING (Mojo 1.0.0b1, — verified by the unit
# test, NOT a guess): the OBVIOUS two-step teardown that `erased_frame.mojo`
# uses — run `W.__del__` in-place via `destroy_pointee()`, then free the raw
# byte home via a SEPARATE `OwnedPointer[UInt8]` drop — DOUBLE-FREES a `W` that
# has a NESTED heap-owning field (an inner `OwnedPointer` / `List` at a realistic
# offset). The in-place destroy + the separate byte-free are not tracked as ONE
# consume of W's storage, so the inner field's home is freed twice (a
# heap-corruption that only trips on a LATER allocation — the destroy-recreate/use-after-free
# family; the test reproduces it deterministically across two erasures). The FIX
# (used here): `__del__` RELINQUISHES `_home`'s free (`unsafe_leak()`) and the
# `_drop_fn` reconstructs ONE `OwnedPointer[W]` over the bytes and `.into_inner()`s it
# — destroy + free as a SINGLE tracked consume (the blessed pointer-rule shape
# `take_result` uses). Do NOT "simplify" the drop back to the two-step shape; it
# regresses silently on any payload with a nested heap-owning field.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.parked_morsel_slab import ParkedMorselSlab
from komira_async.runtime.suspendable_handler import (
    DeliveredResponse,
    HANDLER_DONE,
    HANDLER_EMIT,
    HANDLER_ERR,
    HANDLER_OP_ID_BIAS,
    HANDLER_PARKED,
    SuspendableHandler,
)

from komira_core.collections.slab import Slab


# =============================================================================
# NoContext — the empty step-context for the reactor-FREE arm.
# =============================================================================
# The DEFAULT `Ctx` parameter of `ErasedHandle`. The task/queue/dispatch arm
# (`make_erased` / `make_borrowed_erased`) erases work whose `step` needs NO
# external context — it threads this empty value, which the step trampoline
# ignores. Because `ErasedHandle[Ctx = NoContext]` has `NoContext` as the
# DEFAULT parameter, the task arm spells `ErasedHandle` BARE (resolving to
# `ErasedHandle[NoContext]`) so the channel-element type identity is preserved
# across the entire task/queue + dispatch hot path (ZERO ripple). The handler-
# frame arm spells `ErasedHandle[Reactor[S]]` (the reactor IS its step context).
# An empty `@fieldwise_init` POD — Movable & Deinitable (the `Ctx`
# bound).


@fieldwise_init
struct NoContext(Movable, Deinitable):
    """The empty step-context for the reactor-free task/queue arm of
    `ErasedHandle`. The DEFAULT `Ctx` parameter, so the task arm spells
    `ErasedHandle` bare. The step trampoline threads (and ignores) it; it carries
    no state."""

    pass


# =============================================================================
# ErasableWork — the trait every payload that rides ErasedHandle conforms
#      to.
# =============================================================================
# A work payload implements BOTH step shapes (REQUIRED methods — NO trait
# default; see the dispatch finding on the trait below). A payload that only
# logically uses one arm implements the other as an explicit no-op / DONE. `run`
# is the void-returning task/queue arm (the `_TaskEntry.run_fnptr` shape); `step`
# is the result-returning handler-frame arm (returns a POD step code; the heavy
# Movable result is heap-boxed SEPARATELY by the producer's `step` trampoline,
# exactly as `_ErasedStepResult` does — kept out of the trait so the trait has
# no associated Movable-result type, which would re-introduce a parameter the
# erasure exists to remove).
#
# WHY REQUIRED (not trait-default) methods — the dispatch finding: a trait
# DEFAULT body is STATICALLY bound by the GENERIC erasure trampolines
# (`_erased_run_for[W: ErasableWork]` / `_erased_step_for[W]`). When the
# trampoline calls `work_ptr[].run()` with `W` a trait-bound parameter, Mojo
# 1.0.0b1 resolves to the trait DEFAULT in the generic context — it does NOT
# dynamically dispatch to `W`'s override. A default no-op `run` would therefore
# silently shadow EVERY payload's `run` AFTER erasure (the keystone's
# `handle.run()` would execute a no-op; the read-through would never run; any
# observable side effect would be lost). Making the methods REQUIRED removes the
# default so the trampoline binds to the SOLE (concrete) impl. This is the same
# shape `erased_frame.mojo`'s `SuspendableHandler` uses (no default `step`), and
# the unit test (`test_statebound_*_reads_through_erasure_at_runtime`) guards it
# by asserting an observable side effect that ONLY lands if the override runs.


trait ErasableWork(Movable, Deinitable):
    """A payload that can be type-erased into an `ErasedHandle`.

    Exposes both erasure arms as REQUIRED methods. `run` is the void task/queue
    arm; `step` is the result-returning handler-frame arm whose POD return is the
    step code (a heap-boxed Movable result, if any, is produced out-of-band by
    the caller's own step trampoline — see `ErasedStepResult`).

    DISPATCH FINDING (Mojo 1.0.0b1, — verified by the unit test,
    NOT a guess): these methods MUST be REQUIRED (no trait-default body). A
    DEFAULT body is statically bound by the GENERIC trampolines
    (`_erased_run_for[W: ErasableWork]` / `_erased_step_for[W: ErasableWork]`):
    when the trampoline calls `work_ptr[].run()` with `W` a trait-bound
    parameter, Mojo 1.0.0b1 resolves the call to the trait DEFAULT in the generic
    context — it does NOT dynamically dispatch to `W`'s override. So a default
    no-op `run` would silently shadow EVERY concrete payload's `run` after
    erasure (the keystone's `handle.run()` would run a no-op, the read-through
    would never execute, and any observable side effect would be lost). Making
    the methods REQUIRED removes the default, so the trampoline's `work_ptr[].run`
    binds to the SOLE (concrete) implementation — the override actually runs.
    This matches the `erased_frame.mojo` `SuspendableHandler` precedent (no
    default `step`). A payload that only logically uses ONE arm implements the
    other as an explicit no-op / DONE (see the test payloads).
    """

    def run(mut self) raises -> None:
        """Void task/queue arm (the `_TaskEntry.run_fnptr` shape). REQUIRED — a
        payload that only uses `step` implements this as an explicit no-op
        (`pass`). (See the dispatch finding above: a trait-DEFAULT body would be
        statically bound by the generic trampoline and shadow the override)."""
        ...

    def step(mut self) raises -> Int:
        """Result-returning handler-frame arm. Returns a POD step code (the
        caller maps it: e.g. 0=DONE, 1=PARKED, ...). REQUIRED — a payload that
        only uses `run` implements this as an explicit `return STEP_DONE`. (See
        the dispatch finding above: a trait-DEFAULT body would be statically
        bound by the generic trampoline and shadow the override)."""
        ...


# =============================================================================
# ErasedStepResult — the ONE unified type-erased step outcome.
# =============================================================================
# The result-type CONVERGENCE: this is
# now the SINGLE step-outcome type for BOTH erasure arms — the reactor-free
# task/queue arm AND the reactor-threaded handler-frame arm. It SUBSUMES (and
# fully RETIRES) `erased_frame.mojo:_ErasedStepResult`.
#
# A POD discriminant code + op_id + an OPTIONAL heap-boxed, type-erased Movable
# result + an OPTIONAL error String + an OPTIONAL heap-boxed EMIT chunk. Carries
# NO result type parameter, so ONE consumer can hold step outcomes of N work /
# handler types in one shape. The concrete result is reconstructed via
# `take_result[R]()` / `take_response[R]()` (the blessed pointer-rule
# `OwnedPointer.into_inner()` primitive — NO raw `take_pointee`).
#
# WHY the handler fields fold in HERE (the directive's result-type convergence):
# the handler DONE response rides the SAME `_result_blob` slot the task-arm
# result uses (`take_response` IS `take_result` — one heap-box, one unbox
# primitive). The handler ERR text rides `_err`. The RESERVED streaming EMIT
# chunk rides `_chunk_blob` (PARALLEL to `_result_blob`). The frame-ROUTING ids
# (`request_id` / `parked_op_id`) are NOT here — they are driver bookkeeping on
# the `ErasedHandlerFrame` wrapper, not step OUTPUT. So this ONE result
# converges both arms with NO per-arm result type.

comptime STEP_PARKED: Int = 0  # awaiting a (biased) op_id; carries op_id
comptime STEP_DONE: Int = 1  # terminal; carries the optional heap-boxed result
comptime STEP_ERR: Int = 2  # unrecoverable; carries an error String
# RESERVED (streaming-readiness — NOT produced by any live trampoline): one
# stream chunk heap-boxed in `_chunk_blob` + a GENERIC biased resume op_id.
comptime STEP_EMIT: Int = 3  # RESERVED: one stream chunk + stay resumable


@fieldwise_init
struct ErasedStepResult(Movable, Deinitable):
    """The ONE unified type-erased step outcome (both erasure arms): a POD code +
    op_id + an optional heap-boxed result + an optional error String + an
    optional (RESERVED) heap-boxed EMIT chunk.

    Movable, NOT Copyable: it owns the heap-boxed result / chunk. Consumed
    EXACTLY ONCE — `take_result[R]()` / `take_response[R]()` unboxes the result
    (running R's destructor implicitly when the returned value drops), OR if
    never unboxed the box's `__del__` frees the raw bytes (which would LEAK R's
    heap fields if R has any — the consumer ALWAYS unboxes a DONE result before
    dropping). The RESERVED EMIT `_chunk_blob` follows the SAME consume-once
    contract via `take_chunk[Chunk]()`."""

    var _code: Int
    var _op_id: Int64
    # Heap-boxed, type-erased result/response (None for codes that carry no
    # result). The raw bytes are an `alloc[R](1) + init_pointee_move` home,
    # bitcast UInt8.
    var _result_blob: Optional[OwnedPointer[UInt8]]
    # The error text on STEP_ERR (empty otherwise). The handler ERR arm carries
    # the handler's message; the task arm leaves it empty.
    var _err: String
    # RESERVED: heap-boxed, type-erased EMIT chunk — a SECOND payload PARALLEL to
    # `_result_blob` (None for PARKED / DONE / ERR). Same alloc/bitcast/own
    # shape; reconstructed by `take_chunk[Chunk]()`. Unused until EMIT lands.
    var _chunk_blob: Optional[OwnedPointer[UInt8]]

    @staticmethod
    def done(var result_blob: OwnedPointer[UInt8]) -> ErasedStepResult:
        return ErasedStepResult(
            _code=STEP_DONE,
            _op_id=Int64(0),
            _result_blob=Optional[OwnedPointer[UInt8]](result_blob^),
            _err=String(""),
            _chunk_blob=Optional[OwnedPointer[UInt8]](),
        )

    @staticmethod
    def done_empty() -> ErasedStepResult:
        return ErasedStepResult(
            _code=STEP_DONE,
            _op_id=Int64(0),
            _result_blob=Optional[OwnedPointer[UInt8]](),
            _err=String(""),
            _chunk_blob=Optional[OwnedPointer[UInt8]](),
        )

    @staticmethod
    def parked(op_id: Int64) -> ErasedStepResult:
        return ErasedStepResult(
            _code=STEP_PARKED,
            _op_id=op_id,
            _result_blob=Optional[OwnedPointer[UInt8]](),
            _err=String(""),
            _chunk_blob=Optional[OwnedPointer[UInt8]](),
        )

    @staticmethod
    def error() -> ErasedStepResult:
        """The reactor-free task arm's ERR (no message)."""
        return ErasedStepResult(
            _code=STEP_ERR,
            _op_id=Int64(0),
            _result_blob=Optional[OwnedPointer[UInt8]](),
            _err=String(""),
            _chunk_blob=Optional[OwnedPointer[UInt8]](),
        )

    @staticmethod
    def error_msg(err: String) -> ErasedStepResult:
        """The handler-frame arm's ERR — carries the handler's error message
        (the `_ErasedStepResult.error(err)` fold)."""
        return ErasedStepResult(
            _code=STEP_ERR,
            _op_id=Int64(0),
            _result_blob=Optional[OwnedPointer[UInt8]](),
            _err=err,
            _chunk_blob=Optional[OwnedPointer[UInt8]](),
        )

    @staticmethod
    def emit(
        var chunk_blob: OwnedPointer[UInt8], op_id: Int64
    ) -> ErasedStepResult:
        """RESERVED (streaming-readiness — NOT yet produced by any trampoline):
        one heap-boxed stream chunk + the GENERIC biased resume op_id. The chunk
        is the erased parallel of the DONE response box; reconstructed by
        `take_chunk[Chunk]()`. Folds `_ErasedStepResult.emit` so the erased EMIT
        discriminant is constructible the moment the EMIT machinery lands."""
        return ErasedStepResult(
            _code=STEP_EMIT,
            _op_id=op_id,
            _result_blob=Optional[OwnedPointer[UInt8]](),
            _err=String(""),
            _chunk_blob=Optional[OwnedPointer[UInt8]](chunk_blob^),
        )

    @always_inline
    def code(self) -> Int:
        return self._code

    @always_inline
    def op_id(self) -> Int64:
        return self._op_id

    @always_inline
    def is_parked(self) -> Bool:
        return self._code == STEP_PARKED

    @always_inline
    def is_done(self) -> Bool:
        return self._code == STEP_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._code == STEP_ERR

    @always_inline
    def is_emit(self) -> Bool:
        """RESERVED: True iff this is the erased EMIT variant. No live trampoline
        produces it yet; the predicate exists so the driver's exhaustive switch
        can route it (today: to the safe ERR arm)."""
        return self._code == STEP_EMIT

    @always_inline
    def has_result(self) -> Bool:
        return Bool(self._result_blob)

    def err_text(self) -> String:
        return self._err

    def take_result[R: Movable & Deinitable](mut self) -> R:
        """Reconstruct the concrete `R` from the heap-boxed result and move it
        out (consuming the box). Caller MUST check `has_result()` first.

        SAFETY: the box was produced as `alloc[R](1) + init_pointee_move(r) +
        bitcast[UInt8]()`, so its bytes ARE a valid `R` (the seam supplies the
        SAME `R` the producer used). `unsafe_leak()` relinquishes the UInt8
        box's free, the bytes are retyped to `R*`, an `OwnedPointer[R]` is
        reconstructed over the SAME allocation, and `OwnedPointer.into_inner()` moves
        the `R` out + frees in one shot — no double-free. The blessed
        partial-move primitive (NO raw `take_pointee`). The pointer never
        escapes this body."""
        var box = self._result_blob.take()
        var raw = box^.unsafe_take_allocation().unsafe_leak()
        var owned = OwnedPointer[R](unsafe_from_raw_pointer=raw.bitcast[R]())
        return owned^.into_inner()

    def take_response[R: Movable & Deinitable](mut self) -> R:
        """Handler-frame ALIAS of `take_result` (the `_ErasedStepResult.
        take_response[Resp]` fold). The handler DONE response rides the SAME
        `_result_blob` slot as the task-arm result, so the unbox primitive is
        identical — ONE result type, ONE consume primitive."""
        return self.take_result[R]()

    def take_chunk[Chunk: Movable & Deinitable](mut self) -> Chunk:
        """RESERVED (streaming-readiness): reconstruct the concrete `Chunk` from
        the heap-boxed EMIT chunk and move it out — the SAME unbox shape as
        `take_result` (the blessed pointer-rule OwnedPointer.into_inner primitive, no
        raw take_pointee). Caller MUST check `is_emit()` first. Unused until the
        EMIT machinery lands; defined now so the parallel chunk payload has its
        consume primitive reserved alongside `take_result`.

        SAFETY: identical to `take_result` — the box was produced as
        `alloc[Chunk](1) + init_pointee_move + bitcast[UInt8]()`, so its bytes
        ARE a valid `Chunk` (the seam supplies the SAME `Chunk` the producer
        used)."""
        var box = self._chunk_blob.take()
        var raw = box^.unsafe_take_allocation().unsafe_leak()
        var owned = OwnedPointer[Chunk](
            unsafe_from_raw_pointer=raw.bitcast[Chunk]()
        )
        return owned^.into_inner()


# =============================================================================
# Thin fn-ptr trampoline signatures (POD function-pointer types).
# =============================================================================
# The wildcard origin (`MutExternalOrigin`) is CONFINED to these comptime
# ALIASES (NOT a struct field). The producer (`make_erased`) and the consumer
# (the driver, blind) monomorphize the trampoline separately on opposite sides
# of the type-erasure boundary; the byte pointer is the unavoidable
# type-erasure handle. SAME FFI-POD fn-ptr carve-out (`_RunFn` / `_DropFn`)
# that `_TaskEntry` + `ErasedFrame` ship — a code pointer, no heap.


# `_RunFn` — the void task/queue arm: step the type-erased work in-place,
# returns nothing (the `_TaskEntry.run_fnptr` shape). Reactor-FREE (no step
# context) — the task/queue/dispatch arm uses this.
comptime _RunFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
) raises thin -> None


# `_StepFn[Ctx]` — the result-returning step arm, GENERALIZED over a step-CONTEXT
# `Ctx` (the E1-erasure-fold). The trampoline takes the byte ptr to the work's
# heap home + a per-call `mut Ctx` borrow + returns an `ErasedStepResult` (the
# heap-boxed result rides inside). For the task arm `Ctx = NoContext` (empty,
# ignored); for the handler-frame arm `Ctx = Reactor[S]` (the reactor IS the
# step context — the `erased_frame.mojo:_StepFn[S]` fold). Because `Ctx` is a
# parameter of the alias, ONE `ErasedHandle[Ctx]` struct carries BOTH arms;
# the `mut Ctx` carries through the thin fn-ptr with no wildcard leak.
comptime _StepFn[Ctx: Movable & Deinitable] = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],
    mut Ctx,
) raises thin -> ErasedStepResult


# `_DropFn` — destroy the type-erased work AND free its home buffer in ONE shot:
# reconstruct an `OwnedPointer[W]` over the raw home bytes (whose free
# `ErasedHandle.__del__` already relinquished via `unsafe_leak()`) and `.into_inner()` it,
# so `W.__del__` + the buffer free are a SINGLE tracked consume. This avoids the
# two-step `destroy_pointee()`-then-separate-`free()` double-free of a W with a
# nested heap-owning field under Mojo 1.0.0b1.
comptime _DropFn = def (UnsafePointer[UInt8, MutUntrackedOrigin]) thin -> None


# =============================================================================
# ErasedHandle — the dual-step manual-vtable type-erasure handle.
# =============================================================================
# Subsumes `_TaskEntry` (void run arm) AND `ErasedFrame[S]` (result step arm) by
# erasing the work type W: `OwnedPointer[W]` → `OwnedPointer[UInt8]` home +
# `_run_fn` / `_step_fn` / `_drop_fn`. The ONE blessed wildcard site.


struct ErasedHandleBase[Ctx: Movable & Deinitable = NoContext](
    Movable, Deinitable
):
    """A type-erased, heap-owning handle over ONE concrete work payload,
    erasing the payload type entirely, GENERALIZED over a step-CONTEXT `Ctx`
    (the E1-erasure-fold). The ONE family base; drivers hold a
    `Slab[ErasedHandleBase[Ctx]]` of N distinct payload types and run / step each
    BLIND.

    `Ctx` DEFAULTS to `NoContext`. TWO instantiations (ONE struct, ONE
    mechanism):
      * the TASK/QUEUE/DISPATCH arm is the comptime alias `ErasedHandle`
        (== `ErasedHandleBase[NoContext]`, reactor-free) — `make_erased` /
        `make_borrowed_erased`. The bare `ErasedHandle` alias preserves the
        channel-element type identity across the whole hot path (ZERO ripple),
        because a bare default struct parameter does NOT resolve in a
        type-PARAMETER position (`MpscSender[ErasedHandleBase]` is non-concrete);
        the alias supplies the `[NoContext]` binding so `MpscSender[ErasedHandle]`
        stays concrete. Its `step` threads (and ignores) an empty `NoContext`.
      * the HANDLER-FRAME arm is `ErasedHandleBase[Reactor[S]]` — the reactor IS
        the step context — via `make_handler_erased[H, S]`. This is the
        `erased_frame.mojo:ErasedFrame[S]` fold: ONE generic struct, two
        instantiations.

    Field set (safe across destroy-recreate; the wildcard lives ONLY in the fn-ptr ALIASES):
      * `_home`    — heap-owning, type-erased home of the concrete payload
                     (CONCRETE origin via OwnedPointer, ASAP-tracked).
      * `_run_fn`  — FFI-POD thin fn-ptr (void task/queue arm; reactor-free).
      * `_step_fn` — FFI-POD thin fn-ptr (result-returning step arm; threads
                     `mut Ctx`).
      * `_drop_fn` — FFI-POD thin fn-ptr (runs the payload destructor in-place).

    Consumed EXACTLY ONCE: `run`/`step` use the payload IN-PLACE (no consume, may
    be called many times); `__del__` relinquishes `_home`'s free (`unsafe_leak()`)
    and hands the raw bytes to `_drop_fn`, which reconstructs ONE
    `OwnedPointer[W]` and destroys+frees in a single tracked consume (exactly
    once). Per-dispatch / per-task / per-request, NOT a destroy-recreate pool
    field — so NOT the destroy-recreate lifecycle shape.
    """

    # `_home` owns the raw bytes of the concrete payload (an `alloc[W](1) +
    # init_pointee_move(work) + bitcast[UInt8]()` home). CONCRETE origin. On
    # teardown, `__del__` `unsafe_leak()`s the bytes out of `_home` (relinquishing
    # its free) and the `_drop_fn` reconstructs a single `OwnedPointer[W]` that
    # runs `W.__del__` + frees the buffer in ONE tracked consume — so a W with a
    # nested heap-owning field is never double-freed (the Trap-1 / destroy-recreate hazard
    # the prior two-step `destroy_pointee()`-then-separate-free shape hit).
    var _home: OwnedPointer[UInt8]

    # FFI-POD fn-ptr field (pointer-rule carve-out — code pointer, no heap; the
    # wildcard in the alias signature is the type-erasure handle, identical to
    # `_TaskEntry.run_fnptr`). The void task/queue arm (reactor-free).
    var _run_fn: _RunFn

    # FFI-POD fn-ptr field (same carve-out). The result-returning step arm;
    # threads `mut Self.Ctx` and returns an `ErasedStepResult` carrying the
    # heap-boxed result.
    var _step_fn: _StepFn[Self.Ctx]

    # FFI-POD fn-ptr field (same carve-out) — runs the W destructor in-place
    # over the home bytes on handle drop.
    var _drop_fn: _DropFn

    def __init__(
        out self,
        var home: OwnedPointer[UInt8],
        run_fn: _RunFn,
        step_fn: _StepFn[Self.Ctx],
        drop_fn: _DropFn,
    ):
        self._home = home^
        self._run_fn = run_fn
        self._step_fn = step_fn
        self._drop_fn = drop_fn

    def run(mut self) raises:
        """Drive the type-erased work via the VOID task/queue arm, BLIND.

        SAFETY: `_home` owns the work's heap home for this handle's lifetime; we
        form a `MutExternalOrigin` byte pointer to it (the type-erasure handle
        the trampoline expects) and invoke `_run_fn`. The trampoline
        reinterprets the byte ptr back to the concrete W in-body (it was bound
        to `_erased_run_for[W]` for the SAME W at `make_erased` time). The
        pointer is dereferenced synchronously on this stack; W is used IN-PLACE
        (not moved/freed) so the handle stays runnable. The wildcard origin is
        confined to this cast-site body — it is NOT a struct field."""
        var p = self._home.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
        self._run_fn(p)

    def step(mut self, mut ctx: Self.Ctx) raises -> ErasedStepResult:
        """Drive the type-erased work via the RESULT-RETURNING step arm, BLIND,
        threading the step-context `Ctx` (the `erased_frame.mojo:ErasedFrame.
        step(reactor)` fold). Returns an `ErasedStepResult` (the heap-boxed
        result rides inside, reconstructed by the caller via `take_result[R]()` /
        `take_response[R]()`). For the task arm `Ctx == NoContext` (the empty
        context is threaded + ignored — see `step_no_ctx`); for the handler arm
        `Ctx == Reactor[S]` (the reactor IS the step context).

        SAFETY: identical to `run` — the byte ptr is reinterpreted to the SAME
        W the producer bound `_erased_step_for[W]` / `_erased_handler_step_for[H,
        S]` to; W is used in-place. The wildcard origin is confined to this
        cast-site body."""
        var p = self._home.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
        return self._step_fn(p, ctx)


    def __deinit__(deinit self):
        """Destroy the type-erased work AND free its home buffer in ONE shot via
        `_drop_fn`. We RELINQUISH `_home`'s own free first (`unsafe_leak()`) so the
        single owner of the bytes for the teardown is the `OwnedPointer[W]` the
        drop trampoline reconstructs — which runs `W.__del__` and frees the
        allocation atomically (`OwnedPointer.into_inner()` / `.__del__`). This is the
        SAME single-owner reconstruct-and-free shape `ErasedStepResult.
        take_result` uses (the blessed pointer-rule primitive), and it avoids the
        two-step `destroy_pointee()`-then-separate-`free()` shape — which
        double-frees a W with a nested heap-owning field (e.g. an inner
        `OwnedPointer`) under Mojo 1.0.0b1, since the in-place `destroy_pointee`
        + the separate buffer free are not seen as ONE consume of W's storage.

        SAFETY: `_home` owns the W's heap home; we `unsafe_leak()` to relinquish
        its free (so it does NOT also free the buffer), hand the raw bytes to
        `_drop_fn` which reconstructs an `OwnedPointer[W]` over the SAME
        allocation and runs the destroy+free in one shot. The wildcard origin is
        confined to this cast-site body. Runs exactly once per handle."""
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._drop_fn(raw)


# =============================================================================
# ErasedHandle — the TASK/QUEUE/DISPATCH arm identity (the reactor-free
#       comptime alias).
# =============================================================================
# The SOLE channel-element type across the entire task/queue + dispatch hot path:
# `MpscSender[ErasedHandle]`, `MpscReceiver[ErasedHandle]`,
# `mpsc_channel[ErasedHandle]`, `Slab[OwnedPointer[MpscSender[ErasedHandle]]]`,
# the worker drain, spawner, dispatcher borrowed-pool fast path (~54 refs across
# 7 files). It MUST be a CONCRETE type in a type-PARAMETER position — and a bare
# default struct parameter (`ErasedHandleBase`) does NOT resolve there (Mojo
# 1.0.0b1: `MpscSender[ErasedHandleBase]` is non-concrete). This comptime alias
# supplies the `[NoContext]` binding so the hot path keeps spelling `ErasedHandle`
# bare with ZERO ripple — the channel-element identity (and the entire
# hot path) is preserved EXACTLY.
comptime ErasedHandle = ErasedHandleBase[NoContext]


# =============================================================================
# make_erased — heap-box a concrete ErasableWork W into an ErasedHandle.
# =============================================================================


def make_erased[W: ErasableWork](var work: W) -> ErasedHandle:
    """Erase a concrete work `W` into an `ErasedHandle` (the reactor-free task
    arm, `Ctx == NoContext`). Heap-boxes `work` into a `_home` and binds the
    TOP-LEVEL parametric trampolines `_erased_run_for[W]` / `_erased_step_for[W]`
    / `_erased_drop_for[W]` (NOT nested closures — the load-bearing correction).

    PUBLIC signature is pointer-free: takes `var work: W` (consumed), returns
    `ErasedHandle[NoContext]` (spellable bare as `ErasedHandle`) by move.

    SAFETY: `alloc[W](1)` returns a concrete-origin pointer we own; we
    move-construct `work` into it (`init_pointee_move`), then bitcast to a
    `UInt8` home wrapped in an `OwnedPointer[UInt8]` (single owner; its drop
    frees the raw allocation; W's destructor is run in-place by
    `_erased_drop_for[W]` in `ErasedHandle.__del__` first). Same alloc/bitcast/
    own shape as `make_erased` in `erased_frame.mojo`."""
    var home_typed = alloc[W](1)
    # SAFETY: fresh allocation we own; in-place move-construct the work into it.
    UnsafePointer(to=home_typed[]).unsafe_write(work^)
    var home = OwnedPointer[UInt8](
        unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
    )
    # TOP-LEVEL parametric trampolines captured as thin fn-ptrs. NOT closures.
    var run_t = _erased_run_for[W]
    var step_t = _erased_step_for[W]
    var drop_t = _erased_drop_for[W]
    return ErasedHandle(home^, run_t, step_t, drop_t)


# =============================================================================
# make_borrowed_erased — the BORROWED/POOLED family member.
# =============================================================================
# The SECOND ownership mode of the ErasedHandle family.
# `make_erased` is OWNING: it heap-boxes the work and `__del__` frees the
# home. `make_borrowed_erased` is BORROWED/POOLED: the work bytes ALREADY live in
# a CALLER-OWNED home (the dispatcher's `_shard_buf` byte-slab —,
# zero per-shard alloc); the handle carries a NON-OWNING byte ptr to them + the
# SAME run/step vtable. The ONLY difference is the drop arm: `_borrowed_noop_drop`
# does NOTHING (the pool owns + reuses the bytes), where `_erased_drop_for[W]`
# destroys+frees. This is EXACTLY `_TaskEntry`'s existing dispatcher shape
# (`task_raw` -> pooled `_shard_buf` slot + `_noop_drop` drop_fnptr), now a NAMED
# member of the ErasedHandle family.
#
# ZERO HEAP ALLOC (the whole point — the dispatcher hot fork-join path): this
# constructor allocates NOTHING. It wraps the caller's pool byte ptr in an
# `OwnedPointer[UInt8]` ONLY as the family base's run/drop target — but that
# OwnedPointer's free is RELINQUISHED in `ErasedHandle.__del__` (via `unsafe_leak()`,
# the SAME single-consume teardown as the owning mode), and the BORROWED
# `_drop_fn` is a no-op, so the pool bytes are NEVER freed by the handle. The
# pool's own teardown frees them exactly once.
#
# CONSUME-ONCE CONTRACT (the run vs drop arms): for a payload `W` whose `run`
# CONSUMES its state (the spawner's run-then-free model), the borrowed handle must
# run the SAME consume the owning model's `run`+`__del__` did — see the spawner
# migration: `_SpawnedTaskHeader.run` runs the task IN-PLACE + publishes, and the
# borrowed `__del__` no-op leaves the heap home to the spawner's owning home (the
# spawner uses make_erased, NOT this). For the DISPATCHER (`_DispatchShard`, POD,
# no heap-owning interior), `run` reads the shard bytes in-place + loops; the pool
# reuses the bytes next dispatch with an overwriting `init_pointee_move`/memcpy.


def make_borrowed_erased[W: ErasableWork](
    home_byte: UnsafePointer[UInt8, MutUntrackedOrigin],
) -> ErasedHandle:
    """Erase a concrete work `W` whose bytes ALREADY live in a CALLER-OWNED home
    (the pool / slab) into a BORROWED `ErasedHandle`. The handle runs / steps the
    SAME per-W vtable as `make_erased`, but its drop arm is `_borrowed_noop_drop`
    — it does NOT free the home (the pool owns + reuses the bytes). ZERO heap
    alloc.

    SAFETY: `home_byte` is a byte ptr into a caller-owned home (e.g. the
    dispatcher's `_shard_buf` slab slot) holding a valid moved-in `W` (the
    producer wrote it via `init_pointee_move` / memcpy at dispatch entry). We wrap
    it in an `OwnedPointer[UInt8]` ONLY to satisfy the family base's `_home` field
    — its free is RELINQUISHED by `ErasedHandle.__del__` (`unsafe_leak()`) before the
    `_drop_fn` runs, and the borrowed `_drop_fn` (`_borrowed_noop_drop`) does
    NOTHING, so the pool bytes are never freed by this handle. The borrow's
    lifetime is bounded by the producer's contract (the dispatcher's wake-word
    barrier holds the pool alive until every shard's `run` returns; the consumer
    runs the handle synchronously on the worker pthread, then drops it). The
    wildcard origin is the same byte-ptr type-erasure handle the channel crossing
    requires (the blessed `_TaskEntry.task_raw` carve-out); it is confined to this
    parameter + the `_home` cast, NEVER a struct FIELD."""
    # SCHED-TRACE: the erasure VOLUME + the enqueue-loop dispatch
    # WALL (bucket c) are attributed at the SOLE call site
    # (LocalDispatcher.run_with_state — this is the only caller; grep confirms)
    # via `sched_trace_add_dispatch(enqueue_ns, n_workers)`. Counting there (once
    # per dispatch, gated on the cached `_sched_on` field) rather than here (once
    # per erasure, needing a per-erasure env probe) keeps the OFF hot path at
    # ZERO external_call — the <1%-overhead-when-off HARD REQUIREMENT. If a second
    # caller of make_borrowed_erased ever appears, move the count here.
    #
    # Wrap the caller's pool byte ptr as the family base's run/drop target. NO
    # alloc — the bytes already live in the pool. The OwnedPointer is a POD 8-byte
    # handle; its free is relinquished in __del__ (unsafe_leak()) and the borrowed
    # _drop_fn no-ops, so the pool bytes outlive the handle.
    var home = OwnedPointer[UInt8](unsafe_from_raw_pointer=home_byte)
    var run_t = _erased_run_for[W]
    var step_t = _erased_step_for[W]
    var drop_t: _DropFn = _borrowed_noop_drop
    return ErasedHandle(home^, run_t, step_t, drop_t)


def _borrowed_noop_drop(
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
):
    """The BORROWED-mode drop trampoline — a NO-OP. The pool (caller) owns + frees
    the home bytes; the borrowed handle must NOT touch them on drop. Identical to
    the dispatcher's prior `_noop_drop` `_TaskEntry.drop_fnptr`. The `p` byte ptr
    (which `ErasedHandle.__del__` `unsafe_leak()`'d out of `_home`) points into the
    caller-owned pool — we deliberately do nothing with it.

    SAFETY: by contract `p` is a borrowed byte ptr into a pool the caller owns;
    the no-op is the correct drop for a non-owning handle. The pointer never
    escapes."""
    pass


# =============================================================================
# Top-level parametric trampolines (the manual vtable bodies).
# =============================================================================
# Captured as thin fn-ptrs by `make_erased`; invoked BLIND by the driver. Each
# reinterprets the byte ptr back to the concrete W in-body. FREE FUNCTIONS, not
# nested closures (the load-bearing correction; `_erased_step_for` in
# `erased_frame.mojo` is the precedent).


def _erased_run_for[W: ErasableWork](
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
) raises -> None:
    """Per-W VOID-arm trampoline. Reinterpret the byte ptr to `W` IN-PLACE and
    call `W.run()` — which dispatches to the CONCRETE `W`'s `run` because
    `ErasableWork.run` is REQUIRED (no trait default to statically shadow it; see
    the dispatch finding on the trait).

    SAFETY: `p` is the byte ptr to W's heap home (the `_home` `make_erased`
    allocated for THIS W). We bitcast it back to `W*` — valid because the handle
    was created by `make_erased[W]` binding THIS trampoline for THIS W. W is
    used IN-PLACE (`run` takes `mut self`); it is NOT moved or freed here. The
    pointer is dereferenced synchronously on this stack; it never escapes."""
    var work_ptr = p.bitcast[W]()
    work_ptr[].run()


def _erased_step_for[W: ErasableWork](
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
    mut ctx: NoContext,
) raises -> ErasedStepResult:
    """Per-W RESULT-arm trampoline (the reactor-FREE task arm — `Ctx ==
    NoContext`). Reinterpret the byte ptr to `W` IN-PLACE, call `W.step()` (the
    CONCRETE `W`'s `step` — `ErasableWork.step` is REQUIRED, so no trait default
    shadows it), and wrap the POD step code in an `ErasedStepResult`. The empty
    `NoContext` is threaded by the `_StepFn[NoContext]` signature + IGNORED (the
    task arm needs no step context). A payload that produces a heap-boxed Movable
    result uses its own producer trampoline instead (see the test); this generic
    trampoline maps the POD code: STEP_DONE → done_empty, STEP_PARKED →
    parked(op), else → error.

    SAFETY: identical to `_erased_run_for` — `p` is reinterpreted to the SAME W
    the producer bound; W is used in-place; the pointer never escapes. The
    `NoContext` carries no state."""
    var work_ptr = p.bitcast[W]()
    var code = work_ptr[].step()
    if code == STEP_PARKED:
        return ErasedStepResult.parked(Int64(0))
    elif code == STEP_DONE:
        return ErasedStepResult.done_empty()
    else:
        return ErasedStepResult.error()


@always_inline
def single_consume_drop[W: Movable & Deinitable](
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
):
    """THE single-consume teardown primitive — ONE source of truth for the
    dual-step-drop finding. Destroy a concrete `W`
    AND free its home buffer in ONE shot by reconstructing an `OwnedPointer[W]`
    over the home bytes and `.into_inner()`-ing it, so `W.__del__` + the buffer free are
    a SINGLE tracked consume.

    Both erasure trampolines call this so the finding cannot rot into two
    near-identical copies: `_erased_drop_for[W]` (this module) AND
    `segment_desc_registry.seg_destroy_for[W]` (komira_engine_dispatch, the
    `SegStateBox` teardown). `@always_inline` so an address-taken
    trampoline keeps its own out-of-line symbol (the nm-gate `seg_destroy_for`
    count) while this helper contributes ZERO out-of-line mass — DRY without an
    elaboration delta.

    WHY single-shot (NOT `destroy_pointee()` + a separate buffer free): under
    Mojo 1.0.0b1/b2, the two-step shape (run `W.__del__` in-place via
    `destroy_pointee`, then free the raw byte home via a separate
    `OwnedPointer[UInt8]`) double-frees a `W` that has a NESTED heap-owning field
    (e.g. an inner `OwnedPointer[Int]` / `List` at a realistic offset): the
    in-place destroy + the separate byte-free are not tracked as ONE consume of
    W's storage, so the inner field's home is freed twice (a heap-corruption that
    only trips on a later allocation — the destroy-recreate/Trap-1 family). Reconstructing
    ONE `OwnedPointer[W]` and `.into_inner()`-ing it makes the destroy+free a single
    tracked consume — the SAME blessed pointer-rule shape `take_result` uses.

    # SAFETY: `p` is the raw byte home of a valid `W` placed by the caller's
    # `alloc[W](1) + init_pointee_move`, whose OwnedPointer free was RELINQUISHED
    # by the owning handle's `__del__` (`unsafe_leak()`) BEFORE this call, so this
    # helper is the SOLE owner of the bytes for teardown. We retype `p` to `W*`,
    # reconstruct an `OwnedPointer[W]` over the SAME allocation, and `.into_inner()` to
    # move the `W` out (running `W.__del__` on its heap fields) + free the buffer
    # in one shot. The moved-out `W` drops at the end of this statement. No
    # double-free; the raw pointer never escapes this body. The wildcard origin is
    # the erasure-internals raw-home carve-out ((a) FFI-POD) confined here."""
    var owned = OwnedPointer[W](unsafe_from_raw_pointer=p.bitcast[W]())
    var work = owned^.into_inner()
    _ = work^


def _erased_drop_for[W: ErasableWork](
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
):
    """Per-W drop trampoline (address-taken by `make_erased`). Forwards to the
    shared `single_consume_drop[W]` primitive (review C1 — ONE source of truth for
    the dual-step-drop finding, documented there). `ErasableWork` refines
    `Movable & Deinitable`, so `W` binds `single_consume_drop`'s
    bound.

    SAFETY: see `single_consume_drop`. `p` is the raw byte home of a valid `W`
    placed by `make_erased[W]`, whose free was RELINQUISHED by
    `ErasedHandle.__del__` (`unsafe_leak()`) — this trampoline is the sole owner for
    teardown; the pointer never escapes."""
    single_consume_drop[W](p)


# =============================================================================
# HANDLER-FRAME arm trampolines + make_handler_erased (the ErasedFrame
#       fold).
# =============================================================================
# The reactor-THREADED arm: erase a concrete `H: SuspendableHandler` into an
# `ErasedHandle[Reactor[S]]` (`Ctx == Reactor[S]`). This folds
# `erased_frame.mojo`'s `make_erased[H, S]` + `_erased_step_for[H, S]` +
# `_erased_drop_for[H]` onto the SAME family struct — ONE type-erasure mechanism,
# two instantiations (`NoContext` task arm / `Reactor[S]` handler arm).
#
# The step trampoline calls `H.step[S](reactor) -> HandlerStepResult[H.Resp]` and
# ERASES the result through the EXHAUSTIVE switch into the unified
# `ErasedStepResult`: a DONE response is heap-boxed into the `_result_blob` slot
# (so the result carries no `Resp` param), PARKED carries the op_id, ERR carries
# the message (the `_err` slot), EMIT (RESERVED) heap-boxes the chunk PARALLEL in
# `_chunk_blob`. The frame-ROUTING ids (request_id / parked_op_id) are NOT here —
# they live on the `ErasedHandlerFrame` wrapper.


def _erased_handler_run_noop(
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
) raises -> None:
    """The handler arm's VOID `_run_fn` — a NO-OP. A `SuspendableHandler` has no
    void `run` (it is driven by `step(reactor)`), so the family base's `_run_fn`
    is a no-op for the handler instantiation. The handler driver never calls
    `run()`; this satisfies the `_RunFn` field of `ErasedHandle[Reactor[S]]`.

    SAFETY: does nothing; the pointer never escapes."""
    pass


def _erased_handler_step_for[
    H: SuspendableHandler,
    S: WakerSink & Movable & Deinitable,
](
    p: UnsafePointer[UInt8, MutUntrackedOrigin],
    mut r: Reactor[S],
) raises -> ErasedStepResult:
    """Per-(H, S) handler-frame step trampoline (`Ctx == Reactor[S]`). Reinterpret
    the byte ptr to `H` IN-PLACE, call `H.step[S](r)`, and ERASE the result
    through an EXHAUSTIVE switch into the unified `ErasedStepResult` (no `else:
    done` fall-through — the same hazard the driver's switch closes): a
    DONE response is heap-boxed into the `_result_blob` slot (so the result
    carries no `Resp` param); PARKED carries the op_id; ERR carries the message;
    EMIT (RESERVED) heap-boxes the chunk PARALLEL. An unknown/reserved kind falls
    to the explicit DEFAULT → ERR arm, never silently DONE. The `erased_frame.
    mojo:_erased_step_for[H, S]` fold.

    SAFETY: `p` is the byte ptr to the SM's heap home (the `_home`
    `make_handler_erased` allocated for THIS H). We bitcast it back to `H*` —
    valid because the handle was created by `make_handler_erased[H, S]` binding
    THIS trampoline for THIS H. The SM is used IN-PLACE (`step` takes `mut self`);
    it is NOT moved or freed here — the frame stays steppable across resumes, and
    `_erased_handler_drop_for[H]` destroys it later. The pointer is dereferenced
    synchronously on this stack; it never escapes."""
    var sm_ptr = p.bitcast[H]()
    var sr = sm_ptr[].step[S](r)
    if sr.is_parked():
        return ErasedStepResult.parked(sr.op_id())
    elif sr.is_done():
        # Heap-box the Movable-not-Copyable DONE response into a UInt8 home (the
        # erased response box). Same alloc/bitcast/own shape as the SM home;
        # reconstructed by `ErasedStepResult.take_response[H.Resp]()`.
        var resp_home = alloc[H.Resp](1)
        # SAFETY: fresh allocation we own; move the DONE response into it.
        UnsafePointer(to=resp_home[]).unsafe_write(sr.take_response())
        var resp_blob = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=resp_home.bitcast[UInt8]()
        )
        return ErasedStepResult.done(resp_blob^)
    elif sr.is_error():
        return ErasedStepResult.error_msg(sr.err_text())
    elif sr.is_emit():
        # RESERVED streaming arm — NOT reachable from any live handler. When EMIT
        # lands, heap-box the chunk PARALLEL to the response box (same shape) and
        # carry the resume op_id so the erased EMIT travels through
        # `take_chunk[H.Resp]()`. Kept here so the switch is EXHAUSTIVE the moment
        # EMIT is implemented — additive, not a re-shape of the erased ABI.
        var chunk_home = alloc[H.Resp](1)
        # SAFETY: fresh allocation we own; move the EMIT chunk into it.
        UnsafePointer(to=chunk_home[]).unsafe_write(sr.take_chunk())
        var chunk_blob = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=chunk_home.bitcast[UInt8]()
        )
        return ErasedStepResult.emit(chunk_blob^, sr.op_id())
    else:
        # DEFAULT: an unknown/reserved kind — route to the explicit ERR arm,
        # never silently treated as DONE.
        return ErasedStepResult.error_msg(
            String("unknown HandlerStepResult kind in handler step trampoline")
        )


def _erased_handler_drop_for[
    H: SuspendableHandler,
](p: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """Per-H handler-frame drop trampoline. Destroy the concrete `H` SM AND free
    its home buffer in ONE shot by reconstructing an `OwnedPointer[H]` over the
    home bytes and letting its drop run `H.__del__` + free the allocation
    atomically (the SAME single-tracked-consume shape as `_erased_drop_for[W]`;
    the `erased_frame.mojo:_erased_drop_for[H]` fold). Avoids the two-step
    destroy-then-separate-free double-free of an H with a nested heap-owning field
    under Mojo 1.0.0b1.

    SAFETY: `p` is the raw byte home of a valid `H` placed by
    `make_handler_erased[H, _]` (`alloc[H](1) + init_pointee_move`), whose free
    was RELINQUISHED by `ErasedHandle.__del__` (`unsafe_leak()`), so this trampoline
    is the SOLE owner of the bytes for teardown. We retype `p` to `H*`,
    reconstruct an `OwnedPointer[H]` over the SAME allocation, and `.into_inner()` to
    move the `H` out + free in one shot. No double-free; the pointer never escapes
    this body."""
    var owned = OwnedPointer[H](unsafe_from_raw_pointer=p.bitcast[H]())
    var sm = owned^.into_inner()
    _ = sm^


def make_handler_erased[
    H: SuspendableHandler,
    S: WakerSink & Movable & Deinitable,
](var sm: H) -> ErasedHandleBase[Reactor[S]]:
    """Erase a concrete handler SM `H` into an `ErasedHandleBase[Reactor[S]]` (the
    reactor-threaded handler-frame arm). Heap-boxes `sm` into a `_home` and binds
    the TOP-LEVEL parametric trampolines `_erased_handler_step_for[H, S]` /
    `_erased_handler_drop_for[H]` + the no-op `_run_fn` (NOT nested closures). The
    `erased_frame.mojo:make_erased[H, S]` fold — minus the `request_id`, which now
    rides the `ErasedHandlerFrame` routing wrapper.

    PUBLIC signature is pointer-free: takes `var sm: H` (consumed), returns
    `ErasedHandle[Reactor[S]]` by move. The seam supplies `S == RT.Sink`.

    SAFETY: `alloc[H](1)` returns a concrete-origin pointer we own; we move-
    construct `sm` into it (`init_pointee_move`), then bitcast to a `UInt8` home
    wrapped in an `OwnedPointer[UInt8]` (single owner; its drop frees the raw
    allocation; the SM destructor is run in-place by `_erased_handler_drop_for[H]`
    in `ErasedHandle.__del__` first). Same alloc/bitcast/own shape as
    `make_erased`."""
    var sm_home = alloc[H](1)
    # SAFETY: fresh allocation we own; in-place move-construct the SM into it.
    UnsafePointer(to=sm_home[]).unsafe_write(sm^)
    var home = OwnedPointer[UInt8](
        unsafe_from_raw_pointer=sm_home.bitcast[UInt8]()
    )
    var run_t: _RunFn = _erased_handler_run_noop
    var step_t = _erased_handler_step_for[H, S]
    var drop_t = _erased_handler_drop_for[H]
    return ErasedHandleBase[Reactor[S]](home^, run_t, step_t, drop_t)


# =============================================================================
# StateBoundWork[Ctx, origin] — the generalized StateBound.
# =============================================================================
# The wildcard-FIELD-FREE generalization of `_DispatchShard[State, T]` (which
# carries SIX wildcard pointer fields). The borrowed dispatch context rides as a
# SINGLE `Pointer[Ctx, origin]` with a CONCRETE origin parameter on the STRUCT
# (the `memory_region.mojo` `ref [origin] self → ByteView[origin]` precedent),
# NOT `UnsafePointer[_, MutExternalOrigin]`. So `lint_wildcard_field.sh` (which
# gates on the wildcard origin identifiers) sees ZERO new owning wildcard
# fields.
#
# WHY ONE BORROWED `Ctx` (the load-bearing design choice): `_DispatchShard`
# carried SIX independent wildcard pointers because the wildcard erased every
# origin to the SAME widened `MutExternalOrigin` — so six distinct stack/heap
# owners could ride six fields with no origin-matching. A CONCRETE origin
# parameter cannot do that: the Mojo compiler requires every borrow bound to one
# struct `origin` to share that exact origin (it ENFORCES the lifetime relation
# the wildcard erased). The correct generalization is therefore to BUNDLE the
# per-dispatch borrowed state (State + shared Segment + in_flight + wake_word +
# error_slot + cancel) into ONE caller-owned `Ctx` value — which is precisely
# how a real per-core dispatcher owns ONE per-dispatch context frame and the
# shards borrow INTO it. Every shard then borrows the SAME `Ctx` under ONE
# `origin`. This is STRICTLY safer than the six-wildcard shape: the compiler
# tracks the one borrow, the shared Segment (a `Ctx` field) is shared by
# construction (every shard reaches the SAME `Ctx`), and there is no wildcard to
# defeat ASAP-destruction tracking.
#
# THE COMPOSITION CHECK (the keystone): this payload is itself an `ErasableWork`
# (its `run` reads the bound `Ctx` through the concrete-origin pointer). When it
# goes through `make_erased[StateBoundWork[Ctx, o]]`, the borrow-safety SURVIVES
# the erasure: the `origin` parameter is part of the erased W type, so the
# bitcast in the trampoline recovers the SAME `Pointer[Ctx, origin]` field — the
# erasure does NOT silently widen it to a wildcard. The shared Segment stays
# SHARED: it is a field of the ONE borrowed `Ctx` every shard reaches.
#
# Lifetime contract (UNCHANGED from `_DispatchShard`): the borrow is bound to
# the caller's `origin`; the dispatcher's fork-join barrier (the wake-word) MUST
# block until every shard's `run` returns before the borrowed `Ctx` can go out
# of scope. `origin` makes that contract VISIBLE to (and ENFORCED by) the
# compiler (vs the wildcard, which erased it).


struct StateBoundWork[
    Ctx: Movable & Deinitable,
    origin: Origin[mut=True],
](Movable, Deinitable, ErasableWork):
    """A per-shard work payload binding a BORROWED per-dispatch context `Ctx`
    (which bundles the State + shared Segment + per-dispatch atomics) reached by
    a SINGLE `Pointer[Ctx, origin]` — concrete origin, NOT wildcard — that rides
    `ErasedHandle`.

    The generalization of `_DispatchShard`: same fork-join contract, ZERO
    wildcard fields, and STRICTLY safer (one tracked borrow vs six wildcard
    pointers). The `origin` parameter ties the borrow to the caller's `Ctx`
    home; the dispatcher's barrier guarantees no `run` reads through it after the
    `Ctx` could go out of scope. The shared Segment is a field of `Ctx`, so it is
    SHARED by construction (every shard reaches the SAME `Ctx`).

    `run` (the void arm) is where the production body (cancel poll, first-error
    CAS, in_flight fetch_sub, futex wake, the `[lo, hi)` Segment loop) layers on
    — reaching all of it through `ctx_ref()`. This struct is intentionally
    minimal so the unit test proves the bind-through-erasure shape; the
    production `_DispatchShard` body slots onto the SAME single-borrow field set.
    """

    # Borrowed per-dispatch context home, concrete `origin` — NOT a wildcard.
    # The caller retains ownership; the barrier blocks until every `run` returns.
    var _ctx: Pointer[Self.Ctx, Self.origin]
    var _lo: Int64
    var _hi: Int64
    var _wid: Int32

    def __init__(
        out self,
        ref [Self.origin] ctx: Self.Ctx,
        lo: Int64,
        hi: Int64,
        wid: Int32,
    ):
        # Bind the borrow as a concrete-`origin` Pointer (Pointer(to=ref) ties
        # the pointer's origin to the ref's origin — NO wildcard cast).
        self._ctx = Pointer(to=ctx)
        self._lo = lo
        self._hi = hi
        self._wid = wid

    @always_inline
    def lo(self) -> Int64:
        return self._lo

    @always_inline
    def hi(self) -> Int64:
        return self._hi

    @always_inline
    def wid(self) -> Int32:
        return self._wid

    @always_inline
    def ctx_ref(self) -> ref [Self.origin] Self.Ctx:
        """Borrow the bound per-dispatch context through the concrete-origin
        pointer. The returned ref carries the SAME `origin` the borrow was bound
        to (NOT `self`) — Repro 5/5b: tie the ref to the inner pointer's origin.
        The shared Segment + State + atomics are reached as fields of this `Ctx`,
        SHARED across every shard built over the SAME `ctx`."""
        return self._ctx[]

    def run(mut self) raises -> None:
        """Void task/queue arm. This minimal generalization's `run` is an
        explicit no-op — the production `_DispatchShard` body (cancel poll,
        first-error CAS, in_flight fetch_sub, futex wake, the `[lo, hi)` Segment
        loop, all reached through `ctx_ref()`) layers on HERE. REQUIRED (not a
        trait default) so the generic erasure trampoline dispatches to THIS body
        after erasure rather than a shadowing trait-default no-op (see the
        `ErasableWork` dispatch finding)."""
        pass

    def step(mut self) raises -> Int:
        """Result arm — not this payload's arm (it is a void-`run` shard), so it
        explicitly signals DONE. REQUIRED for the same dispatch reason as `run`.
        """
        return STEP_DONE


# =============================================================================
# CarriedHandle[T, origin] — a baked-in concrete handle to a shared
#      resource.
# =============================================================================
# The env-var killer. A producer bakes a CONCRETE-origin handle to a forever-
# lived shared resource (e.g. `SharedEngine`) into the payload; the consumer
# reaches the resource via `get()` — NOT via `engine_handle.resolve_cached()` /
# `unsafe_from_address=Int` (the `compiler_miscompile_wildcard` mechanism). The
# `origin` ties the handle to the real owner's lifetime, so the compiler relates
# the handle to the owner — ASAP-destruction can NOT free the owner while the
# handle is read (the exact failure `unsafe_from_address=Int` exhibited).


struct CarriedHandle[T: AnyType, origin: Origin[mut=False]](
    Movable, Copyable, Deinitable
):
    """A baked-in, concrete-origin borrow handle to a forever-lived shared
    resource `T` (e.g. `SharedEngine`). The drop-the-env-var replacement: the
    consumer reads the resource's STRUCT FIELDS through `get()` correctly,
    because `origin` relates the handle to the REAL owner — the
    `unsafe_from_address=Int` failure (owner ASAP-freed → `num_workers()==0`,
    SIGSEGV) cannot occur. POD (a single `Pointer`); Copyable so a producer can
    bake it into N shard payloads.
    """

    var _ptr: Pointer[Self.T, Self.origin]

    def __init__(out self, ref [Self.origin] resource: Self.T):
        # Bind the handle to the resource's concrete origin (NO wildcard cast,
        # NO Int laundering).
        self._ptr = Pointer(to=resource)

    @always_inline
    def get(self) -> ref [Self.origin] Self.T:
        """Reach the shared resource through the carried concrete-origin handle.
        The returned ref carries the SAME `origin` the handle was bound to (NOT
        `self`) — Repro 5/5b."""
        return self._ptr[]


# =============================================================================
# MutCarriedHandle[T, origin] — the MUTABLE twin of CarriedHandle.
# =============================================================================
# Same env-var killer, but the carried borrow is MUTABLE: the consumer reaches
# a `mut`-requiring method on the shared resource (e.g. `SharedEngine.
# drain_worker_to_records`, which is `mut self` — it pops the per-worker ring +
# resets the arena) through `get_mut()` — NOT via `engine_handle.engine_ref()` /
# `unsafe_from_address=Int`. `CarriedHandle` (mut=False) proved the READS are
# coherent (test_shared_erasure_real_shapes.mojo PART 2); this twin extends the
# SAME concrete-origin tracking to the MUTATING drain reach the idle-hook worker
# actually needs. The `origin: Origin[mut=True]` ties the handle to the real
# owner's lifetime AND mutability — the SAME single-concrete-origin `Pointer`
# field shape `StateBoundWork` carries, so it adds ZERO owning wildcard
# field.


struct MutCarriedHandle[T: AnyType, origin: Origin[mut=True]](
    Movable, Copyable, Deinitable
):
    """A baked-in, concrete-MUTABLE-origin borrow handle to a forever-lived
    shared resource `T` (e.g. `SharedEngine`). The mutable twin of
    `CarriedHandle`: the consumer drives a `mut self` method on the resource
    (the worker DRAIN reach: `drain_worker_to_records` pops the ring + resets the
    arena) through `get_mut()`, with the heap-owning fields (`_rings` arena,
    `_dict` SiteDictionary, `_anchor`) read + written COHERENTLY because `origin`
    relates the handle to the REAL owner. The `unsafe_from_address=Int` failure
    (owner ASAP-untracked → `num_workers()==0`, SiteDictionary misses, corrupt
    arg-decode → SIGSEGV) cannot occur. POD (a single `Pointer`); Copyable so a
    producer can bake it into N hook payloads.

    Lifetime contract: the resource is the forever-root the producer borrows at
    install (where the resource + the install are both in scope with concrete
    origins); the handle is dropped (or simply stops being read) before the
    resource — for the idle hook, the runtime joins every worker BEFORE the
    EngineContext drops the engine (the join-before-drop the engine already
    relies on), so no `get_mut()` runs after the engine could go out of scope.
    """

    var _ptr: Pointer[Self.T, Self.origin]

    def __init__(out self, ref [Self.origin] resource: Self.T):
        # Bind the handle to the resource's concrete MUTABLE origin (NO wildcard
        # cast, NO Int laundering).
        self._ptr = Pointer(to=resource)

    @always_inline
    def get_mut(self) -> ref [Self.origin] Self.T:
        """Reach the shared resource MUTABLY through the carried concrete-origin
        handle, for a `mut self` method call (the worker DRAIN). The returned ref
        carries the SAME `origin` the handle was bound to (NOT `self`) —
        Repro 5/5b — so it stays a tracked mutable borrow of the real owner."""
        return self._ptr[]


# =============================================================================
# ErasedHandlerFrame[S] — the driver-side handler-frame ROUTING wrapper.
# =============================================================================
# The `erased_frame.mojo:ErasedFrame[S]` fold. `ErasedFrame`
# was a SECOND type-erasure struct (its own OwnedPointer[UInt8] home + step/drop
# fn-ptr vtable) PLUS two routing Int64s. The fold splits those responsibilities:
#
#   * the TYPE-ERASURE (home + vtable + step/drop) is now the ONE family struct
#     `ErasedHandle[Reactor[S]]` (built by `make_handler_erased[H, S]`);
#   * the frame-ROUTING bookkeeping (the conn-fd `request_id` the response writes
#     back to + the `parked_op_id` the driver keys on) is this PLAIN wrapper —
#     NO vtable, NO fn-ptrs, NO type-erasure. It just COMPOSES the ONE folded
#     handle with two POD Int64s.
#
# So `ErasedFrame[S]` (the type-erasure shape) is RETIRED — the runtime now has
# ONE type-erasure mechanism (the `ErasedHandle` family). This wrapper is pure
# routing bookkeeping, which the directive explicitly homes on "the driver-side
# frame wrapper" rather than on the erased step OUTPUT (`ErasedStepResult`).
#
# safe across destroy-recreate: the handle is a single heap blob reached via OwnedPointer (CONCRETE
# origin); the two Int64s are POD. Consumed EXACTLY ONCE (the handle's own
# single-consume teardown); the wrapper adds no extra ownership.


struct ErasedHandlerFrame[
    S: WakerSink & Movable & Deinitable,
](Movable, Deinitable):
    """A driver-side suspended-handler frame: the ONE folded
    `ErasedHandle[Reactor[S]]` (the type-erasure) + the frame-ROUTING ids. Replaces
    `erased_frame.mojo:ErasedFrame[S]` — which was a parallel type-erasure struct;
    this is a PLAIN wrapper (no vtable) over the family handle.

    Field set:
      * `_handle`       — the folded `ErasedHandle[Reactor[S]]` (heap-owning,
                          type-erased home of the concrete handler SM + the
                          step/drop vtable; CONCRETE origin via OwnedPointer).
      * `_parked_op_id` — the reactor op_id this frame is parked on (0 if not
                          parked); the driver keys the frame off it.
      * `_request_id`   — routing key (the conn fd in the server seam) so the
                          resumed handler's response writes back to the right
                          connection.

    Consumed EXACTLY ONCE (the handle's single-consume teardown). NOT a long-lived
    driver field itself (it is per-request, owned by the driver's `Slab` for its
    in-flight window) — so NOT the destroy-recreate-struct shape the wildcard-field ban
    targets.
    """

    var _handle: ErasedHandleBase[Reactor[Self.S]]
    var _parked_op_id: Int64
    var _request_id: Int64

    def __init__(
        out self,
        var handle: ErasedHandleBase[Reactor[Self.S]],
        request_id: Int64,
    ):
        self._handle = handle^
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

    def step(
        mut self, mut reactor: Reactor[Self.S]
    ) raises -> ErasedStepResult:
        """Drive the type-erased SM one step, BLIND, through the folded handle's
        `step(reactor)` arm (the reactor is the step context). The driver calls
        this without knowing the concrete handler type."""
        return self._handle.step(reactor)


def make_erased_handler_frame[
    H: SuspendableHandler,
    S: WakerSink & Movable & Deinitable,
](var sm: H, request_id: Int64) -> ErasedHandlerFrame[S]:
    """Erase a concrete handler SM `H` into an `ErasedHandlerFrame[S]` — the
    one-call route-factory entry that folds `erased_frame.mojo:make_erased[H, S]`.
    Builds the folded `ErasedHandle[Reactor[S]]` via `make_handler_erased[H, S]`
    and wraps it with the routing `request_id`.

    PUBLIC signature is pointer-free: takes `var sm: H` (consumed) + a routing
    `request_id`, returns `ErasedHandlerFrame[S]` by move."""
    var handle = make_handler_erased[H, S](sm^)
    return ErasedHandlerFrame[S](handle^, request_id)


# =============================================================================
# ErasedHandlerDriver[S, Resp] — the type-erased multiplexing driver.
# =============================================================================
# The `erased_frame.mojo:ErasedHandlerDriver[S, Resp]` fold — UNCHANGED drive
# shape, only the parked-frame element type changes from the retired
# `ErasedFrame[S]` to the routing wrapper `ErasedHandlerFrame[S]` (which composes
# the ONE folded `ErasedHandle[Reactor[S]]`), and the step result is the unified
# `ErasedStepResult` (was `_ErasedStepResult`). One driver multiplexes N DISTINCT
# concrete handler types through ONE `ParkedMorselSlab[ErasedHandlerFrame[S]]` —
# no `KomiraSuspendableHandler` sum, no per-handler driver monomorph.
#
# The only concrete type parameter besides the reactor sink `S` is the DELIVERED
# response type `Resp` (one type — `HttpResponse` — for every route), because the
# erased step result heap-boxes the DONE response type-erased and the driver
# reconstructs the concrete `Resp` at the single delivery chokepoint via
# `ErasedStepResult.take_response[Resp]()`.
#
# safe across destroy-recreate: the driver runs synchronously on the worker's own thread; the
# parked slab holds `ErasedHandlerFrame[S]` (each a single heap blob reached via
# OwnedPointer, NOT a Movable struct in a byte-slab); the delivered slab holds
# `DeliveredResponse[Resp]`. ZERO UnsafePointer in any public signature; the
# wildcard origin stays confined to the `ErasedHandle` internals.


struct ErasedHandlerDriver[
    S: WakerSink & Movable & Deinitable,
    Resp: Movable & Deinitable,
](Movable, Deinitable):
    """Per-worker multiplexing driver for TYPE-ERASED suspendable handler frames,
    parametric over the reactor sink `S` + the delivered response type `Resp`
    ONLY (never over the handler type — that is the whole point of the erasure).
    Holds the in-flight parked frames (keyed by their already-biased op_id, in a
    `ParkedMorselSlab[ErasedHandlerFrame[S]]`) + the delivered responses (in a
    `Slab[DeliveredResponse[Resp]]`).

    One driver multiplexes N DISTINCT concrete handler types: each route's factory
    builds its concrete `StagedHandler` SM and `make_erased_handler_frame[
    ConcreteH, S]`'s it into an `ErasedHandlerFrame[S]`; the driver steps each
    BLIND and reconstructs the concrete `Resp` (== `ConcreteH.Resp`, the same for
    every route) at the single delivery chokepoint. Subsumes
    `SuspendableHandlerDriver[S, H]` by erasing the `H` parameter — no
    `KomiraSuspendableHandler` sum, no per-handler driver monomorph.

    The driver is SERVE-SEAM-AGNOSTIC: it does NOT poll the reactor itself (the
    HttpServer owns the single poll loop and routes completions to `resume`). The
    demux predicate `is_parked_op_id` is the same biased-op_id check the old
    driver exposes, so the server's routing is unchanged."""

    var _parked: ParkedMorselSlab[ErasedHandlerFrame[Self.S]]
    var _delivered: Slab[DeliveredResponse[Self.Resp]]
    # Observability — concurrency-evidence counters (mirror the old driver).
    var _admit_count: Int64
    var _park_count: Int64
    var _resume_count: Int64
    var _peak_inflight: Int64

    def __init__(out self):
        self._parked = ParkedMorselSlab[ErasedHandlerFrame[Self.S]]()
        self._delivered = Slab[DeliveredResponse[Self.Resp]]()
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
        op_id one this driver is currently parked on? True iff the op_id is in the
        dynamically-allocated (biased) space AND a frame is keyed on it. Identical
        to the retired driver's `is_parked_op_id`."""
        if op_id < HANDLER_OP_ID_BIAS:
            return False
        return self._parked.contains(op_id)

    def peak_parked_op_id_for_test(self) raises -> Int64:
        """TEST-ONLY: the (biased) op_id the FIRST parked frame is keyed on, or 0
        if none."""
        if self._parked.len() == 0:
            return Int64(0)
        return self._parked.op_id_at(0)

    def _update_peak(mut self):
        var n = Int64(self._parked.len())
        if n > self._peak_inflight:
            self._peak_inflight = n

    def _deliver(
        mut self,
        var frame: ErasedHandlerFrame[Self.S],
        var sr: ErasedStepResult,
    ):
        """The DONE arm: reconstruct the concrete `Resp` from the heap-boxed,
        type-erased DONE response (`take_response[Resp]()` — the blessed
        OwnedPointer.into_inner primitive, consumed exactly once), land it
        in the delivered slab keyed by the frame's request_id (the conn fd), then
        drop the frame (its in-place SM destructor runs via the handle's drop).
        Caller has already discriminated `is_done()`."""
        var rid = frame.request_id()
        self._delivered.append(
            DeliveredResponse[Self.Resp](rid, sr.take_response[Self.Resp]())
        )
        _ = frame^

    def _deliver_err(
        mut self,
        var frame: ErasedHandlerFrame[Self.S],
        var sr: ErasedStepResult,
    ):
        """The ERR arm (and the DEFAULT / EMIT-reserved arm). An ERR result
        carries NO response (every concrete handler turns a domain error into a
        DONE(error-response) before returning — ERR is reserved for unrecoverable
        handler bugs / a not-yet-implemented kind). The driver does NOT fabricate
        a response; the seam observes no delivery for this rid and drops the conn
        (defensive). The frame drops here (its SM destructor runs)."""
        _ = sr^
        _ = frame^

    def _park(
        mut self,
        var frame: ErasedHandlerFrame[Self.S],
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
        var frame: ErasedHandlerFrame[Self.S],
        var sr: ErasedStepResult,
    ) raises -> Bool:
        """THE EXHAUSTIVE SWITCH on the erased step-result kind. Both `admit` and
        `resume` funnel through here so the terminal-vs-park decision lives in ONE
        place and is exhaustive by construction. Returns True iff the frame PARKED
        (and therefore stays in `_parked`); False iff the frame was retired
        (delivered or dropped) and no longer exists.

        Arms (NO `else: deliver` fall-through):
          * PARKED → `_park`        (frame retained, keyed by the biased op_id)
          * DONE   → `_deliver`     (response unboxed + landed; frame dropped)
          * ERR    → `_deliver_err` (no response; frame dropped, conn dropped)
          * EMIT   → RESERVED streaming arm (routes to SAFE ERR today)
          * DEFAULT → SAFE ERR arm, never silently delivered."""
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
            self._deliver_err(frame^, sr^)
            return False
        else:
            self._deliver_err(frame^, sr^)
            return False

    def admit(
        mut self,
        var frame: ErasedHandlerFrame[Self.S],
        mut reactor: Reactor[Self.S],
    ) raises -> Bool:
        """Step a freshly-admitted erased frame once, then route the result
        through the exhaustive switch. If it parks (on an already-biased reactor
        op_id from `alloc_op_id`), it is stashed keyed by that op_id and the worker
        is free to admit/serve another request. If it finishes in one step (a 401 /
        fast path / a one-step sync handler), the response is delivered
        immediately — no park. Returns True iff the frame PARKED."""
        self._admit_count = self._admit_count + Int64(1)
        var sr = frame.step(reactor)
        return self._dispatch_step_result(frame^, sr^)

    def resume(mut self, op_id: Int64, mut reactor: Reactor[Self.S]) raises:
        """Resume the frame parked on `op_id` (if any), then route the result
        through the exhaustive switch: on re-PARK the frame is re-keyed on the new
        (biased) op_id; on DONE/ERR/unknown it is delivered or retired. Non-
        matching op_ids are benign (a completion for a since-finished / unknown
        op)."""
        var maybe = self._parked.take(op_id)
        if maybe:
            self._resume_count = self._resume_count + Int64(1)
            var frame = maybe.take()
            var sr = frame.step(reactor)
            _ = self._dispatch_step_result(frame^, sr^)

    def take_delivered(mut self) -> Slab[DeliveredResponse[Self.Resp]]:
        """Move the delivered responses out (the seam writes each back to its conn
        fd; a test asserts on them)."""
        var out = self._delivered^
        self._delivered = Slab[DeliveredResponse[Self.Resp]]()
        return out^

    # -------------------------------------------------------------------------
    # Test conveniences — reactor-polling drive methods (the server seam does NOT
    # use these; they exist so the demux + multiplex can be exercised in
    # isolation without a server). Mirror the retired ErasedHandlerDriver.
    # -------------------------------------------------------------------------
    def drive_one_ready_batch(mut self, mut reactor: Reactor[Self.S]) raises:
        """Drive EXACTLY ONE poll cycle: block until at least one parked frame's
        fd is ready, drain that completion batch, and resume the matching
        frame(s). No-op when nothing is parked."""
        if self._parked.len() == 0:
            return
        var completions = reactor.poll_completions(Int32(-1))
        for ci in range(len(completions)):
            self.resume(completions[ci].op_id, reactor)

    def run_until_idle(mut self, mut reactor: Reactor[Self.S]) raises:
        """Drive parked frames to completion: until no frame is parked, poll the
        reactor for any completion, resume the matching frame."""
        var guard = 0
        while self._parked.len() > 0 and guard < 1_000_000:
            var completions = reactor.poll_completions(Int32(-1))
            for ci in range(len(completions)):
                self.resume(completions[ci].op_id, reactor)
            guard += 1


# -----------------------------------------------------------------------------
# ⚠ MOJO-1.0.0 API CHANGE -- SURFACED FOR REVIEW. ONE call site repo-wide:
# tests/test_shared_erasure.mojo:558.
#
# This was a METHOD whose `self` was re-declared at a narrower INSTANTIATION
# (`mut self: ErasedHandleBase[NoContext]`) -- valid only on the NoContext arm.
# 1.0.0 requires `self: Self` and points at a `where` clause.
#
# ★ THE `where` FIX DOES NOT REACH THIS ONE, AND THE DISTINCTION IS THE POINT.
# The CONFORMANCE
# gate -- `where conforms_to(Self.T, Trait)` -- genuinely works and DOES
# refine the body; both receiver refinements in channel/spsc.mojo stayed methods
# because of it. This gate is a type EQUALITY, which is a different animal:
#
#   `where Self.Ctx == NoContext` COMPILES, gates the call correctly, and then
#   FAILS IN THE BODY -- `l-value of type 'NoContext' cannot be converted to
#   reference of type 'Ctx'`. Equality gates the CALL and does NOT refine the
#   BODY. A `where` that typechecks is not a `where` that works; it has to be
#   forced through a real body before it is believed.
#
# Two escapes were probed and both dead-end: `var c = Self.Ctx()` (no default
# ctor is implied by the bound) and `rebind[Self.Ctx](raw^)` (rebind's result
# needs an implicit copy at the binding, and Ctx is not ImplicitlyCopyable).
#
# A free function over the CONCRETE instantiation refines both: `h` is an
# `ErasedHandleBase[NoContext]`, so `h.step(ctx)` typechecks. Semantics,
# safety argument and trampoline behaviour are unchanged.
# -----------------------------------------------------------------------------


def step_no_ctx(mut h: ErasedHandleBase[NoContext]) raises -> ErasedStepResult:
    """The reactor-FREE task/queue convenience step: construct + thread an
    empty `NoContext` so the task arm steps WITHOUT spelling a context. Only
    valid on the `NoContext` instantiation (the `ErasedHandle` alias); the
    handler arm (`ErasedHandleBase[Reactor[S]]`) uses `step(reactor)`.

    SAFETY: identical to `step` — the empty `NoContext` carries no state; the
    task-arm trampoline ignores it.

    Was `ErasedHandleBase.step_no_ctx()` before Mojo 1.0.0 — see the note
    above."""
    var ctx = NoContext()
    return h.step(ctx)
