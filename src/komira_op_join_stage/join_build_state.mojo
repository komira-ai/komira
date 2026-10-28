# =============================================================================
# join_build_state -- `JoinBuildState`, the breaker state of a stage's
# JOIN_BUILD arm: it accumulates the build side into a `JoinBuildTable` and
# hands the table to the probe side
# =============================================================================
#
# A true pipeline breaker: `feed_row` inserts each build row, the drain emits
# nothing (`drain_to_record_batch` is None), and `take_join_build_table` moves
# the populated table out, once, for the probe (`JoinProbeState`). The state
# holds the table as `Optional[OwnedPointer[...]]`, single owner; the handoff
# is a move (build state, then whoever carries it, then the probe state).
#
# Input layout of a build batch: key column 0 at `key_col0`, key column 1 at
# `key_col1` (two-or-more-column keys), key columns 2 and 3 at input columns 2
# and 3, then the payload columns: payload `p` at input column
# `KB.arity() + p`.
#
# A build row with a NULL in any key column is not inserted (a NULL key
# matches nothing). Every payload is stored at its own type with its NULL
# (`PayloadColumn.write_slot_from_batch`), so an INT64 payload keeps all 64
# bits and a NULL payload stays NULL.
#
# Parallel builds: each worker fills its own state and the driver folds them
# with `combine` before the handoff; the merged table probes the same as one
# built from all rows (`JoinBuildTable.combine`).
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.batch_view import BatchView
from komira_arrow.schema import RecordBatch
from komira_expr.stage_program import BREAKER_JOIN_BUILD
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_key_bundle import KeyBundle
from komira_op_join_stage.join_payload_column import PayloadColumn


struct JoinBuildState[
    key_col0: Int,
    key_col1: Int,
    n_pay: Int,
    KB: KeyBundle,
    *Payload: PayloadColumn,
](Movable, BreakerStateCombinable):
    """The JOIN_BUILD breaker state over a `JoinBuildTable[KB, *Payload]`.

    Parameters:
        key_col0: The input column of key column 0.
        key_col1: The input column of key column 1 (ignored by a one-column
            key; pass -1).
        n_pay: How many payload columns `feed_row` fills (the first `n_pay`
            of the pack; at most the pack's length).
        KB: The key block (`KeyBundle1[...]`..`KeyBundle4[...]`).
        Payload: The payload columns.
    """

    var build: Optional[OwnedPointer[JoinBuildTable[Self.KB, *Self.Payload]]]

    def __init__(out self, var build: JoinBuildTable[Self.KB, *Self.Payload]):
        """A state over `build` (empty or pre-sized)."""
        self.build = Optional[
            OwnedPointer[JoinBuildTable[Self.KB, *Self.Payload]]
        ](OwnedPointer[JoinBuildTable[Self.KB, *Self.Payload]](build^))

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_JOIN_BUILD

    @staticmethod
    @always_inline
    def payload_arity() -> Int:
        """The number of payload columns of the table."""
        return Self.Payload.__len__()

    @staticmethod
    @always_inline
    def _pay_col(p: Int) -> Int:
        """The input column of payload column `p`."""
        return Self.KB.arity() + p

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Insert build row `row`: its key (skipped if any key column is NULL)
        and its first `n_pay` payload columns. Raises once the table was
        taken."""
        comptime assert Self.n_pay <= Self.Payload.__len__(), (
            "JoinBuildState: n_pay is more than the payload columns"
        )
        if not self.build:
            raise Error(
                "JoinBuildState.feed_row: the build table was already taken"
            )
        ref table = self.build.value()[]
        comptime n_key = Self.KB.arity()
        var key_is_null = batch.col_is_null(Self.key_col0, row)
        comptime if n_key >= 2:
            if batch.col_is_null(Self.key_col1, row):
                key_is_null = True
        comptime if n_key >= 3:
            if batch.col_is_null(2, row):
                key_is_null = True
        comptime if n_key >= 4:
            if batch.col_is_null(3, row):
                key_is_null = True
        if key_is_null:
            return

        table._maybe_grow()
        var saw_dup = False
        var slot = table.keys.build_insert_row[
            bo, Self.key_col0, Self.key_col1, 2, 3
        ](batch, row, table.n_used, table.capacity_mask, saw_dup)
        if saw_dup:
            table.has_duplicate_keys = True
        comptime for p in range(Self.n_pay):
            table.payload_write_from_batch[p, bo](
                slot, batch, Self._pay_col(p), row
            )

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """None: the build emits no batch; the table leaves through
        `take_join_build_table`."""
        return None

    def take_join_build_table(
        mut self,
    ) raises -> OwnedPointer[JoinBuildTable[Self.KB, *Self.Payload]]:
        """Move the table out (once). Raises if it was already taken."""
        if not self.build:
            raise Error(
                "JoinBuildState.take_join_build_table: the build table was"
                " already taken"
            )
        return self.build.take()

    def combine(mut self, var other: Self) raises:
        """Fold `other`'s table into this one (`JoinBuildTable.combine`).
        Raises if either table was already taken."""
        if not self.build:
            raise Error(
                "JoinBuildState.combine: this state's build table was already"
                " taken"
            )
        if not other.build:
            raise Error(
                "JoinBuildState.combine: the other state's build table was"
                " already taken"
            )
        var other_owned = other.build.take()
        var other_table = other_owned^.take()
        ref self_table = self.build.value()[]
        self_table.combine(other_table^)

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("JoinBuildState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("JoinBuildState.probe_asof_batch: not an ASOF_JOIN state")
