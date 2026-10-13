# =============================================================================
# optimizer_cost_order -- the total order on DP join candidates
# =============================================================================
#
# `dp_pair_beats` decides whether a DPccp candidate replaces the entry already
# in the DP table for the same relation set (`optimizer_dpccp.emit_pair`).
# The DP costs are Float64 sums of integer cardinalities, and a symmetric
# join graph gives several decompositions of one set the same sum. Before
# this order existed the first candidate emitted kept the entry, so the tree
# chosen depended on the enumerator's emission order, which
# komira-ai/komira#1176 will change. Here a tie is broken on the relation-set
# bitmasks, so the choice is a function of the plan alone (relation ids
# follow the order of the chain's leaves in the input plan).
#
# The other cost comparisons the driver's passes make compare integers and
# keep the input on a tie: build-side selection keeps the written operand
# order, and greedy reordering keeps the lowest chain position.
#
# The costs are sums of integer cardinalities: exact up to 2^53, and above
# it rounded by IEEE-754 addition, which gives the same result on every
# platform (Mojo's `+` on Float64 carries no fast-math flag, so it is not
# contracted or reassociated). No cost is NaN; a NaN would compare as a tie
# and fall to the bitmask order rather than win.
# =============================================================================


def dp_pair_beats(
    cost: Float64,
    left_bits: UInt64,
    right_bits: UInt64,
    incumbent_cost: Float64,
    incumbent_left_bits: UInt64,
    incumbent_right_bits: UInt64,
) -> Bool:
    """Whether the candidate `(left_bits, right_bits)` at `cost` replaces the
    incumbent DP entry for the same combined relation set.

    The lower cost wins. At an equal cost the lower `left_bits` wins, then the
    lower `right_bits`. Two candidates for one combined set with the same
    `left_bits` have the same `right_bits`, so the last comparison only
    matters to a caller that passes unrelated sets.

    Args:
        cost: The candidate's cumulative cost.
        left_bits: The candidate's left relation set.
        right_bits: The candidate's right relation set.
        incumbent_cost: The cost of the entry in the table.
        incumbent_left_bits: The entry's left relation set.
        incumbent_right_bits: The entry's right relation set.

    Returns:
        True when the candidate orders strictly before the incumbent.
    """
    if cost < incumbent_cost:
        return True
    if cost > incumbent_cost:
        return False
    if left_bits != incumbent_left_bits:
        return left_bits < incumbent_left_bits
    return right_bits < incumbent_right_bits
