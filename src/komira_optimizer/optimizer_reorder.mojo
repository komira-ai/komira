# =============================================================================
# Optimizer join reordering -- Greedy algorithm
# =============================================================================
#
# Reorders chains of consecutive INNER joins to minimize the size of the
# intermediate hash tables, using a greedy cost-based strategy:
#
#   1. Walk the plan. When a JOIN_INNER subtree is found, flatten it into a
#      JoinChain (list of leaf relations + list of join edges).
#   2. Sort leaf relations by cardinality ascending.
#   3. Seed the running plan with the smallest relation.
#   4. Repeatedly pick the remaining relation that, when joined, produces
#      the smallest estimated intermediate cardinality. Ties are broken
#      by insertion order. Relations without a connecting edge become
#      CROSS joins (only used as a last resort).
#
# This is a port of the v0.3 Rust optimizer:
#   - RelationSet
#   - JoinRelation/JoinEdge
#   - extract_join_chain
#   - greedy_join_order
#   - reorder_joins
#
# **Scope**: this module is the greedy search and the chain types and
# cost functions it shares with the DPccp enumerator (`optimizer_dpccp`,
# not in this tree).
#
# **Cost model**: greedy ranks candidates with
# `estimate_join_cardinality_for_reorder`, the conservative fallback
# `max(left_card, right_card)`, which is what the v0.3 formula
# collapses to when both sides' key_distinct_count is unknown. The
# NDV-aware `estimate_join_cardinality_with_ndv` is the DPccp cost
# function (see `greedy_join_order`).
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr, EXPR_COL_REF
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_SCAN,
    JOIN_INNER,
    JOIN_CROSS,
)
from komira_plan_stats.table_stats import TableStats
from komira_plan_ir.plan_helpers import (
    _copy_plan,
    _copy_expr_array,
    _copy_agg_expr_array,
    _take_filter_child,
    _take_project_child,
    _take_aggregate_child,
    _take_join_left,
    _take_join_right,
    _take_sort_child,
    _take_limit_child,
    _take_distinct_child,
    _take_topn_child,
)
from .optimizer_stats import estimate_cardinality
from .optimizer_filter_selectivity import scale_table_stats_for_selectivity


# =============================================================================
# Constants
# =============================================================================

# Bitmask width limit. Beyond this we fall back to the original plan
# because RelationSet uses a single UInt64. Matches v0.3 RelationSet(u64).
comptime MAX_RELATIONS_FOR_REORDER: Int = 64

# Cardinality saturation constant to prevent overflow in CROSS-join fallback
# math. Large enough to dominate any comparison but well below Int.MAX.
comptime REORDER_CARDINALITY_MAX: Int = 1 << 62


# =============================================================================
# RelationSet -- compact bit-mask over up to 64 relations
# =============================================================================

struct RelationSet(Copyable, Movable):
    """A set of relation ids backed by a single UInt64 bitmask.

    Supports up to 64 relations. Each method is `@always_inline` to ensure
    the bitwise operations fuse with their call sites. Matches the v0.3
    Rust implementation.
    """

    var bits: UInt64

    @always_inline
    def __init__(out self):
        self.bits = UInt64(0)

    @always_inline
    def __init__(out self, bits: UInt64):
        self.bits = bits

    @staticmethod
    @always_inline
    def empty() -> RelationSet:
        return RelationSet(UInt64(0))

    @staticmethod
    @always_inline
    def singleton(id: Int) -> RelationSet:
        # SAFETY: id must be < 64. Caller enforces via MAX_RELATIONS_FOR_REORDER.
        return RelationSet(UInt64(1) << UInt64(id))

    @always_inline
    def union(self, other: RelationSet) -> RelationSet:
        return RelationSet(self.bits | other.bits)

    @always_inline
    def intersects(self, other: RelationSet) -> Bool:
        return (self.bits & other.bits) != UInt64(0)

    @always_inline
    def contains(self, id: Int) -> Bool:
        return (self.bits & (UInt64(1) << UInt64(id))) != UInt64(0)

    @always_inline
    def count(self) -> Int:
        # pop_count is available via std.bit but we don't need it on the
        # hot path -- greedy tops out at O(n^2) for n<=64 relations.
        var v = self.bits
        var c = 0
        while v != UInt64(0):
            v &= v - UInt64(1)
            c += 1
        return c

    @always_inline
    def remove(self, id: Int) -> RelationSet:
        return RelationSet(self.bits & ~(UInt64(1) << UInt64(id)))

    @always_inline
    def is_empty(self) -> Bool:
        return self.bits == UInt64(0)

    def iter(self) -> List[Int]:
        """Return the sorted list of set-bit indices (relation ids).

        Port of v0.3 `RelationSet::iter`. Mojo 0.26 has
        no first-class iterator protocol that composes well with struct
        methods, so the helper materializes a small `List[Int]` instead.
        For DPccp (not in this tree) n <= 12 means at most 12 entries per
        call — the alloc cost is negligible next to DP hashing, and the explicit list
        sidesteps the `ref` / self-lifetime gymnastics an iterator would
        require.
        """
        var out = List[Int]()
        var v = self.bits
        var idx = 0
        while v != UInt64(0):
            if (v & UInt64(1)) != UInt64(0):
                out.append(idx)
            v >>= UInt64(1)
            idx += 1
        return out^


# =============================================================================
# JoinRelation / JoinEdge / JoinChain
# =============================================================================

struct JoinRelation(Movable):
    """A leaf relation in a flattened INNER-join chain.

    Fields:
        id: Dense 0-based id assigned at extraction time. Used as a bit
            position in `RelationSet`.
        plan: Deep-copied LogicalPlan subtree for this leaf. Held via
            OwnedPointer because LogicalPlan is Movable-only and cannot
            be stored directly in a Movable container field that must be
            move-initialized from a `var` parameter.
        cardinality: Estimated output rows for this leaf, computed once
            by `estimate_cardinality` at extraction time.
        table_stats: Per-column NDV (and null_count / min / max) sourced
            from the Parquet footer when the leaf walks down to a
            `PLAN_SCAN(SOURCE_PARQUET)` that has stats populated. None
            means stats unavailable. Consumed by
            `estimate_join_cardinality_with_ndv` to apply the FK-PK
            formula `(L*R)/max(NDV(lk), NDV(rk))`.
    """

    var id: Int
    var plan: OwnedPointer[LogicalPlan]
    var cardinality: Int
    var table_stats: Optional[TableStats]

    def __init__(
        out self,
        id: Int,
        var plan: LogicalPlan,
        cardinality: Int,
        var table_stats: Optional[TableStats] = None,
    ):
        self.id = id
        self.plan = OwnedPointer(plan^)
        self.cardinality = cardinality
        self.table_stats = table_stats^

struct JoinEdge(Movable):
    """An equi-join edge connecting two relations in a JoinChain.

    `left_relation` and `right_relation` are ids assigned during
    extraction (dense 0..n-1). The key lists are stored in the order
    they appeared in the original JOIN nodes; `collect_connecting_keys`
    flips them when the edge direction is reversed relative to the
    current sub-join set.

    Movable-only (not Copyable). Callers read edges via `ref e = edges[i]`
    so that the two owned `List[String]`s do not get duplicated.
    """

    var left_relation: Int
    var right_relation: Int
    var left_keys: List[String]
    var right_keys: List[String]

    def __init__(
        out self,
        left_relation: Int,
        right_relation: Int,
        var left_keys: List[String],
        var right_keys: List[String],
    ):
        self.left_relation = left_relation
        self.right_relation = right_relation
        self.left_keys = left_keys^
        self.right_keys = right_keys^

struct JoinChain(Movable):
    """A flattened chain of INNER joins as relations + edges.

    Produced by `extract_join_chain` from a LogicalPlan subtree rooted
    at a JOIN_INNER node. `greedy_join_order` consumes the chain and
    returns a reordered LogicalPlan.
    """

    var relations: Slab[JoinRelation]
    var edges: Slab[JoinEdge]

    def __init__(out self):
        self.relations = Slab[JoinRelation]()
        self.edges = Slab[JoinEdge]()

# =============================================================================
# Schema ownership lookup
# =============================================================================


def _schema_has_all_columns(schema: Schema, columns: List[String]) -> Bool:
    """Return True iff all `columns` are present in `schema` by name."""
    if len(columns) == 0:
        return False
    var n = schema.num_columns()
    for i in range(len(columns)):
        var target = columns[i]
        var found = False
        for j in range(n):
            if schema.field_name(j) == target:
                found = True
                break
        if not found:
            return False
    return True


def find_relation_owning_columns(
    relations: Slab[JoinRelation],
    start: Int,
    end: Int,
    columns: List[String],
) -> Int:
    """Find the relation in relations[start:end] whose schema contains ALL
    `columns`. Returns the *offset relative to `start`* on success, -1
    otherwise.

    Ports v0.3 `find_relation_owning_columns`. The
    Mojo version takes an explicit [start, end) slice because
    Slab does not support Rust-style subslices.
    """
    if len(columns) == 0 or start >= end:
        return -1
    for offset in range(end - start):
        var idx = start + offset
        # Bind via `ref` to avoid implicit copy of the Schema, which is
        # Movable-only. The reference is tied to relations' backing
        # buffer and stays valid for the duration of the lookup.
        ref rel_plan = relations[idx].plan[]
        if _schema_has_all_columns(rel_plan.output_schema, columns):
            return offset
    return -1


# =============================================================================
# extract_join_chain -- flatten an INNER-join subtree
# =============================================================================


@always_inline
def _is_rename_free_passthrough_project(plan: LogicalPlan) -> Bool:
    """Return True iff `plan` is a Project that is safe to pierce in
    `_extract_join_chain_inner`.

    A Project is pierce-safe when ALL of the following hold:
      1. tag == PLAN_PROJECT.
      2. exprs is non-empty.
      3. EVERY output expr is EXPR_COL_REF (no aliases / derived / lits).
      4. EVERY output col_ref name exists in the child schema by name.
      5. NO two outputs share the same col_ref name (no duplicates).

    Such a Project is a column-subset / column-reorder over its child --
    it does NOT introduce new column names downstream. This is the only
    Project shape we can safely "pierce" in `_extract_join_chain_inner`,
    because the chain-rebuild side (`greedy_join_order`) walks the leaf
    relations purely by NAME -- if a leaf's column is renamed by a
    pierced Project, the rebuild's `find_relation_owning_columns` lookup
    would silently fail and the greedy order would skew toward
    representative-id fallbacks.

    Allowlist:
      Case 1 (reorder-only)        -- PIERCED. Names exist in child.
      Case 2 (drop-col, non-key)   -- PIERCED. Schema widens at the
                                       leaf; pierce widening is safe.
      Case 3 (drop-col, IS key)    -- VACUOUS in well-formed IR. A
                                       parent join key references the
                                       Project's OUTPUT, so a column the
                                       Project drops cannot be a parent
                                       key.
      Case 4 (rename-only Alias)   -- NOT pierced (deferred).
                                       Pierce-with-rename-rewrite would
                                       require threading a rename map
                                       through the chain extractor +
                                       rewriting outer-join keys; it is
                                       a strict-superset feature.
      Case 5 (computed)            -- NOT pierced. New name not in leaf.
      Edge 1 (added literal)       -- NOT pierced (tag != COL_REF).
      Edge 2 (CAST/STRING_OP/CASE) -- NOT pierced (tag != COL_REF).
      Edge 4 (duplicate names)     -- NOT pierced. Pierce would silently
                                       dedupe to the leaf's single
                                       occurrence; downstream consumers
                                       depending on schema width would
                                       observe a mismatch.

    CRITICAL: only EXPR_COL_REF outputs are safe to pierce. Any other
    tag (EXPR_ALIAS, EXPR_BINARY_OP, EXPR_LITERAL, EXPR_CAST,
    EXPR_STRING_OP, EXPR_WHEN, EXPR_UNARY_OP, EXPR_COL_IDX) introduces
    a name or transformation that does NOT exist in the leaf schema.
    DO NOT relax this check without re-checking every case of the
    allowlist above.

    Concrete examples:
      Project([col_ref("a"), col_ref("b")], child)         -- PIERCED
      Project([alias(col_ref("a"), "x")], child)           -- NOT pierced (rename)
      Project([col_ref("a") + lit(1)], child)              -- NOT pierced (derived)
      Project([col_ref("a"), col_ref("b") + col_ref("c")], child) -- NOT pierced
      Project([col_ref("a"), col_ref("a")], child)         -- NOT pierced (duplicate)

    TODO: rename-pierce. If benchmark data shows a
    residual rename-Project pattern that breaks join chains, extend
    pierce to Alias-only Projects by threading a rename map through
    `_extract_join_chain_inner` and rewriting outer-join keys (Case 4
    above).
    """
    if plan.tag != PLAN_PROJECT:
        return False
    ref pdata = plan._project.value()[]
    var n = len(pdata.exprs)
    if n == 0:
        return False
    ref child_schema = pdata.child[].output_schema
    for i in range(n):
        # CRITICAL: only EXPR_COL_REF outputs are safe to pierce. See
        # the allowlist comment above before relaxing this check.
        if pdata.exprs[i].tag != EXPR_COL_REF:
            return False
        var name = pdata.exprs[i].col_ref_name()
        # Rename-free means the col_ref name must exist in the child
        # schema. (A rename via Alias would have tag == EXPR_ALIAS,
        # already filtered above. We additionally require that the
        # output name == the child name -- by construction of
        # `LogicalPlan.project`, a bare ColRef carries the same field
        # name as the source field, so the schema lookup at position
        # `i` against `child_schema` already matches.)
        var found = False
        for j in range(child_schema.num_columns()):
            if child_schema.field_name(j) == name:
                found = True
                break
        if not found:
            return False
    # Reject Projects with duplicate output column names (Edge 4 of
    # the allowlist above). Pierce would silently collapse the duplicate
    # outputs to the leaf's single occurrence of the column; a
    # downstream operator that depended on the schema width (e.g. an
    # ordinal-index consumer expecting two columns named "a") would
    # observe a different schema. O(n^2) over typical n < 20 outputs.
    for i in range(n):
        var name_i = pdata.exprs[i].col_ref_name()
        for j in range(i + 1, n):
            if pdata.exprs[j].col_ref_name() == name_i:
                return False
    return True


def _extract_join_chain_inner(
    var plan: LogicalPlan,
    mut relations: Slab[JoinRelation],
    mut edges: Slab[JoinEdge],
) raises:
    """Recursive helper for `extract_join_chain`.

    If `plan` is a JOIN_INNER node, recurse into both children and record
    an edge. If `plan` is a rename-free pass-through Project (every
    output expression is `EXPR_COL_REF` matching the child schema by
    name), pierce it and recurse into the child. Otherwise, `plan` is a
    leaf -- estimate its cardinality and append it as a new
    JoinRelation.

    Project-piercing is gated on `_is_rename_free_passthrough_project`
    to keep the rebuild safe: greedy_join_order walks leaves purely by
    column name, so any rename / derived expression in a pierced Project
    would invalidate downstream key lookups. See the helper docstring
    for the exact carve-out.

    Consumes `plan`.
    """
    # Project-pierce: a rename-free col-ref-only Project is a
    # column-subset / column-reorder that does not introduce new names
    # downstream, so the chain extractor can safely recurse INTO its
    # child. The Project node itself is dropped on the assumption that
    # downstream consumers reference columns by name -- the greedy
    # rebuild produces a superset schema (all leaf columns concatenated
    # at every join level), which preserves all referenced names.
    if _is_rename_free_passthrough_project(plan):
        var pierced_child = _copy_plan(plan._project.value()[].child[])
        _extract_join_chain_inner(pierced_child^, relations, edges)
        return

    # A residual-carrying (`predicate=` non-equi / range) INNER
    # join is NOT flattenable — flattening it through the chain would lose
    # the residual condition. Treat it as a leaf relation (the greedy
    # rebuild will place it whole, with its residual intact).
    #
    # SCOPE (M3 invariant): per-column edge split below
    # runs ONLY inside this JOIN_INNER + not has_residual() branch.
    # SEMI/ANTI/LEFT/RIGHT/FULL/CROSS/ASOF subtrees fall through to the
    # leaf-extract path at the end of this function (the whole subtree
    # is wrapped opaquely as one JoinRelation).
    if plan.tag == PLAN_JOIN and plan._join.value()[].join_type == JOIN_INNER \
       and not plan._join.value()[].has_residual():
        var left_start = len(relations)

        # Recurse into left. We copy the child before recursing so that
        # the original `plan` stays intact until we also extract its
        # right side and its keys. This mirrors the "take ownership of
        # children then take left_keys/right_keys" flow in v0.3.
        var left_child = _copy_plan(plan._join.value()[].left[])
        _extract_join_chain_inner(left_child^, relations, edges)
        var left_end = len(relations)

        var right_start = len(relations)
        var right_child = _copy_plan(plan._join.value()[].right[])
        _extract_join_chain_inner(right_child^, relations, edges)
        var right_end = len(relations)

        # ---------------------------------------------------------------
        # Per-column edge split.
        #
        # Without the split, the legacy path would emit
        # ONE JoinEdge per PLAN_JOIN carrying the full composite
        # left_on/right_on. For a composite like Q5's
        # (l_orderkey, l_suppkey) = (o_orderkey, s_suppkey), the cross-
        # name keys mis-route lineitem to whichever "orders subtree
        # representative" find_relation_owning_columns picks for the
        # composite. The per-column split below emits ONE JoinEdge per
        # (left_on[i], right_on[i]) index when each per-column key
        # resolves to a distinct base leaf in the recursed slices;
        # unresolved key indices fall back into a single composite
        # leftover edge (M2 invariant).
        #
        # CONTRACT (M1 invariant, load-bearing):
        # per-column edges from a single composite source MUST be
        # appended CONTIGUOUSLY in INDEX ORDER (i = 0, 1, 2, ...). The
        # rebuild side (collect_connecting_keys) walks
        # `edges` in Slab insertion order and aggregates keys; the
        # (lk[i], rk[i]) pairing is preserved by this aggregation
        # contract. The loop below satisfies M1 trivially because it
        # iterates `i` in ascending order and appends to `edges`
        # sequentially. ANY future "sort edges by cost" optimization
        # in the chain extractor would break this — guarded by
        # test_optimizer_reorder_multi_key_insertion_order.mojo.
        # ---------------------------------------------------------------
        ref jdata = plan._join.value()[]
        var n_keys = len(jdata.left_on)

        var leftover_lk = List[String]()
        var leftover_rk = List[String]()

        for i in range(n_keys):
            # Look up THIS single key's owning leaf within each recursed
            # slice. A per-column lookup succeeds (offset >= 0) when a
            # single leaf in the slice owns the per-column key by name.
            var single_lk = List[String]()
            single_lk.append(jdata.left_on[i])
            var single_rk = List[String]()
            single_rk.append(jdata.right_on[i])

            var left_off_i = find_relation_owning_columns(
                relations, left_start, left_end, single_lk
            )
            var right_off_i = find_relation_owning_columns(
                relations, right_start, right_end, single_rk
            )

            if left_off_i >= 0 and right_off_i >= 0:
                # Per-column edge. M1 invariant: i is monotonically
                # increasing AND `edges.append` preserves Slab insertion
                # order, so per-column edges from this composite are
                # appended contiguously in index order.
                var left_rel_id_i = left_start + left_off_i
                var right_rel_id_i = right_start + right_off_i
                var lk_one = List[String]()
                lk_one.append(jdata.left_on[i])
                var rk_one = List[String]()
                rk_one.append(jdata.right_on[i])
                edges.append(JoinEdge(
                    relations[left_rel_id_i].id,
                    relations[right_rel_id_i].id,
                    lk_one^,
                    rk_one^,
                ))
            else:
                # M2 invariant: per-column lookup failed for this key
                # index — defer it to the leftover composite edge below.
                # Common when an upstream Project introduces a derived
                # column that no base leaf owns by name, or when an
                # un-pierced rename hides the source column. Do NOT
                # split unresolvable keys further — they need the
                # composite-fallback shape to keep find_relation_owning
                # _columns from regressing to the multi-leaf-miss case
                # the legacy path handled.
                leftover_lk.append(jdata.left_on[i])
                leftover_rk.append(jdata.right_on[i])

        if len(leftover_lk) > 0:
            # M2 invariant: leftover composite preserves correctness.
            # collect_connecting_keys still aggregates correctly because
            # per-column edges contribute their single keys + the
            # leftover edge contributes the remaining keys = the
            # original composite. No key duplication because leftover_lk
            # only contains keys whose per-column lookup FAILED.
            #
            # The leftover edge follows the legacy fallback logic:
            # find_relation_owning_columns over the full leftover list
            # against each side's recursed slice; if no single leaf owns
            # the full leftover list, fall back to start-of-slice
            # representative ids (mirrors the legacy behavior).
            var leftover_left_off = find_relation_owning_columns(
                relations, left_start, left_end, leftover_lk
            )
            var leftover_left_rel_id: Int
            if leftover_left_off >= 0:
                leftover_left_rel_id = left_start + leftover_left_off
            else:
                leftover_left_rel_id = left_start

            var leftover_right_off = find_relation_owning_columns(
                relations, right_start, right_end, leftover_rk
            )
            var leftover_right_rel_id: Int
            if leftover_right_off >= 0:
                leftover_right_rel_id = right_start + leftover_right_off
            else:
                leftover_right_rel_id = right_start

            edges.append(JoinEdge(
                relations[leftover_left_rel_id].id,
                relations[leftover_right_rel_id].id,
                leftover_lk^,
                leftover_rk^,
            ))
        return

    # Cross-flatten: a bridge-less JOIN_CROSS (empty
    # left_on/right_on, no residual) is an ACCIDENTAL cartesian produced by
    # the SQL frontend's left-deep comma-join build when two adjacent FROM
    # tables share no direct WHERE equi-predicate. Q9's canonical shape is
    # `FROM part, supplier, lineitem, ...` — part and supplier connect ONLY
    # through lineitem (`p_partkey = l_partkey` AND `s_suppkey = l_suppkey`),
    # so the frontend emits `part × supplier` as a CROSS at the bottom of the
    # left-deep tree and `eliminate_cross_join` correctly can NOT fold it (no
    # bridging conjunct exists between the two). Treating that CROSS as an
    # opaque leaf makes the reordered plan materialize the full ~200K×10K
    # cartesian below the selective lineitem FK join.
    #
    # Instead FLATTEN it: recurse into BOTH children as separate leaves
    # WITHOUT emitting an edge between them. The cross-sides then reconnect to
    # the chain through the per-column edges of the OTHER joins (the
    # `(part×supplier) ⋈ lineitem` composite splits into part↔lineitem +
    # supplier↔lineitem via the per-column split above), plus
    # `derive_transitive_edges` densification where a caller runs it (this
    # module does not), so greedy rebuilds a proper join tree instead of
    # the cartesian.
    #
    # Correctness in the genuine-cross case is preserved by the existing
    # guards: if the flattened relations are truly disconnected (a real cross
    # product with no bridging FK anywhere), `extract_join_chain` yields 0
    # edges and returns None (caller keeps the original CROSS), OR greedy's
    # CROSS fallback rebuilds a valid tree. (DPccp's cross-product augmentation
    # and a guard against an unsafe synthesized top CROSS are not in this tree.)
    # A residual-carrying CROSS (cross+non-equi predicate) is NOT flattened —
    # it falls through to the opaque-leaf path below, preserving the residual.
    if plan.tag == PLAN_JOIN and plan._join.value()[].join_type == JOIN_CROSS \
       and not plan._join.value()[].has_residual():
        var cross_left = _copy_plan(plan._join.value()[].left[])
        _extract_join_chain_inner(cross_left^, relations, edges)
        var cross_right = _copy_plan(plan._join.value()[].right[])
        _extract_join_chain_inner(cross_right^, relations, edges)
        return

    # Leaf: any non-INNER-join node becomes a base relation. Walk down
    # through pure-passthrough nodes (Project, Filter) to find a SCAN
    # and copy its `table_stats` onto the JoinRelation.
    #
    # After `estimate_cardinality` applies the
    # filter's predicate-aware selectivity, cap each column's NDV at
    # the post-filter cardinality via
    # `scale_table_stats_for_selectivity`. DuckDB mirrors this
    # behavior — a column cannot have more distinct values than there
    # are surviving rows (see `relation_statistics_helper.cpp`). This
    # is load-bearing for the composite-NDV graph in `optimizer_tdom`:
    # under a post-filter `part` shrunk 200K→40K, `part.p_partkey` NDV
    # must scale from 200K→40K so the per-bucket denominator reflects
    # the narrower equivalence-class TDOM.
    var card = estimate_cardinality(plan)
    var ts = _find_leaf_table_stats(plan)
    if ts and card >= 1:
        ts = Optional[TableStats](
            scale_table_stats_for_selectivity(ts.value().copy(), card)
        )
    var new_id = len(relations)
    relations.append(JoinRelation(new_id, plan^, card, ts^))


def _find_leaf_table_stats(plan: LogicalPlan) -> Optional[TableStats]:
    """Walk down a leaf subtree to find a Parquet SCAN's table_stats.

    The chain extractor's leaves are typically Scan, Filter(Scan),
    Project(Scan), or Project(Filter(Scan)). Aggregate / sort / topn
    leaves do not have meaningful per-input-column NDV (they're
    intermediate results), so we stop and return None.
    """
    if plan.tag == PLAN_SCAN and plan._scan:
        if plan._scan.value()[].table_stats:
            return Optional[TableStats](
                plan._scan.value()[].table_stats.value().copy()
            )
        return None
    if plan.tag == PLAN_FILTER and plan._filter:
        return _find_leaf_table_stats(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT and plan._project:
        return _find_leaf_table_stats(plan._project.value()[].child[])
    return None


def extract_join_chain(var plan: LogicalPlan) raises -> Optional[JoinChain]:
    """Flatten a JOIN_INNER subtree into a JoinChain.

    Returns `None` if the tree yields fewer than 2 relations, fewer than
    1 edge, or more than MAX_RELATIONS_FOR_REORDER relations. In any of
    these cases the caller falls back to the unoptimized plan.

    Consumes `plan` on success.
    """
    var chain = JoinChain()
    _extract_join_chain_inner(plan^, chain.relations, chain.edges)

    if len(chain.relations) < 2:
        return None
    if len(chain.edges) == 0:
        return None
    if len(chain.relations) > MAX_RELATIONS_FOR_REORDER:
        return None
    return Optional[JoinChain](chain^)


# =============================================================================
# Cost model for the greedy search
# =============================================================================


@always_inline
def estimate_join_cardinality_for_reorder(left_card: Int, right_card: Int) -> Int:
    """Conservative join cardinality fallback when no per-key NDV is known.

    v0.3 uses `(l * r) / max(distinct(l, left_keys), distinct(r, right_keys))`
    which, when per-column distinct counts are unknown, collapses to
    `(l * r) / min(l, r)` = `max(l, r)`. The NDV-aware variant lives
    at `estimate_join_cardinality_with_ndv` below; callers reach for the
    aware version when both sides carry `Optional[TableStats]`, and fall
    through to this max-based fallback otherwise.
    """
    var mx = left_card
    if right_card > mx:
        mx = right_card
    if mx < 1:
        mx = 1
    return mx


@always_inline
def _max_ndv_across_keys(
    stats: TableStats, key_names: List[String]
) -> Optional[Int]:
    """Return max(NDV(k) for k in key_names) when ALL keys have NDV.

    Returns None when any key is missing or has no writer-emitted
    distinct_count. The "max" choice mirrors v0.3 behavior. A
    missing NDV on ANY key means we cannot compute a sound (L*R)/NDV
    estimate (the formula assumes all join keys are equi-joined and
    each contributes); returning None correctly signals "fall through".

    CONTRACT: the per-column edge split
    feeds this helper SINGLE-key `key_names` lists on the common path
    (one key per JoinEdge). When `len(key_names) == 1`, this function
    collapses to "NDV of that single column". The multi-key composite
    path is reserved for the leftover-fallback edge (M2 invariant)
    and is known to over-estimate via max() across keys; the TDOM
    equivalence classes (`optimizer_tdom`)
    replace the max() denominator with a TDOM-aware estimator at
    cost-compute time and are the canonical fix for composite
    denominators. Here the per-column path uses
    single-key NDV (sound, tighter than max across composites)
    and the leftover composite path uses the legacy max-across-keys
    (loose, but only affects keys whose per-column lookup failed).
    """
    if len(key_names) == 0:
        return None
    var best: Int = 0
    for i in range(len(key_names)):
        var dc_opt = stats.column_distinct_count(key_names[i])
        if not dc_opt:
            return None
        var dc = dc_opt.value()
        if dc <= 0:
            return None
        if dc > best:
            best = dc
    if best <= 0:
        return None  # cov: unreachable key_names is non-empty and every dc is above 0, so best is above 0
    return Optional[Int](best)


def estimate_join_cardinality_with_ndv(
    left_card: Int,
    right_card: Int,
    left_stats_opt: Optional[TableStats],
    right_stats_opt: Optional[TableStats],
    left_keys: List[String],
    right_keys: List[String],
) -> Int:
    """NDV-aware join cardinality estimate.

    Implements v0.3 `estimate_join_cardinality_for_reorder`
    via the FK-PK formula:

        |L joined R| approx (|L| * |R|) / max(NDV(L, lk), NDV(R, rk))

    When both sides have writer-emitted NDV, this captures the correct
    intuition for foreign-key joins: a small dimension table joining a
    big fact table on the FK column produces ~|fact| rows, but joining
    on a low-NDV column (e.g. customer.c_nationkey with only ~25 distinct
    values out of 150K rows) produces a Cartesian-shaped fanout
    `(150K * 2K) / 25 = 12M`, NOT `max(150K, 2K) = 150K`. The latter
    is what the max-based fallback returns, which ranks such a low-NDV
    join as cheap and orders it early instead of a higher-NDV path.

    The CLAMP `min(NDV, side_card)` is load-bearing: writer-emitted
    distinct_count is summed across row groups (over-estimate), and
    even an exact NDV can exceed the relation's current cardinality
    after a filter. Without the clamp, divisor > L produces
    (L*R)/divisor < R, which is sub-physical for the FK-PK shape
    (a join cannot produce fewer rows than the smaller side's
    matched-key count). That sub-physical estimate would make a
    cost-based enumerator (DPccp, not in this tree) rank candidate joins
    by the WRONG metric and pick worse plans.

    Algorithm:
      1. For each side, compute clamped_ndv = min(max_NDV, side_card).
      2. Divisor = max(clamped_left_ndv, clamped_right_ndv); if neither
         side has stats, fall through to legacy max(l, r).
      3. Saturating product to avoid Int overflow on large multiplies.
      4. result = max(1, prod / divisor).
    """
    var clamped_l: Int = 0
    var clamped_r: Int = 0
    if left_stats_opt:
        var ndv_l = _max_ndv_across_keys(left_stats_opt.value(), left_keys)
        if ndv_l:
            var v = ndv_l.value()
            if left_card > 0 and v > left_card:
                v = left_card
            clamped_l = v
    if right_stats_opt:
        var ndv_r = _max_ndv_across_keys(right_stats_opt.value(), right_keys)
        if ndv_r:
            var v = ndv_r.value()
            if right_card > 0 and v > right_card:
                v = right_card
            clamped_r = v

    var divisor = clamped_l
    if clamped_r > divisor:
        divisor = clamped_r

    if divisor <= 0:
        return estimate_join_cardinality_for_reorder(left_card, right_card)

    var lc = left_card
    var rc = right_card
    if lc < 1: lc = 1
    if rc < 1: rc = 1
    var prod: Int
    if lc >= REORDER_CARDINALITY_MAX // rc:
        prod = REORDER_CARDINALITY_MAX
    else:
        prod = lc * rc
    var est = prod // divisor
    if est < 1:
        est = 1
    return est


def find_connecting_edge(
    left_set: RelationSet,
    right_set: RelationSet,
    edges: Slab[JoinEdge],
) -> Int:
    """Return the index of the first edge connecting `left_set` and
    `right_set`, or -1 if none exists. An edge connects the sets iff one
    endpoint is in `left_set` and the other is in `right_set`.
    """
    for i in range(len(edges)):
        # `ref` binding avoids an implicit copy of the JoinEdge (it
        # owns two List[String]s which are non-trivial to copy).
        ref e = edges[i]
        var lc = left_set.contains(e.left_relation)
        var rc = right_set.contains(e.right_relation)
        var rc2 = left_set.contains(e.right_relation)
        var lc2 = right_set.contains(e.left_relation)
        if (lc and rc) or (rc2 and lc2):
            return i
    return -1


struct JoinKeyPair(Movable):
    """Pair of left/right key lists returned from `collect_connecting_keys`.

    Not a tuple because Mojo 0.26.3 tuple support is limited and not all
    code generators accept returning a tuple by value. A small struct is
    unambiguous.
    """
    var left: List[String]
    var right: List[String]

    def __init__(out self, var left: List[String], var right: List[String]):
        self.left = left^
        self.right = right^

def collect_connecting_keys(
    left_set: RelationSet,
    right_set: RelationSet,
    edges: Slab[JoinEdge],
) -> JoinKeyPair:
    """Collect join keys from all edges that connect `left_set` and
    `right_set`. When an edge's natural direction is reversed relative
    to the running sub-join (i.e. edge.left is in right_set), the
    returned key lists are flipped to keep `left_keys[i]` in
    `left_set`'s schema.

    Mirrors v0.3 `collect_connecting_keys`.

    CONTRACT (M1 invariant): the per-column
    edge split in `_extract_join_chain_inner` emits
    per-column edges from one composite source CONTIGUOUSLY in INDEX
    ORDER. This function walks `edges` in Slab insertion order and
    aggregates keys; the (lk[i], rk[i]) pairing across a composite
    source is preserved by this walk + aggregation. Any future
    optimization that re-sorts `edges` (e.g. "sort edges by cost")
    between chain extraction and rebuild WOULD CORRUPT the key
    pairing — the rebuild would silently produce a physically valid
    but semantically wrong join shape. This invariant is regression-
    tested by:
        tests/test_optimizer_reorder_multi_key_insertion_order.mojo
    Do NOT re-order `edges` between extract and rebuild.
    """
    var lk = List[String]()
    var rk = List[String]()
    for i in range(len(edges)):
        ref e = edges[i]
        if left_set.contains(e.left_relation) and right_set.contains(e.right_relation):
            for k in range(len(e.left_keys)):
                lk.append(e.left_keys[k])
                rk.append(e.right_keys[k])
        elif left_set.contains(e.right_relation) and right_set.contains(e.left_relation):
            for k in range(len(e.right_keys)):
                lk.append(e.right_keys[k])
                rk.append(e.left_keys[k])
    return JoinKeyPair(lk^, rk^)


# =============================================================================
# Greedy search
# =============================================================================


def _take_smallest_relation(mut relations: Slab[JoinRelation]) -> JoinRelation:
    """Remove and return the relation with the smallest cardinality.

    Ties are broken by the relation's original id (the insertion
    order), which makes this a stable selection when called
    repeatedly. O(n) per call; callers use it for an O(n^2) sort
    over at most MAX_RELATIONS_FOR_REORDER (=64) elements.

    This is the only sorting primitive we need for greedy -- we
    don't actually want the whole array sorted, just to pull the
    smallest one out at the start.
    """
    var n = len(relations)
    debug_assert(n > 0, "_take_smallest_relation on empty array")
    var best = 0
    for i in range(1, n):
        var c = relations[i].cardinality
        var bc = relations[best].cardinality
        if c < bc:
            best = i
        elif c == bc and relations[i].id < relations[best].id:
            best = i
    return relations.swap_remove(best)


def greedy_join_order(var chain: JoinChain) raises -> LogicalPlan:
    """Build a join tree by greedy smallest-intermediate-first.

    Ports v0.3 `greedy_join_order`. Panics at runtime
    if the chain has <2 relations -- the caller must verify this in
    `extract_join_chain`.

    Cost model: legacy `max(l, r)` fallback via
    `estimate_join_cardinality_for_reorder`. The NDV-aware path
    (`estimate_join_cardinality_with_ndv`) is the DPccp cost function
    (`optimizer_dpccp._cost_for_pair`, not in this tree); greedy
    intentionally does NOT consume it. Multi-way reordering is designed to
    go through DPccp (n>=4 chains); greedy serves the n<4 fallback path,
    where the small chain shape makes the FK-PK cost signal moot.
    """
    var first = _take_smallest_relation(chain.relations)
    var current_set = RelationSet.singleton(first.id)
    var current_card = first.cardinality
    var current_plan = _copy_plan(first.plan[])

    while len(chain.relations) > 0:
        var best_pos = -1
        var best_card: Int = REORDER_CARDINALITY_MAX

        for pos in range(len(chain.relations)):
            var rel_id = chain.relations[pos].id
            var rel_set = RelationSet.singleton(rel_id)
            var edge_idx = find_connecting_edge(
                current_set, rel_set, chain.edges
            )
            if edge_idx >= 0:
                var jc = estimate_join_cardinality_for_reorder(
                    current_card, chain.relations[pos].cardinality
                )
                if jc < best_card:
                    best_card = jc
                    best_pos = pos

        var pick_pos: Int
        if best_pos >= 0:
            pick_pos = best_pos
        else:
            pick_pos = 0  # CROSS-join fallback

        var next_rel = chain.relations.swap_remove(pick_pos)
        var next_set = RelationSet.singleton(next_rel.id)
        var keys = collect_connecting_keys(
            current_set, next_set, chain.edges
        )
        var lk = keys.left.copy()
        var rk = keys.right.copy()
        var next_plan = _copy_plan(next_rel.plan[])
        var next_card = next_rel.cardinality

        if len(lk) == 0:
            # CROSS join: no connecting edge.
            var empty_l = List[String]()
            var empty_r = List[String]()
            current_plan = LogicalPlan.join(
                current_plan^, next_plan^, empty_l^, empty_r^, JOIN_CROSS
            )
            var prod: Int
            if current_card >= REORDER_CARDINALITY_MAX // max(next_card, 1):
                prod = REORDER_CARDINALITY_MAX
            else:
                prod = current_card * next_card
            current_card = prod
        else:
            var jc = estimate_join_cardinality_for_reorder(
                current_card, next_card
            )
            current_plan = LogicalPlan.join(
                current_plan^, next_plan^, lk^, rk^, JOIN_INNER
            )
            current_card = jc

        current_set = current_set.union(next_set)

    return current_plan^


# =============================================================================
# reorder_joins -- top-level driver
# =============================================================================


def reorder_joins(var plan: LogicalPlan) raises -> LogicalPlan:
    """Walk the plan tree and reorder each maximal INNER-join subtree.

    For non-join nodes we recurse into children. For a JOIN_INNER node we
    first reorder both children (so any nested chains become part of the
    outer chain's leaves), then extract and apply greedy.

    For non-INNER joins (LEFT / RIGHT / FULL / SEMI / ANTI / CROSS)
    we only recurse -- they're reorder barriers because their semantics
    depend on side.
    """
    var tag = plan.tag

    if tag == PLAN_JOIN:
        var jt = plan._join.value()[].join_type
        # A residual-carrying (`predicate=` non-equi / range)
        # join is a reorder barrier — flattening it into a chain would
        # lose the residual. Recurse into children, rebuild PRESERVING
        # the residual.
        var has_resid = plan._join.value()[].has_residual()
        if jt == JOIN_INNER and not has_resid:
            # Recurse into both children so nested inner joins are
            # already flattened-then-reordered before we attempt to
            # extract this chain.
            var left = _take_join_left(plan)
            var right = _take_join_right(plan)
            var new_left = reorder_joins(left^)
            var new_right = reorder_joins(right^)
            var lk = plan._join.value()[].left_on.copy()
            var rk = plan._join.value()[].right_on.copy()
            var rebuilt = LogicalPlan.join(
                new_left^, new_right^, lk^, rk^, JOIN_INNER
            )

            # `extract_join_chain` consumes its input. For a well-formed
            # INNER-join tree (which is what this branch handles), extraction
            # yields >= 2 relations because both children of `rebuilt`
            # contribute at least one leaf, but it still returns None when
            # the chain has no edge or more than MAX_RELATIONS_FOR_REORDER
            # relations.
            #
            # We must copy `rebuilt` before passing it to
            # extract_join_chain so we can return the unchanged plan if
            # extraction declines. The copy cost is a one-time deep copy
            # over each inner-join chain root in the plan tree.
            var rebuilt_copy = _copy_plan(rebuilt)
            var maybe_chain = extract_join_chain(rebuilt^)
            if maybe_chain:
                var chain = maybe_chain.take()
                return greedy_join_order(chain^)
            return rebuilt_copy^

        # Non-INNER (or residual-carrying) join: recurse into children
        # and rebuild, preserving the residual.
        var algo = plan._join.value()[].algo_hint
        var residual: Optional[OwnedPointer[Expr]] = None
        if has_resid:
            residual = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        var left = _take_join_left(plan)
        var right = _take_join_right(plan)
        var new_left = reorder_joins(left^)
        var new_right = reorder_joins(right^)
        var lk = plan._join.value()[].left_on.copy()
        var rk = plan._join.value()[].right_on.copy()
        return LogicalPlan.join(
            new_left^, new_right^, lk^, rk^, jt, algo, residual^,
        )

    # Non-JOIN cases mutate the parent's child OwnedPointer in
    # place instead of rebuilding the parent wrapper Schema. The JOIN
    # case (above) still rebuilds because we may swap join order via
    # greedy_join_order.
    elif tag == PLAN_FILTER:
        var child_in = _copy_plan(plan._filter.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._filter.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_PROJECT:
        var child_in = _copy_plan(plan._project.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._project.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_AGGREGATE:
        var child_in = _copy_plan(plan._aggregate.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._aggregate.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_SORT:
        var child_in = _copy_plan(plan._sort.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._sort.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_LIMIT:
        var child_in = _copy_plan(plan._limit.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._limit.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_DISTINCT:
        var child_in = _copy_plan(plan._distinct.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._distinct.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_TOPN:
        var child_in = _copy_plan(plan._topn.value()[].child[])
        var new_child = reorder_joins(child_in^)
        plan._topn.value()[].child = OwnedPointer(new_child^)

    # PLAN_SCAN and unknown tags: no children to recurse into.
    return plan^
