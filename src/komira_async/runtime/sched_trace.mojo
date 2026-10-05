# =============================================================================
# sched_trace — scheduler wall-attribution instrumentation
# =============================================================================
#
# SCHED-TRACE. Thin typed Mojo wrappers over the process-global
# scheduler-trace counter block in `komira_async/reactor/_posix_shim.c`
# (a TU-static / relaxed-atomic counter block).
#
# The instrumentation splits the runtime's flat "dispatch + idle" self-time
# bucket into four attributed-WALL buckets:
#
#   (a) inter-segment barrier   — worker parked, NO run_with_state live (depth==0)
#   (b) intra-segment straggler — worker parked, a dispatch IS live   (depth>0)
#   (c) dispatch CPU            — enqueue-loop wall + worker MPSC drain-pop
#   (d) spin-poll CPU burn      — the empty spin-window CPU-burn before park
#
# HARD REQUIREMENT (<1% overhead when OFF): the enabled flag is set ONCE at
# startup (`sched_trace_configure`) and each hot-path owner
# (LocalDispatcher._sched_on / Worker._sched_accum.enabled) caches it in a
# struct FIELD, so the OFF path is a single cold Bool branch with ZERO
# external_call. NOTHING in this module is comptime-parameterized — it keeps
# the runtime elaboration flat.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns


# -----------------------------------------------------------------------------
# Call-site ids. A small POD UInt32 threaded
# per `run_with_state` fork (NO comptime axis — the method is already
# monomorphized per [State,T]; this is a plain runtime constant per call site).
# id 0 (SITE_OTHER) = unlabeled: forks in peer-owned join/concat fork sites the
# runtime cannot label at the call site fall here (unless a SchedSiteScope guard
# on an owned enclosing frame pushed one). These MUST mirror the _sched_site_name
# switch in komira_async/reactor/_posix_shim.c (diagnostic label only).
# -----------------------------------------------------------------------------
comptime SITE_OTHER: UInt32 = 0  # @label=OTHER(unlabeled)
comptime SITE_PARQUET_DECODE: UInt32 = 1     # @label=parquet_decode_scan subrg_scan_executor
comptime SITE_PARQUET_AGG: UInt32 = 2        # @label=parquet_agg_scan subrg_agg_executor
comptime SITE_AGG_RADIX_SCATTER: UInt32 = 3  # agg_radix phase-1 process/scatter
comptime SITE_AGG_RADIX_MERGE: UInt32 = 4    # agg_radix phase-2 partition merge
comptime SITE_AGG_HASH: UInt32 = 5           # agg_hash_parallel
comptime SITE_AGG_PERFECT: UInt32 = 6        # @label=agg_perfect_hash agg_perfect_hash
comptime SITE_AGG_EXT_FOLD: UInt32 = 7       # agg_extended_grouped fold
comptime SITE_SINK_EXECUTOR: UInt32 = 8      # @label=sink_executor_msink unified/executor_msink
comptime SITE_COMBINE: UInt32 = 9            # @label=combine_lib combine_lib parallel radix combine
comptime SITE_SORT: UInt32 = 10              # @label=sort_compiler_par compiler_parallel sort driver
comptime SITE_COUNT_DISTINCT: UInt32 = 11    # agg_count_distinct_parallel/strenc
comptime SITE_SEMI_JOIN: UInt32 = 12         # @label=semi_join_build semi_join build
comptime SITE_JOIN_MULTIKEY: UInt32 = 13     # @label=join_multikey_kernel join_multi_key_parallel kernel
comptime SITE_PARTITION_BY: UInt32 = 14      # partition_scan_sink_*
comptime SITE_MEDIAN_DRAIN: UInt32 = 15      # median_parallel_drain
comptime SITE_CD_RADIX: UInt32 = 16          # cd_radix_parallel / cd kernel
comptime SITE_SEGMENT_EXEC: UInt32 = 17      # @label=segment_exec_wrapper segment_execution WorkerPool wrapper
comptime SITE_SPILL_INSERT: UInt32 = 18      # spill_parallel_insert
comptime SITE_TYPED_STAGE: UInt32 = 19       # @label=typed_stage_agg materialize_typed_stage / rowblock
comptime SITE_JOIN_TYPED: UInt32 = 20        # @label=join_typed_ambient ambient: drive_column_typed_join
comptime SITE_COMPILER_PAR: UInt32 = 21      # @label=compiler_parallel_agg compiler_parallel misc
comptime SITE_EXECUTE_SINK: UInt32 = 22      # unified/execute_sink
comptime SITE_ROW_PIPELINE: UInt32 = 23      # unified/row_pipeline_driver / probe

# -----------------------------------------------------------------------------
# Join / concat / helper drivers. Without these ids, forks from these drivers
# land in id 0 and the trace can measure the SIZE of the driver-serial prize
# but not its LOCATION. Every id MUST mirror the `_sched_site_name` switch in
# komira_async/reactor/_posix_shim.c (a mislabel there is diagnostic-only —
# it does not corrupt the accounting).
# -----------------------------------------------------------------------------
comptime SITE_JOIN_HASH_BUILD: UInt32 = 24   # unified/join/hash_index_parallel +
                                             # materialize_typed_join BUILD phase
comptime SITE_JOIN_PROBE: UInt32 = 25        # compiler_parallel probe-into +
                                             # materialize_typed_join PROBE phase +
                                             # row_join_probe_multiworker
comptime SITE_CONCAT: UInt32 = 26            # @label=concat_parallel engine_runtime/streaming_concat_parallel
comptime SITE_ROW_TYPED_BREAKER: UInt32 = 27 # unified/row_typed_breaker_segment
comptime SITE_AGG_STEAL_MERGE: UInt32 = 28   # unified/agg/partitioned_agg_steal_merge
comptime SITE_AGG_COMBINE_COLUMNAR: UInt32 = 29  # unified/agg/columnar_agg_sink_combine
comptime SITE_RESIDUAL_SEMI_ANTI: UInt32 = 30    # residual_semi_anti_parallel
comptime SITE_UNTYPED_COL_AGG: UInt32 = 31   # sdk col-agg drivers (agg_node_exec)
comptime SITE_FORMAT_READ: UInt32 = 32       # csv / orc / avro readers + IPC decompress
comptime SITE_FORMAT_WRITE: UInt32 = 33      # parquet writer / csv_sink + IPC compress
comptime SITE_FOREVER_ROOT: UInt32 = 34      # @label=forever_root_step forever_root_step_driver
comptime SITE_GENERIC_FORK_JOIN: UInt32 = 35 # komira_async/runtime/parallel_* helpers
comptime SITE_CD_STRENC: UInt32 = 36         # agg_count_distinct_strenc key encode
comptime SITE_PARTITION_UDF: UInt32 = 37     # stage_primitives/partition_udf_parallel

# -----------------------------------------------------------------------------
# MSINK SITE DE-CONFLATION. `SITE_SINK_EXECUTOR` (id 8) belongs to the
# morsel-sink collect driver, which owns the SETUP/DRAIN/COMBINE/PREPARE/
# FINALIZE/TEARDOWN brackets. The untyped radix hash-agg has two forks of its
# own — the multi-way DRAIN/emit fork and the partition COMBINE fork — with
# their own post-barrier serial spines. Stamping them 8 would charge every
# serial window after a radix-agg fork to site 8 with no bracket able to name
# it, so ids 38-39 keep the msink row meaning msink.
# -----------------------------------------------------------------------------
comptime SITE_RADIX_UNTYPED_DRAIN: UInt32 = 38    # radix_hash_agg_untyped mw drain/emit
comptime SITE_RADIX_UNTYPED_COMBINE: UInt32 = 39  # radix_hash_agg_untyped partition combine


# -----------------------------------------------------------------------------
# ids 40-42, DECLARED IN `komira_async_api.sched_sites` and
# re-exported here so the registry stays one ordered list.
#
# `gather_batch` (stage 4 of every ORDER BY, plus filter / join-output assembly)
# lives in `komira_core`, BELOW this module, so it cannot import from here — it
# names its own three ids in core. They are re-exported so an id collision is
# visible in this file and so async-side readers (the tests, the dump) can use
# the same names. Every one MUST mirror `_sched_site_name` in `_posix_shim.c`.
# -----------------------------------------------------------------------------
from komira_async_api.sched_sites import (
    SITE_GATHER_FIXEDWIDTH,
    SITE_GATHER_STR_LEN,
    SITE_GATHER_STR_SCATTER,
    # id 44 — declared in core for the same reason as 40-42 (the join chunk
    # pricing wave forks from komira_core). Listed here so the registry stays
    # one ordered list and an id collision is visible. It is OUT of numeric
    # order relative to 43 below only because 43 is declared in this file; the
    # ids themselves do not collide.
    SITE_JOIN_CHUNK_PRICE,
)


# -----------------------------------------------------------------------------
# FUSED-DIM-WAVE id.
#
# `run_subrg_scan_multi` driven from `run_generic_wave_fold`: ONE fork whose task
# space is the UNION of a multi-dim BUILD antichain's row groups, replacing N
# sequential blocking fork-joins. It gets its OWN id rather than reusing
# SITE_PARQUET_DECODE (id 1) because the fused wave and the single-leaf decode
# have different fork-count / driver-serial shapes — conflating them would hide
# exactly the effect being measured.
# -----------------------------------------------------------------------------
comptime SITE_FUSED_DIM_BUILD: UInt32 = 43   # subrg_scan_executor multi-leaf wave


# -----------------------------------------------------------------------------
# EXTRACT-PARALLEL id. (id 44 is SITE_JOIN_CHUNK_PRICE, declared in core.)
#
# The composite join's per-row FNV-1a key-hash wave
# (`join_key_extract.hash_string_keys` in the engine operators). Its own id,
# not SITE_JOIN_MULTIKEY (13): 13's fork count is the PROBE's, and the point of
# bracketing the extract separately is that the extract and the probe have
# different fork shapes.
# -----------------------------------------------------------------------------
comptime SITE_JOINKEY_HASH: UInt32 = 45      # join key extract FNV-1a wave


# -----------------------------------------------------------------------------
# MK-MERGE-PARALLEL id.
#
# The multi-key parallel probe's DRIVER-SIDE merge: after the probe barrier the
# driver concatenates the per-worker `List[Int]` pairs into the caller's output
# lists. Done serially that is a large single-thread memcpy into not-yet-faulted
# destination pages with every pool worker parked at the barrier, so it forks.
#
# ⚠ ITS OWN ID — NOT `SITE_JOIN_MULTIKEY` (13). 13's fork count is the PROBE's
# (one fork per `parallel_multi_key_inner_probe_into` call, `n_tasks ==
# num_workers`). Folding the merge wave into 13 would double its `count`. Also
# NOT 44 (join_chunk_price) or 40 (gather_str_len) for the same reason.
#
# The merge fires ONCE per probe call with `n_tasks == min(pool_workers,
# num_workers)`, so `count` and `task_min`/`task_max` are both readable evidence:
# `count == 0` means the wave silently degraded to the inline arm.
# -----------------------------------------------------------------------------
comptime SITE_JOIN_MK_MERGE: UInt32 = 46     # multi-key probe per-worker merge


# -----------------------------------------------------------------------------
# MK-BUILD-PARALLEL id.
#
# The COMPOSITE (multi-key) hash-join BUILD (`mk_ht_build`). Run serially it is
# one composite-hash + chain-insert loop on the driver with every pool worker
# parked. The single-key `hash_join_build_parallel` (id 24) cannot serve it:
# that kernel is one INT64 key column and one `_hash_join_key`, while this one
# gathers N keys per row, honours the `_NAN_SENTINEL_BITS` skip-row rule, and
# populates a composite bloom.
#
# ⚠ ITS OWN ID — NOT 24 (`join_hash_build`). 24's fork count is the SINGLE-KEY
# build's; folding the composite build into it would make "did the single-key
# parallel build fire?" unanswerable from a dump. Same argument 45 and 46 make
# for the extract and the merge.
#
# ⚠ THE SITE ROW IS THE DISPATCH WITNESS, AND IT IS THE ONLY ONE. The wave runs
# through `fork_join_shared`, whose serial arm executes the SAME chunk bodies in
# chunk order — which for a Treiber-push chain build reproduces the serial
# builder's chain order EXACTLY. So a silent degradation to the inline arm
# (`force_serial`, `has_pool=False`, below the chunk floor, or the nested-
# dispatch interlock) is BYTE-IDENTICAL ON OUTPUT and is undetectable from the
# result. `count == 0` on this row is the falsifier; `task_min == task_max ==
# pool width` is the proof it fanned.
# -----------------------------------------------------------------------------
comptime SITE_MK_JOIN_BUILD: UInt32 = 47     # composite-key hash-join build


# -----------------------------------------------------------------------------
# RADIX-SRC-RELEASE. The wave that DESTROYS the per-worker radix
# agg src tables after the partition combine has joined. It emits no value, so
# this site row is the ONLY witness that it fanned: the query answer is
# byte-identical whether the free() storm ran on the workers or on the driver,
# so a silent decline to the serial drop is undetectable from the result.
# `count == 0` on this row is the falsifier.
#
# ⚠ ITS OWN ID — NOT 39 (`radix_untyped_combine`). 39's fork count is the
# partition-combine's and is the evidence that the combine fanned; folding a
# second fork from the same file into it would make either question
# unanswerable, exactly as 47 argues against 24.
# -----------------------------------------------------------------------------
comptime SITE_RADIX_UNTYPED_RELEASE: UInt32 = 48  # radix_untyped src teardown wave

# -----------------------------------------------------------------------------
# 49 — the concat INPUT teardown wave, and why it is its own site, not 26.
#
# 26 (`SITE_CONCAT`) is the column-parallel concat's PRODUCING fork. This one
# destroys the INPUT batches after that fork has joined. Those are different
# questions -- "did the concat fan out" vs "did the teardown fan out" -- and 26
# already answers the first; folding them makes either unanswerable, exactly as
# 47 argues against 24. Run serially, the destruction under the concat subtree
# is driver-serial with every worker parked.
#
# ⚠ Frame-pointer unwinding under-prices this subtree badly, because it cannot
# unwind the destructor chains. Do not derive this site's value from an `fp`
# profile; use DWARF unwinding.
# -----------------------------------------------------------------------------
comptime SITE_CONCAT_RELEASE: UInt32 = 49  # @label=concat_input_release concat input-batch teardown wave


# -----------------------------------------------------------------------------
# SITE_RESIDUAL_MARK_PREPARE — the mark-join's buffer FILL, moved off the driver.
#
# WHY ITS OWN ID AND NOT FOLDED INTO SITE_RESIDUAL_SEMI_ANTI (30). The point of
# this wave is to shrink the driver-serial window that `SCHED_TRANS
# concat_input_release -> residual_semi_anti` measures. Reusing site 30 would put
# the wave INSIDE the very row read to judge it, so the before/after would be
# uninterpretable — the gap would shrink because a fork moved into it, not
# because work left the driver. A separate id keeps the two readable apart.
#
# WHAT IT COVERS (`residual_semi_anti_parallel.parallel_residual_semi_anti_mark`):
# `ht` (cap * 8 B, filled `_CHAIN_END`), `next_chain` (num_build_rows * 8 B,
# zero), `has_pass` (num_probe_rows * 1 B, zero) — hundreds of MB of
# single-threaded first-touch memset per query at scale if run on the driver.
#
# Emits no value, so this row is the only witness it fanned.
# -----------------------------------------------------------------------------
comptime SITE_RESIDUAL_MARK_PREPARE: UInt32 = 50  # mark-join ht/chain/mark fill


# -----------------------------------------------------------------------------
# SITE_RESIDUAL_MARK_BUILD / _STREAM — the mark-join's two correlated-join waves,
# split apart.
#
# WHY. With one id on BOTH `run_with_state` calls in
# `residual_semi_anti_parallel.parallel_residual_semi_anti_mark`, the row would
# carry one `count`, one `fork_ns` and — worse — ONE `task_max` for the two
# waves together. A build-side change is priced against the BUILD wave alone; a
# row that sums it with the probe cannot say what fraction it could take.
#
# ⚠ 30 IS UNUSED. Nothing stamps it, so a surviving `id=30` row in a
# `SCHED_SITE` dump means some other path is stamping it — or the ambient
# `SchedSiteScope` fallback in `local_dispatcher` (used when `site_id == 0`) is
# firing. Either would itself be a finding; the C dump skips any site whose
# count is 0, so 30 must simply vanish from the block.
#
# ⚠ "STREAM" IS THE PROBE WAVE. The mark-join is decomposed into a BUILD wave
# and a STREAM wave; the operator source calls the second one PROBE throughout
# (`_ResidualProbeTask`, `num_probe_morsels`). They are the same wave.
#
# ⚠ THESE TWO CONSTANTS ARE NOT IN THE GENERATED LABEL TABLE. A swapped pair
# here would label build as stream with every label check green. The falsifier
# is a runtime read-back of the transition matrix: `transition(50, 51) > 0`,
# `transition(51, 52) > 0` and `transition(50, 52) == 0`, which a swap cannot
# satisfy because the PREPARE wave provably precedes BUILD.
# -----------------------------------------------------------------------------
comptime SITE_RESIDUAL_MARK_BUILD: UInt32 = 51   # mark-join Treiber-push build
comptime SITE_RESIDUAL_MARK_STREAM: UInt32 = 52  # mark-join probe+residual+mark


# -----------------------------------------------------------------------------
# SITE_SEMI_PROBE_INDEX / _COUNT — the semi/anti hash-set probe's two forks.
#
# WHY THEY GET IDS AT ALL. Both forks in `semi_join.mojo` dispatch through
# `parallel_steal` WITHOUT a `site_id`, so they would land in id 35
# (`SITE_GENERIC_FORK_JOIN`) — the catch-all — alongside every other helper
# caller. A fork whose grain is a hand-typed morsel size can fail to reach full
# width on a wide pool for every table below millions of rows, and a defect
# stated in tasks-per-fork cannot be guarded from a shared anonymous bucket.
#
# WHY TWO IDS AND NOT ONE. The same reason ids 51/52 are split.
# `probe_semi_parallel` (emits survivor INDICES) and `_probe_count_parallel`
# (folds a COUNT) are separate waves with separate geometries, and both write
# the `grain_geometry` table, which is LAST-WRITE-WINS per site. One id would
# let whichever ran last silently answer for both — and a guard reading that
# slot would pass while the other site's grain sat reverted.
# -----------------------------------------------------------------------------
comptime SITE_SEMI_PROBE_INDEX: UInt32 = 53  # semi/anti probe -> survivor indices
comptime SITE_SEMI_PROBE_COUNT: UInt32 = 54  # semi/anti probe -> count only


# -----------------------------------------------------------------------------
# SITE_JOIN_HT_FILL — the join build's CHAIN-HEAD TABLE fill, moved off the
# driver.
#
# WHAT IT COVERS. Both mainline parallel join builds size a chain-head table to
# `cap` slots and `memset` it to 0xFF (`_CHAIN_END` == -1) before their build
# wave:
#   * `hash_chain_parallel_build.chain_build_parallel`      (single INT64 key)
#   * `join_multi_key_parallel_build.multi_key_hash_join_build_parallel`
#     (composite key)
# `cap * 8` bytes, first-touch. The table is NOT elidable — the Treiber push
# READS `ht[slot]` as its `old` before the first CAS — so the only lever
# available is to fan the fill, which is what this site labels.
#
# WHY ITS OWN ID AND NOT `SITE_JOIN_HASH_BUILD` / `SITE_MK_JOIN_BUILD`. The
# lesson ids 51/52 are split for: stamping the fill with the id of the wave it
# precedes folds the fill's fork span into the very row a reader uses to judge
# whether the fill left the driver, so before/after is uninterpretable — the
# build row's `fork_ns` would rise because a fork moved INTO it, not because
# work left the driver. A separate id also makes `count > 0` the fire witness
# for a gate whose two arms are otherwise byte-identical on output.
#
# Emits no value, so this row is the only witness it fanned.
# -----------------------------------------------------------------------------
comptime SITE_JOIN_HT_FILL: UInt32 = 55  # join build chain-head table fill


# -----------------------------------------------------------------------------
# SITE_AGG_EXT_EXTRACT — the grouped extended fold's INPUT-EXTRACT wave.
#
# WHY IT GETS ITS OWN ID AND DOES NOT REUSE 3 OR 7. `agg_extended_grouped`
# already dispatches two waves: `SITE_AGG_RADIX_SCATTER` (3) for the row scatter
# and `SITE_AGG_EXT_FOLD` (7) for the fold. The extract is a THIRD wave, earlier
# than both, with its own geometry (a flattened slot x row-morsel space, one
# morsel per column-slice) and its own cost model (pure DRAM traffic, no hashing,
# no accumulation). Folding it into either neighbour would put two different
# geometries in one `grain_geometry` slot, which is LAST-WRITE-WINS per site —
# the defect ids 51/52 are split apart to avoid, and the reason
# SITE_SEMI_PROBE_{INDEX,COUNT} are two ids and not one.
#
# The extract runs fanned by default, so a sched-trace run with NO site-56 row
# is the proof that some caller turned the fan off — the arm is READABLE FROM A
# RUN rather than inferred.
# -----------------------------------------------------------------------------
comptime SITE_AGG_EXT_EXTRACT: UInt32 = 56  # agg_extended_grouped input extract


# -----------------------------------------------------------------------------
# SITE 57 -- the partition-topn per-partition heap BUILD wave
# -----------------------------------------------------------------------------
# `PartitionTopNSink.combine()` as one serial pass over every row leaves the
# whole pool spinning, so the build row-range-partitions that pass over the
# pool. It has its OWN site id rather than riding `SITE_GENERIC_FORK_JOIN`
# (35): this row is the reading that says the wave FIRED at all -- the
# anonymous catch-all bucket cannot say that, because an unrelated helper
# firing there would read the same.
comptime SITE_PTOPN_HEAP_BUILD: UInt32 = 57  # @label=ptopn_heap_build partition_topn_sink parallel heap build


# -----------------------------------------------------------------------------
# PER-FORK CALL-SITE TAGS (`FORKTAG_*`)
# -----------------------------------------------------------------------------
# A DIFFERENT ID SPACE FROM `SITE_*`, ON PURPOSE. A site names the KIND of fork
# (its row must stay comparable across traces, so splitting site 8 into three
# ids is not available). A fork tag names the CALL SITE inside that kind, and it
# appears only on the per-fork rows. Nothing that reads a `SCHED_SITE` row
# changes.
#
# WHY THEY EXIST. `SITE_SINK_EXECUTOR` (8) is stamped by THREE `run_with_state`
# dispatches and can fire several times per rep — one big pipeline fork and
# several tiny collect forks, say. The per-SITE accumulator cannot say whether
# the site's occupancy is the big fork's own number (a real prize) or an
# average dragged down by the small ones (no prize at all).
#
# A TAG IS NOT A GUESS ABOUT WHICH CALL SITE FORKED -- it is stamped BY that
# call site, immediately before the fork, and the note carries the site it
# expects so a stolen note is recorded UNLABELLED and counted rather than
# mislabelled. See `sched_trace_set_fork_note` and `komira_sched_set_fork_note`.
#
# id 0 IS THE "no caller stamped this fork" SENTINEL and is CORRECT for most
# forks. A site with exactly one dispatch needs no tag: its site id already names
# its call site, and the per-fork rows already separate its forks from each other.
# Tags exist only where one site id has several dispatches.
comptime FORKTAG_NONE: UInt32 = 0  # @label=unlabeled

# `executor_msink.mojo` -- the three dispatches that all stamp SITE_SINK_EXECUTOR.
# `execute_collect_morsel_sink`'s streaming pull-loop; `n = eff_workers`, so this
# is the ONE msink fork a fan-out cap can shrink.
comptime FORKTAG_MSINK_STREAM_PULL: UInt32 = 1
# `execute_collect_morsel_sink_op`'s streaming pull-loop; `n = num_workers`,
# unconditionally (reached from the multikey join cascade's probe+agg).
comptime FORKTAG_MSINK_OP_PULL: UInt32 = 2
# `_drive_combine_partition`; `n = num_partitions`, so its geometry is the one
# msink fork whose fan is NOT the worker count. The tag turns its share of site
# 8's span into a per-fork fact instead of a bracket-derived one.
comptime FORKTAG_MSINK_COMBINE_PART: UInt32 = 3

# `join_multi_key_parallel_build.mojo` -- the two waves of the composite build.
# Their sites (55 / 47) each have exactly ONE dispatch, so these tags are not
# needed for attribution; they are stamped because the notes also carry the
# geometry (`units` = chunks, `rows` = build rows) that explains each wave's
# occupancy, and a wave whose numbers travel with it cannot be paired wrongly.
comptime FORKTAG_MK_HT_FILL: UInt32 = 4
comptime FORKTAG_MK_BUILD: UInt32 = 5


# -----------------------------------------------------------------------------
# NAMED SERIAL-PHASE ids.
#
# WHY THESE EXIST. `sched_trace_site(s, 1)` (`inter_ns`) charges a driver-serial
# window to the site of the fork that PRECEDED it, so a site row names the fork
# BEFORE the window, not the code running IN it. `inter_next_ns` (field 6) adds
# the mirror-image POST-barrier attribution and `inter_same_ns` (field 7) the
# share where the two agree — together they BRACKET a window's owner without any
# annotation. Where they DISAGREE (a prev != next handoff) only an explicit
# bracket can split the window, and that is what these phase ids are for: a
# driver brackets a named serial region and reports (wall, fork); SERIAL =
# wall - fork is the fork-excluded residue a parallelization could recover.
#
# Every id MUST mirror the `_sched_phase_name` switch in
# komira_async/reactor/_posix_shim.c (diagnostic label only). id 0 is reserved
# as "no phase" and is rejected by the recorder.
# -----------------------------------------------------------------------------
comptime PHASE_CONCAT_TILED_SETUP: UInt32 = 1     # _concat_tiled entry -> fork
comptime PHASE_CONCAT_TILED_ASSEMBLE: UInt32 = 2  # _concat_tiled barrier -> return
comptime PHASE_CONCAT_COLS_SETUP: UInt32 = 3      # _concat_impl entry -> fork
comptime PHASE_CONCAT_COLS_ASSEMBLE: UInt32 = 4   # _concat_impl barrier -> return
comptime PHASE_RESIDUAL_SEMI_ANTI_SERIAL: UInt32 = 5  # serial NLJ mark kernel

# -----------------------------------------------------------------------------
# COMPOSITE-KEY JOIN ids 6..12.
#
# `materialize_composite_join_over_batches` (the composite-key join leaf) has
# two forks (SITE_JOIN_MULTIKEY=13 probe, SITE_GATHER_*=40/41/42 assemble);
# without brackets every driver-SERIAL window between them is anonymous and
# lands in the inter-gap of whatever unrelated site forked last. These ids make
# that budget readable from a run.
#
# The five driver phases partition the leaf's wall end to end:
#   6 EXTRACT_BUILD + 7 EXTRACT_PROBE -> the per-side key materialization
#   8 HT_BUILD -> MultiKeyHashJoinBuilder.build
#   9 PROBE -> wall around the probe; fork = the site-13 span, so
#     SERIAL = wall - fork is EXACTLY the post-barrier per-worker index-list
#     merge, the window the 13->40 SCHED_TRANS cell could only bound from above.
#   10 ASSEMBLE -> wall around assemble_join_result*; fork = the 40/41/42
#     gather spans, so SERIAL is the assemble's own serial residue.
# 11 / 12 cut ACROSS 6 and 7 (they are recorded inside the shared kernel
# `extract_join_key_columns_typed`, so they cover every caller, not just this
# leaf): the `as_string` step vs the FNV-1a hash loop. They are the two
# candidate mechanisms inside the extract that a leaf-symbol profile cannot
# separate, because the fresh-allocation page-fault cost lands in an
# unresolved `[unknown]`. 11's window is an Arc refcount bump for a plain
# STRING key column (`Column.share_as_string`), and 12 FORKS its per-row loop
# across the caller's pool as `SITE_JOINKEY_HASH` (45) — so 12, and the 6/7
# brackets containing it, report a real `fork_ns` and `SERIAL = wall - fork`
# is the residue.
# -----------------------------------------------------------------------------
comptime PHASE_CJ_EXTRACT_BUILD: UInt32 = 6   # extract build-side join keys
comptime PHASE_CJ_EXTRACT_PROBE: UInt32 = 7   # extract probe-side join keys
comptime PHASE_CJ_HT_BUILD: UInt32 = 8        # MultiKeyHashJoinBuilder.build
comptime PHASE_CJ_PROBE: UInt32 = 9           # probe (SERIAL = index-list merge)
comptime PHASE_CJ_ASSEMBLE: UInt32 = 10       # assemble_join_result*
comptime PHASE_JOINKEY_AS_STRING: UInt32 = 11  # extract: as_string buffer copy
comptime PHASE_JOINKEY_FNV: UInt32 = 12        # extract: FNV-1a hash loop


# -----------------------------------------------------------------------------
# TAIL-WINDOW ids 13..23. A query can lose most of its gap to a reference
# engine to PARALLELISM rather than to excess work: the same useful CPU retired
# at a fraction of the effective threads. The `SCHED_TRANS` table locates the
# serial wall, but a transition cell names the fork BEFORE a window, never the
# code IN it. These ids name the code.
#
# Each was placed from a DRIVER-TID-RESTRICTED LBR profile, never from reading
# source: `perf record --call-graph lbr` + `perf script --tid <main tid>` +
# fold. (`--call-graph fp` resolves almost none of the Mojo callers, and
# `perf report --pid` filters by PROCESS, so it does NOT restrict to the driver
# thread — the `pid` sort key is what splits by TID.)
#
# WINDOW A — 13/14/15 — the in-mem RESIDENT leaf pipeline. With tables resident
# in an InMemoryRegistry, the whole filter+gather can run on the driver with
# the pool parked: predicate eval (e.g. libc `memmem` for a `NOT LIKE
# '%x%y%'`), gather, and leaf resolve.
#
# WINDOW B — 16/17 — the PLAN-PREPARE spine (EngineContext._prepare_plan).
# Both scale with the RESIDENT DATA VOLUME, not with plan size, and both fire
# once per rep with `fork == 0` by construction:
#   16 `_inline_registry_scans` -> `_inline_one_registry_scan` -> `copy_batch`
#      deep-copies every registry batch INTO the plan.
#   17 `_apply_dup_agg_materialize` -> `collect_agg_subtree_hashes` ->
#      `_write_plan_node` -> `SourceVariant.structural_id` -> `Column.
#      content_hash` hashes every resident batch's BYTES to derive the
#      agg-CSE structural id.
#
# WINDOW C — 18..22 — `HashBuildSink.combine_parallel`. Ids 20 + 21 are the two
# steps BETWEEN that driver's two forks: the int64 key `Column.as_primitive`
# (a COPY) and `_finalize_dynamic_filter_from_keys` (a SECOND,
# element-by-element `List[Int64]` copy of the same keys). 19 and 22 wrap the
# two forks themselves, so the window's `wall - fork` partition is readable end
# to end from one dump.
#
# WINDOW D — 23 — the multikey cascade driver's HT build, on ONE thread.
#
# Every id MUST mirror `_sched_phase_name` + `_sched_phase_unit` in
# komira_async/reactor/_posix_shim.c.
# -----------------------------------------------------------------------------
comptime PHASE_INMEM_LEAF_RESOLVE: UInt32 = 13    # @unit=rows_resolved resident batch materialize
comptime PHASE_INMEM_FILTER_EVAL: UInt32 = 14     # @unit=rows_evaluated predicate eval (LIKE/memmem)
comptime PHASE_INMEM_FILTER_GATHER: UInt32 = 15   # @unit=rows_gathered survivor gather
comptime PHASE_PLAN_INLINE_REGISTRY: UInt32 = 16  # @unit=copy_bytes planner registry deep-copy
comptime PHASE_PLAN_AGG_CSE_HASH: UInt32 = 17     # @unit=hash_bytes planner content-hash walk
comptime PHASE_HBS_GATHER_MORSELS: UInt32 = 18    # @unit=morsels per-worker slab gather+sort
comptime PHASE_HBS_PAYLOAD_CONCAT: UInt32 = 19    # @unit=rows build-side concat (FORKS)
comptime PHASE_HBS_KEY_AS_PRIMITIVE: UInt32 = 20  # @unit=keys_copied key column copy
comptime PHASE_HBS_DYNAMIC_FILTER: UInt32 = 21    # @unit=keys_copied dynamic-filter key copy
comptime PHASE_HBS_HT_BUILD: UInt32 = 22          # @unit=keys HT build (FORKS)
comptime PHASE_MK_HT_BUILD: UInt32 = 23           # @unit=build_rows multikey HT build
comptime PHASE_INMEM_LEAF_PROJECT: UInt32 = 24    # @unit=rows_projected resident projection narrow

# -----------------------------------------------------------------------------
# REGION ids. Ids 25+ are opened with
# `SchedRegion`, which OBSERVES its nesting on a thread-local stack instead of
# declaring it in `_sched_phase_is_nested`. They share this one id space with
# the legacy bracket ids above — one id, one name, one `@unit`.
#
# ⚠ THE ROOT IS NOT OPTIONAL. Without a region declared as the root there is no
# denominator and no UNATTRIBUTED term: the rows are individually true and add
# up to nothing. `sched_region_set_root` declares it; the dump prints
# `partition_valid=0` when it is missing.
# -----------------------------------------------------------------------------
comptime PHASE_QUERY_ROOT: UInt32 = 25  # @label=query_root whole-query driver bracket; self_ns == UNATTRIBUTED

# THE GENERIC PIPELINE STAGES. These bracket `materialize_plan`'s
# own three stages, which EVERY query traverses — there is not one
# query-specific id here, and that is deliberate.
#
# ⚠ WHY NO QUERY-SHAPED IDS. A set of ids shaped after one query would
# decompose that query and nothing else — a narrow-envelope fix and a fitted
# instrument. Bracketing the STAGES answers every query's question on the same
# run, because the stages are where the driver actually spends its serial time
# regardless of plan shape. None of the 24 legacy ids covers any of this: 1-4
# concat, 5 residual, 6-12 composite join, 13-15 + 24 in-mem leaf, 16-17
# plan-prepare INTERNALS (not the stage), 18-22 hash-build-sink, 23 multikey HT.
#
# Together with the root these partition the timed wall with no gap to argue
# about. A stage that comes back large gets sub-split next — and that costs two
# lines.
comptime PHASE_PLAN_PREPARE: UInt32 = 26     # @unit=rows STAGE 1: _prepare_plan (optimize + compile + fastpath door)
comptime PHASE_ENTRY_BIND: UInt32 = 27       # @unit=rows STEP 6/L5: scan-bind scope + in-mem payload bind
comptime PHASE_WALKER_DISPATCH: UInt32 = 28  # @unit=rows STAGE 2: the raising central walker (all execution)

# -----------------------------------------------------------------------------
# STAGE-2 SUB-SPLIT — ids 29..42.
#
# `walker_dispatch` (28) typically holds the overwhelming majority of a rooted
# partition, and a partition whose largest bucket is nine tenths of the total
# localizes nothing. These ids cut STAGE 2 at boundaries a lever can be aimed
# at.
#
# ⚠ EVERY ONE OF THESE BRACKETS THE CODE IT NAMES, NOT THE FORK BEFORE IT. That
# is the reason they are regions and not more `SCHED_SITE` rows: a site's
# `inter_ns` accrues to the PREVIOUS fork, so it measures the serial time that
# FOLLOWS a site rather than that site's own. A region's wall is its own
# bracket's, and its `self_ns` excludes every nested region by OBSERVED
# nesting, so no row here can inherit a neighbour's time.
#
# THE OPERATOR LAYER (29..38) is cut at the walker's own dispatch points, so it
# is plan-shape-generic: any query with a join gets `walk_join`, any query with
# a scan gets `walk_leaf_scan`, with no per-query code. `walk_leaf_scan` is the
# SCAN/DECODE bucket.
#
# THE JOIN LAYER (39..42) splits what is left INSIDE one join: resolving a side
# to a resident batch (recursion or collect) vs driving a kernel over two
# already-resident sides. `join_side_resolve` is where a scan under a join
# lands; `join_residual_mark` is the EXISTS / NOT EXISTS mark join (fork sites
# 50/51/52) seen from the DRIVER's side of the barrier.
#
# A window NOT bracketed here neither vanishes nor double-counts: it stays in
# its parent region's `self_ns`, which is the honest place for it.
# -----------------------------------------------------------------------------
comptime PHASE_WALK_LEAF_SCAN: UInt32 = 29   # @unit=rows non-breaker leaf: parquet collect / in-mem resolve
comptime PHASE_WALK_JOIN: UInt32 = 30        # walker JOIN breaker dispatch
comptime PHASE_WALK_AGG: UInt32 = 31         # walker AGGREGATE breaker dispatch
comptime PHASE_WALK_SORT: UInt32 = 32        # walker SORT/TOPN breaker dispatch
comptime PHASE_WALK_DISTINCT: UInt32 = 33    # walker DISTINCT (+ all-count-distinct) dispatch
comptime PHASE_WALK_CROSS: UInt32 = 34       # walker CROSS (scalar-broadcast) dispatch
comptime PHASE_WALK_WINDOW: UInt32 = 35      # walker PARTITION_BY window dispatch
comptime PHASE_WALK_PTOPN: UInt32 = 36       # walker PARTITION_TOPN dispatch
comptime PHASE_WALK_PROJECT: UInt32 = 37     # @unit=rows project-over-breaker narrow / computed eval
comptime PHASE_WALK_FILTER: UInt32 = 38      # @unit=rows post-breaker residual filter over a resident batch
comptime PHASE_JOIN_SIDE_RESOLVE: UInt32 = 39   # @unit=rows one join side -> resident batch
comptime PHASE_JOIN_INMEM_KERNEL: UInt32 = 40   # @unit=rows both-resident build+probe kernel
comptime PHASE_JOIN_RESIDUAL_MARK: UInt32 = 41  # @unit=rows SEMI/ANTI residual mark join (sites 50/51/52)
comptime PHASE_JOIN_DIRECT_LEAF: UInt32 = 42    # @unit=rows fused parquet 32-way probe leaf

# RUNG 2 — inside the in-mem kernel (ids 48..50). The kernel's build / probe /
# concat boundaries as regions turn three timings into three rows of a
# partition that closes. `join_inmem_kernel` keeps the setup between them as
# its own self_ns.
comptime PHASE_JOIN_HT_BUILD: UInt32 = 48     # @unit=build_rows chain HT build + key as_primitive
comptime PHASE_JOIN_PROBE_FAN: UInt32 = 49    # @unit=probe_rows morsel-parallel probe fan
comptime PHASE_JOIN_OUT_CONCAT: UInt32 = 50   # @unit=rows drain + column-parallel output concat

# RUNG 3 — the two windows rung 2 leaves UNNAMED (ids 51..52). With build,
# probe and concat all bracketed, the kernel's OWN residue is still a bucket
# nobody can aim at. Both are per-JOIN fixed costs, not per-row ones, so read
# them as `wall/count`, never as a rate.
comptime PHASE_JOIN_KERNEL_SETUP: UInt32 = 51    # driver-owned Arcs + output schema (O(columns))
comptime PHASE_JOIN_KERNEL_RELEASE: UInt32 = 52  # HT + build-batch + schema + shared-state teardown

# RUNG 4 — inside the setup window (ids 53..54). The setup window is wholly
# serial with every worker parked, and holds three costs with three different
# shapes. These two carve out the O(workers) and O(rows) halves so id 51 keeps
# only the O(columns) one.
comptime PHASE_JOIN_PROBE_OPS: UInt32 = 53     # @unit=workers per-worker JoinProbeOpAdapter slab
comptime PHASE_JOIN_MORSEL_SPLIT: UInt32 = 54  # @unit=morsel_rows BatchMorselSource split of the probe batch

# -----------------------------------------------------------------------------
# STAGE-1 SUB-SPLIT — ids 43..47.
#
# These name every step the FULL Stage-1 door composes, so the `plan_prepare`
# residue is `check_scan_bindings_at_entry` + the plan-validation gate and
# nothing else (Stage 1 can fork: scan dedup materializes shared relations).
#
# ⚠ THE COLD REP IS IN HERE. A first rep pays a cold optimize many times the
# warm cost, and the region counters are CUMULATIVE, so a per-rep mean over a
# short run is dominated by it. Read `count` and divide, or difference two runs
# at different rep counts; never read a mean as a warm cost.
# -----------------------------------------------------------------------------
comptime PHASE_PREP_SCAN_STATS: UInt32 = 43   # precompute_scan_stats: footer row-count/NDV into the scans
comptime PHASE_PREP_PLAN_HASH: UInt32 = 44    # structural_hash + compute_stats_hash + the L2 resolved cache
comptime PHASE_PREP_OPTIMIZE: UInt32 = 45     # L1 lookup -> optimize_full (MISS) / factory clone (HIT)
comptime PHASE_PREP_SCAN_DEDUP: UInt32 = 46   # _apply_scan_dedup (shared-relation materialize; FORKS)
comptime PHASE_PREP_FASTPATH: UInt32 = 47     # collect-shape detect + metadata-footer fast path


# -----------------------------------------------------------------------------
# THE CHUNKED TERMINAL — ids 55..59.
#
# `materialize_plan_chunked` is a SECOND terminal. Without regions of its own a
# chunked query would report a VALID partition with `UNATTRIBUTED` at ~100%,
# because the three stage regions live in `materialize_plan`. Queries whose
# output column exceeds Arrow's int32 offset ceiling can ONLY run there.
#
# ⚠ THE THREE STAGE IDS ARE DELIBERATELY *REUSED*, NOT CLONED. The chunked
# terminal brackets `PHASE_PLAN_PREPARE` / `PHASE_ENTRY_BIND` /
# `PHASE_WALKER_DISPATCH` (26/27/28) around the SAME three stages, because it
# runs the same Stage-1 door and the same bind door as `materialize_plan`. That
# is what lets a reader put a chunked query's table beside any other row for
# row; a parallel `PHASE_CHUNK_PREPARE` would make the two paths incomparable
# for no gain. Exactly one terminal runs per execution, so the counters cannot
# double-count.
#
# The ids below name what is BELOW stage 2 and exists only on this path.
# -----------------------------------------------------------------------------
comptime PHASE_CHUNK_JOIN_CASCADE: UInt32 = 55  # try_execute_join_plan_table (the `_try_run_join` cascade)
comptime PHASE_CHUNK_RECOVERY: UInt32 = 56      # overflow RECOVERY: side resolve + composite chunked leaf
comptime PHASE_CHUNK_PROJECT: UInt32 = 57       # @unit=rows per-chunk pure-colref projection

# Inside `PHASE_CJ_ASSEMBLE` (id 10), which is where the chunked composite leaf
# spends the output-assembly half of its wall. The two have DIFFERENT shapes and
# separating them is the whole point: pricing is O(output rows x priced string
# columns) and answers "how many chunks", the gather is O(output rows x columns)
# and does the copying. Reading them as one number cannot distinguish a chunking
# tax from the copy the query is actually for.
comptime PHASE_CJ_CHUNK_PRICE: UInt32 = 58   # @unit=rows join_output_chunk_bounds byte pricing (FORKS)
comptime PHASE_CJ_CHUNK_GATHER: UInt32 = 59  # @unit=rows per-chunk assemble_join_result_dispatch (FORKS)


# -----------------------------------------------------------------------------
# THE FUSED PARQUET JOIN LEAF — ids 60..66.
#
# WHY THESE EXIST, AND WHY THE FORK TABLE IS NOT ENOUGH. `join_direct_leaf`
# (42) is ONE region over the whole of `materialize_parquet_join` ->
# `_run_fused_parquet_probe`, and on a bare INNER equi-join over two parquet
# files that region IS the query: it would carry ~all of the root's wall as a
# single `self_ns` with nothing inside it. The SCHED_SITE fork table does report
# the four forks on this route (22 build scan, 24/9 the build's HT waves, 8 the
# fused probe, 26 the output assembly), but a fork span is NOT a phase wall —
# it excludes every driver-serial window between the forks, it has no
# denominator, and summing fork spans does not close against anything.
#
# These seven ids partition the leaf END TO END, so `sum(self_ns)` closes into
# `join_direct_leaf`'s wall exactly the way every other region does, and the
# leaf's own `self_ns` becomes the leaf's UNNAMED residue rather than the whole
# query.
#
#   60 build_setup    driver-serial: build projection resolve, footer parse,
#                     hooks, HashBuildSpec/HashBuildSink construction.
#   61 build_scan     `execute_collect_no_combine` — the build-side parquet
#                     DECODE + per-worker HashBuildSink insert. FORKS (site 22).
#                     ⇒ DuckDB's TABLE_SCAN(build) + HASH_JOIN Sink.
#                     ⚠ DECLARES NO `@unit`, DELIBERATELY. The build ROW COUNT is
#                     not known until `combine_parallel` has drained the
#                     per-worker slabs, i.e. after this window closes; a phase
#                     that declared `@unit=build_rows` and could only ever set
#                     n=0 would print `n=0 unit=build_rows`, which reads as a
#                     MEASURED zero. 62 carries the count instead.
#   62 build_combine  `combine_parallel` + the three takes + `free()` — morsel
#                     gather, payload concat, key `as_primitive`, chain-HT build,
#                     bloom/dynamic-filter OR-reduce. FORKS.
#                     ⇒ DuckDB's HASH_JOIN Finalize.
#                     ⚠ The legacy `PHASE_HBS_*` brackets (18..22) sit INSIDE
#                     this window and are in the SCHED_PHASE table, NOT the
#                     region partition — they do not double-count here, and they
#                     do not sum to it either.
#   63 probe_setup    `_run_fused_parquet_probe` entry -> the wave: output
#                     schema derivation, deferred-gather eligibility, probe
#                     projection resolve, hooks, dynamic-filter install, the
#                     O(workers) `Slab[JoinProbeOpAdapter]` construction.
#   64 probe_wave     `execute_collect_morsel_sink_op` — the FUSED scan+probe.
#                     FORKS (site 8). A WALL alone cannot split it: see
#                     `SCHED_OPWAVE`, which divides the wave's worker-busy time
#                     into the operator's own `elapsed_compute` (PROBE) and the
#                     residue (DECODE + sink).
#                     ⇒ DuckDB's TABLE_SCAN(probe) + HASH_JOIN Execute.
#   65 output_assemble the deferred assembly / the count-only fold / the
#                     column-parallel concat — whichever arm this join took.
#                     FORKS (site 26).
#   66 release        the Arc teardown tail: the HT, the build batch, the output
#                     schema, the per-worker resume slab, the ExprPools, the
#                     dynamic filter. Freeing a large hash table is NOT free.
#
# ⚠ A ZERO HERE IS NOT THE SAME AS AN ABSENCE. Every declared phase is printed
# by `SCHED_REGION_DECLARED` with its `count`, wired flag and sample counts, so
# `count=0` ("this phase never ran on this query") is distinguishable from
# `count>0 self_ns=0` ("it ran and cost nothing") and from `wired=0` ("no call
# site opens it — the counter does not exist yet").
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
comptime PHASE_FJ_BUILD_SETUP: UInt32 = 60      # @unit=build_cols fused-join build-side driver setup
comptime PHASE_FJ_BUILD_SCAN: UInt32 = 61       # build parquet decode + sink insert (FORKS; NO unit -- see below)
comptime PHASE_FJ_BUILD_COMBINE: UInt32 = 62    # @unit=build_rows HT build + payload concat + bloom (FORKS)
comptime PHASE_FJ_PROBE_SETUP: UInt32 = 63      # @unit=workers probe-side driver setup + per-worker ops
comptime PHASE_FJ_PROBE_WAVE: UInt32 = 64       # @unit=probe_rows fused scan+probe wave (FORKS)
comptime PHASE_FJ_OUTPUT_ASSEMBLE: UInt32 = 65  # @unit=rows deferred assembly / concat / count fold (FORKS)
comptime PHASE_FJ_RELEASE: UInt32 = 66          # @unit=build_rows HT + build batch + slab teardown


# -----------------------------------------------------------------------------
# Enable / lifecycle
# -----------------------------------------------------------------------------


@always_inline
def sched_trace_enabled() -> Bool:
    """True iff scheduler tracing was enabled by `sched_trace_configure` (or a
    test's `sched_trace_force_enable`). Call at construction time and cache the
    result in a field — never per-iteration."""
    return external_call["komira_sched_trace_enabled", Int32]() != Int32(0)


@always_inline
def sched_trace_reset():
    """Zero every counter (precise per-window measurement + the unit test)."""
    _ = external_call["komira_sched_reset", Int32]()


@always_inline
def sched_trace_dump():
    """Print the machine-parseable summary block to stderr on demand (also fired
    automatically at process exit once enabled)."""
    _ = external_call["komira_sched_dump", Int32]()


@always_inline
def sched_trace_pool_depth() -> Int64:
    """The (a)/(b) discriminator: the process-global on-pool dispatch depth
    (`_OnPoolDispatchGuard`). > 0 == a run_with_state dispatch is live (a worker
    parking now is an intra-segment straggler, bucket b); == 0 == no dispatch is
    live (an inter-segment barrier park, bucket a)."""
    return external_call["komira_on_pool_depth", Int64]()


# -----------------------------------------------------------------------------
# Driver-side recorders (run_with_state)
# -----------------------------------------------------------------------------


@always_inline
def sched_trace_add_segment(
    site: UInt32, fork_start_ns: UInt64, barrier_ns: UInt64, n_tasks: UInt64
):
    """Record one fork->barrier span + the driver-serial inter-fork gap since the
    previous dispatch returned (bucket (a) driver-view cross-check), binned by
    call-site `site`. The fork span/count/task-count accrue to `site`; the
    inter-gap accrues to the site of the PREVIOUS fork (its combine/finalize
    window). `n_tasks` is n_workers (parallel shards) for this fork."""
    _ = external_call["komira_sched_add_segment", Int32](
        site, fork_start_ns, barrier_ns, n_tasks
    )


@always_inline
def sched_trace_worker_busy_total() -> UInt64:
    """Total worker-busy ns across all workers — the sum of `handle.run()` wall
    each worker has accrued. Snapshot at fork_start and again after the barrier;
    the DELTA is the worker time the fork actually consumed. See
    `sched_trace_add_segment_occ`."""
    return external_call["komira_sched_worker_busy_total", UInt64]()


@always_inline
def sched_trace_add_segment_occ(
    site: UInt32,
    fork_start_ns: UInt64,
    barrier_ns: UInt64,
    n_tasks: UInt64,
    busy_at_fork_ns: UInt64,
    busy_at_barrier_ns: UInt64,
):
    """`sched_trace_add_segment` plus the IN-BAND OCCUPANCY sample.

    `n_tasks` says how many shards were POSTED, not how many did WORK — reading
    22 on a wave where 2 shards claim a morsel and 20 return immediately says
    "fully fanned" about a 9%-occupied fork. The occupancy sample closes that:

        span_avg  = (busy_at_barrier - busy_at_fork) / (barrier - fork_start)
        occupancy = span_avg / n_tasks

    Pass 0/0 for "no sample"; the recorder keeps a separate count so a site with
    no sample prints -1 rather than 0.00 ("unmeasured" and "idle" are different
    findings). Time-weighted AVERAGE, deliberately, not a max over "shards that
    claimed a morsel": a max over-reports a wave whose shards are briefly busy
    and then idle, and it is the average that a re-grain lever actually moves.

    ⚠ THE SAMPLE LAGS BY UP TO ONE WORKER ITERATION. `_SchedWorkerAccum.store()`
    runs at the TOP of each worker loop iteration — AFTER the handle it just ran
    — and the barrier can return before that worker loops around. A fork may
    therefore miss the tail of its own last shard and pick up the previous
    fork's, so a SHORT fork following a long one can read occupancy > 1.0. The
    dump FLAGS such a row `occ_lag=1` rather than clamping it: a clamp would
    delete the one signal saying the number is an artifact. The discriminating
    case is a ~10x read (2 of 22 vs 22 of 22), which the lag does not threaten."""
    _ = external_call["komira_sched_add_segment_occ", Int32](
        site, fork_start_ns, barrier_ns, n_tasks,
        busy_at_fork_ns, busy_at_barrier_ns,
    )


# -----------------------------------------------------------------------------
# PER-FORK ROWS
# -----------------------------------------------------------------------------


@always_inline
def sched_trace_set_fork_note(
    tag: UInt32, expect_site: UInt32, units: UInt64, rows: UInt64
):
    """Stamp the CALL SITE of the fork about to happen, for the per-fork rows.

    The recorder bins busy/span per SITE, summed over every fork. Where one site
    id is stamped by several dispatches that is unattributable: `SITE_SINK_EXECUTOR`
    (8) has THREE and can fire several times per rep, and an averaged
    occupancy there is consistent both with the one
    big pipeline fork being that packed and with it being nearly full and dragged
    down by several tiny ones. This is what separates them.

    `tag` is a `FORKTAG_*`. `units` / `rows` are whatever geometry the call site
    already holds (0 = none) -- they ride along so a fork's occupancy and the
    geometry that explains it cannot be paired wrongly.

    `expect_site` is the `SITE_*` this caller is about to fork at, and it is NOT
    redundant: it is what makes a STOLEN note detectable. `komira_sched_add_segment_occ`
    consumes-and-clears the note, so if any other dispatch forks between this call
    and the intended one, the consuming fork's own site will not match and the row
    is recorded UNLABELLED with `note_mismatch=1`, counted in the
    `SCHED_FORKS_BEGIN` header. A wrong tag is never printed.

    CALL IT IMMEDIATELY BEFORE THE FORK, with no dispatch in between, ONCE PER
    FORK -- never per morsel and never per row. And call it only under an
    already-resolved cold `sched_trace_enabled()` Bool: the shipped path must not
    reach it at all.
    """
    _ = external_call["komira_sched_set_fork_note", Int32](
        tag, expect_site, units, rows
    )


@always_inline
def sched_trace_fork_count(field: Int32) -> UInt64:
    """Fork-ring census. 0=forks SEEN (may exceed the ring) 1=rows KEPT
    2=notes set 3=notes consumed 4=notes site-MISMATCHED 5=notes overwritten
    before use 6=ring capacity.

    (0) > (1) is FIRST-N truncation of the tail, never loss of the head.
    (4) or (5) non-zero is an attribution-health finding: some fork ran between a
    stamp and the fork it was written for. Check it before quoting any tag."""
    return external_call["komira_sched_fork_count", UInt64](field)


@always_inline
def sched_trace_fork(i: UInt64, field: Int32) -> UInt64:
    """One per-fork row. 0=site 1=tag 2=tasks 3=span_ns 4=busy_ns
    5=inter_ns (the driver-serial gap BEFORE this fork) 6=t0_rel_ns
    7=units 8=rows 9=flags (bit0 = no occupancy sample, bit1 = note site
    mismatch).

    Occupancy is deliberately NOT returned: the caller divides
    `busy_ns / span_ns / tasks` from the recorded integers, so a rounded double
    can never be mistaken for a measurement. `flags & 1` means the fork carried no
    occupancy sample -- UNMEASURED, which is a different finding from idle."""
    return external_call["komira_sched_get_fork", UInt64](i, field)


@always_inline
def sched_trace_add_dispatch(ns: UInt64, erasures: UInt64):
    """Record the enqueue-loop dispatch wall (make_borrowed_erased + shard build +
    try_send) + the erasure volume (= n_workers per dispatch). Bucket (c)."""
    _ = external_call["komira_sched_add_dispatch", Int32](ns, erasures)


@always_inline
def sched_trace_fork_ns_now() -> UInt64:
    """The process-global cumulative fork->barrier span sum (`_sched_fork_ns`,
    the same as `sched_trace_global(3)`). Snapshot it around a driver-serial
    phase bracket: the delta across the phase = the fork span that COMPLETED
    inside the phase (its already-parallel portion). serial = wall - fork_delta
    is the fork-excluded recoverable residue. Driver-thread-only read (the
    dispatcher is non-reentrant, so only the phase's own internal forks bump
    this during the bracket)."""
    return external_call["komira_sched_get_global", UInt64](Int32(3))


@always_inline
def sched_trace_add_msink_phase(
    drain_ns: UInt64,
    combine_wall_ns: UInt64,
    combine_fork_ns: UInt64,
    finalize_wall_ns: UInt64,
    finalize_fork_ns: UInt64,
    driver_wall_ns: UInt64,
    setup_ns: UInt64 = UInt64(0),
    prepare_ns: UInt64 = UInt64(0),
    teardown_ns: UInt64 = UInt64(0),
    prepare_fork_ns: UInt64 = UInt64(0),
):
    """Record one morsel-sink collect driver's combine-phase measurements.

    `execute_collect_morsel_sink[_op]`: the per-worker-locals DRAIN wall, the WALL
    + internal-FORK span of both `sink.combine()` (the parallelize target)
    and `sink.finalize()`, and the whole-driver WALL (`driver_wall_ns`, entry->
    return incl. the parallel scan/agg fork). SERIAL = wall - fork is the
    fork-excluded driver-serial residue (recoverable by parallelizing). The
    combine/finalize serial residues sit inside the SITE_SINK_EXECUTOR inter-gap;
    the dump's PHASE block partitions that inter-gap (shares of INTER-GAP, NOT
    wall). `driver_wall_ns` is the denominator for the dump's WALL_ATTR block,
    which reports each phase as a % of the RUN's wall (the number a perf
    decision must read — the inter-gap % overstates the lever ~10x). Call ONCE per
    breaker driver on the trace-on path only (gate on cached
    `sched_trace_enabled()`).

    HANDOFF-RESIDUAL BRACKETS. The three
    trailing args name the driver-serial spine that would otherwise be an
    anonymous "handoff residual" INSIDE an otherwise-instrumented window with
    no name:
      * `setup_ns`    — driver entry -> the streaming fork: source hooks, the
        fan-out cap, the per-worker locals slab (`n_workers` x
        `sink.init_local()`, one heap allocation EACH), `sink.init_global()`, the
        State build. NB this window precedes site 8's OWN fork, so it lands in the
        PREVIOUS site's inter-gap; the dump reports it on its own line, NOT inside
        the site-8 partition.
      * `prepare_ns` / `prepare_fork_ns` — between the combine bracket and the
        finalize bracket: `num_partitions()` + `_drive_combine_partition` +
        `prepare_finalize()`. **This phase is NOT pure driver-serial**:
        `_drive_combine_partition` calls `dispatcher.run_with_state(...,
        site_id=SITE_SINK_EXECUTOR)` whenever `num_partitions() > 1`, so it must
        be reported wall/fork/serial like combine and finalize. (Reporting
        only its wall under a `(serial)` label would claim many times the
        inter-gap it is part of, and point at a "serial prepare" that is in
        fact a parallel fork.)
      * `teardown_ns` — between the finalize bracket and the driver's return: the
        Finished-arm guard, the output `take_slot_unchecked(0)`, the
        FinalizeOutput drop.
    `setup_ns` and `teardown_ns` contain no dispatch and ARE pure driver-serial,
    so wall == serial for those two. All args default to 0 so a caller not yet
    re-bracketed compiles and behaves as before.
    """
    _ = external_call["komira_sched_add_msink_phase", Int32](
        drain_ns, combine_wall_ns, combine_fork_ns,
        finalize_wall_ns, finalize_fork_ns, driver_wall_ns,
        setup_ns, prepare_ns, teardown_ns, prepare_fork_ns,
    )


# -----------------------------------------------------------------------------
# Getters (unit test + Mojo-side introspection). Field selectors match the C.
# -----------------------------------------------------------------------------


@always_inline
def sched_trace_global(field: Int32) -> UInt64:
    """Global counter by field id: 0=dispatch_ns 1=erasure_count 2=seg_count
    3=fork_ns 4=inter_ns 5=msink_drain_ns 6=msink_combine_wall_ns
    7=msink_combine_fork_ns 8=msink_finalize_wall_ns 9=msink_finalize_fork_ns
    10=msink_phase_count (5-10 = combine-phase split);
    11=msink_driver_wall_ns (cumulative) 12=msink_last_driver_wall_ns
    13=msink_last_drain_ns 14=msink_last_combine_wall_ns
    15=msink_last_combine_fork_ns 16=msink_last_finalize_wall_ns
    17=msink_last_finalize_fork_ns (11-17 = per-run WALL);
    18=msink_setup_ns 19=msink_prepare_ns 20=msink_teardown_ns
    21=msink_last_setup_ns 22=msink_last_prepare_ns 23=msink_last_teardown_ns
    (18-23 = msink handoff-residual brackets);
    24=msink_prepare_fork_ns 25=msink_last_prepare_fork_ns (PREPARE fork:
    19 and 22 are prepare WALLs, which INCLUDE the
    `_drive_combine_partition` fork; the driver-serial residue is wall - fork)."""
    return external_call["komira_sched_get_global", UInt64](field)


@always_inline
def sched_trace_worker(wid: UInt64, field: Int32) -> UInt64:
    """Per-worker counter by field id: 0=run 1=pop 2=park_inter 3=park_intra
    4=spin 5=empty_windows 6=tasks 7=seen; 8=spin_found_ns 9=found_windows
    (8-9 = productive-spin blind spot);
    10=empty_inter_w 11=empty_intra_w (empty-window causality split;
    10+11 == 5 by construction)."""
    return external_call["komira_sched_get_worker", UInt64](wid, field)


@always_inline
def sched_trace_site(site: UInt32, field: Int32) -> UInt64:
    """Per-site counter by field id: 0=fork_ns 1=inter_ns 2=count 3=task_sum
    4=task_min 5=task_max; post-barrier attribution:
    6=inter_next_ns 7=inter_same_ns 8=inter_next_count.

    `inter_ns` (1) charges each driver-serial gap to the site of the PREVIOUS
    fork; `inter_next_ns` (6) charges the SAME wall to the site of the FOLLOWING
    fork. The two totals are equal; only the distribution differs. `inter_same_ns`
    (7) is the sub-part where prev == next == `site`, i.e. the window is fenced by
    two forks of THIS site — the share whose ownership needs no further proof."""
    return external_call["komira_sched_get_site_field", UInt64](site, field)


@always_inline
def sched_trace_transition(prev: UInt32, next: UInt32, field: Int32) -> UInt64:
    """Transition matrix cell: the driver-serial wall
    that fell between a `prev`-site fork's barrier and a `next`-site fork's
    start. field 0=gap_ns 1=count. `prev == next` cells are confirmed-own
    windows; `prev != next` cells straddle a driver handoff (the tail of `prev`
    plus the head of `next`) and need an explicit phase bracket to split."""
    return external_call["komira_sched_get_transition", UInt64](
        prev, next, field
    )


@always_inline
def sched_trace_add_serial_phase(
    phase: UInt32, wall_ns: UInt64, fork_ns: UInt64
):
    """Generic named serial-phase bracket. Record one
    driver-serial region: `wall_ns` = the bracket's wall, `fork_ns` = the
    fork->barrier span that COMPLETED inside it (the delta of
    `sched_trace_fork_ns_now()` across the bracket). SERIAL = wall - fork is the
    fork-excluded residue — the part a parallelization could actually recover; a
    region that already forks internally shows near-zero SERIAL and has nothing
    to recover. Call on the trace-on path only (gate on a cached
    `sched_trace_enabled()`), once per region execution."""
    _ = external_call["komira_sched_add_serial_phase", Int32](
        phase, wall_ns, fork_ns
    )


@always_inline
def sched_trace_add_serial_phase_n(
    phase: UInt32, wall_ns: UInt64, fork_ns: UInt64, n: UInt64
):
    """TAIL-WINDOW bracket: `sched_trace_add_serial_phase` plus the
    region's own WORK UNIT `n` — rows resolved / rows evaluated / keys copied /
    morsels gathered, per `_sched_phase_unit` in the C shim.

    WHY a count and not just a wall. The run-to-run wall
    noise (max-min over byte-identical runs) can exceed a small lever's
    effect, so such a lever is not decidable from wall in one sweep. `n` is exact, reproducible run to run, and moves the
    instant a lever removes work — so a bracket stays falsifiable below its own
    timing floor. Same argument as the `copy_bytes` counter on the join key
    extract. Pass 0 when the region has no meaningful unit."""
    _ = external_call["komira_sched_add_serial_phase_n", Int32](
        phase, wall_ns, fork_ns, n
    )


@always_inline
def sched_trace_thread_cpu_ns() -> UInt64:
    """★ OCCUPANCY FALSIFIER. `CLOCK_THREAD_CPUTIME_ID`
    for the CALLING thread, in ns.

    WHY IT EXISTS. Every `CLASS=BRACKET` row's `serial_ns` is labelled
    `bound=upper`, and the reason is not conservatism: a wall cannot tell a
    driver BURNING CPU inside the window from one PARKED on page faults or a
    blocking read. Fanning out a parked window across 20 workers recovers
    NOTHING, so a lever sized off `serial_ns` alone can be over-stated without
    limit: a window that looks large in wall can shrink several-fold the
    instant occupancy is applied.

    Bracket a window with two of these; `delta / wall` is the fraction the
    thread was on a CPU, and `serial_ns * occ` is the recoverable ceiling.

    THIS CLOCK COUNTS KERNEL TIME ON THIS THREAD, deliberately. A MINOR fault
    is real work 20 threads can do 20-ways, so it belongs in the recoverable
    half; a MAJOR fault or a blocking syscall descheduled the thread and does
    not advance this clock, so it lands in the un-recoverable half. That is
    exactly the split the falsifier is asking about."""
    return external_call["komira_sched_thread_cpu_ns", UInt64]()


@always_inline
def sched_trace_add_phase_cpu(phase: UInt32, cpu_ns: UInt64):
    """Accumulate a `sched_trace_thread_cpu_ns` delta against an EXISTING phase
    id. A separate call rather than a wider `add_serial_phase_n` on purpose: 49
    bracket sites call that one and only the few under investigation should pay
    two extra `clock_gettime`s. A phase with no `cpu_ns` prints no `occ` field
    at all — `occ=0.00` would read as "the driver was parked" when it means
    "nobody measured"."""
    _ = external_call["komira_sched_add_phase_cpu", Int32](phase, cpu_ns)


@always_inline
def sched_trace_add_msink_cpu(finalize_cpu_ns: UInt64, combine_cpu_ns: UInt64):
    """The same falsifier for the msink driver's finalize / combine brackets,
    which live in their own storage rather than the phase table."""
    _ = external_call["komira_sched_add_msink_cpu", Int32](
        finalize_cpu_ns, combine_cpu_ns
    )


@always_inline
def sched_trace_add_msink_run(
    fin_wall_ns: UInt64,
    fin_fork_ns: UInt64,
    fin_cpu_ns: UInt64,
    comb_wall_ns: UInt64,
    comb_fork_ns: UInt64,
    driver_wall_ns: UInt64,
    label: StaticString,
):
    """★ ONE msink driver invocation, recorded SEPARATELY from the sums.

    `SCHED_MSINK finalize` totals every morsel-sink breaker in the run, and on
    a multi-breaker query that sum hides the only question worth asking: WHICH
    sink. A total of 65 ms/rep of finalize at
    near-100% serial cannot say whether that is one 65 ms window or three
    22 ms ones, nor which operator owns it, and a lever aimed at a sum is aimed
    at nothing.

    It matters because the sinks already DISAGREE: `CountDistinctAggSink` forks
    through the `disp_ptr` seam and the same bracket can read almost entirely
    FORKED, while other sinks read almost entirely serial. `label` is the sink's
    own `combine_trace_label()`; most inherit the base's honest `"unlabeled"`,
    and a census of those is a to-do list rather than false coverage.

    Only the FIRST 48 invocations are kept — see the C block for why first-N and
    not a wrap. The count keeps rising past the cap so the dump reports what it
    dropped."""
    _ = external_call["komira_sched_add_msink_run", Int32](
        fin_wall_ns,
        fin_fork_ns,
        fin_cpu_ns,
        comb_wall_ns,
        comb_fork_ns,
        driver_wall_ns,
        label.unsafe_ptr(),
        UInt64(label.byte_length()),
    )


@always_inline
def sched_trace_serial_phase(phase: UInt32, field: Int32) -> UInt64:
    """Named serial-phase counter: 0=wall_ns 1=fork_ns 2=count
    3=serial_ns (wall - fork, saturating); 4=n (TAIL-WINDOW work unit)."""
    return external_call["komira_sched_get_serial_phase", UInt64](phase, field)


# -----------------------------------------------------------------------------
# OP-WAVE — the SCAN / OPERATOR split inside one fused fork
# -----------------------------------------------------------------------------
# See the `SCHED OPWAVE` block in `komira_async/reactor/_posix_shim.c` for the
# subtraction and for why `present`/`absent` are recorded rather than inferred.
# One call per FORK, driver-side, after the barrier — never per morsel.


@always_inline
def sched_trace_add_op_wave(
    site: UInt32,
    busy_ns: UInt64,
    op_ns: UInt64,
    rows_in: UInt64,
    rows_out: UInt64,
    workers: UInt64,
    present: UInt64,
    absent: UInt64,
):
    """Record one op-bearing wave's worker-busy total and the share of it the
    OPERATOR (not the source) accounted for.

    `busy_ns` is the `sched_trace_worker_busy_total()` delta across the fork;
    `op_ns` the summed `elapsed_compute` of the per-worker operators; the
    residue is the DECODE + sink + morsel plumbing. `present`/`absent` count the
    operators that did and did not carry an `elapsed_compute` metric, so a zero
    `op_ns` can be told apart from an unwired counter."""
    _ = external_call["komira_sched_add_op_wave", Int32](
        site, busy_ns, op_ns, rows_in, rows_out, workers, present, absent
    )


@always_inline
def sched_trace_op_wave(site: UInt32, field: Int32) -> UInt64:
    """Op-wave getter. 0=count 1=busy_ns 2=op_ns 3=rows_in 4=rows_out
    5=workers 6=metric_present 7=metric_absent. Process-cumulative."""
    return external_call["komira_sched_get_op_wave", UInt64](site, field)


@always_inline
def sched_trace_opwave_rows_in(site: UInt32) -> UInt64:
    """Total INPUT rows the operators at `site` have seen, process-cumulative.

    This is the honest work unit for a fused scan+operator wave: the driver
    never sees the decoded row count (the whole point of the fusion is that no
    resident batch exists), but every `MorselOperatorImpl` counts the rows it was
    handed. Returns 0 when tracing is OFF — nothing is recorded then, and a
    region's `n` is printed only on a traced run."""
    return sched_trace_op_wave(site, Int32(3))


# -----------------------------------------------------------------------------
# Ambient call-site (SchedSiteScope). An owned enclosing driver can push a site
# id so forks in a callee the runtime cannot label at the call site (peer-owned
# join/concat) are attributed. run_with_state reads the ambient site ONLY when
# its own `site_id` arg is 0 (unlabeled) AND tracing is on — labeled sites never
# touch it.
# -----------------------------------------------------------------------------


@always_inline
def sched_trace_get_site() -> UInt32:
    """The current ambient call-site (0 if no SchedSiteScope is active)."""
    return external_call["komira_sched_get_site", UInt32]()


@always_inline
def sched_trace_swap_site(site: UInt32) -> UInt32:
    """Set the ambient site, returning the previous (for guard restore)."""
    return external_call["komira_sched_swap_site", UInt32](site)


@always_inline
def sched_trace_set_site(site: UInt32):
    """Set the ambient site (guard restore path)."""
    _ = external_call["komira_sched_set_site", Int32](site)


struct SchedSiteScope(Movable):
    """RAII ambient-site guard. Construct with a SITE_* id around a fork region
    in an owned enclosing frame; forks reached inside (in callees the runtime
    cannot label directly) inherit the site. Restores the previous ambient site
    on drop. Zero-cost when tracing is OFF (a cold Bool branch, no external_call).

    Keep the guard var alive across the enclosed `run_with_state` call — bind it
    to a `var` and add `_ = guard^` (or call `.keep()`) AFTER the fork so ASAP
    destruction does not restore the site before the fork records its segment.
    """

    var _enabled: Bool
    var _prev: UInt32

    def __init__(out self, site: UInt32):
        self._enabled = sched_trace_enabled()
        self._prev = UInt32(0)
        if self._enabled:
            self._prev = sched_trace_swap_site(site)

    def __deinit__(deinit self):
        if self._enabled:
            sched_trace_set_site(self._prev)

    @always_inline
    def keep(self):
        """No-op keepalive anchor: a call after the enclosed fork holds the
        guard live so ASAP destruction does not restore the site early."""
        pass


# -----------------------------------------------------------------------------
# SchedRegion — the scoped bracket
# -----------------------------------------------------------------------------


def sched_trace_configure(enabled: Bool, region_log: Bool = False):
    """Configure scheduler tracing for this process from the binary's flags.

    Call ONCE at startup, before any runtime is constructed (dispatchers and
    workers cache the flag at construction). `enabled` turns the counters on
    and arms the summary dump to stderr at exit; `region_log` also emits the
    per-region markers (it needs `enabled`). Tracing is off until this is
    called."""
    _ = external_call["komira_sched_trace_configure", Int32](
        Int32(1) if enabled else Int32(0),
        Int32(1) if region_log else Int32(0),
    )


@always_inline
def sched_trace_force_enable(on: Bool):
    """TEST-ONLY: set the trace-enable flag without arming the exit dump.

    A `SchedRegion` test without this would be VACUOUS, reading zeros that mean
    "tracing off" rather than "the mechanism is wrong". Does NOT arm the atexit
    dump."""
    _ = external_call["komira_sched_force_enable", Int32](Int32(1) if on else Int32(0))


@always_inline
def sched_region_enter(phase: UInt32) -> Int32:
    """Push `phase` onto this thread's region stack. Returns an opaque token to
    hand back to `sched_region_exit` (0 = not recorded)."""
    return external_call["komira_sched_region_enter", Int32](phase)


@always_inline
def sched_region_exit(
    phase: UInt32, token: Int32, wall_ns: UInt64, fork_ns: UInt64, n: UInt64
):
    """Pop `phase`. Records self_ns = wall_ns - (children's inclusive wall), and
    charges wall_ns to the parent's child accumulator. A pop that does not match
    top-of-stack records a MISNEST and attributes nothing."""
    _ = external_call["komira_sched_region_exit", Int32](
        phase, token, wall_ns, fork_ns, n
    )


@always_inline
def sched_region_set_root(phase: UInt32):
    """Declare which phase id is the query ROOT. The report reads the root's
    self_ns as UNATTRIBUTED and its wall_ns as the partition denominator.
    Without it the dump prints `partition_valid=0`."""
    _ = external_call["komira_sched_region_set_root", Int32](phase)


@always_inline
def sched_region_adopt_driver():
    """Adopt the CALLING thread as the driver for the driver/worker partition.
    `sched_trace_reset()` already does this; call it directly only when a run
    must not clear the counters it is about to read."""
    _ = external_call["komira_sched_region_adopt_driver", Int32]()


@always_inline
def sched_region(phase: UInt32, field: Int32) -> UInt64:
    """Region counter: 0=wall_ns 1=self_ns 2=fork_ns 3=count 4=n 5=depth_max;
    worker partition 6=wall_ns 7=self_ns 8=count."""
    return external_call["komira_sched_get_region", UInt64](phase, field)


@always_inline
def sched_region_health(field: Int32) -> UInt64:
    """Region health: 0=misnest 1=overflow 2=orphan 3=driver_samples
    4=worker_samples 5=root_id 6=open_depth(this thread).

    `misnest != 0` invalidates the whole run's partition — see `SchedRegion`."""
    return external_call["komira_sched_get_region_health", UInt64](field)


struct SchedRegion(Movable):
    """A scoped driver bracket carrying its own nesting, work unit and fork-exclusion.

    THE unit of decomposition. Adding a named phase is two lines:

    ```mojo
    comptime PHASE_MY_WINDOW: UInt32 = 40  # @unit=rows what it counts
    ...
    var r = SchedRegion(PHASE_MY_WINDOW)
    ...                                   # the region
    r.set_n(UInt64(rows))                 # optional: the work unit
    _ = r^                                # close it HERE, not at scope end
    ```

    WHAT IT REPLACES. The legacy `sched_trace_add_serial_phase_n` form needed
    ~6 lines of hand-written timing arithmetic at every site (`_tw_t0 =
    perf_counter_ns()`, `_tw_f0 = sched_trace_fork_ns_now()`, ... the subtraction,
    the call) plus, if it nested, a hand-edited boolean in
    `_sched_phase_is_nested` — a literal
    `return id == 11 || id == 12 || id == 19 || id == 22;` that nothing checked.
    There are 49 such hand-written bracket sites across 9 files today.

    WHY NESTING IS OBSERVED. `self_ns = wall_ns - sum(children wall_ns)` is
    computed from a thread-local stack, so sum(self_ns) over a rooted tree is a
    PARTITION by construction. A new region cannot double-count, and the
    UNATTRIBUTED residue (the root's own self_ns) becomes an ordinary row
    instead of a ratio the dump withholds.

    ⚠ ASAP DESTRUCTION IS THE HAZARD, and it is the same one `SchedSiteScope`
    documents. Mojo destroys a value at its last use, NOT at scope end, so a
    region whose last mention is early will close early and measure the wrong
    window. Close it explicitly with `_ = r^` at the point you mean, or anchor
    it with `r.keep()`. An out-of-order close is DETECTED, not guessed at: it
    bumps MISNEST and the run's whole partition is reported invalid, because a
    plausible wrong partition is worse than none.

    ⚠ THE FORK-EXCLUSION IS WHY `serial` MEANS ANYTHING. `fork_ns` is the
    fork->barrier span that COMPLETED inside the bracket, so `wall - fork` is
    the residue a parallelization could actually recover; a region that already
    forks internally shows near-zero serial and has nothing to recover.

    Zero-cost when tracing is OFF: `_enabled` is cached in a field at
    construction and the OFF path is a cold Bool branch with no external_call.
    """

    var _enabled: Bool
    var _phase: UInt32
    var _token: Int32
    var _t0: UInt64
    var _f0: UInt64
    var _n: UInt64

    def __init__(out self, phase: UInt32, n: UInt64 = UInt64(0)):
        self._enabled = sched_trace_enabled()
        self._phase = phase
        self._token = Int32(0)
        self._t0 = UInt64(0)
        self._f0 = UInt64(0)
        self._n = n
        if self._enabled:
            self._token = sched_region_enter(phase)
            self._f0 = sched_trace_fork_ns_now()
            # t0 LAST so the bracket's own bookkeeping is outside its wall.
            self._t0 = UInt64(perf_counter_ns())

    def __deinit__(deinit self):
        if self._enabled and self._token != Int32(0):
            var t1 = UInt64(perf_counter_ns())
            var wall = t1 - self._t0 if t1 > self._t0 else UInt64(0)
            var f1 = sched_trace_fork_ns_now()
            var fork = f1 - self._f0 if f1 > self._f0 else UInt64(0)
            sched_region_exit(self._phase, self._token, wall, fork, self._n)

    @always_inline
    def set_n(mut self, n: UInt64):
        """Set the region's WORK UNIT, which is usually known only at the END of
        the region (rows gathered, keys copied, groups emitted).

        Why a count and not just a wall: run-to-run wall noise can
        exceed a small lever's effect, so such a lever is not decidable from
        wall in one sweep. `n` is exact, reproducible run to run,
        and moves the instant a lever removes work — so a bracket stays
        falsifiable below its own timing floor."""
        self._n = n

    @always_inline
    def add_n(mut self, n: UInt64):
        """Accumulate into the work unit (a region that counts across a loop)."""
        self._n = self._n + n

    @always_inline
    def enabled(self) -> Bool:
        """The trace flag this region cached at construction.

        Exists so a caller can gate an ADJACENT trace read on the SAME cold Bool
        the region already resolved, instead of paying a second
        `sched_trace_enabled()` external_call on the OFF path. The rule is
        'zero cost when off', and a helper that reads a counter unconditionally
        is not zero."""
        return self._enabled

    @always_inline
    def keep(self):
        """No-op keepalive anchor: a call at the END of the intended region
        holds it live so ASAP destruction does not close it early."""
        pass


# -----------------------------------------------------------------------------
# _SchedWorkerAccum — per-worker POD accumulator (one field on Worker)
# -----------------------------------------------------------------------------


struct _SchedWorkerAccum(Copyable, Movable):
    """Per-worker wall accumulators for the a/b/c/d split. Plain POD scalars
    (trivially safe across destroy-recreate). `enabled` is cached ONCE at Worker construction so the
    worker hot loop gates on a cold Bool field — zero external_call when OFF.

    Absolute totals grow across the whole process; `store()` overwrites the
    matching C slot each iteration. Per-window attribution is a snapshot-delta
    (or reset()) by the reader; for the per-bench binaries a process run IS one
    query, so the cumulative totals give the correct FRACTIONS.
    """

    var enabled: Bool
    var run_ns: UInt64          # sum of handle.run() wall (useful + nested dispatch)
    var pop_ns: UInt64          # MPSC drain-pop overhead (bucket c)
    var park_inter_ns: UInt64   # blocking-park wall while depth==0 (bucket a)
    var park_intra_ns: UInt64   # blocking-park wall while depth>0  (bucket b)
    var spin_ns: UInt64         # empty spin-window CPU-burn (bucket d)
    var empty_windows: UInt64   # count of empty spin windows
    var tasks: UInt64           # count of handles run
    # PRODUCTIVE-SPIN BLIND SPOT. A spin
    # window that ran and THEN caught work used to accumulate into NO bucket — the
    # found-work arm `continue`s straight past every accumulator, so bucket (d)
    # saw only the EMPTY windows and the pre-catch burn was invisible. These two
    # fields make Regime-SPIN burn visible as its OWN bucket (e). `spin_found_ns`
    # is BUSY-EXCLUDED: the window wall MINUS the (pop_ns + run_ns) that advanced
    # inside it, so the drain-pop / handle.run wall the window also covers is not
    # double-counted against bucket (c) or the useful remainder.
    var spin_found_ns: UInt64   # productive spin-window burn, busy-excluded (bucket e)
    var found_windows: UInt64   # count of spin windows that caught work
    # EMPTY-WINDOW CAUSALITY. `empty_windows` above is one
    # undifferentiated count and cannot say WHY the window came up empty. These
    # two partition it by the on-pool dispatch depth sampled at window CLOSE —
    # the same (a)/(b) discriminator the park wall already uses:
    #   inter (depth==0): no dispatch live anywhere -> the pool is starved by the
    #     single-threaded DRIVER's serial region. Real starvation; fix upstream.
    #   intra (depth>0): a dispatch IS live, so work exists somewhere, but THIS
    #     worker's own queue is empty. The spin loop only calls
    #     `drain_task_queue` on its OWN queue and never steals, so this reads as
    #     "my shard finished, the fork did not" — imbalance, a DIFFERENT cause.
    # Invariant: empty_inter_w + empty_intra_w == empty_windows.
    var empty_inter_w: UInt64   # empty windows closed while depth==0
    var empty_intra_w: UInt64   # empty windows closed while depth>0

    def __init__(out self):
        self.enabled = sched_trace_enabled()
        self.run_ns = UInt64(0)
        self.pop_ns = UInt64(0)
        self.park_inter_ns = UInt64(0)
        self.park_intra_ns = UInt64(0)
        self.spin_ns = UInt64(0)
        self.empty_windows = UInt64(0)
        self.tasks = UInt64(0)
        self.spin_found_ns = UInt64(0)
        self.found_windows = UInt64(0)
        self.empty_inter_w = UInt64(0)
        self.empty_intra_w = UInt64(0)

    @always_inline
    def store(self, wid: UInt64):
        """Flush the absolute totals to the process-global C slot for `wid`."""
        _ = external_call["komira_sched_worker_store", Int32](
            wid,
            self.run_ns,
            self.pop_ns,
            self.park_inter_ns,
            self.park_intra_ns,
            self.spin_ns,
            self.empty_windows,
            self.tasks,
            self.spin_found_ns,
            self.found_windows,
            self.empty_inter_w,
            self.empty_intra_w,
        )


# -----------------------------------------------------------------------------
# Agg-in-pass fire counter (the AGG-IN-PASS admission pin). A test-observable
# fire signal INDEPENDENT of the sched-trace block above (same TU-static
# relaxed-atomic mechanism in `_posix_shim.c`, always on and NOT touched
# by `sched_trace_reset`). The fused CASE-B agg-over-join resolver arm bumps this
# once per admission-SUCCESS; the admission-pin test resets + reads it. Purpose:
# close the vacuous-green trap — if admission silently dies,
# `ON` takes the SAME resident path as `OFF` and the byte-equiv oracle passes
# trivially, so a test asserts the fused arm ACTUALLY fired (count>0) on a
# join-then-aggregate shape and DECLINED (count==0) on a wrong-way / non-INNER shape. One relaxed
# add per fire (negligible on the ON path); ZERO on the OFF/decline path.
# -----------------------------------------------------------------------------


@always_inline
def agg_in_pass_fire_inc():
    """Increment the process-global agg-in-pass fire counter (one relaxed add).
    Called at the admission-SUCCESS point of the CASE-B agg-over-join resolver
    arm — both the column-reference fire and the mapped (computed-aggregand) fire."""
    _ = external_call["komira_agg_in_pass_fire_inc", Int32]()


@always_inline
def agg_in_pass_fire_count() -> UInt64:
    """Read the process-global agg-in-pass fire count (test-observable). > 0 iff
    the fused agg-over-join arm has fired since the last reset."""
    return external_call["komira_agg_in_pass_fire_count", UInt64]()


@always_inline
def agg_in_pass_fire_reset():
    """Zero the fire counter (a fresh per-window / per-test measurement)."""
    _ = external_call["komira_agg_in_pass_fire_reset", Int32]()


# -----------------------------------------------------------------------------
# Join-order advisory fire counter. A
# test-observable fire signal for the join-order advisory checker
# (komira_sdk's order advisory), INDEPENDENT of the sched-trace block above
# (same TU-static relaxed-atomic mechanism in `_posix_shim.c`, always on, NOT
# touched by `sched_trace_reset`). The checker bumps this once per DIVERGENCE
# (author join order estimated worse than the optimizer's reordered order). The
# advisory is READ-ONLY (never changes bytes), so a byte-equiv oracle can never
# catch a silently-dead checker — this counter is the fire pin: a falsifier resets it,
# feeds an author order known to blow up, asserts count>0 (FIRED); another feeds an
# already-optimal order, asserts count==0 (SILENT). One relaxed add per fire;
# ZERO on the silent path.
# -----------------------------------------------------------------------------


@always_inline
def order_advisory_fire_inc():
    """Increment the process-global join-order-advisory fire counter (one relaxed
    add). Called at the DIVERGENCE point of the checker (author order estimated
    worse than the optimizer's reordered order)."""
    _ = external_call["komira_order_advisory_fire_inc", Int32]()


@always_inline
def order_advisory_fire_count() -> UInt64:
    """Read the process-global join-order-advisory fire count (test-observable).
    > 0 iff the checker has warned on an order divergence since the last
    reset."""
    return external_call["komira_order_advisory_fire_count", UInt64]()


@always_inline
def order_advisory_fire_reset():
    """Zero the fire counter (a fresh per-test measurement)."""
    _ = external_call["komira_order_advisory_fire_reset", Int32]()


# -----------------------------------------------------------------------------
# Projection-seam leaf-scan decode intermediate-width
# observable. The projection seam narrows a breaker's leaf-scan parquet decode to
# {projection ∪ the breaker's keys}, so the DECODED intermediate carries only kept
# columns — dead columns are never materialized. The post-materialize output is
# byte-identical to the post-materialize narrow regardless, so a byte-equiv oracle cannot
# see whether the pre-materialize narrow fired. This SET-observable records the
# decoded `batch.num_columns()`; each projection falsifier resets + reads it to PROVE
# the pre-materialize narrow (NARROW width fired vs FULL width killed). Shared
# across the projection-seam breakers (sort / partition_topn / window).
# -----------------------------------------------------------------------------
@always_inline
def seam1_decode_ncols_set(n: UInt64):
    """Record the decoded intermediate column count of a projection-seam leaf-scan
    collect. Called right after the decode."""
    _ = external_call["komira_seam1_decode_ncols_set", Int32](n)


# The wide-decode reading is reached structurally by materializing a frame
# with no projection.
@always_inline
def seam1_decode_ncols_get() -> UInt64:
    """Read the last projection-seam leaf-scan decoded intermediate column count
    (test-observable): the NARROW keep-width when the seam fired; the FULL scan width
    when the frame carries NO projection, so the seam declines."""
    return external_call["komira_seam1_decode_ncols_get", UInt64]()


@always_inline
def seam1_decode_ncols_reset():
    """Zero the projection-seam decode-width observable (a fresh per-test measurement)."""
    _ = external_call["komira_seam1_decode_ncols_reset", Int32]()


# -----------------------------------------------------------------------------
# Join-reorder fire counter. Bumped
# once per maximal INNER-join chain the dpccp/greedy reorderer emits a reordered
# order for. The decision pin: a fluent multi-join chain routed through the
# flatten-EXECUTE path asserts count>0 (the reorderer FIRED under the flat plan);
# the kill-switched author-order path never reaches the reorderer -> count==0.
# Same TU-static relaxed-atomic mechanism, always on, NOT reset by
# `sched_trace_reset`.
# -----------------------------------------------------------------------------


@always_inline
def join_reorder_fire_inc():
    """Increment the process-global join-reorder fire counter (one relaxed add).
    Called by `reorder_joins_with_dp` per emitted INNER-join chain."""
    _ = external_call["komira_join_reorder_fire_inc", Int32]()


@always_inline
def join_reorder_fire_count() -> UInt64:
    """Read the process-global join-reorder fire count (test-observable). > 0 iff
    the reorderer has emitted a reordered chain since the last reset."""
    return external_call["komira_join_reorder_fire_count", UInt64]()


@always_inline
def join_reorder_fire_reset():
    """Zero the fire counter (a fresh per-test measurement)."""
    _ = external_call["komira_join_reorder_fire_reset", Int32]()


# -----------------------------------------------------------------------------
# Generic-executor fire counter.
# The test-observable fire signal for the SHAPE-FREE generic wave-fold Runtime-A
# consumer (`run_generic_wave_fold`) — the
# DEFAULT-ON executor for the agg-over-INNER-join star. Same TU-static
# relaxed-atomic mechanism (`_posix_shim.c`), always on, NOT touched by
# `sched_trace_reset`. The generic path is DECLINE-not-corrupt, so the e2e ON leg
# resets + asserts count>0 (the generic wave-fold ACTUALLY drove the query, never a
# vacuous green from a fallback). One relaxed add per fire; ZERO on decline.
# -----------------------------------------------------------------------------


@always_inline
def exec_generic_fire_inc():
    """Increment the process-global generic-wave-fold fire counter (one relaxed
    add). Called at the successful-cascade point of `run_generic_wave_fold`."""
    _ = external_call["komira_exec_generic_fire_inc", Int32]()


@always_inline
def exec_generic_fire_count() -> UInt64:
    """Read the process-global generic-wave-fold fire count (test-observable). > 0
    iff the shape-free generic consumer produced a joined batch since the last
    reset (proving it DROVE the query, not that it declined to the matcher)."""
    return external_call["komira_exec_generic_fire_count", UInt64]()


@always_inline
def exec_generic_fire_reset():
    """Zero the generic fire counter (a fresh per-test measurement)."""
    _ = external_call["komira_exec_generic_fire_reset", Int32]()


# -----------------------------------------------------------------------------
# FUSED-DIM-WAVE reachability counter.
#
# A plain
# `for i in range(payload_dim_count)` of blocking fork-joins over the dim-build
# antichain is replaced by ONE `run_subrg_scan_multi` fork whose task space is the UNION of every eligible dim
# leaf's row groups. This counter accumulates the NUMBER OF DIMS the fused wave
# carried — not the number of waves — so a guard can assert the antichain really
# fused >= 2 leaves rather than the weaker "some wave ran". A revert to the
# sequential loop, or a gate that silently declines every dim, drops it to 0.
#
# Same TU-static relaxed-atomic mechanism as `exec_generic_fire_*`, always on,
# NOT touched by `sched_trace_reset`.
# -----------------------------------------------------------------------------


@always_inline
def fused_dim_wave_add(n_dims: Int):
    """Record that a fused multi-dim BUILD wave carried `n_dims` leaves."""
    _ = external_call["komira_fused_dim_wave_add", Int32](UInt64(n_dims))


@always_inline
def fused_dim_wave_dims() -> UInt64:
    """Read the accumulated fused-dim-wave leaf count (test-observable)."""
    return external_call["komira_fused_dim_wave_dims", UInt64]()


@always_inline
def fused_dim_wave_reset():
    """Zero the fused-dim-wave counter (a fresh per-test measurement)."""
    _ = external_call["komira_fused_dim_wave_reset", Int32]()


# -----------------------------------------------------------------------------
# Partial-bind falsifier's
# seg-state alloc/free BALANCE. `seg_state_alloc_inc` is called by the
# grouped-agg registration leaf's init_thunk (one bump per state-box allocation);
# `seg_state_free_inc` by the free-guard inside the boxed state (one bump per
# teardown). The partial-bind test resets the pair, drives a partial-bind whose Nth init
# RAISES (segs 1..N-1 already bound), and asserts alloc == free — proving the
# already-bound state boxes tear down EXACTLY ONCE on the raise. Same TU-static
# relaxed-atomic mechanism as the fire counter; test-only.
# -----------------------------------------------------------------------------


@always_inline
def seg_state_alloc_inc():
    """Bump the process-global seg-state ALLOC counter (grouped-agg init_thunk)."""
    _ = external_call["komira_seg_state_alloc_inc", Int32]()


@always_inline
def seg_state_free_inc():
    """Bump the process-global seg-state FREE counter (boxed-state teardown guard)."""
    _ = external_call["komira_seg_state_free_inc", Int32]()


@always_inline
def seg_state_alloc_count() -> UInt64:
    """Read the process-global seg-state ALLOC count (test-observable)."""
    return external_call["komira_seg_state_alloc_count", UInt64]()


@always_inline
def seg_state_free_count() -> UInt64:
    """Read the process-global seg-state FREE count (test-observable)."""
    return external_call["komira_seg_state_free_count", UInt64]()


@always_inline
def seg_state_balance_reset():
    """Zero BOTH seg-state balance counters (a fresh per-test measurement)."""
    _ = external_call["komira_seg_state_balance_reset", Int32]()
