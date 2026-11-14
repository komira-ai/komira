# =============================================================================
# LoserTree: a tournament tree for k-way merge
# =============================================================================
#
# A loser tree costs log2(k) comparisons per output element, against
# 2*log2(k) for a binary heap, and replays a fixed leaf-to-root path, which
# branch prediction likes. It is the k-way merge of sorted runs (for example
# the runs an external sort spills).
#
# The tree has `capacity` leaves (the next power of two >= the number of
# streams) and `capacity` internal nodes. Each internal node holds the LOSER
# of the match played there; `nodes[0]` holds the overall winner. Stream `i`
# is leaf `i + capacity`; the parent of node `j` is `j / 2`. When the winning
# stream advances, only its path to the root is replayed.
#
# The tree stores stream indices only and knows nothing about keys: the
# caller's `LoserTreeComparator` owns the streams and their cursors and
# answers `is_less(a, b)` / `is_exhausted(i)`.
#
# `LOSER_TREE_SENTINEL` (-1) marks a padding leaf or an empty tree.
# =============================================================================


comptime LOSER_TREE_SENTINEL: Int = -1


trait LoserTreeComparator(Deinitable):
    """Comparator contract for LoserTree.

    Implementations own the per-stream cursors and the sorted-run data.

    Contract:
      - `is_less(a, b)` returns True iff stream `a`'s current element is
        strictly less than stream `b`'s. For exhausted streams, is_less
        must return False (exhausted stream always "loses"). `mut` because
        implementations may advance cursors or update caches; however the
        LoserTree itself never mutates cursors via is_less -- only queries.
      - `is_exhausted(i)` returns True iff stream `i` has no more elements.

    Movable is intentionally NOT required: the tree only ever borrows
    `mut cmp`, never moves it, so a comparator may own non-Movable state
    (its cursors, by value) instead of reaching it through a pointer.
    """

    def is_less(mut self, a: Int, b: Int) -> Bool: ...
    def is_exhausted(self, i: Int) -> Bool: ...


@always_inline
def _next_power_of_two(n: Int) -> Int:
    """Smallest power of 2 >= n. Precondition: n >= 1."""
    var p = 1
    while p < n:
        p = p * 2
    return p


struct LoserTree(Movable, Deinitable):
    """Loser tree for k-way merge. Maintains the invariant that the overall
    minimum element is always available via `peek_winner()`. Streams are
    identified by index 0..num_streams.

    Not Copyable: owns `nodes` List by value. Move is fine for threading the
    tree through a merge loop.
    """

    var nodes: List[Int]
    """`nodes[0]` = winner stream index (or SENTINEL if all exhausted).
    `nodes[1..capacity]` = loser stream index at each internal node."""

    var capacity: Int
    """Next power of 2 >= num_streams. Number of internal nodes and also
    the offset for leaf indexing."""

    var num_streams: Int
    """Actual number of input streams (may be < capacity)."""

    def __init__[C: LoserTreeComparator](out self, num_streams: Int, mut cmp: C):
        """Builds a new loser tree for `num_streams` input streams.

        `cmp.is_less(a, b)` must return True iff stream `a`'s current element is
        strictly less than stream `b`'s. Exhausted streams should "lose"
        (is_less returns False when either arg is exhausted).

        Precondition: num_streams >= 1. A zero-stream tree is nonsensical.
        """
        debug_assert(num_streams > 0, "loser tree requires at least one stream")

        if num_streams == 1:
            var n1 = List[Int]()
            n1.append(0)
            self.nodes = n1^
            self.capacity = 1
            self.num_streams = num_streams
            return

        var capacity = _next_power_of_two(num_streams)

        # Internal nodes (indices 0..capacity). nodes[0] = overall winner.
        var nodes = List[Int]()
        for _ in range(capacity):
            nodes.append(LOSER_TREE_SENTINEL)

        # winners[i] at position i holds the winner propagated up to that node.
        # Size is 2*capacity: leaves live at capacity..2*capacity.
        var winners = List[Int]()
        for _ in range(2 * capacity):
            winners.append(LOSER_TREE_SENTINEL)

        # Initialize leaves: leaves[i] = stream i for i < num_streams, else SENTINEL.
        for i in range(num_streams):
            winners[capacity + i] = i
        # Leaves capacity+num_streams .. 2*capacity stay SENTINEL (virtual empty streams).

        # Build from bottom internal node up to root (node 1).
        # Children of internal node `pos` are `2*pos` and `2*pos+1`.
        # Winner propagates up, loser stays at `pos`.
        var pos = capacity - 1
        while pos >= 1:
            var left = winners[2 * pos]
            var right = winners[2 * pos + 1]

            if left == LOSER_TREE_SENTINEL and right == LOSER_TREE_SENTINEL:
                # Both children virtual/exhausted.
                nodes[pos] = LOSER_TREE_SENTINEL
                winners[pos] = LOSER_TREE_SENTINEL
            elif right == LOSER_TREE_SENTINEL:
                # Only left child valid -- it wins.
                nodes[pos] = LOSER_TREE_SENTINEL  # no real loser
                winners[pos] = left
            elif left == LOSER_TREE_SENTINEL:
                # Only right child valid -- it wins.
                nodes[pos] = LOSER_TREE_SENTINEL
                winners[pos] = right
            else:
                # Both valid: compare. Winner propagates up, loser stays.
                if cmp.is_less(left, right):
                    # left wins
                    nodes[pos] = right  # loser
                    winners[pos] = left  # winner propagates
                else:
                    # right wins (or equal -- right wins to maintain stability)
                    nodes[pos] = left
                    winners[pos] = right
            pos -= 1

        # The overall winner is the winner at node 1 (the root internal node).
        nodes[0] = winners[1]

        self.nodes = nodes^
        self.capacity = capacity
        self.num_streams = num_streams

    @always_inline
    def peek_winner(self) -> Int:
        """Returns the index of the stream with the current minimum element,
        or LOSER_TREE_SENTINEL (-1) if all streams were INITIALLY empty.

        Contract:
          - Before any elements are consumed, the returned index either refers
            to a live stream (caller reads its current element), or is
            SENTINEL iff every stream started empty.
          - After consumption drains all streams, peek_winner may still return
            a real (but now-exhausted) stream index -- the tournament replay
            does not substitute SENTINEL when both winner and opponent are
            dead. Callers MUST guard the merge loop with `is_exhausted()` on
            the reported winner and stop when it is exhausted.
        """
        return self.nodes[0]

    def update_winner[C: LoserTreeComparator](mut self, mut cmp: C):
        """Called after the winner's stream has been advanced (or exhausted).

        Replays the tournament from the winner's leaf to the root. The
        `cmp` object must reflect the post-advance state (i.e. `cmp.is_less`
        sees the NEW current element of the just-advanced stream, and
        `cmp.is_exhausted` returns True for streams whose cursor has passed
        the end of their run).
        """
        if self.num_streams == 1:
            if cmp.is_exhausted(0):
                self.nodes[0] = LOSER_TREE_SENTINEL
            return

        var winner = self.nodes[0]
        # If the winner slot is already sentinel, tree is exhausted; nothing to do.
        if winner == LOSER_TREE_SENTINEL:
            return

        # Walk from the winner's leaf up to the root.
        var pos = (winner + self.capacity) // 2

        while pos > 0:
            var opponent = self.nodes[pos]

            # `is_dead`: stream is SENTINEL (padding) or exhausted.
            # Must check exhaustion dynamically since `winner` changes during
            # the walk (after swaps at lower levels).
            var opponent_dead = (
                opponent == LOSER_TREE_SENTINEL
                or (opponent < self.num_streams and cmp.is_exhausted(opponent))
            )
            var winner_dead = (
                winner == LOSER_TREE_SENTINEL
                or (winner < self.num_streams and cmp.is_exhausted(winner))
            )

            var swap: Bool
            if opponent_dead:
                # Opponent is gone -- winner continues up.
                swap = False
            elif winner_dead:
                # Winner is gone -- opponent takes over.
                swap = True
            else:
                # Both valid: compare elements. If winner is NOT less than
                # opponent, opponent wins (swap).
                swap = not cmp.is_less(winner, opponent)

            if swap:
                self.nodes[pos] = winner
                winner = opponent

            pos = pos // 2

        self.nodes[0] = winner
