# =============================================================================
# compaction_policy -- when a delta chain is worth folding into a fresh base.
# =============================================================================
#
# A chain is folded when either threshold trips, so reading never costs more than
# a bounded number of deltas and a delta layer never grows to the size of the
# base it sits on:
#
#   * count: the chain holds `delta_count_max` deltas or more;
#   * size:  the deltas' bytes, scaled by the denominator, reach the base's
#            bytes scaled by the numerator.
#
# The size ratio is an exact integer ratio, so the trigger is deterministic. A
# policy reads no clock; an age-based trigger is the host's to add, with its own
# clock.
# =============================================================================


@fieldwise_init
struct CompactionPolicy(Copyable, ImplicitlyCopyable, Movable):
    """The count-or-size compaction trigger.

    Fields:
        delta_count_max: Fold once the chain holds this many deltas or more. A
            value of one or less folds every chain that has a delta; a very
            large value turns the count leg off.
        bytes_fraction_num: Numerator of the size leg's ratio.
        bytes_fraction_den: Denominator of the size leg's ratio. A value of zero
            or less turns the size leg off.

    The size leg fires when `delta_bytes * den >= base_bytes * num`. A chain
    with no deltas is never folded: there is nothing to fold, and a policy with
    a zero numerator would otherwise ask for a rewrite after every rewrite.
    """

    var delta_count_max: Int
    var bytes_fraction_num: Int64
    var bytes_fraction_den: Int64

    @staticmethod
    def default() -> CompactionPolicy:
        """Fold at 32 deltas, or once the deltas reach half the base's bytes."""
        return CompactionPolicy(32, Int64(1), Int64(2))

    def should_compact(
        self, num_deltas: Int, delta_bytes: Int64, base_bytes: Int64
    ) -> Bool:
        """True iff the count leg or the size leg trips.

        Args:
            num_deltas: The number of deltas on the chain.
            delta_bytes: The total bytes of the delta objects.
            base_bytes: The total bytes of the base table objects.
        """
        if num_deltas <= 0:
            return False
        if num_deltas >= self.delta_count_max:
            return True
        if self.bytes_fraction_den <= Int64(0):
            return False
        return (
            delta_bytes * self.bytes_fraction_den
            >= base_bytes * self.bytes_fraction_num
        )
