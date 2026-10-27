# =============================================================================
# shuffle_retention_policy: `ShuffleRetentionPolicy[S]`, the driver-side
# retention policy that bounds an unbounded multi-segment stream's shuffle
# storage.
# =============================================================================
#
# The reclaim mechanism is in `komira_shuffle.retention` (`reclaim_floor`,
# `reap_epochs_below`): store-generic, with no opinion about who calls it or
# when. This module is the policy around it, held by the streaming driver for
# one shuffle cut:
#   * it owns a clone of the durable shuffle store, the cut's `shuffle_id` and
#     the plan-fixed set of expected producers;
#   * it keeps `lowest_live_epoch` across passes, so a pass reaps only
#     `[lowest_live_epoch, floor)` and never revisits reaped epochs;
#   * it reaps once every `reap_every_n_rounds` calls, so the driver does not
#     pay a LIST/DELETE pass every round;
#   * it is fail-safe: the floor is the minimum durable consumer cursor
#     across all consumers, never wall-clock time and never the producer's
#     position. When no consumer pins a floor (an empty cursor list, or every
#     cursor the `Int64.MAX` sentinel of a segment that consumes no shuffle) it
#     retains everything. The mechanism's strict `e < floor` keeps the epoch
#     the slowest consumer is positioned at.
#
# The driver calls `maybe_reap` between rounds, never inside a dispatch. The
# store is held by value; there is no pointer in this module.
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore
from komira_shuffle.retention import (
    reclaim_floor,
    reap_epochs_below,
    ShuffleReapStats,
)


# =============================================================================
# §1 — RetentionObservability — what the policy has done so far (test / governor).
# =============================================================================


@fieldwise_init
struct RetentionObservability(Copyable, Movable, Deinitable):
    """A snapshot of the retention policy's cumulative work — the observability
    a test or a governor reads. A plain value (Int64 scalars and a Bool).

    Fields:
      var last_floor: Int64        — the most recent reclaim floor used (the min
        consumer cursor of the last reap pass), or `Int64.MIN` if no reap has run.
      var lowest_live_epoch: Int64 — the persisted lower bound of still-live
        epochs (advanced to `floor` after each reap so successive passes skip
        already-reaped epochs).
      var total_epochs_reaped: Int64 — cumulative WHOLE epochs reclaimed across
        every reap pass.
      var total_objects_deleted: Int64 — cumulative DELETE calls issued.
      var reap_passes: Int64       — how many passes reached a real floor: the
        ones that reaped, and the ones whose floor was at or below
        `lowest_live_epoch` (nothing to reap). A cadence skip or a no-floor
        retain does not count.
      var last_pass_reaped: Bool   — whether the LAST `maybe_reap` call actually
        reaped (False == cadence-skipped or fail-safe-retained)."""

    var last_floor: Int64
    var lowest_live_epoch: Int64
    var total_epochs_reaped: Int64
    var total_objects_deleted: Int64
    var reap_passes: Int64
    var last_pass_reaped: Bool


# =============================================================================
# §2 — ShuffleRetentionPolicy[S] — the driver-side per-cut retention policy.
# =============================================================================
#
# One policy per shuffle cut. Generic over the same store
# backend `S: CloneableConditionalWriteStore` the sink + read source + reaper
# bind, so single-node (LocalFs / in-memory) and multi-node (S3) share the SAME
# policy differing only in store backend.
# =============================================================================


struct ShuffleRetentionPolicy[S: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The driver-side per-cut retention POLICY: collect the durable consumer
    cursors, compute the reclaim floor (`min(cursors)`, fail-safe on a missing
    consumer), and drive the cross-epoch `reap_epochs_below` MECHANISM at a
    cadence, persisting `lowest_live_epoch` across passes. Holds the store by
    value (clone-shared) so it can issue the reaper's DELETE calls between
    rounds.

    Fields:
      var _store: S                — the durable shuffle store (clone-shared with
        the sink / read source — the reaper deletes through it).
      var _shuffle_id: Int64       — the segment-cut shuffle namespace id.
      var _expected_producers: List[Int64] — the plan-fixed producer set the
        reap-pass's seal-read re-verifies (MUST equal the set the driver sealed).
      var _lowest_live_epoch: Int64 — the persisted lower bound of still-live
        epochs (advanced to the floor after each reap; `reap_epochs_below` reaps
        `[lowest_live_epoch, floor)`).
      var _reap_every_n_rounds: Int — the cadence: reap once every N rounds
        (1 == every round; the test default). A reap pass issues LIST/DELETE
        calls, so a >1 cadence amortizes that cost.
      var _rounds_since_reap: Int  — the cadence counter (reset to 0 once a pass
        completes without raising; a raising pass keeps it, so the next call
        retries).
      var _last_floor: Int64       — the last reclaim floor used (observability).
      var _total_epochs_reaped: Int64 — cumulative whole epochs reclaimed.
      var _total_objects_deleted: Int64 — cumulative DELETE calls issued.
      var _reap_passes: Int64      — passes that reached a real floor.
      var _last_pass_reaped: Bool  — whether the last `maybe_reap` reaped.
    """

    var _store: Self.S
    var _shuffle_id: Int64
    var _expected_producers: List[Int64]
    var _lowest_live_epoch: Int64
    var _reap_every_n_rounds: Int
    var _rounds_since_reap: Int
    var _last_floor: Int64
    var _total_epochs_reaped: Int64
    var _total_objects_deleted: Int64
    var _reap_passes: Int64
    var _last_pass_reaped: Bool

    def __init__(
        out self,
        var store: Self.S,
        shuffle_id: Int64,
        var expected_producers: List[Int64],
        reap_every_n_rounds: Int = 1,
        start_lowest_live_epoch: Int64 = Int64(0),
    ):
        """Construct a per-cut retention policy.

        `store` is the durable shuffle store (cloned from the same backing the
        sink / read source use); `shuffle_id` is the cut's namespace;
        `expected_producers` is the plan-fixed producer set; `reap_every_n_rounds` is the cadence (1 ==
        every round — the test default; >1 amortizes the LIST/DELETE cost);
        `start_lowest_live_epoch` is the lower bound of still-live epochs (0 on a
        fresh job, or a recovered value on restart)."""
        self._store = store^
        self._shuffle_id = shuffle_id
        self._expected_producers = expected_producers^
        self._lowest_live_epoch = (
            start_lowest_live_epoch if start_lowest_live_epoch >= Int64(0)
            else Int64(0)
        )
        self._reap_every_n_rounds = (
            reap_every_n_rounds if reap_every_n_rounds > 0 else 1
        )
        self._rounds_since_reap = 0
        self._last_floor = Int64.MIN
        self._total_epochs_reaped = Int64(0)
        self._total_objects_deleted = Int64(0)
        self._reap_passes = Int64(0)
        self._last_pass_reaped = False

    # =========================================================================
    # The cadence-gated, fail-safe reap pass (driven BETWEEN rounds).
    # =========================================================================

    def maybe_reap(mut self, consumer_cursors: List[Int64]) raises -> Bool:
        """The driver calls this BETWEEN rounds (NEVER inside a segment's
        run_step) with the durable consumer cursors collected from every segment
        via `Segment.seg_consumer_cursor()`. Returns True iff the reaper actually
        ran this call.

        THE FAIL-SAFE GATES (in order):
          1. CADENCE — tick the counter; only proceed once every
             `_reap_every_n_rounds` calls. A cadence skip returns False (retain).
          2. NO CONSUMER PINS A FLOOR — if the cursor list is empty or every
             cursor is the `Int64.MAX` no-floor sentinel (no segment consumes a
             shuffle), the floor is `Int64.MAX`; we RETAIN everything (nothing
             to reclaim against). Returns False. `reclaim_floor` raises on an
             empty set, so an empty list is decided here and never reaches it.

        If the reaper raises, `lowest_live_epoch` and the cadence counter are
        left as they were, so the next call retries the pass.

        On a real floor: drive `reap_epochs_below(store, shuffle_id, floor,
        lowest_live_epoch, expected_producers)` — reaps `[lowest_live_epoch,
        floor)`, STRICTLY below the floor (an epoch AT the slowest consumer's
        cursor is RETAINED). Then PERSIST `lowest_live_epoch = floor` so the next
        pass skips the just-reaped epochs, and fold the stats into the
        observability counters. Idempotent + safe to re-run (the mechanism is
        delete-of-absent tolerant)."""
        # GATE 1 — cadence. Tick; bail unless this is a reap round.
        self._rounds_since_reap += 1
        self._last_pass_reaped = False
        if self._rounds_since_reap < self._reap_every_n_rounds:
            return False

        # GATE 2 — no consumer pins a floor (all sentinels / empty). Compute the
        # min directly so the all-MAX case is a clean RETAIN (and an empty set is
        # treated identically to "no floor" without leaning on the raise).
        var floor = self._min_cursor(consumer_cursors)
        if floor >= Int64.MAX:
            # No consumer pins a floor — RETAIN everything (fail-safe).
            self._rounds_since_reap = 0
            return False

        # The floor is a real consumer cursor. Take it from the mechanism's own
        # `reclaim_floor` so the min-across-consumers contract has one source.
        floor = reclaim_floor(consumer_cursors)

        # Nothing to reap below the floor yet — the lowest live epoch already
        # sits at or above it (a lagging consumer that has not advanced past the
        # last reap). Record the floor for observability + RETAIN.
        if self._lowest_live_epoch >= floor:
            self._last_floor = floor
            self._reap_passes += Int64(1)
            self._rounds_since_reap = 0
            return False

        # Drive the cross-epoch reaper: reap [lowest_live_epoch, floor), STRICTLY
        # below the floor. The mechanism resolves each epoch's producer set from
        # its durable seal (falling back to expected_producers), deletes the
        # whole per-epoch family, and is idempotent.
        var stats: ShuffleReapStats = reap_epochs_below(
            self._store,
            self._shuffle_id,
            floor,
            self._lowest_live_epoch,
            self._expected_producers,
        )

        # PERSIST the floor as the new lowest-live-epoch so successive passes
        # skip the just-reaped epochs. Fold the stats into the counters.
        self._rounds_since_reap = 0
        self._lowest_live_epoch = floor
        self._last_floor = floor
        self._total_epochs_reaped += stats.epochs_reaped
        self._total_objects_deleted += stats.objects_deleted
        self._reap_passes += Int64(1)
        self._last_pass_reaped = True
        return True

    @always_inline
    def _min_cursor(self, cursors: List[Int64]) -> Int64:
        """The MIN cursor across the list, or `Int64.MAX` for an empty list (the
        no-floor sentinel). Raise-free, so GATE 2 can decide RETAIN without
        `reclaim_floor`'s raise on an empty set."""
        var m = Int64.MAX
        for i in range(len(cursors)):
            if cursors[i] < m:
                m = cursors[i]
        return m

    # =========================================================================
    # Observability
    # =========================================================================

    @always_inline
    def lowest_live_epoch(self) -> Int64:
        """The persisted lower bound of still-live epochs (advanced to the floor
        after each reap)."""
        return self._lowest_live_epoch

    @always_inline
    def last_floor(self) -> Int64:
        """The most recent reclaim floor used (or `Int64.MIN` if no reap ran)."""
        return self._last_floor

    @always_inline
    def total_epochs_reaped(self) -> Int64:
        """Cumulative whole epochs reclaimed across every reap pass."""
        return self._total_epochs_reaped

    @always_inline
    def total_objects_deleted(self) -> Int64:
        """Cumulative DELETE calls issued."""
        return self._total_objects_deleted

    @always_inline
    def reap_passes(self) -> Int64:
        """Passes that reached a real floor, whether or not anything was below
        it (cadence skips and no-floor retains do not count)."""
        return self._reap_passes

    @always_inline
    def last_pass_reaped(self) -> Bool:
        """Whether the last `maybe_reap` actually reaped."""
        return self._last_pass_reaped

    def observability(self) -> RetentionObservability:
        """A snapshot of the cumulative retention work."""
        return RetentionObservability(
            self._last_floor,
            self._lowest_live_epoch,
            self._total_epochs_reaped,
            self._total_objects_deleted,
            self._reap_passes,
            self._last_pass_reaped,
        )
