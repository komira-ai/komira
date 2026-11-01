# =============================================================================
# join_probe_state -- `JoinProbeState`, the breaker state of a stage's
# JOIN_PROBE arm: it probes a built `JoinBuildTable` with each probe batch and
# emits the joined rows of that batch
# =============================================================================
#
# Not an accumulate-then-drain state: `probe_batch` emits per input batch
# (`feed_row` does nothing and the drain is None). The state owns the table
# (moved in from the build side) and only reads it.
#
# Output of `probe_batch`, one row per (probe row, matching build row) pair,
# probe rows in input order, a probe row's matches in table order:
#   - `jkey`: probe key column 0 at its own type;
#   - `p0`, `p1`, ...: every build payload column at its own type (a STRING
#     payload as STRING), NULL where the build payload is NULL.
# With duplicate build keys every match is emitted (M:N); otherwise the first
# match is the only one. A probe row with a NULL key matches nothing.
#
# The join type comes from the stage's probe spec (`join_t`):
#   - INNER (any `join_t` but `JOIN_LEFT`): a probe row without a match emits
#     nothing.
#   - LEFT (`JOIN_LEFT`): a probe row without a match (a NULL-key row
#     included) emits one row: its probe key (NULL if it is NULL) and NULL in
#     every payload column.
# `jkey` is nullable for LEFT only; payload columns are always nullable. A
# validity bitmap is attached only to a column that holds a NULL.
#
# The batch is assembled as a `RecordBatch`, lifted into a `ColumnNativeBatch`
# and bridged back (komira_engine_runtime's column-native shims); the round
# trip is byte-identical.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.column_native import ColumnNativeBatch
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_expr.stage_program import BREAKER_JOIN_PROBE, JOIN_LEFT
from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)

from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_key_bundle import KeyBundle
from komira_op_join_stage.join_key_slot import key_from_bits
from komira_op_join_stage.join_payload_column import PayloadColumn


def _primitive_with_nulls[
    dt: DType
](var values: List[Scalar[dt]], valid: List[Bool]) raises -> Column[HeapRegion]:
    """A primitive column of `values`, with a validity bitmap from `valid`
    when some entry is False."""
    var pa = PrimitiveArray[dt].from_list(values)
    var n = len(valid)
    var nulls = 0
    for i in range(n):
        if not valid[i]:
            nulls += 1
    if nulls > 0:
        var bm = Bitmap.create(n)
        for i in range(n):
            if valid[i]:
                bm.set(i)
        pa.validity = Optional[Bitmap[HeapRegion]](bm^)
        pa.null_count = nulls
    return Column.from_primitive[dt](pa^)


struct JoinProbeState[
    probe_col0: Int, probe_col1: Int, KB: KeyBundle, *Payload: PayloadColumn
](Movable, BreakerStateCombinable):
    """The JOIN_PROBE breaker state over a built `JoinBuildTable[KB,
    *Payload]`.

    Parameters:
        probe_col0: The probe-batch column of key column 0.
        probe_col1: The probe-batch column of key column 1 (ignored by a
            one-column key; pass -1). Keys of one or two columns only.
        KB: The key block of the table.
        Payload: The payload columns of the table.
    """

    var build: JoinBuildTable[Self.KB, *Self.Payload]

    def __init__(out self, var build: JoinBuildTable[Self.KB, *Self.Payload]):
        """A state over a built table (taken by move)."""
        self.build = build^

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_JOIN_PROBE

    @staticmethod
    @always_inline
    def payload_arity() -> Int:
        """The number of payload columns emitted after `jkey`."""
        return Self.Payload.__len__()

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Nothing: the probe emits per batch through `probe_batch`."""
        pass

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """None: the probe has no terminal drain."""
        return None

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """The joined rows of `batch` (see the module header), or None when
        there are none (an empty batch; for INNER also a batch without a
        match)."""
        comptime assert Self.KB.arity() <= 2, (
            "JoinProbeState: probes a one- or two-column key"
        )
        comptime is_left = join_t == JOIN_LEFT
        comptime KDT = Self.KB.key_dtype[0]()
        comptime assert KDT != DType.bool, (
            "JoinProbeState: a BOOL jkey column is not emitted"
        )
        var n = batch.n_rows()
        var has_dups = self.build.has_duplicate_keys

        # One output row per entry: the probe row and the build slot (-1 for
        # LEFT's unmatched row).
        var out_rows = List[Int]()
        var out_slots = List[Int]()
        var match_slots = List[Int]()
        for row in range(n):
            match_slots.clear()
            self.build.keys.probe_batch_row[
                bo, Self.probe_col0, Self.probe_col1, 0, 0
            ](batch, row, self.build.capacity_mask, has_dups, match_slots)
            if len(match_slots) > 0:
                for si in range(len(match_slots)):
                    out_rows.append(row)
                    out_slots.append(match_slots[si])
            else:
                comptime if is_left:
                    out_rows.append(row)
                    out_slots.append(-1)

        var n_out = len(out_rows)
        if n_out == 0:
            return None

        var sb = SchemaBuilder()
        sb.add_field(Field(String("jkey"), ArrowType.from_dtype(KDT), is_left))
        comptime for p in range(Self.Payload.__len__()):
            comptime if Self.Payload[p].IS_STRING:
                sb.add_field(Field(String("p", p), ArrowType.STRING, True))
            else:
                sb.add_field(
                    Field(
                        String("p", p),
                        ArrowType.from_dtype(Self.Payload[p].DT),
                        True,
                    )
                )
        var schema = sb.build()

        var rbb = RecordBatchBuilder.with_capacity(1 + Self.Payload.__len__())
        var keys = List[Scalar[KDT]](capacity=n_out)
        var key_valid = List[Bool](capacity=n_out)
        for i in range(n_out):
            var row = out_rows[i]
            if batch.col_is_null(Self.probe_col0, row):
                keys.append(Scalar[KDT](0))
                key_valid.append(False)
            else:
                keys.append(batch.col_scalar[KDT](Self.probe_col0, row))
                key_valid.append(True)
        rbb.add_column(_primitive_with_nulls[KDT](keys^, key_valid))
        comptime for p in range(Self.Payload.__len__()):
            rbb.add_column(self._payload_column[p](out_slots))
        var built = rbb.build(schema^)

        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def _payload_column[
        p: Int
    ](self, slots: List[Int]) raises -> Column[HeapRegion]:
        """Payload column `p` at each slot of `slots` (NULL for -1 and for a
        NULL payload)."""
        var n = len(slots)
        var valid = List[Bool](capacity=n)
        comptime if Self.Payload[p].IS_STRING:
            var values = List[String](capacity=n)
            for i in range(n):
                var s = slots[i]
                if s < 0 or self.build.payload_is_null[p](s):
                    values.append(String(""))
                    valid.append(False)
                else:
                    values.append(self.build.payload_str_at[p](s))
                    valid.append(True)
            return Column.from_string(
                StringArray.from_strings_with_validity(values, valid)
            )
        else:
            comptime DT = Self.Payload[p].DT
            comptime assert DT != DType.bool, (
                "JoinProbeState: a BOOL payload column is not emitted"
            )
            var values = List[Scalar[DT]](capacity=n)
            for i in range(n):
                var s = slots[i]
                if s < 0 or self.build.payload_is_null[p](s):
                    values.append(Scalar[DT](0))
                    valid.append(False)
                else:
                    values.append(
                        key_from_bits[DT](self.build.payload_bits_at[p](s))
                    )
                    valid.append(True)
            return _primitive_with_nulls[DT](values^, valid)

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        raise Error("JoinProbeState.probe_asof_batch: not an ASOF_JOIN state")

    def combine(mut self, var other: Self) raises:
        """Raises: a probe state has nothing to merge (each worker emits its
        own batches against the shared table)."""
        raise Error(
            "JoinProbeState.combine: a JOIN_PROBE state is not merged across"
            " workers"
        )
