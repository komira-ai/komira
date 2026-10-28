# =============================================================================
# op_filter -- OP_FILTER over the selection mask
# =============================================================================
#
# `FilterOp` evaluates a predicate over a morsel's batch and, instead of
# gathering the survivors, records them as the batch's deferred selection mask
# (`RecordBatch.set_selection_mask`). The operators after it honour the mask: a
# projection evaluates under it (`MapOp`), a limit counts the selected rows,
# and the collect sink gathers once. No second selection representation is
# added to `Morsel`.
#
#   * All rows pass: the batch is left without a mask.
#   * No row passes: FILTERED_EMPTY, and the driver drops the morsel.
#   * Otherwise the mask holds one bit per physical row.
#
# Three-valued logic is the evaluator's (`evaluate_filter_narrowed`): a row
# whose predicate is UNKNOWN (a NULL operand) is dropped, and `TRUE OR NULL`
# is kept.
#
# A batch that arrives with a mask of its own (a scan that deferred its decode
# filter) is gathered first: the predicate must not be evaluated over a row an
# earlier filter already rejected, because a predicate can raise on a row's
# value.
#
# A predicate whose NULL scope the evaluator cannot derive
# (`predicate_null_scope_unhandled_tag`) is refused by name on the first batch,
# because the fallback would drop rows over a NULL in an unrelated column.

from std.builtin.swap import swap
from std.memory import ArcPointer

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.schema import RecordBatch
from komira_batch_eval.conjunction import evaluate_filter_narrowed
from komira_batch_eval.predicate_null_scope import (
    predicate_null_scope_refusal,
    predicate_null_scope_unhandled_tag,
)
from komira_column_kernels.compiler_helpers import (
    materialize_selection_if_present,
)
from komira_exec_types.exec_result import (
    ExecResult,
    FILTERED_EMPTY,
    NEED_MORE_INPUT,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_physical_plan.physical_plan import MorselOp, OP_FILTER
from komira_plan_expr.expr import Expr


struct FilterShared(Movable):
    """What the per-worker filters of one operator share: the predicate, owned
    once."""

    var _predicate: ArcPointer[Expr]

    def __init__(out self, ref spec: MorselOp) raises:
        if spec.tag != OP_FILTER or not spec.filter_predicate:
            raise Error(
                "komira_pipeline_exec: an OP_FILTER carries no predicate"
            )
        self._predicate = ArcPointer[Expr](spec.filter_predicate.value().copy())

    def make(self) -> FilterOp:
        """A filter for one worker."""
        return FilterOp(ArcPointer(copy=self._predicate))


struct FilterOp(MorselOperatorImpl):
    """Narrows a morsel to the rows its predicate keeps, as a selection mask."""

    var _predicate: ArcPointer[Expr]
    var _scope_checked: Bool

    def __init__(out self, var predicate: ArcPointer[Expr]):
        self._predicate = predicate^
        self._scope_checked = False

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        if morsel.batch.has_selection_mask():
            var extracted = RecordBatch()
            swap(morsel.batch, extracted)
            morsel.replace_batch(materialize_selection_if_present(extracted^))
        var rows = morsel.num_rows()
        if rows == 0:
            return ExecResult(FILTERED_EMPTY)
        if not self._scope_checked:
            var tag = predicate_null_scope_unhandled_tag(
                self._predicate[], morsel.batch.schema
            )
            if tag >= 0:
                raise Error(
                    "komira_pipeline_exec: OP_FILTER refuses its predicate: "
                    + predicate_null_scope_refusal(tag)
                )
            self._scope_checked = True
        var kept = evaluate_filter_narrowed(morsel.batch, self._predicate[])
        var n_kept = kept.length()
        if n_kept == 0:
            return ExecResult(FILTERED_EMPTY)
        if n_kept == rows:
            return ExecResult(NEED_MORE_INPUT)
        var mask = BooleanArray.allocate(rows)
        for i in range(n_kept):
            mask.set(
                Int(kept.indices.get_typed[Scalar[DType.int32]](i)), True
            )
        morsel.batch.set_selection_mask(mask^)
        return ExecResult(NEED_MORE_INPUT)
