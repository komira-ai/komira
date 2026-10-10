# =============================================================================
# row_evaluator.mojo — row-native comptime boolean predicate
# =============================================================================
#
# The Row-layer filter arm of the four-quadrant engine architecture: the
# comptime-monomorphized boolean predicate that runs
# directly over a `RowBlock`'s packed fixed cells — the row-native mirror of
# the column-format `Predicate.eval[W]` fan-out.
#
# Shape:
#   `RowExprBoolEvaluator[PRED_OP, COL_OFFSET, DT, LIT]` — a zero-field
#   comptime carrier. `.make()` constructs it; `eval_batch(rb, n_rows, mask)`
#   walks the block and sets `mask[row]` from
#   `rb.read_fixed[DT](row, COL_OFFSET) <op> LIT`. All of PRED_OP /
#   COL_OFFSET / DT / LIT are comptime parameters, so the comparison folds to
#   a single monomorphic branch-free predicate per row (the per-row dispatch
#   ladder evaporates at comptime).
#
# Encapsulation invariants:
#   * ZERO UnsafePointer in any public signature (cell reads route through
#     `RowBlock.read_fixed[DT]`, which encapsulates the pointer arithmetic).
#   * ZERO wildcard origin.
#   * ZERO unsafe_from_address / ArcPointer / take_pointee.
#   * Struct-parameter access is qualified `Self.X` in every body position
#     (every comptime param below is `Self.PRED_OP` / `Self.COL_OFFSET` /
#     `Self.DT` / `Self.LIT`).
#
# References:
#   * RowBlock.read_fixed[DT]: `row_block.mojo`.
#   * Column-format predicate fan-out precedent: `predicate.mojo`.
# =============================================================================

from komira_row_format.row_block import RowBlock


# -----------------------------------------------------------------------------
# Predicate-op constants (the comptime PRED_OP domain)
# -----------------------------------------------------------------------------
# Discriminates the comparison the evaluator applies. Kept as `UInt8` value
# constants so the comptime `@parameter if` ladder in `eval_batch` folds to a
# single branch per monomorphization. Adding a new op (e.g. GE / LT / NE) is a
# 1-line addition here + 1 arm in the comptime ladder.
# -----------------------------------------------------------------------------

comptime ROW_PRED_GT: UInt8 = 1
"""`col <op> lit` is `col > lit`."""

comptime ROW_PRED_LE: UInt8 = 2
"""`col <op> lit` is `col <= lit`."""

comptime ROW_PRED_EQ: UInt8 = 3
"""`col <op> lit` is `col == lit`."""

comptime ROW_PRED_LT: UInt8 = 4
"""`col <op> lit` is `col < lit`."""

comptime ROW_PRED_GE: UInt8 = 5
"""`col <op> lit` is `col >= lit`."""

comptime ROW_PRED_NE: UInt8 = 6
"""`col <op> lit` is `col != lit`."""


# =============================================================================
# RowExprBoolEvaluator — comptime-monomorphized row-native predicate
# =============================================================================


struct RowExprBoolEvaluator[
    PRED_OP: UInt8,
    COL_OFFSET: Int,
    DT: DType,
    LIT: Scalar[DT],
](Movable, Deinitable):
    """Row-native comptime boolean predicate over a `RowBlock`.

    Zero-field comptime carrier. Every axis of the comparison is a comptime
    parameter:
        PRED_OP    — ROW_PRED_GT / ROW_PRED_LE / ROW_PRED_EQ / ...
        COL_OFFSET — byte offset of the compared cell within each row.
        DT         — the cell DType.
        LIT        — the comptime literal compared against (typed `Scalar[DT]`).

    `eval_batch` reads `rb.read_fixed[DT](row, COL_OFFSET)` per row and folds
    the comptime `PRED_OP` ladder to one monomorphic branch-free predicate.

    The struct is `Movable & Deinitable` (it owns no heap; the
    conformances are required only so callers may move / store it).
    """

    def __init__(out self):
        """Empty ctor — the evaluator carries no runtime state."""
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        """Construct the (stateless) evaluator. Mirrors the `.make()` ctor
        convention used across the row-format substrate."""
        return Self()

    @always_inline
    def eval_one(self, value: Scalar[Self.DT]) -> Bool:
        """Apply the comptime predicate to a single cell value.

        The `@parameter if` ladder selects exactly one arm at comptime
        (PRED_OP is comptime), so this folds to a single comparison with no
        runtime branch on the op tag.
        """
        comptime if Self.PRED_OP == ROW_PRED_GT:
            return value > Self.LIT
        elif Self.PRED_OP == ROW_PRED_LE:
            return value <= Self.LIT
        elif Self.PRED_OP == ROW_PRED_EQ:
            return value == Self.LIT
        elif Self.PRED_OP == ROW_PRED_LT:
            return value < Self.LIT
        elif Self.PRED_OP == ROW_PRED_GE:
            return value >= Self.LIT
        elif Self.PRED_OP == ROW_PRED_NE:
            return value != Self.LIT
        else:
            # Unknown op tag — comptime-unreachable for the declared set.
            return False

    def eval_batch(self, rb: RowBlock, n_rows: Int, mut mask: List[Bool]):
        """Evaluate the predicate over rows `[0, n_rows)` of `rb`, writing
        the boolean outcome into `mask[row]`.

        Caller invariant: `len(mask) >= n_rows` (the test pre-fills `mask`
        with `n_rows` Falses). The cell read routes through
        `RowBlock.read_fixed[DT]` — no raw pointer crosses this boundary.

        Args:
            rb: The source row block (packed fixed cells).
            n_rows: Number of rows to evaluate.
            mask: Output selection mask; `mask[row]` set per row.
        """
        for row in range(n_rows):
            var v = rb.read_fixed[Self.DT](row, Self.COL_OFFSET)
            mask[row] = self.eval_one(v)


# =============================================================================
# selected_row_indices — mask -> surviving row indices
# =============================================================================


def selected_row_indices(mask: List[Bool], n: Int) -> List[Int]:
    """Collect the indices `i < n` with `mask[i]` set.

    Companion to `RowExprBoolEvaluator.eval_batch`: turns a boolean
    selection mask into the dense list of surviving row indices (the input
    to a row-format gather / project pass).

    Args:
        mask: Selection mask (`mask[i]` True iff row `i` survives).
        n: Number of mask entries to scan (`<= len(mask)`).

    Returns:
        A dense `List[Int]` of surviving indices, in ascending order.
    """
    var out = List[Int]()
    for i in range(n):
        if mask[i]:
            out.append(i)
    return out^
