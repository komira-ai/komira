# =============================================================================
# plan_group_estimate — an ACCURACY INSTRUMENT for plan-time GROUP BY
# cardinality. It is deliberately NOT a producer: nothing it computes reaches
# any routing decision, and there is no switch that makes it one.
# =============================================================================
#
# ⛔ READ THIS BEFORE WIRING ANYTHING TO IT.
# ---------------------------------------------------------------------------
# This module computes a number and PRINTS it. It does not write
# `AggregateData.estimated_groups`, and the pass that used to
# (`precompute_group_estimates`) was deleted before it ever landed, on purpose.
# The slot has three consumers — the in-mem choke point's GROUP arm, door-2's
# `by_rows_group_est`, and `AggSinkData.estimated_groups` -> the S1_MINIMAP /
# S1_PARTITIONED pivot — so writing it is not an experiment, it is a routing
# change to three doors at once. Adding a "just flip this to enable it" flag
# would put that change one typo away, so there is no such flag. If a future
# landing decides the estimate is good enough to route on, it should have to
# WRITE the wiring, and be reviewed as what it is.
#
# WHAT THE INSTRUMENT IS FOR
# ---------------------------------------------------------------------------
# `inmem_agg_choose_strategy`'s GROUP arm has never fired: `[AST]` printed
# `group_est=-1` at all fifteen in-mem sites of the lever census.
# Before deciding whether to feed it, the open question is not "can we compute
# an estimate" but "how WRONG is the estimate we can compute, per site, on real
# corpus data" — and nothing in this repo has ever measured that. This module
# is that measurement. It emits, per in-mem dispatch, a PREDICTED group count
# beside the ACTUAL one (the agg's own output row count), plus the PROVENANCE
# of the prediction, which is the part that turns out to matter most.
#
# ⚠ TWO FACTS THE PRIOR RECORD GOT WRONG. Both were relayed as fact out of a
# source comment (`hash_agg_untyped_sink.mojo`) into four documents.
#
#   1. `precompute_aggregate_estimates` was NOT "deleted". It is
#      intact at `komira_parquet/parquet_cardinality.mojo` with zero callers —
#      its CALL SITE died with the `execute_forest_with_caches` island, exactly
#      as its sibling `precompute_scan_stats`'s did. That sibling was re-wired
#      in `komira_sdk/engine_context.mojo`; nobody came back for
#      this one.
#   2. `.with_group_hint()` DOES NOT EXIST. The real API is
#      `.with_estimated_groups(n)` (`komira_sdk/plan_carrier.mojo`, plus the
#      `ScanFrame` and `TypedDataFrame` surfaces). The phantom name occurs on
#      trunk only inside prose that was quoting that comment.
#
#   What the comment got RIGHT is its measurement: `group_est = -1` at every
#   in-mem site, independently confirmed from the trace census.
#
# ⚠ AND REVIVING THE OLD PRODUCER WOULD NOT HAVE HELPED THIS DOOR ANYWAY.
# `_walk_to_scan` (`parquet_cardinality.mojo`) returns None on a FILTER, on a
# JOIN, and on any scan carrying a pushed-down `scan.filter`. Every in-mem
# dispatch is a post-join or post-agg resident batch, so re-wiring it changes
# `group_est` at ZERO of them. Verified by reading it, not by trusting a note.
#
# ⭐ SO THIS RESOLVER IS A DIFFERENT SHAPE, AND REACH IS NOT ITS PROBLEM.
# `_resolve_key_ndv` below walks THROUGH `FILTER` / `JOIN` / `PROJECT` /
# `AGGREGATE` / `SORT` / `LIMIT` / `TOPN` to find the base column a group key
# came from, so it DOES reach a post-join door — q11's `GROUP BY ps_partkey`
# over `partsupp x supplier x nation` resolves to the partsupp scan. Reach was
# never the binding constraint. **SIGNAL AVAILABILITY IS**, and that is the
# finding this module exists to make legible.
#
# ⭐⭐⭐ THE ANSWER, MEASURED ON THE LIVE CORPUS: NO PLAN-TIME
# ESTIMATOR OF ANY DESIGN CAN FEED THE IN-MEM DOOR.
# ---------------------------------------------------------------------------
# Run with the accuracy trace on over tpch q4 / q11 / q12 / q13 /
# q22, every in-mem dispatch reported:
#
#   [AGE] ... pred=-1 prov=none why=no_footer_source ...
#
# `no_footer_source` is emitted only when the walk reaches a SCAN whose
# `source_type` is IN_MEMORY or BINDING. That is not "the statistics were
# missing" and not "the walk gave up" — it is that BY THE TIME THIS DOOR IS
# REACHED THE SUB-PLAN BELOW THE AGGREGATE HAS ALREADY BEEN EXECUTED AND
# REPLACED BY ITS RESIDENT BATCH. There is no file left in the plan to describe.
# Six of seven sites; the seventh (q13's `GROUP BY c_count`) is `computed_key`,
# an aggregate output, which is correct and unfixable by construction.
#
# So the ordering of the three candidate explanations is settled:
#   * `precompute_aggregate_estimates` cannot reach — TRUE (`_walk_to_scan`
#     refuses a FILTER and a JOIN), and it was never the whole story.
#   * this resolver reaches through FILTER / JOIN / PROJECT / AGGREGATE — also
#     TRUE, and it does not help, because there is no join left below the
#     aggregate at dispatch time.
#   * the door needs a RUNTIME estimate (an HLL sketch over the resident batch,
#     or the per-worker partial counts the fold already builds), not a
#     plan-time one. That is a different design, and it is the only one the
#     measurement leaves standing.
#
# ⚠ AND EVEN A PERFECT ESTIMATE WOULD NOT FIX q13. The same run measured its
# two sibling dispatches at IDENTICAL inputs — `in_rows=150000` both — with
# `actual=150000` and `actual=42`, the shape the choke point's docstring
# asserts and nothing had previously measured. BOTH were routed RADIX, by the
# ROWS arm. The harm there is an OVER-admission of a 42-group fold, and the
# scale gate is a DISJUNCTION (`n_rows >= min_rows OR group_est >= min_groups`)
# — so an estimate can only ADD admissions and can never withdraw that one. The
# cell that most visibly wants a group estimate is one a group estimate
# structurally cannot help.
#
# ⭐⭐ THE PROVENANCE PROBLEM, MEASURED ON THE REAL FIXTURES.
# ---------------------------------------------------------------------------
# There are three signals a group key can resolve through, and they are NOT
# interchangeable. Measured over the TPC-H SF1 Parquet fixtures
# (`column_ndv_estimate`'s own inputs, read straight from the
# footers):
#
#   PROV_HLL     merged HyperLogLog register state across row groups. The only
#                signal that is an honest NDV. ⚠ `hll_registers` is a
#                KOMIRA-ONLY Parquet statistics extension emitted only by our
#                writer — and the fixture data is untracked and regenerated per
#                machine, so whether a column carries it depends on which
#                generator last ran on that box. **ZERO columns of the TPC-H
#                SF1 fixtures carried it in this measurement.**
#   PROV_DCSUM   the standard-Parquet per-row-group `distinct_count`, SUMMED
#                across row groups by `column_distinct_count`. It OVER-COUNTS
#                by a factor of roughly the ROW-GROUP COUNT, because the same
#                key recurs in every row group. Measured: `o_orderpriority`
#                reports 65 over 13 row groups against a truth of 5 (13x);
#                `l_shipmode` 343 over 49 row groups against 7 (49x);
#                `l_returnflag` 147 over 49 against 3 (49x). The multiplier is
#                a property of the FILE LAYOUT, so it too moves with whichever
#                generator wrote the box's fixtures.
#   PROV_DOMAIN  the integer `min`/`max` span. An UPPER BOUND on NDV, not an
#                estimate of it. Measured: `o_orderkey` spans 6,000,000 in a
#                1,500,000-row table — 4x more distinct values than there are
#                rows, before any clamp.
#
# **AND THE TWO POPULATIONS DO NOT OVERLAP.** In the SF1 fixtures every
# LOW-cardinality group key is a string carrying `distinct_count` and no int
# domain; every HIGH-cardinality key (`ps_partkey`, `c_custkey`, `l_orderkey`,
# `o_orderkey`) carries NO `distinct_count` at all and only a domain. So the
# cells where a RADIX combine actually wins are reachable ONLY through the
# weakest signal, and the cells reachable through the middle signal are the
# ones already correctly declining. That is the honest headline, and it is why
# this ships as an instrument.
#
# ⛔ NO FALLBACK VALUE IS EVER SILENTLY CONSUMED. Every estimate carries the
# provenance of its WEAKEST contributing key, and a key that resolves through
# nothing makes the WHOLE estimate `None` — never a partial product, never a
# default. `optimizer_stats.estimate_cardinality`'s `child // 10` arm is not
# used here, not even as a clamp: priced against the three cells
# `inmem_agg_choose_strategy`'s docstring cites it is wrong in the dangerous
# direction (q11's 29,818 true groups -> 3,168, missing the win; q4's 5 true
# groups -> 5,252, crossing the 5,000 floor).
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
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
    SOURCE_IN_MEMORY,
    SOURCE_BINDING,
)
from komira_plan_ir.logical_plan_variants import AggregateData, DistinctData
from komira_plan_stats.table_stats import TableStats


# -----------------------------------------------------------------------------
# Provenance — ORDERED WEAKEST-LAST, because an estimate is only as trustworthy
# as its weakest contributing key and the aggregation rule is `max`.
# -----------------------------------------------------------------------------

comptime GROUP_EST_PROV_NONE: UInt8 = 0
"""No estimate. At least one group key resolved through nothing."""

comptime GROUP_EST_PROV_HLL: UInt8 = 1
"""Every key's NDV came from merged HyperLogLog registers — an honest distinct
count. ⚠ Requires the Komira-only footer extension; no DuckDB- or
parquet-rs-written fixture can produce this."""

comptime GROUP_EST_PROV_DCSUM: UInt8 = 2
"""At least one key fell back to the per-row-group `distinct_count` SUM. OVER-
COUNTS by roughly the row-group count. Comparable across runs only on
byte-identical fixtures."""

comptime GROUP_EST_PROV_DOMAIN: UInt8 = 3
"""At least one key resolved only through an integer `min`/`max` span. This is
an UPPER BOUND on the distinct count, not an estimate of it."""


# -----------------------------------------------------------------------------
# DECLINE REASONS — because "it returned nothing" localises nothing.
#
# ⭐ THIS VOCABULARY EXISTS BECAUSE THE FIRST LIVE RUN NEEDED IT. Every corpus
# cell printed `pred=-1 prov=none`: the estimator declined on tpch q4, q11, q12
# and all three of q13's dispatches, while the unit fixtures for the same shapes
# resolved. "Nothing resolves" is a fact with at least five different causes and
# five different fixes, and an instrument that cannot tell them apart is not
# measuring, it is reporting a mood.
# -----------------------------------------------------------------------------

comptime GROUP_EST_WHY_OK: UInt8 = 0
"""An estimate was produced."""

comptime GROUP_EST_WHY_COMPUTED_KEY: UInt8 = 1
"""A GROUP BY key is not a plain column reference, so no writer statistic
describes it. Fix: none — this is correct behaviour."""

comptime GROUP_EST_WHY_NO_STATS: UInt8 = 2
"""The walk reached a SCAN carrying no `TableStats` at all. Fix: this is a
`precompute_scan_stats` reach question, NOT an estimator question."""

comptime GROUP_EST_WHY_NO_COLUMN: UInt8 = 3
"""`TableStats` present but the column is absent from it. Fix: a naming or
projection-provenance question — the stats were built over a different schema
than the key names in scope."""

comptime GROUP_EST_WHY_NO_SIGNAL: UInt8 = 4
"""The column IS in the stats and carries neither a usable `distinct_count` nor
an integer min/max. Fix: a WRITER question — the footer does not contain the
information. This is the reason that cannot be engineered around here."""

comptime GROUP_EST_WHY_NO_FOOTER_SOURCE: UInt8 = 6
"""The walk reached a SCAN that is not a FILE source at all — an in-memory or
already-materialised batch. There is no footer to have read, so this is a PLAN
SHAPE fact, not a missing-statistics one.

⭐ SPLIT OUT OF `no_stats` AFTER THE FIRST LIVE RUN, WHICH IS WHEN IT MATTERED.
The corpus printed `why=no_stats` at five of six in-mem sites, and that single
tag covers two findings with opposite consequences: a PARQUET scan without
stats means `precompute_scan_stats` did not reach it (fixable, and a real gap),
while a non-file source means the sub-plan below the aggregate has already been
EXECUTED and replaced by its resident batch — in which case no plan-time
estimator of any design can help, because by the time the door is reached there
is no file left to describe. Conflating them would have credited or blamed the
wrong layer."""

comptime GROUP_EST_WHY_UNWALKABLE: UInt8 = 5
"""The walk hit a plan node it has no rule for (a UNION, or a leaf that is not
a SCAN — e.g. an in-memory or already-materialised source). Fix: an estimator
question, and the only one of the five that is."""


def group_est_why_name(why: UInt8) -> StaticString:
    """Short tag for the trace. Paired with `prov=`: `prov` says how much to
    trust a number that exists, `why` says what stopped one existing."""
    if why == GROUP_EST_WHY_OK:
        return "ok"
    if why == GROUP_EST_WHY_COMPUTED_KEY:
        return "computed_key"
    if why == GROUP_EST_WHY_NO_STATS:
        return "no_stats"
    if why == GROUP_EST_WHY_NO_COLUMN:
        return "no_column"
    if why == GROUP_EST_WHY_NO_SIGNAL:
        return "no_signal"
    if why == GROUP_EST_WHY_NO_FOOTER_SOURCE:
        return "no_footer_source"
    return "unwalkable"


def group_est_prov_name(prov: UInt8) -> StaticString:
    """Short tag for the trace. The tag is the point: a number without its
    provenance is exactly the artefact this module refuses to emit."""
    if prov == GROUP_EST_PROV_HLL:
        return "hll"
    if prov == GROUP_EST_PROV_DCSUM:
        return "dcsum"
    if prov == GROUP_EST_PROV_DOMAIN:
        return "domain"
    return "none"


struct GroupEstimate(ImplicitlyCopyable, Movable):
    """A predicted group count and the provenance of the weakest signal that
    produced it.

    `groups == -1` means NO ESTIMATE, and it is the common answer. It is not an
    error and it is not a zero — it is the module declining to invent one.
    """

    var groups: Int
    var provenance: UInt8
    var why: UInt8
    """Why no estimate was produced (`GROUP_EST_WHY_OK` when one was). The
    decline reason is the load-bearing output when `groups == -1`, which is the
    common case."""

    @always_inline
    def __init__(
        out self,
        groups: Int = -1,
        provenance: UInt8 = GROUP_EST_PROV_NONE,
        why: UInt8 = GROUP_EST_WHY_UNWALKABLE,
    ):
        self.groups = groups
        self.provenance = provenance
        self.why = why

    @always_inline
    def is_known(self) -> Bool:
        return self.groups >= 0


# -----------------------------------------------------------------------------
# Row upper bound — the clamp. Returns a bound that is TRUE, or nothing.
# -----------------------------------------------------------------------------


def plan_row_upper_bound(imm plan: LogicalPlan) -> Optional[Int]:
    """A **true** upper bound on the rows `plan` can emit, or `None`.

    Deliberately NOT `optimizer_stats.estimate_cardinality`: that is an
    ESTIMATE (selectivity factors, a 10% aggregate reduction, a 1,000,000-row
    default for a stats-less scan), and an estimate used as a clamp can saw a
    correct NDV product DOWNWARD — a second way to be wrong. Every arm below
    either returns a quantity the node structurally cannot exceed, or gives up.

    `PLAN_JOIN` gives up on purpose: a join can FAN OUT, so neither side's row
    count bounds the output.
    """
    var tag = plan.tag
    if tag == PLAN_SCAN and plan._scan:
        ref sd = plan._scan.value()[]
        if sd.row_count:
            return Optional[Int](sd.row_count.value())
        if sd.table_stats:
            var rc = sd.table_stats.value().row_count
            if rc > 0:
                return Optional[Int](rc)
        return None
    if tag == PLAN_FILTER and plan._filter:
        return plan_row_upper_bound(plan._filter.value()[].child[])
    if tag == PLAN_PROJECT and plan._project:
        return plan_row_upper_bound(plan._project.value()[].child[])
    if tag == PLAN_SORT and plan._sort:
        return plan_row_upper_bound(plan._sort.value()[].child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return plan_row_upper_bound(plan._distinct.value()[].child[])
    if tag == PLAN_AGGREGATE and plan._aggregate:
        # Groups can never exceed the rows they were folded from.
        return plan_row_upper_bound(plan._aggregate.value()[].child[])
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return plan_row_upper_bound(plan._partition_by.value()[].child[])
    if tag == PLAN_LIMIT and plan._limit:
        var n = plan._limit.value()[].n
        var child = plan_row_upper_bound(plan._limit.value()[].child[])
        if child and child.value() < n:
            return child
        return Optional[Int](n)
    if tag == PLAN_TOPN and plan._topn:
        var n2 = plan._topn.value()[].n
        var child2 = plan_row_upper_bound(plan._topn.value()[].child[])
        if child2 and child2.value() < n2:
            return child2
        return Optional[Int](n2)
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        # Per-partition N with an unknown partition count: no bound.
        return None
    return None


# -----------------------------------------------------------------------------
# Per-key resolution.
# -----------------------------------------------------------------------------


def _ndv_from_scan_stats(
    imm stats: TableStats, name: String
) -> GroupEstimate:
    """Resolve one column against one scan's `TableStats`, reporting WHICH of
    the three signals answered.

    ⭐ CLAMPED TO THE SCAN'S OWN ROW COUNT HERE, at the point of resolution.
    That is the only place a per-key bound is knowable when the aggregate sits
    over a JOIN, where `plan_row_upper_bound` correctly refuses to bound the
    output at all. Without it, `o_orderkey`'s measured 6,000,000-wide domain
    would be reported unclamped for a 1,500,000-row table.

    A non-positive `distinct_count` reads as ABSENT, not as zero groups: "the
    writer wrote nothing useful" and "this column has no values" are
    indistinguishable here and the first is overwhelmingly more common.
    """
    var idx = stats.find_column(name)
    if idx < 0:
        return GroupEstimate(-1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_COLUMN)
    var row_cap = stats.row_count
    ref cs = stats.column_stats[idx]
    if cs.distinct_count:
        var dc = cs.distinct_count.value()
        if dc > 0:
            if row_cap > 0 and dc > row_cap:
                dc = row_cap
            # ⛔ THE PROVENANCE ACCESSOR FAILS OPEN, AND THIS IS WHERE THAT
            # IS CLOSED. `TableStats.column_distinct_count_from_hll` returns
            # **True** when the `from_hll` parallel array is EMPTY — a
            # deliberate backward-compat rule for pre-Phase-2.a fixtures whose
            # docstring reads "assume HLL-backed". For a COST MODEL choosing
            # between two join orders, an optimistic default is a defensible
            # tie-break. For an ACCURACY MEASUREMENT it is the exact artefact
            # this module forbids: it would stamp `hll` — "an honest distinct
            # count" — on a number that is really a row-group SUM, and every
            # reader of the resulting table would over-trust it.
            #
            # So an ABSENT provenance array is UNVERIFIED, and unverified
            # degrades to the WEAKER claim. `build_table_stats_from_provider`
            # (the only producer that reaches a real Parquet footer) always
            # populates the array, so this costs production nothing and only
            # refuses to launder a fixture.
            var prov = GROUP_EST_PROV_DCSUM
            if (
                len(stats.from_hll) > 0
                and stats.column_distinct_count_from_hll(name)
            ):
                prov = GROUP_EST_PROV_HLL
            return GroupEstimate(dc, prov, GROUP_EST_WHY_OK)
    # An INT domain only — a float min/max says nothing about a distinct count,
    # and a string min/max is a lexicographic range, not a countable domain.
    var no_signal = GroupEstimate(
        -1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_SIGNAL
    )
    if not cs.min_value or not cs.max_value:
        return no_signal
    ref mn = cs.min_value.value()
    ref mx = cs.max_value.value()
    if not mn.is_int() or not mx.is_int():
        return no_signal
    var lo = Int(mn.int_val)
    var hi = Int(mx.int_val)
    if hi < lo:
        return no_signal
    var span = hi - lo + 1
    if span < 1:
        return no_signal
    if row_cap > 0 and span > row_cap:
        span = row_cap
    return GroupEstimate(span, GROUP_EST_PROV_DOMAIN, GROUP_EST_WHY_OK)


def _project_source_name(
    imm plan: LogicalPlan, name: String
) -> Optional[String]:
    """The child-side column a PROJECT's output column `name` is a pure
    rename/passthrough of, or `None` when it is COMPUTED.

    Matched on the expression's OWN produced name, never positionally against
    `output_schema`: the two can disagree in length (a wildcard expansion, a
    CSE-introduced column) and a positional match that slipped by one would
    resolve a key to the WRONG column's NDV — a wrong-but-confident number,
    which is the single artefact this module must not emit.
    """
    ref pd = plan._project.value()[]
    for i in range(len(pd.exprs)):
        ref e = pd.exprs[i]
        if e.is_col_ref():
            if e.col_ref_name() == name:
                return Optional[String](name)
            continue
        if e.is_alias():
            if e.alias_name() != name:
                continue
            ref child = e.alias_child_ref()
            if child.is_col_ref():
                return Optional[String](child.col_ref_name())
            return None
    return None


def _resolve_key_ndv(imm plan: LogicalPlan, name: String) -> GroupEstimate:
    """Upper bound on the distinct values of column `name` in the rows `plan`
    emits, with provenance — or an unknown `GroupEstimate`.

    Every recursive arm preserves the UPPER-BOUND property: FILTER, LIMIT, TOPN
    and an inner/semi JOIN can only remove rows, so they can only remove
    distinct values; PROJECT renames; an AGGREGATE that GROUPS BY the column
    passes its distinct values through exactly.
    """
    var tag = plan.tag
    if tag == PLAN_SCAN and plan._scan:
        ref sd = plan._scan.value()[]
        if not sd.table_stats:
            # ⭐ WHICH KIND OF "no stats" THIS IS DECIDES WHO OWNS THE GAP.
            # A non-file source never had a footer, so no plan-time estimator
            # can ever describe it; a FILE source without stats is a
            # `precompute_scan_stats` reach gap and is fixable.
            if sd.source_type == SOURCE_IN_MEMORY or sd.source_type == SOURCE_BINDING:
                return GroupEstimate(
                    -1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_FOOTER_SOURCE
                )
            return GroupEstimate(
                -1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_STATS
            )
        return _ndv_from_scan_stats(sd.table_stats.value(), name)
    if tag == PLAN_PROJECT and plan._project:
        var src = _project_source_name(plan, name)
        if not src:
            return GroupEstimate(
                -1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_COMPUTED_KEY
            )
        return _resolve_key_ndv(plan._project.value()[].child[], src.value())
    if tag == PLAN_FILTER and plan._filter:
        return _resolve_key_ndv(plan._filter.value()[].child[], name)
    if tag == PLAN_SORT and plan._sort:
        return _resolve_key_ndv(plan._sort.value()[].child[], name)
    if tag == PLAN_LIMIT and plan._limit:
        return _resolve_key_ndv(plan._limit.value()[].child[], name)
    if tag == PLAN_TOPN and plan._topn:
        return _resolve_key_ndv(plan._topn.value()[].child[], name)
    if tag == PLAN_DISTINCT and plan._distinct:
        return _resolve_key_ndv(plan._distinct.value()[].child[], name)
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return _resolve_key_ndv(plan._partition_by.value()[].child[], name)
    if tag == PLAN_AGGREGATE and plan._aggregate:
        # Only a GROUP BY key survives an aggregate as a base column. An
        # aggregate OUTPUT (q13's `c_count`) has no writer statistic anywhere,
        # and `unknown` is the correct answer for it, not a gap.
        ref ad = plan._aggregate.value()[]
        for k in range(len(ad.group_by)):
            ref e = ad.group_by[k]
            if e.is_col_ref() and e.col_ref_name() == name:
                return _resolve_key_ndv(ad.child[], name)
        # An aggregate OUTPUT column (q13's `c_count`). Reported as a computed
        # key because that is what it is: a derived value no writer described.
        return GroupEstimate(
            -1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_COMPUTED_KEY
        )
    if tag == PLAN_JOIN and plan._join:
        ref jd = plan._join.value()[]
        var l = _resolve_key_ndv(jd.left[], name)
        var r = _resolve_key_ndv(jd.right[], name)
        return _tighter(l, r)
    if tag == PLAN_ASOF_JOIN and plan._asof_join:
        ref aj = plan._asof_join.value()[]
        return _tighter(
            _resolve_key_ndv(aj.left[], name),
            _resolve_key_ndv(aj.right[], name),
        )
    # PLAN_UNION and anything else: a union's distinct set is the union of its
    # inputs' and neither input bounds it, so there is no sound bound here.
    return GroupEstimate()


def _tighter(imm a: GroupEstimate, imm b: GroupEstimate) -> GroupEstimate:
    """The better of two resolutions of the same name on two join sides.

    A value present in an inner join's output is present in BOTH contributing
    sides, so the smaller bound is the correct one. Provenance travels with the
    value that won — reporting the other side's stronger tag for a number it
    did not produce would be the fallback-laundering this module forbids.
    """
    if not a.is_known() and not b.is_known():
        # Neither side resolved. Report the MORE SPECIFIC reason: the column
        # lives on exactly one side, and that side's answer ("no signal for it")
        # localises the problem where the other's ("no column of that name")
        # only says the key was not there — which is expected of the side it
        # does not belong to.
        if a.why == GROUP_EST_WHY_NO_COLUMN:
            return GroupEstimate(-1, GROUP_EST_PROV_NONE, b.why)
        return GroupEstimate(-1, GROUP_EST_PROV_NONE, a.why)
    if not a.is_known():
        return GroupEstimate(b.groups, b.provenance, b.why)
    if not b.is_known():
        return GroupEstimate(a.groups, a.provenance, a.why)
    if a.groups <= b.groups:
        return GroupEstimate(a.groups, a.provenance, a.why)
    return GroupEstimate(b.groups, b.provenance, b.why)




# -----------------------------------------------------------------------------
# Entry points.
# -----------------------------------------------------------------------------


comptime _GROUP_EST_CEILING: Int = 1_000_000_000
"""Overflow guard for the multi-key product when no row bound is derivable (an
aggregate directly over a join). Not a threshold and not tunable — it exists
only so `a * b` cannot wrap."""


def _saturating_mul(a: Int, b: Int, imm bound: Optional[Int]) -> Int:
    """`a * b`, saturated at `bound` (or a fixed ceiling when none is known).

    The independence assumption behind a product of per-key NDVs is the largest
    source of over-estimation here; the saturation is what stops it becoming an
    unbounded one."""
    var ceiling = bound.value() if bound else _GROUP_EST_CEILING
    if b <= 0:
        return a
    if a > ceiling // b:
        return ceiling
    var prod = a * b
    if prod > ceiling:
        return ceiling
    return prod


def _estimate_over(
    imm child: LogicalPlan, imm keys: List[String]
) -> GroupEstimate:
    """Product of the per-key bounds over `child`, clamped, with the WEAKEST
    contributing provenance.

    ⛔ ALL-OR-NOTHING. One unresolvable key makes the whole answer unknown. A
    product over the keys we happen to understand is not an estimate of
    anything, and it is the shape most likely to look confident while being
    arbitrarily wrong.
    """
    if len(keys) == 0:
        # A scalar aggregate emits exactly one row. Arithmetic, not estimation,
        # so it needs no statistic and carries no provenance risk.
        return GroupEstimate(1, GROUP_EST_PROV_HLL, GROUP_EST_WHY_OK)
    var bound = plan_row_upper_bound(child)
    var product: Int = 1
    var weakest = GROUP_EST_PROV_HLL
    for k in range(len(keys)):
        var per_key = _resolve_key_ndv(child, keys[k])
        if not per_key.is_known():
            # ALL-OR-NOTHING, and the FIRST failing key's reason is the one
            # reported: it is the one a fix would have to address first.
            return GroupEstimate(-1, GROUP_EST_PROV_NONE, per_key.why)
        if per_key.provenance > weakest:
            weakest = per_key.provenance
        product = _saturating_mul(product, per_key.groups, bound)
    if bound and product > bound.value():
        product = bound.value()
    if product < 1:
        product = 1
    return GroupEstimate(product, weakest, GROUP_EST_WHY_OK)


def estimate_groups_for_agg(imm agg_data: AggregateData) -> GroupEstimate:
    """Predicted group count for an AGGREGATE node, or an unknown estimate.

    This is the entry point the in-mem door uses, because that door holds an
    `AggregateData` and not the enclosing `LogicalPlan`.
    """
    var n = len(agg_data.group_by)
    var keys = List[String]()
    for k in range(n):
        ref e = agg_data.group_by[k]
        if not e.is_col_ref():
            # A computed key (`GROUP BY substr(x, 1, 4)`): no writer statistic
            # describes a derived value, and per the all-or-nothing rule one
            # such key makes the whole node unknown.
            return GroupEstimate(
                -1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_COMPUTED_KEY
            )
        keys.append(e.col_ref_name())
    return _estimate_over(agg_data.child[], keys)


def estimate_groups_for_distinct(imm d: DistinctData) -> GroupEstimate:
    """Predicted distinct-row count for a DISTINCT node."""
    var keys = List[String]()
    if d.columns:
        keys = d.columns.value().copy()
    else:
        ref child_schema = d.child[].output_schema
        var nc = child_schema.num_columns()
        if nc == 0:
            return GroupEstimate()
        for c in range(nc):
            keys.append(child_schema.field_name(c))
    return _estimate_over(d.child[], keys)


def estimate_group_count(imm plan: LogicalPlan) -> GroupEstimate:
    """Dispatch on the plan tag. Unknown for any node that is neither an
    AGGREGATE nor a DISTINCT."""
    if plan.tag == PLAN_AGGREGATE and plan._aggregate:
        return estimate_groups_for_agg(plan._aggregate.value()[])
    if plan.tag == PLAN_DISTINCT and plan._distinct:
        return estimate_groups_for_distinct(plan._distinct.value()[])
    return GroupEstimate()
