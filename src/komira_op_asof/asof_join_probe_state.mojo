# =============================================================================
# asof_join_probe_state -- `AsofJoinProbeState`, the breaker state of a
# stage's ASOF_JOIN arm: it probes a built `AsofJoinBuildTable` with each
# probe batch and emits that batch's joined rows
# =============================================================================
#
# Not an accumulate-then-drain state: `probe_asof_batch` emits per input
# batch (`feed_row` does nothing and the drain is None). The state owns the
# table (moved in from the build side) and only reads it.
#
# The match is FORWARD and INNER (DuckDB `ASOF JOIN ... ON probe.t <=
# build.t`): each probe row takes the first build row whose temporal key is at
# or after its own (`asof_probe_forward_0`); a probe row without one, and a
# probe row whose temporal key is NULL, emits nothing.
#
# Output of `probe_asof_batch`, one row per matched probe row, in input order:
#   - `atemp`: the probe's temporal key, at `TempK`;
#   - `p0`, `p1`, ...: every build payload at its own type, nullable, NULL
#     where the build payload is NULL.
# None when no probe row matched.
#
# Scope: a table without equi keys (`AsofKeyBundle0`).
#
# The batch is assembled as a `RecordBatch`, lifted into a `ColumnNativeBatch`
# and bridged back (komira_engine_runtime's column-native shims); the round
# trip is byte-identical.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column_native import ColumnNativeBatch
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_expr.stage_program import BREAKER_ASOF_JOIN
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from komira_op_asof.asof_join_build import (
    AsofJoinBuildTable,
    AsofKeyBundle,
    PayloadColumn,
    primitive_with_nulls,
)


struct AsofJoinProbeState[
    probe_temp_col: Int,
    KB: AsofKeyBundle,
    TempK: DType,
    *Payload: PayloadColumn,
](Movable, BreakerStateCombinable):
    """The ASOF_JOIN breaker state over a built `AsofJoinBuildTable[KB,
    TempK, *Payload]`.

    Parameters:
        probe_temp_col: The probe-batch column of the temporal key.
        KB: The equi-key block (`AsofKeyBundle0`).
        TempK: The temporal key's DType.
        Payload: The payload columns of the table.
    """

    var build: AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload]

    def __init__(
        out self,
        var build: AsofJoinBuildTable[Self.KB, Self.TempK, *Self.Payload],
    ):
        """A state over a built table (taken by move)."""
        self.build = build^

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_ASOF_JOIN

    @staticmethod
    @always_inline
    def payload_arity() -> Int:
        """The number of payload columns emitted after `atemp`."""
        return Self.Payload.__len__()

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Nothing: the probe emits per batch through `probe_asof_batch`."""
        pass

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """None: the probe has no terminal drain."""
        return None

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("AsofJoinProbeState.probe_batch: use probe_asof_batch")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """The joined rows of `batch` (see the module header), or None when no
        probe row matched."""
        comptime assert Self.KB.ARITY == 0, (
            "AsofJoinProbeState.probe_asof_batch: a table without equi keys"
            " (AsofKeyBundle0)"
        )
        var n = batch.n_rows()
        var out_temp = List[Scalar[Self.TempK]]()
        var out_valid = List[Bool]()
        var out_slots = List[Int]()
        for row in range(n):
            if batch.col_is_null(Self.probe_temp_col, row):
                continue
            var probe_temp = batch.col_scalar[Self.TempK](
                Self.probe_temp_col, row
            )
            var slot = self.build.probe_binary(probe_temp)
            if slot >= 0:
                out_temp.append(probe_temp)
                out_valid.append(True)
                out_slots.append(slot)
        if len(out_slots) == 0:
            return None

        comptime n_pay = Self.Payload.__len__()
        var sb = SchemaBuilder()
        sb.add_field(
            Field(String("atemp"), ArrowType.from_dtype(Self.TempK), False)
        )
        comptime for p in range(n_pay):
            sb.add_field(
                Field(
                    String("p", p),
                    ArrowType.from_dtype(Self.Payload[p].DT),
                    True,
                )
            )
        var schema = sb.build()

        var rbb = RecordBatchBuilder.with_capacity(1 + n_pay)
        rbb.add_column(primitive_with_nulls[Self.TempK](out_temp^, out_valid))
        comptime for p in range(n_pay):
            rbb.add_column(self.build.payload[p].gather_column(out_slots))
        var built = rbb.build(schema^)

        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def combine(mut self, var other: Self) raises:
        """Raises: a probe state has nothing to merge (each worker emits its
        own batches against the shared table)."""
        raise Error(
            "AsofJoinProbeState.combine: an ASOF_JOIN probe state is not"
            " merged across workers"
        )
