# =============================================================================
# op_unnest -- OP_UNNEST: one output row per element of a LIST column
# =============================================================================
#
# `UnnestShared` checks the spec (an OP_UNNEST naming a column) and makes one
# `UnnestOp` per worker. The operator finds the column by name in each morsel's
# schema, which must hold a LIST of one flat child, and replaces it IN PLACE
# (same position, same name) by an element column; every other column is
# repeated once per output row of its input row. Per input row, in input order:
#
#   a list of n > 0 elements   n rows, the elements in list order (a NULL
#                              element stays NULL);
#   an empty or NULL list      no row, or with `keep_empty` one row whose
#                              element is NULL.
#
# The element field is nullable when the list's child is nullable or when
# `keep_empty` can put a NULL there (`unnest_output_schema`).
#
# The output is emitted in chunks of whole input rows, about `UNNEST_CHUNK_ROWS`
# output rows each (one input row whose list is longer makes a chunk of its own
# size). A morsel with a selection mask is gathered first. The first call takes
# the dense morsel into the operator; each call gives one chunk back as the
# morsel's batch with HAVE_MORE_OUTPUT, and the call that gives the last input
# row's rows returns NEED_MORE_INPUT. A morsel with no row, or whose lists give
# no output row, is dropped (FILTERED_EMPTY).

from std.builtin.swap import swap

from arrow.arrow_types import ArrowType
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from column_kernels.compiler_helpers import materialize_selection_if_present
from exec_types.exec_result import (
    ExecResult,
    FILTERED_EMPTY,
    HAVE_MORE_OUTPUT,
    NEED_MORE_INPUT,
)
from join_assembly.compiler_join_assembly import emit_gather_column_projected
from morsel.morsel import Morsel
from morsel.morsel_operator import MorselOperatorImpl
from physical_plan.physical_plan import MorselOp, OP_UNNEST


comptime UNNEST_CHUNK_ROWS = 65536
"""The output rows after which a chunk of whole input rows ends."""


def _find_list_column(ref schema: Schema, column: String) raises -> Int:
    """The index of the LIST column `column` of `schema`; raises by name when
    there is no such column or it is not a LIST of one child."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == column:
            var field = schema.field_at(i)
            if field.arrow_type != ArrowType.LIST or field.num_children() != 1:
                raise Error("unnest: column '" + column + "' is not a list")
            return i
    raise Error("unnest: no column '" + column + "' in its input")


def unnest_output_schema(
    ref schema: Schema, column: String, keep_empty: Bool
) raises -> Schema:
    """The schema of the rows `UnnestOp` emits for input of `schema`: the
    fields of `schema` with `column` replaced in place by its element type,
    nullable when the list's child is or when `keep_empty` is set."""
    var at = _find_list_column(schema, column)
    var sb = SchemaBuilder()
    for c in range(schema.num_columns()):
        var field = schema.field_at(c)
        if c == at:
            sb.add_field(
                Field(
                    column,
                    field.child_arrow_type(0),
                    field.child_nullable(0) or keep_empty,
                )
            )
        else:
            sb.add_field(field^)
    return sb.build()


struct UnnestShared(Movable):
    """What the per-worker unnests of one operator share: the column and the
    keep-empty flag."""

    var column: String
    var keep_empty: Bool

    def __init__(out self, ref spec: MorselOp) raises:
        if spec.tag != OP_UNNEST:
            raise Error(
                "pipeline_exec: an OP_UNNEST spec is expected, got operator"
                " tag "
                + String(Int(spec.tag))
            )
        if spec.unnest_column == "":
            raise Error("pipeline_exec: an OP_UNNEST names no column")
        self.column = spec.unnest_column
        self.keep_empty = spec.unnest_keep_empty

    def output_schema(self, ref schema: Schema) raises -> Schema:
        """The schema of the rows this operator emits for input of `schema`."""
        return unnest_output_schema(schema, self.column, self.keep_empty)

    def make(self) -> UnnestOp:
        """An unnest for one worker."""
        return UnnestOp(self.column, self.keep_empty)


struct UnnestOp(MorselOperatorImpl):
    """One worker's unnest; see the module header."""

    var _column: String
    var _keep_empty: Bool
    # The morsel being emitted in chunks, the index of its list column, the
    # list's elements as a one-column batch, the output schema, and the next
    # input row.
    var _pending: Optional[RecordBatch]
    var _at: Int
    var _elements: Optional[RecordBatch]
    var _out_schema: Optional[Schema]
    var _next_row: Int

    def __init__(out self, column: String, keep_empty: Bool):
        self._column = column
        self._keep_empty = keep_empty
        self._pending = None
        self._at = -1
        self._elements = None
        self._out_schema = None
        self._next_row = 0

    def _start(mut self, var held: RecordBatch) raises:
        """Take the dense input `held` and prepare to emit it."""
        self._at = _find_list_column(held.schema, self._column)
        self._out_schema = unnest_output_schema(
            held.schema, self._column, self._keep_empty
        )
        ref col = held.column_at(self._at)
        if col.arrow_type != ArrowType.LIST or col.num_children() != 1:
            raise Error("unnest: column '" + self._column + "' is not a list")
        var sb = SchemaBuilder()
        sb.add_field(
            Field(
                self._column,
                held.schema.field_at(self._at).child_arrow_type(0),
                True,
            )
        )
        var builder = RecordBatchBuilder()
        builder.add_column(col.child_at(0).share())
        self._elements = builder.build(sb.build())
        self._pending = Optional(held^)
        self._next_row = 0

    def _clear(mut self):
        self._pending = None
        self._elements = None
        self._out_schema = None
        self._at = -1
        self._next_row = 0

    def _emit_chunk(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Emit the next chunk with rows of the pending morsel into `morsel`:
        HAVE_MORE_OUTPUT while input rows are left, NEED_MORE_INPUT with the
        last chunk, FILTERED_EMPTY when no row is left to emit."""
        var n = self._pending.value().num_rows()
        var outer = List[Int]()
        var elem = List[Int]()
        var stop = self._next_row
        ref list_col = self._pending.value().column_at(self._at)
        ref offsets = list_col._offsets.value()
        var view = offsets.view_ro()
        while stop < n and (len(outer) == 0 or len(outer) < UNNEST_CHUNK_ROWS):
            var s = 0
            var e = 0
            if not list_col.is_null_at(stop):
                s = Int(view.get_typed[Int32](list_col._offset + stop))
                e = Int(view.get_typed[Int32](list_col._offset + stop + 1))
            if e > s:
                for k in range(s, e):
                    outer.append(stop)
                    elem.append(k)
            elif self._keep_empty:
                outer.append(stop)
                elem.append(-1)
            stop += 1
        self._next_row = stop
        var count = len(outer)
        if count == 0:
            self._clear()
            return ExecResult(FILTERED_EMPTY)
        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()
        ref held = self._pending.value()
        for c in range(held.num_columns()):
            if c == self._at:
                emit_gather_column_projected(
                    self._elements.value(),
                    0,
                    self._column,
                    self._keep_empty,
                    elem,
                    count,
                    builder,
                    sb,
                )
            else:
                emit_gather_column_projected(
                    held,
                    c,
                    held.schema.field_name(c),
                    False,
                    outer,
                    count,
                    builder,
                    sb,
                )
        var chunk = builder.build(self._out_schema.value().copy())
        morsel.replace_batch(chunk^)
        if stop < n:
            return ExecResult(HAVE_MORE_OUTPUT)
        self._clear()
        return ExecResult(NEED_MORE_INPUT)

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        if self._pending:
            return self._emit_chunk(morsel)
        if morsel.batch.has_selection_mask():
            var extracted = RecordBatch()
            swap(morsel.batch, extracted)
            morsel.replace_batch(materialize_selection_if_present(extracted^))
        if morsel.num_rows() == 0:
            return ExecResult(FILTERED_EMPTY)
        var held = RecordBatch()
        swap(morsel.batch, held)
        self._start(held^)
        return self._emit_chunk(morsel)
