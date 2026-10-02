# =============================================================================
# bound_relation.mojo — the GENERAL bound-relation seam (w2d) + the NAMED arm
# =============================================================================
#
# DESIGN — GENERAL, NOT SUM-shaped (the load-bearing call, per the coordinator):
#   `relation` is THE general handle: a resident RecordBatch shared via
#   ArcPointer (so one bound relation is REUSED across many formulas without
#   re-materializing — RecordBatch is Movable-only + non-cloneable-by-copy, so a
#   lowering that must MOVE a batch into a scan clones via `copy_batch`). w3's
#   JOIN/FILTER lowerings take the SAME `relation` handle. `column` is the
#   per-reference selector (which column of the relation this name refers to);
#   an empty selector = the whole relation (COUNT-rows / FILTER). w3 extends the
#   selector (multi-column / predicate) WITHOUT reshaping `relation`.
#
# =============================================================================
# =============================================================================
#
# THE DEFECT IT CLOSES, stated as the corpus states it. `tests/sdk/
# test_cross_facade_differential.mojo` measures Excel at REACHES_BYTES **0 of
# 13** — not one Excel plan can leave this process — and the reason is this
# struct: every Excel leaf was a resident `RecordBatch`, and
# `plan_wire_codec._source_to_wire` refuses that arm BY NAME
# (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`) as its FIRST branch. A
# parquet-backed leaf is arm 1 of that same function and encodes with ZERO
# codec edits. So the unlock is not a wire feature; it is a second way to bind.
#
# ⚠⚠ CONVERGENCE BY VALUE, NOT BY TYPE — AND THAT IS A MEASUREMENT, NOT A TASTE.
#
# ⚠ FOR THE SAME REASON, `LogicalPlan` IS NOT IMPORTED HERE EITHER. The named
# arm's scan leaf is built by `fn_rel_agg._named_scan(rel)`, which lives in the
# one module that already carries the SDK/plan surface. Keeping the plan type
# off the scalar side is the same discipline, applied pre-emptively.
#
# Encapsulation rule : ArcPointer for GENUINE shared ownership of one
# resident relation across many evaluations (NOT to make a struct Copyable for
# list storage — the sharing is the point). No UnsafePointer anywhere except the
# address-identity read in `same_relation`, which discards it.
# =============================================================================

from std.memory import ArcPointer
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.source.source_variant import SourceVariant


struct NamedTable(Copyable, Movable):
    """A catalog table Excel can bind a name to: `(name, schema, source)`.

        var t = cat.table_of("ord")            # CatalogTable, SDK side
        BoundRelation(NamedTable(t.name, t.schema, t.source), "o_amount")
    """

    var name: String
    var schema: Schema
    var source: SourceVariant

    def __init__(out self, var name: String, var schema: Schema, var source: SourceVariant):
        self.name = name^
        self.schema = schema^
        self.source = source^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.schema.copy(), self.source.copy())


struct BoundRelation(Copyable, Movable):
    """A name bound to an engine relation + a column selector. Copyable because
    `relation` is an ArcPointer (shared) and `column` is a String — so
    FormulaBindings stays Copyable and a relation is shared, not duplicated."""

    # THE general relation handle — shared, reusable across evaluations.
    #
    # ⚠ ON THE NAMED ARM THIS IS AN EMPTY PLACEHOLDER — no rows AND no columns
    # (see the named `__init__` for why it does not carry the table's schema).
    # It is a placeholder and not the data, so NOTHING may read it on that arm:
    # that is why `require_resident` exists and why every un-migrated family
    # calls it at entry. A confident zero is worse than a refusal.
    var relation: ArcPointer[RecordBatch]
    # The selected column of `relation` (empty = the whole relation).
    var column: String
    # THE NAMED, FILE-BACKED ARM. `None` on the resident arm — which is every
    # binding that existed before step S3, unchanged.
    #
    # ⚠ BEHIND AN `ArcPointer`, FOR THE SAME REASON `relation` IS. `NamedTable`
    # holds a `Schema` and a `SourceVariant` — the latter a wide tagged union
    # over every source kind. Storing it INLINE puts that type's full copy and
    # destructor machinery into `BoundRelation`'s own, and `BoundRelation` is
    # copied at essentially every node of the REL lowering tree (`rel.copy()`,
    # `List[BoundRelation]`, `Optional[BoundRelation]`, and every lowering that
    # takes one by value). A one-word shared handle keeps this struct the size
    # it was and instantiates the heavy copy/drop code ONCE.
    var table: Optional[ArcPointer[NamedTable]]

    def __init__(out self, var relation: ArcPointer[RecordBatch], column: String):
        """The RESIDENT arm — unchanged. Binds a name to a batch already in this
        process."""
        self.relation = relation^
        self.column = column
        self.table = Optional[ArcPointer[NamedTable]]()

    def __init__(out self, var table: NamedTable, column: String):
        """★ THE NAMED arm. Binds a name to a CATALOG TABLE — a (name, schema,
        SourceVariant) triple, which over a parquet path is a leaf the wire
        codec already accepts.
        schema here, measure the compile — do not assume."""
        self.relation = ArcPointer(RecordBatch())
        self.column = column
        self.table = Optional[ArcPointer[NamedTable]](ArcPointer(table^))

    def copy(self) -> Self:
        var out = Self(self.relation.copy(), self.column.copy())
        if self.table:
            # A refcount bump, NOT a deep copy of the schema + source. Two
            # bindings over one table share one `NamedTable`, exactly as two
            # bindings over one batch share one `RecordBatch`.
            out.table = Optional[ArcPointer[NamedTable]](self.table.value().copy())
        return out^

    @always_inline
    def has_column(self) -> Bool:
        return self.column.byte_length() > 0

    @always_inline
    def is_named(self) -> Bool:
        """True if this relation is bound by NAME to a catalog table (the
        file-backed arm), False if it is a resident batch."""
        return Bool(self.table)

    def table_name(self) -> String:
        """The catalog name this relation is bound to, or `""` on the resident
        arm (which has no name — that is the whole reason the wire cannot carry
        it)."""
        if self.table:
            return self.table.value()[].name.copy()
        return String("")

    def table_schema(self) raises -> Schema:
        """The named table's schema. Raises on the resident arm."""
        if not self.table:
            raise Error(
                "BoundRelation.table_schema: this relation is bound to a"
                " RESIDENT batch, not to a named table. Read `relation[].schema`."
            )
        return self.table.value()[].schema.copy()

    def named_table(self) raises -> NamedTable:
        """A COPY of the named table this relation is bound to. Raises on the
        resident arm.

        ⚠ THE SCAN LEAF IS BUILT FROM THIS, ELSEWHERE. The obvious place for a
        `named_scan()` returning a `LogicalPlan` is right here, and it must not
        be here: this file is imported by `formula_eval.mojo`, the SCALAR
        evaluator, and every type this file names enters the scalar side's
        elaboration graph. The measurement in the header is what that costs. The
        leaf is therefore built by `fn_rel_agg._named_scan`, in the one module
        that already carries the plan/SDK surface."""
        if not self.table:
            raise Error(
                "BoundRelation.named_table: this relation is bound to a RESIDENT"
                " batch. A resident batch has no name the wire can carry; bind"
                " it through a catalog table (SqlCatalog.add_parquet) first."
            )
        return self.table.value()[].copy()

    def require_resident(self, site: String) raises:
        """⚠ THE MIGRATION FRONTIER, MADE LOUD.

        Called at the entry of every Excel lowering family that has NOT yet been
        migrated to the named arm. Without it those families would read the
        zero-row placeholder and return a perfectly confident wrong answer —
        `SUMIFS` over a named table would be 0, `FILTER` would spill nothing —
        which is strictly worse than not supporting the arm at all.
        """
        if self.table:
            raise Error(
                "Excel: the relation '"
                + self.table.value()[].name
                + "' is bound by NAME to a file-backed table, but the lowering '"
                + site
                + "' has not been migrated to the named arm and can only read a"
                + " RESIDENT RecordBatch. Bind this name to a resident batch, or"
                + " migrate that family."
            )

    def require_named(self, site: String) raises:
        """⚠ THE INVERSE OF `require_resident`, AND IT IS NOT A SECOND MIGRATION
        FRONTIER — it is what a verb BORN on the named arm says.

        `require_resident` above marks a lowering that predates the named arm
        and has not been migrated: its call sites are the REMAINING WORK, and
        each one is deleted when its family moves. This one marks the opposite
        and is not debt of the same kind: a relation verb added AFTER the named
        arm existed, with no resident lowering to migrate FROM.

        ⚠ SO A `rg require_named` COUNT IS NOT PROGRESS IN EITHER DIRECTION.
        `rg require_resident` is a shrinking work list; this is a growing list
        of verbs that never needed one. Do not add the two together, and do not
        read a rise here as a regression."""
        if not self.table:
            raise Error(
                "Excel: the lowering '"
                + site
                + "' has no RESIDENT lowering — it is a relation verb born on"
                + " the NAMED (file-backed) arm, and the relation it was handed"
                + " is bound to a resident RecordBatch. Bind the name through a"
                + " catalog table (SqlCatalog.add_parquet) first."
            )

    @always_inline
    def same_relation(self, other: BoundRelation) -> Bool:
        """True if `self` and `other` alias the SAME resident RecordBatch — the
        two ArcPointer handles reference ONE underlying box (e.g. two
        BoundRelations built from `arc.copy()` over one batch). This is BATCH
        IDENTITY, not name equality.

        Used by the INDEX(MATCH) fuse guard: the fused lowering selects one
        relation's column FROM the other relation's batch, which is only result-
        identical to the standalone composition when the two references are the
        SAME batch. Gating on the column NAME alone is UNSOUND — two DISTINCT
        batches can coincidentally share a column name, and the fuse would then
        read from the wrong batch (divergent from standalone composition).

        ⚠ ON THE NAMED ARM, IDENTITY IS THE TABLE NAME, NOT THE ADDRESS. Two
        named bindings over one table hold two DISTINCT placeholder batches, so
        the address test would call them different relations and the batching in
        `formula_graph._execute_batch` would silently stop fusing. Comparing the
        catalog name is the correct identity for a leaf whose meaning IS its
        name (resolution is case-insensitive in `SqlCatalog._find`, and
        `add_parquet` lower-cases what it stores, so a byte compare here is
        already case-insensitive). A named relation is NEVER the same relation
        as a resident one: they cannot be row-aligned by construction."""
        if self.is_named() or other.is_named():
            if not (self.is_named() and other.is_named()):
                return False
            return self.table.value()[].name == other.table.value()[].name
        # SAFETY: address-identity comparison of the two ArcPointer pointees. The
        # `Int(UnsafePointer(to=...))` reads each box's address for the equality
        # test and DISCARDS it — no pointer crosses this signature (return is
        # Bool), none is stored, and `unsafe_from_address` is never used. Two
        # ArcPointers cloned from one box dereference to the same object, so
        # equal addresses <=> same resident batch.
        return Int(UnsafePointer(to=self.relation[])) == Int(
            UnsafePointer(to=other.relation[])
        )
