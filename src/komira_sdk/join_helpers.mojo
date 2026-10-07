# =============================================================================
# join_helpers -- DataFrame join validation + plan-building helpers
# =============================================================================
#
# Free-function bodies for `DataFrame._build_join_plan` and
# `DataFrame._validate_join_arg_shape`. Extracted from `dataframe.mojo`
# to keep that file under the 1000-LOC Mojo-JIT-hang
# threshold.
#
# The DataFrame methods are now thin shims that own the field-extraction
# (`self._take_plan()`, `self._take_reg()`) and delegate the body to one
# of these helpers. Behavior is byte-identical to the originals.
# =============================================================================

from komira_scan_source.compiler_registry import InMemoryRegistry
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JOIN_ALGO_AUTO, JOIN_ALGO_HASH, JOIN_ALGO_SORT_MERGE,
)


# =============================================================================
# _BuiltJoin -- (plan, registry, cnt) bundle returned by _build_join_plan_impl
# =============================================================================
#
# Mojo 0.26.3's stdlib `Tuple` requires Copyable elements; LogicalPlan
# and InMemoryRegistry are Movable-only. This Movable-only struct is
# the canonical replacement for the missing `Tuple[Movable...]`.
#
# Fields are wrapped in `Optional` so callers can `take_plan()` /
# `take_reg()` to extract the owned values without triggering the
# Mojo 0.26.3 partial-move-from-struct-field error (hard ban #11).
# =============================================================================
struct _BuiltJoin(Movable):
    var _plan: Optional[LogicalPlan]
    var _reg: Optional[InMemoryRegistry]
    var cnt: Int

    def __init__(
        out self,
        var plan: LogicalPlan,
        var reg: InMemoryRegistry,
        cnt: Int,
    ):
        self._plan = Optional[LogicalPlan](plan^)
        self._reg = Optional[InMemoryRegistry](reg^)
        self.cnt = cnt

    def take_plan(mut self) -> LogicalPlan:
        """Move the plan out. Leaves None. Caller owns the result."""
        return self._plan.take()

    def take_reg(mut self) -> InMemoryRegistry:
        """Move the registry out. Leaves None. Caller owns the result."""
        return self._reg.take()


# =============================================================================
# _build_join_plan_impl -- validation + plan construction
# =============================================================================
#
# Returns the (plan, registry, cnt) triple to construct a fresh
# DataFrame. The caller supplies the already-extracted fields from
# both DataFrames; this helper does NOT touch DataFrame structs.
# =============================================================================
def _build_join_plan_impl(
    var left_plan: LogicalPlan,
    var left_reg: InMemoryRegistry,
    left_cnt: Int,
    var right_plan: LogicalPlan,
    var right_reg: InMemoryRegistry,
    right_cnt: Int,
    var left_keys: List[String],
    var right_keys: List[String],
    join_type: UInt8,
    algo: String,
) raises -> _BuiltJoin:
    """Internal: validate keys, build the JOIN LogicalPlan node, and
    return the (plan, registry, cnt) triple for the resulting DataFrame.

    Single funnel for all per-how methods + the `df.join(how=)` shim.
    Separating this from the public-facing methods lets each
    per-how method enforce its own `cross_join`-vs-non-cross
    distinctions while sharing the validation + lowering body.
    """
    if len(left_keys) != len(right_keys):
        raise Error(
            "DataFrame.join: left_keys and right_keys length mismatch "
            "(left=" + String(len(left_keys))
            + ", right=" + String(len(right_keys)) + ")"
        )
    if len(left_keys) == 0:
        raise Error(
            "DataFrame.join: at least one join key is required "
            "(use cross_join for cartesian product)."
        )

    var algo_hint: UInt8
    if algo == "" or algo == "auto":
        algo_hint = JOIN_ALGO_AUTO
    elif algo == "hash":
        algo_hint = JOIN_ALGO_HASH
    elif algo == "sort_merge":
        algo_hint = JOIN_ALGO_SORT_MERGE
    else:
        raise Error(
            "DataFrame.join: unknown algo=\"" + algo + "\". "
            "Expected one of \"\", \"auto\", \"hash\", \"sort_merge\"."
        )

    var cnt = left_cnt + right_cnt

    # Merge registries.
    left_reg.merge_from(right_reg^)

    var plan = LogicalPlan.join(
        left_plan^, right_plan^, left_keys^, right_keys^,
        join_type, algo_hint,
    )
    return _BuiltJoin(plan^, left_reg^, cnt)


# =============================================================================
# _validate_join_arg_shape_impl -- (left_keys, right_keys, on) tri-arg gate
# =============================================================================
def _validate_join_arg_shape_impl(
    method: String,
    len_left_keys: Int,
    len_right_keys: Int,
    len_on: Int,
) raises:
    """Internal: validate the (`left_keys`, `right_keys`, `on`)
    tri-arg shape is exactly one of:
      * `on=[...]`              (same name on both sides), or
      * `left_keys=[...]` and `right_keys=[...]` (asymmetric).
    Mixing the two forms (or passing none) raises.

    Length-equality between `left_keys` and `right_keys` is checked
    downstream in `_build_join_plan_impl`.
    """
    var on_set = len_on > 0
    var lk_set = len_left_keys > 0
    var rk_set = len_right_keys > 0
    if on_set and (lk_set or rk_set):
        raise Error(
            "DataFrame." + method + ": pass either on= or "
            "left_keys/right_keys, not both."
        )
    if (not on_set) and (not (lk_set and rk_set)):
        raise Error(
            "DataFrame." + method + ": at least one join key is "
            "required (use left_keys/right_keys or on; use "
            "cross_join for cartesian product)."
        )
