# =============================================================================
# parquet_source_options — the Parquet morsel source's options and the pure
# decisions it takes
# =============================================================================
#
# `ParquetScanOptions` holds every switch of the source as a value its caller
# passes (a host maps its flags or its profile to it); the source reads no
# environment variable and probes no machine. The functions here are the
# source's decisions that depend only on their arguments, so each is tested
# directly: the claim stride, the selection-pipeline deferral, the morsel
# partition ids, the numeric-dictionary count shape, the mapping of lowered
# hooks to capabilities, and projection names to leaf indices.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_async.ops.waker_sink import NoopSink
from komira_fs.column_set import ColumnSet
from komira_fs.local_fs import LocalFs
from komira_morsel.source_hooks import LoweredSourceHooks
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_api.metadata import FileMetaData
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    Expr,
)
from komira_plan_expr.expr_id import ExprId
from komira_scan_planning.source_capability_config import SourceCapabilityConfig


# The most workers a source serves (its per-worker slots are sized to this).
comptime MAX_WORKERS: Int = 128
# Morsel partition ids: a row group's sub-morsels take
# `rg * SUB_SLOT_STRIDE + k`, so the collect sink's (partition id, origin)
# sort puts every morsel in file order whether or not its row group was split.
comptime SUB_SLOT_STRIDE: Int = 1_048_576
comptime _MAX_CURSOR_STRIDE: Int64 = 32
comptime _ADAPTIVE_THRESHOLD_FACTOR: Int = 8
# The late-materialized decode gathers the projection once (rather than
# gathering filter and payload apart) when at least this share survives.
comptime LATE_MAT_HIGH_SEL_THRESHOLD: Float64 = 0.5
# The selection pipeline defers the gather (emits a dense batch with its
# mask) when at least this share survives.
comptime SEL_PIPE_DEFER_MIN_PASS_RATE: Float64 = 0.5


@fieldwise_init
struct ParquetScanOptions(Copyable, Movable):
    """The source's switches.

    Fields:
        late_mat_disabled: decode the projection and the filter columns
            together and filter after (no payload deferral).
        forced_cursor_stride: claim this many row groups per cursor bump
            (0: the adaptive stride).
        sel_pipe_enabled: a non-selective filter emits a dense batch with
            its selection mask instead of gathering.
        decode_arena: the payload decode reuses the reader's own decode
            context (see `ParquetReader.decode_columns_subset_arena`).
        rg_allmatch: a `count(*)` of a row group whose statistics prove the
            filter keeps every row is taken from the footer.
        cursor_grain_rows: the cursor-grain route's grain (0: derived).
        l3_cache_bytes: the host's L3 size, for the derived grain (0: the
            default).
        subrg_mode: decode row ranges of a row group in parallel: 0 off,
            1 one unit per page, 2 `subrg_units_per_rg` row ranges.
        subrg_units_per_rg: ranges per row group in mode 2.
        subrg_snap: in mode 2, snap ranges to page boundaries when a row
            group has enough pages.
        subrg_shared: decode each (row group, column) dictionary once.
        subrg_emit_coarse: concatenate a worker's ranges into morsels of
            about `subrg_emit_rows` rows.
        subrg_emit_rows: the coarse morsel size (0: the largest row group).
    """

    var late_mat_disabled: Bool
    var forced_cursor_stride: Int
    var sel_pipe_enabled: Bool
    var decode_arena: Bool
    var rg_allmatch: Bool
    var cursor_grain_rows: Int
    var l3_cache_bytes: Int
    var subrg_mode: Int
    var subrg_units_per_rg: Int
    var subrg_snap: Bool
    var subrg_shared: Bool
    var subrg_emit_coarse: Bool
    var subrg_emit_rows: Int

    @staticmethod
    def default() -> ParquetScanOptions:
        """Late materialization, the adaptive stride, the selection
        pipeline and the all-match count on; the arena, the row-range split
        and every override off."""
        return ParquetScanOptions(
            late_mat_disabled=False,
            forced_cursor_stride=0,
            sel_pipe_enabled=True,
            decode_arena=False,
            rg_allmatch=True,
            cursor_grain_rows=0,
            l3_cache_bytes=0,
            subrg_mode=0,
            subrg_units_per_rg=4,
            subrg_snap=False,
            subrg_shared=False,
            subrg_emit_coarse=False,
            subrg_emit_rows=0,
        )


def adaptive_stride(num_rgs: Int, num_workers: Int) -> Int64:
    """Row groups claimed per cursor bump: 1 below `8 * num_workers` row
    groups, else `ceil(num_rgs / (2 * num_workers))` capped at 32."""
    if num_rgs < _ADAPTIVE_THRESHOLD_FACTOR * num_workers:
        return 1
    var per_worker = (num_rgs + (2 * num_workers) - 1) // (2 * num_workers)
    return max(min(Int64(per_worker), _MAX_CURSOR_STRIDE), 1)


@always_inline
def sel_pipe_should_defer(sel_pipe_enabled: Bool, surviving: Int, total: Int) -> Bool:
    """Whether a partially passing row group emits its dense batch with the
    selection mask (no gather): only with the pipeline on, some row failing,
    and at least `SEL_PIPE_DEFER_MIN_PASS_RATE` passing (a selective filter
    gathers its few survivors instead of making the consumer walk dead
    rows)."""
    if not sel_pipe_enabled or surviving >= total:
        return False
    return Float64(surviving) >= SEL_PIPE_DEFER_MIN_PASS_RATE * Float64(total)


@always_inline
def rg_partition_id(claimed_rg: Int) -> Int:
    """The partition id of a row group's whole (unsplit) morsel: its first
    sub-slot, so whole and split row groups sort together in file order."""
    return claimed_rg * SUB_SLOT_STRIDE


@always_inline
def rg_index_of_partition_id(partition_id: Int) -> Int:
    """The flat row group a morsel of this source was decoded from (whole or
    split)."""
    return partition_id // SUB_SLOT_STRIDE


def dict_count_comparison_op(stg: Expr) -> UInt8:
    """The comparison of `column <cmp> integer-literal` (cmp in =, <>, <,
    <=, >, >=), or `0xFF` for any other shape."""
    if stg.tag != EXPR_BINARY_OP:
        return 0xFF
    var op = stg.binary_op()
    if not (op == BIN_EQ or op == BIN_NE or op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE):
        return 0xFF
    if stg.binary_left_ref().tag != EXPR_COL_REF:
        return 0xFF
    ref rhs = stg.binary_right_ref()
    if not rhs.is_literal():
        return 0xFF
    var dt = rhs.literal_value().dtype
    if not (dt == DType.int64 or dt == DType.int32 or dt == DType.int16 or dt == DType.int8):
        return 0xFF
    return op


def lowered_hooks_to_source_caps(hooks: LoweredSourceHooks) -> SourceCapabilityConfig:
    """The capabilities a source is built with from its lowered hooks: bypass
    columns, count-only, morsel rows, prefetch, the pushed predicate, the
    decode filter stages, the dynamic filter key and the hash-aggregate key
    and inputs. The pointer hooks (expression pool, dynamic filter, cancel
    flag), the projection and dictionary preservation are constructor
    arguments, not capabilities."""
    var stages: Optional[List[ExprId]] = None
    if len(hooks.decode_filter) > 0:
        stages = Optional(hooks.decode_filter.copy())
    var bypass: Optional[ColumnSet] = None
    if len(hooks.bypass_columns) > 0:
        bypass = Optional(ColumnSet.columns(hooks.bypass_columns.copy()))
    var agg_cols: Optional[List[Int]] = None
    if hooks.hash_agg_agg_col_indices:
        agg_cols = Optional(hooks.hash_agg_agg_col_indices.value().copy())
    return SourceCapabilityConfig(
        predicate=None,
        join_filter=None,
        bloom_set=None,
        late_mat_predicate=None,
        late_mat_filter_set=None,
        late_mat_payload_set=None,
        dict_sink=None,
        bypass_set=bypass^,
        count_only=hooks.count_only,
        morsel_rows=hooks.morsel_rows,
        prefetch_enabled=hooks.prefetch_enabled,
        pushed_predicate=hooks.pushed_predicate,
        decode_filter_stages=stages^,
        dynamic_filter_key_name=hooks.dynamic_filter_key_name,
        fused_eval_enabled=True,
        use_1pass_gather=False,
        hash_agg_key_col_idx=hooks.hash_agg_key_col_idx,
        hash_agg_agg_col_indices=agg_cols^,
        row_window_active=False,
        row_window_first_rg=-1,
        row_window_last_rg=-1,
    )


def resolve_projection_indices_via_meta(meta: FileMetaData, names: List[String]) raises -> ColumnSet:
    """The leaf indices of the top-level columns `names`, in that order
    (every column when `names` is empty).

    Raises:
        If a name is not a column of the footer.
    """
    if len(names) == 0:
        return ColumnSet.all()
    var total_file_cols = max(len(meta.schema) - 1, 0)
    var indices = List[Int]()
    for i in range(len(names)):
        var found = -1
        for c in range(total_file_cols):
            if meta.schema[c + 1].name == names[i]:
                found = c
                break
        if found < 0:
            raise Error("parquet source: unknown projection column '" + names[i] + "'")
        indices.append(found)
    return ColumnSet.columns(indices^)


def resolve_projection_indices(mut footer_cache: ParquetMetadataCache, path: String, names: List[String]) raises -> ColumnSet:
    """`resolve_projection_indices_via_meta` over the footer of the local
    file `path`, shared out of the session cache."""
    if len(names) == 0:
        return ColumnSet.all()
    var fs = LocalFs[NoopSink].new()
    var shared = footer_cache.get_or_parse_shared_via_fs(path, fs, False)
    return resolve_projection_indices_via_meta(shared.meta[], names)
