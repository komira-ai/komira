# =============================================================================
# ScanRegistry — MECHANISM 1 of the ownership rule. The registry HOLDS the Arc.
# =============================================================================
#
# Three mechanisms together make a `handle: Int` in the plan as safe as the
# `ArcPointer[Slab[RecordBatch]]` it replaces:
#
#   1. THE REGISTRY HOLDS THE ARC   <- THIS FILE
#   2. EPOCH CHECK                  <- `scan_resolver.check_binding`, wired at
#                                      every terminal route
#   3. OWNERSHIP PLACEMENT          <- `EngineContext._scan_registry`
#
# Mechanism 2 alone is not enough: with only `UnboundScanResolver` in
# production, whose epoch is `SCAN_EPOCH_NONE`, EVERY handle would raise
# `SCAN_BINDING_EPOCH_MISMATCH` at EVERY terminal route — including a handle
# minted, one frame earlier, by the very `EngineContext` running the query.
# With a real registry owned by the context and passed to the gate, a handle
# minted by THIS context resolves and a handle from a dead or foreign registry
# still raises by name.
#
# =============================================================================
# WHY THIS IS IN `komira_scan_source` AND NOT IN A NEW TOP PACKAGE
# =============================================================================
#
# A TOP package whose deps name every package that owns a scan kind is the
# correct answer for TIER 2 — a resolver that
# hands back a `MorselSourceImpl` cannot live in core, because
# `MorselSourceImpl` lives in `komira_morsel`, which depends on core (see
# `fs_resolver.mojo`).
#
# It is NOT the answer for the IN_MEMORY kind. The in-memory payload is
# `ArcPointer[Slab[RecordBatch]]` — `ArcPointer` is `std.memory`,
# `Slab` is `komira_collections.slab`, `RecordBatch` is
# `komira_arrow.record_batch`. Every one is a type core already spells,
# which is also why `InMemoryRegistry`
# (`komira_scan_source/compiler_registry.mojo`), the other registry for
# in-memory batches, lives in core. A kind whose payload is a core type needs
# no package above core; a kind whose payload is not one does. The
# DAG-inversion hazard is about naming a SOURCE TYPE from core, and this file
# names none.
#
# `ScanMorselResolver` (tier 2, for a kind whose payload the engine PULLS
# rather than holds) and its conformer go above core. This file is not that.
#
# =============================================================================
# WHAT A HANDLE COSTS, AND WHAT IT BUYS
# =============================================================================
#
# `payload_arc(handle)` returns an `ArcPointer` COPY — a refcount bump, O(1),
# independent of resident bytes. That is the whole of mechanism 1: the batches
# are still refcount-kept, the keep-alive simply moved OUT OF THE IR. A plan
# node that carries only `(kind_id, handle, registry_epoch)` is pure data — it
# serializes, it clones without touching a refcount, and its identity is a
# function of its content rather than of a heap address.
#
# The dangling window narrows from "any use-after-free" to the one auditable
# case: "registry dropped while a plan referencing it is replayed" —
# and mechanism 2 turns THAT into a named raise.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_EPOCH_NONE,
    SCAN_HANDLE_UNBOUND,
)
from komira_scan_source.scan_resolver import (
    ScanPayloadResolver,
    ScanResolver,
)


@always_inline
def _next_scan_registry_epoch() -> UInt64:
    """A process-unique, strictly-increasing, NONZERO epoch.

    Reuses the same C-side `static uint64_t` + `__atomic_fetch_add` counter that
    `in_memory_source._next_inmem_source_id` draws from
    (`komira_next_inmem_source_id` in the C posix shim). SHARING ONE COUNTER IS
    DELIBERATE and is the stronger choice, not a shortcut: the property an epoch
    needs is that no two registries in a process ever hold the same value, and
    one counter guarantees that by construction. A second counter would have to
    be argued to be disjoint from the first; it does not need to be, because an
    epoch is only ever compared against another epoch.

    Never returns 0, so `SCAN_EPOCH_NONE` stays reserved for "binds nothing"
    (`UnboundScanResolver`) and can never be a live registry's epoch.
    """
    # SAFETY: fixed-arity, scalar-returning C function; no pointers cross the
    # FFI boundary. The counter and its atomic are internal to the C shim.
    return external_call["komira_next_inmem_source_id", UInt64]()


comptime SCAN_REGISTRY_SLOT_SPACE_EXHAUSTED: StaticString = (
    "SCAN_REGISTRY_SLOT_SPACE_EXHAUSTED"
)
"""NAMED ERROR — this registry holds 2^31 simultaneously-live slots.

The slot occupies the low 31 bits of a handle (the high 32 carry the mint
generation and bit 63 is left clear so a handle is never negative), so a slot
index at the mask is the last representable one.

⚠ IT RAISES RATHER THAN TRUNCATING, AND THE ALTERNATIVES ARE BOTH WORSE. A
truncating mint aliases slot `s` with slot `s + 2^31` — the silent-wrong-rows
class the generation exists to prevent. Returning `SCAN_HANDLE_UNBOUND` is
quieter still: the binding would read as "binds nothing", every gate would pass
it, and the query would take the legacy union arm today and break silently after
the arm is deleted. A named raise is the only answer that cannot be mistaken for
success.
"""


comptime SCAN_REGISTRY_UNKNOWN_HANDLE: StaticString = (
    "SCAN_REGISTRY_UNKNOWN_HANDLE"
)
"""NAMED ERROR — `payload_arc` / `evict` given a handle this registry never minted.

Distinct from `SCAN_BINDING_HANDLE_NOT_BOUND`, which is what the GATE raises for
a slot that was minted and then evicted. This one means the index is not a slot
at all — a caller bug (a handle from another registry, or `SCAN_HANDLE_UNBOUND`
passed through), not an eviction-policy question.
"""


# =============================================================================
# THE HANDLE ENCODING — slot in the low 31 bits, MINT GENERATION above it
# =============================================================================
#
# A handle is `slot | (generation << 31)`. Without a generation, `handle ==
# slot index` and the parallel arrays would grow by one entry PER BIND and
# never shrink, so a warm long-lived `EngineContext` would accumulate
# handle-space forever even at zero residency — invisible to
# `resident_payload_rows()`, which is a statement about BYTES and not about the
# arrays that index them.
#
# ⚠ THE GENERATION IS WHAT MAKES RECLAIM SAFE, AND WITHOUT IT RECLAIM IS A
# SILENT WRONG ANSWER. A handle is a plan-node value that may outlive the entry
# it names — that is the whole hazard this registry manages. Reclaiming slot `s` and
# re-minting it for different bytes would make a stale plan node's handle `s`
# resolve to SOMEBODY ELSE'S PAYLOAD: not a raise, not a crash, the wrong rows.
# The generation removes that: a handle minted at generation `g` is valid only
# while `gens[slot] == g`, and every reclaim bumps the generation the next mint
# will carry, so a stale handle can only ever miss.
#
# Generation 0 is the pre-reclaim world, so until a scope first reclaims, a
# handle is numerically identical to its slot index.
#
# ⚠ THE SLOT FIELD IS 31 BITS, NOT 32, AND THE MISSING BIT IS THE SIGN BIT.
# With the slot in bits 0-31 and the generation in bits 32-63,
# `Int(generation) << 32` would SET BIT 63 for any generation >= 2^31 and
# every handle minted after that would come out NEGATIVE. `is_bound`,
# `payload_arc`, `evict` and `kind_at` all guard `handle < 0`, so the
# registry would not merely mis-resolve — it would stop resolving ANY handle,
# permanently, for the life of the context. That is reachable on exactly the
# deployment this design is for: a server that keeps ONE warm `EngineContext`
# per worker, where a closing `ScanBindScope` bumps the generation once per
# binding query.
#
# 31 slot bits + 32 generation bits = 63, so bit 63 is never written and a
# handle is ALWAYS non-negative by construction rather than by a check. The
# generation is the field that actually advances (once per reclaiming scope
# close), and the slot field still addresses 2^31 simultaneously-live slots.
comptime _SCAN_HANDLE_SLOT_BITS: Int = 31
comptime _SCAN_HANDLE_SLOT_MASK: Int = (1 << _SCAN_HANDLE_SLOT_BITS) - 1
comptime _SCAN_HANDLE_GEN_MASK: Int = (1 << 32) - 1
comptime _SCAN_HANDLE_GEN_MAX: UInt32 = UInt32(0xFFFFFFFF)
"""The last generation this encoding can express.

⚠ REACHING IT STOPS RECLAIM, IT DOES NOT WRAP. A wrapped generation re-mints a
slot index at a generation a still-live plan node may already hold, which is the
SILENT WRONG ROWS this whole encoding exists to prevent — strictly worse than
the growth `ScanBindScope` was added to stop. Fail-closed is the right choice
and this comment keeps it.

⚠ THE COST OF EXHAUSTION IS AVAILABILITY, NOT JUST INDEX BYTES. The payloads
ARE still released, so residency is unaffected — but once reclaim stops,
`len(live)` grows monotonically with every bind, and `bind_batches` RAISES
`SCAN_REGISTRY_SLOT_SPACE_EXHAUSTED` at slot 2^31. From that point EVERY
IN-MEMORY BIND ON THIS CONTEXT FAILS BY NAME — an AVAILABILITY failure of the
warm per-worker context, not a memory-accounting one. And the practical
endpoint arrives first: four parallel arrays at ~25 bytes/slot means ~53 GB of
INDEX at the ceiling, so the process dies of memory before it ever raises.

⚠ NEITHER ENDPOINT IS MEASURED. The generation advances once per reclaiming
scope close — roughly once per binding query — so exhaustion is ~2^32 such
queries on ONE `EngineContext`. That is days rather than years at a five-figure
query rate on a context kept deliberately warm. Treat it as the shape of the
failure, not as a schedule. The falsifier that would settle it (drive
`mint_gen` to this value and assert the refusal by name) is not written.
"""


@always_inline
def _scan_handle_slot(handle: Int) -> Int:
    return handle & _SCAN_HANDLE_SLOT_MASK


@always_inline
def _scan_handle_gen(handle: Int) -> UInt32:
    return UInt32((handle >> _SCAN_HANDLE_SLOT_BITS) & _SCAN_HANDLE_GEN_MASK)


@always_inline
def _scan_handle_make(slot: Int, generation: UInt32) -> Int:
    """Never negative: `slot <= 2^31-1` and `Int(generation) << 31 <= 2^63-2^31`.

    The slot bound is enforced at the ONE place a slot is created
    (`bind_batches`, which raises `SCAN_REGISTRY_SLOT_SPACE_EXHAUSTED`), so this
    helper has no unrepresentable input to defend against.
    """
    return slot | (Int(generation) << _SCAN_HANDLE_SLOT_BITS)


struct _ScanRegistryStore(Movable, Deinitable):
    """The registry's mutable state, held behind an `ArcPointer`.

    ⚠ THE INDIRECTION IS NOT A SPELLING PREFERENCE — IT IS WHAT LETS THE RELEASE
    RUN ON THE UNWIND PATH. `ScanBindScope`'s destructor has to reach this state
    at a moment when the `EngineContext` that owns the registry is itself being
    unwound, and a `Pointer[ScanRegistry, origin]` field would mean holding a
    borrow of the context across the entire query body — the frame in which the
    context is mutably used dozens of times. A second `ArcPointer` to this state
    has no such coupling: the scope owns its own reference, mutates through it,
    and the two references are independent as far as the origin system is
    concerned. (`InMemorySource._sid_memo` is the precedent for mutating
    through an `ArcPointer` held by an immutable receiver.)
    """

    var kinds: List[UInt32]
    var gens: List[UInt32]
    """Per-slot MINT GENERATION. Parallel to `live`, truncated with it, and
    re-appended at the CURRENT `mint_gen` when a reclaimed slot is re-minted —
    which is what makes a stale handle to a reclaimed slot miss instead of
    resolving to the wrong payload."""
    var payloads: List[Optional[ArcPointer[Slab[RecordBatch]]]]
    var live: List[Bool]
    var free: List[Int]
    """Slots `evict` tombstoned, available for RE-MINT at a higher generation.

    ⚠ THIS IS THE `evict` HALF OF THE BOUNDED HANDLE SPACE. `ScanBindScope`
    reclaims the tail it minted, which bounds the QUERY path; `evict` bounds
    the MATVIEW path — the one lifecycle that deliberately does NOT go through
    a scope, because its acquire and release are separate API verbs, and which
    would otherwise grow one slot per create/drop and one per refresh, forever,
    on the warm per-worker context.

    A FREE LIST rather than a tail pop, because the matview shapes do not put the
    dead slot at the tail: `_refresh_materialized_view_batch` binds the NEW
    generation before evicting the OLD, so the dead slot is always beneath a live
    one and a trailing-run reclaim never fires for a refresh.

    ⚠ RE-MINT IS SAFE ONLY THROUGH THE GENERATION, and `evict` bumps `mint_gen`
    for exactly that reason: a plan node still naming this slot at the old
    generation must MISS, not resolve into whoever gets the index next."""
    var total_mints: UInt64
    """Every slot this registry has EVER minted, monotone, never reclaimed.

    ⚠ IT EXISTS BECAUSE RECLAIM TAKES `num_slots()` AWAY FROM THE ANTI-VACUITY
    JOB. A falsifier that asserts "the pass actually bound something" before
    asserting residency is zero cannot use `num_slots()`: with the handle space
    reclaimed at scope close that reads 0 for a CORRECT pass. `num_slots()` is
    purely the handle-space oracle; this is purely the did-anything-happen
    oracle. Conflating them makes one number answer two questions and get one
    of them wrong."""
    var open_scopes: Int
    """How many `ScanBindScope`s are currently open on this store.

    ⚠ IT IS THE INTERLOCK BETWEEN THE TWO RECLAIM MECHANISMS. `ScanBindScope`
    releases the RANGE `[first_slot, len(live))` — derived, never a recorded
    list, which is the property that makes an acquire that forgets to append
    impossible. That range is only the scope's own mints while binds inside a
    scope APPEND. If a bind under an open scope took a low free slot instead,
    the scope's range would not cover it and that payload would be resident
    for the context's life.

    So free-slot reuse is disabled while any scope is open. The matview binds,
    which are the ones that need it, run with no scope open by construction: they
    are `create_materialized_view` / `_refresh_materialized_view_batch`, not
    query doors."""
    var mint_gen: UInt32
    """The generation the NEXT mint stamps. Bumped once per reclaim — by a
    closing scope AND by `evict` — never per bind: a handle only has to be
    distinguishable from the handles that occupied its slot BEFORE a reclaim, and
    bumping per bind would burn the 32-bit space at query rate."""

    def __init__(out self):
        self.kinds = List[UInt32]()
        self.gens = List[UInt32]()
        self.payloads = List[Optional[ArcPointer[Slab[RecordBatch]]]]()
        self.live = List[Bool]()
        self.free = List[Int]()
        self.total_mints = 0
        self.open_scopes = 0
        self.mint_gen = 0


struct ScanBindScope(Movable, Deinitable):
    """★ THE RAII BIND SCOPE — the release that runs on the UNWIND path.

    ⚠ THIS EXISTS BECAUSE A RELEASE SPELLED AS A STATEMENT AFTER THE BODY IS NOT
    A RELEASE. The entry-time bind pass is an ACQUIRE: it takes a SECOND
    retaining reference to a payload that already has an owner. A release
    statement written after the query body is skipped by a RAISE between the
    two, and because `bind` took its OWN reference, unwinding the plan does not
    drop it: `ctx.bind_plan_inmem_payloads(plan)` then `_ = plan^` would leave
    the rows resident. On a server that keeps ONE warm `EngineContext` per
    worker across every request, that leak is per-RAISING-QUERY for the life of
    the worker.

    A destructor runs on BOTH paths out of a live range. That is the whole
    mechanism, and it is why the doors hold a VALUE rather than an `Int`
    watermark.

    ⚠ THE FALSIFIER MUST ASSERT `resident_payload_rows()`, NEVER `num_bound()`.
    A tombstone-only evict takes the count to zero while the bytes stay
    resident, so a test written against the count goes GREEN on a broken
    implementation.
    """

    var _store: ArcPointer[_ScanRegistryStore]
    var _first_slot: Int
    """The handle-space size when the scope opened. Everything at or above it
    was minted inside this scope.

    A RANGE and not a list of handles: a returned list is a fourth thing that
    has to be kept in step with the binds, and an acquire that forgets to
    append is invisible. The range is DERIVED."""
    var _armed: Bool

    def __init__(out self, store: ArcPointer[_ScanRegistryStore], first: Int):
        self._store = store.copy()
        self._first_slot = first
        self._armed = True

    def __deinit__(deinit self):
        """RELEASE + RECLAIM. Runs on the normal path AND on the unwind path.

        Non-raising by construction (Mojo's `__deinit__` cannot propagate): it
        touches the lists directly rather than calling `evict`, whose raise is
        about a caller passing a handle it never minted — a question that cannot
        arise for a range this scope derived itself.
        """
        if not self._armed:
            return
        ref st = self._store[]
        if st.open_scopes > 0:
            st.open_scopes -= 1
        var first = self._first_slot
        if first < 0:
            first = 0

        # ---- RELEASE: drop this scope's payloads. RESIDENCY, not bookkeeping.
        var n = len(st.live)
        for i in range(first, n):
            st.live[i] = False
            st.payloads[i] = Optional[ArcPointer[Slab[RecordBatch]]](None)

        # ---- RECLAIM: give the handle space back.
        # Only the tail this scope minted, and only when it is genuinely the
        # tail — a scope destroyed OUT OF ORDER (an outer one before an inner
        # one) finds the list already shorter and reclaims nothing, which is
        # correct rather than merely safe: every slot it would have taken is
        # already gone.
        # ⚠ AT THE LAST EXPRESSIBLE GENERATION, RECLAIM STOPS — IT DOES NOT
        # WRAP. `mint_gen` is a `UInt32` and `+= 1` wraps silently, which would
        # re-mint these slot indices at a generation a still-live plan node may
        # already hold: the SILENT WRONG ROWS this encoding exists to prevent,
        # strictly worse than the handle-space growth reclaim was added to stop.
        # The payloads above are released either way, so RESIDENCY is unaffected
        # — but do not read that as "costs index bytes": past exhaustion the
        # slot arrays grow monotonically and `bind_batches` eventually REFUSES
        # EVERY IN-MEMORY BIND by name. See `_SCAN_HANDLE_GEN_MAX`.
        if n > first and st.mint_gen < _SCAN_HANDLE_GEN_MAX:
            while len(st.live) > first:
                _ = st.live.pop()
                _ = st.kinds.pop()
                _ = st.gens.pop()
                _ = st.payloads.pop()
            # ⚠ THE BUMP IS WHAT MAKES THE RECLAIM SAFE. Without it the next
            # scope re-mints these slot indices and a stale plan node's handle
            # resolves to the WRONG payload — silently, with rows.
            st.mint_gen += 1
            # DROP FREE ENTRIES THAT NO LONGER NAME A SLOT. `evict` may have
            # tombstoned an index inside this scope's range; the pop above
            # already removed it, so leaving it on the free list would hand
            # `bind_batches` an index past the end of every array.
            var kept = List[Int]()
            for i in range(len(st.free)):
                if st.free[i] < first:
                    kept.append(st.free[i])
            st.free = kept^


struct ScanRegistry(ScanPayloadResolver, Movable, Deinitable):
    """MECHANISM 1 — the execution-time payload registry for core-typed scan
    payloads, and a `ScanResolver` conformer so mechanism 2 can be run against
    a registry that actually binds things.

    Conforms to `ScanPayloadResolver` (tier 1b), which adds no method:
    `payload_arc` below already has the signature. What the conformance buys
    is that a payload-read site can take `[RES: ScanPayloadResolver]` and never
    name this struct — `pipeline_compiler._inline_one_registry_scan` is one.

    Owned by `EngineContext` (mechanism 3). Its epoch is stamped into every
    binding it binds, and `check_binding` refuses any binding carrying a
    different one.

    NOT a `Slab`: eviction has to leave the handle space stable (a handle is a
    plan-node value that may outlive the entry it names — that is the whole
    hazard this design manages), so slots are tombstoned rather than compacted.
    `List[Optional[ArcPointer[T]]]` is the shape, one `Optional` per slot, so a
    tombstone can drop its payload while the index it occupies stays addressable
    (`komira_async`'s connection registry is a `List[ArcPointer[T]]`
    precedent; the `Optional` is what this registry adds, and why is on the
    field).

    A reader that already took its Arc through `payload_arc` is unaffected by a
    later eviction: the handoff is BY VALUE, so its payload outlives the slot.
    """

    var _epoch: UInt64
    var _store: ArcPointer[_ScanRegistryStore]
    """The three parallel lists, behind an `ArcPointer` so `ScanBindScope` can
    release on the unwind path without borrowing the owning `EngineContext`.

    ⚠ `payloads` is `Optional[ArcPointer[…]]`, NOT `ArcPointer[…]` — and that IS
    the retention guarantee, not a spelling preference.

    `live` is BOOKKEEPING: it decides what `is_bound` / `num_bound` answer.
    `payloads` is RESIDENCY: it decides whether the bytes are still in the
    process. An `evict` that flipped only the first would let a slot report
    not-bound while its `ArcPointer` — and every `RecordBatch` behind it —
    stayed resident for the owning context's entire life, with every count
    still correct. Nothing but the bytes would show it.

    Two parallel lists rather than one `Optional` doing both jobs, because a
    tombstone must keep answering the bookkeeping question after it has stopped
    answering the residency one: a handle is a plan-node value that may outlive
    the entry it names, and such a plan must get `SCAN_BINDING_HANDLE_NOT_BOUND`
    — a live registry, a reclaimed slot — rather than an out-of-range error or a
    silent resolve into whatever a compaction moved in.
    """

    def __init__(out self):
        """Mint a fresh, process-unique epoch. Two registries constructed in one
        process never share one, which is what makes a handle from a DROPPED
        registry detectable rather than accidentally valid."""
        self._epoch = _next_scan_registry_epoch()
        self._store = ArcPointer[_ScanRegistryStore](_ScanRegistryStore())

    def __init__(out self, *, unbound: Bool):
        """A registry that BINDS NOTHING and can never accidentally bind.

        Its epoch is `SCAN_EPOCH_NONE`, so `is_bound` is False for every handle
        and `payload_arc` RAISES `SCAN_REGISTRY_UNKNOWN_HANDLE` for every
        handle. It exists for ONE reason: to be the DEFAULT VALUE of the
        `scan_registry` parameter threaded to the in-memory payload-read
        frames, so callers without a context (tests, benchmarks) keep
        compiling.

        ⚠ THE DEFAULT IS NOT THE WIRING, AND IT IS DELIBERATELY NOT SILENT. A
        production frame that fell back to this value would RAISE BY NAME the
        moment it asked for a payload — it cannot return an empty result and
        cannot return the wrong rows. Every production call of a threaded frame
        must pass `scan_registry=` explicitly.

        Distinct from `ScanRegistry()`, which mints a REAL epoch (one FFI atomic
        per construction) and is a live-but-empty registry — a handle against it
        is `HANDLE_NOT_BOUND`, a different diagnosis. This is the "binds
        nothing" identity `UnboundScanResolver` already carries on tier 1.
        """
        _ = unbound
        self._epoch = SCAN_EPOCH_NONE
        self._store = ArcPointer[_ScanRegistryStore](_ScanRegistryStore())

    # -------------------------------------------------------------------------
    # ScanResolver conformance (tier 1 — identity and freshness only)
    # -------------------------------------------------------------------------

    def epoch(self) -> UInt64:
        """This registry's process-unique monotonic epoch. Never
        `SCAN_EPOCH_NONE`."""
        return self._epoch

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        """True iff this registry holds a LIVE payload at `handle` for
        `kind_id`. False for an out-of-range handle, a tombstoned slot, a slot
        whose MINT GENERATION has moved on (the handle names bytes that were
        reclaimed), or a slot minted for a different kind — a handle is
        meaningless outside the (kind, generation, registry) triple that minted
        it."""
        if handle < 0:
            return False
        var slot = _scan_handle_slot(handle)
        ref st = self._store[]
        if slot >= len(st.live):
            return False
        if st.gens[slot] != _scan_handle_gen(handle):
            return False
        if not st.live[slot]:
            return False
        return st.kinds[slot] == kind_id

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """A resident payload has no freshness to re-read: the bytes cannot
        change under the registry, because the registry owns them. So the
        binding's own token is the current one.

        A kind whose content CAN change behind a live handle (a broker offset, a
        search generation) is a SNAPSHOT_LIVE kind and needs a resolver that
        re-reads. That resolver is not this one, and returning the stored token
        here is the correct answer for the kinds this registry serves rather
        than a stub — the same reason `UnboundScanResolver` returns it.
        """
        return binding.snapshot_token

    # -------------------------------------------------------------------------
    # Binding
    # -------------------------------------------------------------------------
    #
    # ★ THE THREE BIND VERBS BELOW TAKE `read self`, AND THAT REFLECTS WHAT IS
    # MUTATED RATHER THAN RELAXING A GUARANTEE.
    #
    # `ScanRegistry` is a HANDLE. Every byte of mutable state it names lives in
    # `_ScanRegistryStore`, behind an `ArcPointer`, and the proof that `mut self`
    # would guarantee nothing about exclusive access to it is IN THIS FILE:
    # `ScanBindScope.__deinit__` releases payloads, reclaims slot indices, bumps
    # `mint_gen` and decrements `open_scopes` while holding NOTHING BUT A COPY OF
    # THAT ARC — no registry, no `mut`, and by design, because the release has to
    # run while the owning `EngineContext` is itself unwinding. A modifier that a
    # second holder of the same Arc can bypass is not an exclusivity claim.
    #
    # ⚠ WHAT `mut` WOULD COST: the WIDENING routes. A frame re-rooted as a
    # source (`SingleSourceResolver.materialize_source` ->
    # `TypedSource.materialize_into_source`) is handed `read scan_registry` —
    # `read` deliberately, so a terminal can hand down `self._scan_registry`
    # beside `mut self._parquet_runtime_footer_cache` — and it must BIND,
    # because it executes its own inner plan at a SECOND terminal after the
    # first has already bound. `mut` there would leave only a parallel bind API
    # or a `mut` ripple through every threaded signature.
    #
    # `read` here does NOT mean "this does not mutate" — it means the MUTATION IS
    # NOT OF THE RECEIVER. `payload_arc` and `structural_id`
    # (`in_memory_source.mojo`, the precedent named on `_ScanRegistryStore`)
    # already read and write through an Arc from a `read` receiver. `evict`
    # stays `mut self` on purpose: it is a lifecycle verb whose caller owns the
    # registry outright (the matview create/refresh pair), and nothing that
    # only borrows one has any business tombstoning its slots.

    def bind_batches(
        self, kind_id: UInt32, var payload: ArcPointer[Slab[RecordBatch]]
    ) raises -> Int:
        """Take shared ownership of `payload` and return its handle.

        The Arc is MOVED in and held for the registry's lifetime (or until
        `evict`, or until the enclosing `ScanBindScope` closes). This is the
        `evict`, or until the enclosing `ScanBindScope` closes). This is
        mechanism 1: the batches are still refcount-kept, the

        The returned handle carries the slot AND the slot's MINT GENERATION —
        see `_scan_handle_make`. A slot index reclaimed by a closing bind scope
        is re-minted at a HIGHER generation, so a plan node still carrying the
        old handle misses rather than resolving to the new payload.
        """
        ref st = self._store[]
        # ---- RE-MINT A SLOT `evict` GAVE BACK, if one is free and no scope is
        # open. The interlock is on `open_scopes` and it is load-bearing: a
        # closing `ScanBindScope` releases the derived RANGE `[first, len)`, so a
        # bind under an open scope MUST append or that range stops being the set
        # the scope acquired. See `_ScanRegistryStore.open_scopes`.
        #
        # ⚠ A LOOP AND NOT AN `if`, BECAUSE THE MINT IS WHERE ALIASING WOULD
        # ACTUALLY HAPPEN AND THE FREE LIST IS ONLY A HINT. The
        # invariant that matters is `a live slot is never minted twice`, and the
        # authority on liveness is `live[]`, not the free list. `evict` is
        # idempotent so a duplicate cannot be pushed — but a free entry naming a
        # slot that is currently live can only mean the list disagrees with the
        # truth, and honouring it would hand two SIMULTANEOUSLY-LIVE bindings the
        # SAME handle and overwrite the first one's payload with the second's:
        # wrong rows, not a leak. Skipping such an entry is O(1) amortised and
        # makes the aliasing unreachable from the mint side even if a future
        # release path re-introduces a double push.
        while st.open_scopes == 0 and len(st.free) > 0:
            var reused = st.free.pop()
            if reused < 0 or reused >= len(st.live) or st.live[reused]:
                continue
            st.total_mints += 1
            st.kinds[reused] = kind_id
            st.gens[reused] = st.mint_gen
            st.payloads[reused] = Optional[ArcPointer[Slab[RecordBatch]]](
                payload^
            )
            st.live[reused] = True
            return _scan_handle_make(reused, st.mint_gen)

        var slot = len(st.live)
        if slot > _SCAN_HANDLE_SLOT_MASK:
            raise Error(
                String(SCAN_REGISTRY_SLOT_SPACE_EXHAUSTED)
                + String(": registry epoch ")
                + String(self._epoch)
                + String(" holds ")
                + String(slot)
                + String(" slots, and a handle's slot field is ")
                + String(_SCAN_HANDLE_SLOT_BITS)
                + String(" bits. Minting past it would alias slot s with slot")
                + String(" s + 2^31 — the silent-wrong-rows class the mint")
                + String(" generation exists to prevent.")
            )
        st.total_mints += 1
        st.kinds.append(kind_id)
        st.gens.append(st.mint_gen)
        st.payloads.append(Optional[ArcPointer[Slab[RecordBatch]]](payload^))
        st.live.append(True)
        return _scan_handle_make(slot, st.mint_gen)

    def open_scan_bind_scope(self) -> ScanBindScope:
        """Open a RAII bind scope over this registry — everything bound between
        here and the scope's destruction is released when it is destroyed,
        INCLUDING on the unwind path.

        It replaces a watermark + release-statement pair, which is correct on
        every non-raising path and skipped entirely by a raise. See
        `ScanBindScope`.
        """
        ref st = self._store[]
        st.open_scopes += 1
        return ScanBindScope(self._store, len(st.live))

    def bind(
        self, binding: ScanBinding, var payload: ArcPointer[Slab[RecordBatch]]
    ) raises -> ScanBinding:
        """Bind `payload` and return the binding STAMPED with this registry's
        handle and epoch.

        Returns a new binding rather than mutating one in place, matching
        `ScanBinding.with_handle`'s shape: a binding is a value on a plan node,
        and a plan node is not something a registry is allowed to reach into.
        """
        var h = self.bind_batches(binding.kind_id, payload^)
        return binding.with_handle(h, self._epoch)

    # -------------------------------------------------------------------------
    # Resolution
    # -------------------------------------------------------------------------

    def payload_arc(
        self, handle: Int
    ) raises -> ArcPointer[Slab[RecordBatch]]:
        """The payload for `handle`, as a refcount bump.

        ⚠ O(1) IN RESIDENT BYTES — a refcount increment, not a batch copy. This
        is what lets a payload-read site take the batches without the plan node
        ever having held them, and it is why moving the Arc out of the IR costs
        nothing at resolve time.

        Returns the Arc BY VALUE rather than a `ref` into `self._payloads` on
        purpose: a `ref` would borrow the registry for as long as the caller
        holds the batches, which is precisely the coupling a handle exists to
        remove. A taken Arc keeps its payload alive even if the slot is evicted
        immediately afterwards.

        Raises `SCAN_REGISTRY_UNKNOWN_HANDLE` for a handle this registry never
        minted, and for a tombstoned slot. `is_bound` is the non-raising form
        and is what the gate uses.
        """
        var slot = _scan_handle_slot(handle)
        ref st = self._store[]
        if handle < 0 or slot >= len(st.live):
            raise Error(
                String(SCAN_REGISTRY_UNKNOWN_HANDLE)
                + String(": handle ")
                + String(handle)
                + String(" was never minted by registry epoch ")
                + String(self._epoch)
                + String(" (it holds ")
                + String(len(st.live))
                + String(" slots)")
            )
        if st.gens[slot] != _scan_handle_gen(handle):
            raise Error(
                String(SCAN_REGISTRY_UNKNOWN_HANDLE)
                + String(": handle ")
                + String(handle)
                + String(" names slot ")
                + String(slot)
                + String(" at mint generation ")
                + String(Int(_scan_handle_gen(handle)))
                + String(", which registry epoch ")
                + String(self._epoch)
                + String(" reclaimed (the slot is now at generation ")
                + String(Int(st.gens[slot]))
                + String("). The bind scope that minted this handle closed;")
                + String(" resolving it would hand back another query's bytes,")
                + String(" which is why the generation is in the handle.")
            )
        if not st.live[slot]:
            raise Error(
                String(SCAN_REGISTRY_UNKNOWN_HANDLE)
                + String(": handle ")
                + String(handle)
                + String(" was evicted from registry epoch ")
                + String(self._epoch)
            )
        return st.payloads[slot].value().copy()

    def evict(mut self, handle: Int) raises:
        """Tombstone a slot AND RELEASE ITS PAYLOAD.

        Two effects, and the second one is the point; the difference is
        invisible to every bookkeeping assertion:

          1. BOOKKEEPING — `_live[handle] = False`. The handle space does not
             shift, so a plan node that still names this index gets
             `SCAN_BINDING_HANDLE_NOT_BOUND` (a live registry, a reclaimed
             slot) rather than silently resolving to whatever a compaction
             moved in.
          2. RESIDENCY — `_payloads[handle] = None`, dropping this registry's
             `ArcPointer`. If no other holder remains, the `Slab` and every
             `RecordBatch` in it are freed HERE.

        ⚠ WITHOUT (2) THIS METHOD IS A LIE THAT NO COUNT CAN CATCH.
        `num_bound()` reads `_live`, so a tombstone-only evict takes it to zero
        while the bytes stay resident — which means a falsifier written against
        `num_bound` would go GREEN on a broken implementation. Assert against
        `resident_payload_rows()`, which can only be answered by dereferencing
        an Arc this registry actually still holds.

        A reader that already took its Arc via `payload_arc` is unaffected: that
        handoff is by value, so its payload survives an immediate eviction. This
        is the sentence that makes eviction safe to call while a query is in
        flight.
        """
        var slot = _scan_handle_slot(handle)
        ref st = self._store[]
        if handle < 0 or slot >= len(st.live):
            raise Error(
                String(SCAN_REGISTRY_UNKNOWN_HANDLE)
                + String(": cannot evict handle ")
                + String(handle)
                + String(" — registry epoch ")
                + String(self._epoch)
                + String(" never minted it")
            )
        if st.gens[slot] != _scan_handle_gen(handle):
            # A STALE handle whose slot has already been reclaimed and re-minted
            # for other bytes. Evicting on the slot alone would free a LIVE
            # payload belonging to an unrelated query — the same class of bug
            # `_release_inmem_payload`'s foreign-epoch guard exists for, one
            # level down. A no-op is the correct answer: the bytes this handle
            # named are already gone.
            return
        if not st.live[slot]:
            # ★ IDEMPOTENCE — A SECOND RELEASE OF THE SAME HANDLE IS A NO-OP,
            # AND WITHOUT THIS CLAUSE IT IS *WRONG DATA*.
            #
            # ⚠ THE FREE LIST BELOW IS WHAT MAKES A DOUBLE RELEASE DANGEROUS.
            # `evict` does not touch `gens[slot]`, so the generation check above
            # PASSES AGAIN on a repeat call with the same handle: without this
            # guard, the second call would push `slot` onto `free` a SECOND time
            # and bump the generation a second time. Two subsequent binds would
            # then pop the SAME index at the SAME `mint_gen` and be handed the
            # SAME handle, with the second payload overwriting the first — two
            # simultaneously-live bindings resolving to one slot. That is a
            # query reading another query's bytes: not a raise, not a leak, the
            # wrong rows, which is the exact class the mint generation exists
            # to prevent.
            #
            # A NO-OP rather than a raise, for the same reason as the stale
            # branch above and as `_release_inmem_payload`'s two no-op guards: a
            # double release is the ordinary consequence of an error path
            # retrying, and a release verb that punishes being called twice is
            # one that callers wrap in state-tracking of their own — which is
            # how release paths end up unwired. The bytes this handle named are
            # already gone either way.
            #
            # ⚠ AND IT IS THE `live` FLAG THAT ANSWERS THIS, NOT THE FREE LIST.
            # Liveness is the truth about the slot; the free list is a
            # derivative of it. Testing membership of `free` would be O(n) AND
            # would still miss a slot released by a closing `ScanBindScope` at
            # generation exhaustion, which is released-but-never-freed.
            return
        st.live[slot] = False
        st.payloads[slot] = Optional[ArcPointer[Slab[RecordBatch]]](None)

        # ---- 3. RECLAIM — hand the slot back to the mint pool.
        # ⚠ WITHOUT THIS THE HANDLE SPACE IS UNBOUNDED ON THE MATVIEW PATH.
        # `evict` is the release verb for the ONE lifecycle that deliberately
        # does not go through a `ScanBindScope` — acquire in
        # `create_materialized_view`, release in `drop_materialized_view` — so
        # nothing else would ever reclaim its slots, and `num_slots()` would
        # climb 1,2,3,… across create/drop cycles and across refreshes of ONE
        # view, at zero residency, on the warm per-worker context.
        #
        # THE GENERATION BUMP IS WHAT MAKES IT SAFE, exactly as for the scope: a
        # plan node still naming this slot must MISS rather than resolve into
        # whoever re-mints the index. At the last expressible generation the
        # reclaim STOPS instead of wrapping — the payload is already gone above,
        # so RESIDENCY is unaffected. ⚠ That is not the same as "exhaustion is
        # cheap": with reclaim stopped the slot arrays grow monotonically and
        # `bind_batches` eventually refuses every in-memory bind by name. See
        # `_SCAN_HANDLE_GEN_MAX`.
        if st.mint_gen < _SCAN_HANDLE_GEN_MAX:
            st.mint_gen += 1
            st.free.append(slot)

    # -------------------------------------------------------------------------
    # Introspection (tests, EXPLAIN, and the ledger)
    # -------------------------------------------------------------------------

    def num_slots(self) -> Int:
        """The size of the HANDLE SPACE — live entries plus tombstones.

        ⚠ THE HANDLE-SPACE ORACLE, and it is the only number that can see
        unbounded handle growth. `resident_payload_rows()` cannot see it — that
        is a statement about BYTES, and this is a statement about the arrays
        that index them. Assert it across a LOOP of queries: a single query
        cannot distinguish "reclaims" from "grew once".
        """
        return len(self._store[].live)

    def total_mints(self) -> UInt64:
        """Slots ever minted — MONOTONE, unaffected by evict or by reclaim.

        THE ANTI-VACUITY ORACLE: "did this pass bind anything at all". Use it
        wherever a falsifier needs that before asserting residency is zero;
        `num_slots()` cannot answer it any more, because a correct pass reclaims
        its slots and leaves the handle space where it found it.
        """
        return self._store[].total_mints

    def num_bound(self) -> Int:
        """Live (non-tombstoned) entries — BOOKKEEPING, reads `_live`.

        ⚠ NOT A RESIDENCY MEASURE, and a falsifier that uses it as one can
        miss a retention bug: this counter is correct about bindings and says
        nothing about bytes. Worse in the other direction — a tombstone-only
        `evict` takes this to 0 while the payload stays resident, so a test
        written here goes green on a broken implementation. Use
        `resident_payload_rows()` / `num_resident_payloads()`.
        """
        ref st = self._store[]
        var n = 0
        for i in range(len(st.live)):
            if st.live[i]:
                n += 1
        return n

    # -------------------------------------------------------------------------
    # RESIDENCY — what this registry still HOLDS, as distinct from what it still
    # ACKNOWLEDGES.
    # -------------------------------------------------------------------------

    def num_resident_payloads(self) -> Int:
        """Slots whose `ArcPointer` this registry STILL HOLDS.

        Walks `_payloads`, never `_live`. The two disagree exactly when a slot
        is tombstoned without its Arc being dropped — which is the whole defect
        class this pair of methods exists to make visible. Post-fix they agree
        for every slot; a future retention policy that reclaims bytes while
        keeping a slot addressable would make them disagree in the OTHER
        direction, which is fine and is why they are two methods.
        """
        ref st = self._store[]
        var n = 0
        for i in range(len(st.payloads)):
            if st.payloads[i]:
                n += 1
        return n

    def resident_payload_rows(self) raises -> Int:
        """Total rows across every payload this registry still holds.

        ⚠ THE RESIDENCY ORACLE, and the reason it is rows rather than slots:
        answering it requires DEREFERENCING the `ArcPointer` and reading the
        `RecordBatch`es behind it. A flag cannot satisfy it, a stored count
        cannot drift into satisfying it, and an implementation that released the
        bytes but kept a number would have to be a deliberate lie rather than an
        oversight.

        This is the assertion a "does the release API still release" falsifier
        must be written against. `num_bound()` is the one it must NOT be written
        against — see that method.

        Rows, not bytes: rows are exact and allocator-independent, whereas a
        byte figure over Arrow buffers is an estimate whose formula would itself
        need a test. The property under test is "is this payload still reachable
        from the registry", and rows answer it decisively.
        """
        ref st = self._store[]
        var n = 0
        for i in range(len(st.payloads)):
            if not st.payloads[i]:
                continue
            ref slab = st.payloads[i].value()[]
            for b in range(len(slab)):
                n += slab[b].num_rows()
        return n

    def kind_at(self, handle: Int) raises -> UInt32:
        """The kind a slot was minted for. Raises for an unknown handle."""
        var slot = _scan_handle_slot(handle)
        ref st = self._store[]
        if handle < 0 or slot >= len(st.live):
            raise Error(
                String(SCAN_REGISTRY_UNKNOWN_HANDLE)
                + String(": handle ")
                + String(handle)
                + String(" was never minted by registry epoch ")
                + String(self._epoch)
            )
        return st.kinds[slot]

    def handle_is_unbound_sentinel(self, handle: Int) -> Bool:
        """`SCAN_HANDLE_UNBOUND` is not a slot and never becomes one. Named so a
        caller does not have to know the sentinel's value to ask."""
        return handle == SCAN_HANDLE_UNBOUND
