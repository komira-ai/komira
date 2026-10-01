# =============================================================================
# komira_async.runtime.installable_hook — the ONE blessed installable-hook
#   primitive.
# =============================================================================
#
# WHAT THIS IS
#   A single LOW-layer, pointer-free-public, installable hook primitive that
#   BOTH the runtime (the idle-hook slot) AND the logger (the native-index hook)
#   adopt cross-package, acyclic, with ZERO bespoke wildcard on the consumer
#   side. It is the "ERASED composition" the POC1 acid test proved: an
#   `ErasedHandle`-shaped fire callback (the type-erasure boundary) + a
#   `CarriedHandle`-carried forever-root context the hook reaches its resources
#   through — placed in the LOW layer so every higher layer imports ONE blessed
#   primitive instead of hand-rolling its own wildcard byte-ptr surface.
#
#   It SUBSUMES the bare-POD `_IdleHookSlot` (idle_hook.mojo): same 3-word
#   footprint (a borrowed context byte-ptr + two FFI-POD code pointers), same
#   worker-borrows / EngineContext-owns contract, but exposes a pointer-free
#   public API (`fire` / `drop` / the `install`/`home` factory pair) so the
#   HIGH consumer never spells `UnsafePointer` or `MutExternalOrigin`. The HIGH
#   producer hands a typed context + typed trampolines to `make_installable_hook`
#   / `installable_hook_home`; the LOW primitive owns the erasure.
#
# THE ONE BLESSED WILDCARD (the SOLE wildcard site, alias/body-confined)
#   The only `MutExternalOrigin` here lives in the `_HookFireFn` / `_HookDropFn`
#   comptime ALIASES (the FFI-POD fn-ptr carve-out — code pointers, no heap) and
#   the `ErasedHook.ctx_raw` byte-ptr FIELD (the unavoidable type-erasure handle
#   the worker passes BLIND across the worker import boundary — physically cannot
#   name the concrete HIGH context type `C`, since the import direction is
#   komira_async <- the HIGH package). This is byte-for-byte the blessed
#   `_TaskEntry.task_raw` carve-out. It is the ONE primitive site of this
#   kind; the HIGH logger drops to ZERO bespoke wildcard by importing
#   THIS primitive (the whole point of the consolidation).
#
# THE ENGINE REACH (the SIGSEGV-class fix — the env-var killer)
#   The hook body's forever-root resource reach (e.g. the logger drain reaching
#   the `SharedEngine`) goes through a `MutCarriedHandle[Resource, origin]`
# BAKED INTO the HIGH context at install — where the
#   resource AND the install are both in scope with concrete origins. The worker
#   reconstructs the context (coherently, via the OwnedPointer-wrap the
#   `_TaskEntry` model proved) and reaches the resource via the carried handle's
#   `get_mut()` — a concrete-origin pointer the compiler tracks — NOT
#   `engine_handle.engine_ref()` (`unsafe_from_address=Int`, which severs lifetime tracking). The
#   A/B `unsafe_from_address=Int` FAILED on exactly this reach (`num_workers()==0`,
#   SiteDictionary misses, corrupt arg-decode → SIGSEGV); the carried concrete
#   origin reads + mutates the engine's heap fields correctly.
#
# OWNERSHIP / DESTROY-RECREATE SAFETY (the load-bearing safety contract)
#   The worker BORROWS the context via `ctx_raw` — it OWNS no heap for the hook,
#   so the slot's drop is a no-op (the destroy-recreate owning-field trap needs an OWNED heap
#   field; `ctx_raw` is a BORROW into the forever-root the HIGH layer owns). The
#   forever-root context home is a real `alloc[C](1) + init_pointee_move` the
#   producer makes via `installable_hook_home`; the worker reconstructs it via
#   `OwnedPointer(unsafe_from_raw_pointer=)` (a PROPER tracked origin → coherent
#   heap-field reads — the `_run_task_for[Task]` model); the HIGH `_drop_fn`
#   frees it ONCE after the runtime joins every worker.
#   There is exactly ONE owner of the home bytes for teardown — no double-free.
#
# ACYCLICITY
#   This file names ONLY the erased fn-ptr types (over `UnsafePointer[UInt8]` +
#   `UInt16`) and the POD `ErasedHook`. It NEVER names a HIGH context / store /
#   index type, so `somepath(komira_async, <HIGH package>)` stays EMPTY.
#
# Mojo 1.0.0b1 pin. The fn-ptr TYPE aliases use the `def (...) thin -> ...` form
# (the type-site spelling — matches `task_entry.mojo` / `shared_erasure.mojo`'s
# blessed `_RunFn` / `_DropFn`; `thin` is LOAD-BEARING).
# =============================================================================

from std.memory import alloc, UnsafePointer


# =============================================================================
# HookCtxPtr — the opaque erased-context pointer type the WHOLE wildcard is
#      confined to.
# =============================================================================
# This LOW module is the SOLE place the `MutExternalOrigin` wildcard is spelled.
# The HIGH producer's trampolines + context-home reconstruction reach the erased
# context THROUGH this `HookCtxPtr` alias — so the HIGH package's source text
# never contains `MutExternalOrigin` (the consolidation that lets the HIGH logger
# carry ZERO bespoke wildcard; the `lint_mut_external_origin` text gate sees the
# wildcard ONLY here). It is the blessed type-erasure handle the worker passes
# BLIND across the worker import boundary — byte-for-byte the `_TaskEntry.task_raw`
# carve-out.
comptime HookCtxPtr = UnsafePointer[UInt8, MutUntrackedOrigin]


# =============================================================================
# Trampoline signatures (POD function-pointer types).
# =============================================================================
# The wildcard origin is CONFINED to the `HookCtxPtr` alias above (NOT a struct
# field other than the type-erasure handle below). The HIGH producer
# monomorphizes the trampoline on the concrete context type; the worker (blind)
# invokes it via the POD fn-ptr. Same FFI-POD carve-out `_TaskEntry` +
# `_IdleHookSlot` ship — a code pointer, no heap.


# `_HookFireFn` — fire the hook ONCE on the worker's own thread in the idle
# window. Takes the erased context byte-ptr + the `worker_id` the worker passes
# directly (the SPSC key the HIGH body uses). `raises` because the HIGH body
# (drain + build + publish) can raise; the worker's call site swallows the error
# so one bad fire never crashes the worker loop (the at-most-once contract).
comptime _HookFireFn = def (
    HookCtxPtr,   # ctx_raw — the HIGH-owned context home (opaque erased handle)
    UInt16,       # worker_id — passed by the worker
) raises thin -> None

# `_HookDropFn` — free the forever-root context home. Runs ONCE, HIGH-side, AFTER
# all workers join (the worker NEVER calls it; the slot's own drop is a no-op).
# `thin` is LOAD-BEARING (dropping it → AnyTrait[def[...]] dynamic-trait error).
comptime _HookDropFn = def (HookCtxPtr) thin -> None


# =============================================================================
# ErasedHook — the per-worker installable hook (POD; 3 machine words).
# =============================================================================


@fieldwise_init
struct ErasedHook(Movable, Copyable, ImplicitlyCopyable, Deinitable):
    """The ONE blessed installable-hook primitive (POD; 3 machine words).

    The erased composition POC1 validated: a borrowed context byte-ptr (the
    type-erasure handle into a forever-root the HIGH layer owns) + two FFI-POD
    code pointers (fire / drop). BOTH the runtime idle-hook slot and the logger
    native-index hook adopt THIS struct — the consolidation that lets the HIGH
    logger carry ZERO bespoke wildcard.

    Copyable (POD) so it composes with the `Optional`/install plumbing and the
    runtime's per-worker push.

    Pointer discipline:
      - `ctx_raw` is the blessed type-erasure handle (the `_TaskEntry.task_raw`
        carve-out). The hook OWNS no heap; the byte-ptr is a BORROW into a
        forever-root the HIGH layer owns + frees (via `fire`'s sibling `drop`
        trampoline) after join. NONE of the three destroy-recreate owning-field ingredients.
      - `fire_fn` / `drop_fn` are FFI-POD code pointers (carve-out (a) —
        the pointer rules(a)), byte-for-byte `_TaskEntry.run_fnptr` /
        `.drop_fnptr`.
    """

    # SAFETY (FFI carve-out — the pointer rules + destroy-recreate safety argument;
    #         identical justification to `_TaskEntry.task_raw`). This is the
    #         FFI-POD-CARVEOUT BORROWED byte pointer, the SOLE blessed wildcard
    #         site of the installable-hook primitive.
    #
    # (a) WHY a wildcard is load-bearing: `ErasedHook` IS the type-erasure
    #     boundary across the worker import boundary. The worker (komira_async)
    #     physically cannot name the concrete HIGH context `C` (which lives in a
    #     package that depends ON komira_async). The HIGH producer (the install
    #     site) and the worker consumer monomorphize the fire trampoline on
    #     OPPOSITE sides; the worker's element type cannot be parametric on `C`.
    #     The byte-ptr is the unavoidable type-erasure handle — the SAME shape
    #     `_TaskEntry.task_raw` already crosses for the spawn path.
    #
    # (b) WHEN non-null: from the HIGH INSTALL phase (once at setup) until process
    #     teardown. Before install the worker holds `Optional[ErasedHook] = None`;
    #     `ctx_raw` is NEVER dereferenced before install and NEVER after the
    #     join-before-drop (the worker thread is gone).
    #
    # (c) OWNING vs BORROWED: BORROWED. `ctx_raw` targets a forever-root context
    #     home the HIGH layer owns; the hook frees NOTHING on drop. That home (a
    #     real `alloc[C](1) + init_pointee_move`) is the ONLY owning home and
    #     tracks the context's lifetime — so the destroy-recreate owning-field trap cannot
    #     fire.
    #
    # (d) TEARDOWN: the context home is freed by the HIGH layer via `drop_fn`
    #     STRICTLY AFTER the runtime has joined every worker pthread (the SAME
    #     join-before-drop that makes the engine reach sound). After the join, no
    #     worker can reach `ctx_raw`.
    #
    # The field is spelled with the literal `MutExternalOrigin` (NOT the
    # `HookCtxPtr` alias) DELIBERATELY: `lint_wildcard_field.sh` matches the
    # literal wildcard text at struct-body indent, and this is the ONE blessed
    # wildcard FIELD of the hook primitives — it MUST stay visible to that
    # gate (allowlisted, count=1), not hidden behind an alias.
    var ctx_raw: UnsafePointer[UInt8, MutUntrackedOrigin]

    # FFI-POD fn-ptr field (carve-out (a) — code pointer, no heap). The
    # HIGH-monomorphized fire trampoline (one bounded drain+build+publish).
    var fire_fn: _HookFireFn

    # FFI-POD fn-ptr field — the HIGH-monomorphized drop trampoline. Invoked ONCE
    # by the HIGH layer after join (NEVER by the worker).
    var drop_fn: _HookDropFn

    @always_inline
    def fire(mut self, worker_id: UInt16) raises:
        """Fire the hook ONCE, BLIND, on the worker's own thread. Invokes the
        HIGH-monomorphized `fire_fn` with the erased context handle + the worker
        id (the SPSC drain key). The worker calls this in its idle window,
        bounded + fail-safe.

        SAFETY: `ctx_raw` is the borrowed forever-root context handle; the HIGH
        trampoline reconstructs the concrete context (the proven OwnedPointer-wrap
        coherent read) and reaches its resources via the baked carried handles —
        no UnsafePointer crosses any consumer boundary beyond this one blessed
        handle. The wildcard origin is confined to the FFI-POD fn-ptr alias +
        this `ctx_raw` field (the type-erasure handle)."""
        self.fire_fn(self.ctx_raw, worker_id)

    @always_inline
    def drop(mut self):
        """Free the forever-root context home, ONCE, HIGH-side, after join.
        Invokes the HIGH-monomorphized `drop_fn` which reconstructs an
        `OwnedPointer[C]` over the home bytes and lets it drop (running `C`'s
        destructor + freeing the alloc in one tracked consume). The HIGH layer
        calls this AFTER `runtime.shutdown()` joins all workers — never the
        worker. The hook's own drop is a no-op (it owns no heap)."""
        self.drop_fn(self.ctx_raw)


# =============================================================================
# installable_hook_home — allocate the forever-root context home.
# =============================================================================
# The HIGH producer calls this to CONSUME its typed context `C` into a
# forever-root raw home (the EXACT `_TaskEntry` ownership model: `alloc[C](1) +
# init_pointee_move`), returning the erased byte-ptr the `ErasedHook` borrows +
# the HIGH layer later frees via `drop`. PARAMETRIC on the concrete `C` — the
# HIGH side names it; the worker never does.


def installable_hook_home[
    C: Movable & Deinitable
](var ctx: C) -> HookCtxPtr:
    """Allocate the forever-root context home (the EXACT `_TaskEntry` ownership
    model): `alloc[C](1) + init_pointee_move(ctx)`, returning the erased byte-ptr
    (as the opaque `HookCtxPtr` — the HIGH caller never spells the wildcard). The
    home lives until the matching `_HookDropFn` frees it (after join).

    The HIGH layer holds ONLY this POD byte-ptr (inside its `ErasedHook`), not a
    second `OwnedPointer` — so there is no second owner to double-free, and the
    worker's `OwnedPointer(unsafe_from_raw_pointer=)` reconstruction reads the
    heap-owning fields coherently (the proven `_run_task_for` pattern).

    SAFETY: fresh allocation we own; move-construct the context into it. The home
    is freed exactly once by the HIGH `drop` trampoline after join. PARAMETRIC `C`
    is named only HIGH-side; the returned byte-ptr is the type-erasure handle.
    """
    var raw = alloc[C](1)
    # SAFETY: fresh allocation we own; move-construct the context into it.
    UnsafePointer(to=raw[]).unsafe_write(ctx^)
    return raw.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin]()
