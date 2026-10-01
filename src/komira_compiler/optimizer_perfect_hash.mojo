# =============================================================================
# optimizer_perfect_hash.mojo — the perfect-hash planner detector family
# =============================================================================
# ⛔ NOT THE LIVE PERFECT-HASH ROUTE. Nothing in the engine calls this module:
# the live perfect-hash aggregation is `PerfectHashAggUntyped` /
# `perfect_hash_untyped_envelope_supported` in `komira_engine_operators`,
# chosen by the SDK's aggregate dispatcher. This module is a statistics-driven
# detector kept with its tests; an edit here changes no engine behaviour.
# =============================================================================

# =============================================================================
# DetectPerfectHashAgg -- planner rewrite rule
# =============================================================================
#
# Walks a LogicalPlan looking for the canonical PerfectHash shape:
#
#       Aggregate(keys=[<single INT32/INT64 col>], agg_exprs=[... no
#                 COUNT_DISTINCT ...],
#                 child=Scan(Parquet, ...))
#
# When found AND the source's column-chunk statistics show the key
# column's global [min, max] domain is <= 65536, returns an
# eligibility decision carrying `(domain_size, key_offset, key_type_id,
# key_name)` -- everything PerfectHashAggSink needs for construction.
#
# Source statistics are read through the `StatsProvider` trait
# (`komira_core.plan.stats_provider`), not `FileMetaData` /
# `ParquetType` directly. The trait is format-agnostic, so the same
# rewrite rule trips on any format's stats provider without a planner
# change. The 65536-ceiling check stays here (policy decision) and
# dispatches through the `compute_int_key_domain` helper in
# `stats_helpers.mojo`.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.agg_expr import AGG_COUNT_DISTINCT
from komira_core.plan.expr import Expr, EXPR_COL_REF, EXPR_ALIAS
from komira_core.plan.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_core.plan.physical_type import PhysicalType
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.stats_provider import StatsProvider

from .stats_helpers import compute_int_key_domain


# =============================================================================
# Constants
# =============================================================================
#
# Single-key + composite domain ceiling (matches the perfect-hash
# aggregate's own `_MAX_PERFECT_HASH_DOMAIN`).

comptime _MAX_PERFECT_HASH_DOMAIN: Int = 65_536


# =============================================================================
# PerfectHash eligibility (single-int-key) -- StatsProvider-backed
# =============================================================================
#
# Walks per-row-group min/max via the `StatsProvider` trait, which
# the source-format crate (`komira_parquet.ParquetStatsProvider` today,
# `komira_jsonl.JsonStatsProvider` etc.) implements. The
# domain-size + ceiling math is encapsulated in `compute_int_key_domain`
# (compiler/stats_helpers.mojo). This file owns ONLY the
# perfect-hash-specific shape match.


def check_perfect_hash_eligible[T: StatsProvider](
    stats: T,
    key_name: String,
    num_rgs: Int,
) -> Tuple[Bool, Int, Int64, UInt8]:
    """Check if PerfectHash aggregation is applicable.

    Returns `(eligible, domain_size, key_offset, key_type_id)`.
    `eligible=False` if the column is missing, the writer didn't emit
    min/max stats, the domain is too large, or the key is not int.

    Reads statistics through `StatsProvider`. The runtime-
    stats walk + INT32/INT64 sign-extension dispatch lives in
    `compute_int_key_domain` (the helper); this function only owns
    the perfect-hash policy (ceiling + return shape).

    `num_rgs` is accepted for backward compatibility with callers but
    is no longer load-bearing -- the helper walks
    `stats.num_row_groups` itself. The parameter is preserved so
    that callers passing `num_rgs = stats.num_row_groups` continue
    to type-check; future callers may drop it.
    """
    # Quick guard: caller-supplied `num_rgs` must agree with
    # `stats.num_row_groups`. Bail if they disagree to preserve
    # the previous "fail closed" semantics (the legacy code rejected
    # whenever `rg_i >= len(metadata.row_groups)`).
    if num_rgs <= 0:
        return (False, 0, Int64(0), UInt8(0))
    if num_rgs > stats.num_row_groups():
        return (False, 0, Int64(0), UInt8(0))

    var names = List[String]()
    names.append(key_name)
    var dom_opt = compute_int_key_domain(stats, names, _MAX_PERFECT_HASH_DOMAIN)
    if not dom_opt:
        return (False, 0, Int64(0), UInt8(0))

    var dom = dom_opt.value()
    return (True, dom[0], Int64(dom[1]), dom[2])


# =============================================================================
# PerfectHashComposite eligibility -- StatsProvider-backed (Stream AI)
# =============================================================================
#
# Mirrors `check_perfect_hash_eligible` but for multiple int keys.
# Walks each key column's per-RG `column_rg_min_max` to compute global
# [min, max], then multiplies per-key ranges to compute the composite
# domain. Returns packed per-key info so the streaming sink can compute
# composite indices without re-reading metadata.
#
# Output layout (same shape as `_detect_composite_domain` in
# agg_perfect_hash.mojo so the existing `_build_perfect_hash_composite_output`
# matcher can reuse the info array):
#   [composite, col0, col1, ..., min0, min1, ..., range0, range1, ...,
#    stride0, stride1, ..., num_keys]
#
# NOTE: col indices returned here are *projection-relative* (the
# k-th key projects to column k of the projected batch), NOT raw
# Parquet leaf indices. The caller must pass the same projection
# ordering when constructing the sink so row-time column lookup matches.
#
# Domain ceiling is `_MAX_PERFECT_HASH_DOMAIN` (65_536) to match
# single-key. Returns `(False, 0, [])` if ineligible.

from std.collections import List as _StdList


def check_perfect_hash_composite_eligible[T: StatsProvider](
    stats: T,
    key_names: List[String],
    num_rgs: Int,
) -> Tuple[Bool, Int, List[Int]]:
    """Return `(eligible, composite_domain, info_list)`.

    `info_list` is packed exactly the way
    `agg_perfect_hash._detect_composite_domain` packs it so
    `_build_perfect_hash_composite_output` stays reusable.

    The col-idx slots hold RESOLVED PROJECTED column indices (col idx
    = k for the k-th key) -- the caller projects keys first via
    `_agg_needed_column_names_local`, so this matches what the sink
    sees.
    """
    var num_keys = len(key_names)
    var empty = List[Int]()
    if num_keys < 2:
        return (False, 0, empty^)
    if num_rgs <= 0:
        var e2 = List[Int]()
        return (False, 0, e2^)
    if num_rgs > stats.num_row_groups():
        var e3 = List[Int]()
        return (False, 0, e3^)

    var key_mins = List[Int]()
    var key_maxs = List[Int]()
    var key_type_ids = List[UInt8]()

    for k in range(num_keys):
        var name = key_names[k]

        # Physical type must be INT32 / INT64.
        var pt_opt = stats.column_physical_type(name)
        if not pt_opt:
            var e = List[Int]()
            return (False, 0, e^)
        var pt = pt_opt.value()
        var ktid: UInt8
        if pt == PhysicalType.INT32:
            ktid = ArrowType.INT32.type_id
        elif pt == PhysicalType.INT64:
            ktid = ArrowType.INT64.type_id
        else:
            var e = List[Int]()
            return (False, 0, e^)
        key_type_ids.append(ktid)

        # Walk every RG's stats to build global min/max for this key.
        var gmin: Int64 = 0x7FFFFFFFFFFFFFFF
        var gmax: Int64 = -0x7FFFFFFFFFFFFFFF - 1
        for rg_i in range(num_rgs):
            var mm_opt = stats.column_rg_min_max(name, rg_i)
            if not mm_opt:
                var e = List[Int]()
                return (False, 0, e^)
            # `Tuple[ScalarValue, ScalarValue]` is not ImplicitlyCopyable
            # (ScalarValue carries a String field). Borrow the tuple and
            # peel out the int_val fields -- the int-domain check is the
            # only thing we need.
            ref mm = mm_opt.value()
            var mn = mm[0].int_val
            var mx = mm[1].int_val
            if mn < gmin:
                gmin = mn
            if mx > gmax:
                gmax = mx

        key_mins.append(Int(gmin))
        key_maxs.append(Int(gmax))

    # Compute per-key ranges + composite product.
    var key_ranges = List[Int]()
    var composite = 1
    for k in range(num_keys):
        var kr = key_maxs[k] - key_mins[k] + 1
        if kr <= 0:
            var e = List[Int]()
            return (False, 0, e^)
        key_ranges.append(kr)
        composite *= kr
        if composite <= 0 or composite > _MAX_PERFECT_HASH_DOMAIN:
            var e = List[Int]()
            return (False, 0, e^)

    # Row-major strides (last key stride = 1).
    var strides = List[Int]()
    for _ in range(num_keys):
        strides.append(0)
    strides[num_keys - 1] = 1
    var k2 = num_keys - 2
    while k2 >= 0:
        strides[k2] = strides[k2 + 1] * key_ranges[k2 + 1]
        k2 -= 1

    # Pack: [composite, col0..colK-1, min0..minK-1, range0..rangeK-1,
    #        stride0..strideK-1, num_keys].
    # col idx: position in `key_names` (0..num_keys-1) since the
    # projected batch places keys in `key_names` order.
    var info = List[Int]()
    info.append(composite)
    for k in range(num_keys):
        info.append(k)  # projected col idx = key position
    for k in range(num_keys):
        info.append(key_mins[k])
    for k in range(num_keys):
        info.append(key_ranges[k])
    for k in range(num_keys):
        info.append(strides[k])
    info.append(num_keys)

    # Per-key type ids are intentionally NOT in `info` -- the legacy
    # output-builder layout doesn't carry them and the sink derives
    # them from `batch.column_at(k)` at run time. Keeping this comment
    # so a future "carry them too" change is intentional.
    return (True, composite, info^)


# =============================================================================
# Strategy decision
# =============================================================================


@fieldwise_init
struct PerfectHashStrategy(Copyable, Movable):
    """Outcome of DetectPerfectHashAgg on a LogicalPlan.

    When `eligible` is True, the agg subtree is a PerfectHash candidate
    and the remaining fields hold the construction parameters for
    PerfectHashAggSink. When False, callers fall back to the FlatHash
    path.
    """
    var eligible: Bool
    var domain_size: Int
    var key_offset: Int64
    var key_type_id: UInt8
    var key_name: String

    @staticmethod
    def ineligible() -> Self:
        return PerfectHashStrategy(False, 0, Int64(0), UInt8(0), String(""))


# =============================================================================
# Expression key-name extraction
# =============================================================================


def _extract_single_key_name(expr: Expr) -> String:
    """Resolve `expr` to a column name if it is a ColRef or an Alias over
    a ColRef. Returns the empty string otherwise.
    """
    if expr.tag == EXPR_COL_REF:
        return expr.col_ref_name()
    if expr.tag == EXPR_ALIAS:
        ref child = expr.alias_child_ref()
        if child.tag == EXPR_COL_REF:
            return child.col_ref_name()
    return String("")


# =============================================================================
# Shape-only detection (no metadata required) -- used by the unit test
# =============================================================================


def detect_perfect_hash_agg_shape(plan: LogicalPlan) -> Bool:
    """Return True iff `plan` is an Aggregate(single int/bool col,
    no COUNT_DISTINCT) directly over Scan(Parquet).

    Shape-only check -- does NOT consult Parquet statistics. ⛔ There is no
    "execute-time entry point": `detect_perfect_hash_agg` has
    zero live callers, as does this function -- the only remaining referrers
    are `__init__.mojo` re-exports and the unit test. It WOULD additionally
    validate the metadata-derived domain size. See the DEAD MODULE banner at
    the top of this file for the live impl and the one live door.
    """
    if plan.tag != PLAN_AGGREGATE:
        return False
    ref agg = plan.aggregate_data_ref()
    if len(agg.group_by) != 1:
        return False
    if len(agg.agg_exprs) == 0:
        return False
    for a in range(len(agg.agg_exprs)):
        if agg.agg_exprs[a].func == AGG_COUNT_DISTINCT:
            return False
    var key_name = _extract_single_key_name(agg.group_by[0])
    if key_name == "":
        return False
    # Must be an INT32 / INT64 key in the child schema.
    ref child = agg.child[]
    var key_type = ArrowType.NULL
    var found = False
    for i in range(child.output_schema.num_columns()):
        if child.output_schema.field_name(i) == key_name:
            key_type = child.output_schema.field_arrow_type(i)
            found = True
            break
    if not found:
        return False
    if key_type != ArrowType.INT32 and key_type != ArrowType.INT64:
        return False
    # Child must be Scan(Parquet).
    if child.tag != PLAN_SCAN:
        return False
    ref scan = child.scan_data_ref()
    if scan.source_type != SOURCE_PARQUET:
        return False
    return True


# =============================================================================
# Full detection (shape + StatsProvider-backed metadata)
# =============================================================================


def detect_perfect_hash_agg[T: StatsProvider](
    plan: LogicalPlan,
    stats: T,
    num_rgs: Int,
) -> PerfectHashStrategy:
    """Full `DetectPerfectHashAgg` rewrite: shape + footer statistics.

    Returns a `PerfectHashStrategy` whose `eligible` is True iff the
    plan matches the shape check AND the key column's global
    [min, max] domain (from column-chunk stats across all RGs) is
    <= `_MAX_PERFECT_HASH_DOMAIN` (65536).

    When eligible, the caller constructs a PerfectHashAggSink
    with the returned `domain_size` / `key_offset` / `key_type_id`.
    """
    if not detect_perfect_hash_agg_shape(plan):
        return PerfectHashStrategy.ineligible()

    ref agg = plan.aggregate_data_ref()
    var key_name = _extract_single_key_name(agg.group_by[0])

    var tup = check_perfect_hash_eligible(stats, key_name, num_rgs)
    if not tup[0]:
        return PerfectHashStrategy.ineligible()

    return PerfectHashStrategy(
        True, tup[1], tup[2], tup[3], key_name
    )
