# =============================================================================
# asof_join_sink -- `AsofJoinSink`, the ASOF left join over two materialised
# sides
# =============================================================================
#
# Batch ingest: the walker must see every right row of an equi-key group to
# pick each left row's best match, and both sides are sorted first, so both
# sides are taken whole. The left side arrives through `consume` (one or more
# batches), the right side as one batch at `materialize_with_right`, which
# sorts both sides on `(equi_keys..., asof)` (unless the plan says a side is
# already sorted), runs the walker and assembles the output.
#
# Output: every left column as it is, then every right column, made nullable
# and renamed `<name>_right` when a left column has its name. One row per left
# row (in the sorted left order); a left row without a match gets NULL in
# every right column. What matches is the walker's rule (asof_walker: NULL
# keys and NULL ASOF values match nothing; float keys in `sort_key_lt`
# order).
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_join_assembly.compiler_join_assembly import assemble_join_result
from komira_op_sort.sort_multi import sort_batch_by_keys
from komira_physical_plan.physical_plan import AsofJoinSinkData

from komira_op_asof.asof_walker import asof_merge_dispatch


def _col_idx_by_name(ref schema: Schema, name: String) raises -> Int:
    """The index of column `name`; raises when there is none."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return i
    raise Error("AsofJoinSink: column '" + name + "' not found in input schema")


def _names_to_indices(ref schema: Schema, names: List[String]) raises -> List[Int]:
    """The indices of `names`, in order."""
    var out = List[Int]()
    for i in range(len(names)):
        out.append(_col_idx_by_name(schema, names[i]))
    return out^


def _asof_output_schema(
    ref left_schema: Schema, ref right_schema: Schema
) raises -> Schema:
    """Left fields as they are, then right fields made nullable, renamed
    `<name>_right` on a collision with a left name. Field metadata (time
    zone, decimal precision and scale, dictionary index type) is kept."""
    var sb = SchemaBuilder()
    for i in range(left_schema.num_columns()):
        sb.add_field(left_schema.field_at(i))
    for i in range(right_schema.num_columns()):
        var rname = right_schema.field_name(i)
        var collision = False
        for j in range(left_schema.num_columns()):
            if left_schema.field_name(j) == rname:
                collision = True
                break
        var rf = right_schema.field_at(i)
        if collision:
            rf.name = rname + "_right"
        rf.nullable = True
        sb.add_field(rf^)
    return sb.build()


def _ascending(n: Int) -> List[Bool]:
    """`n` ascending sort directions."""
    var descs = List[Bool]()
    for _ in range(n):
        descs.append(False)
    return descs^


struct AsofJoinSink(Movable):
    """The ASOF left join of the batches `consume` takes (left) with the
    batch `materialize_with_right` takes (right). Built by
    `AsofJoinSink.new(AsofJoinSinkData(...))`; one worker."""

    var _spec: AsofJoinSinkData
    var _left_batches: Slab[RecordBatch]

    @staticmethod
    def new(var spec: AsofJoinSinkData) -> AsofJoinSink:
        """A sink over `spec`."""
        return AsofJoinSink(_spec=spec^, _left_batches=Slab[RecordBatch]())

    def __init__(
        out self,
        var _spec: AsofJoinSinkData,
        var _left_batches: Slab[RecordBatch],
    ):
        self._spec = _spec^
        self._left_batches = _left_batches^

    def consume(mut self, var batch: RecordBatch) raises:
        """Take one left batch (an empty one is dropped)."""
        if batch.num_rows() == 0:
            return
        self._left_batches.append(batch^)

    def combine(mut self) raises:
        """Nothing: one worker, nothing to merge."""
        pass

    def materialize(mut self) raises -> RecordBatch:
        """Raises: the ASOF join needs its right side; call
        `materialize_with_right`."""
        raise Error(
            "AsofJoinSink.materialize: the ASOF join needs its right side;"
            " call materialize_with_right(right_batch)"
        )

    def materialize_with_right(
        mut self, var right_batch: RecordBatch
    ) raises -> RecordBatch:
        """Sort both sides, walk them and assemble the joined batch (see the
        module header). No left rows: an empty batch."""
        var raw_left = self._left_batches^
        self._left_batches = Slab[RecordBatch]()
        if len(raw_left) == 0:
            return RecordBatch()
        var left = concat_record_batches_nway(raw_left^)

        # Sort a side on (equi_keys..., asof) unless the plan says it is
        # sorted (a non-empty `*_sort_keys`).
        if len(self._spec.left_sort_keys) == 0:
            var keys = self._spec.left_keys.copy()
            keys.append(self._spec.left_asof)
            left = sort_batch_by_keys(left^, keys, _ascending(len(keys)))
        if len(self._spec.right_sort_keys) == 0:
            var keys = self._spec.right_keys.copy()
            keys.append(self._spec.right_asof)
            right_batch = sort_batch_by_keys(
                right_batch^, keys, _ascending(len(keys))
            )

        var lk_idx = _names_to_indices(left.schema, self._spec.left_keys)
        var rk_idx = _names_to_indices(right_batch.schema, self._spec.right_keys)
        var la_idx = _col_idx_by_name(left.schema, self._spec.left_asof)
        var ra_idx = _col_idx_by_name(right_batch.schema, self._spec.right_asof)

        var left_batches = Slab[RecordBatch]()
        left_batches.append(left^)
        var right_batches = Slab[RecordBatch]()
        right_batches.append(right_batch^)

        var left_batch_out = List[Int]()
        var left_row_out = List[Int]()
        var right_batch_out = List[Int]()
        var right_row_out = List[Int]()
        asof_merge_dispatch(
            self._spec.strategy,
            self._spec.asof_dtype,
            left_batches,
            right_batches,
            lk_idx,
            rk_idx,
            la_idx,
            ra_idx,
            self._spec.tolerance,
            left_batch_out,
            left_row_out,
            right_batch_out,
            right_row_out,
        )

        # One left batch, so a left row index is its row; -1 on the right is
        # an unmatched left row (NULL right columns).
        var n_out = len(left_row_out)
        var left_indices = List[Int](capacity=n_out)
        var right_indices = List[Int](capacity=n_out)
        for i in range(n_out):
            left_indices.append(left_row_out[i])
            if right_batch_out[i] < 0:
                right_indices.append(-1)
            else:
                right_indices.append(right_row_out[i])

        var out_schema = _asof_output_schema(
            left_batches[0].schema, right_batches[0].schema
        )
        return assemble_join_result(
            left_batches[0],
            right_batches[0],
            left_indices,
            right_indices,
            out_schema^,
            left_nullable=False,
            right_nullable=True,
        )

    def free(mut self):
        """Nothing to free: the storage is dropped with the sink."""
        pass
