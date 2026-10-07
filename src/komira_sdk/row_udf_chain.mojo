# =============================================================================
# row_udf_chain.mojo — the comptime-carrying chain for `df.map[m]().filter[p]()`
# =============================================================================
#
# ── THE PROBLEM THIS FILE EXISTS TO SOLVE ───────────────────────────────────
#
# `PlanCarrier` is a ZERO-PARAMETER struct. Every verb on it takes a RUNTIME
# value and returns another `PlanCarrier`:
#
#     filter(var self, var predicate: Expr) -> Self
#     filter_with_udf(var self, var pred: Expr,
#                     var udf_data: OwnedPointer[UdfData]) -> Self
#
# The second one is the whole difficulty. A typed UDF's identity IS its Mojo
# type; `OwnedPointer[UdfData]` is a RUNTIME payload, so passing a UDF through
# it ERASES the comptime function at the plan boundary and the walker cannot
# get it back. `lower_untyped`'s `_lower_filter_node` says exactly that: it
# raises `UnsupportedByLowerUntyped` for a UDF segment because "the walker
# can't recover F from the type-erased payload".
#
# ⚠ AND THAT ERASURE IS NOW A REFUSAL, NOT A GAP. One commit
# made `filter_with_udf` / `project_with_udf` REFUSE, because the column path
# read the SURROGATE those verbs stamp (`FilterData.predicate` is a
# `lit(true)` placeholder; `ProjectData.exprs` are placeholder col-refs) and
# ran it AS IF IT WERE THE QUERY — the customer's UDF was discarded and every
# row came back. So routing the row form through `UdfData` would be building
# on a path that was just closed for returning wrong answers.
#
# ── THE ANSWER: DO NOT CROSS THE ERASING SEAM ───────────────────────────────
#
# The typed path AUTHORS A
# PHYSICAL PLAN, AT COMPTIME: a typed UDF builds no `UdfData` node, there
# is no name to resolve, and plan-level identity questions do not arise, because
# there is no plan-level object to identify.
#
# So the chain below carries the customer's functions AS COMPTIME PARAMETERS
# OF ITS OWN TYPE, and carries the SCAN as a runtime `LogicalPlan` (a scan is
# data — a path, a projection, a pushed filter — and nothing about it is
# comptime). `m` and `p` reach the Stage slots without ever being written
# down as a runtime value.
#
# ── WHY THREE STRUCTS AND NOT ONE ───────────────────────────────────────────
#
# A single carrier would need a "no map yet" and a "no filter yet" sentinel in
# comptime function position. Mojo 1.0.0 has no null function parameter, and a
# `_keep_all[R]` sentinel would then have to be COMPARED against at
# `materialize` time to know whether to emit a filter slot — comparing comptime
# function values, which is exactly the operation the earlier investigation
# established comptime cannot do. So the STATE OF THE CHAIN IS THE TYPE:
#
#     RowMapChain[m]        map only          .filter[p]() -> RowChain[m, p]
#     RowFilterChain[p]     filter only       .map[m]()    -> RowChain[m, p]
#     RowChain[m, p]        both
#
# Three states, a closed lattice over two verbs, each knowing its own Stage
# shape at compile time with no runtime discriminant to get wrong.
#
# ── ⚠ WHAT `.map[m]().filter[p]()` MEANS, WHICH IS WHAT SQL MEANS ───────────
#
# In the design's own idiom BOTH functions take the SOURCE row:
#
#     def margin(row: Order) -> Priced
#     def cheap (row: Order) -> Bool
#     df.map[margin]().filter[cheap]()
#
# `cheap` reads `price`, which is NOT among the map's output columns. That is
# not a mistake and it is not "the filter runs on the map's output": it is
# WHERE, and `WHERE` has always bound against the FROM-clause schema, never
# the SELECT list:
#
#     SELECT (price - cost) / price AS margin, ...  FROM orders  WHERE price < 100
#
# BOTH row UDFs bind the SCAN schema; the map decides the output columns and
# the filter decides the rows. Chain ORDER does not change the answer, exactly
# as `SELECT`/`WHERE` order does not. This also matches the substrate: one
# `Stage[Filter, Projects, NoBreaker, NoState]` runs its filter pass and then
# its project pass over the SAME input morsel, so the semantics and the
# machine agree instead of being reconciled.
#
# ⚠ THE COROLLARY: A ROW UDF ALWAYS READS THE SCAN. `.map[a]().map[b]()` —
# chaining a second map onto the first map's OUTPUT — is a different shape
# (it needs two stages, or a fused row-to-row-to-row call) and is NOT offered
# here rather than being offered and silently binding `b` to the scan.
#
# ── The projection is the row struct ────────────────────────────────────────
#
# `row_projection[In]()` is pushed into the scan, so the morsel handed to the
# Stage has `In`'s fields as columns 0..N-1 in declared order — the contract
# `_build_row_n` reads by. When both verbs are present they must agree on the
# input row type; `RowChain` takes ONE `In` for both, so a mismatch is a type
# error at the `.filter[p]()` call, not a wrong answer.
#
# ── Encapsulation invariants ──────────── ──────────────────────────
#   - NO `UnsafePointer` in any signature; the carriers hold a `LogicalPlan`
#     by value inside an `Optional`, taken with `.take()`.
#   - NO wildcard origins, no `unsafe_from_address`, no `take_pointee`.
#   - This module imports NO SDK sibling that imports it back: it names the
#     plan IR and the eval-layer row surface only. `plan_carrier.mojo` imports
#     THIS; the executable half lives in `row_udf_driver.mojo`, which the
#     engine-context terminal imports. A `.collect()` method here would have
#     to name `EngineContext`, closing an import cycle
#     (plan_carrier -> row_udf_chain -> engine_context -> plan_carrier).
# =============================================================================

from std.collections import Optional

from komira_plan_ir.logical_plan import LogicalPlan

from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.row_udf import (
    RowFilterUdf,
    RowMapUdf,
    assert_row_udf_ids_differ,
)


# =============================================================================
# §1 — RowChain[In, Out, //, m, p] — both verbs
# =============================================================================


@fieldwise_init
struct RowChain[
    In: AutoKomiraSchema & Deinitable,
    Out: AutoKomiraSchema & Deinitable, //,
    m: def(In) thin -> Out,
    p: def(In) thin -> Bool,
    map_id: StringLiteral = "",
    filter_id: StringLiteral = "",
](Movable):
    """A scan plus a row MAP and a row FILTER, both comptime.

    Terminal: `ctx.materialize_rows(chain^)`.
    """

    var _plan: Optional[LogicalPlan]

    comptime MapUdf = RowMapUdf[m = Self.m, id = Self.map_id]
    comptime FilterUdf = RowFilterUdf[f = Self.p, id = Self.filter_id]

    def take_plan(mut self) -> LogicalPlan:
        """Take the carried scan plan. The chain is spent afterwards."""
        return self._plan.take()

    @staticmethod
    def check_identities():
        """REFUSE a chain whose two row UDFs derive the same `UDF_ID`.

        Called from the driver rather than at struct scope so the message
        names a chain the customer actually built. It cannot fire for a
        map/filter pair today — the `rowmap` / `rowfilter` kind tags separate
        them — and it is here anyway, because the tags are one edit away from
        being dropped and this is the check that would notice."""
        assert_row_udf_ids_differ[
            Self.MapUdf.UDF_ID, Self.FilterUdf.UDF_ID, "map/filter"
        ]()


# =============================================================================
# §2 — RowMapChain[In, Out, //, m] — map only, gains `.filter[p]()`
# =============================================================================


@fieldwise_init
struct RowMapChain[
    In: AutoKomiraSchema & Deinitable,
    Out: AutoKomiraSchema & Deinitable, //,
    m: def(In) thin -> Out,
    map_id: StringLiteral = "",
](Movable):
    """A scan plus a row MAP. `.filter[p]()` adds the predicate.

    Terminal: `ctx.materialize_rows(chain^)`.
    """

    var _plan: Optional[LogicalPlan]

    comptime MapUdf = RowMapUdf[m = Self.m, id = Self.map_id]

    def filter[
        p: def(Self.In) thin -> Bool, filter_id: StringLiteral = ""
    ](var self) -> RowChain[
        m = Self.m, p = p, map_id = Self.map_id, filter_id=filter_id
    ]:
        """Add a row predicate over the SAME input row type as the map.

        `p` must take `Self.In`: a predicate over a different row struct is a
        type error HERE, at the call the customer wrote, rather than a
        mis-bound column read at run time."""
        return RowChain[
            m = Self.m, p = p, map_id = Self.map_id, filter_id=filter_id
        ](self._plan.take())

    def take_plan(mut self) -> LogicalPlan:
        return self._plan.take()


# =============================================================================
# §3 — RowFilterChain[In, //, p] — filter only, gains `.map[m]()`
# =============================================================================


@fieldwise_init
struct RowFilterChain[
    In: AutoKomiraSchema & Deinitable, //,
    p: def(In) thin -> Bool,
    filter_id: StringLiteral = "",
](Movable):
    """A scan plus a row FILTER. `.map[m]()` adds the projection.

    Terminal: `ctx.materialize_rows(chain^)`. With no map the chain emits
    `In`'s own columns for the surviving rows.
    """

    var _plan: Optional[LogicalPlan]

    comptime FilterUdf = RowFilterUdf[f = Self.p, id = Self.filter_id]

    def map[
        Out: AutoKomiraSchema & Deinitable, //,
        m: def(Self.In) thin -> Out,
        map_id: StringLiteral = "",
    ](var self) -> RowChain[
        m=m, p = Self.p, map_id=map_id, filter_id = Self.filter_id
    ]:
        """Add a row map over the SAME input row type as the predicate."""
        return RowChain[
            m=m, p = Self.p, map_id=map_id, filter_id = Self.filter_id
        ](self._plan.take())

    def take_plan(mut self) -> LogicalPlan:
        return self._plan.take()
