# =============================================================================
# sched_sites — the sched-trace SITE_* ids owned by `komira_core` kernels.
# =============================================================================
#
# The canonical SITE_* registry lives in `komira_async`'s sched-trace module
# (ids 0..39) next to the recorder API. But `komira_core` sits BELOW
# `komira_async`, so a core kernel that dispatches a fork-join wave —
# `helpers/compiler_helpers.gather_batch`, stage 4 of every `ORDER BY` —
# cannot import that registry to label its own forks. Without a label, every
# one of its waves lands in the anonymous `SITE_GENERIC_FORK_JOIN` (id 35)
# bucket.
#
# So: the core-owned wave ids are DECLARED here (core can name them) and
# RE-EXPORTED by the sched-trace registry (so it still lists every id in one
# ordered place, and an id collision is visible there). Any id added here
# MUST also be added to the site-name switch in `komira_async`'s reactor C
# shim — a mislabel there is diagnostic-only, but a MISSING one prints the
# useless default "site".
#
# `site_id` is a plain runtime `UInt32` threaded per `run_with_state` fork, never
# a comptime axis, so declaring the constants here costs nothing.
# =============================================================================

# ids 0..39 are owned by komira_async's sched-trace registry.
# ids 40..42: the three dependent waves of `gather_batch`. They are kept
# SEPARATE rather than folded into one "gather" id because the three waves
# have different cost shapes and a regression in any ONE of them must stay
# visible: 40 is O(rows) offset arithmetic,
# 41 is the memcpy-bound byte scatter, 42 is the fixed-width indexed gather.
comptime SITE_GATHER_STR_LEN: UInt32 = 40      # gather_batch STRING pass-1 lengths
comptime SITE_GATHER_STR_SCATTER: UInt32 = 41  # gather_batch STRING pass-2 scatter
comptime SITE_GATHER_FIXEDWIDTH: UInt32 = 42   # gather_batch fixed-width scatter

# id 44: `helpers/join_chunk_plan.join_output_chunk_bounds`' per-tile byte
# pricing wave. id 43 is SITE_FUSED_DIM_BUILD, declared in the sched-trace
# registry.
#
# A SEPARATE ID, DELIBERATELY NOT `SITE_GATHER_STR_LEN` (40). The pricing wave
# computes the SAME per-output-row quantity as wave 1 of the gather
# (`offsets[col_offset+idx+1] - offsets[col_offset+idx]`), so folding it into
# id 40 would "work". It must not be done: the `gather_str_len` fork count is
# a per-query signal (forks = string columns x chunks), and adding this
# wave's forks to that counter would silently change what it measures.
# Separate id, separate row, separate count.
comptime SITE_JOIN_CHUNK_PRICE: UInt32 = 44    # join_chunk_plan per-tile pricing
