# =============================================================================
# count_star_op.mojo — COUNT(*), the op that counts rows rather than values
# =============================================================================
#
# `CountOp[dt]` is COUNT(col): `HashAggOpAgg` asks `input_is_null` first and
# feeds it only the rows whose input column is not NULL. COUNT(*) counts every
# row, NULL or not, so it is its own op: `COUNTS_ROWS` makes
# `HashAggOpAgg.input_is_null` answer False without reading the column, and
# `NEEDS_VALUE = False` keeps the band fold from reading it. The bound `col` is
# a placeholder. A group always holds at least one row, so the count of a group
# is never 0 except for the one row of an ungrouped aggregate over no input,
# where DuckDB answers 0 (`EMPTY_IS_NULL = False`).
# =============================================================================

from komira_agg.hash_agg_op_dt import HashAggOpDt


struct CountStarOp[dt: DType](HashAggOpDt):
    """COUNT(*): counts every row fed. Identity 0, state and output INT64."""

    comptime DT: DType = Self.dt
    comptime OUT_DT: DType = DType.int64
    comptime NEEDS_VALUE: Bool = False
    comptime COUNTS_ROWS: Bool = True
    comptime EMPTY_IS_NULL: Bool = False
    comptime StateTy = Scalar[DType.int64]

    @staticmethod
    @always_inline
    def init() -> Scalar[DType.int64]:
        return Scalar[DType.int64](0)

    @staticmethod
    @always_inline
    def update_scalar(mut state: Scalar[DType.int64], value: Scalar[Self.dt]):
        state = state + 1

    @staticmethod
    @always_inline
    def finalize(state: Scalar[DType.int64]) -> Scalar[Self.OUT_DT]:
        return state

    @staticmethod
    @always_inline
    def combine(mut state: Scalar[DType.int64], partial: Scalar[DType.int64]):
        state = state + partial
