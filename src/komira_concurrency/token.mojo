# =============================================================================
# komira_concurrency.token — CancellationToken + Cancellable
# =============================================================================
# A CLEAN LEAF — it imports only `std.memory` + `std.atomic` — so it
# belongs in `komira_core`: the arrow IPC dispatch entries need
# `CancellationToken` in their signatures, and keeping the token here lets
# them reach it without depending on the async runtime.
#
# CancellationToken is the canonical shared-ownership Movable wrapper:
# internally `_chain: List[ArcPointer[_AtomicSlot]]` holding the full
# ancestor chain root → leaf. ArcPointer is encapsulated; it never
# appears in public method signatures.
#
# Token tree implementation (flat-list ancestor chain):
#   Mojo 0.26.3 rejects recursive struct fields ("struct has recursive
#   reference to itself"), so the natural "parent: ArcPointer<token>"
#   shape doesn't compile. Instead, each token holds a flat List of
#   ArcPointer[_AtomicSlot] representing its FULL ancestor chain
#   (root → leaf). The token's OWN cancellation slot is the LAST entry;
#   cancellation by self mutates only that last slot. is_cancelled() walks
#   the list checking each slot's flag — if ANY ancestor is cancelled,
#   this token is cancelled too. Cancellation cascades downward (parent's
#   cancel sets parent's slot; descendants observe via shared list entry)
#   but NOT upward (child's cancel sets only the child's slot).
#
#   When a child is constructed, it COPIES the parent's chain (List clone +
#   refcount bump on each ArcPointer slot via `copy=`) and appends its own
#   fresh slot. Memory cost: O(depth) per token; fine for the bounded-depth
#   case (practical bound: 32; not enforced).
#
# Movable but NOT Copyable:
#   Mojo 0.26.3 cannot synthesize implicit copy for a struct holding
#   `List[ArcPointer[T]]` (the List's copy synthesis hits a non-trivial
#   element copy via ArcPointer(copy=...)). To preserve ArcPointer's
#   refcount semantics + simplify the substrate API, CancellationToken
#   exposes EXPLICIT `clone()` instead of implicit Copyable. Downstream
#   types (JoinHandle, ExecutionBudget, TaskScope) hold CancellationToken
#   fields by value (Movable transfer); when shared, callers explicitly
#   `clone()` at the share boundary. Same shape as the engine's
#   `DynamicFilter` (manual `copy()` method).
#
# Atomic dtype rationale:
#   * cancel flag: Atomic[DType.uint8] — only needs store/load (no
#     compare_exchange or fetch_*). uint8 supports those on Mojo 0.26.3.
#   * NOT Atomic[DType.bool]: bool dtype rejects pop.atomic.rmw.
#
# Pointer discipline:
#   * ArcPointer encapsulated in `_chain` field (List of slots).
#   * Public methods take/return value-typed `CancellationToken`.
#   * No UnsafePointer in any public method signature.
#   * No wildcard origins.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from komira_atomic_alias import AtomicU8


# Single ancestor-chain entry. Holds flag + reason + frozen flag for one
# level of the tree. Wrapped by ArcPointer in the chain so descendants
# share the slot.
struct _AtomicSlot(Movable, Deinitable):
    """One slot in the ancestor chain. Holds the cancel flag, reason, and
    frozen marker for a single level of the tree.

    OwnedPointer[Atomic] indirection because Atomic[DType.uint8] is NOT
    Movable on Mojo 0.26.3; ArcPointer requires T: Movable.
    """

    var _flag: OwnedPointer[AtomicU8]
    var _reason: String
    var _frozen: Bool

    def __init__(out self, frozen: Bool):
        var raw = alloc[AtomicU8](1)
        # SAFETY: raw is a fresh allocation we own. Atomic ctor accepts a
        # Scalar value. Ownership transfers to OwnedPointer.
        raw[] = AtomicU8(UInt8(0))
        self._flag = OwnedPointer[AtomicU8](unsafe_from_raw_pointer=raw)
        self._reason = String("")
        self._frozen = frozen


@fieldwise_init
struct CancellationToken(Movable, Deinitable):
    """Cheap-to-clone, lock-free cancellation handle.

    See module docstring for design notes.

    Public surface (no ArcPointer crossings):
      * static `new()` — root token.
      * static `never()` — non-cancellable (frozen) token.
      * `clone()` — explicit deep clone (refcount bumps on each slot).
      * `is_cancelled()` — walks ancestor chain checking each slot.
      * `cancel(reason)` — idempotent; mutates only the LAST slot.
      * `child()` — derives a new token with self as parent.
      * `reason()` — first non-empty reason in the chain (root → leaf).

    NOT Copyable — use `clone()` explicitly. The Movable-only constraint
    matches the engine's DynamicFilter pattern.
    """

    # Ancestor chain: ordered root → leaf. Last entry is THIS token's own
    # slot. Earlier entries are ancestors. List of ArcPointer makes each
    # slot shared across descendants.
    var _chain: List[ArcPointer[_AtomicSlot]]

    @staticmethod
    @always_inline
    def new() -> CancellationToken:
        """Construct a root token (chain has 1 entry: own slot).

        Pre-sizes the List capacity to 1: the default `List()` ctor
        allocates with capacity=0 and grows on first append, costing two
        heap operations; pre-sizing collapses to one alloc.
        """
        var chain = List[ArcPointer[_AtomicSlot]](capacity=1)
        chain.append(ArcPointer[_AtomicSlot](_AtomicSlot(frozen=False)))
        return CancellationToken(_chain=chain^)

    @staticmethod
    @always_inline
    def never() -> CancellationToken:
        """The never-cancelled token. cancel()
        on a never-token is silently ignored (frozen flag).

        Each call constructs a fresh frozen token; the List is pre-sized
        to 1 (same rationale as `new()`).
        """
        var chain = List[ArcPointer[_AtomicSlot]](capacity=1)
        chain.append(ArcPointer[_AtomicSlot](_AtomicSlot(frozen=True)))
        return CancellationToken(_chain=chain^)

    @always_inline
    def clone(self) -> CancellationToken:
        """Explicit clone. Refcount-bumps each slot in the chain. Used by
        engine code that wants to share the same logical token across
        multiple owners (sink + probe; spawn parent + child; etc.).

        Same shape as the engine's DynamicFilter.copy().

        Pre-sizes the destination List to the source chain length,
        eliminating the grow-on-append realloc in the depth-1 typical case.
        Inlined so the chain-walk loop is visible to the compiler for
        unroll/specialization when depth is statically known.
        """
        var n = len(self._chain)
        var new_chain = List[ArcPointer[_AtomicSlot]](capacity=n)
        for i in range(n):
            new_chain.append(ArcPointer[_AtomicSlot](copy=self._chain[i]))
        return CancellationToken(_chain=new_chain^)

    @always_inline
    def is_cancelled(self) -> Bool:
        """Returns True if THIS token or any
        ancestor in the chain has been cancelled.

        Cost: O(depth-of-chain). Polled per morsel boundary, so
        the read is cold; depth bounded by spawn nesting (practical
        bound: 32; not enforced).

        @always_inline so the depth-1 typical case (one atomic load +
        branch) is visible to a trampoline's between-task poll.
        """
        for i in range(len(self._chain)):
            if self._chain[i][]._flag[].load() != UInt8(0):
                return True
        return False

    def cancel(mut self, reason: String):
        """Cancel this token (mutates ONLY the
        last slot in the chain — ancestors are not modified). Cascade-
        downward is implicit: descendants share the same slot via their
        ancestor chain.

        Idempotent: first call sets the flag; second call is a no-op (flag
        already non-zero; we don't overwrite the reason).

        Frozen tokens (from never()) silently ignore cancel.
        """
        var n = len(self._chain)
        if n == 0:
            return  # Defensive — should not happen.
        var last_idx = n - 1
        if self._chain[last_idx][]._frozen:
            return
        if self._chain[last_idx][]._flag[].load() != UInt8(0):
            return  # Already cancelled; idempotent no-op.
        # Write reason BEFORE flag (Release fence implicit via Atomic.store).
        self._chain[last_idx][]._reason = reason
        AtomicU8.store(
            UnsafePointer(to=self._chain[last_idx][]._flag[])
            .unsafe_bitcast[Scalar[DType.uint8]](), UInt8(1),
        )

    def child(self) -> CancellationToken:
        """Returns a new child token whose ancestor
        chain is self's chain + a fresh own-slot.

        Each ArcPointer in the chain is cloned (refcount bump); the new
        own-slot is allocated fresh.

        Pre-sizes the destination List to the ancestor count + 1 (own
        slot) to skip the grow-on-append realloc.
        """
        var n = len(self._chain)
        var new_chain = List[ArcPointer[_AtomicSlot]](capacity=n + 1)
        for i in range(n):
            new_chain.append(ArcPointer[_AtomicSlot](copy=self._chain[i]))
        new_chain.append(ArcPointer[_AtomicSlot](_AtomicSlot(frozen=False)))
        return CancellationToken(_chain=new_chain^)

    def reason(self) -> String:
        """Returns the first non-empty reason in
        the chain (root → leaf), or "" if no slot is cancelled.

        Walks root-to-leaf so the OUTERMOST cancellation reason wins (which
        matches the user's mental model: a parent cancelling for a query-
        deadline reason should surface that reason in every descendant).
        """
        for i in range(len(self._chain)):
            if self._chain[i][]._flag[].load() != UInt8(0):
                return self._chain[i][]._reason
        return String("")


trait Cancellable(Deinitable):
    """Anything that holds a
    CancellationToken and exposes it. Engine code that owns long-lived state
    (per-query state, scheduler tasks) implements Cancellable so cancellation
    propagates without manual plumbing."""

    def cancellation_token(self) -> CancellationToken:
        ...

    def is_cancelled(self) -> Bool:
        ...
