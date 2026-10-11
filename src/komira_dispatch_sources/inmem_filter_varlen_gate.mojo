# =============================================================================
# komira_dispatch_sources.inmem_filter_varlen_gate -- the row half of the
#   resident-filter fan-out's admission, with a lower floor for a predicate
#   that reads a variable-width column.
# =============================================================================
#
# The in-memory leaf filters a resident batch serially, or fans the filter out
# over workers (contiguous row ranges, survivors concatenated in range order,
# so the result is the same rows in the same order either way). Its row floor
# for the fan-out is 262,144 rows, set for a fixed-width compare of a few
# nanoseconds per row.
#
# A predicate that reads a STRING, LARGE_STRING, BINARY or LARGE_BINARY column
# (a LIKE, a contains, an equality over a string) pays per byte, several times
# the per-row cost of a fixed-width compare, so the fan-out pays for itself on
# fewer rows. Such a predicate is admitted from
# `INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN` = 65,536 rows. A predicate that reads
# only fixed-width columns keeps the caller's floor.
#
# This module decides who is admitted, never what the filter computes. The
# varlen floor is a flag (`varlen_on`, default
# `INMEM_FILTER_VARLEN_GATE_DEFAULT_ON`): False restores the row-count-only
# gate, the A/B arm. The worker-count half of the admission stays with the
# caller.
# =============================================================================

from std.collections import Set

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_plan_expr.expr import Expr
from komira_plan_ir.plan_helpers import _collect_expr_columns


comptime INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN: Int = 65_536
"""The fan-out floor for a predicate that reads a variable-width column. A
cost decision, never a correctness one."""

comptime INMEM_FILTER_VARLEN_GATE_DEFAULT_ON: Bool = True
"""The default of `inmem_filter_rows_admit_fanout`'s `varlen_on` flag."""


def predicate_reads_varlen_column(
    imm batch: RecordBatch, imm predicate: Expr
) -> Bool:
    """True iff `predicate` references at least one column of `batch` whose
    type is STRING, LARGE_STRING, BINARY or LARGE_BINARY. A column name the
    batch does not carry is skipped (the evaluator owns that error)."""
    var cols = Set[String]()
    _collect_expr_columns(predicate, cols)
    for name in cols:
        var idx = -1
        for i in range(batch.schema.num_columns()):
            if batch.schema.field_name(i) == name:
                idx = i
                break
        if idx < 0:
            continue
        var at = batch.schema.field_arrow_type(idx)
        if (
            at == ArrowType.STRING
            or at == ArrowType.LARGE_STRING
            or at == ArrowType.BINARY
            or at == ArrowType.LARGE_BINARY
        ):
            return True
    return False


def inmem_filter_rows_admit_fanout(
    imm batch: RecordBatch,
    imm predicate: Expr,
    floor_rows: Int,
    *,
    varlen_on: Bool = INMEM_FILTER_VARLEN_GATE_DEFAULT_ON,
) -> Bool:
    """The row half of the fan-out's admission: True when `batch` has at least
    `floor_rows` rows (the fixed-width floor) for any predicate, or, with
    `varlen_on`, at least `INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN` rows for a
    predicate that reads a variable-width column. With `varlen_on=False` only
    `floor_rows` admits."""
    var n = batch.num_rows()
    if n >= floor_rows:
        return True
    if n < INMEM_FILTER_PARALLEL_MIN_ROWS_VARLEN:
        return False
    return varlen_on and predicate_reads_varlen_column(batch, predicate)
