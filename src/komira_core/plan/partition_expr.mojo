# =============================================================================
# PartitionExpr -- window function expressions for PARTITION BY / OVER
# =============================================================================
#
# Describes a single partition function expression (row_number, rank, lag,
# running sum, ...) along with frame specs and default values for offset
# functions.
#
# Limitations:
#   - All column-referencing variants take a single column index/name.
#   - No expression arguments (column names only).
#
# PartitionExpr is a tagged union: `func` selects which aux fields matter.
# =============================================================================

from ..arrow.schema import Schema, Field
from ..arrow.arrow_types import ArrowType
from .scalar_value import ScalarValue
# `PartitionFrame` and the `FRAME_*` constants live in `partition_frame.mojo`
# — a ZERO-IMPORT leaf — because `expr.mojo` needs `PartitionFrame` and
# nothing else from this file, and this file's `partition_expr_output_field`
# drags `arrow.schema`'s large closure in behind it. This import is BOTH the
# in-scope import (the code below uses `PartitionFrame`) AND the FACADE
# re-export: `from .partition_expr import PartitionFrame` / `FRAME_UNITS_*` /
# `FRAME_BOUND_*` resolves. Same pattern `logical_plan.mojo` uses for the
# `*Data` structs it re-exports out of `logical_plan_variants.mojo`.
from .partition_frame import (
    PartitionFrame,
    FRAME_UNITS_ROWS,
    FRAME_UNITS_RANGE,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
)


# =============================================================================
# PartitionExpr function tags
# =============================================================================

# Ranking functions -- ignore frame spec
comptime PF_ROW_NUMBER: UInt8 = 0
comptime PF_RANK: UInt8 = 1
comptime PF_DENSE_RANK: UInt8 = 2
comptime PF_PERCENT_RANK: UInt8 = 3
comptime PF_CUME_DIST: UInt8 = 4
comptime PF_NTILE: UInt8 = 5

# Offset functions. LAG / LEAD ignore the frame spec (SQL). FIRST_VALUE /
# LAST_VALUE / NTH_VALUE READ it: their
# constructors carry SQL's ordered default, `PartitionFrame.running_range()`,
# and `partition_value_fns` resolves any ROWS / RANGE frame per row.
comptime PF_LAG: UInt8 = 10
comptime PF_LEAD: UInt8 = 11
comptime PF_FIRST_VALUE: UInt8 = 12
comptime PF_LAST_VALUE: UInt8 = 13
comptime PF_NTH_VALUE: UInt8 = 14

# Aggregate window functions -- use frame spec
comptime PF_SUM: UInt8 = 20
comptime PF_AVG: UInt8 = 21
comptime PF_COUNT: UInt8 = 22
comptime PF_MIN: UInt8 = 23
comptime PF_MAX: UInt8 = 24


# =============================================================================
# PartitionExpr -- the actual expression
# =============================================================================

def partition_fn_name(func: UInt8) -> String:
    """The window function's SQL name (`FUNC_<n>` for a tag with no name)."""
    if func == PF_ROW_NUMBER:
        return "ROW_NUMBER"
    elif func == PF_RANK:
        return "RANK"
    elif func == PF_DENSE_RANK:
        return "DENSE_RANK"
    elif func == PF_PERCENT_RANK:
        return "PERCENT_RANK"
    elif func == PF_CUME_DIST:
        return "CUME_DIST"
    elif func == PF_NTILE:
        return "NTILE"
    elif func == PF_LAG:
        return "LAG"
    elif func == PF_LEAD:
        return "LEAD"
    elif func == PF_FIRST_VALUE:
        return "FIRST_VALUE"
    elif func == PF_LAST_VALUE:
        return "LAST_VALUE"
    elif func == PF_NTH_VALUE:
        return "NTH_VALUE"
    elif func == PF_SUM:
        return "SUM"
    elif func == PF_AVG:
        return "AVG"
    elif func == PF_COUNT:
        return "COUNT"
    elif func == PF_MIN:
        return "MIN"
    elif func == PF_MAX:
        return "MAX"
    return "FUNC_" + String(Int(func))


struct PartitionExpr(Movable, Copyable, Writable):
    """A single partition function expression.

    Tagged union. `func` determines which auxiliary fields are meaningful.
    """
    var func: UInt8
    var column: String
    var offset: Int
    var default_value: ScalarValue
    var has_default: Bool
    var frame: PartitionFrame
    var alias_name: String

    def __init__(
        out self,
        func: UInt8,
        var column: String,
        offset: Int,
        var default_value: ScalarValue,
        has_default: Bool,
        var frame: PartitionFrame,
        var alias_name: String,
    ):
        self.func = func
        self.column = column^
        self.offset = offset
        self.default_value = default_value^
        self.has_default = has_default
        self.frame = frame^
        self.alias_name = alias_name^

    def copy(self) -> Self:
        return Self(
            self.func,
            self.column.copy(),
            self.offset,
            self.default_value.copy(),
            self.has_default,
            self.frame.copy(),
            self.alias_name.copy(),
        )

    # -------------------------------------------------------------------------
    # Factory methods
    # -------------------------------------------------------------------------

    @staticmethod
    def row_number() -> PartitionExpr:
        return PartitionExpr(
            PF_ROW_NUMBER, String(""), 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def rank() -> PartitionExpr:
        return PartitionExpr(
            PF_RANK, String(""), 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def dense_rank() -> PartitionExpr:
        return PartitionExpr(
            PF_DENSE_RANK, String(""), 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def percent_rank() -> PartitionExpr:
        return PartitionExpr(
            PF_PERCENT_RANK, String(""), 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def cume_dist() -> PartitionExpr:
        return PartitionExpr(
            PF_CUME_DIST, String(""), 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def ntile(num_buckets: Int) -> PartitionExpr:
        return PartitionExpr(
            PF_NTILE, String(""), num_buckets, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def lag(column: String, offset: Int = 1) -> PartitionExpr:
        return PartitionExpr(
            PF_LAG, column, offset, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def lag_default(column: String, offset: Int, var default_value: ScalarValue) -> PartitionExpr:
        return PartitionExpr(
            PF_LAG, column, offset, default_value^, True,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def lead(column: String, offset: Int = 1) -> PartitionExpr:
        return PartitionExpr(
            PF_LEAD, column, offset, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def lead_default(column: String, offset: Int, var default_value: ScalarValue) -> PartitionExpr:
        return PartitionExpr(
            PF_LEAD, column, offset, default_value^, True,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def first_value(column: String) -> PartitionExpr:
        """SQL `FIRST_VALUE(column)` under SQL's DEFAULT frame for an ordered
        window, `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`
        (`running_range()`; the whole partition when there is no ORDER BY).

        ⚠ FIRST_VALUE / LAST_VALUE / NTH_VALUE READ THEIR FRAME. Served over
        the WHOLE partition whatever the frame said, `LAST_VALUE(v) OVER
        (PARTITION BY g ORDER BY o)` would answer the partition's last row
        where DuckDB v1.5.3 answers the current row's last PEER. `.with_frame(...)` states
        any other frame, e.g. the whole partition as `ROWS BETWEEN UNBOUNDED
        PRECEDING AND UNBOUNDED FOLLOWING`.
        """
        return PartitionExpr(
            PF_FIRST_VALUE, column, 0, ScalarValue(), False,
            PartitionFrame.running_range(), String(""),
        )

    @staticmethod
    def last_value(column: String) -> PartitionExpr:
        return PartitionExpr(
            PF_LAST_VALUE, column, 0, ScalarValue(), False,
            PartitionFrame.running_range(), String(""),
        )

    @staticmethod
    def nth_value(column: String, n: Int) -> PartitionExpr:
        return PartitionExpr(
            PF_NTH_VALUE, column, n, ScalarValue(), False,
            PartitionFrame.running_range(), String(""),
        )

    @staticmethod
    def running_sum(column: String) -> PartitionExpr:
        return PartitionExpr(
            PF_SUM, column, 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def running_count(column: String = String("")) -> PartitionExpr:
        return PartitionExpr(
            PF_COUNT, column, 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def running_avg(column: String) -> PartitionExpr:
        return PartitionExpr(
            PF_AVG, column, 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def running_min(column: String) -> PartitionExpr:
        return PartitionExpr(
            PF_MIN, column, 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def running_max(column: String) -> PartitionExpr:
        return PartitionExpr(
            PF_MAX, column, 0, ScalarValue(), False,
            PartitionFrame.default_ordered(), String(""),
        )

    @staticmethod
    def agg_with_frame(func: UInt8, column: String, var frame: PartitionFrame) -> PartitionExpr:
        """Build an aggregate window function with a custom frame spec."""
        return PartitionExpr(
            func, column, 0, ScalarValue(), False, frame^, String(""),
        )

    # -------------------------------------------------------------------------
    # Chainable setters
    # -------------------------------------------------------------------------

    def with_alias(var self, var alias_name: String) -> PartitionExpr:
        self.alias_name = alias_name^
        return self^

    def with_frame(var self, var frame: PartitionFrame) -> PartitionExpr:
        self.frame = frame^
        return self^

    # -------------------------------------------------------------------------
    # Writable — the window function's FULL identity
    # -------------------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        """`RANK(<column>, offset=<n>[, default=<v>], frame=<f>)[ AS <alias>]`.

        ⛔ THIS IS PLAN IDENTITY, NOT DECORATION. `plan_display` renders a
        `PartitionBy` node's functions with it, and that render IS the
        plan-compile cache key (`LogicalPlan.structural_hash`). A render of
        only `<N> funcs` would let two windows in ONE `EngineContext` that
        differ only in the function (row_number vs rank), its column, offset,
        default, frame or alias share a compiled plan, and the second query
        would answer the FIRST one's values. Every field is
        emitted; a field added to this struct must be added here.
        """
        writer.write(partition_fn_name(self.func), "(", self.column)
        writer.write(", offset=", self.offset)
        if self.has_default:
            writer.write(", default=", self.default_value)
        writer.write(", frame=", self.frame, ")")
        if self.alias_name.byte_length() > 0:
            writer.write(" AS ", self.alias_name)

    # -------------------------------------------------------------------------
    # Classification helpers
    # -------------------------------------------------------------------------

    @always_inline
    def is_ranking(self) -> Bool:
        return self.func <= PF_NTILE

    @always_inline
    def is_offset(self) -> Bool:
        return self.func >= PF_LAG and self.func <= PF_NTH_VALUE

    @always_inline
    def is_aggregate(self) -> Bool:
        return self.func >= PF_SUM and self.func <= PF_MAX

    @always_inline
    def needs_full_partition(self) -> Bool:
        return (
            self.func == PF_PERCENT_RANK
            or self.func == PF_CUME_DIST
            or self.func == PF_NTILE
            or self.func == PF_LAST_VALUE
            or self.func == PF_NTH_VALUE
        )


def needs_full_partition(exprs: List[PartitionExpr]) -> Bool:
    for i in range(len(exprs)):
        if exprs[i].needs_full_partition():
            return True
    return False


def value_fn_has_default(expr: PartitionExpr) -> Bool:
    """True iff a LAG / LEAD carries a DEFAULT that answers the edge row.

    ⚠ A NULL default IS NO DEFAULT. `LAG(x, 1, NULL)` answers NULL at the edge
    exactly as `LAG(x, 1)` does (SQL, DuckDB v1.5.3), so both the kernel
    (`partition_value_fns`) and the output-field nullability below read THIS
    predicate rather than the bare `has_default` flag -- two readers of the
    flag disagreeing is how the schema would say "not nullable" over a column
    carrying edge NULLs.
    """
    if not expr.has_default:
        return False
    if expr.func != PF_LAG and expr.func != PF_LEAD:
        return False
    return not expr.default_value.is_null()


# =============================================================================
# Output type inference
# =============================================================================

def _value_fn_base_name(func: UInt8) -> String:
    """The `_w<i>_<base>` stem of an unaliased value-function column."""
    if func == PF_LAG:
        return String("lag")
    elif func == PF_LEAD:
        return String("lead")
    elif func == PF_FIRST_VALUE:
        return String("first_value")
    elif func == PF_LAST_VALUE:
        return String("last_value")
    return String("nth_value")


def partition_expr_output_field(
    expr: PartitionExpr,
    input_schema: Schema,
    expr_idx: Int,
) raises -> Field:
    """Determine output name, type, and nullability of a PartitionExpr.

    """
    var base_name: String
    var dt: ArrowType
    var nullable: Bool

    if expr.func == PF_ROW_NUMBER:
        base_name = "row_number"
        dt = ArrowType.INT64
        nullable = False
    elif expr.func == PF_RANK:
        base_name = "rank"
        dt = ArrowType.INT64
        nullable = False
    elif expr.func == PF_DENSE_RANK:
        base_name = "dense_rank"
        dt = ArrowType.INT64
        nullable = False
    elif expr.func == PF_PERCENT_RANK:
        base_name = "percent_rank"
        dt = ArrowType.FLOAT64
        nullable = False
    elif expr.func == PF_CUME_DIST:
        base_name = "cume_dist"
        dt = ArrowType.FLOAT64
        nullable = False
    elif expr.func == PF_NTILE:
        base_name = "ntile"
        dt = ArrowType.INT64
        nullable = False
    elif expr.is_offset():
        # ⭐ THE VALUE FUNCTIONS COPY THE INPUT FIELD; THEY DO NOT REBUILD IT.
        # LAG / LEAD / FIRST_VALUE / LAST_VALUE / NTH_VALUE return a CELL of
        # the input column, so the output is that column's type in full --
        # including the slots a three-argument `Field(name, dt, nullable)`
        # drops: DECIMAL (p, s), a TIMESTAMP's zone, a dictionary index type.
        # Dropping DECIMAL (p, s) renders `10.25` as `1025` on the C ABI. It
        # matters here because the kernel (`partition_value_fns`) serves every
        # layout the gather carries, not INT64 / FLOAT64 / STRING only.
        #
        # NULLABILITY: FIRST_VALUE / LAST_VALUE over a non-empty partition
        # always HAVE a source row, so they are nullable iff the input is.
        # LAG / LEAD have NO source row at a partition edge -- NULL there
        # unless a non-NULL DEFAULT answers it -- and NTH_VALUE has none past
        # a partition shorter than n.
        var col_idx = input_schema.column_index(expr.column)
        var in_nullable = input_schema.field_nullable(col_idx)
        var out_nullable: Bool
        if expr.func == PF_LAG or expr.func == PF_LEAD:
            out_nullable = in_nullable or not value_fn_has_default(expr)
        elif expr.func == PF_NTH_VALUE:
            out_nullable = True
        else:
            out_nullable = in_nullable
        var carried = input_schema.field_at(col_idx)
        if expr.alias_name.byte_length() > 0:
            carried.name = expr.alias_name.copy()
        else:
            carried.name = "_w" + String(expr_idx) + "_" + _value_fn_base_name(expr.func)
        carried.nullable = out_nullable
        return carried^
    elif expr.func == PF_SUM:
        base_name = "sum"
        var col_idx = input_schema.column_index(expr.column)
        var input_dt = input_schema.field_arrow_type(col_idx)
        if input_dt == ArrowType.INT8 or input_dt == ArrowType.INT16 \
           or input_dt == ArrowType.INT32 or input_dt == ArrowType.INT64:
            dt = ArrowType.INT64
        else:
            dt = ArrowType.FLOAT64
        nullable = False
    elif expr.func == PF_COUNT:
        base_name = "count"
        dt = ArrowType.INT64
        nullable = False
    elif expr.func == PF_AVG:
        base_name = "avg"
        dt = ArrowType.FLOAT64
        nullable = False
    elif expr.func == PF_MIN or expr.func == PF_MAX:
        if expr.func == PF_MIN:
            base_name = "min"
        else:
            base_name = "max"
        var col_idx = input_schema.column_index(expr.column)
        dt = input_schema.field_arrow_type(col_idx)
        nullable = input_schema.field_nullable(col_idx)
    else:
        raise Error("partition_expr_output_field: unknown func tag " + String(Int(expr.func)))

    var name: String
    if expr.alias_name.byte_length() > 0:
        name = expr.alias_name.copy()
    else:
        name = "_w" + String(expr_idx) + "_" + base_name
    return Field(name, dt, nullable)
