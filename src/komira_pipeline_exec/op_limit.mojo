# =============================================================================
# op_limit -- OP_LIMIT with one row budget shared by the workers
# =============================================================================
#
# The workers of a segment run their own `LimitOp`, and all of them draw on one
# `LimitBudget`: an atomic count of the rows that reached the limit. A morsel
# of `k` selected rows takes the count from `p` to `p + k`; the rows that fit
# under the limit go on and the rest are cut. An operator that finds the budget
# spent returns FINISHED with an empty morsel, so its worker stops claiming.
#
# Which rows survive a limit under several workers depends on which worker
# reached the budget first; with one worker they are the first rows in claim
# order. The count of rows that survive is exact in every case.
#
# A morsel with a selection mask counts its selected rows. It is gathered only
# when the limit cuts into it.

from std.builtin.swap import swap
from std.memory import ArcPointer

from komira_arrow.schema import RecordBatch
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_column_kernels.batch_slice import _slice_batch_first_n
from komira_column_kernels.compiler_helpers import (
    empty_batch_like,
    materialize_selection_if_present,
)
from komira_exec_types.exec_result import (
    ExecResult,
    FINISHED,
    NEED_MORE_INPUT,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_physical_plan.physical_plan import MorselOp, OP_LIMIT


struct LimitBudget(Movable):
    """The rows a limit has let through so far, behind a shared handle."""

    var _cell: ArcPointer[Slab[AtomicI64]]

    def __init__(out self):
        self._cell = ArcPointer[Slab[AtomicI64]](
            Slab[AtomicI64].create_prefilled(1)
        )

    def __init__(out self, *, shared_with: Self):
        self._cell = ArcPointer(copy=shared_with._cell)

    def share(self) -> LimitBudget:
        """Another handle on the same count."""
        return LimitBudget(shared_with=self)

    def take(self, rows: Int) -> Int:
        """Add `rows` to the count and return the count before."""
        return Int(self._cell[].get_mut_interior(0).fetch_add(Int64(rows)))

    def taken(self) -> Int:
        """The rows counted so far."""
        return Int(self._cell[].get_mut_interior(0).load())


struct LimitShared(Movable):
    """What the per-worker limits of one operator share: the row count and the
    budget."""

    var limit: Int
    var _budget: LimitBudget

    def __init__(out self, ref spec: MorselOp) raises:
        if spec.tag != OP_LIMIT or spec.limit_count < 0:
            raise Error(
                "komira_pipeline_exec: an OP_LIMIT needs a row count of zero"
                " or more, got "
                + String(spec.limit_count)
            )
        self.limit = spec.limit_count
        self._budget = LimitBudget()

    def make(self) -> LimitOp:
        """A limit for one worker."""
        return LimitOp(self.limit, self._budget.share())


struct LimitOp(MorselOperatorImpl):
    """Lets the first `limit` rows of the segment through."""

    var _limit: Int
    var _budget: LimitBudget

    def __init__(out self, limit: Int, var budget: LimitBudget):
        self._limit = limit
        self._budget = budget^

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        var selected = morsel.num_rows()
        if morsel.batch.has_selection_mask():
            selected = morsel.batch.selection_mask_true_count()
        if selected == 0:
            # Nothing to count; a spent budget still ends this worker's claims.
            if self._budget.taken() >= self._limit:
                return ExecResult(FINISHED)
            return ExecResult(NEED_MORE_INPUT)
        var before = self._budget.take(selected)
        if before >= self._limit:
            morsel.replace_batch(empty_batch_like(morsel.batch))
            return ExecResult(FINISHED)
        var room = self._limit - before
        if selected > room:
            var extracted = RecordBatch()
            swap(morsel.batch, extracted)
            var dense = materialize_selection_if_present(extracted^)
            morsel.replace_batch(_slice_batch_first_n(dense, room))
        if before + selected >= self._limit:
            return ExecResult(FINISHED)
        return ExecResult(NEED_MORE_INPUT)
