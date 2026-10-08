# =============================================================================
# Optimizer rule: partition_prune_scans
# Hive-partition pruning of partitioned scans
# =============================================================================
#
# A statistics-independent rule, designed to run BEFORE scan-statistics
# precompute and statistics propagation: pruning the path list shrinks the
# stats computed afterwards. Mirrors DuckDB's hive-partition filter pushdown
# and DataFusion's `ListingTable` partition pruning.
#
# Pattern:
#
#   Filter(<p_col> <op> <literal>  [AND <other conjuncts>])
#     └── Scan(partitioned: paths=[p0, p1, ...], partition_cols=[p_col, ...])
#
# rewrites to
#
#   Filter(<other conjuncts>)               # the p_col conjunct is dropped
#     └── Scan(partitioned: paths=<subset matching the predicate>, ...)
#
# and if EVERY conjunct of the Filter referenced a partition column (so the
# Filter would become empty), the Filter node is removed entirely:
#
#   Scan(partitioned: paths=<pruned subset>, ...)
#
# Each pruned conjunct must be exactly `<partition_col_ref> <cmp_op>
# <literal>` (or the symmetric `<literal> <cmp_op> <partition_col_ref>`)
# with `<cmp_op>` ∈ {==, !=, <, <=, >, >=}. The conjunct is then evaluated
# against each path's per-partition value (the raw `<value>` text parsed to
# the partition column's inferred type): INT64 → integer comparison; STRING
# → byte-lexicographic; DATE32 → byte-lexicographic over the canonical
# `YYYY-MM-DD` text (order-preserving for ISO dates). A path is KEPT iff
# the conjunct holds for it; a path whose value fails to parse for the
# column type, or whose comparison the literal's kind does not allow, is
# KEPT conservatively, and that conjunct then stays on the Filter (we never
# drop a row we're unsure about — correctness over completeness).
#
# References — implementations studied before coding:
#   * DuckDB `src/optimizer/filter_pushdown.cpp` +
#     `src/function/table/read_csv.cpp` / `parquet_extension.cpp`'s
#     `MultiFileReader::ApplyFilters`: hive partition columns are surfaced
#     as constant columns; pushed-down filters on those columns are
#     evaluated against the per-file constant value and files that fail
#     the predicate are pruned from the scan's file list (and the
#     corresponding filter is removed from the residual). The constant-
#     fold-then-prune shape here is the same.
#   * DataFusion `datafusion/core/src/datasource/listing/helpers.rs`
#     (`prune_partitions` + `apply_filters`): builds a "partition table"
#     of one row per file (partition columns only), runs the pushed-down
#     filter expression over it via the normal execution engine, and keeps
#     the files whose row survives. Our pass does the constant-fold inline
#     (one literal per file) rather than spinning up a mini execution, but
#     the prune semantics are identical.
#
# Pass order: komira_optimizer has no driver that orders its passes. This
# pass is designed to run BEFORE `propagate_statistics` and scan-statistics
# precompute (`precompute_scan_stats`, not in this tree).
#
# Mojo discipline: no UnsafePointer crosses a module boundary; the in-place
# rewrite mutates through `Optional[OwnedPointer[...]]` ref-mutation (the
# same shape as `flatten_dependent_joins_inplace`).
# =============================================================================

from std.memory import OwnedPointer
from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
)
from komira_plan_expr.expr_helpers import flatten_and_conjuncts
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ScanData,
    ExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
)


# =============================================================================
# Public API
# =============================================================================


def partition_prune_scans(var plan: LogicalPlan) raises -> LogicalPlan:
    """Top-level entry: prune partitioned-scan path lists using the
    pushed-down filter conjuncts that reference partition columns, and
    drop those conjuncts (and a now-empty Filter) from the plan.

    Idempotent: a plan with no partitioned scans (or no prunable
    conjuncts) is returned structurally unchanged.
    """
    partition_prune_scans_inplace(plan)
    return plan^


def partition_prune_scans_inplace(mut plan: LogicalPlan) raises:
    """In-place rewrite mirror of `partition_prune_scans`.

    Recurses children first, then attempts the Filter→Scan rewrite at
    this node. Recursion shape follows `flatten_dependent_joins_inplace`.
    """
    if plan.tag == PLAN_FILTER:
        partition_prune_scans_inplace(plan._filter.value()[].child[])
        _maybe_prune_filter_over_scan(plan)
    elif plan.tag == PLAN_PROJECT:
        partition_prune_scans_inplace(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        partition_prune_scans_inplace(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        partition_prune_scans_inplace(plan._join.value()[].left[])
        partition_prune_scans_inplace(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        partition_prune_scans_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        partition_prune_scans_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        partition_prune_scans_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        partition_prune_scans_inplace(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        partition_prune_scans_inplace(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        partition_prune_scans_inplace(plan._partition_topn.value()[].child[])
    # PLAN_SCAN / PLAN_ASOF_JOIN: nothing to prune at this node.


# =============================================================================
# The Filter → Scan rewrite
# =============================================================================


def _maybe_prune_filter_over_scan(mut plan: LogicalPlan) raises:
    """If `plan` is a Filter directly over a partitioned Parquet Scan,
    prune the scan's path list using the partition-column conjuncts and
    rewrite the Filter to drop those conjuncts (removing the Filter if it
    becomes empty)."""
    # plan.tag == PLAN_FILTER (caller guarantees).
    # MOJO 1.0.0: `child` / `scan` / `psrc` are projections of ONE walk of the
    # Filter. Reaching `.predicate` through a second `plan._filter` walk would
    # invalidate all three.
    ref fd = plan._filter.value()[]
    ref child = fd.child[]
    if child.tag != PLAN_SCAN:
        return
    if not child._scan:
        return
    ref scan = child._scan.value()[]
    if scan.source.tag != SOURCE_VARIANT_PARQUET:
        return
    ref psrc = scan.source._parquet.value()
    if len(psrc.partition_cols) == 0:
        return
    if len(psrc.paths) == 0:
        return
    # SKIP the lazy dir-scanning Hive shape. Its
    # partition filter is owned by the `attach_hive_predicate` pass (not in
    # this tree), which attaches the Tier-1 POD that `open_pruned`
    # (`komira_fs`) prunes with at the LIST prefix; a post-listing prune here
    # would be redundant (and there is no enumerated path list to prune —
    # `paths == [base_dir]`, `partition_values` empty). The two passes are
    # mutually exclusive per scan.
    if psrc.is_dir_scan_hive():
        return

    # Build a name → (col_idx, ArrowType) lookup for the partition columns.
    var part_names = List[String]()
    var part_types = List[ArrowType]()
    for i in range(len(psrc.partition_cols)):
        part_names.append(String(psrc.partition_cols[i].name))
        part_types.append(psrc.partition_cols[i].arrow_type)

    # Flatten the predicate into conjuncts; classify each as prunable
    # (a `<part_col> <cmp> <lit>` form) or residual.
    var conjuncts = flatten_and_conjuncts(fd.predicate)
    var prunable_col_idx = List[Int]()         # per prunable conjunct: partition col idx
    var prunable_op = List[UInt8]()            # cmp op (already oriented col-on-left)
    var prunable_lit = List[ScalarValue]()     # literal value
    var prunable_ci = List[Int]()              # per prunable conjunct: its index in `conjuncts`
    var is_prunable = List[Bool]()             # per conjunct

    for ci in range(len(conjuncts)):
        ref c = conjuncts[ci]
        var col_idx = -1
        var op: UInt8 = 0
        var lit = ScalarValue.from_bool(False)  # placeholder; overwritten on match
        if _classify_partition_conjunct(c, part_names, col_idx, op, lit):
            prunable_col_idx.append(col_idx)
            prunable_op.append(op)
            prunable_lit.append(lit^)
            prunable_ci.append(ci)
            is_prunable.append(True)
        else:
            is_prunable.append(False)

    if len(prunable_col_idx) == 0:
        return  # nothing to prune; leave the plan as-is.

    # Determine which paths survive ALL prunable conjuncts. A conjunct that
    # could not be decided for some path (literal kind does not match the
    # column type, value does not parse, unhandled type) keeps that path
    # and stays on the Filter: dropping it would return that path's rows
    # unfiltered.
    var keep = List[Bool]()
    for _ in range(len(psrc.paths)):
        keep.append(True)
    var undecided = List[Bool]()
    for _ in range(len(prunable_col_idx)):
        undecided.append(False)
    for pi in range(len(psrc.paths)):
        for k in range(len(prunable_col_idx)):
            var col = prunable_col_idx[k]
            var raw = String(psrc.partition_values[pi][col])
            var t = part_types[col]
            var verdict = _decide(raw, prunable_op[k], prunable_lit[k], t)
            if not verdict:
                undecided[k] = True
            elif not verdict.value():
                keep[pi] = False
                break

    # The Filter keeps every conjunct that is not prunable or that some
    # path left undecided, in the original order.
    for k in range(len(prunable_ci)):
        if undecided[k]:
            is_prunable[prunable_ci[k]] = False
    var residual = ExprArray()                 # conjuncts we keep on the Filter (Expr is Movable-only)
    for ci in range(len(conjuncts)):
        if not is_prunable[ci]:
            residual.append(conjuncts[ci].copy())

    var n_kept = 0
    for pi in range(len(psrc.paths)):
        if keep[pi]:
            n_kept += 1

    # Build the pruned path list + matching partition_values. (If nothing
    # was actually pruned, we still drop the decided partition conjuncts
    # below — they are always true for the surviving paths.)
    var all_pruned = n_kept == 0
    var new_paths = List[String]()
    var new_pvals = List[List[String]]()
    if all_pruned:
        # Edge case: every path pruned away. Keep a single (arbitrary) path
        # so the scan retains a valid shape; we then install a literal-FALSE
        # filter so the result is provably empty (DuckDB keeps the scan +
        # adds an always-false filter; we mirror that).
        new_paths.append(String(psrc.paths[0]))
        var row0 = List[String]()
        for j in range(len(psrc.partition_values[0])):
            row0.append(String(psrc.partition_values[0][j]))
        new_pvals.append(row0^)
    else:
        for pi in range(len(psrc.paths)):
            if not keep[pi]:
                continue
            new_paths.append(String(psrc.paths[pi]))
            var row = List[String]()
            for j in range(len(psrc.partition_values[pi])):
                row.append(String(psrc.partition_values[pi][j]))
            new_pvals.append(row^)

    # Rebuild the ParquetSource with the pruned path list. partition_cols
    # are unchanged (the columns still exist; there are just fewer files).
    var pcols_copy = List[Field]()
    for i in range(len(psrc.partition_cols)):
        pcols_copy.append(psrc.partition_cols[i].copy())
    var data_schema = psrc.schema_cached.copy()
    var name_copy: Optional[String] = None
    if psrc.name:
        name_copy = Optional(String(psrc.name.value()))
    var mtime = psrc._mtime_ns
    var new_psrc = ParquetSource.partitioned(
        new_paths^, data_schema^, pcols_copy^, new_pvals^, name_copy^, mtime
    )

    # Reseat the scan's source via a fresh ScanData, preserving the other
    # scan fields (projection / pushed filter / row_count / table_stats /
    # explicit schema). The explicit `schema` on ScanData is the FULL
    # output schema (data + partition cols) — unchanged by pruning.
    var proj_copy: Optional[List[String]] = None
    if scan.projection:
        proj_copy = Optional(scan.projection.value().copy())
    var scan_filter_copy: Optional[Expr] = None
    if scan.filter:
        scan_filter_copy = Optional(scan.filter.value().copy())
    var rc_copy: Optional[Int] = None
    if scan.row_count:
        rc_copy = Optional(scan.row_count.value())
    var ts_copy: Optional[TableStats] = None
    if scan.table_stats:
        ts_copy = Optional(scan.table_stats.value().copy())
    var scan_schema_copy: Optional[Schema] = None
    if scan.schema:
        scan_schema_copy = Optional(scan.schema.value().copy())
    var new_scan_data = ScanData(
        SourceVariant(new_psrc^),
        scan_schema_copy^,
        proj_copy^,
        scan_filter_copy^,
        rc_copy^,
        ts_copy^,
    )
    # Replace the child Scan's ScanData in place.
    plan._filter.value()[].child[]._scan = OwnedPointer(new_scan_data^)

    # Now rewrite the Filter: drop the prunable conjuncts.
    if len(residual) == 0:
        if all_pruned:
            # No residual + every path pruned → the result is empty. Replace
            # the Filter's predicate with a literal FALSE (keeps the Filter
            # node, so the plan stays an always-false Filter over a valid scan).
            plan._filter.value()[].predicate = Expr.literal(ScalarValue.from_bool(False))
        else:
            # No residual + some paths kept → the Filter is now a no-op
            # (the only conjuncts were partition predicates, all true for
            # the surviving paths). Collapse: replace `plan` with its child.
            var child_plan = plan._filter.value()[].child[].copy()
            plan = child_plan^
            # `plan` is now the (pruned) Scan; nothing more to do here.
            return
    else:
        # Rebuild the residual predicate as a left-skewed AND-chain.
        var new_pred = residual[0].copy()
        for i in range(1, len(residual)):
            new_pred = Expr.binary(BIN_AND, new_pred^, residual[i].copy())
        if all_pruned:
            new_pred = Expr.binary(
                BIN_AND, new_pred^, Expr.literal(ScalarValue.from_bool(False))
            )
        plan._filter.value()[].predicate = new_pred^


# =============================================================================
# Conjunct classification
# =============================================================================


def _classify_partition_conjunct(
    c: Expr,
    part_names: List[String],
    mut out_col_idx: Int,
    mut out_op: UInt8,
    mut out_lit: ScalarValue,
) raises -> Bool:
    """If `c` is exactly `<part_col_ref> <cmp> <lit>` (or the symmetric
    `<lit> <cmp> <part_col_ref>`), write the partition col index, the
    col-on-left-oriented comparison op, and the literal into the outs and
    return True. Otherwise return False.

    `<cmp>` ∈ {==, !=, <, <=, >, >=}. AND/OR/string-ops/casts/etc. are not
    prunable here (a later version could handle `IN (...)` over a partition col).
    """
    if c.tag != EXPR_BINARY_OP:
        return False
    var op = c.binary_op()
    if not (op == BIN_EQ or op == BIN_NE or op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE):
        return False
    ref lhs = c.binary_left_ref()
    ref rhs = c.binary_right_ref()
    # Case A: col <op> literal
    if lhs.tag == EXPR_COL_REF and rhs.tag == EXPR_LITERAL:
        var idx = _partition_col_index(lhs.col_ref_name(), part_names)
        if idx < 0:
            return False
        out_col_idx = idx
        out_op = op
        out_lit = rhs.literal_value()
        return True
    # Case B: literal <op> col  →  flip the op so col is on the left.
    if lhs.tag == EXPR_LITERAL and rhs.tag == EXPR_COL_REF:
        var idx = _partition_col_index(rhs.col_ref_name(), part_names)
        if idx < 0:
            return False
        out_col_idx = idx
        out_op = _flip_cmp(op)
        out_lit = lhs.literal_value()
        return True
    return False


def _partition_col_index(name: String, part_names: List[String]) -> Int:
    """Index of `name` in `part_names`, or -1 if not a partition column."""
    for i in range(len(part_names)):
        if part_names[i] == name:
            return i
    return -1


def _flip_cmp(op: UInt8) -> UInt8:
    """`a < b` ⇔ `b > a`, etc. EQ/NE are symmetric."""
    if op == BIN_LT:
        return BIN_GT
    if op == BIN_LE:
        return BIN_GE
    if op == BIN_GT:
        return BIN_LT
    if op == BIN_GE:
        return BIN_LE
    return op  # EQ / NE


# =============================================================================
# Per-path predicate evaluation
# =============================================================================


def _value_satisfies(
    raw: String, op: UInt8, lit: ScalarValue, arrow_type: ArrowType
) -> Bool:
    """Does the partition value `raw` (parsed to `arrow_type`) satisfy
    `<value> <op> <lit>`?  Returns True conservatively when `_decide`
    cannot judge the comparison (we never prune a path we're unsure
    about — correctness over completeness)."""
    var verdict = _decide(raw, op, lit, arrow_type)
    if verdict:
        return verdict.value()
    return True


def _decide(
    raw: String, op: UInt8, lit: ScalarValue, arrow_type: ArrowType
) -> Optional[Bool]:
    """The value of `<raw parsed to arrow_type> <op> <lit>`, or None when it
    cannot be judged: `raw` fails to parse for `arrow_type`, `lit` is not
    the matching kind, or `arrow_type` is not handled."""
    if arrow_type == ArrowType.INT64:
        if not lit.is_int():
            return None  # type mismatch.
        var rv: Int64
        try:
            rv = _parse_int64(raw)
        except:
            return None  # unparseable.
        var lv = lit.int_val
        return _cmp_i64(rv, op, lv)
    elif arrow_type == ArrowType.DATE32:
        # DATE32 partition values are the canonical `YYYY-MM-DD` text; only
        # a string literal of the same shape is compared (any other literal
        # kind is undecided and keeps the path).
        # Byte-lexicographic comparison is order-preserving for ISO dates.
        if not lit.is_string():
            return None
        return _cmp_str(raw, op, lit.string_val)
    elif arrow_type == ArrowType.STRING:
        if not lit.is_string():
            return None
        return _cmp_str(raw, op, lit.string_val)
    # Other partition types (none today).
    return None


def _parse_int64(s: String) raises -> Int64:
    """Parse an optionally-signed decimal integer. Raises on bad input or
    overflow (caller treats a raise as 'keep the path')."""
    var bs = s.as_bytes()
    if len(bs) == 0:
        raise Error("empty int")
    var neg = False
    var start = 0
    if bs[0] == UInt8(ord("-")):
        neg = True
        start = 1
    elif bs[0] == UInt8(ord("+")):
        start = 1
    if start >= len(bs):
        raise Error("sign only")
    var acc: Int64 = 0
    for i in range(start, len(bs)):
        if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
            raise Error("non-digit")
        var d = Int64(Int(bs[i]) - ord("0"))
        # Overflow guard (rough): 18 digits always fit; beyond that, bail.
        if i - start >= 18:
            raise Error("too many digits")
        acc = acc * 10 + d
    if neg:
        acc = -acc
    return acc


def _cmp_i64(a: Int64, op: UInt8, b: Int64) -> Bool:
    if op == BIN_EQ:
        return a == b
    if op == BIN_NE:
        return a != b
    if op == BIN_LT:
        return a < b
    if op == BIN_LE:
        return a <= b
    if op == BIN_GT:
        return a > b
    if op == BIN_GE:
        return a >= b
    return True  # unknown op — keep.


def _cmp_str(a: String, op: UInt8, b: String) -> Bool:
    if op == BIN_EQ:
        return a == b
    if op == BIN_NE:
        return a != b
    if op == BIN_LT:
        return a < b
    if op == BIN_LE:
        return a <= b
    if op == BIN_GT:
        return a > b
    if op == BIN_GE:
        return a >= b
    return True  # unknown op — keep.
