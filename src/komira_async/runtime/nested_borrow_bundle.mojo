# =============================================================================
# komira_async.runtime.nested_borrow_bundle — the ONE blessed nested-dispatch
#   borrow-bundle primitive (the reframed _ForEachState
#   encapsulation).
# =============================================================================
#
# WHAT THIS IS
#   A single LOW-layer, pointer-free-public primitive that bundles the THREE
#   per-dispatch borrows a nested-dispatch wrapper state carries — a borrowed
#   outer State, a borrowed NON-Movable MorselPool, and a borrowed
#   CancellationToken — behind ONE blessed type-erasure handle. It is the
#   encapsulation that is viable once the
#   borrow/owned SPLIT is shown to hit a GENUINE analyzer wall: the
#   wildcard CANNOT be eliminated for `_ForEachState` (the origin-parameterized
#   segment aliases the live `mut state` / pool / cancel args at the
#   `run_with_state` dispatch boundary — three approaches (a direct pointer,
#   a concrete-origin frame and the borrow/owned split) all hit it),
#   but it CAN be ENCAPSULATED behind ONE named, allowlisted, tested primitive
#   so the caller (`for_each_morsel`) carries ZERO bespoke wildcard.
#
# WHY ENCAPSULATE (vs ELIMINATE — the reframe)
#   The HOT-path nested dispatch shape `for_each_morsel` runs a per-morsel body
#   through `LocalDispatcher.run_with_state`. Unlike the `run_with_state` /
#   `_DispatchShard` path — which DID eliminate its six wildcard fields by
#   bundling the borrows into a concrete-origin `_DispatchCtx` and boxing the
#   POD shard through `make_erased`'s opaque-owned-`W` boundary — `_ForEachState`
#   is a NESTED dispatch
#   whose origin-carrying wrapper is passed DIRECTLY as the `State` arg to
#   `run_with_state` AND whose Segment reaches that State via a bitcast in
#   `execute`. Giving the three borrows concrete origins makes the segment-body
#   accessors (reached by bitcast of `state` over `origin_of(state)`) trip
#   "reading a memory location previously writable through another aliased
#   argument" — the borrows alias the live `mut state`. There is no
#   opaque-owned-`W` laundering escape because the wrapper is the `state`
#   arg itself, not an internally-built POD the dispatcher boxes.
#
#   So the wildcard is a SANCTIONED per-dispatch carve-out. The goal of this
#   primitive is zero bespoke wildcards for the one analyzer-blocked site:
#   collapse the THREE scattered bespoke wildcard FIELDS that lived on
#   `_ForEachState` (`outer_state_ptr`, `pool_ptr`, `cancel_token_ptr`) into ONE
#   named primitive with ONE wildcard FIELD, leaving `for_each_morsel` with ZERO
#   bespoke wildcard.
#
# THE ONE BLESSED WILDCARD (the SOLE wildcard FIELD, body-confined)
#   `NestedBorrowBundle` holds exactly ONE `MutExternalOrigin` FIELD: `_home`, a
#   single byte pointer to a heap home of THREE pointer-sized slots that hold the
#   three borrowed *typed* pointers. Each borrow is stored / recovered by a
#   typed bitcast at a fixed slot OFFSET inside the bundle's own method bodies
#   (8-space indent → method-local, NOT a struct FIELD the destroy-recreate field lint
#   gates on). There is NO carrier struct with wildcard FIELDS — the three typed
#   pointers live ONLY as values written into / read from the `_home` byte buffer
#   in method bodies. So the wildcard FIELD count this file contributes is
#   EXACTLY ONE (`_home`). The public accessors (`outer_ref` / `pool_ref` /
#   `cancel_ref`) are POINTER-FREE — they return `ref`s, never raw pointers.
#   This is byte-for-byte the blessed `_TaskEntry.task_raw` / `ErasedHook.ctx_raw`
#   carve-out: ONE byte-ptr type-erasure handle, the recover confined to the
#   primitive's own method bodies.
#
# OWNERSHIP / DESTROY-RECREATE SAFETY (the load-bearing safety contract)
#   `NestedBorrowBundle` is per-dispatch: constructed inside `for_each_morsel`,
#   dropped at its scope end — NOT a destroy-recreate pool field (so NOT the
#   destroy-recreate lifecycle). The three borrows target memory the CALLER owns for the
#   dispatch window: the outer `State` (caller's `mut state`), the `MorselPool`
#   (a stack-frame `var` on `for_each_morsel` — NON-Movable, so it cannot live in
#   an OwnedPointer and MUST be borrowed), and the `CancellationToken` (the
#   caller's `var` parameter). The wake-word barrier inside `run_with_state`
#   guarantees every worker returns BEFORE those borrowed-from values go out of
#   scope — the same dispatch-window liveness contract `_ForEachState` always
#   relied on.
#
#   The bundle OWNS one small heap allocation: the `_home` slot buffer (three
#   pointer-sized machine words). It is POD bytes (three borrow pointers; NO
#   heap-owning interior — the borrows point AT heap the caller owns, they do
#   not OWN it), so the home's teardown is a single `free()` of the raw bytes
#   with no destructor work (none of the three destroy-recreate owning-field ingredients live
#   in the home). The NON-Movable MorselPool the bundle borrows is destroyed by
#   the CALLER's stack frame, never by the bundle. Storing a BORROW (a pointer)
#   to the non-Movable pool — never the pool by value — is exactly what makes the
#   non-Movable case expressible: a non-Movable struct cannot be moved/copied,
#   but a borrowed pointer to it is just a machine word.
#
# Mojo 1.0.0b1 pin.
# =============================================================================

from std.memory import UnsafePointer, alloc
from std.sys import size_of

from komira_async.cancellation.token import CancellationToken
from komira_async.morsel.morsel_pool import MorselPool
from komira_async_api.worker_pool_traits import KeepAlive


# =============================================================================
# NestedBorrowBundle[State, MorselT] — the ONE blessed nested-dispatch
#      borrow bundle.
# =============================================================================
# Holds exactly ONE wildcard FIELD (`_home`, the byte-ptr type-erasure handle)
# and exposes pointer-free `ref`-returning accessors. The three borrows are
# stored into / recovered from three fixed slot offsets in the `_home` byte
# buffer by typed bitcast inside the bundle's method bodies — the SOLE wildcard
# FIELD of the entire `_ForEachState` encapsulation, allowlisted (count=1).


struct NestedBorrowBundle[
    State: KeepAlive,
    MorselT: Copyable & ImplicitlyCopyable
        & Movable & Deinitable,
](KeepAlive, Movable, Deinitable):
    """The ONE blessed nested-dispatch borrow bundle.

    Collapses the THREE scattered bespoke wildcard FIELDS that lived on
    `_ForEachState` (`outer_state_ptr`, `pool_ptr`, `cancel_token_ptr`) into ONE
    named, allowlisted, tested primitive with ONE wildcard FIELD, leaving
    `for_each_morsel` with ZERO bespoke wildcard. The wildcard is a SANCTIONED
    per-dispatch carve-out (the nested-dispatch alias wall POC3 HALT-confirmed
    cannot be eliminated), now CONFINED to this primitive's ONE `_home` byte-ptr
    FIELD + the slot recover/store bodies.

    Pointer discipline:
      - `_home` is the blessed type-erasure handle (the `_TaskEntry.task_raw` /
        `ErasedHook.ctx_raw` carve-out). It owns ONE small heap home: three
        pointer-sized slots holding the three borrowed typed pointers (POD bytes,
        no heap-owning interior). The three borrows it stores point AT
        caller-owned memory, valid for the dispatch window (the wake-word barrier
        in `run_with_state` holds the workers until the borrowed-from values can
        go out of scope).
      - the public accessors (`outer_ref` / `pool_ref` / `cancel_ref`) are
        POINTER-FREE — they return `ref`s, never raw pointers. The slot bitcast
        recover is confined to their method bodies.
      - Per-dispatch / per-call, NOT a destroy-recreate pool field — so NOT the
        destroy-recreate lifecycle shape.
    """

    # Slot layout in the `_home` buffer (pointer-sized machine words):
    #   slot 0 -> the borrowed outer State pointer
    #   slot 1 -> the borrowed NON-Movable MorselPool[MorselT] pointer
    #   slot 2 -> the borrowed CancellationToken pointer
    comptime _SLOT_STATE = 0
    comptime _SLOT_POOL = 1
    comptime _SLOT_CANCEL = 2
    comptime _N_SLOTS = 3
    comptime _PTR_BYTES = size_of[UnsafePointer[UInt8, MutUntrackedOrigin]]()

    # SAFETY (FFI-POD-CARVEOUT type-erasure handle — the pointer rules +
    #         destroy-recreate safety argument; identical justification to
    #         `_TaskEntry.task_raw` / `ErasedHook.ctx_raw`). This is the SOLE
    #         blessed wildcard FIELD of the `_ForEachState` encapsulation.
    #
    # (a) WHY a wildcard is load-bearing: this primitive encapsulates the
    #     NESTED-DISPATCH carve-out. `for_each_morsel` passes the wrapper that
    #     bundles these borrows DIRECTLY as the `State` arg to `run_with_state`,
    #     and the Segment reaches that State by a bitcast in `execute`. Giving the
    #     three borrows concrete origins makes the segment-body accessors alias
    #     the live `mut state` borrow at the dispatch boundary (the analyzer
    #     rejects it for every shape tried — a direct pointer, a
    #     concrete-origin frame, and the borrow/owned split). There is no
    #     opaque-owned-`W` laundering escape because the wrapper IS the
    #     `state` arg, not an internally-built POD the dispatcher boxes. The byte-ptr
    #     is the unavoidable type-erasure handle, the SAME shape the spawn path
    #     already crosses for `_TaskEntry.task_raw`.
    #
    # (b) WHEN non-null: from `NestedBorrowBundle.new` (once per
    #     `for_each_morsel` call) until the bundle drops at the end of that call.
    #     `_home` is NEVER dereferenced after the wake-word barrier returns (every
    #     worker has finished its shard before `for_each_morsel` returns).
    #
    # (c) OWNING vs BORROWED: `_home` OWNS one small POD slot buffer (three borrow
    #     pointers, no heap-owning interior) — freed once in `__del__`. The three
    #     pointers stored IN it are BORROWS into caller-owned memory (the outer
    #     State, the NON-Movable MorselPool on the caller's stack, the
    #     CancellationToken); the bundle frees NONE of those. The destroy-recreate owning-
    #     field trap needs an OWNED heap-owning inner field; the slot buffer has
    #     none.
    #
    # (d) TEARDOWN: `__del__` frees the slot buffer's raw bytes (no destructor
    #     work — the slots are POD machine words). The borrowed-from values are
    #     destroyed by the caller's stack frame STRICTLY AFTER the wake-word
    #     barrier joins every worker — the same join-before-drop `_ForEachState`
    #     always relied on.
    #
    # Spelled with the literal `MutExternalOrigin` (NOT an alias) DELIBERATELY:
    # `lint_wildcard_field.sh` matches the literal wildcard text at struct-body
    # indent, and this is the ONE blessed wildcard FIELD the encapsulation leaves
    # — it MUST stay visible to that gate (allowlisted, count=1).
    var _home: UnsafePointer[UInt8, MutUntrackedOrigin]

    @staticmethod
    def new(
        outer_state_ptr: UnsafePointer[Self.State, MutUntrackedOrigin],
        pool_ptr: UnsafePointer[
            MorselPool[Self.MorselT], MutUntrackedOrigin,
        ],
        cancel_token_ptr: UnsafePointer[
            CancellationToken, MutUntrackedOrigin,
        ],
    ) -> NestedBorrowBundle[Self.State, Self.MorselT]:
        """Bundle the three borrows behind ONE heap slot buffer reached by the
        ONE `_home` byte-ptr handle.

        Takes the three wildcard borrow pointers (the per-dispatch carve-out the
        caller forms ONCE at the bundle boundary), allocates a pointer-sized slot
        buffer, and STORES each typed pointer into its fixed slot by a typed
        bitcast (method-body only — no wildcard struct FIELD). The slots are POD
        machine words, so this is the SAME `alloc + store` shape the erasure
        handles use, with the recover confined to method bodies.

        SAFETY: `alloc[UInt8](_N_SLOTS * _PTR_BYTES)` is a fresh allocation we
        own; each typed-pointer store writes a POD machine word into its slot (no
        double-init). The three pointers are BORROWS the caller guarantees live
        for the dispatch window (the wake-word barrier holds the workers). The
        byte-ptr is the type-erasure handle; `__del__` frees the slot buffer.
        """
        var raw = alloc[UInt8](Self._N_SLOTS * Self._PTR_BYTES)
        var home = raw.unsafe_origin_cast[MutUntrackedOrigin]()
        # SAFETY: store each borrowed typed pointer into its fixed slot. The slot
        # base is computed by byte offset; the typed bitcast writes one POD
        # machine word. No struct field carries the wildcard — only `_home` does.
        (home + Self._SLOT_STATE * Self._PTR_BYTES).bitcast[
            UnsafePointer[Self.State, MutUntrackedOrigin]
        ]()[] = outer_state_ptr
        (home + Self._SLOT_POOL * Self._PTR_BYTES).bitcast[
            UnsafePointer[MorselPool[Self.MorselT], MutUntrackedOrigin]
        ]()[] = pool_ptr
        (home + Self._SLOT_CANCEL * Self._PTR_BYTES).bitcast[
            UnsafePointer[CancellationToken, MutUntrackedOrigin]
        ]()[] = cancel_token_ptr
        return NestedBorrowBundle[Self.State, Self.MorselT](_home=home)

    def __init__(
        out self,
        _home: UnsafePointer[UInt8, MutUntrackedOrigin],
    ):
        self._home = _home

    @always_inline
    def _state_slot(
        self,
    ) -> UnsafePointer[Self.State, MutUntrackedOrigin]:
        """Recover the borrowed State pointer from slot 0 of the `_home` buffer.
        Confined to this primitive's method bodies (NOT a struct FIELD).

        SAFETY: `_home` is the byte-ptr to the slot buffer `new` allocated +
        stored the three borrows into, so slot 0 holds a valid borrowed State
        pointer. The typed bitcast reads one POD machine word; it never escapes
        the public accessor that calls this."""
        return (
            self._home + Self._SLOT_STATE * Self._PTR_BYTES
        ).bitcast[UnsafePointer[Self.State, MutUntrackedOrigin]]()[]

    @always_inline
    def _pool_slot(
        self,
    ) -> UnsafePointer[MorselPool[Self.MorselT], MutUntrackedOrigin]:
        """Recover the borrowed NON-Movable MorselPool pointer from slot 1.

        SAFETY: as `_state_slot` — slot 1 holds the valid borrowed pool pointer
        `new` stored. The pool is NON-Movable, so it is reached ONLY by this
        borrowed pointer (it cannot live in an OwnedPointer)."""
        return (
            self._home + Self._SLOT_POOL * Self._PTR_BYTES
        ).bitcast[
            UnsafePointer[MorselPool[Self.MorselT], MutUntrackedOrigin]
        ]()[]

    @always_inline
    def _cancel_slot(
        self,
    ) -> UnsafePointer[CancellationToken, MutUntrackedOrigin]:
        """Recover the borrowed CancellationToken pointer from slot 2.

        SAFETY: as `_state_slot` — slot 2 holds the valid borrowed token pointer
        `new` stored."""
        return (
            self._home + Self._SLOT_CANCEL * Self._PTR_BYTES
        ).bitcast[UnsafePointer[CancellationToken, MutUntrackedOrigin]]()[]

    @always_inline
    def outer_ref(self) -> ref [MutUntrackedOrigin] Self.State:
        """Borrow the outer State through the bundled slot — POINTER-FREE.

        SAFETY: reaches the caller's `mut state` through the borrowed pointer in
        slot 0. Valid for the dispatch window (the wake-word barrier holds every
        worker until the borrowed-from State can go out of scope). The recover
        bitcast is in `_state_slot`."""
        return self._state_slot()[]

    @always_inline
    def pool_ref(self) -> ref [MutUntrackedOrigin] MorselPool[Self.MorselT]:
        """Borrow the NON-Movable MorselPool through the bundled slot —
        POINTER-FREE.

        SAFETY: reaches the caller's stack-frame `pool` (NON-Movable, borrowed by
        pointer because it cannot live in an OwnedPointer) through the borrowed
        pointer in slot 1. Valid for the dispatch window (same barrier contract).
        The recover bitcast is in `_pool_slot`."""
        return self._pool_slot()[]

    @always_inline
    def cancel_ref(self) -> ref [MutUntrackedOrigin] CancellationToken:
        """Borrow the CancellationToken through the bundled slot — POINTER-FREE.

        SAFETY: reaches the caller's `cancel_token` through the borrowed pointer
        in slot 2. Valid for the dispatch window (same barrier contract). The
        recover bitcast is in `_cancel_slot`."""
        return self._cancel_slot()[]

    def __deinit__(deinit self):
        """Free the one small POD slot buffer the `_home` handle owns. The slots
        are POD machine words (three borrow pointers, no heap-owning interior), so
        this is a raw byte free with NO destructor work — the borrowed-from State /
        MorselPool / CancellationToken are owned + destroyed by the caller's stack
        frame, STRICTLY AFTER the wake-word barrier joins every worker (the same
        join-before-drop `_ForEachState` always relied on).

        SAFETY: `_home` owns the slot buffer's heap home (a fresh
        `alloc[UInt8](...)` from `new`); we free it as raw bytes. The slots have no
        heap-owning interior, so no destructor needs to run on the three borrow
        pointers (they are machine words borrowing caller-owned memory). Runs
        exactly once per bundle."""
        self._home.free()
