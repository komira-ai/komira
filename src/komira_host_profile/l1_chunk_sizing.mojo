# =============================================================================
# l1_chunk_sizing -- the L1-chunk admission predicate and grain rounding
# =============================================================================
#
# `l1_chunk_admit` decides whether a grouped fold should run in L1-sized
# chunks; `l1_chunk_grain_round` rounds a chunk to the grain. Both are pure.
# `MorselSizingPolicy.l1_chunk_rows` (morsel_sizing_policy.mojo) combines them
# with the host's cache sizes.
# =============================================================================

# =============================================================================
# L1-CHUNK SIZING — DEFAULT-ON, NO ENABLE GATE (PERF-L1-CHUNK, path 1)
# =============================================================================
#
# ⚑: `KOMIRA_L1_CHUNK` is DELETED and this path is UNCONDITIONAL.
# The "DEFAULT OFF" / "OFF is the A/B oracle" language below is HISTORY — it
# described the measurement phase. What decides today is `l1_chunk_admit`. The
# full statement of what survived, what went, and where each deleted probe's
# arm now lives is at the ⚑ DEFAULT-ON banner further down this file.
# =============================================================================
#
# WHAT IS WRONG WITH THE SHIPPED SIZING (measured, TPC-H Q1 / sdk b5).
#
#   1. `morsel_rows()` above divides the L1d budget by
#      `Schema.row_width_bytes()`. That is a ROW-STORE width: it sums EVERY
#      column in the FILE schema, and it prices each STRING / DICTIONARY column
#      at a flat 32 B "90th-percentile ETL string" estimate. For the Q1 fixture
#      that is 116 B/row -> (32768/2)/116 = 141 rows.
#   2. `MIN_MORSEL_ROWS_DEFAULT = 1024` then clamps 141 -> 1024.
#   3. `_coalesced_morsel_rows` (komira_parquet/materialize_parquet.mojo)
#      then widens 1024 -> the largest row-group row count = 122,880 rows.
#
#   Net: the computed L1 number is discarded twice and the fold chunk ends up
#   871x larger than the cache-sizing calculation asked for. NOTHING about the
#   shipped chunk size is L1-derived.
#
# WHAT THIS SECTION COMPUTES INSTEAD (the maintainer correction, verbatim):
#
#   "By cache aligning better, it is not about reducing the number of
#    instructions. It is about making sure everything is in the L1 cache so
#    none of the instructions are waiting on the memory controller."
#   "We should be operating columnar like duckdb. They picked 2048 rows because
#    they felt confident that a single column would always fit in L1 cache. I
#    think we could be a little smarter than duckdb because we can use the
#    combination of columns actually being used."
#
#   So the budget is divided by the LIVE row width — the sum over only the
#   columns the operator actually touches, each priced at what the fold reads
#   per row (see `live_row_width_bytes` in
#   `komira_parquet/materialize_parquet.mojo`, which supplies the number).
#
#   DuckDB's 2048 is `16 KiB / 8 B` — one 8-byte column's vector in half of a
#   32 KiB L1d. That is a PER-COLUMN residency claim, and it holds because
#   DuckDB's kernels sweep one column at a time. OUR fold is row-at-a-time
#   ACROSS the live columns inside a chunk (`_apply_agg_update` /
#   `_key_eq_single_col` / `_hash_single_col` all touch every live column on
#   every row), so the residency claim we need is that ALL live columns are
#   co-resident. Hence `budget / SUM(live widths)`, not `budget / max width`.
#
# THE BUDGET FRACTION (justified, not inherited).
#
#   data_budget = l1d_cache_bytes - reserve
#   reserve     = max(resident_state_bytes, l1d * L1_CHUNK_RESERVE_NUM / _DEN)
#                 with the default reserve floor = 1/4 of L1d (8 KiB of 32 KiB).
#
#   Why a 1/4 floor rather than the legacy `/2`, and rather than 0:
#     * NOT 0. The chunk's column payloads are not the only L1 residents. Also
#       hot per-row: the hash table's probed entry lines + the accumulator
#       slots, the key-descriptor / agg-descriptor dispatch structs walked once
#       per row on the generic arm, and the fold's stack frame. 8 KiB is 128
#       cache lines — enough for a low-cardinality group set (Q1's 4 groups x 8
#       accumulators = 256 B) plus the dispatch state, with headroom.
#     * NOT 1/2. The legacy `/2` in `morsel_rows()` was reserving against a
#       ROW-STORE width that already over-counted the payload by ~2x, so it was
#       a reserve on top of a reserve. Once the width is the true live width,
#       halving L1d again would put us BELOW DuckDB's per-column residency for
#       no stated reason.
#     * The floor is a FLOOR: a caller that knows its resident state is bigger
#       (a large hash table) passes `resident_state_bytes` and the reserve grows.
#
# Sweep levers (both are arguments):
#     l1_chunk_budget_bytes(..., base_bytes=<n>)  replace the whole budget
#     l1_chunk_rows(..., forced_rows=<n>)  hard-set the chunk rows, bypassing the formula
#
# =============================================================================
# PHASE 3 REWRITE — THE PREDICATE, AND WHY THE ABOVE WAS HALF OF IT
# =============================================================================
#
# Everything above this banner is the ORIGINAL design and it answers ONE of the
# two questions this policy has to answer. Read the two apart; conflating them
# is the documented root cause of the 81-cell corpus gate blocking L1_CHUNK:
#
#   (a) WHAT SIZE should a chunk be?   -> a cache-level / live-width question.
#   (b) WHETHER to chunk AT ALL?       -> an amortisation / residency question.
#
# Fixing (a) does not touch h2o/q02's +51%. Only (b) does. The measured evidence
# for that separation is a chunk-size sweep on a benchmark host
# (8 arms rotated, 6 rounds x 21 reps, env-size-matched):
#
#   rows      1024     4096     8192    16384    32768    65536   122880
#   q1      -7.01%  -15.99%  -17.11%  -17.52%  -15.24%   -9.10%   +0.33%
#   q02   +242.88% +125.41%  +86.15%  +49.50%  +22.91%   +5.39%   +0.32%
#
# q1 is a broad U. q02 is STRICTLY MONOTONE — there is no chunk size below the
# row group that is anything but a regression for it. So NO SIZING FORMULA CAN
# FIX q02; only declining to chunk can. That is question (b), and it did not
# exist as a concept in the original design: the only decline was the residency
# guard, keyed on `est_groups`, which is -1 (UNKNOWN) on BOTH q1 (which gains
# 17%) and q02 (which loses 50%). The guard could not tell them apart because
# the signal it was reading is absent on both.
#
# ---------------------------------------------------------------------------
# (a) SIZE — the maintainer's live-column-set divisor is KEPT. The BUDGET is re-sited.
# ---------------------------------------------------------------------------
#
# The divisor was never the defect. `live_row_width_bytes` prices only the
# columns the operator touches, from the footer, and it MEASURABLY varies per
# query (q1 = 54 B over 8 live columns; h2o/q02 = 24 B over 3). That is exactly
# the maintainer's "we can be smarter than DuckDB because we can use the combination of
# columns actually being used", and it stays.
#
# The BUDGET was the defect. It was `l1d - l1d/4` = 24 KiB, which over q1's 54 B
# live row is 448 rows — the far LEFT of the sweep above, past the crossover,
# where our per-chunk split cost dominates. The budget is now sited at a
# multiple of the per-core L2 (`L1_CHUNK_BUDGET_NUM/DEN` x `l2_cache_bytes`,
# default 2x = 512 KiB on the Broadwell target), which over q1's 54 B gives
# ~9,700 rows — the middle of the measured -15..-17.5% plateau.
#
# ⚠ THE CACHE LEVEL IS NOT SETTLED AND I AM NOT PRETENDING IT IS. Two
# measurements point different ways and neither is dismissible:
#   * the wall curve above collapses between 32,768 rows (34 MB aggregate over
#     20 workers) and 65,536 (69 MB) against a 55 MiB L3 — which reads as an
#     aggregate-L3 effect (`bench/results/` size sweep, INFERRED from wall);
#   * the PERF-FOLD-4 PMU run measured L3 misses falling 41% with the wall
#     UNMOVED, and 53% of all query cycles sitting in
#     `cycle_activity.stalls_ldm_pending` at 3.78 L1 / 1.52 L2 / 0.52 L3 misses
#     per row — which says the stall is L1/L2 LATENCY and L3 misses were already
#     fully overlapped (MEASURED, counters).
# The honest response to a broad optimum with a contested mechanism is to make
# the budget a NAMED, SWEEPABLE quantity in the middle of the measured plateau
# rather than to assert a cache level. `l1_chunk_budget_bytes(base_bytes=<n>)`
# overrides it whole; the next phase's job is to sweep it, not to believe this
# default.
#
# ---------------------------------------------------------------------------
# (b) WHETHER — amortisation is the discriminator. Width is NOT. Groups is NOT.
# ---------------------------------------------------------------------------
#
# ⚠ THIS IS A DELIBERATE DEVIATION FROM THE maintainer'S FIRST INSTINCT, and the
# measurement that forces it: sizing from the live column set CANNOT answer (b),
# because it discriminates BACKWARDS. h2o/q02's live set is NARROWER than q1's
# (24 B vs 54 B), so a width formula hands the cell that must not be chunked the
# LARGER chunk (1024 rows vs q1's 448). Measured on the shipped binary with
# a chunk-size trace, and confirmed by wall: the pure-formula arm is q1
# +9.53% (9/9 rounds) and q02 +245.54% (9/9) — the worst arm on both cells.
# Width answers (a) and only (a).
#
# GROUP CARDINALITY alone is also not sufficient, and this is the finding that
# kills the obvious fix. Four cells with data:
#
#   cell                       aggs   groups   L1_CHUNK@16384
#   tpch q1                       8        6          -17.5%   <- wants chunking
#   h2o/q02_groupby_2lowcard      1   10,000          +50.3%
#   sdk/b1_agg_lowcard            1       10           +2.8%   <- LOW card, LOSES
#   hc1 / hc2 / hc3             2-3    800K+        declined
#
# Cardinality splits q1 from q02 but puts b1 on the WRONG side. What splits q1
# from BOTH q02 and b1 is the number of FOLD PASSES over the chunk. That is not
# a coincidence: chunking's entire mechanism is making a working set that is
# re-traversed N times cheap to re-traverse. A query with ONE pass has nothing
# to re-traverse and gains nothing from shrinking the set — it only pays the
# per-chunk split cost, multiplied by `rows / chunk_rows`. So:
#
#     ADMIT iff  fold_passes >= L1_CHUNK_MIN_FOLD_PASSES        (amortisation)
#           AND  the operator's own resident state fits the budget  (residency)
#
# ⚠ `L1_CHUNK_MIN_FOLD_PASSES = 4` IS FITTED TO FOUR POINTS. Measured: 8 passes
# wins, 1 pass loses (twice, on two different cells). NOTHING between 2 and 7
# has been measured — hc1/hc2/hc3 sit at 2-3 but decline on residency anyway, so
# they do not constrain it. 4 is chosen conservatively (it declines the whole
# unmeasured middle rather than admitting it) and is tunable via
# `l1_chunk_admit(..., min_passes=<n>)` precisely so the next phase sweeps
# {2,3,4,6,8} over the 81-cell corpus instead of inheriting my guess. ⚠ That
# sweep now needs a RECOMPILE per arm — the env probe is deleted — which is a
# real cost the next phase should plan for and NOT route around by re-adding
# one. If the fused fold
# (PERF-FOLD-4) ever lands default-ON, q1's pass count drops 8 -> 3 and this
# constant MUST come down with it or q1 silently stops being admitted — the two
# are coupled by construction and that coupling is correct, not a bug.
#
# ---------------------------------------------------------------------------
# RESIDENCY IS NOW THREE-STATE, and that is the `est_groups < 0` fix
# ---------------------------------------------------------------------------
#
# `resident_state_bytes` used to be two-state: a byte count, or 0. UNKNOWN was
# spelled 0, i.e. "the hash table is empty", i.e. "definitely small, admit". A
# guard whose failure mode is ADMIT is not a guard. It is now three-state:
#
#     >= 0                      a real estimate; the reserve grows to hold it,
#                               and `>= budget` DECLINES (the hc guard, kept).
#     L1_CHUNK_STATE_UNKNOWN    I have no estimate. ABSTAIN: the reserve keeps
#                               its floor and residency expresses NO OPINION.
#                               Admission then rests ENTIRELY on amortisation.
#
# ⚠ I AM NOT IMPLEMENTING "UNKNOWN -> HARD DECLINE", and the reason is measured,
# not stylistic. Forcing a universal decline (a 1023-byte budget base) was
# run on the box: h2o/q02 returns to baseline (46.178 vs 45.929 ms) and q1
# returns to baseline too — the entire -17% is gone. Hard-declining on UNKNOWN
# is therefore equivalent to deleting the feature, because q1's keys are
# DICT-ENCODED STRINGS and the Parquet footer carries no NDV for them (the
# `distinct_count` / HLL fields are absent on parquet-rs- and DuckDB-written
# files). UNKNOWN does not correlate with the losing cell; it correlates with
# "the key is a string". What DOES correlate is pass count, and that is what
# admits. Abstain is the honest third state: it lets a cell in on affirmative
# evidence from a different conjunct, and it never lets one in on the absence of
# evidence alone.
#
# The estimator that makes residency real where it CAN be real (the product of
# per-key footer NDV upper bounds) lives at
# `komira_parquet/runtime_footer_cache.mojo::agg_leaf_est_groups_from_meta`.
# It resolves h2o/q02 to 10,000 (two int keys, 100 x 100 from min/max stats) and
# hc1/hc2/hc3 to their true large domains. It returns UNKNOWN for q1.
#
# ⚠ AND HERE IS THE ARITHMETIC THAT SHOWS THE ESTIMATOR ALONE WOULD NOT HAVE
# FIXED THE CORPUS GATE, which is the single most important thing to carry
# forward from this landing. Even with a PERFECT `est_groups`, h2o/q02 is
# 10,000 groups x 40 B/slot = 400 KB — UNDER the 512 KiB base. The reserve grows
# to hold it, the budget survives at 124,288 B, and RESIDENCY ADMITS q02. The
# cell that costs +50% would still have been admitted by the guard everyone
# assumed was the fix. Only amortisation declines it. Residency's real job is
# the hc1/hc2/hc3 class (800K+ groups -> tens of MB -> budget 0), where it does
# decline and must keep doing so.
#
# ---------------------------------------------------------------------------
# THE OVERRIDE IS NOT THE SHIPPING PATH, AND IS NOW STRUCTURALLY SEPARATED
# ---------------------------------------------------------------------------
#
# `bench/results/gate_verify/README` states it and this landing enforces
# it. `forced_rows` now overrides SIZE ONLY — it can no longer smuggle
# an ADMISSION past the predicate. Forcing admission is a separate, explicitly
# named `force_admit` PARAMETER (it was `KOMIRA_L1_CHUNK_FORCE`
# until the default flip deleted every behaviour-gating probe), so a measurement
# that bypassed the predicate has to say so in code. Every prior sweep in
# this campaign used the ROWS override and therefore measured a SIZE curve on a
# universally-admitted binary; that is a different experiment from the one that
# ships, and the two must not be quoted for each other.
#
# FALSIFIABLE PREDICTION, WRITTEN BEFORE MEASURING (the campaign's own rule).
# On q1 the principled form computes budget = 2 x 256 KiB = 512 KiB over a
# 54 B live row = 9,709 -> grain-rounded 9,664 rows. The override sweep measured
# -17.11% at 8,192 and -17.52% at 16,384. So the principled form should land at
# -16% to -17.5%. IF IT DOES NOT, THAT GAP IS THE FINDING and it means the
# override was buying something other than its row count.
#
# ⚠ THE OPEN QUESTION THIS INHERITS AND DOES NOT CLOSE — the "LF tax". An arm
# that runs this decision path and DECLINES (byte-identical 122,880-row
# chunking) measured +0.5..+1.2% on the guard cells. Most of that dissolved on
# re-measurement: against an ENV-SIZE-MATCHED control the decision path costs
# ZERO on q1 (-0.29%) and q02 (-0.11%), and the apparent cost was environment-
# block bias (two inert variables alone cost +0.49%/+0.68%, reproducibly, every
# round — no arm in gate_verify had that control). What SURVIVES is hc1 at
# +0.85%, 8/8 rounds; hc3's +0.52% did not reproduce and hc2 was unclean. I
# CANNOT NAME A MECHANISM FOR hc1 AND WILL NOT INVENT ONE — one call per query
# over a few hundred footer entries does not cost 0.58 ms. What this landing
# does instead is make the declining path do STRICTLY LESS WORK than the arm
# that measured it: the amortisation conjunct is evaluated FIRST and
# short-circuits before any footer walk, so a declining query pays two getenv
# calls and an integer compare, not a `live_row_width_bytes` scan over
# `n_row_groups x n_live_columns`. That is a falsifiable mitigation, not an
# explanation. The next phase should re-run hc1 with the env-size-matched
# control on this binary; if +0.85% persists against a path that now does less,
# the cause was never this code.
#
# CLAMPS, AND WHAT EACH ONE IS PROTECTING.
#
#   * `L1_CHUNK_GRAIN = 64` — round DOWN to a multiple of 64 rows. 64 x f64 is
#     8 AVX2 vectors and 8 x 64 B lines; a chunk that is not a whole number of
#     lines leaves a partial line at the seam of every chunk of every column.
#   * `L1_CHUNK_MIN_ROWS = 2048` — and falling below it is now a DECLINE, not a
#     clamp. This is a CHANGE (it was 256, clamped). 2048 is DuckDB's
#     `STANDARD_VECTOR_SIZE` — the chunk size they run EVERY kernel at, and they
#     can afford it because their re-chunk is a pointer reinterpret
#     (`Vector::Reference`) while ours allocates a `MorselArray` and memcpys
#     every nullable / varlen column (`komira_morsel/morsel.mojo`
#     `split_record_batch`). Below the size DuckDB itself uses we have no
#     evidence of a win and direct evidence of split-cost domination: the sweep
#     above prices 1024 rows at q1 -7.01% (less than half the available win) and
#     q02 +242.88%. Clamping into that region silently converts "I cannot make
#     this resident" into "I will chunk it anyway"; declining is the honest
#     answer, and it is the same answer the wide-live-set case wants.
#   * `L1_CHUNK_MAX_ROWS = 16384` — unchanged, and now justified by measurement
#     rather than by an L2 argument: it is the right-hand edge of the measured
#     q1 plateau (-17.52%), one step before the -15.24% at 32,768.
#
#   DECLINE (return 0 — "I have no L1-derived answer, keep your existing
#   sizing") in exactly five situations, all of which are the honest answer
#   rather than a bad number:
#     (a) the hardware probe returned an implausible budget (< 1 KiB);
#     (b) `resident_state_bytes >= budget` — the operator's own state already
#         exceeds the budget, so no chunk size makes the column streams
#         resident. This is the HIGH-CARDINALITY GROUP-BY guard (hc2 is 0.53x vs
#         DuckDB today and must not regress): when the hash table alone blows
#         the budget, shrinking the chunk buys nothing and costs per-chunk
#         dispatch, so we decline and the caller keeps `_coalesced_morsel_rows`;
#     (c) a SINGLE row does not fit in the data budget (the "4 KB string column"
#         case). Same reasoning as (b);
#     (d) NEW — `fold_passes < L1_CHUNK_MIN_FOLD_PASSES`: there is not enough
#         re-traversal to repay the per-chunk split cost (h2o/q02, b1);
#     (e) NEW — the computed row count falls below `L1_CHUNK_MIN_ROWS`: the live
#         set is too wide to be made resident at any chunk size we have evidence
#         for.
#
# ⚠ MEASUREMENT COUPLING — READ BEFORE A/B'ing THIS.
#   This flag is HALF of a two-part design. The other half is per-chunk
#   monomorphic dispatch in the fold (`hash_agg_untyped.mojo`). A smaller chunk
#   costs MORE per-chunk dispatch, and the fold's dispatch is per-ROW today, so
# turning ONLY this flag on is EXPECTED to regress — exactly as the
#   A/B recorded at `materialize_parquet_untyped_agg.mojo:278-289` (q1 35 -> 41
#   ms, verdict "shrinking the fold chunk only adds per-morsel dispatch +
#   per-batch dtype-resolve overhead"). That measurement is CORRECT and it was
#   measuring half a design. The verdict for this flag comes ONLY from the 2x2
#   {old sizing, L1 sizing} x {per-row dispatch, per-chunk monomorphic}.
# MONO_FOLD is default-ON, so that 2x2's second axis is now
#   the shipped default and this flag's verdict is legible on its own.


comptime L1_CHUNK_MIN_ROWS: Int = 2048
comptime L1_CHUNK_MAX_ROWS: Int = 16384
comptime L1_CHUNK_GRAIN: Int = 64
comptime L1_CHUNK_RESERVE_NUM: Int = 1
comptime L1_CHUNK_RESERVE_DEN: Int = 4

# The per-chunk DATA budget, as a fraction of the per-core L2. 2/1 = 2 x L2 =
# 512 KiB on the Broadwell measurement target, which over q1's 54 B live row is
# ~9,700 rows — the middle of the measured -15..-17.5% plateau. See the "(a)
# SIZE" section: the CACHE LEVEL is contested, the PLATEAU is not, and this
# constant is sited in the plateau rather than asserted from a cache level.
comptime L1_CHUNK_BUDGET_NUM: Int = 2
comptime L1_CHUNK_BUDGET_DEN: Int = 1

# The amortisation conjunct. FITTED TO FOUR MEASURED POINTS — see the "(b)
# WHETHER" section. Sweep it by passing `min_passes` to `l1_chunk_admit`; do not
# treat 4 as evidence.
comptime L1_CHUNK_MIN_FOLD_PASSES: Int = 4

# The THIRD state of `resident_state_bytes`: "I have no estimate." Distinct from
# 0 ("the table is empty"), which is what UNKNOWN used to be spelled as and is
# the defect that made q1 and h2o/q02 indistinguishable to the guard. Any
# negative value is treated as UNKNOWN; this constant names the intended one.
comptime L1_CHUNK_STATE_UNKNOWN: Int = -1

# Sentinel returned by `l1_chunk_rows` meaning "no L1-derived answer; the caller
# must keep whatever sizing it would have used".
comptime L1_CHUNK_DECLINE: Int = 0


# =============================================================================
# ⚑ DEFAULT-ON — THE ENABLE GATE IS DELETED, NOT FLIPPED
# =============================================================================
#
# `l1_chunk_enabled()` / `KOMIRA_L1_CHUNK` is GONE, per the maintainer no-shipped-
# kill-switches directive.
#
# ⚠ PROVENANCE — THE LINT DID NOT FORCE THIS, AND SAYING IT DID WOULD BE FALSE.
# `scripts/lint_no_perf_killswitch.sh` matches exactly
# `KOMIRA_*_OFF` / `_DISABLE` / `_DISABLED` / `KOMIRA_DISABLE_*` /
# `KOMIRA_NO_*`, and its header EXPLICITLY excludes `KOMIRA_*_ON` and
# `KOMIRA_*_FORCE` as a different, cheaper class. `KOMIRA_L1_CHUNK` matched
# NONE of those patterns and neither did `KOMIRA_L1_CHUNK_FORCE`; the gate was
# green over this flag on the day it was deleted and would still be green if it
# came back. This deletion is VOLUNTARY CONFORMANCE to the directive, chosen
# because the flag met the directive's description, not a gate response. That
# distinction is load-bearing: a reader who believes the lint compelled it will
# also believe the lint would catch its return, and it would not.
#
# (Separately, and not caused by this landing: the lint is RED on trunk today
# over a pre-existing `KOMIRA_CD_GROUPED_SCAN_DEDUP_OFF` probe at
# `komira_engine_operators/unified/agg/streaming_agg_count_distinct.mojo:430`,
# verified present on pristine `origin/main`. Do not attribute it here.)
#
# A fast path we have decided to ship is not an experiment, and an env probe
# that turns it off is a second unexercised implementation kept alive on a hot
# path. Chunking is now UNCONDITIONAL: every parquet agg leaf runs the
# admission predicate, and `l1_chunk_admit` — not an environment — decides.
#
# ⚠ THAT MEANS `l1_chunk_admit` IS NOW THE ONLY THING BETWEEN A QUERY AND A
# CHUNKED FOLD. It was a measurement guard; it is a production guard. Its two
# conjuncts are the whole safety argument, and the cell it exists to decline
# (h2o/q02_groupby_2lowcard, +50.3% when admitted) is a corpus cell, not a
# hypothetical. Read the "(b) WHETHER" section before touching either conjunct.
#
# WHAT SURVIVES, AND WHY EXACTLY THESE TWO:
#
#   The chunk-size trace — DIAGNOSTIC ONLY. A caller that wants the decision and
#     its inputs printed does so from the values it already holds; the policy
#     carries no trace switch, and a trace cannot change `chosen`. The numbers
#     in this module's docstrings are checkable by reading them off a shipped
#     binary. ⚠ A traced run is not a timing run: under trace the expensive
#     terms are computed regardless of admission.
#
#   `forced_rows` — the SIZE lever, and the NULL CONTROL. Setting it to
#     122880 puts the row-group-sized chunk back and must reproduce the pre-flip
#     wall (measured 80.6 ms on q1); that control is how the default path's
#     -18% is falsified rather than asserted, and deleting it would delete the
#     campaign's only one-binary A/B. It overrides SIZE only — it cannot grant
#     admission — and the cache level this module sizes from is stated CONTESTED
#     in the "(a) SIZE" section, so the sweep it serves is not finished.
#
# WHAT WENT, AND WHERE ITS ARM LIVES NOW. `KOMIRA_L1_CHUNK_FORCE`,
# `KOMIRA_L1_CHUNK_MIN_PASSES` and `KOMIRA_L1_CHUNK_BYTES` all GATED
# BEHAVIOUR, so all three are deleted as probes and re-exposed as plain
# defaulted parameters on the production functions (`force_admit`, `min_passes`,
# `base_bytes`) — the shape the directive's own removals used, reference commit
# ``. A test drives the other arm by passing an argument; an unset
# environment can no longer reach one. `_set_l1_chunk_*` is deliberately NOT a
# mutable global here: these are pure free functions with no construction site
# to read a global at, and a parameter is checkable by the type system where a
# global is a runtime convention.
#
# ⚠ AND THEY ARE THREADED TO THE SEAM, WHICH IS NOT OPTIONAL. "A test drives the
# other arm by passing an argument" is only true if the argument exists on the
# function a query actually calls. `force_admit` / `min_passes` therefore also
# appear on `komira_parquet.materialize_parquet.agg_leaf_morsel_rows`, the ONE
# production caller of `l1_chunk_rows`. Stopping them at the policy method would
# have left both sweeps reachable only from a unit test that bypasses the seam —
# a knob that cannot be turned where the decision is made is a comment, and the
# deletion of the two env probes was justified by these arms being reachable.


def l1_chunk_admit(
    fold_passes: Int,
    budget_bytes: Int,
    min_passes: Int = L1_CHUNK_MIN_FOLD_PASSES,
) -> Bool:
    """THE ADMISSION PREDICATE — question (b), "chunk at all?".

    PURE — no environment at all — so the decision is directly unit-testable
    without a `HardwareProfile`, a footer, or a process environment. Since the
    default flip there is no ENABLE gate anywhere: this predicate IS
    the decision, on every parquet agg leaf, in production.

    Two conjuncts, both required:

      RESIDENCY — `budget_bytes > 0`. The budget is already the residency
        verdict in scalar form: `l1_chunk_budget_bytes` returns 0 when the
        probe is implausible or when the operator's own resident state meets or
        exceeds the budget (the high-cardinality group-by guard). Residency
        ABSTAINS rather than declines when the group count is unknown — see
        `L1_CHUNK_STATE_UNKNOWN`.

      AMORTISATION — `fold_passes >= min_passes`. Chunking
        multiplies a fixed per-chunk cost (a `MorselArray` allocation plus a
        copy-slice of every nullable / varlen column) by `rows / chunk_rows`.
        That is repaid only by re-traversal: shrinking a working set that is
        walked ONCE buys nothing and costs the split. Measured: 8 passes wins
        17.5%, 1 pass loses on two independent cells (h2o/q02 +50.3% at 16,384
        rows and monotonically worse below; sdk/b1_agg_lowcard +2.8%) — and b1
        has only TEN groups, so cardinality would have admitted it. This is the
        conjunct cardinality cannot supply.

    Args:
        fold_passes: How many times the fold walks the chunk's rows. For the
            untyped grouped agg that is the aggregate count (one agg-major pass
            per aggregate expression). A value <= 0 means "unknown" and is
            treated as NOT amortising — unknown must never admit.
        budget_bytes: The output of `l1_chunk_budget_bytes`.
        min_passes: The amortisation threshold. Defaults to
            `L1_CHUNK_MIN_FOLD_PASSES`, which is FITTED TO FOUR MEASURED POINTS
            and nothing in 2..7 has been measured. It is a parameter, not an
            env probe, so a sweep names it at the call site and the shipped
            default cannot be moved by an environment (was
            `KOMIRA_L1_CHUNK_MIN_PASSES`, deleted).

    Returns:
        True iff BOTH conjuncts hold. False is a DECLINE: the caller keeps the
        sizing it would otherwise have used.
    """
    if budget_bytes <= 0:
        return False
    if fold_passes < min_passes:
        return False
    return True


def l1_chunk_grain_round(rows: Int) -> Int:
    """Round `rows` DOWN to a multiple of `L1_CHUNK_GRAIN`, clamp at
    `L1_CHUNK_MAX_ROWS`, and DECLINE below `L1_CHUNK_MIN_ROWS`. Split out from
    `l1_chunk_rows` so the grain / clamp / floor behaviour is unit-testable
    without a `HardwareProfile`.

    ⚠ THE FLOOR IS A DECLINE, NOT A CLAMP (changed). It used to clamp
    a too-small computed row count UP to 256, which silently converted "I cannot
    make this live set resident at any size I have evidence for" into "I will
    chunk it anyway at a size the measurements say is bad". The sweep prices
    1024 rows at q1 -7.01% (under half the available win) and h2o/q02 +242.88%;
    2048 is DuckDB's own `STANDARD_VECTOR_SIZE`, and we cannot afford what they
    can because their re-chunk is a pointer reinterpret and ours is a memcpy.
    Below the floor the honest answer is to keep the caller's sizing.
    """
    var r = (rows // L1_CHUNK_GRAIN) * L1_CHUNK_GRAIN
    if r > L1_CHUNK_MAX_ROWS:
        r = L1_CHUNK_MAX_ROWS
    if r < L1_CHUNK_MIN_ROWS:
        return L1_CHUNK_DECLINE
    return r


