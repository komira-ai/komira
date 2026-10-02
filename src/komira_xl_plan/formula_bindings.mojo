# =============================================================================
# formula_bindings.mojo — WHAT AN EXCEL NAME MEANS. The one value both halves
#                         of the Excel surface read, and neither half owns.
# =============================================================================
#
# The severance is by PACKAGE because the gate's granularity is the package.
# Splitting the FILES without splitting the LIBRARY would have moved nothing.
#
# Encapsulation rule : values only — no `UnsafePointer` in any
# signature, no wildcard origins, no `unsafe_from_address`.
# =============================================================================

from .formula_value import FormulaValue
from .bound_relation import BoundRelation
from .agg_memo import AggMemo


# =============================================================================
# FormulaBindings — name -> value context (replaces A1 addressing in v1, §4.1)
# =============================================================================
struct FormulaBindings(Copyable, Movable):
    """Maps a bound identifier to EITHER a scalar `FormulaValue` (`qty`, `name`)
    OR an engine RELATION (`revenue` -> a bound column of a resident batch, the
    w2d `BoundRelation` seam). v1 binds NAMES, not cells (the sheet/A1 layer is
    out of scope). Both binding kinds are looked up separately; a name is either
    scalar or relational, never both.

    THIRD KIND (the one-plan seam, `formula_graph`): a PRE-RESOLVED aggregate
    binding — `(relation name, aggregate kind) -> value`. The graph lowering
    executes a whole sheet's aggregates in ONE batched plan and records the
    results here; `rel_fold._lower_rel_call` then returns the stored value
    instead of issuing its own engine query. An empty memo (the default) misses
    every lookup, so the per-formula path is byte-unchanged.
    """
    var names: List[String]
    var values: List[FormulaValue]
    # Relation bindings (the w2d bound-relation seam) — parallel lists.
    var rel_names: List[String]
    var rels: List[BoundRelation]
    # Pre-resolved aggregate bindings (the formula_graph one-plan seam).
    var agg_memo: AggMemo

    def __init__(out self):
        self.names = List[String]()
        self.values = List[FormulaValue]()
        self.rel_names = List[String]()
        self.rels = List[BoundRelation]()
        self.agg_memo = AggMemo()

    def copy(self) -> Self:
        var out = Self()
        out.names = self.names.copy()
        out.values = self.values.copy()
        out.rel_names = self.rel_names.copy()
        out.rels = self.rels.copy()
        out.agg_memo = self.agg_memo.copy()
        return out^

    def bind(mut self, name: String, var value: FormulaValue):
        self.names.append(name)
        self.values.append(value^)

    def bind_number(mut self, name: String, v: Float64):
        self.bind(name, FormulaValue.number(v))

    def bind_text(mut self, name: String, v: String):
        self.bind(name, FormulaValue.text_val(v))

    def bind_logical(mut self, name: String, v: Bool):
        self.bind(name, FormulaValue.logical_val(v))

    def bind_blank(mut self, name: String):
        self.bind(name, FormulaValue.blank())

    def bind_relation(mut self, name: String, var relation: BoundRelation):
        """Bind `name` to an engine relation (a bound column, the w2d seam). A
        REL-capable function (SUM/AVERAGE/...) over `name` lowers to a SCAN ->
        AGGREGATE query the engine executes."""
        self.rel_names.append(name)
        self.rels.append(relation^)

    def lookup(self, name: String) -> Optional[FormulaValue]:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return Optional[FormulaValue](self.values[i].copy())
        return Optional[FormulaValue]()

    def lookup_relation(self, name: String) -> Optional[BoundRelation]:
        for i in range(len(self.rel_names)):
            if self.rel_names[i] == name:
                return Optional[BoundRelation](self.rels[i].copy())
        return Optional[BoundRelation]()

    def bind_agg_result(mut self, name: String, kind: UInt8, var value: FormulaValue):
        """Record a PRE-RESOLVED aggregate over the relation bound to `name` (the
        `formula_graph` one-plan seam). `kind` is an `agg_memo.XL_AGG_*`."""
        self.agg_memo.put(name, kind, value^)

    def lookup_agg_result(self, name: String, kind: UInt8) -> Optional[FormulaValue]:
        """The pre-resolved aggregate for `(name, kind)`, if the graph lowering
        already executed it. A hit means the per-site lowering must NOT issue an
        engine query."""
        return self.agg_memo.lookup(name, kind)