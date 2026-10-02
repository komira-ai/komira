# =============================================================================
# agg_memo.mojo — PRE-RESOLVED aggregate bindings (the one-plan seam)
# =============================================================================
#
# THE SHAPE (why this is a BINDING, not a cache). `FormulaBindings` already maps
# a NAME to either a scalar value or a bound relation. An aggregate over a bound
# relation — `SUM(revenue)` — is fully determined by (name, agg kind): the name
# resolves to (batch, column) through the existing relation binding. So the
# resolved aggregate is just a THIRD kind of binding on the same object, and it
# rides every existing signature with zero threading. `rel_fold._lower_rel_call`
# consults it before lowering; a hit costs no engine query.
#
# Encapsulation rule : parallel `List` fields of plain values. No
# UnsafePointer, no wildcard origins, no unsafe_from_address.
# =============================================================================

from .formula_value import FormulaValue
from .xl_fn_table import (
    xl_fn_lookup,
    XLF_AGG,
    XLA_SUM,
    XLA_COUNT,
    XLA_MIN,
    XLA_MAX,
    XLA_MEAN,
)


# --- The BATCHABLE aggregate kinds: the single-relation column aggregates. ---
comptime XL_AGG_SUM: UInt8 = 0
comptime XL_AGG_COUNT: UInt8 = 1
comptime XL_AGG_MIN: UInt8 = 2
comptime XL_AGG_MAX: UInt8 = 3
comptime XL_AGG_AVERAGE: UInt8 = 4

# Sentinel for "not a batchable aggregate name".
comptime XL_AGG_NONE: Int = -1


def xl_agg_kind(fn_name: String) -> Int:
    """Map an Excel function name to its BATCHABLE aggregate kind, or
    `XL_AGG_NONE` if the graph lowering cannot batch it.

    ⚠⚠ THE BATCHABLE SET IS **NARROWER** THAN THE PLAN BUILDER'S, AND THAT IS
    NOT AN OVERSIGHT. `xl_fn_table` gives MEDIAN / STDEV / VAR / COUNTA the
    `XLR_PLAN` reach and NOT `XLR_INLINE_REL`, because the inline relational
    path's terminal (`EngineContext.materialize_scalar_agg_plan`) serves
    EXACTLY SUM/COUNT/MIN/MAX/MEAN and RAISES on anything else by design. The
    graph lowering that consumes this memo runs on that terminal, so a name it
    cannot execute must not be batched INTO it — a batched MEDIAN would turn a
    clean `#NAME?` into a Mojo exception.

    ⇒ The mapping below therefore has arms for the five FULL-REACH tags only,
    and every other tag falls through to `XL_AGG_NONE`. Falling through is
    always correct — the caller then takes the per-site lowering, which is what
    the un-batched path has always done ("conservative by construction").

    ⚠ IT ASKS THE TABLE FOR THE TAG rather than spelling five names again. Four
    sites used to spell that set by hand, in packages that cannot be compiled
    together; `xl_fn_table.mojo`'s header records what that cost.

    ⚠ IT DOES NOT NAME `komira_core.plan.agg_expr`. This module is imported by
    `formula_eval.mojo`, the engine-FREE scalar evaluator whose small compile
    surface is load-bearing — which is exactly why `xl_fn_table`'s tags are
    LOCAL `UInt8`s and `rel_agg_build` is the one module that maps them."""
    var row_opt = xl_fn_lookup(fn_name)
    if not row_opt:
        return XL_AGG_NONE
    var row = row_opt.value().copy()
    # ⚠⚠ THE FAMILY GUARD, AND IT IS LOAD-BEARING RATHER THAN DEFENSIVE.
    # `SUMIF` carries `XLA_SUM` as its PAYLOAD — it really does apply a sum —
    # while denoting AGGREGATE <- FILTER <- SCAN, a shape
    # `materialize_scalar_agg_plan` refuses (it requires a BARE scan under the
    # aggregate). Keying on the tag alone would offer the graph lowering a
    # SUMIF to batch onto that terminal, turning a clean `#NAME?` into a Mojo
    # exception — the exact failure the paragraph above warns about, arriving
    # through the CONDAGG family instead of through MEDIAN. Only the
    # unconditional-aggregate family is batchable.
    if row.family != XLF_AGG:
        return XL_AGG_NONE
    var tag = row.agg_tag
    if tag == XLA_SUM:
        return Int(XL_AGG_SUM)
    if tag == XLA_COUNT:
        return Int(XL_AGG_COUNT)
    if tag == XLA_MIN:
        return Int(XL_AGG_MIN)
    if tag == XLA_MAX:
        return Int(XL_AGG_MAX)
    if tag == XLA_MEAN:
        return Int(XL_AGG_AVERAGE)
    return XL_AGG_NONE


struct AggMemo(Copyable, Movable):
    """A table of PRE-RESOLVED `(relation name, aggregate kind) -> value` entries.

    Populated by the graph lowering after it executes the sheet's aggregates in
    one batched plan; read by `rel_fold._lower_rel_call`, which returns the
    stored value instead of issuing an engine query. Empty (the default) makes
    every lookup miss, so the per-formula path behaves exactly as before."""

    var names: List[String]
    var kinds: List[UInt8]
    var values: List[FormulaValue]

    def __init__(out self):
        self.names = List[String]()
        self.kinds = List[UInt8]()
        self.values = List[FormulaValue]()

    def copy(self) -> Self:
        var out = Self()
        out.names = self.names.copy()
        out.kinds = self.kinds.copy()
        out.values = self.values.copy()
        return out^

    def put(mut self, name: String, kind: UInt8, var value: FormulaValue):
        """Record a resolved aggregate. A re-put of the same key overwrites (the
        graph lowering never re-requests a key it already resolved, so this is a
        defensive path, not a hot one)."""
        for i in range(len(self.names)):
            if self.names[i] == name and self.kinds[i] == kind:
                self.values[i] = value^
                return
        self.names.append(name)
        self.kinds.append(kind)
        self.values.append(value^)

    def lookup(self, name: String, kind: UInt8) -> Optional[FormulaValue]:
        for i in range(len(self.names)):
            if self.names[i] == name and self.kinds[i] == kind:
                return Optional[FormulaValue](self.values[i].copy())
        return Optional[FormulaValue]()

    @always_inline
    def __len__(self) -> Int:
        return len(self.names)
