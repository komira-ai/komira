# =============================================================================
# TopNBoundary -- the running Top-N cut-off, shared between a Top-N sink and
# the scan that feeds it.
# =============================================================================
#
# WHAT IT IS. A Top-N operator over a scan knows, the moment it holds N
# candidate rows, a value that NO further row can be worse than and still make
# the answer: the key of its current N-th best row. Publishing that value back
# INTO the scan turns an unfiltered scan into a filtered one, mid-flight. It is
# DuckDB's `TopNBoundaryValue` (an internal module of DuckDB v1.5.5), which their `PhysicalTopN` pushes as a dynamic table
# filter and `ParquetReader::PrepareRowGroupBuffer` consumes to skip a whole row
# group untouched.
#
# ⭐ WHY IT IS A SEPARATE OBJECT AND NOT A FIELD ON EITHER SIDE. The producer
# (the sink) and the consumer (the source) are two independently-moved values
# that the morsel executor owns at the same time; neither can hold a `ref` to
# the other. Shared ownership of ONE cell is the whole requirement, so the shape
# is `komira_core.cancellation.token`'s verbatim:
#
#   * `OwnedPointer[Atomic[...]]` because `Atomic` is NOT Movable on this
#     compiler and `ArcPointer` requires `T: Movable`;
#   * `ArcPointer[_BoundaryCell]` for the sharing, encapsulated in a private
#     field -- no ArcPointer and no UnsafePointer in any public signature
# (maintainer directive);
#   * an explicit `clone()` rather than implicit `Copyable`, because
#     `List[ArcPointer[T]]` has no synthesised copy.
#
# ⛔ THE ONE INVARIANT, AND IT IS A CORRECTNESS INVARIANT, NOT A TUNING ONE.
# A published boundary must be an UPPER bound (ASC) / LOWER bound (DESC) on the
# key of the final N-th best row. That is guaranteed iff the publisher holds at
# least N candidate rows of its own: if a worker has N rows whose keys are all
# <= b, then the global N-th best key is <= b, whatever every other worker
# holds. A publisher with FEWER than N rows knows nothing and must stay silent.
#
# ⛔ AND THE PRUNE IS `>`, NEVER `>=`. A row whose key EQUALS the boundary can
# still enter the answer -- on a tie-break key, or because the boundary came
# from a worker whose N-th best is exactly that value. Pruning the equal case
# drops rows the unpruned scan would have kept, which is a WRONG ANSWER with
# the right shape. `prunes_range` states this once so no caller re-derives it.
#
# UNSET IS A SENTINEL, NOT A FLAG. `Int64.MAX` (ASC) / `Int64.MIN` (DESC) means
# "nobody has published yet", which collapses the publish to a single CAS loop
# with no second word to keep coherent. A real key EQUAL to the sentinel is
# therefore indistinguishable from unset -- and that fails SAFE: the scan simply
# prunes nothing. It is the one direction this file may fail in.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import alloc, ArcPointer, OwnedPointer, UnsafePointer


comptime _ASC_UNSET: Int64 = Int64.MAX
comptime _DESC_UNSET: Int64 = Int64.MIN


struct _BoundaryCell(Movable, Deinitable):
    """The one shared 64-bit word. `OwnedPointer[Atomic[...]]` indirection for
    the same reason `komira_core.cancellation.token._AtomicSlot` has it:
    `Atomic` is not Movable and `ArcPointer` requires a Movable payload."""

    var _v: OwnedPointer[AtomicI64]

    def __init__(out self, initial: Int64):
        var raw = alloc[AtomicI64](1)
        # SAFETY: `raw` is a fresh single-element allocation this call owns and
        # immediately hands to `OwnedPointer`; nothing else can observe it in
        # between. Atomic's ctor takes a Scalar value.
        raw[] = AtomicI64(initial)
        self._v = OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


@fieldwise_init
struct TopNBoundary(Movable, Deinitable):
    """A shared, monotonically-tightening Top-N cut-off value.

    Movable, not Copyable -- `clone()` explicitly (refcount bump), exactly as
    `CancellationToken` does, and for the same reason.
    """

    # One-element List because a bare `ArcPointer` field would make the struct
    # non-`@fieldwise_init`-able alongside the Bool without a hand-written ctor;
    # the List also mirrors the token's chain shape, which is the pattern this
    # file is a copy of.
    var _cell: List[ArcPointer[_BoundaryCell]]
    var _descending: Bool

    @staticmethod
    def new(descending: Bool) -> TopNBoundary:
        """A boundary in the UNSET state for the given sort direction."""
        var unset = _DESC_UNSET if descending else _ASC_UNSET
        var cell = List[ArcPointer[_BoundaryCell]](capacity=1)
        cell.append(ArcPointer[_BoundaryCell](_BoundaryCell(unset)))
        return TopNBoundary(_cell=cell^, _descending=descending)

    @always_inline
    def clone(self) -> TopNBoundary:
        """Explicit share. The returned handle names the SAME cell."""
        var cell = List[ArcPointer[_BoundaryCell]](capacity=1)
        cell.append(ArcPointer[_BoundaryCell](copy=self._cell[0]))
        return TopNBoundary(_cell=cell^, _descending=self._descending)

    @always_inline
    def descending(self) -> Bool:
        return self._descending

    @always_inline
    def unset_sentinel(self) -> Int64:
        return _DESC_UNSET if self._descending else _ASC_UNSET

    @always_inline
    def load(self) -> Int64:
        """The current cut-off, or `unset_sentinel()` when nobody has
        published. A relaxed read: a stale value only costs a prune, never
        correctness, because the boundary only ever tightens."""
        return self._cell[0][]._v[].load()

    @always_inline
    def is_set(self) -> Bool:
        return self.load() != self.unset_sentinel()

    def publish(mut self, candidate: Int64):
        """Tighten the boundary to `candidate` if it is tighter.

        ⛔ THE CALLER MUST HOLD AT LEAST N CANDIDATE ROWS. See the module
        header: that is what makes the value an upper (ASC) / lower (DESC)
        bound on the FINAL N-th best key rather than a guess.

        Lock-free; loses races harmlessly (a loser re-reads the tighter value
        and returns). Monotone by construction, so the CAS loop terminates.
        """
        while True:
            var old = self._cell[0][]._v[].load()
            if self._descending:
                if candidate <= old:
                    return
            else:
                if candidate >= old:
                    return
            var expected = old
            if self._cell[0][]._v[].compare_exchange(expected, candidate):
                return

    @always_inline
    def prunes_range(self, unit_min: Int64, unit_max: Int64) -> Bool:
        """True iff NO row in a unit whose key lies in `[unit_min, unit_max]`
        can enter the top N, given the boundary published so far.

        ⛔ STRICT comparison -- a key EQUAL to the boundary survives. See the
        module header.
        """
        var b = self._cell[0][]._v[].load()
        if self._descending:
            if b == _DESC_UNSET:
                return False
            return unit_max < b
        if b == _ASC_UNSET:
            return False
        return unit_min > b
