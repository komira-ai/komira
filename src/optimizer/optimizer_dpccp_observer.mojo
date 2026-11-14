# =============================================================================
# Optimizer DPccp -- the observer the enumerators report each pass and pair to
# =============================================================================
#
# The DPccp enumerators (`emit_pair` and the three recursive enumerators in
# `optimizer_dpccp_enum`, `_run_dpccp_passes` in `optimizer_dpccp_solve`) and
# the solver core (`solve_dpccp_observed`) take an observer conforming to
# `DPccpObserver`.
# They call it at three points:
#
#   - `on_pass_begin(allow_cross)` when an enumeration pass starts (the
#     literal-edge pass, then the cross-product pass if the first pass found
#     no plan for the full set);
#   - `on_pair_scored(candidate)` from `emit_pair` for every pair that passed
#     its guards (both sides have DP entries and a real edge joins them, or
#     the pass admits cross products), after the pair is costed and before
#     the DP table is updated;
#   - `on_pass_end(emit_calls, completed)` when a pass returns: the number of
#     `emit_pair` calls the pass made (the iteration counter) and whether it
#     finished under the iteration cap.
#
# The solver passes `NoDPccpObserver`, whose methods are empty, so the
# production path pays nothing. `optimizer_dpccp_diagnostic.DPccpTrace`
# records what it is told. Because the hooks sit in the enumerator itself, a
# trace reports what the enumerator does, including the repeated emits of
# one csg-cmp pair that this enumerator makes on dense graphs
# (komira-ai/komira#1176): every repeat reaches `on_pair_scored`.
# =============================================================================


struct DPCandidate(Copyable, Movable):
    """One scored (left, right) pair, as `emit_pair` priced it.

    Fields:
        left_set_bits: the left relation subset of the pair.
        right_set_bits: the right relation subset.
        cost: `join_card + left_cost + right_cost`, the value the DP table
            compares (a pair replaces the stored entry only when strictly
            cheaper).
        join_card: the join cardinality `emit_pair` assigned to the pair.
        left_cost: the DP cost of the left subset when the pair was scored.
        right_cost: the DP cost of the right subset.
        left_card: the DP cardinality of the left subset.
        right_card: the DP cardinality of the right subset.
        allow_cross: True iff the pair was scored by the cross-product
            pass (a pair with no real connecting edge is admitted there).
    """

    var left_set_bits: UInt64
    var right_set_bits: UInt64
    var cost: Float64
    var join_card: Int
    var left_cost: Float64
    var right_cost: Float64
    var left_card: Int
    var right_card: Int
    var allow_cross: Bool

    @always_inline
    def __init__(
        out self,
        left_set_bits: UInt64,
        right_set_bits: UInt64,
        cost: Float64,
        join_card: Int,
        left_cost: Float64,
        right_cost: Float64,
        left_card: Int,
        right_card: Int,
        allow_cross: Bool,
    ):
        self.left_set_bits = left_set_bits
        self.right_set_bits = right_set_bits
        self.cost = cost
        self.join_card = join_card
        self.left_cost = left_cost
        self.right_cost = right_cost
        self.left_card = left_card
        self.right_card = right_card
        self.allow_cross = allow_cross

    def combined_bits(self) -> UInt64:
        """The relation subset the pair produces (`left | right`)."""
        return self.left_set_bits | self.right_set_bits


trait DPccpObserver:
    """What the DPccp enumerators report. See the module header for when
    each method is called."""

    def on_pass_begin(mut self, allow_cross: Bool):
        """An enumeration pass starts; `allow_cross` is True for the
        cross-product pass."""
        ...

    def on_pair_scored(mut self, candidate: DPCandidate):
        """`emit_pair` costed `candidate` and is about to update the DP
        table with it."""
        ...

    def on_pass_end(mut self, emit_calls: UInt64, completed: Bool):
        """The pass returned after `emit_calls` calls to `emit_pair`;
        `completed` is False iff it stopped at the iteration cap."""
        ...


struct NoDPccpObserver(DPccpObserver):
    """The observer the solver uses: every method is empty."""

    @always_inline
    def __init__(out self):
        pass

    @always_inline
    def on_pass_begin(mut self, allow_cross: Bool):
        pass

    @always_inline
    def on_pair_scored(mut self, candidate: DPCandidate):
        pass

    @always_inline
    def on_pass_end(mut self, emit_calls: UInt64, completed: Bool):
        pass
