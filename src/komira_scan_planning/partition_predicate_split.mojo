# =============================================================================
# komira_scan_planning.partition_predicate_split — the optimizer
# predicate-split that separates a scan's filter into the PARTITION-column
# (Tier-1) part and the DATA-column (Tier-2) part.
# =============================================================================
#
#
# PLACEMENT NOTE (build-graph, NOT a logical reclassification): this is the
# optimizer's scan-construction split (a compiler-layer concern), but it is
# SOURCED in `komira_scan_planning`, next to `komira_fs`, because (a) its OUTPUT type
# `PartitionPredicate` + the `PrunedHiveDiscovery.open_pruned` it feeds both
# live here, and (b) housing it in the compiler package would make the
# compiler import these async predicate types. The one import the split needs (`komira_plan_expr.expr.Expr`) is
# already a dependency of this package (see `reader_factory.mojo`), so this
# placement is acyclic. The split function is the public seam the SDK scan-
# construction calls; it does not change which pkg "owns" the optimizer logic.
#
# Placement = PLAN-CONSTRUCTION time (mirrors DataFusion's `list_files_for_scan`),
# NOT execution. When a Hive-partitioned read is being lowered, the optimizer
# inspects the scan's filter `Expr` and SPLITS it into two tiers:
#
#   * Tier-1 (PARTITION): constraints on PARTITION columns -> a structured
# `PartitionPredicate` (the input shape). These prune WHOLE FILES at
#     list time, BEFORE any footer opens (the prune-at-prefix win). The
#     optimizer hands this to `PrunedHiveDiscovery.open_pruned`.
#
#   * Tier-2 (DATA): constraints on DATA columns -> the RESIDUAL `Expr`,
#     which stays on the scan as the existing row-group / page / row pushdown
# (the dynamic-filter / stats-pruning path — UNCHANGED). does NOT
#     touch the Tier-2 path; it only carves the data-pred back out and returns
#     it for the existing pushdown to consume.
#
# A predicate referencing BOTH splits:
# `dt=...` -> Tier-1 PartitionConstraint; `amount>100` -> Tier-2 residual Expr.
#
# keep the two tiers SEPARATE — partition pruning (path-level,
# plan-time) vs row-group pruning (data-level, execution-time). This module's
# OUTPUT is exactly that separation: `(PartitionPredicate, Optional[Expr])`.
#
# SCOPE:
#   * THIS module: extract partition constraints from the filter Expr, build
#     the PartitionPredicate, return the residual data-pred.
#   * The DISCOVERY routing (EagerGlob vs PrunedHive) is a thin decision on the
#     output: a non-empty PartitionPredicate -> construct PrunedHiveDiscovery
#     via `open_pruned`; an empty one -> EagerGlobDiscovery (today's default).
#     `should_use_pruned_discovery` encodes that decision; the concrete
# `Self.DISC` binding at the source ctor is the type-param.
#   * The partition-COLUMN output materialization (constant columns from the
# path) is — NOT here.
#
# Tested AT THE OPTIMIZER/PLAN SEAM (NO ctx.materialize / typed-read binding):
# `split_partition_predicate(filter, part_cols, part_types)` is a pure
# function over an `Expr` + the partition schema, returning the
# (PartitionPredicate, residual) split — unit-tested directly. This avoids the
# heavyweight source-mode compile.
#
# Pointer discipline:
#   * NO UnsafePointer in any signature — `Expr` (OwnedPointer-internal),
#     `PartitionPredicate` / `PartitionConstraint` (POD-ish value types), and
#     `String` / `Int` / `Bool` / `ArrowType` only.
#   * safe across destroy-recreate: the output is by-value value types; no slab element holds a
#     wildcard-origin or `List`-inside-byte-slab shape.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_IN_LIST,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.expr_helpers import flatten_and_conjuncts
from komira_plan_expr.scalar_value import ScalarValue
from komira_fs.pruned_hive_discovery import (
    PartitionPredicate,
    PartitionConstraint,
)


# =============================================================================
# the split result.
# =============================================================================


@fieldwise_init
struct PredicateSplit(Movable):
    """The result of `split_partition_predicate`:

      * `partition_predicate`: the Tier-1 conjunction over PARTITION columns
        (the `open_pruned` input). EMPTY when the filter references no
        partition column (then the read uses `EagerGlobDiscovery`, today's
        default).
      * `residual`: the Tier-2 data-column predicate — the conjuncts that
        reference DATA columns (or are non-splittable), re-AND-ed back into a
        single `Expr`. `None` when EVERY conjunct was a clean partition
        constraint (the whole filter pruned at list time, nothing left for the
        row-group pushdown). This `Expr` stays on the scan UNCHANGED for the
        existing Tier-2 pushdown.

    The two fields are deliberately SEPARATE value types — Tier-1 is the
    structured prune predicate (path-level, plan-time); Tier-2 is the raw
    `Expr` the row-group pruner already consumes (data-level, exec-time).
    does not conflate them.
    """

    var partition_predicate: PartitionPredicate
    var residual: Optional[Expr]

    @always_inline
    def has_partition_pruning(self) -> Bool:
        """True iff the Tier-1 predicate has at least one constraint — i.e.
        the read should construct `PrunedHiveDiscovery` (vs `EagerGlobDiscovery`)."""
        return self.partition_predicate.num_constraints() > 0


# =============================================================================
# the split driver.
# =============================================================================


def split_partition_predicate(
    filter: Expr,
    partition_cols: List[String],
    partition_types: List[ArrowType],
) raises -> PredicateSplit:
    """Split `filter` into the Tier-1 partition predicate + the Tier-2 residual
    data predicate, given the partition schema (`partition_cols` +
    `partition_types`, parallel lists —).

    Algorithm:
      1. Flatten the top-level AND-tree into a list of conjuncts (a filter is
         a conjunction; an OR or a non-AND root is ONE opaque conjunct).
      2. For each conjunct, try to classify it as a clean PARTITION constraint
         (a comparison or IN-list whose tested column is a PARTITION column):
           * `col <op> literal` where `col` is a partition col -> a
             `PartitionConstraint` (EQ / NE / LT / LE / GT / GE).
           * `col IN (lit, lit, ...)` where `col` is a partition col -> an IN
             `PartitionConstraint`.
         A conjunct that touches a partition col with a shape cannot
         enumerate cleanly (e.g. `col` on BOTH sides, function-wrapped, or a
         literal with no canonical partition text: NULL, FLOAT, DATE32,
         TIMESTAMP, binary, decimal; see `_scalar_to_partition_string`) is
         routed CONSERVATIVELY: it becomes an `OTHER` fold constraint (so the
         fold keeps the file) AND it stays in the residual (so the
         row-group pruner still sees it). Correctness over pruning.
      3. Everything else (conjuncts that reference only DATA columns, or whose
         shape is not a recognized comparison) flows to the Tier-2 residual,
         UNCHANGED.
      4. The surviving residual conjuncts are re-AND-ed into one `Expr`
         (`None` if none remain).

    NO listing / NO discovery construction here — pure derivation over the
    `Expr`. The caller routes the result to `open_pruned` (Tier-1) + the scan
    pushdown (Tier-2).
    """
    # Step 1 — flatten the AND-tree. Reuses the canonical AND-flattener
    # (`komira_plan_expr.expr_helpers.flatten_and_conjuncts`) which returns a
    # `Slab[Expr]` of the non-AND leaf conjuncts (deep copies). `Expr` is
    # Movable-only — it owns `OwnedPointer` children — so the codebase stores
    # it in a `Slab`, never a `List` (which requires `Copyable`).
    var conjuncts = flatten_and_conjuncts(filter)

    var constraints = List[PartitionConstraint]()
    var residual_conjuncts = Slab[Expr]()

    # Step 2/3 — classify each conjunct.
    for ci in range(conjuncts.len()):
        ref conj = conjuncts[ci]
        var classified = _try_partition_constraint(
            conj, partition_cols, partition_types
        )
        if classified.is_partition:
            # A clean (or conservatively-folded) partition constraint -> Tier-1.
            constraints.append(classified.constraint.value().copy())
            if classified.keep_in_residual:
                # Conservative case: also leave it on the data pushdown.
                residual_conjuncts.append(conj.copy())
        else:
            # Tier-2 data predicate (or unrecognized shape) -> residual UNCHANGED.
            residual_conjuncts.append(conj.copy())

    var predicate = PartitionPredicate(constraints=constraints^)

    # Step 4 — re-assemble the residual conjuncts into one Expr.
    var residual = _rebuild_conjunction(residual_conjuncts)

    return PredicateSplit(partition_predicate=predicate^, residual=residual^)


# =============================================================================
# discovery routing decision.
# =============================================================================


@always_inline
def should_use_pruned_discovery(split: PredicateSplit) -> Bool:
    """The routing decision: True -> the scan's `DISC` binds to
    `PrunedHiveDiscovery` (constructed via `open_pruned` with
    `split.partition_predicate`); False -> `EagerGlobDiscovery` (today's
    default, UNCHANGED behavior).

    A read is routed to the pruned discovery iff the split produced at least
    one partition constraint. A Hive-partitioned read whose filter happens to
    name NO partition column still falls back to eager listing (no prune
    possible) — preserving the non-partitioned-read behavior exactly."""
    return split.has_partition_pruning()


# =============================================================================
# per-conjunct classification.
# =============================================================================


@fieldwise_init
struct _Classified(Movable):
    """The result of classifying one conjunct:
      * `is_partition` — True if it became a Tier-1 `PartitionConstraint`.
      * `constraint` — the constraint (Some iff `is_partition`).
      * `keep_in_residual` — True for the CONSERVATIVE case (an OTHER
        constraint that the fold cannot evaluate): keep the conjunct on the
        Tier-2 residual too, so the row-group pruner still applies it. False
        for a clean enumerable/comparison constraint (fully consumed by Tier-1)."""

    var is_partition: Bool
    var constraint: Optional[PartitionConstraint]
    var keep_in_residual: Bool

    @staticmethod
    def data() -> _Classified:
        """Not a partition constraint — flows to the Tier-2 residual."""
        return _Classified(
            is_partition=False,
            constraint=Optional[PartitionConstraint](None),
            keep_in_residual=False,
        )

    @staticmethod
    def clean(var c: PartitionConstraint) -> _Classified:
        """A clean enumerable/comparison partition constraint — fully consumed
        by Tier-1 (NOT kept on the residual)."""
        return _Classified(
            is_partition=True,
            constraint=Optional[PartitionConstraint](c^),
            keep_in_residual=False,
        )

    @staticmethod
    def conservative(var c: PartitionConstraint) -> _Classified:
        """A partition-col conjunct cannot cleanly enumerate -> an OTHER
        fold constraint AND kept on the residual (correctness over pruning)."""
        return _Classified(
            is_partition=True,
            constraint=Optional[PartitionConstraint](c^),
            keep_in_residual=True,
        )


def _try_partition_constraint(
    conj: Expr,
    partition_cols: List[String],
    partition_types: List[ArrowType],
) raises -> _Classified:
    """Classify one conjunct. Recognized partition shapes:
      * `EXPR_BINARY_OP` with a comparison op (EQ/NE/LT/LE/GT/GE) where exactly
        ONE side is a partition `EXPR_COL_REF` and the OTHER is an
        `EXPR_LITERAL` -> a comparison `PartitionConstraint` (op flipped if the
        literal is on the left).
      * `EXPR_IN_LIST` whose tested child is a partition `EXPR_COL_REF` and
        whose values are all literals -> an IN `PartitionConstraint`.

    A conjunct that references a partition col in a shape we cannot enumerate
    (col-on-both-sides, function-wrapped, an OR mixing a partition col) is
    routed CONSERVATIVELY as an OTHER constraint kept on the residual."""

    if conj.tag == EXPR_BINARY_OP:
        return _classify_binary(conj, partition_cols, partition_types)
    if conj.tag == EXPR_IN_LIST:
        return _classify_in_list(conj, partition_cols, partition_types)

    # Not a recognized comparison/in-list shape. If it references a partition
    # col anywhere (e.g. wrapped in a function / OR), route it conservatively
    # so the file-fold keeps the file; else it is a pure data predicate.
    var pcol = _references_partition_col(conj, partition_cols)
    if pcol.byte_length() > 0:
        return _Classified.conservative(PartitionConstraint.other(pcol))
    return _Classified.data()


def _classify_binary(
    conj: Expr,
    partition_cols: List[String],
    partition_types: List[ArrowType],
) raises -> _Classified:
    """Classify an `EXPR_BINARY_OP` conjunct."""
    var op = conj.binary_op()
    if not _is_comparison_op(op):
        # BIN_OR: the SDK's `Expr.in_list` factory FOLDS `col IN (v1..vN)` into
        # a left-leaning OR-chain of `col == vi` EQ leaves (it does NOT emit an
        # EXPR_IN_LIST node — see expr.mojo:2068). Try to RECONSTRUCT that
        # shape back into an IN `PartitionConstraint` so the IN-fan-out
        # prefix path (N targeted prefixes) is reachable. If the OR-chain is
        # NOT a clean same-partition-col EQ-disjunction, fall through.
        if op == BIN_OR:
            var in_recon = _try_or_chain_in_list(
                conj, partition_cols, partition_types
            )
            if in_recon.is_partition:
                return in_recon^
        # AND/OR/arithmetic at the conjunct level that is NOT a reconstructable
        # IN-chain — not a clean per-col constraint. (Top-level AND was already
        # flattened upstream; a residual AND here would be a nested boolean.)
        # Route conservatively if it touches a partition col.
        var pcol = _references_partition_col(conj, partition_cols)
        if pcol.byte_length() > 0:
            return _Classified.conservative(PartitionConstraint.other(pcol))
        return _Classified.data()

    ref lhs = conj.binary_left_ref()
    ref rhs = conj.binary_right_ref()

    var left_is_col = lhs.tag == EXPR_COL_REF
    var right_is_col = rhs.tag == EXPR_COL_REF
    var left_is_lit = lhs.tag == EXPR_LITERAL
    var right_is_lit = rhs.tag == EXPR_LITERAL

    # Shape A: col <op> literal
    if left_is_col and right_is_lit:
        var col = lhs.col_ref_name()
        var pidx = _partition_col_index(col, partition_cols)
        if pidx < 0:
            return _Classified.data()  # data col -> Tier-2
        var atype = partition_types[pidx]
        var val = _scalar_to_partition_string(rhs.literal_value())
        if not val:
            return _Classified.conservative(PartitionConstraint.other(col))
        return _make_compare_constraint(col, op, val.value(), atype)

    # Shape B: literal <op> col  -> flip the op
    if right_is_col and left_is_lit:
        var col = rhs.col_ref_name()
        var pidx = _partition_col_index(col, partition_cols)
        if pidx < 0:
            return _Classified.data()
        var atype = partition_types[pidx]
        var val = _scalar_to_partition_string(lhs.literal_value())
        if not val:
            return _Classified.conservative(PartitionConstraint.other(col))
        return _make_compare_constraint(col, _flip_op(op), val.value(), atype)

    # Shape C: a comparison NOT of the (col, literal) form but referencing a
    # partition col (col-on-both-sides, expr-on-one-side) -> conservative.
    var pcol = _references_partition_col(conj, partition_cols)
    if pcol.byte_length() > 0:
        return _Classified.conservative(PartitionConstraint.other(pcol))
    return _Classified.data()


def _classify_in_list(
    conj: Expr,
    partition_cols: List[String],
    partition_types: List[ArrowType],
) raises -> _Classified:
    """Classify an `EXPR_IN_LIST` conjunct: `child IN (v1..vN)`."""
    ref child = conj.in_list_child_ref()
    if child.tag != EXPR_COL_REF:
        # IN over a non-col expression -> conservative if it touches a partition
        # col, else data.
        var pcol = _references_partition_col(conj, partition_cols)
        if pcol.byte_length() > 0:
            return _Classified.conservative(PartitionConstraint.other(pcol))
        return _Classified.data()

    var col = child.col_ref_name()
    var pidx = _partition_col_index(col, partition_cols)
    if pidx < 0:
        return _Classified.data()  # IN over a data col -> Tier-2 (unchanged)

    var atype = partition_types[pidx]
    ref values = conj.in_list_values_ref()
    var vs = List[String]()
    for vi in range(len(values)):
        var v = _scalar_to_partition_string(values[vi])
        if not v:
            # One value without a canonical text form: the fold cannot
            # match the list, so keep the file and the conjunct.
            return _Classified.conservative(PartitionConstraint.other(col))
        vs.append(v.value())
    return _Classified.clean(PartitionConstraint.in_list(col, vs^, atype))


def _try_or_chain_in_list(
    conj: Expr,
    partition_cols: List[String],
    partition_types: List[ArrowType],
) raises -> _Classified:
    """Try to reconstruct an `Expr.in_list`-folded OR-chain back into an IN
    `PartitionConstraint`. The SDK folds `col IN (v1..vN)` into a left-leaning
    `((col==v1) OR (col==v2)) OR ...` tree (expr.mojo:2068). This walks that
    tree, collecting `col == literal` EQ leaves; iff EVERY leaf is an EQ on the
    SAME partition column against a literal, it returns a clean IN constraint
    (N targeted prefixes via the fan-out). Any deviation (a non-EQ leaf, a
    different col, a non-literal RHS, a data col) returns `_Classified.data()`
    so the caller falls back to the conservative route."""
    var col_name = String("")
    var values = List[String]()
    if not _collect_or_eq_leaves(conj, col_name, values):
        return _Classified.data()
    if col_name.byte_length() == 0 or len(values) == 0:
        return _Classified.data()
    var pidx = _partition_col_index(col_name, partition_cols)
    if pidx < 0:
        return _Classified.data()  # OR-chain over a data col -> Tier-2
    var atype = partition_types[pidx]
    return _Classified.clean(
        PartitionConstraint.in_list(col_name, values^, atype)
    )


def _collect_or_eq_leaves(
    e: Expr, mut col_name: String, mut values: List[String]
) raises -> Bool:
    """DFS an OR-chain, collecting `col == literal` leaves. Returns False the
    moment the shape deviates from a uniform single-column EQ-disjunction:
      * an OR node recurses both sides;
      * an EQ node of `col == literal` (or `literal == col`) records the value
        and pins/confirms `col_name`;
      * anything else -> False.
    `col_name` is set on the first EQ leaf and must match on every later leaf."""
    if e.tag == EXPR_BINARY_OP and e.binary_op() == BIN_OR:
        if not _collect_or_eq_leaves(e.binary_left_ref(), col_name, values):
            return False
        return _collect_or_eq_leaves(e.binary_right_ref(), col_name, values)
    if e.tag == EXPR_BINARY_OP and e.binary_op() == BIN_EQ:
        ref l = e.binary_left_ref()
        ref r = e.binary_right_ref()
        # col == literal  OR  literal == col
        var this_col: String
        var this_val: Optional[String]
        if l.tag == EXPR_COL_REF and r.tag == EXPR_LITERAL:
            this_col = l.col_ref_name()
            this_val = _scalar_to_partition_string(r.literal_value())
        elif r.tag == EXPR_COL_REF and l.tag == EXPR_LITERAL:
            this_col = r.col_ref_name()
            this_val = _scalar_to_partition_string(l.literal_value())
        else:
            return False
        if not this_val:
            # A literal without a canonical text form: not a clean IN; the
            # caller routes the OR conservatively.
            return False
        if col_name.byte_length() == 0:
            col_name = this_col
        elif col_name != this_col:
            return False  # an EQ on a DIFFERENT col -> not a clean IN
        values.append(this_val.value())
        return True
    return False


def _make_compare_constraint(
    col: String, op: UInt8, value: String, atype: ArrowType
) -> _Classified:
    """Build a clean comparison `PartitionConstraint` from a (col, op, value)
    triple. EQ -> the `.eq` factory (prefix-pinnable); the inequalities ->
    `.compare` (fold constraints). All are "clean" (fully consumed by Tier-1,
    NOT kept on the residual — the prefix-walk + the fold cover them)."""
    if op == BIN_EQ:
        return _Classified.clean(PartitionConstraint.eq(col, value, atype))
    # NE / LT / LE / GT / GE -> the fold-constraint ops.
    var fold_op = _bin_op_to_partition_op(op)
    return _Classified.clean(
        PartitionConstraint.compare(col, fold_op, value, atype)
    )


# =============================================================================
# Expr-tree helpers.
# =============================================================================


def _rebuild_conjunction(conjuncts: Slab[Expr]) raises -> Optional[Expr]:
    """Re-AND a `Slab` of residual conjuncts into one `Expr`. `None` for an
    empty slab (the whole filter was consumed by Tier-1); the single conjunct
    itself for a 1-element slab; a left-deep AND-tree otherwise.

    Takes a `Slab[Expr]` (not `List[Expr]`) because `Expr` is Movable-only and
    cannot live in a `List`. Reads each element by `ref` + `.copy()` to build
    the new tree (the slab is not consumed)."""
    if conjuncts.len() == 0:
        return Optional[Expr](None)
    var acc = conjuncts[0].copy()
    for i in range(1, conjuncts.len()):
        acc = Expr.binary(BIN_AND, acc^, conjuncts[i].copy())
    return Optional[Expr](acc^)


def _references_partition_col(e: Expr, partition_cols: List[String]) raises -> String:
    """Return the name of the FIRST partition column referenced anywhere in `e`
    (a DFS over the comparison/in-list/boolean shapes walks), or the empty
    string if `e` references no partition column. Used for the conservative
    OTHER-constraint route — we only need to know WHICH partition col the
    opaque conjunct touches, not the full structure."""
    if e.tag == EXPR_COL_REF:
        var nm = e.col_ref_name()
        if _partition_col_index(nm, partition_cols) >= 0:
            return nm
        return String("")
    if e.tag == EXPR_BINARY_OP:
        var l = _references_partition_col(e.binary_left_ref(), partition_cols)
        if l.byte_length() > 0:
            return l
        return _references_partition_col(e.binary_right_ref(), partition_cols)
    if e.tag == EXPR_IN_LIST:
        return _references_partition_col(e.in_list_child_ref(), partition_cols)
    # Other Expr shapes (cast/unary/string-op/...) are not walked structurally
    # in conservative path — if a partition col is buried under one of
    # these, it simply won't prune (and the data pushdown still applies). This
    # is the correctness-over-pruning fallback fold relies on.
    return String("")


# =============================================================================
# small value helpers.
# =============================================================================


@always_inline
def _is_comparison_op(op: UInt8) -> Bool:
    return (
        op == BIN_EQ
        or op == BIN_NE
        or op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
    )


def _flip_op(op: UInt8) -> UInt8:
    """Flip a comparison op for the `literal <op> col` -> `col <flip> literal`
    rewrite. EQ/NE are symmetric; LT<->GT, LE<->GE swap."""
    if op == BIN_LT:
        return BIN_GT
    if op == BIN_LE:
        return BIN_GE
    if op == BIN_GT:
        return BIN_LT
    if op == BIN_GE:
        return BIN_LE
    return op  # EQ / NE symmetric


def _bin_op_to_partition_op(op: UInt8) -> Int:
    """Map an `Expr` comparison `BIN_*` op to the `PartitionConstraint`
    `_OP_*` op (for the `.compare` factory). EQ is handled by `.eq` upstream;
    this maps NE/LT/LE/GT/GE. The numeric values are the contract:
    LT=2, LE=3, GT=4, GE=5, NE=6."""
    if op == BIN_LT:
        return 2
    if op == BIN_LE:
        return 3
    if op == BIN_GT:
        return 4
    if op == BIN_GE:
        return 5
    if op == BIN_NE:
        return 6
    return 6  # default to NE (should not reach for a comparison op)


def _partition_col_index(col: String, partition_cols: List[String]) -> Int:
    """The index of `col` in `partition_cols`, or -1 if `col` is a DATA
    column (not a partition column)."""
    for i in range(len(partition_cols)):
        if partition_cols[i] == col:
            return i
    return -1


def _scalar_to_partition_string(value: ScalarValue) -> Optional[String]:
    """Render a literal `ScalarValue` into its CANONICAL partition-value text
    form — the form the `PartitionConstraint` stores and the fold /
    prefix-encode consume — or `None` when the literal has no such form.

      * STRING -> the string itself.
      * Integers that fit Int64 (int8..int64, uint8..uint32) -> decimal
        digits. The fold compares INT64 cols numerically, so `1` matches an
        on-disk `01` regardless.
      * BOOL -> `true` / `false`.
      * Every other kind -> `None`: NULL (`col = NULL` is never true, while
        the empty text would match the null partition), FLOAT (`2020.0` is
        neither the INT64 text `2020` nor numerically parsed by the fold),
        DATE32 / TIMESTAMP (the day / micros count is not the `YYYY-MM-DD` /
        `YYYY-MM-DD HH:MM:SS` path text), binary, decimal, uint64 (a value
        >= 2^63 has no Int64 text) and the remaining kinds. The caller
        routes such a conjunct conservatively (an OTHER constraint, kept on
        the residual), so pruning never changes the result. A date predicate
        written as a STRING literal (`dt = '2026-11-04'`) still prunes.

    This matches the `encode_partition_value` contract: the caller produces
    canonical text; encode url-escapes it for the path segment."""
    if value.is_string():
        return Optional[String](value.string_val.copy())
    if value.fits_int64_family():
        return Optional[String](String(value.int_val))
    if value.is_bool():
        return Optional[String](
            String("true") if value.bool_val else String("false")
        )
    return Optional[String](None)
