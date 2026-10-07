/* =============================================================================
 * _sched_labels.inc -- the scheduler-trace label tables.
 * =============================================================================
 *
 * THE AUTHORITY IS THE MOJO `comptime` DECLARATION, NOT THIS FILE:
 *   komira_async.runtime.sched_trace
 *   komira_async_api.sched_sites
 *
 * These tables hold one arm per declaration and are maintained BY HAND: no
 * generator or drift check ships with them, so an edit to a constant must be
 * mirrored here in the same change. A mislabel here is diagnostic-only (it does
 * not corrupt the accounting); the mark-join BUILD/STREAM pair is additionally
 * guarded by a runtime read-back of the transition matrix.
 * =============================================================================
 */

/* Human-readable fork-site label. One arm per `comptime SITE_*`. */
static const char *_sched_site_name(uint32_t id) {
    switch (id) {
    case 0: return "OTHER(unlabeled)";  /* SITE_OTHER */
    case 1: return "parquet_decode_scan";  /* SITE_PARQUET_DECODE */
    case 2: return "parquet_agg_scan";  /* SITE_PARQUET_AGG */
    case 3: return "agg_radix_scatter";  /* SITE_AGG_RADIX_SCATTER */
    case 4: return "agg_radix_merge";  /* SITE_AGG_RADIX_MERGE */
    case 5: return "agg_hash";  /* SITE_AGG_HASH */
    case 6: return "agg_perfect_hash";  /* SITE_AGG_PERFECT */
    case 7: return "agg_ext_fold";  /* SITE_AGG_EXT_FOLD */
    case 8: return "sink_executor_msink";  /* SITE_SINK_EXECUTOR */
    case 9: return "combine_lib";  /* SITE_COMBINE */
    case 10: return "sort_compiler_par";  /* SITE_SORT */
    case 11: return "count_distinct";  /* SITE_COUNT_DISTINCT */
    case 12: return "semi_join_build";  /* SITE_SEMI_JOIN */
    case 13: return "join_multikey_kernel";  /* SITE_JOIN_MULTIKEY */
    case 14: return "partition_by";  /* SITE_PARTITION_BY */
    case 15: return "median_drain";  /* SITE_MEDIAN_DRAIN */
    case 16: return "cd_radix";  /* SITE_CD_RADIX */
    case 17: return "segment_exec_wrapper";  /* SITE_SEGMENT_EXEC */
    case 18: return "spill_insert";  /* SITE_SPILL_INSERT */
    case 19: return "typed_stage_agg";  /* SITE_TYPED_STAGE */
    case 20: return "join_typed_ambient";  /* SITE_JOIN_TYPED */
    case 21: return "compiler_parallel_agg";  /* SITE_COMPILER_PAR */
    case 22: return "execute_sink";  /* SITE_EXECUTE_SINK */
    case 23: return "row_pipeline";  /* SITE_ROW_PIPELINE */
    case 24: return "join_hash_build";  /* SITE_JOIN_HASH_BUILD */
    case 25: return "join_probe";  /* SITE_JOIN_PROBE */
    case 26: return "concat_parallel";  /* SITE_CONCAT */
    case 27: return "row_typed_breaker";  /* SITE_ROW_TYPED_BREAKER */
    case 28: return "agg_steal_merge";  /* SITE_AGG_STEAL_MERGE */
    case 29: return "agg_combine_columnar";  /* SITE_AGG_COMBINE_COLUMNAR */
    case 30: return "residual_semi_anti";  /* SITE_RESIDUAL_SEMI_ANTI */
    case 31: return "untyped_col_agg";  /* SITE_UNTYPED_COL_AGG */
    case 32: return "format_read";  /* SITE_FORMAT_READ */
    case 33: return "format_write";  /* SITE_FORMAT_WRITE */
    case 34: return "forever_root_step";  /* SITE_FOREVER_ROOT */
    case 35: return "generic_fork_join";  /* SITE_GENERIC_FORK_JOIN */
    case 36: return "cd_strenc";  /* SITE_CD_STRENC */
    case 37: return "partition_udf";  /* SITE_PARTITION_UDF */
    case 38: return "radix_untyped_drain";  /* SITE_RADIX_UNTYPED_DRAIN */
    case 39: return "radix_untyped_combine";  /* SITE_RADIX_UNTYPED_COMBINE */
    case 40: return "gather_str_len";  /* SITE_GATHER_STR_LEN */
    case 41: return "gather_str_scatter";  /* SITE_GATHER_STR_SCATTER */
    case 42: return "gather_fixedwidth";  /* SITE_GATHER_FIXEDWIDTH */
    case 43: return "fused_dim_build";  /* SITE_FUSED_DIM_BUILD */
    case 44: return "join_chunk_price";  /* SITE_JOIN_CHUNK_PRICE */
    case 45: return "joinkey_hash";  /* SITE_JOINKEY_HASH */
    case 46: return "join_mk_merge";  /* SITE_JOIN_MK_MERGE */
    case 47: return "mk_join_build";  /* SITE_MK_JOIN_BUILD */
    case 48: return "radix_untyped_release";  /* SITE_RADIX_UNTYPED_RELEASE */
    case 49: return "concat_input_release";  /* SITE_CONCAT_RELEASE */
    case 50: return "residual_mark_prepare";  /* SITE_RESIDUAL_MARK_PREPARE */
    case 51: return "residual_mark_build";  /* SITE_RESIDUAL_MARK_BUILD */
    case 52: return "residual_mark_stream";  /* SITE_RESIDUAL_MARK_STREAM */
    case 53: return "semi_probe_index";  /* SITE_SEMI_PROBE_INDEX */
    case 54: return "semi_probe_count";  /* SITE_SEMI_PROBE_COUNT */
    case 55: return "join_ht_fill";  /* SITE_JOIN_HT_FILL */
    case 56: return "agg_ext_extract";  /* SITE_AGG_EXT_EXTRACT */
    case 57: return "ptopn_heap_build";  /* SITE_PTOPN_HEAP_BUILD */
    default: return "site";
    }
}

/* Human-readable serial-phase / region label. One arm per
 * `comptime PHASE_*`. Shared by the SCHED_PHASE (legacy bracket) and
 * SCHED_REGION (observed-nesting) tables -- one id space, one name. */
static const char *_sched_phase_name(uint32_t id) {
    switch (id) {
    case 1: return "concat_tiled_setup";  /* PHASE_CONCAT_TILED_SETUP */
    case 2: return "concat_tiled_assemble";  /* PHASE_CONCAT_TILED_ASSEMBLE */
    case 3: return "concat_cols_setup";  /* PHASE_CONCAT_COLS_SETUP */
    case 4: return "concat_cols_assemble";  /* PHASE_CONCAT_COLS_ASSEMBLE */
    case 5: return "residual_semi_anti_serial";  /* PHASE_RESIDUAL_SEMI_ANTI_SERIAL */
    case 6: return "cj_extract_build";  /* PHASE_CJ_EXTRACT_BUILD */
    case 7: return "cj_extract_probe";  /* PHASE_CJ_EXTRACT_PROBE */
    case 8: return "cj_ht_build";  /* PHASE_CJ_HT_BUILD */
    case 9: return "cj_probe";  /* PHASE_CJ_PROBE */
    case 10: return "cj_assemble";  /* PHASE_CJ_ASSEMBLE */
    case 11: return "joinkey_as_string";  /* PHASE_JOINKEY_AS_STRING */
    case 12: return "joinkey_fnv";  /* PHASE_JOINKEY_FNV */
    case 13: return "inmem_leaf_resolve";  /* PHASE_INMEM_LEAF_RESOLVE */
    case 14: return "inmem_filter_eval";  /* PHASE_INMEM_FILTER_EVAL */
    case 15: return "inmem_filter_gather";  /* PHASE_INMEM_FILTER_GATHER */
    case 16: return "plan_inline_registry";  /* PHASE_PLAN_INLINE_REGISTRY */
    case 17: return "plan_agg_cse_hash";  /* PHASE_PLAN_AGG_CSE_HASH */
    case 18: return "hbs_gather_morsels";  /* PHASE_HBS_GATHER_MORSELS */
    case 19: return "hbs_payload_concat";  /* PHASE_HBS_PAYLOAD_CONCAT */
    case 20: return "hbs_key_as_primitive";  /* PHASE_HBS_KEY_AS_PRIMITIVE */
    case 21: return "hbs_dynamic_filter";  /* PHASE_HBS_DYNAMIC_FILTER */
    case 22: return "hbs_ht_build";  /* PHASE_HBS_HT_BUILD */
    case 23: return "mk_ht_build";  /* PHASE_MK_HT_BUILD */
    case 24: return "inmem_leaf_project";  /* PHASE_INMEM_LEAF_PROJECT */
    case 25: return "query_root";  /* PHASE_QUERY_ROOT */
    case 26: return "plan_prepare";  /* PHASE_PLAN_PREPARE */
    case 27: return "entry_bind";  /* PHASE_ENTRY_BIND */
    case 28: return "walker_dispatch";  /* PHASE_WALKER_DISPATCH */
    case 29: return "walk_leaf_scan";  /* PHASE_WALK_LEAF_SCAN */
    case 30: return "walk_join";  /* PHASE_WALK_JOIN */
    case 31: return "walk_agg";  /* PHASE_WALK_AGG */
    case 32: return "walk_sort";  /* PHASE_WALK_SORT */
    case 33: return "walk_distinct";  /* PHASE_WALK_DISTINCT */
    case 34: return "walk_cross";  /* PHASE_WALK_CROSS */
    case 35: return "walk_window";  /* PHASE_WALK_WINDOW */
    case 36: return "walk_ptopn";  /* PHASE_WALK_PTOPN */
    case 37: return "walk_project";  /* PHASE_WALK_PROJECT */
    case 38: return "walk_filter";  /* PHASE_WALK_FILTER */
    case 39: return "join_side_resolve";  /* PHASE_JOIN_SIDE_RESOLVE */
    case 40: return "join_inmem_kernel";  /* PHASE_JOIN_INMEM_KERNEL */
    case 41: return "join_residual_mark";  /* PHASE_JOIN_RESIDUAL_MARK */
    case 42: return "join_direct_leaf";  /* PHASE_JOIN_DIRECT_LEAF */
    case 43: return "prep_scan_stats";  /* PHASE_PREP_SCAN_STATS */
    case 44: return "prep_plan_hash";  /* PHASE_PREP_PLAN_HASH */
    case 45: return "prep_optimize";  /* PHASE_PREP_OPTIMIZE */
    case 46: return "prep_scan_dedup";  /* PHASE_PREP_SCAN_DEDUP */
    case 47: return "prep_fastpath";  /* PHASE_PREP_FASTPATH */
    case 48: return "join_ht_build";  /* PHASE_JOIN_HT_BUILD */
    case 49: return "join_probe_fan";  /* PHASE_JOIN_PROBE_FAN */
    case 50: return "join_out_concat";  /* PHASE_JOIN_OUT_CONCAT */
    case 51: return "join_kernel_setup";  /* PHASE_JOIN_KERNEL_SETUP */
    case 52: return "join_kernel_release";  /* PHASE_JOIN_KERNEL_RELEASE */
    case 53: return "join_probe_ops";  /* PHASE_JOIN_PROBE_OPS */
    case 54: return "join_morsel_split";  /* PHASE_JOIN_MORSEL_SPLIT */
    case 55: return "chunk_join_cascade";  /* PHASE_CHUNK_JOIN_CASCADE */
    case 56: return "chunk_recovery";  /* PHASE_CHUNK_RECOVERY */
    case 57: return "chunk_project";  /* PHASE_CHUNK_PROJECT */
    case 58: return "cj_chunk_price";  /* PHASE_CJ_CHUNK_PRICE */
    case 59: return "cj_chunk_gather";  /* PHASE_CJ_CHUNK_GATHER */
    case 60: return "fj_build_setup";  /* PHASE_FJ_BUILD_SETUP */
    case 61: return "fj_build_scan";  /* PHASE_FJ_BUILD_SCAN */
    case 62: return "fj_build_combine";  /* PHASE_FJ_BUILD_COMBINE */
    case 63: return "fj_probe_setup";  /* PHASE_FJ_PROBE_SETUP */
    case 64: return "fj_probe_wave";  /* PHASE_FJ_PROBE_WAVE */
    case 65: return "fj_output_assemble";  /* PHASE_FJ_OUTPUT_ASSEMBLE */
    case 66: return "fj_release";  /* PHASE_FJ_RELEASE */
    default: return "phase";
    }
}

/* The WORK UNIT a phase carries in `n`, or NULL when it reports none.
 * Printed as `n=<v> unit=<name>` so a reader never has to guess whether
 * a count is rows, keys or morsels. Declared with `@unit=` on the
 * comptime line; 36 of 66 phases carry one. */
static const char *_sched_phase_unit(uint32_t id) {
    switch (id) {
    case 13: return "rows_resolved";  /* PHASE_INMEM_LEAF_RESOLVE */
    case 14: return "rows_evaluated";  /* PHASE_INMEM_FILTER_EVAL */
    case 15: return "rows_gathered";  /* PHASE_INMEM_FILTER_GATHER */
    case 16: return "copy_bytes";  /* PHASE_PLAN_INLINE_REGISTRY */
    case 17: return "hash_bytes";  /* PHASE_PLAN_AGG_CSE_HASH */
    case 18: return "morsels";  /* PHASE_HBS_GATHER_MORSELS */
    case 19: return "rows";  /* PHASE_HBS_PAYLOAD_CONCAT */
    case 20: return "keys_copied";  /* PHASE_HBS_KEY_AS_PRIMITIVE */
    case 21: return "keys_copied";  /* PHASE_HBS_DYNAMIC_FILTER */
    case 22: return "keys";  /* PHASE_HBS_HT_BUILD */
    case 23: return "build_rows";  /* PHASE_MK_HT_BUILD */
    case 24: return "rows_projected";  /* PHASE_INMEM_LEAF_PROJECT */
    case 26: return "rows";  /* PHASE_PLAN_PREPARE */
    case 27: return "rows";  /* PHASE_ENTRY_BIND */
    case 28: return "rows";  /* PHASE_WALKER_DISPATCH */
    case 29: return "rows";  /* PHASE_WALK_LEAF_SCAN */
    case 37: return "rows";  /* PHASE_WALK_PROJECT */
    case 38: return "rows";  /* PHASE_WALK_FILTER */
    case 39: return "rows";  /* PHASE_JOIN_SIDE_RESOLVE */
    case 40: return "rows";  /* PHASE_JOIN_INMEM_KERNEL */
    case 41: return "rows";  /* PHASE_JOIN_RESIDUAL_MARK */
    case 42: return "rows";  /* PHASE_JOIN_DIRECT_LEAF */
    case 48: return "build_rows";  /* PHASE_JOIN_HT_BUILD */
    case 49: return "probe_rows";  /* PHASE_JOIN_PROBE_FAN */
    case 50: return "rows";  /* PHASE_JOIN_OUT_CONCAT */
    case 53: return "workers";  /* PHASE_JOIN_PROBE_OPS */
    case 54: return "morsel_rows";  /* PHASE_JOIN_MORSEL_SPLIT */
    case 57: return "rows";  /* PHASE_CHUNK_PROJECT */
    case 58: return "rows";  /* PHASE_CJ_CHUNK_PRICE */
    case 59: return "rows";  /* PHASE_CJ_CHUNK_GATHER */
    case 60: return "build_cols";  /* PHASE_FJ_BUILD_SETUP */
    case 62: return "build_rows";  /* PHASE_FJ_BUILD_COMBINE */
    case 63: return "workers";  /* PHASE_FJ_PROBE_SETUP */
    case 64: return "probe_rows";  /* PHASE_FJ_PROBE_WAVE */
    case 65: return "rows";  /* PHASE_FJ_OUTPUT_ASSEMBLE */
    case 66: return "build_rows";  /* PHASE_FJ_RELEASE */
    default: return NULL;
    }
}

/* Human-readable PER-FORK CALL-SITE label. One arm per
 * `comptime FORKTAG_*`. A tag names WHICH dispatch forked, where the
 * SITE id names only the KIND -- site 8 is stamped by three call sites,
 * which makes a per-site idle figure unattributable. Printed only on
 * the SCHED_FORK rows; no SCHED_SITE row changes. id 0 is the
 * 'no caller stamped this fork' sentinel and is the CORRECT value for
 * every fork whose site has a single dispatch. */
static const char *_sched_fork_tag_name(uint32_t id) {
    switch (id) {
    case 0: return "unlabeled";  /* FORKTAG_NONE */
    case 1: return "msink_stream_pull";  /* FORKTAG_MSINK_STREAM_PULL */
    case 2: return "msink_op_pull";  /* FORKTAG_MSINK_OP_PULL */
    case 3: return "msink_combine_part";  /* FORKTAG_MSINK_COMBINE_PART */
    case 4: return "mk_ht_fill";  /* FORKTAG_MK_HT_FILL */
    case 5: return "mk_build";  /* FORKTAG_MK_BUILD */
    default: return "forktag";
    }
}

/* Is `id` a DECLARED phase at all? The dump prints one
 * SCHED_REGION_DECLARED row per declared phase INCLUDING the ones
 * that never fired, so `count=0` is VISIBLE instead of being an
 * absent row indistinguishable from a phase nobody wired. */
static int _sched_phase_declared(uint32_t id) {
    switch (id) {
    case 1: return 1;  /* PHASE_CONCAT_TILED_SETUP */
    case 2: return 1;  /* PHASE_CONCAT_TILED_ASSEMBLE */
    case 3: return 1;  /* PHASE_CONCAT_COLS_SETUP */
    case 4: return 1;  /* PHASE_CONCAT_COLS_ASSEMBLE */
    case 5: return 1;  /* PHASE_RESIDUAL_SEMI_ANTI_SERIAL */
    case 6: return 1;  /* PHASE_CJ_EXTRACT_BUILD */
    case 7: return 1;  /* PHASE_CJ_EXTRACT_PROBE */
    case 8: return 1;  /* PHASE_CJ_HT_BUILD */
    case 9: return 1;  /* PHASE_CJ_PROBE */
    case 10: return 1;  /* PHASE_CJ_ASSEMBLE */
    case 11: return 1;  /* PHASE_JOINKEY_AS_STRING */
    case 12: return 1;  /* PHASE_JOINKEY_FNV */
    case 13: return 1;  /* PHASE_INMEM_LEAF_RESOLVE */
    case 14: return 1;  /* PHASE_INMEM_FILTER_EVAL */
    case 15: return 1;  /* PHASE_INMEM_FILTER_GATHER */
    case 16: return 1;  /* PHASE_PLAN_INLINE_REGISTRY */
    case 17: return 1;  /* PHASE_PLAN_AGG_CSE_HASH */
    case 18: return 1;  /* PHASE_HBS_GATHER_MORSELS */
    case 19: return 1;  /* PHASE_HBS_PAYLOAD_CONCAT */
    case 20: return 1;  /* PHASE_HBS_KEY_AS_PRIMITIVE */
    case 21: return 1;  /* PHASE_HBS_DYNAMIC_FILTER */
    case 22: return 1;  /* PHASE_HBS_HT_BUILD */
    case 23: return 1;  /* PHASE_MK_HT_BUILD */
    case 24: return 1;  /* PHASE_INMEM_LEAF_PROJECT */
    case 25: return 1;  /* PHASE_QUERY_ROOT */
    case 26: return 1;  /* PHASE_PLAN_PREPARE */
    case 27: return 1;  /* PHASE_ENTRY_BIND */
    case 28: return 1;  /* PHASE_WALKER_DISPATCH */
    case 29: return 1;  /* PHASE_WALK_LEAF_SCAN */
    case 30: return 1;  /* PHASE_WALK_JOIN */
    case 31: return 1;  /* PHASE_WALK_AGG */
    case 32: return 1;  /* PHASE_WALK_SORT */
    case 33: return 1;  /* PHASE_WALK_DISTINCT */
    case 34: return 1;  /* PHASE_WALK_CROSS */
    case 35: return 1;  /* PHASE_WALK_WINDOW */
    case 36: return 1;  /* PHASE_WALK_PTOPN */
    case 37: return 1;  /* PHASE_WALK_PROJECT */
    case 38: return 1;  /* PHASE_WALK_FILTER */
    case 39: return 1;  /* PHASE_JOIN_SIDE_RESOLVE */
    case 40: return 1;  /* PHASE_JOIN_INMEM_KERNEL */
    case 41: return 1;  /* PHASE_JOIN_RESIDUAL_MARK */
    case 42: return 1;  /* PHASE_JOIN_DIRECT_LEAF */
    case 43: return 1;  /* PHASE_PREP_SCAN_STATS */
    case 44: return 1;  /* PHASE_PREP_PLAN_HASH */
    case 45: return 1;  /* PHASE_PREP_OPTIMIZE */
    case 46: return 1;  /* PHASE_PREP_SCAN_DEDUP */
    case 47: return 1;  /* PHASE_PREP_FASTPATH */
    case 48: return 1;  /* PHASE_JOIN_HT_BUILD */
    case 49: return 1;  /* PHASE_JOIN_PROBE_FAN */
    case 50: return 1;  /* PHASE_JOIN_OUT_CONCAT */
    case 51: return 1;  /* PHASE_JOIN_KERNEL_SETUP */
    case 52: return 1;  /* PHASE_JOIN_KERNEL_RELEASE */
    case 53: return 1;  /* PHASE_JOIN_PROBE_OPS */
    case 54: return 1;  /* PHASE_JOIN_MORSEL_SPLIT */
    case 55: return 1;  /* PHASE_CHUNK_JOIN_CASCADE */
    case 56: return 1;  /* PHASE_CHUNK_RECOVERY */
    case 57: return 1;  /* PHASE_CHUNK_PROJECT */
    case 58: return 1;  /* PHASE_CJ_CHUNK_PRICE */
    case 59: return 1;  /* PHASE_CJ_CHUNK_GATHER */
    case 60: return 1;  /* PHASE_FJ_BUILD_SETUP */
    case 61: return 1;  /* PHASE_FJ_BUILD_SCAN */
    case 62: return 1;  /* PHASE_FJ_BUILD_COMBINE */
    case 63: return 1;  /* PHASE_FJ_PROBE_SETUP */
    case 64: return 1;  /* PHASE_FJ_PROBE_WAVE */
    case 65: return 1;  /* PHASE_FJ_OUTPUT_ASSEMBLE */
    case 66: return 1;  /* PHASE_FJ_RELEASE */
    default: return 0;
    }
}

/* Does any non-test call site OPEN this phase? Recorded when the tables were
 * generated (by scanning the engine sources for the identifier, comment
 * lines, import lists and test directories excluded).
 *
 * A `wired=0` phase CANNOT FIRE. Its zero in the region table is not
 * a measurement, and this predicate is the only thing at run time
 * that can say so. */
static int _sched_phase_wired(uint32_t id) {
    switch (id) {
    case 1: return 1;  /* PHASE_CONCAT_TILED_SETUP */
    case 2: return 1;  /* PHASE_CONCAT_TILED_ASSEMBLE */
    case 3: return 1;  /* PHASE_CONCAT_COLS_SETUP */
    case 4: return 1;  /* PHASE_CONCAT_COLS_ASSEMBLE */
    case 5: return 1;  /* PHASE_RESIDUAL_SEMI_ANTI_SERIAL */
    case 6: return 1;  /* PHASE_CJ_EXTRACT_BUILD */
    case 7: return 1;  /* PHASE_CJ_EXTRACT_PROBE */
    case 8: return 1;  /* PHASE_CJ_HT_BUILD */
    case 9: return 1;  /* PHASE_CJ_PROBE */
    case 10: return 1;  /* PHASE_CJ_ASSEMBLE */
    case 11: return 1;  /* PHASE_JOINKEY_AS_STRING */
    case 12: return 1;  /* PHASE_JOINKEY_FNV */
    case 13: return 1;  /* PHASE_INMEM_LEAF_RESOLVE */
    case 14: return 1;  /* PHASE_INMEM_FILTER_EVAL */
    case 15: return 1;  /* PHASE_INMEM_FILTER_GATHER */
    case 16: return 1;  /* PHASE_PLAN_INLINE_REGISTRY */
    case 17: return 1;  /* PHASE_PLAN_AGG_CSE_HASH */
    case 18: return 1;  /* PHASE_HBS_GATHER_MORSELS */
    case 19: return 1;  /* PHASE_HBS_PAYLOAD_CONCAT */
    case 20: return 1;  /* PHASE_HBS_KEY_AS_PRIMITIVE */
    case 21: return 1;  /* PHASE_HBS_DYNAMIC_FILTER */
    case 22: return 1;  /* PHASE_HBS_HT_BUILD */
    case 23: return 1;  /* PHASE_MK_HT_BUILD */
    case 24: return 1;  /* PHASE_INMEM_LEAF_PROJECT */
    case 25: return 1;  /* PHASE_QUERY_ROOT */
    case 29: return 1;  /* PHASE_WALK_LEAF_SCAN */
    case 30: return 1;  /* PHASE_WALK_JOIN */
    case 31: return 1;  /* PHASE_WALK_AGG */
    case 32: return 1;  /* PHASE_WALK_SORT */
    case 33: return 1;  /* PHASE_WALK_DISTINCT */
    case 34: return 1;  /* PHASE_WALK_CROSS */
    case 35: return 1;  /* PHASE_WALK_WINDOW */
    case 36: return 1;  /* PHASE_WALK_PTOPN */
    case 37: return 1;  /* PHASE_WALK_PROJECT */
    case 38: return 1;  /* PHASE_WALK_FILTER */
    case 39: return 1;  /* PHASE_JOIN_SIDE_RESOLVE */
    case 40: return 1;  /* PHASE_JOIN_INMEM_KERNEL */
    case 41: return 1;  /* PHASE_JOIN_RESIDUAL_MARK */
    case 42: return 1;  /* PHASE_JOIN_DIRECT_LEAF */
    case 48: return 1;  /* PHASE_JOIN_HT_BUILD */
    case 49: return 1;  /* PHASE_JOIN_PROBE_FAN */
    case 50: return 1;  /* PHASE_JOIN_OUT_CONCAT */
    case 51: return 1;  /* PHASE_JOIN_KERNEL_SETUP */
    case 52: return 1;  /* PHASE_JOIN_KERNEL_RELEASE */
    case 53: return 1;  /* PHASE_JOIN_PROBE_OPS */
    case 54: return 1;  /* PHASE_JOIN_MORSEL_SPLIT */
    case 55: return 1;  /* PHASE_CHUNK_JOIN_CASCADE */
    case 56: return 1;  /* PHASE_CHUNK_RECOVERY */
    case 57: return 1;  /* PHASE_CHUNK_PROJECT */
    case 58: return 1;  /* PHASE_CJ_CHUNK_PRICE */
    case 59: return 1;  /* PHASE_CJ_CHUNK_GATHER */
    case 60: return 1;  /* PHASE_FJ_BUILD_SETUP */
    case 61: return 1;  /* PHASE_FJ_BUILD_SCAN */
    case 62: return 1;  /* PHASE_FJ_BUILD_COMBINE */
    case 63: return 1;  /* PHASE_FJ_PROBE_SETUP */
    case 64: return 1;  /* PHASE_FJ_PROBE_WAVE */
    case 65: return 1;  /* PHASE_FJ_OUTPUT_ASSEMBLE */
    case 66: return 1;  /* PHASE_FJ_RELEASE */
    default: return 0;
    }
}
