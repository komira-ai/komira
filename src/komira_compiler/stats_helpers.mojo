# =============================================================================
# stats_helpers.mojo — defines only `compute_int_key_domain`
# =============================================================================
# ⛔ NOT THE LIVE PERFECT-HASH ROUTE: only `optimizer_perfect_hash` (itself
# unwired) and the tests call this module. See that module's header.
# =============================================================================

# =============================================================================
# stats_helpers -- StatsProvider-backed plan-time stat helpers
# =============================================================================
#
# The `StatsProvider` trait (in `komira_core.plan.stats_provider`) is
# intentionally policy-free: it exposes per-row-group min/max, physical
# type, distinct count, and total row count, but it does NOT bake in any
# optimizer thresholds (e.g. the perfect-hash 65536 ceiling). Without
# the helpers in this module, every consumer that wanted to ask "is the
# domain of this int column smaller than `ceiling`?" would have to
# reimplement the per-RG min/max walk + sign-extension dispatch.
#
# This module supplies the canonical helpers:
#
#   * `compute_int_key_domain(stats, names, ceiling) -> Optional[(domain_size,
#       key_offset, type_id)]`
#       Single-int-key version. Walks per-RG min/max for `names[0]` to
#       compute the global `[min, max]` and returns the domain size + a
#       (positive) bias offset (so callers can compute a non-negative
#       slot index as `value + key_offset`) + an Arrow type id (INT32 /
#       INT64) for downstream sink dispatch. Returns None when:
#         * `names` is empty or has more than one entry
#         * the column is not present, or has no min/max stats in some RG
#         * the column's physical type is not INT32 / INT64
#         * the resulting domain is non-positive or > `ceiling`
#
# The 65536-ceiling check stays at the CALLER (`optimizer_perfect_hash`)
# because different optimizer rules want different ceilings (single-key
# perfect-hash is 65536; composite is `ceiling^num_keys`; future shapes
# may pick others). The helper exposes the raw domain so the caller can
# decide.
#
# Mojo 0.26.3 monomorphizes `[T: StatsProvider]` at the user's compile
# time, so per-call overhead is identical to a direct method call on
# the concrete struct (no vtable, no dyn dispatch).
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.physical_type import PhysicalType
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.stats_provider import StatsProvider


# -----------------------------------------------------------------------------
# Single-key domain check (RFC v3.1 §5.1).
# -----------------------------------------------------------------------------


def compute_int_key_domain[T: StatsProvider](
    stats: T,
    names: List[String],
    ceiling: Int,
) -> Optional[Tuple[Int, Int, UInt8]]:
    """Return `(domain_size, key_offset, type_id)` for a single int key
    column whose `[min, max]` domain (folded across all row groups via
    `stats.column_rg_min_max`) is non-empty AND `<= ceiling`. Returns
    None otherwise.

    The first element of the returned tuple is the domain size:
    `(global_max - global_min) + 1`. The second is the bias offset:
    `-global_min` (so a runtime hash kernel can compute
    `slot_idx = value + key_offset` and get a non-negative index in
    `[0, domain_size)`). The third is the Arrow `type_id` (INT32 or
    INT64) so the runtime knows which unsigned-extension dispatch to
    use when reading values.

    Args:
        stats: Any `StatsProvider` impl. The concrete impl
            (`ParquetStatsProvider` today, future formats tomorrow)
            is responsible for sign-extending INT32 stats during decode
            -- this helper treats `ScalarValue.int_val` as the
            already-sign-extended canonical int.
        names: List of group-by key column names. Must have exactly
            one entry; multi-key composite domain checks live in the
            caller (`optimizer_perfect_hash.check_perfect_hash_composite_eligible`)
            because the composite shape returns a richer info-list.
        ceiling: Inclusive upper bound on the domain size. Callers
            specify their own ceiling -- 65536 for single-key
            perfect-hash today; future optimizer rules may pick others.

    Returns:
        `Some((domain_size, key_offset, type_id))` when every
        precondition holds; `None` otherwise.
    """
    if len(names) != 1:
        return None

    var name = names[0]

    # Physical type must be an int family (INT32 / INT64). The
    # PhysicalType.is_int helper covers both.
    var pt_opt = stats.column_physical_type(name)
    if not pt_opt:
        return None
    var pt = pt_opt.value()
    if not pt.is_int():
        return None

    # Map physical type to an Arrow `type_id` for downstream sink dispatch.
    # The PerfectHash sink's hot loop selects `value + offset` as a
    # `Scalar[DType.int64]` regardless of source width; the type_id is
    # propagated so the source-side decoder can pick the right
    # PrimitiveArray slice (INT32 vs INT64).
    var type_id: UInt8
    if pt == PhysicalType.INT32:
        type_id = ArrowType.INT32.type_id
    elif pt == PhysicalType.INT64:
        type_id = ArrowType.INT64.type_id
    else:
        return None

    var num_rgs = stats.num_row_groups()
    if num_rgs <= 0:
        return None

    # Walk each RG's min/max via the trait. The implementor (e.g.
    # `ParquetStatsProvider`) handles sign-extension of INT32 raw
    # stats; we receive `ScalarValue.int_val: Int64` already-decoded.
    var global_min: Int64 = 0x7FFFFFFFFFFFFFFF
    var global_max: Int64 = -0x7FFFFFFFFFFFFFFF - 1
    for rg_idx in range(num_rgs):
        var mm_opt = stats.column_rg_min_max(name, rg_idx)
        if not mm_opt:
            # Missing stats in any RG -- bail out (matches the previous
            # `check_perfect_hash_eligible` shape that rejected on missing).
            return None
        # `Tuple[ScalarValue, ScalarValue]` is not ImplicitlyCopyable
        # because `ScalarValue` carries a `String` field. Take a borrow
        # and copy the int_val scalar fields out -- the only thing the
        # int-domain check needs.
        ref mm = mm_opt.value()
        var mn = mm[0].int_val
        var mx = mm[1].int_val
        if mn < global_min:
            global_min = mn
        if mx > global_max:
            global_max = mx

    var domain_size = Int(global_max - global_min) + 1
    if domain_size <= 0 or domain_size > ceiling:
        return None

    var key_offset = Int(-global_min)
    return Optional[Tuple[Int, Int, UInt8]]((domain_size, key_offset, type_id))
