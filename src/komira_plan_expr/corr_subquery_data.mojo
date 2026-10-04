# =============================================================================
# corr_subquery_data — `EXPR_CORRELATED_SUBQUERY`'s payload, WITHOUT the plan
# =============================================================================
#
# ⭐ THIS MODULE IS THE CUT. It is the reason `plan/expr.mojo` does not name
# `LogicalPlan`, and therefore the reason `Expr` can be a leaf type.
#
# ── WHY IT IS SEPARATE ──────────────────────────────────────────────────────
# If `CorrelatedSubqueryData` held a `var inner_plan: OwnedPointer[LogicalPlan]`
# field, `expr.mojo` would have to import it (plus `LogicalPlan` itself, plus
# the four `CORR_KIND_*`) out of `logical_plan.mojo`, and that single import
# line would pull most of `komira_core` into `Expr`'s translation-unit closure:
#
#     closure(plan/expr.mojo), komira_core-restricted, seed included
#       with the `logical_plan` edge .......................... 90
#       with the `logical_plan` edge cut ...................... 59
#       with `logical_plan` AND `partition_expr` cut ...........  7
#
# `logical_plan.mojo` and `logical_plan_variants.mojo` RE-EXPORT every name
# declared here, so `from komira_plan_ir.logical_plan import
# CorrelatedSubqueryData` / `CORR_KIND_SCALAR` / ... resolves.
#
# ── HOW THE PLAN IS HELD ────────────────────────────────────────────────────
# `_plan: ErasedBox` — a heap-owning, DEEP-COPYABLE, type-erased home
# (`erased_box.mojo`, which imports only `std.memory`). The plan is OWNED
# by this payload and DEEP-CLONED on copy; this module just cannot SAY what it
# owns. `plan/corr_subquery.mojo` — which
# may name `LogicalPlan` — is the one place that boxes and unboxes it.
#
# ⛔ IT IS NOT A HANDLE AND THERE IS NO REGISTRY. Do not "improve" it into one.
# A registry would make two `Expr` copies share one plan, and
# `scan_binding_bind_pass.bind_plan_inmem_payloads(registry, mut plan)` MUTATES
# a subquery's inner plan in place — so shared ownership is a silent
# cross-expression mutation, not an optimisation. It would also import an ABA
# generation, an eviction policy and a thread story that this shape does not
# need. The full comparison is in `erased_box.mojo`'s header.
#
# ── ⚠ `inner_tag` IS DENORMALISED ON PURPOSE ────────────────────────────────
# `Expr.write_to` prints `inner_tag=<n>` for EXPLAIN, and `Expr.structural_hash`
# is FNV-1a over that text. Reading it off the live plan would need
# `LogicalPlan`, i.e. the edge back. It is a `UInt8` copied at construction from
# the plan being boxed, and the ONE place that can set it is
# `corr_subquery.make_correlated_subquery_data`.
#
# ⚠⚠ AND THE RENDER IS WEAKER THAN IT LOOKS.
# The render is `kind`, `len(outer_refs)` and `inner_tag`, so two
# subqueries differing only in their inner plan hash identically and
# `plan_cse` can share them. That is a known defect of the render, not of
# the erasure. Do not read the
# denormalised field as having introduced it, and do not close it by removing
# the field — close it by rendering MORE (the inner plan's own structural hash),
# which is a job for `corr_subquery.mojo`, the module that can see the plan.
# =============================================================================

from komira_plan_expr.erased_box import ErasedBox, DeepCopyable, make_erased_box


# =============================================================================
# CorrelatedSubquery kind constants
# =============================================================================
#
# Declared here (and re-exported by `logical_plan.mojo`) because `Expr`
# needs them and they are four `UInt8`s — nothing about them requires the
# plan module. Discriminant for `CorrelatedSubqueryData.kind`; selects the
# lowering shape `flatten_dependent_joins` produces:
#   - CORR_KIND_EXISTS         → JOIN_SEMI
#   - CORR_KIND_NOT_EXISTS     → JOIN_ANTI
#   - CORR_KIND_SCALAR         → JOIN_LEFT + agg sink (Q17 shape)
#   - CORR_KIND_IN_CORRELATED  → JOIN_SEMI with the IN-list equi-key appended (Q20)

comptime CORR_KIND_EXISTS: UInt8 = 0
comptime CORR_KIND_NOT_EXISTS: UInt8 = 1
comptime CORR_KIND_SCALAR: UInt8 = 2
comptime CORR_KIND_IN_CORRELATED: UInt8 = 3


comptime CORR_SUBQ_PLAN_TYPE_TAG: UInt32 = 0xC0BB1A01
"""The `ErasedBox` type tag for a boxed `LogicalPlan`.

⚠ The box's bytes carry no type, so this constant IS the check. Every unbox
compares it and RAISES on a mismatch (`corr_subquery.corr_data_inner_plan_ref`);
a second boxed type in this tree needs its OWN tag, never this one."""


trait BoxablePlan(DeepCopyable):
    """What a type must offer to be BOXED as a correlated subquery's inner plan.

    ⭐ THIS TRAIT KEEPS CONSTRUCTION A METHOD ON `Expr`.
    `Expr.correlated_subquery(...)` is a static method on `Expr` that is
    PARAMETRIC over `P: BoxablePlan`; `P` is INFERRED from the argument, so
    `Expr.correlated_subquery(inner_plan^, refs^, kind)` reads naturally at
    every construction site without a free function in a plan-layer module.

    ⚠ IT IS A COMPTIME BOUND, NOT STORED. Nothing here is dynamic dispatch (Mojo
    1.0.0 has none), and conforming costs `LogicalPlan` two inlineable methods
    and zero bytes.

    `erased_type_tag` is the conformer's OWN identity, checked at every unbox, so
    a second conformer cannot be mistaken for the first. The guard is DERIVED
    from the boxed type rather than asserted by the boxing site — the same reason
    `UdfDescriptor.is_describable()` is derived rather than declared."""

    def plan_tag(self) -> UInt8:
        """The node discriminant, snapshotted into
        `CorrelatedSubqueryData.inner_tag` at construction. See that field."""
        ...

    def erased_type_tag(self) -> UInt32:
        """This conformer's `ErasedBox` type tag. `LogicalPlan` returns
        `CORR_SUBQ_PLAN_TYPE_TAG`."""
        ...


struct CorrelatedSubqueryData(Movable):
    """Payload for `Expr` tag `EXPR_CORRELATED_SUBQUERY`.

    Fields:
        _plan: the subquery's `LogicalPlan`, OWNED, type-erased. Reach it with
            `corr_subquery.corr_data_inner_plan_ref(cs)` — the accessor is a
            free function in a module that may name the plan, which is the whole
            point of this split. ⚠ Never `unsafe_as` it by hand; that skips the
            type-tag check.
        outer_refs: column names from the OUTER scope that the inner plan
            correlates with. Validated against the outer parent's output schema
            by `flatten_dependent_joins` at lowering time.
        kind: one of CORR_KIND_EXISTS / _NOT_EXISTS / _SCALAR / _IN_CORRELATED.
        in_lhs_col: for CORR_KIND_IN_CORRELATED — the OUTER column on the LHS of
            the `IN` predicate (e.g. `s_suppkey`). Empty otherwise.
        in_rhs_col: for CORR_KIND_IN_CORRELATED — the INNER column the subquery
            projects that the `IN` matches against (e.g. `ps_suppkey`). Empty
            otherwise.
        inner_tag: a SNAPSHOT of the boxed plan's `tag`, taken at construction.
            See the header — it exists so `Expr.write_to` needs no plan.
    """

    var _plan: ErasedBox
    var outer_refs: List[String]
    var kind: UInt8
    var in_lhs_col: String
    var in_rhs_col: String
    var inner_tag: UInt8

    def __init__(
        out self,
        var plan_box: ErasedBox,
        var outer_refs: List[String],
        kind: UInt8,
        inner_tag: UInt8,
        var in_lhs_col: String = String(),
        var in_rhs_col: String = String(),
    ):
        """⚠ TAKES AN ALREADY-BOXED PLAN. Call
        `corr_subquery.make_correlated_subquery_data(...)` instead — it takes a
        `LogicalPlan^`, mints the box with the right tag, and reads `inner_tag`
        off the plan so the snapshot cannot disagree with what was boxed."""
        self._plan = plan_box^
        self.outer_refs = outer_refs^
        self.kind = kind
        self.in_lhs_col = in_lhs_col^
        self.in_rhs_col = in_rhs_col^
        self.inner_tag = inner_tag

    def copy(self) -> Self:
        """Deep-clone, INCLUDING the inner plan.

        `ErasedBox.copy()` routes through `erased_box_copy_for[LogicalPlan]`,
        i.e. `LogicalPlan.copy()`. Two copies never share a plan; see the
        header for why that is load-bearing rather than tidy."""
        return Self(
            self._plan.copy(),
            self.outer_refs.copy(),
            self.kind,
            self.inner_tag,
            self.in_lhs_col,
            self.in_rhs_col,
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive Deinitable
    # check on the recursive self-reference reachable through the boxed plan.
    # Field destructors still run (`ErasedBox.__del__` frees the plan).
    def __deinit__(deinit self):
        pass


def make_correlated_subquery_data[
    P: BoxablePlan
](
    var inner_plan: P,
    var outer_refs: List[String],
    kind: UInt8,
    var in_lhs_col: String = String(),
    var in_rhs_col: String = String(),
) -> CorrelatedSubqueryData:
    """THE ONE PLACE A PLAN IS BOXED INTO A SUBQUERY PAYLOAD.

    Reads `inner_tag` and the box's type tag off the plan BEFORE consuming it,
    so the snapshot cannot disagree with what was boxed — which is exactly what
    a hand-written box-then-fill-the-struct sequence gets wrong. Generic, and
    therefore still leaf: this module names no plan type.

    ⚠ `inner_plan` is CONSUMED (moved into the box). The payload OWNS it and
    `CorrelatedSubqueryData.copy()` deep-clones it — ordinary owned-value
    semantics. This module just cannot say what it owns."""
    var inner_tag = inner_plan.plan_tag()
    var type_tag = inner_plan.erased_type_tag()
    var box = make_erased_box[P](inner_plan^, type_tag)
    return CorrelatedSubqueryData(
        box^, outer_refs^, kind, inner_tag, in_lhs_col^, in_rhs_col^
    )
