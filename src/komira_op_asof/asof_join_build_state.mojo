# =============================================================================
# asof_join_build_state -- `AsofJoinBuildState`, the breaker state of a
# stage's ASOF_JOIN_BUILD arm: it accumulates the build side into an
# `AsofJoinBuildTable` and hands the table to the probe side
# =============================================================================
#
# A true pipeline breaker: `feed_row` appends each build row, the drain emits
# nothing (`drain_to_record_batch` is None), and `take_asof_build_table` moves
# the table out, once, for the probe (`AsofJoinProbeState`). The state holds
# the table as `Optional[OwnedPointer[...]]`, single owner; the handoff is a
# move.
#
# Scope: a table without equi keys (`AsofKeyBundle0`). Input layout of a build
# batch: the temporal key at `temp_col`, then payload `p` at `temp_col + 1 +
# p`. Rows arrive in ascending temporal order (a sort upstream is the
# contract; this state does not sort).
#
# A row whose temporal key is NULL is not stored (it matches nothing). Every
# payload is stored at its own type with its NULL.
#
# `combine` raises: the table is handed off whole, and a merge of two sorted
# tables across workers is not implemented.
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.batch_view import BatchView
from komira_arrow.schema import RecordBatch
from komira_expr.stage_program import BREAKER_ASOF_JOIN_BUILD
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from komira_op_asof.asof_join_build import (
    AsofJoinBuildTable,
    AsofKeyBundle,
    PayloadColumn,
)


struct AsofJoinBuildState[
    temp_col: Int,
    n_pay: Int,
    KB: AsofKeyBundle,
    TempK: DType,
    *Payload: PayloadColumn,
](Movable, BreakerStateCombinable):
    """The ASOF_JOIN_BUILD breaker state over an `AsofJoinBuildTable[KB,
    TempK, *Payload]`.

    Parameters:
        temp_col: The build-batch column of the temporal key.
        n_pay: The number of payload columns (equal to the pack's length).
        KB: The equi-key block (`AsofKeyBundle0`).
        TempK: The temporal key's DType.
        Payload: The payload columns.
    """

    var build: Optional[
        OwnedPointer[AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload]]
    ]

    def __init__(
        out self,
        var build: AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload],
    ):
        """A state over an empty (or pre-sized) table, taken by move."""
        comptime assert Self.n_pay == Self.Payload.__len__(), (
            "AsofJoinBuildState: n_pay must equal the payload pack's length"
        )
        self.build = Optional[
            OwnedPointer[AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload]]
        ](
            OwnedPointer[
                AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload]
            ](build^)
        )

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_ASOF_JOIN_BUILD

    @staticmethod
    @always_inline
    def payload_arity() -> Int:
        """The number of payload columns."""
        return Self.Payload.__len__()

    @staticmethod
    @always_inline
    def _pay_col(p: Int) -> Int:
        """The build-batch column of payload `p`."""
        return Self.temp_col + 1 + p

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Append build row `row`: its temporal key and its payloads (see the
        module header). A NULL temporal key: the row is not stored."""
        comptime assert Self.KB.ARITY == 0, (
            "AsofJoinBuildState.feed_row: a table without equi keys"
            " (AsofKeyBundle0)"
        )
        if not self.build:
            raise Error(
                "AsofJoinBuildState.feed_row: the table was already taken"
            )
        if batch.col_is_null(Self.temp_col, row):
            return
        ref table = self.build.value()[]
        table._append_temporal(batch.col_scalar[Self.TempK](Self.temp_col, row))
        comptime for p in range(Self.Payload.__len__()):
            table.payload[p].append_from_batch(batch, Self._pay_col(p), row)

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """None: the build emits nothing; the table leaves through
        `take_asof_build_table`."""
        return None

    def take_asof_build_table(
        mut self,
    ) raises -> OwnedPointer[
        AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload]
    ]:
        """Move the table out for the probe side. Raises on a second take."""
        if not self.build:
            raise Error(
                "AsofJoinBuildState.take_asof_build_table: the table was"
                " already taken"
            )
        return self.build.take()

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("AsofJoinBuildState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error(
            "AsofJoinBuildState.probe_asof_batch: not an ASOF_JOIN probe state"
        )

    def combine(mut self, var other: Self) raises:
        """Raises: the build table is handed off whole, not merged across
        workers."""
        raise Error(
            "AsofJoinBuildState.combine: the ASOF build table is not merged"
            " across workers"
        )
