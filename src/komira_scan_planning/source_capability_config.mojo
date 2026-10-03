# =============================================================================
# komira_scan_planning.source_capability_config — generic source capability bundle
# =============================================================================
# Format-agnostic scan capability config: most fields are format-agnostic
# POD; the
# 2 semantically-parquet-bound fields (`fused_eval_enabled`,
# `dynamic_filter_key_name`) carry parquet-flavored semantics but their TYPES
# are format-agnostic (Bool / String). Hosting the bundle here unblocks the
# csv/json/orc plug-in scenarios that will share the same caps shape.
#
# The bridge from `LoweredSourceHooks` (engine_runtime) to
# `SourceCapabilityConfig` is `lowered_hooks_to_source_caps` and stays in
# `komira_parquet.parquet_source` — moving it here would force
# `komira_scan_planning` to depend on `komira_engine_runtime`, a layering
# inversion. The free function imports the type from this module.
#
# Pointer discipline:
#   - ZERO `UnsafePointer` in any field.
#   - All fields are POD or POD-Optional.
# =============================================================================

from komira_fs.column_set import ColumnSet
from komira_fs.file_format_capabilities import (
    BloomFilterRef,
    DictSinkRef,
    DynamicJoinFilterRef,
    PhysicalPredicate,
)

from komira_core.traits.expr_id import ExprId


# =============================================================================
# SourceCapabilityConfig — bundle of capability hooks + source-config items
# =============================================================================
#
# Bundles all capability hooks (predicate, join_filter, bloom_set, late-mat
# config, bypass_set, count_only) AND the two source-configuration knobs
# (morsel_rows, prefetch_enabled) for the multi-consumer source structs to
# carry.
#
# Field set (16 fields total):
#
#   Capability hooks (9):
#     var predicate: Optional[PhysicalPredicate]
#     var join_filter: Optional[DynamicJoinFilterRef]
#     var bloom_set: Optional[BloomFilterRef]
#     var late_mat_predicate: Optional[PhysicalPredicate]
#     var late_mat_filter_set: Optional[ColumnSet]
#     var late_mat_payload_set: Optional[ColumnSet]
#     var dict_sink: Optional[DictSinkRef]
#     var bypass_set: Optional[ColumnSet]
#     var count_only: Bool
#
#   Source-configuration knobs (2):
#     var morsel_rows: Int          — intra-RG split (0 = no split)
#     var prefetch_enabled: Bool    — kernel readahead hint
#
#   Step 3b additions (5):
#     var pushed_predicate: Optional[ExprId]
#     var decode_filter_stages: Optional[List[ExprId]]
#     var dynamic_filter_key_name: String
#     var fused_eval_enabled: Bool
#     var use_1pass_gather: Bool
#
# Default-constructed via `default()`: every Optional is None, Bools are
# False (except `fused_eval_enabled` which defaults to True),
# `morsel_rows` is 0. Equivalent to "no capability active" (plain
# decode + projection + one morsel per RG, no prefetch).
# =============================================================================


@fieldwise_init
struct SourceCapabilityConfig(Movable, Copyable, Deinitable):
    """Capability hooks + source-configuration bundle for
    ColumnarMultiConsumerSource_Single / _Known and any future
    columnar-format multi-consumer sources."""

    # Capability hooks (9).
    var predicate: Optional[PhysicalPredicate]
    var join_filter: Optional[DynamicJoinFilterRef]
    var bloom_set: Optional[BloomFilterRef]
    var late_mat_predicate: Optional[PhysicalPredicate]
    var late_mat_filter_set: Optional[ColumnSet]
    var late_mat_payload_set: Optional[ColumnSet]
    var dict_sink: Optional[DictSinkRef]
    var bypass_set: Optional[ColumnSet]
    var count_only: Bool

    # Source-configuration knobs (2).
    var morsel_rows: Int
    var prefetch_enabled: Bool

    # Step 3b Path α: RG-stats pruning ExprId. When
    # `pushed_predicate` is `Some(id)` AND a real ExprPool is bound to
    # the source struct's `expr_o` parameter, `next_morsel` consults
    # `can_prune_row_group(rg, meta, pool.resolve(id))` after each cursor
    # claim and skips RGs proven unsatisfiable by column-chunk stats.
    #
    # Distinct from `predicate: Optional[PhysicalPredicate]` above: that
    # field is the v0.1 opaque planner-side handle (resolved engine-side
    # to a typed expression in v0.2+); `pushed_predicate` is the concrete
    # ExprPool index used by the rg_pruner walk. Both can be set
    # independently — `pushed_predicate` drives RG-stats pruning, while
    # `predicate` drives in-decode predicate eval (Path β scope).
    var pushed_predicate: Optional[ExprId]

    # Step 3b Path β: late-mat config (mirrors legacy
    # `set_decode_filter` + `_dynamic_filter_key_name` + `_USE_1PASS_GATHER`
    # comptime alias). These four fields drive the decode-time predicate
    # evaluation path that lands in chunks 2-6 (inlined in
    # `_Single.next_morsel` and `_Known.next_morsel`).
    #
    # `decode_filter_stages`: ordered list of ExprIds to evaluate during
    #   decode (AND-combined). Mirrors legacy
    #   `ParquetMorselSource._decode_filter_stages`. When `Some(stages)`
    #   AND `expr_pool` is bound, the late-mat path engages.
    # `dynamic_filter_key_name`: probe-side join-key column name that
    #   the DynamicJoinFilter applies to. Empty string means "no
    #   dyn-filter probe configured." Mirrors legacy
    #   `ParquetMorselSource._dynamic_filter_key_name`.
    # `fused_eval_enabled`: gate for the Cluster F fused filter+project
    #   fast path. Mirrors legacy `ParquetMorselSource._fused_eval_enabled`.
    # `use_1pass_gather`: gate for the 1-pass selection-bearing decode
    #   shape. Current plumbing always reads this as False (2-pass).
    var decode_filter_stages: Optional[List[ExprId]]
    var dynamic_filter_key_name: String
    var fused_eval_enabled: Bool
    var use_1pass_gather: Bool

    # Decode-fused hash agg cap.
    # When `hash_agg_key_col_idx` is `Some(k)`, the parquet source's
    # `next_morsel` calls `decode_for_hash_agg(rg, k, agg_cols, ...)`
    # instead of `decode_columns_subset(...)`. The single-Int64-key
    # contract is enforced by the planner before this cap is set.
    #
    # `hash_agg_agg_col_indices` carries the agg-input column indices
    # the sink will need (e.g. SUM(col)/MIN(col)/MAX(col) source
    # columns). The decode-fused path returns these as a
    # `List[Column]` inside the `HashAggDecodedRG` payload so the sink
    # consumes them by reference into its accumulator.
    #
    # The decode-fused path is gated on:
    #   1. `hash_agg_key_col_idx.is_some()` — opt-in at planner level
    #   2. `pushed_predicate.is_none()` — no predicate pushdown active
    #      (skip the with-filter composition for v0.1)
    #   3. `morsel_rows == 0` — one morsel per RG (skip sub-morsel
    #      split for v0.1)
    # If any gate fails the source falls through to the existing
    # `decode_columns_subset` path and the morsel carries
    # `hash_agg_decoded == None`.
    var hash_agg_key_col_idx: Optional[Int]
    var hash_agg_agg_col_indices: Optional[List[Int]]

    # ROWSELECTION-WIRING: targeted flat-RG window.
    # When `row_window_active` is True, `next_morsel` decodes a claimed flat RG
    # ONLY when `row_window_first_rg <= claimed_rg <= row_window_last_rg`, else
    # it skips the claim (identical control flow to a stats-pruned RG). Set by
    # the collect leaf after resolving a `ParquetSourceData.row_window` against
    # the footer row-group prefix sums. Default inactive (-1, -1) — every
    # existing ctor site decodes all row groups, byte-identical to today. An
    # EMPTY window resolves to `first_rg=0, last_rg=0` (decode ONLY RG 0, which
    # the leaf then trims to 0 rows so the result carries the source schema).
    var row_window_active: Bool
    var row_window_first_rg: Int
    var row_window_last_rg: Int

    @staticmethod
    def default() -> SourceCapabilityConfig:
        """Default-construct: no capabilities active, no source config
        knobs set. Plain decode + projection + one morsel per RG."""
        return SourceCapabilityConfig(
            predicate=None,
            join_filter=None,
            bloom_set=None,
            late_mat_predicate=None,
            late_mat_filter_set=None,
            late_mat_payload_set=None,
            dict_sink=None,
            bypass_set=None,
            count_only=False,
            morsel_rows=0,
            prefetch_enabled=False,
            pushed_predicate=None,
            decode_filter_stages=None,
            dynamic_filter_key_name=String(""),
            fused_eval_enabled=True,
            use_1pass_gather=False,
            hash_agg_key_col_idx=None,
            hash_agg_agg_col_indices=None,
            row_window_active=False,
            row_window_first_rg=-1,
            row_window_last_rg=-1,
        )
